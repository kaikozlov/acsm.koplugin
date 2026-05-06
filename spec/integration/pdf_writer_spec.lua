--- Tests for adobe/pdf/writer.lua (PDF serializer)

local writer = require("adobe.pdf.writer")

describe("PDF writer", function()

    ------------------------------------------------------------------
    -- serializeObject: numbers
    ------------------------------------------------------------------
    describe("serializeObject with numbers", function()
        it("serializes positive integers", function()
            assert.equals("42", writer.serializeObject(42))
        end)

        it("serializes zero", function()
            assert.equals("0", writer.serializeObject(0))
        end)

        it("serializes negative integers", function()
            assert.equals("-1", writer.serializeObject(-1))
        end)

        it("serializes floats", function()
            local s = writer.serializeObject(3.14)
            assert.truthy(s:find("^3%."))
            assert.truthy(tonumber(s) > 3)
            assert.truthy(tonumber(s) < 4)
        end)
    end)

    ------------------------------------------------------------------
    -- serializeObject: booleans
    ------------------------------------------------------------------
    describe("serializeObject with booleans", function()
        it("serializes true", function()
            assert.equals("true", writer.serializeObject(true))
        end)

        it("serializes false", function()
            assert.equals("false", writer.serializeObject(false))
        end)
    end)

    ------------------------------------------------------------------
    -- serializeObject: names
    ------------------------------------------------------------------
    describe("serializeObject with names", function()
        it("serializes a simple name via {name=...}", function()
            assert.equals("/Type", writer.serializeObject({ name = "Type" }))
        end)

        it("serializes a name with multiple parts", function()
            assert.equals("/FlateDecode", writer.serializeObject({ name = "FlateDecode" }))
        end)

        it("hex-escapes special characters in names", function()
            -- space becomes #20
            assert.equals("/Name#20With#20Spaces",
                writer.serializeObject({ name = "Name With Spaces" }))
        end)

        it("serializes names from parser PSLiteral if available", function()
            local ok, pdfparser = pcall(require, "adobe.pdf.parser")
            if ok then
                local lit = pdfparser.literal("Catalog")
                assert.equals("/Catalog", writer.serializeObject(lit))
            end
        end)
    end)

    ------------------------------------------------------------------
    -- serializeObject: strings
    ------------------------------------------------------------------
    describe("serializeObject with strings", function()
        it("serializes a simple string", function()
            assert.equals("(hello)", writer.serializeObject("hello"))
        end)

        it("serializes an empty string", function()
            assert.equals("()", writer.serializeObject(""))
        end)
    end)

    ------------------------------------------------------------------
    -- serializeObject: string escaping
    ------------------------------------------------------------------
    describe("string escaping", function()
        it("escapes parentheses", function()
            assert.equals("(hello\\(world\\))",
                writer.serializeObject("hello(world)"))
        end)

        it("escapes backslashes", function()
            assert.equals("(back\\\\slash)",
                writer.serializeObject("back\\slash"))
        end)

        it("escapes newlines", function()
            assert.equals("(line\\nbreak)",
                writer.serializeObject("line\nbreak"))
        end)

        it("escapes carriage returns", function()
            assert.equals("(col\\r\\n)",
                writer.serializeObject("col\r\n"))
        end)

        it("escapes tabs as named escape", function()
            -- tab (byte 9) is escaped as \t per PDF spec
            local s = writer.serializeObject("a\tb")
            assert.equals("(a\\tb)", s)
        end)
    end)

    ------------------------------------------------------------------
    -- serializeObject: arrays
    ------------------------------------------------------------------
    describe("serializeObject with arrays", function()
        it("serializes an array of numbers", function()
            assert.equals("[1 2 3]", writer.serializeObject({ 1, 2, 3 }))
        end)

        it("serializes an empty array", function()
            assert.equals("[]", writer.serializeObject({}))
        end)

        it("serializes nested arrays", function()
            -- Compact format: no space between ] and [
            assert.equals("[[1 2][3 4]]",
                writer.serializeObject({ { 1, 2 }, { 3, 4 } }))
        end)

        it("serializes mixed-type arrays", function()
            local arr = { 42, { name = "Catalog" }, "hello" }
            local s = writer.serializeObject(arr)
            -- Compact format: space only when both adjacent bytes are alnum
            assert.equals("[42/Catalog(hello)]", s)
        end)
    end)

    ------------------------------------------------------------------
    -- serializeObject: dicts
    ------------------------------------------------------------------
    describe("serializeObject with dicts", function()
        it("serializes a simple dict", function()
            local d = { Type = { name = "Catalog" } }
            local s = writer.serializeObject(d)
            -- Compact format: no space between name and name value
            assert.equals("<</Type/Catalog>>", s)
        end)

        it("serializes a dict with multiple keys", function()
            local d = {
                Type = { name = "Page" },
                Length = 42,
            }
            local s = writer.serializeObject(d)
            assert.truthy(s:match("^<<"))
            assert.truthy(s:match(">>$"))
            assert.truthy(s:find("/Type/Page"))
            assert.truthy(s:find("/Length 42")) -- space before number
        end)

        it("serializes an empty dict", function()
            -- An empty table with no string keys is actually an empty
            -- array in our detection logic. Use a dict with a dummy
            -- key or check both forms.
            local s = writer.serializeObject({})
            assert.truthy(s == "[]" or s == "<<>>")
        end)
    end)

    ------------------------------------------------------------------
    -- serializeObject: indirect references
    ------------------------------------------------------------------
    describe("serializeObject with indirect refs", function()
        it("serializes an indirect reference", function()
            local ref = { ref = { objid = 5, genno = 0 } }
            assert.equals("5 0 R", writer.serializeObject(ref))
        end)

        it("serializes a reference with nonzero genno", function()
            local ref = { ref = { objid = 10, genno = 2 } }
            assert.equals("10 2 R", writer.serializeObject(ref))
        end)
    end)

    ------------------------------------------------------------------
    -- serializeObject: streams
    ------------------------------------------------------------------
    describe("serializeObject with streams", function()
        it("serializes a stream object", function()
            local stream = {
                dict = { Type = { name = "ObjStm" } },
                stream_data = "hello stream data",
            }
            local s = writer.serializeObject(stream)
            assert.truthy(s:find("^<<"))
            assert.truthy(s:find("/Length 17"))
            assert.truthy(s:find("stream\n"))
            assert.truthy(s:find("hello stream data"))
            assert.truthy(s:find("endstream$"))
        end)
    end)

    ------------------------------------------------------------------
    -- serializeObject: keywords
    ------------------------------------------------------------------
    describe("serializeObject with keywords", function()
        it("serializes a keyword via {keyword=...}", function()
            assert.equals("endobj", writer.serializeObject({ keyword = "endobj" }))
        end)

        it("serializes keywords from parser PSKeyword if available", function()
            local ok, pdfparser = pcall(require, "adobe.pdf.parser")
            if ok then
                local kw = pdfparser.keyword("obj")
                assert.equals("obj", writer.serializeObject(kw))
            end
        end)
    end)

    ------------------------------------------------------------------
    -- writeCleanPdf: complete PDF output
    ------------------------------------------------------------------
    describe("writeCleanPdf", function()
        local tmpfile

        before_each(function()
            tmpfile = os.tmpname()
            -- Ensure tmpname doesn't give us a file that already exists
            os.remove(tmpfile)
        end)

        after_each(function()
            if tmpfile then
                os.remove(tmpfile)
            end
        end)

        it("writes a minimal valid PDF", function()
            local doc = {
                version = "%PDF-1.4",
                trailer = {
                    Root = { ref = { objid = 1, genno = 0 } },
                },
                xref_entries = {},
                objects = {
                    [1] = { Type = { name = "Catalog" } },
                },
            }

            writer.writeCleanPdf(nil, tmpfile, doc, nil)

            local f = io.open(tmpfile, "rb")
            assert.truthy(f, "output file should exist")
            local content = f:read("*a")
            f:close()

            -- Header
            assert.truthy(content:find("%%PDF%-1%.4"), "should have PDF header")

            -- Binary comment (4 high bytes)
            assert.truthy(content:find("%%\xe2\xe3\xcf\xd3"), "should have binary comment")

            -- Object
            assert.truthy(content:find("1 0 obj"), "should have object header")
            assert.truthy(content:find("/Type/Catalog"), "should have dict content")
            assert.truthy(content:find("endobj"), "should have object footer")

            -- Cross-reference table
            assert.truthy(content:find("xref"), "should have xref")
            assert.truthy(content:find("0000000000 65535 f"), "should have free entry 0")

            -- Trailer
            assert.truthy(content:find("trailer"), "should have trailer")
            assert.truthy(content:find("/Root 1 0 R"), "should have Root reference")
            assert.truthy(content:find("/Size 2"), "should have Size = maxobj + 1")

            -- Startxref + EOF
            assert.truthy(content:find("startxref"), "should have startxref")
            assert.truthy(content:find("%%%%EOF"), "should have %%EOF")
        end)

        it("omits /Encrypt from trailer", function()
            local doc = {
                version = "%PDF-1.6",
                trailer = {
                    Root = { ref = { objid = 1, genno = 0 } },
                    Encrypt = { ref = { objid = 2, genno = 0 } },
                },
                xref_entries = {},
                objects = {
                    [1] = { Type = { name = "Catalog" } },
                    -- Object 2 (Encrypt) exists but should be skipped
                    [2] = { Type = { name = "Encrypt" } },
                },
            }

            writer.writeCleanPdf(nil, tmpfile, doc, 2)

            local f = io.open(tmpfile, "rb")
            local content = f:read("*a")
            f:close()

            -- Encrypt dict (obj 2) should NOT appear in the output
            assert.falsy(content:find("2 0 obj"), "should not write encrypt object")

            -- Trailer should NOT have /Encrypt
            assert.falsy(content:find("/Encrypt"), "trailer should not have Encrypt")

            -- Size = max remaining objid + 1 = 1 + 1 = 2
            assert.truthy(content:find("/Size 2"), "should have correct Size")
        end)

        it("fills xref_entries with offsets", function()
            local xref = {}
            local doc = {
                version = "%PDF-1.4",
                trailer = {
                    Root = { ref = { objid = 1, genno = 0 } },
                },
                xref_entries = xref,
                objects = {
                    [1] = { Type = { name = "Catalog" } },
                },
            }

            writer.writeCleanPdf(nil, tmpfile, doc, nil)

            assert.truthy(xref[1], "should have entry for object 1")
            assert.is_number(xref[1].offset)
            assert.equals(0, xref[1].genno)
            assert.truthy(xref[1].offset > 0, "offset should be positive")
        end)

        it("writes stream objects correctly", function()
            local doc = {
                version = "%PDF-1.4",
                trailer = {
                    Root = { ref = { objid = 1, genno = 0 } },
                },
                xref_entries = {},
                objects = {
                    [1] = { Type = { name = "Catalog" } },
                    [2] = {
                        dict = {
                            Filter = { name = "FlateDecode" },
                        },
                        stream_data = "compressed data here",
                    },
                },
            }

            writer.writeCleanPdf(nil, tmpfile, doc, nil)

            local f = io.open(tmpfile, "rb")
            local content = f:read("*a")
            f:close()

            assert.truthy(content:find("2 0 obj"), "should have stream object")
            assert.truthy(content:find("/Filter/FlateDecode"), "should have filter")
            assert.truthy(content:find("/Length 20"), "should have correct Length")
            assert.truthy(content:find("stream\n"), "should have stream keyword")
            assert.truthy(content:find("compressed data here"), "should have stream data")
            assert.truthy(content:find("endstream"), "should have endstream")
        end)

        it("handles gaps in objid sequence", function()
            local doc = {
                version = "%PDF-1.4",
                trailer = {
                    Root = { ref = { objid = 5, genno = 0 } },
                },
                xref_entries = {},
                objects = {
                    [5] = { Type = { name = "Catalog" } },
                    [10] = { Type = { name = "Pages" } },
                },
            }

            writer.writeCleanPdf(nil, tmpfile, doc, nil)

            local f = io.open(tmpfile, "rb")
            local content = f:read("*a")
            f:close()

            -- Both objects should be present
            assert.truthy(content:find("5 0 obj"))
            assert.truthy(content:find("10 0 obj"))

            -- Size should be 11 (maxobj 10 + 1)
            assert.truthy(content:find("/Size 11"))

            -- xref should have 11 entries (0 through 10)
            assert.truthy(content:find("0 11"))
        end)
    end)
end)
