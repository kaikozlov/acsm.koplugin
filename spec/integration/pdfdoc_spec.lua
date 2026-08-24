--- Tests for adobe/pdf/pdfdoc.lua (PDF document reader)

local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfparser = require("adobe.pdf.parser")
-- Helper: create a minimal valid PDF in a temp file
local function createMinimalPdf(extra_objects)
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
    f:write(string.format("<< /Size %d /Root 1 0 R >>\n", maxid + 1))
    f:write("startxref\n")
    f:write(string.format("%d\n", xref_offset))
    f:write("%%EOF\n")

    f:close()
    return tmp
end

describe("PDFDocument", function()
    teardown(function()
        -- Clean up any temp files if needed
    end)

    it("should open a minimal valid PDF", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        local ok, err = doc:open(tmp)
        assert.is_truthy(ok, "open failed: " .. tostring(err))

        doc:close()
    end)

    it("should read the PDF header", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        assert.is_truthy(doc.header:match("^%%PDF"))
        doc:close()
    end)

    it("should parse the xref table", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        assert.is_truthy(#doc.xrefs > 0, "should have at least one xref section")
        doc:close()
    end)

    it("should enumerate all objids", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        local ids = doc:allObjids()
        assert.is_truthy(#ids >= 2, "should have at least 2 objects (catalog + pages)")
        -- Verify specific IDs exist
        local seen = {}
        for _, id in ipairs(ids) do
            seen[id] = true
        end
        assert.is_truthy(seen[1], "object 1 (catalog) should be in objids")
        assert.is_truthy(seen[2], "object 2 (pages) should be in objids")
        -- Object 0 should NEVER be returned (it's reserved/free)
        assert.is_falsy(seen[0], "object 0 should not appear in objids")
        doc:close()
    end)

    it("should load objects by objid", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        local catalog = doc:getobj(1)
        assert.is_truthy(catalog, "object 1 (catalog) should load")
        -- Catalog should have Type=Catalog
        local typ = catalog.Type or catalog["type"]
        if typ and type(typ) == "table" and getmetatable(typ) == pdfparser.PSLiteral then
            assert.equals("Catalog", typ.name)
        end
        doc:close()
    end)

    it("should detect no encryption on a plain PDF", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        assert.is_falsy(doc.encryption, "plain PDF should not have encryption")
        assert.is_falsy(doc:getEncryptionFilter())
        doc:close()
    end)

    it("should parse trailer and find Root", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        assert.is_truthy(doc.root, "should have Root reference")
        doc:close()
    end)

    it("should handle extra objects", function()
        local tmp = createMinimalPdf({
            { id = 3, data = "3 0 obj\n<< /Title (Hello World) /Author (Test) >>\nendobj\n" },
        })
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        local obj3 = doc:getobj(3)
        assert.is_truthy(obj3, "object 3 should load")

        doc:close()
    end)

    it("should produce a clean trailer without Encrypt", function()
        local tmp = createMinimalPdf()
        finally(function()
            os.remove(tmp)
        end)

        local doc = pdfdoc.PDFDocument:new()
        doc:open(tmp)

        local clean = doc:getCleanTrailer()
        assert.is_falsy(clean.Encrypt, "clean trailer should not have Encrypt")
        doc:close()
    end)
end)
