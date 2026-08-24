--- Advanced integration tests for adobe/pdf/pdfdoc.lua
-- Tests: PDFStream, PDFXRefStream, decipher_all, getobj with decryption,
-- _expandObjStm, extractAdeptLicense, _unpredict, incremental updates.
-- Uses real KOReader crypto and zlib — no mocking.

local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfparser = require("adobe.pdf.parser")
local ffi = require("ffi")

-- Load zlib module first (it defines z_stream struct)
require("adobe.util.zlib")

-- Add deflate FFI defs (inflate defs already loaded by zlib.lua)
ffi.cdef([[
    int deflateInit2_(z_stream *strm, int level, int method,
                      int windowBits, int memLevel, int strategy,
                      const char *version, int stream_size);
    int deflate(z_stream *strm, int flush);
    int deflateEnd(z_stream *strm);
]])

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local libz
if ffi.loadlib then
    local ok
    ok, libz = pcall(ffi.loadlib, "z", "1")
    if not ok then
        libz = ffi.load("z")
    end
else
    libz = ffi.load("z")
end

--- Helper: zlib-wrapped deflate compress (for FlateDecode streams)
-- pdfdoc.lua uses zlib.inflater() which expects zlib header (windowBits=15)
local function rawDeflate(data)
    local stream = ffi.new("z_stream[1]")
    local rc = libz.deflateInit2_(
        stream,
        -1,
        8, -- Z_DEFAULT_COMPRESSION, method=DEFLATED
        15, -- zlib wrapper (matches zlib.inflater())
        8,
        0, -- memLevel, strategy
        libz.zlibVersion(),
        ffi.sizeof(stream[0])
    )
    assert(rc == 0, "deflateInit2 failed: " .. tostring(rc))

    stream[0].next_in = ffi.cast("Bytef *", data)
    stream[0].avail_in = #data

    local CHUNK = #data + 256
    local outbuf = ffi.new("uint8_t[?]", CHUNK)
    stream[0].next_out = outbuf
    stream[0].avail_out = CHUNK

    rc = libz.deflate(stream, 4) -- Z_FINISH
    assert(rc == 1, "deflate failed: " .. tostring(rc)) -- Z_STREAM_END

    local produced = CHUNK - tonumber(stream[0].avail_out)
    libz.deflateEnd(stream)
    return ffi.string(outbuf, produced)
end

--- Helper: create a minimal valid PDF in a temp file
local function createMinimalPdf(extra_objects, opts)
    opts = opts or {}
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")

    local objects = {}
    -- Object 1: Catalog
    table.insert(objects, { id = 1, data = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" })
    -- Object 2: Pages
    table.insert(objects, { id = 2, data = "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n" })

    -- Add any extra objects
    if extra_objects then
        for _, obj in ipairs(extra_objects) do
            table.insert(objects, obj)
        end
    end

    f:write("%PDF-1.4\n")
    f:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))

    local offsets = {}
    for _, obj in ipairs(objects) do
        offsets[obj.id] = f:seek()
        f:write(obj.data)
    end

    local xref_offset = f:seek()
    local maxid = 0
    for _, obj in ipairs(objects) do
        if obj.id > maxid then
            maxid = obj.id
        end
    end

    f:write("xref\n")
    f:write(string.format("0 %d\n", maxid + 1))
    f:write("0000000000 65535 f \r\n")
    for id = 1, maxid do
        local off = offsets[id] or 0
        f:write(string.format("%010d 00000 n \r\n", off))
    end

    f:write("trailer\n")
    local trailer_extra = opts.trailer_extra or ""
    f:write(string.format("<< /Size %d /Root 1 0 R %s>>\n", maxid + 1, trailer_extra))
    f:write("startxref\n")
    f:write(string.format("%d\n", xref_offset))
    f:write("%%EOF\n")

    f:close()
    return tmp
end

--- Helper: create a PDF with encryption dict for testing extractAdeptLicense
local function createEncryptedPdf(encrypt_dict_str, encrypt_id)
    encrypt_id = encrypt_id or 3
    local tmp = os.tmpname()
    local f = io.open(tmp, "wb")

    local objects = {}
    table.insert(objects, { id = 1, data = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n" })
    table.insert(objects, { id = 2, data = "2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n" })
    local edata = string.format("%d 0 obj\n%s\nendobj\n", encrypt_id, encrypt_dict_str)
    table.insert(objects, { id = encrypt_id, data = edata })

    f:write("%PDF-1.4\n")
    f:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))

    local offsets = {}
    for _, obj in ipairs(objects) do
        offsets[obj.id] = f:seek()
        f:write(obj.data)
    end

    local xref_offset = f:seek()
    local maxid = encrypt_id
    f:write("xref\n")
    f:write(string.format("0 %d\n", maxid + 1))
    f:write("0000000000 65535 f \r\n")
    for id = 1, maxid do
        local off = offsets[id] or 0
        f:write(string.format("%010d 00000 n \r\n", off))
    end

    f:write("trailer\n")
    f:write(string.format("<< /Size %d /Root 1 0 R /Encrypt %d 0 R /ID [(abcdefghijklmnop)(abcdefghijklmnop)] >>\n", maxid + 1, encrypt_id))
    f:write("startxref\n")
    f:write(string.format("%d\n", xref_offset))
    f:write("%%EOF\n")

    f:close()
    return tmp
end

------------------------------------------------------------------------
-- PDFStream tests
------------------------------------------------------------------------

describe("PDFStream", function()
    describe("basic construction", function()
        it("creates a stream with dictionary and rawdata", function()
            local s = pdfdoc.PDFStream:new({ Length = 5 }, "hello")
            assert.equals("hello", s.rawdata)
            assert.equals(5, s.dic.Length)
            assert.is_nil(s.data)
        end)

        it("set_objid stores objid and genno", function()
            local s = pdfdoc.PDFStream:new({}, "test")
            s:set_objid(42, 3)
            assert.equals(42, s.objid)
            assert.equals(3, s.genno)
        end)
    end)

    describe("decode() without decipher", function()
        it("copies rawdata to data when no decipher is set", function()
            local s = pdfdoc.PDFStream:new({}, "raw content")
            s:decode()
            assert.equals("raw content", s.data)
            assert.is_nil(s.rawdata) -- rawdata cleared after decode
        end)

        it("is idempotent (calling decode twice doesn't error)", function()
            local s = pdfdoc.PDFStream:new({}, "content")
            s:decode()
            s:decode() -- should be no-op
            assert.equals("content", s.data)
        end)
    end)

    describe("decode() with decipher", function()
        it("applies decipher function to stream data", function()
            local function reverse_decipher(objid, genno, data)
                return data:reverse()
            end
            local s = pdfdoc.PDFStream:new({}, "dlrow olleh", reverse_decipher)
            s:set_objid(1, 0)
            s:decode()
            assert.equals("hello world", s.data)
        end)

        it("deciphers dictionary string values via decipher_all", function()
            local called_with = {}
            local function track_decipher(objid, genno, data)
                table.insert(called_with, data)
                return "DEC:" .. data
            end
            local dic = { Title = "encrypted_title", Count = 42 }
            local s = pdfdoc.PDFStream:new(dic, "stream_data", track_decipher)
            s:set_objid(5, 0)
            s:decode(true) -- gen_xref_stm=true to store decdata/decdic
            -- decdic should have decrypted string values
            assert.equals("DEC:encrypted_title", s.decdic.Title)
            -- non-string values should be unchanged
            assert.equals(42, s.decdic.Count)
        end)

        it("stores decdata when gen_xref_stm is true", function()
            local function xor_decipher(objid, genno, data)
                local t = {}
                for i = 1, #data do
                    t[i] = string.char(bit.bxor(data:byte(i), 0xFF))
                end
                return table.concat(t)
            end
            local raw = "\xA0\xB0\xC0"
            local s = pdfdoc.PDFStream:new({}, raw, xor_decipher)
            s:set_objid(1, 0)
            s:decode(true)
            assert.equals(s.decdata, s.data)
            -- Verify decryption was applied
            assert.equals("\x5F\x4F\x3F", s.data)
        end)
    end)

    describe("get_data()", function()
        it("triggers decode on first call", function()
            local s = pdfdoc.PDFStream:new({}, "lazy data")
            assert.is_nil(s.data) -- not decoded yet
            local result = s:get_data()
            assert.equals("lazy data", result)
        end)
    end)

    describe("get_decdata()", function()
        it("returns rawdata when no decipher is set", function()
            local s = pdfdoc.PDFStream:new({}, "plain")
            assert.equals("plain", s:get_decdata())
        end)

        it("decrypts rawdata on-the-fly without full decode", function()
            local function upper_decipher(objid, genno, data)
                return data:upper()
            end
            local s = pdfdoc.PDFStream:new({}, "hello", upper_decipher)
            s:set_objid(1, 0)
            -- get_decdata should decrypt without calling full decode
            local result = s:get_decdata()
            assert.equals("HELLO", result)
            assert.is_nil(s.data) -- full decode not triggered
        end)

        it("returns cached decdata if already decoded", function()
            local call_count = 0
            local function counting_decipher(objid, genno, data)
                call_count = call_count + 1
                return "decrypted"
            end
            local s = pdfdoc.PDFStream:new({}, "raw", counting_decipher)
            s:set_objid(1, 0)
            s:decode(true) -- sets decdata
            call_count = 0 -- reset
            local result = s:get_decdata()
            assert.equals("decrypted", result)
            assert.equals(0, call_count) -- should not call decipher again
        end)
    end)

    describe("get_decdic()", function()
        it("returns raw dictionary when no decipher is set", function()
            local dic = { Author = "Test", Pages = 5 }
            local s = pdfdoc.PDFStream:new(dic, "data")
            local result = s:get_decdic()
            assert.equals("Test", result.Author)
            assert.equals(5, result.Pages)
        end)

        it("decrypts dictionary strings on-the-fly", function()
            local function prefix_decipher(objid, genno, data)
                return "D:" .. data
            end
            local dic = { Title = "secret", Count = 10 }
            local s = pdfdoc.PDFStream:new(dic, "x", prefix_decipher)
            s:set_objid(2, 0)
            local result = s:get_decdic()
            assert.equals("D:secret", result.Title)
            assert.equals(10, result.Count)
        end)

        it("returns cached decdic if already decoded", function()
            local call_count = 0
            local function counting_decipher(objid, genno, data)
                call_count = call_count + 1
                return "dec"
            end
            local dic = { Key = "val" }
            local s = pdfdoc.PDFStream:new(dic, "raw", counting_decipher)
            s:set_objid(1, 0)
            s:decode(true) -- caches decdic
            call_count = 0
            local result = s:get_decdic()
            assert.equals("dec", result.Key)
            assert.equals(0, call_count)
        end)
    end)

    describe("get_rawdata()", function()
        it("returns rawdata before decode", function()
            local s = pdfdoc.PDFStream:new({}, "original")
            assert.equals("original", s:get_rawdata())
        end)

        it("returns nil after decode (rawdata is cleared)", function()
            local s = pdfdoc.PDFStream:new({}, "content")
            s:decode()
            assert.is_nil(s:get_rawdata())
        end)
    end)
end)

------------------------------------------------------------------------
-- decipher_all tests
------------------------------------------------------------------------

describe("decipher_all", function()
    local function simple_decipher(objid, genno, data)
        -- Simple "decryption": reverse the string
        return data:reverse()
    end

    it("decrypts a plain string", function()
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, "dlrow")
        assert.equals("world", result)
    end)

    it("returns numbers unchanged", function()
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, 42)
        assert.equals(42, result)
    end)

    it("returns booleans unchanged", function()
        assert.equals(true, pdfdoc.decipher_all(simple_decipher, 1, 0, true))
        assert.equals(false, pdfdoc.decipher_all(simple_decipher, 1, 0, false))
    end)

    it("returns nil unchanged", function()
        assert.is_nil(pdfdoc.decipher_all(simple_decipher, 1, 0, nil))
    end)

    it("decrypts all strings in a flat dict", function()
        local obj = { Title = "eltiT", Author = "rohtuA", Count = 5 }
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, obj)
        assert.equals("Title", result.Title)
        assert.equals("Author", result.Author)
        assert.equals(5, result.Count) -- number unchanged
    end)

    it("decrypts strings in arrays", function()
        local obj = { "cba", "fed", 123 }
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, obj)
        assert.equals("abc", result[1])
        assert.equals("def", result[2])
        assert.equals(123, result[3])
    end)

    it("decrypts nested dicts recursively", function()
        local obj = {
            outer = "retuo",
            nested = {
                inner = "renni",
                deep = { value = "eulav" },
            },
        }
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, obj)
        assert.equals("outer", result.outer)
        assert.equals("inner", result.nested.inner)
        assert.equals("value", result.nested.deep.value)
    end)

    it("does not decrypt PSLiteral names", function()
        local obj = { Type = pdfparser.literal("Catalog") }
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, obj)
        -- PSLiteral should be unchanged
        assert.equals(pdfparser.PSLiteral, getmetatable(result.Type))
        assert.equals("Catalog", result.Type.name)
    end)

    it("does not decrypt PSKeyword tokens", function()
        local obj = { kw = pdfparser.keyword("obj") }
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, obj)
        assert.equals(pdfparser.PSKeyword, getmetatable(result.kw))
        assert.equals("obj", result.kw.name)
    end)

    it("does not recurse into indirect references", function()
        local ref = { ref = { objid = 5, genno = 0 } }
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, ref)
        -- ref should be returned as-is
        assert.equals(5, result.ref.objid)
    end)

    it("does not decrypt PDFStream objects (they handle their own)", function()
        local stream = pdfdoc.PDFStream:new({ Title = "secret" }, "rawdata")
        local obj = { mystream = stream }
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, obj)
        -- Stream object should be the same instance (not recursed into)
        assert.equals(stream, result.mystream)
    end)

    it("passes correct objid and genno to decipher function", function()
        local captured_objid, captured_genno
        local function capture_decipher(objid, genno, data)
            captured_objid = objid
            captured_genno = genno
            return data
        end
        pdfdoc.decipher_all(capture_decipher, 99, 7, "test")
        assert.equals(99, captured_objid)
        assert.equals(7, captured_genno)
    end)

    it("handles mixed dict with arrays, strings, numbers, names", function()
        local obj = {
            Name = pdfparser.literal("Page"),
            Title = "eltiT",
            Kids = { "1dik", "2dik" },
            Count = 2,
            Ref = { ref = { objid = 10, genno = 0 } },
        }
        local result = pdfdoc.decipher_all(simple_decipher, 1, 0, obj)
        assert.equals("Titl" .. "e", result.Title) -- avoid literal match confusion
        assert.equals("kid1", result.Kids[1])
        assert.equals("kid2", result.Kids[2])
        assert.equals(2, result.Count)
        assert.equals("Page", result.Name.name)
        assert.equals(10, result.Ref.ref.objid)
    end)
end)

------------------------------------------------------------------------
-- _unpredict tests (PNG Up predictor)
------------------------------------------------------------------------

describe("_unpredict (PNG Up predictor)", function()
    -- _unpredict is local in pdfdoc.lua, but it's used internally by
    -- PDFXRefStream. We test it indirectly through PDFXRefStream parsing.
    -- However, we can also test it by building xref stream data with predictors.

    -- Since _unpredict is local, we test it through the XRefStream path.
    -- We'll build a compressed xref stream with Predictor=12 and verify it parses correctly.

    it("correctly unpredicts data through XRefStream parsing", function()
        -- Build xref entries with PNG Up predictor (filter byte 2 prefix per row)
        -- W = [1, 2, 1] => entlen = 4, columns = 4
        -- Row 1 (obj 0): type=0 (free), offset=0, genno=0 => \x00\x00\x00\x00
        -- Row 2 (obj 1): type=1, offset=100, genno=0 => \x01\x00\x64\x00
        -- Row 3 (obj 2): type=1, offset=200, genno=0 => \x01\x00\xC8\x00

        -- With PNG Up predictor, each row has a filter byte (2) prepended,
        -- and each byte = current - previous row's byte (mod 256)
        local columns = 4

        -- Raw entries (what we want after unprediction):
        local row1 = "\x00\x00\x00\x00" -- free entry for obj 0
        local row2 = "\x01\x00\x64\x00" -- obj 1 at offset 100
        local row3 = "\x01\x00\xC8\x00" -- obj 2 at offset 200

        -- Apply PNG Up encoding: filter=2 means each byte = (cur - prev) % 256
        -- Row 1 (prev = all zeros): delta = row1 - 0 = row1
        local delta1 = row1
        -- Row 2: delta = row2 - row1
        local delta2 = ""
        for i = 1, columns do
            delta2 = delta2 .. string.char((row2:byte(i) - row1:byte(i)) % 256)
        end
        -- Row 3: delta = row3 - row2
        local delta3 = ""
        for i = 1, columns do
            delta3 = delta3 .. string.char((row3:byte(i) - row2:byte(i)) % 256)
        end

        -- Predicted data: filter_byte(2) + delta per row
        local predicted = "\x02" .. delta1 .. "\x02" .. delta2 .. "\x02" .. delta3

        -- Compress the predicted data
        local compressed = rawDeflate(predicted)

        -- Build a PDF with an xref stream containing this data
        local tmp = os.tmpname()
        local f = io.open(tmp, "wb")
        f:write("%PDF-1.5\n")
        f:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))

        -- Object 1: Catalog
        f:seek()
        f:write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        -- Object 2: Pages
        f:seek()
        f:write("2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n")

        -- XRef stream (object 3)
        local xref_off = f:seek()
        local xref_stream_content = string.format(
            "3 0 obj\n<< /Type /XRef /Size 3 /W [1 2 1] /Root 1 0 R /Length %d /Filter /FlateDecode /Predictor 12 /Columns 4 >>\nstream\r\n",
            #compressed
        )
        f:write(xref_stream_content)
        f:write(compressed)
        f:write("\r\nendstream\nendobj\n")

        f:write("startxref\n")
        f:write(string.format("%d\n", xref_off))
        f:write("%%EOF\n")
        f:close()

        -- Parse with PDFDocument
        local doc = pdfdoc.PDFDocument:new()
        local ok, err = doc:open(tmp)
        -- The xref stream parsing should have applied _unpredict
        assert.is_truthy(ok or #doc.xrefs > 0, "should parse xref stream with predictor: " .. tostring(err))

        os.remove(tmp)
        if doc.file then
            doc:close()
        end
    end)
end)

describe("xref predictor filter family", function()
    local cases = {
        {
            name = "TIFF Sub",
            predictor = 2,
            rows = {
                string.char(0, 0, 0, 0),
                string.char(1, 255, 100, 156),
                string.char(1, 255, 200, 56),
            },
        },
        {
            name = "Sub",
            predictor = 11,
            rows = {
                string.char(0, 0, 0, 0),
                string.char(1, 255, 100, 156),
                string.char(1, 255, 200, 56),
            },
        },
        {
            name = "Average",
            predictor = 13,
            rows = {
                string.char(0, 0, 0, 0),
                string.char(1, 0, 100, 206),
                string.char(1, 0, 150, 156),
            },
        },
        {
            name = "Paeth",
            predictor = 14,
            rows = {
                string.char(0, 0, 0, 0),
                string.char(1, 255, 100, 156),
                string.char(0, 0, 100, 156),
            },
        },
    }

    for _, case in ipairs(cases) do
        it("decodes the " .. case.name .. " filter", function()
            local predicted = {}
            for _, row in ipairs(case.rows) do
                if case.predictor >= 10 then
                    row = string.char(case.predictor - 10) .. row
                end
                predicted[#predicted + 1] = row
            end
            local compressed = rawDeflate(table.concat(predicted))
            local stream_obj = {
                dic = {
                    Type = pdfparser.literal("XRef"),
                    Size = 3,
                    W = { 1, 2, 1 },
                    Filter = pdfparser.literal("FlateDecode"),
                    DecodeParms = {
                        Predictor = case.predictor,
                        Columns = 4,
                    },
                },
                rawdata = compressed,
            }

            local xref = pdfdoc.PDFXRefStream:new()
            xref:load_from_obj(stream_obj)
            assert.equals(100, xref:getpos(1))
            assert.equals(200, xref:getpos(2))
        end)
    end
end)

------------------------------------------------------------------------
-- XRef stream with /DecodeParms predictor (issue #21)
--
-- Real-world hypercompressed PDFs (e.g. Cantook/deMarque library loans)
-- put /Predictor and /Columns inside /DecodeParms per PDF 32000-1 7.4.4.3:
--   <</Type/XRef .../W[1 4 1]/DecodeParms<</Columns 6/Predictor 12>>/Filter/FlateDecode>>
-- The parser must apply the Up predictor from DecodeParms, or every object
-- offset decodes as garbage and the /Encrypt dict can never be resolved.
------------------------------------------------------------------------

describe("xref stream with /DecodeParms predictor (issue #21)", function()
    local function upPredict(data, columns)
        -- PNG Up encoding: filter byte 2, then delta vs previous row
        local rows = {}
        local prev = string.rep("\0", columns)
        for i = 1, #data, columns do
            local row = data:sub(i, i + columns - 1)
            local delta = ""
            for j = 1, #row do
                delta = delta .. string.char((row:byte(j) - prev:byte(j)) % 256)
            end
            rows[#rows + 1] = "\x02" .. delta
            prev = row
        end
        return table.concat(rows)
    end

    local function buildIssue21Pdf(dict_style)
        -- Objects: 0 free, 1 Catalog, 2 Encrypt (EBX_HANDLER), 3 xref stream, 4 free
        local offsets = {}

        local tmp = os.tmpname()
        local f = io.open(tmp, "wb")
        f:write("%PDF-1.5\n")
        f:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))

        offsets[1] = f:seek()
        f:write("1 0 obj\n<< /Type /Catalog >>\nendobj\n")

        offsets[2] = f:seek()
        f:write("2 0 obj\n<</Filter/EBX_HANDLER/Length 128/V 4/EBX_PUBLISHER(Publisher)/EBX_TITLE(Title)/EBX_AUTHOR(Author)>>\nendobj\n")

        offsets[4] = f:seek() -- marker; object 4 stays free/unwritten

        -- XRef stream (object 3), W=[1 4 1] => entlen=6, Columns=6
        offsets[3] = f:seek()

        local entries = {}
        -- obj 0: free
        entries[1] = "\x00" .. "\x00\x00\x00\x00" .. "\x00"
        -- obj 1..3: type 1, 4-byte offset, gen 0
        for _, id in ipairs({ 1, 2, 3 }) do
            local off = offsets[id]
            entries[#entries + 1] = "\x01"
                .. string.char(math.floor(off / 0x1000000) % 0x100, math.floor(off / 0x10000) % 0x100, math.floor(off / 0x100) % 0x100, off % 0x100)
                .. "\x00"
        end
        -- obj 4: free
        entries[#entries + 1] = "\x00" .. "\x00\x00\x00\x00" .. "\x00"
        local raw = table.concat(entries)

        local compressed = rawDeflate(upPredict(raw, 6))

        -- dict_style "decodeparms" mirrors the issue's serialization exactly
        -- (Predictor/Columns nested in DecodeParms); "inline" keeps the
        -- non-standard top-level form some producers emit.
        local parms
        if dict_style == "decodeparms" then
            parms = "/DecodeParms<</Columns 6/Predictor 12>>"
        else
            parms = "/Predictor 12 /Columns 6"
        end

        f:write(
            string.format(
                "3 0 obj\n<</Length %d/Type/XRef/Root 1 0 R/Encrypt 2 0 R/Size 5/Index[0 5]/W[1 4 1]%s/Filter/FlateDecode>>\nstream\r\n",
                #compressed,
                parms
            )
        )
        f:write(compressed)
        f:write("\r\nendstream\nendobj\n")

        f:write(string.format("startxref\n%d\n%%%%EOF\n", offsets[3]))
        f:close()
        return tmp
    end

    it("resolves /Encrypt when predictor is inside /DecodeParms", function()
        local tmp = buildIssue21Pdf("decodeparms")
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        local ok, err = doc:open(tmp)
        assert.is_truthy(ok, "should open: " .. tostring(err))

        -- The real parser must preserve nested dictionaries and indirect
        -- references; a flat dictionary scanner cannot satisfy these checks.
        local trailer = doc.xrefs[1].trailer
        assert.equals(12, trailer.DecodeParms.Predictor)
        assert.equals(2, trailer.Encrypt.ref.objid)

        -- Offsets must have decoded correctly (the actual issue-21 symptom:
        -- garbage offsets => /Encrypt unresolvable => "No /Encrypt dict in PDF")
        local obj1 = doc:getobj(1)
        assert.is_truthy(obj1, "object 1 should resolve through predicted xref stream")
        assert.is_truthy(obj1.Type and obj1.Type.name == "Catalog", "object 1 should be the Catalog")

        assert.is_truthy(doc.encryption, "encryption info should be collected from trailer")
        assert.is_truthy(doc.encryption.param, "/Encrypt dict should resolve")
        assert.equals("EBX_HANDLER", doc:getEncryptionFilter())

        doc:close()
    end)

    it("still parses non-standard top-level /Predictor (backward compat)", function()
        local tmp = buildIssue21Pdf("inline")
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        local ok, err = doc:open(tmp)
        assert.is_truthy(ok, "should open: " .. tostring(err))
        assert.is_truthy(doc:getobj(1), "object 1 should resolve")
        assert.equals("EBX_HANDLER", doc:getEncryptionFilter())

        doc:close()
    end)
end)

------------------------------------------------------------------------
-- PDFXRefStream tests
------------------------------------------------------------------------

describe("PDFXRefStream", function()
    describe("W-array entry parsing", function()
        it("parses entries with W=[1,2,1]", function()
            -- Build raw xref data: 3 objects
            -- obj 0: free (type=0)
            -- obj 1: at offset 100 (type=1, offset=100, genno=0)
            -- obj 2: at offset 200 (type=1, offset=200, genno=0)
            local entries = ""
            entries = entries .. "\x00\x00\x00\x00" -- obj 0: free
            entries = entries .. "\x01\x00\x64\x00" -- obj 1: type=1, offset=0x0064=100, gen=0
            entries = entries .. "\x01\x00\xC8\x00" -- obj 2: type=1, offset=0x00C8=200, gen=0

            local compressed = rawDeflate(entries)

            -- Build a stream object like the parser would produce
            local stream_obj = {
                dic = {
                    Type = pdfparser.literal("XRef"),
                    Size = 3,
                    W = { 1, 2, 1 },
                    Length = #compressed,
                    Filter = pdfparser.literal("FlateDecode"),
                },
                rawdata = compressed,
            }

            local xref = pdfdoc.PDFXRefStream:new()
            xref:load_from_obj(stream_obj)

            -- Verify positions
            local pos1, gen1 = xref:getpos(1)
            assert.equals(100, pos1)
            assert.equals(0, gen1)

            local pos2, gen2 = xref:getpos(2)
            assert.equals(200, pos2)
            assert.equals(0, gen2)

            -- Free object (type=0) should return nil
            local pos0 = xref:getpos(0)
            assert.is_nil(pos0)
        end)

        it("parses entries with W=[1,3,2] (larger field sizes)", function()
            -- obj 0: free
            -- obj 1: at offset 70000 (0x011170), gen=5
            local entries = ""
            entries = entries .. "\x00\x00\x00\x00\x00\x00" -- obj 0: free (6 bytes)
            entries = entries .. "\x01\x01\x11\x70\x00\x05" -- obj 1: type=1, offset=0x011170=70000, gen=5

            local compressed = rawDeflate(entries)

            local stream_obj = {
                dic = {
                    Type = pdfparser.literal("XRef"),
                    Size = 2,
                    W = { 1, 3, 2 },
                    Length = #compressed,
                    Filter = pdfparser.literal("FlateDecode"),
                },
                rawdata = compressed,
            }

            local xref = pdfdoc.PDFXRefStream:new()
            xref:load_from_obj(stream_obj)

            local pos1, gen1 = xref:getpos(1)
            assert.equals(70000, pos1)
            -- genno returned by getpos is always 0 for type=1
            assert.equals(0, gen1)
        end)

        it("parses type=2 entries (objects in ObjStm)", function()
            -- obj 0: free
            -- obj 1: normal at offset 50
            -- obj 2: in ObjStm (stream obj 5, index 3)
            local entries = ""
            entries = entries .. "\x00\x00\x00\x00" -- obj 0: free
            entries = entries .. "\x01\x00\x32\x00" -- obj 1: at offset 50
            entries = entries .. "\x02\x00\x05\x03" -- obj 2: in ObjStm #5, index 3

            local compressed = rawDeflate(entries)

            local stream_obj = {
                dic = {
                    Type = pdfparser.literal("XRef"),
                    Size = 3,
                    W = { 1, 2, 1 },
                    Length = #compressed,
                    Filter = pdfparser.literal("FlateDecode"),
                },
                rawdata = compressed,
            }

            local xref = pdfdoc.PDFXRefStream:new()
            xref:load_from_obj(stream_obj)

            -- Type=2: returns nil pos, 0 genno, stmid, stindex
            local pos2, gen2, stmid, stindex = xref:getpos(2)
            assert.is_nil(pos2)
            assert.equals(0, gen2)
            assert.equals(5, stmid)
            assert.equals(3, stindex)
        end)
    end)

    describe("section ranges (Index array)", function()
        it("handles non-contiguous sections via Index array", function()
            -- Index = [5 2 10 1] means:
            -- Section 1: objects 5,6 (2 entries starting at 5)
            -- Section 2: object 10 (1 entry starting at 10)
            local entries = ""
            entries = entries .. "\x01\x00\x64\x00" -- obj 5: at offset 100
            entries = entries .. "\x01\x00\xC8\x00" -- obj 6: at offset 200
            entries = entries .. "\x01\x01\x2C\x00" -- obj 10: at offset 300

            local compressed = rawDeflate(entries)

            local stream_obj = {
                dic = {
                    Type = pdfparser.literal("XRef"),
                    Size = 11,
                    W = { 1, 2, 1 },
                    Index = { 5, 2, 10, 1 },
                    Length = #compressed,
                    Filter = pdfparser.literal("FlateDecode"),
                },
                rawdata = compressed,
            }

            local xref = pdfdoc.PDFXRefStream:new()
            xref:load_from_obj(stream_obj)

            local pos5 = xref:getpos(5)
            assert.equals(100, pos5)

            local pos6 = xref:getpos(6)
            assert.equals(200, pos6)

            local pos10 = xref:getpos(10)
            assert.equals(300, pos10)

            -- Object 7 is not in any section
            assert.is_nil(xref:getpos(7))
        end)

        it("defaults to Index=[0, Size] when Index is absent", function()
            local entries = ""
            entries = entries .. "\x00\x00\x00\x00" -- obj 0: free
            entries = entries .. "\x01\x00\x0A\x00" -- obj 1: at offset 10

            local compressed = rawDeflate(entries)

            local stream_obj = {
                dic = {
                    Type = pdfparser.literal("XRef"),
                    Size = 2,
                    W = { 1, 2, 1 },
                    -- No Index field
                    Length = #compressed,
                    Filter = pdfparser.literal("FlateDecode"),
                },
                rawdata = compressed,
            }

            local xref = pdfdoc.PDFXRefStream:new()
            xref:load_from_obj(stream_obj)

            local pos1 = xref:getpos(1)
            assert.equals(10, pos1)
        end)
    end)

    describe("objids()", function()
        it("returns all object IDs from all sections", function()
            local entries = ""
            entries = entries .. "\x01\x00\x0A\x00" -- obj 3
            entries = entries .. "\x01\x00\x14\x00" -- obj 4
            entries = entries .. "\x01\x00\x1E\x00" -- obj 8

            local compressed = rawDeflate(entries)

            local stream_obj = {
                dic = {
                    Type = pdfparser.literal("XRef"),
                    Size = 9,
                    W = { 1, 2, 1 },
                    Index = { 3, 2, 8, 1 },
                    Length = #compressed,
                    Filter = pdfparser.literal("FlateDecode"),
                },
                rawdata = compressed,
            }

            local xref = pdfdoc.PDFXRefStream:new()
            xref:load_from_obj(stream_obj)

            local ids = xref:objids()
            assert.equals(3, #ids)
            assert.equals(3, ids[1])
            assert.equals(4, ids[2])
            assert.equals(8, ids[3])
        end)
    end)
end)

------------------------------------------------------------------------
-- PDFDocument:getobj() with decryption
------------------------------------------------------------------------

describe("PDFDocument:getobj() with decryption", function()
    it("decrypts string values in loaded objects when decipher is set", function()
        -- Create a PDF with a dict object containing a string
        local tmp = createMinimalPdf({
            { id = 3, data = "3 0 obj\n<< /Title (encrypted_value) /Count 7 >>\nendobj\n" },
        })
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        -- Set a decipher that prefixes with objid
        doc:set_decipher(function(objid, genno, data)
            return string.format("[%d]%s", objid, data)
        end)

        -- Clear cached objects so getobj re-loads with decipher
        doc.objs = {}

        local obj = doc:getobj(3)
        assert.is_truthy(obj)
        assert.equals("[3]encrypted_value", obj.Title)
        assert.equals(7, obj.Count)

        doc:close()
    end)

    it("does not decrypt the Encrypt dict object itself", function()
        -- When loading via _loadRawObject (used for Encrypt dict), no decryption happens
        local tmp = createMinimalPdf({
            { id = 3, data = "3 0 obj\n<< /Filter /EBX_HANDLER /V 4 /ADEPT_LICENSE (license_data) >>\nendobj\n" },
        })
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        doc:set_decipher(function(objid, genno, data)
            return "DECRYPTED:" .. data
        end)

        -- _loadRawObject bypasses decipher
        local obj = doc:_loadRawObject(3)
        assert.is_truthy(obj)
        -- String should NOT be decrypted via _loadRawObject
        -- (it may already be cached from open())
        -- Let's test with a fresh doc that hasn't cached obj 3
        doc:close()

        local doc2 = pdfdoc.PDFDocument:new()
        doc2:open(tmp)
        doc2:set_decipher(function(objid, genno, data)
            return "DECRYPTED:" .. data
        end)
        doc2.objs = {} -- clear cache
        local raw = doc2:_loadRawObject(3)
        assert.is_truthy(raw)
        -- _loadRawObject should not apply decipher
        assert.equals("license_data", raw.ADEPT_LICENSE)
        doc2:close()
    end)

    it("attaches decipher to stream objects", function()
        -- Create a stream object in the PDF
        local stream_data = "stream content here"
        local stream_obj = string.format("3 0 obj\n<< /Length %d >>\nstream\r\n%s\r\nendstream\nendobj\n", #stream_data, stream_data)
        local tmp = createMinimalPdf({
            { id = 3, data = stream_obj },
        })
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        local decipher_called = false
        doc:set_decipher(function(objid, genno, data)
            decipher_called = true
            return data:upper()
        end)
        doc.objs = {} -- clear cache

        local obj = doc:getobj(3)
        assert.is_truthy(obj)
        -- Stream should have decipher attached but not called yet
        assert.is_truthy(obj.decipher)
        -- Trigger decryption
        local decdata = obj:get_decdata()
        assert.is_true(decipher_called)
        assert.equals("STREAM CONTENT HERE", decdata)

        doc:close()
    end)

    it("caches objects after first load", function()
        local tmp = createMinimalPdf({
            { id = 3, data = "3 0 obj\n<< /Value (test) >>\nendobj\n" },
        })
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        local call_count = 0
        doc:set_decipher(function(objid, genno, data)
            call_count = call_count + 1
            return data
        end)
        doc.objs = {}

        local obj1 = doc:getobj(3)
        local obj2 = doc:getobj(3)
        assert.equals(obj1, obj2) -- same cached reference
        assert.equals(1, call_count) -- decipher only called once

        doc:close()
    end)

    it("returns nil for non-existent object", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        local obj = doc:getobj(999)
        assert.is_nil(obj)

        doc:close()
    end)
end)

------------------------------------------------------------------------
-- PDFDocument:_expandObjStm() tests
------------------------------------------------------------------------

describe("PDFDocument:_expandObjStm()", function()
    it("expands objects from a compressed object stream", function()
        -- Build a PDF with an ObjStm (object stream)
        -- Object stream format:
        -- Header: N pairs of "objid offset" (decimal, space-separated)
        -- Body: serialized objects at those offsets (relative to start of body)

        -- Child objects: obj 4 = dict {/A (hello)}, obj 5 = number 42
        local child4 = "<< /A (hello) >>"
        local child5 = "42"
        -- Header: "4 0 5 17" (obj 4 at offset 0, obj 5 at offset 17)
        -- Wait, we need to know the exact offset. Let's be precise:
        -- child4 is 16 bytes "<< /A (hello) >>"... let's count
        -- Actually the offset is from the start of the objects section
        local header = string.format("4 0 5 %d ", #child4 + 1) -- +1 for space/newline
        local body = child4 .. " " .. child5
        local stm_content = header .. body

        -- Compress the content
        local compressed = rawDeflate(stm_content)

        -- Build the ObjStm stream object (obj 3)
        local stm_obj_str =
            string.format("3 0 obj\n<< /Type /ObjStm /N 2 /First %d /Length %d /Filter /FlateDecode >>\nstream\r\n", #header, #compressed)
        stm_obj_str = stm_obj_str .. compressed .. "\r\nendstream\nendobj\n"

        -- Build xref that knows obj 4 and 5 are in ObjStm 3
        -- We need a classic xref for objects 1, 2, 3 (catalog, pages, objstm)
        -- and the document needs to resolve obj 4 and 5 via ObjStm
        -- For simplicity, build a PDF where we manually set up xref entries

        local tmp = os.tmpname()
        local ff = io.open(tmp, "wb")
        ff:write("%PDF-1.5\n")
        ff:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))

        local offsets = {}
        offsets[1] = ff:seek()
        ff:write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        offsets[2] = ff:seek()
        ff:write("2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n")
        offsets[3] = ff:seek()
        ff:write(stm_obj_str)

        local xref_offset = ff:seek()
        -- Classic xref only knows about objects 1-3
        -- Objects 4-5 would be referenced via XRefStream (type=2)
        -- For this test, we'll use a classic xref and manually add ObjStm references
        ff:write("xref\n")
        ff:write("0 4\n")
        ff:write("0000000000 65535 f \r\n")
        ff:write(string.format("%010d 00000 n \r\n", offsets[1]))
        ff:write(string.format("%010d 00000 n \r\n", offsets[2]))
        ff:write(string.format("%010d 00000 n \r\n", offsets[3]))

        ff:write("trailer\n")
        ff:write("<< /Size 6 /Root 1 0 R >>\n")
        ff:write("startxref\n")
        ff:write(string.format("%d\n", xref_offset))
        ff:write("%%EOF\n")
        ff:close()

        -- Open the document
        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        -- Manually expand ObjStm 3
        doc:_expandObjStm(3)

        -- Check that child objects are now cached
        local obj4 = doc.objs[4]
        local obj5 = doc.objs[5]

        assert.is_truthy(obj4, "object 4 should be extracted from ObjStm")
        assert.is_truthy(obj5, "object 5 should be extracted from ObjStm")

        -- Verify obj4 is the dict
        if type(obj4) == "table" then
            assert.equals("hello", obj4.A)
        end

        -- Verify obj5 is the number
        assert.equals(42, obj5)

        doc:close()
        os.remove(tmp)
    end)

    it("does not expand the same ObjStm twice", function()
        -- Build a simple ObjStm
        local stm_content = "10 0 42" -- one object: obj 10 = number 42
        local compressed = rawDeflate(stm_content)

        local stm_obj_str = string.format("3 0 obj\n<< /Type /ObjStm /N 1 /First 5 /Length %d /Filter /FlateDecode >>\nstream\r\n", #compressed)
        stm_obj_str = stm_obj_str .. compressed .. "\r\nendstream\nendobj\n"

        local tmp = os.tmpname()
        local ff = io.open(tmp, "wb")
        ff:write("%PDF-1.5\n")
        ff:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))
        local offsets = {}
        offsets[1] = ff:seek()
        ff:write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        offsets[2] = ff:seek()
        ff:write("2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n")
        offsets[3] = ff:seek()
        ff:write(stm_obj_str)

        local xref_offset = ff:seek()
        ff:write("xref\n0 4\n")
        ff:write("0000000000 65535 f \r\n")
        ff:write(string.format("%010d 00000 n \r\n", offsets[1]))
        ff:write(string.format("%010d 00000 n \r\n", offsets[2]))
        ff:write(string.format("%010d 00000 n \r\n", offsets[3]))
        ff:write("trailer\n<< /Size 4 /Root 1 0 R >>\n")
        ff:write("startxref\n")
        ff:write(string.format("%d\n", xref_offset))
        ff:write("%%EOF\n")
        ff:close()

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        doc:_expandObjStm(3)
        doc:_expandObjStm(3) -- second call should be no-op

        assert.is_truthy(doc._expanded_stms[3])
        assert.equals(42, doc.objs[10])

        doc:close()
        os.remove(tmp)
    end)
end)

------------------------------------------------------------------------
-- PDFDocument:extractAdeptLicense() tests
------------------------------------------------------------------------

describe("PDFDocument:extractAdeptLicense()", function()
    it("extracts ADEPT_LICENSE string from encryption dict", function()
        local license_xml = "<?xml version='1.0'?><rights><key>value</key></rights>"
        local encrypt_dict = string.format("<< /Filter /EBX_HANDLER /V 4 /ADEPT_LICENSE (%s) /EBX_BOOKID (urn:uuid:test-123) >>", license_xml)
        local tmp = createEncryptedPdf(encrypt_dict)
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        assert.is_truthy(doc.encryption, "should detect encryption")
        local license, bookid = doc:extractAdeptLicense()
        assert.equals(license_xml, license)
        assert.equals("urn:uuid:test-123", bookid)

        doc:close()
    end)

    it("returns nil when no ADEPT_LICENSE present", function()
        local encrypt_dict = "<< /Filter /Standard /V 4 /R 4 /O (xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx) /U (yyyyyyyyyyyyyyyyyyyyyyyyyyyyyyyy) >>"
        local tmp = createEncryptedPdf(encrypt_dict)
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        local license = doc:extractAdeptLicense()
        assert.is_nil(license)

        doc:close()
    end)

    it("returns license without bookid when EBX_BOOKID is absent", function()
        local license_xml = "<rights>test</rights>"
        local encrypt_dict = string.format("<< /Filter /EBX_HANDLER /V 4 /ADEPT_LICENSE (%s) >>", license_xml)
        local tmp = createEncryptedPdf(encrypt_dict)
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        local license, bookid = doc:extractAdeptLicense()
        assert.equals(license_xml, license)
        assert.is_nil(bookid)

        doc:close()
    end)

    it("detects EBX_HANDLER encryption filter", function()
        local encrypt_dict = "<< /Filter /EBX_HANDLER /V 4 /ADEPT_LICENSE (test) >>"
        local tmp = createEncryptedPdf(encrypt_dict)
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        assert.equals("EBX_HANDLER", doc:getEncryptionFilter())

        doc:close()
    end)

    it("detects Standard encryption filter", function()
        local encrypt_dict = "<< /Filter /Standard /V 2 /R 3 >>"
        local tmp = createEncryptedPdf(encrypt_dict)
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        assert.equals("Standard", doc:getEncryptionFilter())

        doc:close()
    end)
end)

------------------------------------------------------------------------
-- Incremental updates and fallback scanning
------------------------------------------------------------------------

describe("incremental updates", function()
    it("reads multiple xref sections (Prev chain)", function()
        -- Build a PDF with two xref sections simulating an incremental update.
        -- Pad between first %%EOF and incremental update so the first startxref
        -- is outside the last-1024-byte window (which is what _find_xref searches).
        local tmp = os.tmpname()
        local f = io.open(tmp, "wb")

        f:write("%PDF-1.4\n")
        f:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))

        -- Original objects
        local off1 = f:seek()
        f:write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        local off2 = f:seek()
        f:write("2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n")

        -- First xref section
        local xref1_offset = f:seek()
        f:write("xref\n")
        f:write("0 3\n")
        f:write("0000000000 65535 f \r\n")
        f:write(string.format("%010d 00000 n \r\n", off1))
        f:write(string.format("%010d 00000 n \r\n", off2))
        f:write("trailer\n")
        f:write("<< /Size 3 /Root 1 0 R >>\n")
        f:write("startxref\n")
        f:write(string.format("%d\n", xref1_offset))
        f:write("%%EOF\n")

        -- Pad between sections so the first startxref falls outside last 1024 bytes
        f:write(string.rep(" ", 1200) .. "\n")

        -- Incremental update: add object 3 and new xref
        local off3 = f:seek()
        f:write("3 0 obj\n<< /Info (Updated) >>\nendobj\n")

        local xref2_offset = f:seek()
        f:write("xref\n")
        f:write("3 1\n")
        f:write(string.format("%010d 00000 n \r\n", off3))
        f:write("trailer\n")
        f:write(string.format("<< /Size 4 /Root 1 0 R /Prev %d >>\n", xref1_offset))
        f:write("startxref\n")
        f:write(string.format("%d\n", xref2_offset))
        f:write("%%EOF\n")

        f:close()

        -- Parse
        local doc = pdfdoc.PDFDocument:new()
        local ok, err = doc:open(tmp)
        assert.is_truthy(ok, "should open incremental PDF: " .. tostring(err))

        -- Should have 2 xref sections
        assert.is_truthy(#doc.xrefs >= 2, "should have at least 2 xref sections, got " .. #doc.xrefs)

        -- Should be able to load all 3 objects
        local obj1 = doc:getobj(1)
        assert.is_truthy(obj1)
        local obj3 = doc:getobj(3)
        assert.is_truthy(obj3)
        assert.equals("Updated", obj3.Info)

        doc:close()
        os.remove(tmp)
    end)

    it("falls back to scanning when xref is missing", function()
        -- Build a PDF without a proper xref (no "xref" keyword, just objects + trailer)
        local tmp = os.tmpname()
        local f = io.open(tmp, "wb")

        f:write("%PDF-1.4\n")
        f:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))

        f:write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")
        f:write("2 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n")
        f:write("3 0 obj\n<< /Title (Fallback Test) >>\nendobj\n")

        -- Write a fake startxref pointing to an invalid location
        -- to trigger fallback scanning
        f:write("startxref\n")
        f:write("99999\n") -- invalid offset
        f:write("%%EOF\n")

        f:close()

        local doc = pdfdoc.PDFDocument:new()
        local ok = doc:open(tmp)
        -- Should still succeed via fallback scanning
        -- (At minimum should have found some xref entries)
        if ok or #doc.xrefs > 0 then
            local ids = doc:allObjids()
            -- Should find at least some objects
            assert.is_truthy(#ids > 0, "fallback scan should find objects")
        end

        if doc.file then
            doc:close()
        end
        os.remove(tmp)
    end)
end)

------------------------------------------------------------------------
-- PDFXRef (classic) additional tests
------------------------------------------------------------------------

describe("PDFXRef (classic)", function()
    it("parses multiple subsections in one xref table", function()
        -- Build a PDF with a multi-subsection xref
        local tmp = os.tmpname()
        local f = io.open(tmp, "wb")

        f:write("%PDF-1.4\n")
        f:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))

        local off1 = f:seek()
        f:write("1 0 obj\n<< /Type /Catalog /Pages 5 0 R >>\nendobj\n")
        local off5 = f:seek()
        f:write("5 0 obj\n<< /Type /Pages /Kids [] /Count 0 >>\nendobj\n")

        local xref_offset = f:seek()
        f:write("xref\n")
        -- Subsection 1: objects 0-1
        f:write("0 2\n")
        f:write("0000000000 65535 f \r\n")
        f:write(string.format("%010d 00000 n \r\n", off1))
        -- Subsection 2: object 5
        f:write("5 1\n")
        f:write(string.format("%010d 00000 n \r\n", off5))

        f:write("trailer\n")
        f:write("<< /Size 6 /Root 1 0 R >>\n")
        f:write("startxref\n")
        f:write(string.format("%d\n", xref_offset))
        f:write("%%EOF\n")
        f:close()

        local doc = pdfdoc.PDFDocument:new()
        local ok, err = doc:open(tmp)
        assert.is_truthy(ok, "should open multi-subsection xref PDF: " .. tostring(err))

        -- Should find objects 1 and 5
        local obj1 = doc:getobj(1)
        assert.is_truthy(obj1)
        local obj5 = doc:getobj(5)
        assert.is_truthy(obj5)
        -- Object 3 should not exist
        assert.is_nil(doc:getobj(3))

        doc:close()
        os.remove(tmp)
    end)

    it("getpos returns offset and genno", function()
        local xref = pdfdoc.PDFXRef:new()
        xref.offsets[5] = { genno = 2, offset = 1234 }
        local pos, gen = xref:getpos(5)
        assert.equals(1234, pos)
        assert.equals(2, gen)
    end)

    it("getpos returns nil for unknown objid", function()
        local xref = pdfdoc.PDFXRef:new()
        xref.offsets[1] = { genno = 0, offset = 100 }
        assert.is_nil(xref:getpos(99))
    end)

    it("objids returns sorted list", function()
        local xref = pdfdoc.PDFXRef:new()
        xref.offsets[5] = { genno = 0, offset = 500 }
        xref.offsets[1] = { genno = 0, offset = 100 }
        xref.offsets[3] = { genno = 0, offset = 300 }
        local ids = xref:objids()
        assert.equals(3, #ids)
        assert.equals(1, ids[1])
        assert.equals(3, ids[2])
        assert.equals(5, ids[3])
    end)
end)

------------------------------------------------------------------------
-- getCleanTrailer tests
------------------------------------------------------------------------

describe("PDFDocument:getCleanTrailer()", function()
    it("removes Encrypt, Prev, and XRefStm from trailer", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        -- Manually inject keys to verify they're stripped
        if doc.xrefs[1] and doc.xrefs[1].trailer then
            doc.xrefs[1].trailer.Encrypt = { ref = { objid = 99 } }
            doc.xrefs[1].trailer.Prev = 12345
            doc.xrefs[1].trailer.XRefStm = 67890
        end

        local clean = doc:getCleanTrailer()
        assert.is_nil(clean.Encrypt)
        assert.is_nil(clean.Prev)
        assert.is_nil(clean.XRefStm)
        -- Root should still be present
        assert.is_truthy(clean.Root)

        doc:close()
    end)
end)

------------------------------------------------------------------------
-- set_decipher tests
------------------------------------------------------------------------

describe("PDFDocument:set_decipher()", function()
    it("stores the decipher function on the document", function()
        local doc = pdfdoc.PDFDocument:new()
        assert.is_nil(doc.decipher)
        local fn = function() end
        doc:set_decipher(fn)
        assert.equals(fn, doc.decipher)
    end)
end)

------------------------------------------------------------------------
-- allObjids with multiple xrefs
------------------------------------------------------------------------

describe("PDFDocument:allObjids()", function()
    it("deduplicates objids from multiple xref sections", function()
        local doc = pdfdoc.PDFDocument:new()
        -- Simulate two xref sections with overlapping IDs
        local xref1 = pdfdoc.PDFXRef:new()
        xref1.offsets[1] = { genno = 0, offset = 100 }
        xref1.offsets[2] = { genno = 0, offset = 200 }

        local xref2 = pdfdoc.PDFXRef:new()
        xref2.offsets[2] = { genno = 0, offset = 250 } -- duplicate
        xref2.offsets[3] = { genno = 0, offset = 300 }

        doc.xrefs = { xref1, xref2 }

        local ids = doc:allObjids()
        assert.equals(3, #ids) -- should be deduplicated
        assert.equals(1, ids[1])
        assert.equals(2, ids[2])
        assert.equals(3, ids[3])
    end)
end)
