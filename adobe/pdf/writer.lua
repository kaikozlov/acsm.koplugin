--- PDF serializer / clean writer.
-- Faithful port of ineptpdf.py PDFSerializer class (lines 2141-2350).
--
-- Architecture: stream-based serialization that writes directly to the
-- output file, tracking the last byte written to determine when separator
-- spaces are needed (matching ineptpdf.py's self.last pattern exactly).

local writer = {}

local ok, pdfparser = pcall(require, "adobe.pdf.parser")
if not ok then
    pdfparser = nil
end

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Escape a string for PDF literal-string output (parenthesized).
-- Matches ineptpdf.py PDFSerializer.escape_string().
local function escapeString(s)
    local r = s:gsub("\\", "\\\\")
    r = r:gsub("\n", "\\n")
    r = r:gsub("%(", "\\(")
    r = r:gsub("%)", "\\)")
    return r
end

--- Serialize a PDF name to /Name with #XX hex escaping.
-- Matches ineptpdf.py PSLiteral.__repr__().
local function serializeName(name)
    local parts = {}
    for i = 1, #name do
        local c = name:byte(i)
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or
           (c >= 48 and c <= 57) then
            parts[#parts + 1] = string.char(c)
        else
            parts[#parts + 1] = string.format("#%02x", c)
        end
    end
    return "/" .. table.concat(parts)
end

--- Check whether a table looks like a dict (has string keys).
local function isDict(t)
    for k, _ in pairs(t) do
        if type(k) == "string" then
            return true
        end
    end
    return false
end

------------------------------------------------------------------------
-- PDFSerializer — faithful port of ineptpdf.py class
------------------------------------------------------------------------

local PDFSerializer = {}
PDFSerializer.__index = PDFSerializer

function PDFSerializer.new(out)
    local self = setmetatable({}, PDFSerializer)
    self.out = out
    self.last = ""  -- 1-char string tracking last byte written
    return self
end

--- Write data and track last byte.
-- Matches ineptpdf.py: self.outf.write(data); self.last = data[-1:]
function PDFSerializer:write(data)
    if data and #data > 0 then
        self.out:write(data)
        self.last = data:sub(-1)
    end
end

--- Get current file position.
function PDFSerializer:tell()
    return self.out:seek()
end

--- Escape a string for PDF literal output.
-- Escapes all characters required by PDF spec §7.3.4.2:
-- backslash, parens, and the named escapes (\n, \r, \t, \b, \f).
-- Also escapes other control chars (< 32) as octal.
-- More thorough than ineptpdf.py but fully spec-compliant.
function PDFSerializer:escape_string(s)
    local parts = {}
    for i = 1, #s do
        local c = s:byte(i)
        if c == 92 then       -- backslash
            parts[#parts + 1] = "\\\\"
        elseif c == 40 then   -- (
            parts[#parts + 1] = "\\("
        elseif c == 41 then   -- )
            parts[#parts + 1] = "\\)"
        elseif c == 10 then   -- LF
            parts[#parts + 1] = "\\n"
        elseif c == 13 then   -- CR
            parts[#parts + 1] = "\\r"
        elseif c == 9 then    -- HT
            parts[#parts + 1] = "\\t"
        elseif c == 8 then    -- BS
            parts[#parts + 1] = "\\b"
        elseif c == 12 then   -- FF
            parts[#parts + 1] = "\\f"
        elseif c < 32 then    -- other control
            parts[#parts + 1] = string.format("\\%03o", c)
        else
            parts[#parts + 1] = string.char(c)
        end
    end
    return table.concat(parts)
end

--- Check if last byte is alphanumeric.
-- Matches Python's self.last.isalnum().
local function lastIsAlnum(self)
    local b = self.last
    if not b or #b == 0 then return false end
    local c = b:byte(1)
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
end

--- Check if first byte of a string is alphanumeric.
local function firstIsAlnum(s)
    if not s or #s == 0 then return false end
    local c = s:byte(1)
    return (c >= 48 and c <= 57) or (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
end

--- Format a number as a string.
local function formatNumber(obj)
    if obj == math.floor(obj) and math.abs(obj) < 2 ^ 53 then
        return tostring(math.floor(obj))
    end
    local s = string.format("%.14g", obj)
    if s:find("e") or s:find("E") then
        s = string.format("%.14f", obj)
    end
    if s:find("%.") then
        s = s:gsub("0+$", "")
        s = s:gsub("%.$", "")
    end
    return s
end

--- Classify a Lua table into a type for serialization.
-- Returns one of: "ref", "stream", "legacy_stream", "literal", "keyword",
-- "dict", "array", or nil (unknown).
local function classifyTable(obj)
    if obj.ref then return "ref" end
    if obj.dic ~= nil and obj.rawdata ~= nil then return "stream" end
    if obj.stream_data ~= nil then return "legacy_stream" end
    if pdfparser and getmetatable(obj) == pdfparser.PSLiteral then return "literal" end
    if pdfparser and getmetatable(obj) == pdfparser.PSKeyword then return "keyword" end
    -- Fallback name: plain table with ONLY a 'name' field
    if type(obj.name) == "string" then
        local n = 0
        for _ in pairs(obj) do n = n + 1 end
        if n == 1 then return "literal" end
    end
    -- Fallback keyword: plain table with ONLY a 'keyword' field
    if type(obj.keyword) == "string" then
        local n = 0
        for _ in pairs(obj) do n = n + 1 end
        if n == 1 then return "keyword" end
    end
    -- Dict or array
    if isDict(obj) then return "dict" end
    return "array"
end

--- Serialize a single PDF object.
-- Faithful port of ineptpdf.py PDFSerializer.serialize_object().
function PDFSerializer:serialize_object(obj)
    local t = type(obj)

    if t == "table" then
        local kind = classifyTable(obj)

        if kind == "ref" then
            -- PDFObjRef: "5 0 R"
            if lastIsAlnum(self) then
                self:write(" ")
            end
            self:write(string.format("%d %d R", obj.ref.objid, obj.ref.genno))

        elseif kind == "stream" then
            -- PDFStream
            local data = obj.get_decdata and obj:get_decdata() or obj.rawdata
            local dic = obj.get_decdic and obj:get_decdic() or obj.dic
            if type(dic) == "table" then
                dic.Length = #data
            end
            self:serialize_object(dic)
            self:write("stream\n")
            self:write(data)
            self:write("\nendstream")

        elseif kind == "legacy_stream" then
            local data = obj.stream_data
            local dict = obj.dict or {}
            dict.Length = #data
            self:serialize_object(dict)
            self:write("stream\n")
            self:write(data)
            self:write("\nendstream")

        elseif kind == "literal" then
            -- PSLiteral: write as /Name
            local name = obj.name
            self:write(serializeName(name))

        elseif kind == "keyword" then
            -- PSKeyword: write raw
            self:write(obj.keyword or obj.name)

        elseif kind == "dict" then
            -- dict: << /Key val /Key val >>
            -- Correct malformed Mac OS resource forks for Stanza
            if obj.ResFork ~= nil and obj.Type ~= nil
                    and obj.Subtype == nil and type(obj.Type) == "number" then
                obj.Subtype = obj.Type
                obj.Type = nil
            end
            self:write("<<")
            for key, val in pairs(obj) do
                if type(key) == "string" then
                    self:write(serializeName(key))
                    self:serialize_object(val)
                end
            end
            self:write(">>")

        elseif kind == "array" then
            -- list: [ elem elem ... ]
            self:write("[")
            for i = 1, #obj do
                self:serialize_object(obj[i])
            end
            self:write("]")
        end

    elseif t == "number" then
        -- int or Decimal
        local s = formatNumber(obj)
        if lastIsAlnum(self) then
            self:write(" ")
        end
        self:write(s)

    elseif t == "boolean" then
        local s = obj and "true" or "false"
        if lastIsAlnum(self) then
            self:write(" ")
        end
        self:write(s)

    elseif t == "string" then
        -- bytearray: write as (escaped)
        -- All Lua strings from our decrypted objects are treated as
        -- bytearray (decrypted PDF string values).
        self:write("(")
        self:write(self:escape_string(obj))
        self:write(")")

    else
        -- Fallback: str(obj)
        local s = tostring(obj)
        if firstIsAlnum(s) and lastIsAlnum(self) then
            self:write(" ")
        end
        self:write(s)
    end
end

--- Serialize an indirect object.
-- Matches ineptpdf.py serialize_indirect() exactly.
function PDFSerializer:serialize_indirect(objid, obj)
    self:write(string.format("%d 0 obj", objid))
    self:serialize_object(obj)
    if lastIsAlnum(self) then
        self:write("\n")
    end
    self:write("endobj\n")
end

------------------------------------------------------------------------
-- Public API
------------------------------------------------------------------------

--- Serialize a PDF object to a string (convenience for tests).
function writer.serializeObject(obj)
    local buf = {}
    local ser = PDFSerializer.new({
        write = function(_, data) buf[#buf + 1] = data end,
        seek = function() return 0 end,
    })
    ser:serialize_object(obj)
    return table.concat(buf)
end

--- Write a clean unencrypted PDF.
-- Matches ineptpdf.py PDFSerializer.dump() (non-xref-stm path).
function writer.writeCleanPdf(inPath, outPath, doc, encrypt_objid)
    local out, err = io.open(outPath, "wb")
    if not out then
        error("Cannot open output file: " .. outPath .. ": " .. tostring(err))
    end

    local ser = PDFSerializer.new(out)

    -- Write header
    ser:write(doc.version)
    ser:write("\n%\xe2\xe3\xcf\xd3\n")

    -- Collect object IDs, excluding Encrypt dict
    local objids = {}
    local maxobj = 0
    for objid, _ in pairs(doc.objects) do
        if objid ~= encrypt_objid then
            objids[#objids + 1] = objid
            if objid > maxobj then maxobj = objid end
        end
    end
    table.sort(objids)

    local size = maxobj + 1

    -- Write each object, recording byte offsets for xref
    local xrefs = {}

    if doc.xref_entries then
        for k, _ in pairs(doc.xref_entries) do
            doc.xref_entries[k] = nil
        end
    end

    for _, objid in ipairs(objids) do
        local obj = doc.objects[objid]
        xrefs[objid] = ser:tell()

        if doc.xref_entries then
            doc.xref_entries[objid] = { offset = xrefs[objid], genno = 0 }
        end

        ser:serialize_indirect(objid, obj)
    end

    -- Cross-reference table
    local startxref = ser:tell()
    out:write("xref\n")
    out:write(string.format("0 %d\n", size))
    out:write("0000000000 65535 f \n")
    for objid = 1, maxobj do
        if xrefs[objid] then
            out:write(string.format("%010d 00000 n \n", xrefs[objid]))
        else
            out:write("0000000000 65535 f \n")
        end
    end

    -- Trailer
    local trailer = {}
    for k, v in pairs(doc.trailer) do
        if k ~= "Encrypt" then
            trailer[k] = v
        end
    end
    trailer.Size = size

    out:write("trailer\n")
    ser:serialize_object(trailer)
    out:write(string.format("\nstartxref\n%d\n%%%%EOF\n", startxref))

    out:close()
end

return writer
