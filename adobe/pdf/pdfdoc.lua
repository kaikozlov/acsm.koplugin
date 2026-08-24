--- PDF document reader for ADEPT decryption.
-- Reads PDF structure (xref, trailer, objects), extracts encryption info,
-- and provides per-object decryption using the book key.
--
-- Ported from ineptpdf.py (PDFDocument, PDFXRef, PDFXRefStream).

local logger = require("logger")

local pdfparser = require("adobe.pdf.parser")
local ffi = require("ffi")

local pdfdoc = {}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function is_keyword(obj, expected)
    if type(obj) ~= "table" then
        return false
    end
    if getmetatable(obj) ~= pdfparser.PSKeyword then
        return false
    end
    if expected then
        return obj.name == expected
    end
    return true
end

local function name_str(obj)
    if type(obj) == "table" and getmetatable(obj) == pdfparser.PSLiteral then
        return obj.name
    end
    if type(obj) == "string" then
        return obj
    end
    return nil
end

local function int_value(x)
    if x == nil then
        return 0
    end
    if type(x) == "number" then
        return x
    end
    -- indirect ref? resolve later
    return 0
end

--- Apply PNG Up predictor decoding (Predictor 12).
-- Strips filter bytes and reconstructs rows.
-- @param data string compressed data with filter bytes
-- @param params table with Columns and Predictor keys
-- @return string unpredicted data (columns bytes per row)
local function _unpredict(data, params)
    local predictor = params.Predictor or params["predictor"] or params["Predictor"]
    if not predictor or predictor == 0 then
        return data
    end
    local columns = params.Columns or params["columns"] or params["Columns"] or 1
    if columns == 0 then
        return data
    end
    local row_len = columns + 1
    local buf = {}
    local prev = string.rep("\0", columns)
    for i = 0, #data - 1, row_len do
        if i + row_len > #data then
            break
        end
        local filter = data:byte(i + 1)
        local row = data:sub(i + 2, i + row_len)
        if filter == 2 then
            local parts = {}
            for j = 1, #row do
                parts[j] = string.char((row:byte(j) + prev:byte(j)) % 256)
            end
            row = table.concat(parts)
        end
        buf[#buf + 1] = row
        prev = row
    end
    return table.concat(buf)
end

local function paeth(a, b, c)
    local p = a + b - c
    local pa, pb, pc = math.abs(p - a), math.abs(p - b), math.abs(p - c)
    if pa <= pb and pa <= pc then
        return a
    elseif pb <= pc then
        return b
    end
    return c
end

--- Decode a PNG-predicted (Predictor >= 10) buffer: each row is prefixed
-- with a filter byte selecting None/Sub/Up/Average/Paeth reconstruction.
-- Handles the full PNG filter family; producers (qpdf, Acrobat Fast Web
-- View) routinely mix filters across rows.
local function _unpredictPNG(data, columns)
    local row_len = columns + 1
    local buf = {}
    local prev = string.rep("\0", columns)
    for i = 0, #data - 1, row_len do
        if i + row_len > #data then
            break
        end
        local filter = data:byte(i + 1)
        local row = data:sub(i + 2, i + row_len)
        if filter == 1 then -- Sub: delta vs left neighbor (raw input)
            local out = {}
            for j = 1, #row do
                local left = j > 1 and out[j - 1]:byte() or 0
                out[j] = string.char((row:byte(j) + left) % 256)
            end
            row = table.concat(out)
        elseif filter == 2 then -- Up: delta vs previous row
            local out = {}
            for j = 1, #row do
                out[j] = string.char((row:byte(j) + prev:byte(j)) % 256)
            end
            row = table.concat(out)
        elseif filter == 3 then -- Average: delta vs floor((left+up)/2) (raw input)
            local out = {}
            for j = 1, #row do
                local left = j > 1 and out[j - 1]:byte() or 0
                out[j] = string.char((row:byte(j) + math.floor((left + prev:byte(j)) / 2)) % 256)
            end
            row = table.concat(out)
        elseif filter == 4 then -- Paeth
            local out = {}
            for j = 1, #row do
                local left = j > 1 and out[j - 1]:byte() or 0
                local up = prev:byte(j)
                local upleft = j > 1 and prev:byte(j - 1) or 0
                out[j] = string.char((row:byte(j) + paeth(left, up, upleft)) % 256)
            end
            row = table.concat(out)
        end
        -- filter 0 (None): row is already raw
        buf[#buf + 1] = row
        prev = row
    end
    return table.concat(buf)
end

--- Resolve predictor parameters for an xref stream and unpredict its data.
-- Per PDF 32000-1 7.4.4.3, /Predictor and /Columns live inside /DecodeParms
-- (a dict, or an array of dicts when the stream has multiple filters).
-- Some producers inline them at the top level of the stream dict instead —
-- accept both. Columns defaults to the W-array entry length.
-- @param data string inflated xref stream data
-- @param dic table the xref stream's dictionary
-- @param entlen number W[1]+W[2]+W[3] entry length
-- @return string unpredicted data
local function _applyXRefPredictor(data, dic, entlen)
    local parms = dic.DecodeParms or dic["decodeparms"] or dic["DecodeParms"]
    if type(parms) == "table" and parms[1] ~= nil and type(parms[1]) == "table" then
        -- Array of per-filter parameter dicts: use the first
        parms = parms[1]
    end
    local params = type(parms) == "table" and parms or dic
    local predictor =
        int_value(params.Predictor or params["predictor"] or params["Predictor"] or dic.Predictor or dic["predictor"] or dic["Predictor"])
    if predictor == 0 then
        return data
    end
    local columns = int_value(params.Columns or params["columns"] or params["Columns"] or dic.Columns or dic["columns"] or dic["Columns"])
    if columns == 0 then
        columns = entlen
    end
    if predictor >= 10 then
        return _unpredictPNG(data, columns)
    end
    -- Predictor 2 (TIFF horizontal differencing) and legacy inline form:
    -- the old decoder treats the data as PNG-Up rows; keep that behavior.
    return _unpredict(data, { Predictor = predictor, Columns = columns })
end

------------------------------------------------------------------------
-- PDFStream
------------------------------------------------------------------------

-- PDFStream is a plain table with these fields:
--   dic      - the stream dictionary (table with string keys)
--   rawdata  - raw (still encrypted) stream data
--   data     - decoded data (after decrypt + decompress), nil until accessed
--   decdata  - decrypted-but-not-decompressed data
--   decdic   - decrypted dictionary
--   objid    - object ID
--   genno    - generation number
--   decipher - decrypt function(objid, genno, data) -> decrypted data
--
-- This matches ineptpdf.py's PDFStream class exactly.

local PDFStream = {}
PDFStream.__index = PDFStream
pdfdoc.PDFStream = PDFStream

function PDFStream:new(dic, rawdata, decipher)
    local stream = setmetatable({
        dic = dic or {},
        rawdata = rawdata or "",
        decipher = decipher,
        data = nil,
        decdata = nil,
        decdic = nil,
        objid = 0,
        genno = 0,
    }, self)
    return stream
end

function PDFStream:set_objid(objid, genno)
    self.objid = objid
    self.genno = genno
end

--- Decode the stream: decrypt (if cipher), then decompress (if filter).
-- Matches ineptpdf.py PDFStream.decode()
function PDFStream:decode(gen_xref_stm)
    if self.data ~= nil then
        return
    end -- already decoded
    assert(self.rawdata ~= nil, "PDFStream:decode called with nil rawdata")

    local data = self.rawdata

    -- Step 1: Decrypt if we have a cipher
    if self.decipher and data and #data > 0 then
        data = self.decipher(self.objid, self.genno, data)
        -- Also decrypt dict string values
        local dic = pdfdoc.decipher_all(self.decipher, self.objid, self.genno, self.dic)
        if gen_xref_stm then
            self.decdata = data
            self.decdic = dic
        end
    end

    -- Step 2: Decompress if /Filter present
    -- For clean output we write raw decrypted data (get_decdata),
    -- so we don't actually need to decompress here for the main use case.
    -- But keep it for completeness.
    self.data = data
    self.rawdata = nil
end

--- Get decoded (decrypted + decompressed) data.
function PDFStream:get_data()
    if self.data == nil then
        self:decode()
    end
    return self.data
end

--- Get raw (still possibly encrypted) data.
function PDFStream:get_rawdata()
    return self.rawdata
end

--- Get decrypted data (not decompressed).
-- This is what PDFSerializer uses for writing clean output.
-- Matches ineptpdf.py PDFStream.get_decdata()
function PDFStream:get_decdata()
    if self.decdata ~= nil then
        return self.decdata
    end
    local data = self.rawdata
    if self.decipher and data and #data > 0 then
        data = self.decipher(self.objid, self.genno, data)
    end
    return data
end

--- Get decrypted dictionary.
-- Matches ineptpdf.py PDFStream.get_decdic()
function PDFStream:get_decdic()
    if self.decdic ~= nil then
        return self.decdic
    end
    local dic = self.dic
    if self.decipher and dic then
        dic = pdfdoc.decipher_all(self.decipher, self.objid, self.genno, dic)
    end
    return dic
end

------------------------------------------------------------------------
-- Classic xref table
------------------------------------------------------------------------

local PDFXRef = {}
PDFXRef.__index = PDFXRef
pdfdoc.PDFXRef = PDFXRef

function PDFXRef:new()
    return setmetatable({
        offsets = {}, -- objid -> {genno, offset}
        trailer = nil,
    }, self)
end

function PDFXRef:objids()
    local ids = {}
    for id, _ in pairs(self.offsets) do
        ids[#ids + 1] = id
    end
    table.sort(ids)
    return ids
end

function PDFXRef:load(p)
    -- After "xref" keyword, read subsections until "trailer"
    while true do
        local pos, line = p:nextline()
        if not line or line == "" then
            error("Premature EOF reading xref")
        end
        if line:match("^%s*trailer") then
            p:seek(pos)
            break
        end
        local start_s, nobjs_s = line:match("^%s*(%d+)%s+(%d+)%s*$")
        if not start_s then
            error("Invalid xref line: " .. tostring(line))
        end
        local start = tonumber(start_s)
        local nobjs = tonumber(nobjs_s)
        for i = 0, nobjs - 1 do
            local _, entry_line = p:nextline()
            if entry_line then
                local offset_s, genno_s, use = entry_line:match("^%s*(%d+)%s+(%d+)%s+(%w)")
                if use == "n" and offset_s then
                    self.offsets[start + i] = {
                        genno = tonumber(genno_s),
                        offset = tonumber(offset_s),
                    }
                end
            end
        end
    end
    self:load_trailer(p)
end

function PDFXRef:load_trailer(p)
    local _, tok = p:nexttoken()
    if not is_keyword(tok, "trailer") then
        error("Expected 'trailer' keyword")
    end
    local result = p:nextobject()
    if not result or type(result[2]) ~= "table" then
        error("Expected trailer dict")
    end
    self.trailer = result[2]
end

function PDFXRef:getpos(objid)
    local entry = self.offsets[objid]
    if not entry then
        return nil
    end
    return entry.offset, entry.genno
end

------------------------------------------------------------------------
-- XRef stream (PDF 1.5+)
------------------------------------------------------------------------

local PDFXRefStream = {}
PDFXRefStream.__index = PDFXRefStream
pdfdoc.PDFXRefStream = PDFXRefStream

function PDFXRefStream:new()
    return setmetatable({
        index = {}, -- list of {first, size}
        data = nil,
        fl1 = 0,
        fl2 = 0,
        fl3 = 0,
        entlen = 0,
        trailer = nil,
    }, self)
end

local function nunpack(s, default)
    if not s or #s == 0 then
        return default or 0
    end
    local v = 0
    for i = 1, #s do
        v = v * 256 + s:byte(i)
    end
    return v
end

function PDFXRefStream:load(p)
    -- The stream object follows the objid/genno/obj tokens
    -- It's already been positioned by the caller
    local result = p:nextobject()
    -- nextobject returns a single {pos, value} table — unwrap it
    local obj = type(result) == "table" and result[2] or nil
    if type(obj) ~= "table" or not obj.rawdata then
        error("Expected PDFStream for xref stream")
    end

    local dic = obj.dic or {}
    local streamType = name_str(dic.Type or dic["Type"])
    if streamType ~= "XRef" then
        error("Invalid XRef stream: Type=" .. tostring(streamType))
    end

    local size = int_value(dic.Size or dic["size"])
    local indexRaw = dic.Index or dic["index"]
    if indexRaw == nil then
        self.index = { { 0, size } }
    else
        if type(indexRaw) ~= "table" then
            indexRaw = { indexRaw }
        end
        self.index = {}
        for i = 1, #indexRaw, 2 do
            self.index[#self.index + 1] = { indexRaw[i], indexRaw[i + 1] }
        end
    end

    local w_val = dic.W or dic["w"] or dic["W"]
    if type(w_val) ~= "table" then
        w_val = { w_val, w_val, w_val }
    end
    self.fl1 = int_value(w_val[1])
    self.fl2 = int_value(w_val[2])
    self.fl3 = int_value(w_val[3])
    self.entlen = self.fl1 + self.fl2 + self.fl3

    -- Decompress the stream data
    local rawdata = obj.rawdata or ""
    -- Try zlib decompress
    local ok, zlib = pcall(require, "adobe.util.zlib")
    if ok and zlib and #rawdata > 0 then
        local inflater = zlib.inflater()
        local parts = {}
        inflater:update(rawdata, #rawdata, function(ptr, len)
            parts[#parts + 1] = ffi.string(ptr, len)
        end)
        inflater:close()
        local decompressed = (parts[1] and table.concat(parts) or nil)
        if decompressed then
            self.data = _applyXRefPredictor(decompressed, dic, self.entlen)
        else
            self.data = rawdata
        end
    else
        self.data = rawdata
    end

    self.trailer = dic
end

--- Load from a pre-parsed stream object (for _read_xref_from).
function PDFXRefStream:load_from_obj(obj, start)
    if type(obj) ~= "table" or not obj.rawdata then
        error("Expected PDFStream for xref stream")
    end
    local dic = obj.dic or {}
    local streamType = name_str(dic.Type or dic["Type"] or dic["type"])
    if streamType ~= "XRef" then
        error("Invalid XRef stream: Type=" .. tostring(streamType))
    end
    local size = int_value(dic.Size or dic["size"] or dic["Size"])
    local indexRaw = dic.Index or dic["index"] or dic["Index"]
    if indexRaw == nil then
        self.index = { { 0, size } }
    else
        if type(indexRaw) ~= "table" then
            indexRaw = { indexRaw }
        end
        self.index = {}
        for i = 1, #indexRaw, 2 do
            self.index[#self.index + 1] = { indexRaw[i], indexRaw[i + 1] }
        end
    end
    local w_val = dic.W or dic["w"] or dic["W"]
    if type(w_val) ~= "table" then
        w_val = { w_val, w_val, w_val }
    end
    self.fl1 = int_value(w_val[1])
    self.fl2 = int_value(w_val[2])
    self.fl3 = int_value(w_val[3])
    self.entlen = self.fl1 + self.fl2 + self.fl3
    local rawdata = obj.rawdata or ""
    local ok, zlib_mod = pcall(require, "adobe.util.zlib")
    if ok and zlib_mod and #rawdata > 0 then
        local inflater = zlib_mod.inflater()
        local parts = {}
        inflater:update(rawdata, #rawdata, function(ptr, len)
            parts[#parts + 1] = ffi.string(ptr, len)
        end)
        inflater:close()
        local decompressed = (parts[1] and table.concat(parts) or nil)
        if decompressed then
            self.data = _applyXRefPredictor(decompressed, dic, self.entlen)
        else
            self.data = rawdata
        end
    else
        self.data = rawdata
    end

    self.trailer = dic
end
function PDFXRefStream:objids()
    local ids = {}
    for _, idx in ipairs(self.index) do
        local first, size = idx[1], idx[2]
        for id = first, first + size - 1 do
            ids[#ids + 1] = id
        end
    end
    return ids
end

function PDFXRefStream:getpos(objid)
    local offset = 0
    for _, idx in ipairs(self.index) do
        local first, size = idx[1], idx[2]
        if first <= objid and objid < first + size then
            if not self.data or self.entlen == 0 then
                -- xref data failed to decode (bad predictor/unpredict) —
                -- an offset read from garbage would silently misparse objects
                return nil
            end
            local i = self.entlen * ((objid - first) + offset)
            if i + self.entlen > #self.data then
                return nil
            end
            local ent = self.data:sub(i + 1, i + self.entlen) -- Lua 1-indexed
            local f1 = nunpack(ent:sub(1, self.fl1), 1)
            if f1 == 1 then
                -- Object at offset
                local pos = nunpack(ent:sub(self.fl1 + 1, self.fl1 + self.fl2))
                if pos == 0 then
                    -- Offset 0 is never a valid object start (that is the
                    -- %PDF header); signals garbage-decoded offsets.
                    return nil
                end
                return pos, 0
            elseif f1 == 2 then
                -- Object in ObjStm
                local stmid = nunpack(ent:sub(self.fl1 + 1, self.fl1 + self.fl2))
                local stindex = nunpack(ent:sub(self.fl1 + self.fl2 + 1))
                return nil, 0, stmid, stindex -- signal: need ObjStm
            end
            -- free object
            return nil
        end
        offset = offset + size
    end
    return nil
end

------------------------------------------------------------------------
-- PDFDocument
------------------------------------------------------------------------

local PDFDocument = {}
PDFDocument.__index = PDFDocument
pdfdoc.PDFDocument = PDFDocument

function PDFDocument:new()
    return setmetatable({
        xrefs = {},
        objs = {}, -- objid -> parsed object
        trailer = nil,
        encryption = nil, -- { docid, param } from trailer
        encrypt_objid = nil,
        root = nil,
        header = nil,
        file = nil,
        parser = nil,
    }, self)
end

--- Open and parse a PDF file's structure (xref, trailer, encryption).
function PDFDocument:open(filepath)
    local f, err = io.open(filepath, "rb")
    if not f then
        return nil, "Cannot open file: " .. err
    end
    self.file = f

    -- Read header
    self.header = f:read(8) or "%PDF-1.0"
    if not self.header:match("^%%PDF") then
        -- Not a valid PDF header, but we'll try anyway
        logger.warn("[pdfdoc] File does not start with %PDF header")
    end

    -- Skip the binary comment line
    local p = pdfparser.new(f)
    self.parser = p

    -- Find xref
    self.xrefs = self:_read_xref()

    -- Collect trailer info
    for _, xref in ipairs(self.xrefs) do
        local trailer = xref.trailer
        if not trailer then
            goto continue
        end

        -- Extract encryption info
        if trailer.Encrypt or trailer["Encrypt"] then
            local encryptRef = trailer.Encrypt or trailer["Encrypt"]
            if type(encryptRef) == "table" and encryptRef.ref then
                self.encrypt_objid = encryptRef.ref.objid
            end
            local idList = trailer.ID or trailer["id"] or {}
            if type(idList) ~= "table" then
                idList = { idList }
            end
            -- Actually load the Encrypt dict object from the file
            -- (don't use getobj yet — decipher isn't set, and we want the
            -- raw encrypted dict to read encryption parameters)
            local encryptDict = {}
            if type(encryptRef) == "table" and encryptRef.ref then
                local encObj = self:_loadRawObject(encryptRef.ref.objid)
                if type(encObj) == "table" and not encObj.ref then
                    encryptDict = encObj
                end
            elseif type(encryptRef) == "table" and not encryptRef.ref then
                encryptDict = encryptRef
            end
            self.encryption = {
                docid = idList,
                param = encryptDict,
            }
        end

        -- Extract root
        if trailer.Root or trailer["Root"] then
            self.root = trailer.Root or trailer["Root"]
            break
        end

        ::continue::
    end

    return true
end

function PDFDocument:close()
    if self.file then
        self.file:close()
        self.file = nil
    end
end

--- Find the startxref offset by scanning backwards from EOF.
function PDFDocument:_find_xref()
    local f = self.file
    f:seek("end", -1024) -- search last 1KB
    local chunk = f:read(1024) or ""
    -- Find "startxref" followed by a number
    local startxref_pos = chunk:match("startxref%s+(%d+)")
    if startxref_pos then
        return tonumber(startxref_pos)
    end
    return nil, "startxref not found"
end

--- Read xref tables starting from a given offset.
function PDFDocument:_read_xref_from(start, xrefs)
    local f = self.file
    local p = pdfparser.new(f)
    p:seek(start) -- parser.new() resets to 0, so we must seek

    local _, token = p:nexttoken()

    if type(token) == "number" then
        -- XRef stream (PDF 1.5+): starts with objid
        -- parser.new() seeks to 0; re-seek to the xref stream's offset
        p = pdfparser.new(f)
        p:seek(start)
        local xref = PDFXRefStream:new()
        -- Read objid genno obj tokens then the stream
        p:nexttoken() -- objid (number)
        p:nexttoken() -- genno (number)
        p:nexttoken() -- "obj" keyword
        -- Now read the stream object.
        -- nextobject returns a single {pos, value} table — unwrap it.
        local result = p:nextobject()
        local stream_obj = type(result) == "table" and result[2] or nil
        -- If the tokenizer gave us a proper stream (dic + rawdata), use it
        -- directly — it handles nested dicts (DecodeParms etc.) correctly.
        -- Fallback: parse raw PDF text ourselves (for tokenizers/parsers that
        -- failed, e.g. legacy files the tokenizer chokes on).
        if type(stream_obj) ~= "table" or stream_obj.ref or not stream_obj.dic then
            -- Fallback: parse raw PDF text ourselves
            f:seek("set", start)
            local content = f:read(65536) or ""
            -- Pattern search for "stream" followed by CR/LF (PDF spec allows \r\n, \r, or \n)
            local streamMarker = content:find("stream[\r\n]")
            if streamMarker then
                local dataStart = content:find("[\r\n]", streamMarker + 6) + 1
                local endMarker = content:find("endstream", dataStart, true)
                if endMarker then
                    local realEnd = endMarker - 1
                    while realEnd >= dataStart do
                        local b = content:byte(realEnd)
                        if b ~= 10 and b ~= 13 then
                            break
                        end
                        realEnd = realEnd - 1
                    end
                    stream_obj = { dic = {}, rawdata = content:sub(dataStart, realEnd) }
                    local dictStart = content:find("<<", 1, true)
                    if dictStart and dictStart < streamMarker then
                        -- Manual PDF dict parser for flat key-value pairs
                        local dictRaw = content:sub(dictStart + 2, streamMarker - 1)
                        local function parseDict(raw)
                            local parsed = {}
                            local pp = 1
                            while pp <= #raw do
                                while pp <= #raw do
                                    local b = raw:byte(pp)
                                    if b ~= 32 and b ~= 10 and b ~= 13 and b ~= 9 and b ~= 12 then
                                        break
                                    end
                                    pp = pp + 1
                                end
                                if pp > #raw then
                                    break
                                end
                                if raw:byte(pp) == 62 then
                                    break
                                end
                                if raw:byte(pp) == 47 then
                                    pp = pp + 1
                                    local keyStart = pp
                                    while pp <= #raw do
                                        local b = raw:byte(pp)
                                        if b == 32 or b == 10 or b == 13 or b == 9 or b == 12 or b == 47 or b == 60 or b == 62 then
                                            break
                                        end
                                        pp = pp + 1
                                    end
                                    local key = raw:sub(keyStart, pp - 1)
                                    -- PDF names are case-sensitive; keep original
                                    -- case so trailer readers (Encrypt/Root/Prev)
                                    -- can find these keys
                                    while pp <= #raw do
                                        local b = raw:byte(pp)
                                        if b ~= 32 and b ~= 10 and b ~= 13 and b ~= 9 and b ~= 12 then
                                            break
                                        end
                                        pp = pp + 1
                                    end
                                    local b = raw:byte(pp)
                                    if b >= 48 and b <= 57 or b == 45 then
                                        local valStart = pp
                                        while pp <= #raw do
                                            b = raw:byte(pp)
                                            if not (b >= 48 and b <= 57 or b == 45 or b == 46) then
                                                break
                                            end
                                            pp = pp + 1
                                        end
                                        parsed[key] = tonumber(raw:sub(valStart, pp - 1)) or raw:sub(valStart, pp - 1)
                                    elseif b == 47 then
                                        pp = pp + 1
                                        local valStart = pp
                                        while pp <= #raw do
                                            b = raw:byte(pp)
                                            if b == 32 or b == 10 or b == 13 or b == 9 or b == 12 or b == 47 or b == 60 or b == 62 then
                                                break
                                            end
                                            pp = pp + 1
                                        end
                                        parsed[key] = raw:sub(valStart, pp - 1)
                                    elseif b == 91 then
                                        local arrStart = pp + 1
                                        local depth = 1
                                        while pp <= #raw and depth > 0 do
                                            pp = pp + 1
                                            local b2 = raw:byte(pp)
                                            if b2 == 91 then
                                                depth = depth + 1
                                            elseif b2 == 93 then
                                                depth = depth - 1
                                            end
                                        end
                                        local arrStr = raw:sub(arrStart, pp - 1)
                                        pp = pp + 1
                                        local arr = {}
                                        for n in arrStr:gmatch("%S+") do
                                            local v = tonumber(n)
                                            if v then
                                                arr[#arr + 1] = v
                                            end
                                        end
                                        parsed[key] = arr
                                    else
                                        while pp <= #raw do
                                            b = raw:byte(pp)
                                            if b == 32 or b == 10 or b == 13 or b == 9 or b == 12 then
                                                break
                                            end
                                            pp = pp + 1
                                        end
                                    end
                                else
                                    pp = pp + 1
                                end
                            end
                            return parsed
                        end
                        stream_obj.dic = parseDict(dictRaw)
                    end
                end
            end
        else
            f:seek("set", start)
            local content = f:read(65536) or ""
            -- Pattern search for "stream" followed by CR/LF (PDF spec allows \r\n, \r, or \n)
            local streamMarker = content:find("stream[\r\n]")
            if streamMarker then
                local dataStart = content:find("[\r\n]", streamMarker + 6) + 1
                local length = int_value(stream_obj.Length or stream_obj["length"])
                if length and length > 0 and dataStart + length <= #content then
                    stream_obj.rawdata = content:sub(dataStart, dataStart + length - 1)
                end
            end
        end
        if type(stream_obj) == "table" and not stream_obj.ref then
            xref:load_from_obj(stream_obj, start)
        end
        xrefs[#xrefs + 1] = xref

        -- Follow Prev/XRefStm chains
        local trailer = xref.trailer
        if trailer then
            if trailer.XRefStm or trailer["XRefStm"] then
                local pos = int_value(trailer.XRefStm or trailer["XRefStm"])
                self:_read_xref_from(pos, xrefs)
            end
            if trailer.Prev or trailer["Prev"] then
                local pos = int_value(trailer.Prev or trailer["Prev"])
                self:_read_xref_from(pos, xrefs)
            end
        end
    elseif is_keyword(token, "xref") then
        -- Classic xref table
        -- We need to skip past the "xref" line and read subsections.
        -- Read raw bytes from the file to find end of "xref" line.
        f:seek("set", start)
        local header = f:read(256) or ""
        local xref_end = header:find("\n", 1, true)
        if xref_end then
            p:seek(start + xref_end) -- past the "xref\n" line
        else
            p:seek(start + 5) -- skip "xref\n"
        end
        local xref = PDFXRef:new()
        xref:load(p)
        xrefs[#xrefs + 1] = xref

        -- Follow XRefStm/Prev chains
        local trailer = xref.trailer
        if trailer then
            if trailer.XRefStm or trailer["XRefStm"] then
                local pos = int_value(trailer.XRefStm or trailer["XRefStm"])
                self:_read_xref_from(pos, xrefs)
            end
            if trailer.Prev or trailer["Prev"] then
                local pos = int_value(trailer.Prev or trailer["Prev"])
                self:_read_xref_from(pos, xrefs)
            end
        end
    else
        -- Fallback: scan whole file for objects
        logger.warn("[pdfdoc] No valid xref found, scanning file for objects")
        f:seek("set", 0)
        p = pdfparser.new(f)
        local offsets = {}
        while true do
            local pos, line = p:nextline()
            if not line then
                break
            end
            local objid_s, genno_s = line:match("^(%d+)%s+(%d+)%s+obj")
            if objid_s then
                offsets[tonumber(objid_s)] = { genno = tonumber(genno_s), offset = pos }
            end
            if line:match("^%s*trailer") then
                -- Try to parse trailer
                local ok, xref2 = pcall(function()
                    local x = PDFXRef:new()
                    x.offsets = offsets
                    x:load_trailer(p)
                    return x
                end)
                if ok then
                    xrefs[#xrefs + 1] = xref2
                end
            end
        end
        if #xrefs == 0 and next(offsets) then
            -- At least store the offsets even without trailer
            local xref2 = PDFXRef:new()
            xref2.offsets = offsets
            xrefs[#xrefs + 1] = xref2
        end
    end
end

--- Read all xref tables.
function PDFDocument:_read_xref()
    local xrefs = {}
    local ok, err = pcall(function()
        local pos = self:_find_xref()
        if pos then
            self:_read_xref_from(pos, xrefs)
        end
    end)
    if not ok then
        logger.warn("[pdfdoc] Error reading xref: ", err)
    end
    if #xrefs == 0 then
        -- Fallback scan
        self:_read_xref_from(0, xrefs)
    end
    return xrefs
end

--- Load an object by its objid from the file.
-- This is THE central method — it integrates parsing and decryption.
-- Matches ineptpdf.py PDFDocument.getobj() exactly.
--
-- For each object:
--   1. Find offset from xref
--   2. Seek parser there, parse the object
--   3. If it's a stream, set objid/genno on it
--   4. If decipher is set, call decipher_all on non-stream objects
--   5. Cache the result
function PDFDocument:getobj(objid)
    if self.objs[objid] then
        return self.objs[objid]
    end

    local offset, stmid
    for _, xref in ipairs(self.xrefs) do
        offset, _, stmid = xref:getpos(objid)
        if offset or stmid then
            break
        end
    end

    if stmid then
        self:_expandObjStm(stmid)
        return self.objs[objid]
    end

    if not offset then
        return nil -- object not found
    end

    -- Parse the object at that offset
    local p = pdfparser.new(self.file)
    p:seek(offset)

    -- Read objid genno obj tokens
    p:nexttoken()
    local _, genno_tok = p:nexttoken()
    p:nexttoken()

    -- Now parse the actual object
    local result = p:nextobject()
    if not result then
        return nil
    end

    local obj = result[2]
    local real_genno = type(genno_tok) == "number" and genno_tok or 0

    -- If it's a stream, upgrade to PDFStream and set objid/genno
    if type(obj) == "table" and obj.dic ~= nil and obj.rawdata ~= nil then
        -- Promote the raw table to a PDFStream instance so methods work
        setmetatable(obj, PDFStream)
        obj:set_objid(objid, real_genno)
        -- Attach decipher if the document has one
        if self.decipher then
            obj.decipher = self.decipher
        end
    elseif self.decipher then
        -- Non-stream object: decrypt all string values
        obj = pdfdoc.decipher_all(self.decipher, objid, real_genno, obj)
    end

    self.objs[objid] = obj
    return obj
end

--- Load an object without decryption (for reading the Encrypt dict itself).
-- The Encrypt dict must be read raw because its parameters tell us
-- HOW to decrypt everything else.
function PDFDocument:_loadRawObject(objid)
    if self.objs[objid] then
        return self.objs[objid]
    end

    local offset, stmid
    for _, xref in ipairs(self.xrefs) do
        offset, _, stmid = xref:getpos(objid)
        if offset or stmid then
            break
        end
    end
    if stmid then
        self:_expandObjStm(stmid)
        return self.objs[objid]
    end
    if not offset then
        return nil
    end

    local p = pdfparser.new(self.file)
    p:seek(offset)

    -- Skip objid genno obj tokens
    p:nexttoken() -- objid
    p:nexttoken() -- genno
    p:nexttoken() -- obj keyword

    local result = p:nextobject()
    if not result then
        return nil
    end

    local obj = result[2]
    -- If it's a stream, upgrade to PDFStream and set objid/genno
    if type(obj) == "table" and obj.dic ~= nil and obj.rawdata ~= nil then
        setmetatable(obj, PDFStream)
        obj:set_objid(objid, 0)
    end

    self.objs[objid] = obj
    return obj
end

--- Expand a compressed object stream (ObjStm) and cache its child objects.
-- Matches ineptpdf.py PDFDocument.getobj() ObjStm handling (lines 1833-1879).
function PDFDocument:_expandObjStm(stmid)
    if self._expanded_stms and self._expanded_stms[stmid] then
        return
    end

    -- Load the container stream object
    local stm = self:getobj(stmid)
    if not stm or type(stm) ~= "table" or stm.dic == nil then
        return
    end

    -- Get decrypted raw data, then decompress (FlateDecode)
    local data = stm:get_decdata()
    if not data or #data == 0 then
        return
    end

    local ok, zlib_mod = pcall(require, "adobe.util.zlib")
    if ok and zlib_mod then
        local inflater = zlib_mod.inflater()
        local parts = {}
        inflater:update(data, #data, function(ptr, len)
            parts[#parts + 1] = ffi.string(ptr, len)
        end)
        inflater:close()
        if parts[1] then
            data = table.concat(parts)
        end
    end

    -- Parse N (number of child objects) from the decompressed data
    local n = tonumber(stm.dic.N or stm.dic["n"]) or 0
    if n == 0 then
        return
    end

    -- Parse the header: N pairs of (objid, offset)
    -- Format: whitespace-separated decimal integers, followed by concatenated object content
    local pos = 1
    local function skipWhitespace()
        while pos <= #data do
            local b = data:byte(pos)
            if b ~= 32 and b ~= 10 and b ~= 13 and b ~= 9 and b ~= 12 and b ~= 0 then
                break
            end
            pos = pos + 1
        end
    end
    local function parseInteger()
        skipWhitespace()
        local start = pos
        while pos <= #data do
            local b = data:byte(pos)
            if b < 48 or b > 57 then
                break
            end
            pos = pos + 1
        end
        if start > pos - 1 then
            return nil
        end
        return tonumber(data:sub(start, pos - 1))
    end

    local pairs_list = {}
    for i = 1, n do
        local oid = parseInteger()
        local off = parseInteger()
        if not oid then
            break
        end
        pairs_list[i] = { objid = oid, offset = off }
    end

    -- The remaining data (after the header) contains the serialized objects
    -- at offsets specified in the header pairs.
    -- Build a memory-backed file for the parser by using a tempfile
    -- (Lua PDF parser requires a real file handle).
    skipWhitespace()
    local objectsBase = pos

    if #pairs_list < n then
        logger.warn("[pdfdoc] _expandObjStm: only parsed ", #pairs_list, " of ", n, " header pairs")
    end

    for idx, pair in ipairs(pairs_list) do
        if not self.objs[pair.objid] then
            local objStart = objectsBase + pair.offset
            -- Determine end: if this is the last object, it goes to EOF;
            -- otherwise it ends at the next object's start
            local objEnd
            if idx < #pairs_list then
                objEnd = objectsBase + pairs_list[idx + 1].offset
            else
                objEnd = #data + 1
            end

            if objStart < objEnd and objStart <= #data then
                local childData = data:sub(objStart, objEnd - 1)
                -- Parse through a tempfile (parser needs real file)
                local tmpname = os.tmpname and os.tmpname()
                if tmpname then
                    local tmpf = io.open(tmpname, "wb")
                    if tmpf then
                        tmpf:write(childData)
                        tmpf:close()
                        local fh = io.open(tmpname, "rb")
                        if fh then
                            local tmpp = pdfparser.new(fh)
                            local result = tmpp:nextobject()
                            if result and result[2] then
                                local child = result[2]
                                if type(child) == "table" and child.dic ~= nil and child.rawdata ~= nil then
                                    setmetatable(child, PDFStream)
                                    child:set_objid(pair.objid, 0)
                                    if self.decipher then
                                        child.decipher = self.decipher
                                    end
                                end
                                self.objs[pair.objid] = child
                            end
                            fh:close()
                        end
                        os.remove(tmpname)
                    end
                end
            end
        end
    end

    if not self._expanded_stms then
        self._expanded_stms = {}
    end
    self._expanded_stms[stmid] = true
end

--- Old name for compatibility.
function PDFDocument:loadObject(objid)
    return self:getobj(objid)
end

--- Get all objids from all xref sections.
function PDFDocument:allObjids()
    local seen = {}
    local ids = {}
    for _, xref in ipairs(self.xrefs) do
        for _, id in ipairs(xref:objids()) do
            if not seen[id] then
                seen[id] = true
                ids[#ids + 1] = id
            end
        end
    end
    table.sort(ids)
    return ids
end

--- Get the encryption filter name (e.g., "EBX_HANDLER" or "Standard").
function PDFDocument:getEncryptionFilter()
    if not self.encryption then
        return nil
    end
    local param = self.encryption.param
    local filter = param.Filter or param["filter"]
    if type(filter) == "table" and getmetatable(filter) == pdfparser.PSLiteral then
        return filter.name
    elseif type(filter) == "string" then
        return filter
    end
    return nil
end

--- Extract ADEPT_LICENSE from the encryption dict.
-- Returns: license_xml (string), ebx_bookid (string), or nil
function PDFDocument:extractAdeptLicense()
    if not self.encryption then
        return nil
    end
    local param = self.encryption.param
    local adept_license = param.ADEPT_LICENSE or param["adept_license"]
    if type(adept_license) ~= "string" or #adept_license == 0 then
        return nil
    end
    local ebx_bookid = param.EBX_BOOKID or param["ebx_bookid"]
    if type(ebx_bookid) == "string" then
        ebx_bookid = ebx_bookid
    else
        ebx_bookid = nil
    end
    return adept_license, ebx_bookid
end

------------------------------------------------------------------------
-- Decryption
------------------------------------------------------------------------

--- Decrypt a single PDF object (recursively).
-- Recursively applies the decipher function to all string values.
-- Matches ineptpdf.py decipher_all.
--
-- Critical: PSLiteral and PSKeyword are tables with a .name string field,
-- but those fields must NOT be decrypted — they are PDF names like /Type
-- which are stored unencrypted in the PDF.
function pdfdoc.decipher_all(decipher_fn, objid, genno, obj)
    if type(obj) == "string" then
        return decipher_fn(objid, genno, obj)
    end
    if type(obj) ~= "table" then
        return obj
    end
    if obj.ref then
        return obj
    end -- indirect ref, don't decrypt
    -- PSLiteral and PSKeyword: their .name field is a PDF identifier,
    -- not encrypted data. Return as-is.
    local mt = getmetatable(obj)
    if mt == pdfparser.PSLiteral or mt == pdfparser.PSKeyword then
        return obj
    end
    if obj.dic ~= nil and obj.rawdata ~= nil then
        -- PDFStream: don't recurse into stream here,
        -- stream handles its own decryption via get_decdata/get_decdic
        return obj
    end
    local result = {}
    for k, v in pairs(obj) do
        result[k] = pdfdoc.decipher_all(decipher_fn, objid, genno, v)
    end
    return result
end

--- Get the trailer with /Encrypt removed (for clean output).
function PDFDocument:getCleanTrailer()
    local trailer = {}
    local source = nil
    for _, xref in ipairs(self.xrefs) do
        if xref.trailer then
            source = xref.trailer
        end
    end
    if not source then
        return {}
    end

    for k, v in pairs(source) do
        if k ~= "Encrypt" and k ~= "Prev" and k ~= "XRefStm" then
            trailer[k] = v
        end
    end
    return trailer
end

--- Set the decipher function on the document.
-- Once set, getobj() will transparently decrypt all loaded objects.
function PDFDocument:set_decipher(decipher_fn)
    self.decipher = decipher_fn
end

return pdfdoc
