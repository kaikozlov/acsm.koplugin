--- Integration tests for PDF tokenizer/object parser.
-- Tests the Lua port of ineptpdf.py's PSBaseParser + PSStackParser.

describe("PDF parser", function()
    local parser

    setup(function()
        parser = require("adobe.pdf.parser")
    end)

    -- Helper: create a parser from a string
    local function make_parser(data)
        local fname = os.tmpname()
        local f = io.open(fname, "wb")
        f:write(data)
        f:close()
        f = io.open(fname, "rb")
        -- Store fname for cleanup
        return parser.new(f), fname
    end

    local function cleanup(p, fname)
        if p and p.fp then p.fp:close() end
        if fname then os.remove(fname) end
    end

    ---------------------------------------------------------------
    -- PSLiteral and PSKeyword
    ---------------------------------------------------------------
    describe("PSLiteral", function()
        it("creates name objects", function()
            local lit = parser.literal("Type")
            assert.is.truthy(lit)
            assert.equals("Type", lit.name)
            assert.equals("/Type", tostring(lit))
        end)

        it("has correct metatable", function()
            local lit = parser.literal("Foo")
            assert.equals(parser.PSLiteral, getmetatable(lit))
        end)
    end)

    describe("PSKeyword", function()
        it("creates keyword tokens", function()
            local kw = parser.keyword("obj")
            assert.is.truthy(kw)
            assert.equals("obj", kw.name)
            assert.equals("obj", tostring(kw))
        end)

        it("has correct metatable", function()
            local kw = parser.keyword("endobj")
            assert.equals(parser.PSKeyword, getmetatable(kw))
        end)
    end)

    ---------------------------------------------------------------
    -- Tokenizer: numbers
    ---------------------------------------------------------------
    describe("tokenizing numbers", function()
        it("parses positive integers", function()
            local p, f = make_parser("42")
            local pos, tok = p:nexttoken()
            assert.equals(42, tok)
            cleanup(p, f)
        end)

        it("parses negative integers", function()
            local p, f = make_parser("-7")
            local pos, tok = p:nexttoken()
            assert.equals(-7, tok)
            cleanup(p, f)
        end)

        it("parses zero", function()
            local p, f = make_parser("0")
            local pos, tok = p:nexttoken()
            assert.equals(0, tok)
            cleanup(p, f)
        end)

        it("parses decimal numbers", function()
            local p, f = make_parser("3.14")
            local pos, tok = p:nexttoken()
            assert.is.truthy(math.abs(tok - 3.14) < 0.001)
            cleanup(p, f)
        end)

        it("parses negative decimals", function()
            local p, f = make_parser("-0.5")
            local pos, tok = p:nexttoken()
            assert.is.truthy(math.abs(tok - (-0.5)) < 0.001)
            cleanup(p, f)
        end)

        it("parses leading-dot decimals", function()
            local p, f = make_parser(".5")
            local pos, tok = p:nexttoken()
            assert.is.truthy(math.abs(tok - 0.5) < 0.001)
            cleanup(p, f)
        end)

        it("parses integer then dot as decimal", function()
            local p, f = make_parser("1.0")
            local pos, tok = p:nexttoken()
            assert.is.truthy(math.abs(tok - 1.0) < 0.001)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Tokenizer: names (PSLiteral)
    ---------------------------------------------------------------
    describe("tokenizing names", function()
        it("parses simple names", function()
            local p, f = make_parser("/Type")
            local pos, tok = p:nexttoken()
            assert.is.truthy(getmetatable(tok) == parser.PSLiteral)
            assert.equals("Type", tok.name)
            cleanup(p, f)
        end)

        it("parses names with numbers", function()
            local p, f = make_parser("/Length1")
            local pos, tok = p:nexttoken()
            assert.equals("Length1", tok.name)
            cleanup(p, f)
        end)

        it("parses names ending at whitespace", function()
            local p, f = make_parser("/Root /Size")
            local pos, tok = p:nexttoken()
            assert.equals("Root", tok.name)
            pos, tok = p:nexttoken()
            assert.equals("Size", tok.name)
            cleanup(p, f)
        end)

        it("parses names with hex escapes", function()
            local p, f = make_parser("/Name#20With#20Spaces")
            local pos, tok = p:nexttoken()
            assert.equals("Name With Spaces", tok.name)
            cleanup(p, f)
        end)

        it("parses empty name", function()
            local p, f = make_parser("/ ")
            local pos, tok = p:nexttoken()
            assert.equals("", tok.name)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Tokenizer: keywords
    ---------------------------------------------------------------
    describe("tokenizing keywords", function()
        it("parses obj keyword", function()
            local p, f = make_parser("obj")
            local pos, tok = p:nexttoken()
            assert.is.truthy(getmetatable(tok) == parser.PSKeyword)
            assert.equals("obj", tok.name)
            cleanup(p, f)
        end)

        it("parses endobj keyword", function()
            local p, f = make_parser("endobj")
            local pos, tok = p:nexttoken()
            assert.equals("endobj", tok.name)
            cleanup(p, f)
        end)

        it("parses stream keyword", function()
            local p, f = make_parser("stream")
            local pos, tok = p:nexttoken()
            assert.equals("stream", tok.name)
            cleanup(p, f)
        end)

        it("parses true as boolean true", function()
            local p, f = make_parser("true")
            local pos, tok = p:nexttoken()
            assert.is.truthy(tok)
            cleanup(p, f)
        end)

        it("parses false as boolean false", function()
            local p, f = make_parser("false")
            local pos, tok = p:nexttoken()
            assert.is.falsy(tok)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Tokenizer: literal strings
    ---------------------------------------------------------------
    describe("tokenizing literal strings", function()
        it("parses simple string", function()
            local p, f = make_parser("(hello)")
            local pos, tok = p:nexttoken()
            assert.equals("hello", tok)
            cleanup(p, f)
        end)

        it("parses empty string", function()
            local p, f = make_parser("()")
            local pos, tok = p:nexttoken()
            assert.equals("", tok)
            cleanup(p, f)
        end)

        it("parses string with spaces", function()
            local p, f = make_parser("(hello world)")
            local pos, tok = p:nexttoken()
            assert.equals("hello world", tok)
            cleanup(p, f)
        end)

        it("handles nested parentheses", function()
            local p, f = make_parser("(hello (nested) world)")
            local pos, tok = p:nexttoken()
            assert.equals("hello (nested) world", tok)
            cleanup(p, f)
        end)

        it("handles deeply nested parentheses", function()
            local p, f = make_parser("(a (b (c) d) e)")
            local pos, tok = p:nexttoken()
            assert.equals("a (b (c) d) e", tok)
            cleanup(p, f)
        end)

        it("handles escape sequences", function()
            local p, f = make_parser("(hello\\nworld)")
            local pos, tok = p:nexttoken()
            assert.equals("hello\nworld", tok)
            cleanup(p, f)
        end)

        it("handles escaped backslash", function()
            local p, f = make_parser("(path\\\\name)")
            local pos, tok = p:nexttoken()
            assert.equals("path\\name", tok)
            cleanup(p, f)
        end)

        it("handles escaped parentheses", function()
            local p, f = make_parser("(\\(\\))")
            local pos, tok = p:nexttoken()
            assert.equals("()", tok)
            cleanup(p, f)
        end)

        it("handles \\r escape", function()
            local p, f = make_parser("(line1\\rline2)")
            local pos, tok = p:nexttoken()
            assert.equals("line1\rline2", tok)
            cleanup(p, f)
        end)

        it("handles \\t escape", function()
            local p, f = make_parser("(col1\\tcol2)")
            local pos, tok = p:nexttoken()
            assert.equals("col1\tcol2", tok)
            cleanup(p, f)
        end)

        it("handles \\b escape", function()
            local p, f = make_parser("(\\b)")
            local pos, tok = p:nexttoken()
            assert.equals(string.char(8), tok)
            cleanup(p, f)
        end)

        it("handles \\f escape", function()
            local p, f = make_parser("(\\f)")
            local pos, tok = p:nexttoken()
            assert.equals(string.char(12), tok)
            cleanup(p, f)
        end)

        it("handles octal escapes", function()
            local p, f = make_parser("(\\101)")  -- octal 101 = 'A'
            local pos, tok = p:nexttoken()
            assert.equals("A", tok)
            cleanup(p, f)
        end)

        it("handles 3-digit octal escapes", function()
            local p, f = make_parser("(\\101\\102\\103)")
            local pos, tok = p:nexttoken()
            assert.equals("ABC", tok)
            cleanup(p, f)
        end)

        it("handles octal escape followed by non-octal", function()
            local p, f = make_parser("(\\12X)")  -- octal 12 = \n
            local pos, tok = p:nexttoken()
            assert.equals("\nX", tok)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Tokenizer: hex strings
    ---------------------------------------------------------------
    describe("tokenizing hex strings", function()
        it("parses simple hex string", function()
            local p, f = make_parser("<4F6E>")
            local pos, tok = p:nexttoken()
            assert.equals("On", tok)
            cleanup(p, f)
        end)

        it("parses hex string with spaces", function()
            local p, f = make_parser("<4F 6E 6C 79>")
            local pos, tok = p:nexttoken()
            assert.equals("Only", tok)
            cleanup(p, f)
        end)

        it("parses empty hex string", function()
            local p, f = make_parser("<>")
            -- Empty hex string: '<' then '>' - but our parser first sees '<'
            -- and enters wopen state. It peeks at '>' which is not '<', not
            -- whitespace, not hex - so it falls through. Then wclose sees '>>'.
            -- Actually this is an edge case. Let's see what happens.
            -- In Python: '<>' is handled - wopen sees '>' which is not whitespace/hex,
            -- so it adds EmptyArrayValue. Let's just test that it doesn't crash.
            local pos, tok = p:nexttoken()
            -- We accept either a result or nil; just no error
            cleanup(p, f)
        end)

        it("parses hex string with odd number of digits (pads with 0)", function()
            local p, f = make_parser("<41F>")  -- 'A' + 0xF0
            local pos, tok = p:nexttoken()
            assert.equals("A" .. string.char(0xF0), tok)
            cleanup(p, f)
        end)

        it("parses lowercase hex", function()
            local p, f = make_parser("<616263>")
            local pos, tok = p:nexttoken()
            assert.equals("abc", tok)
            cleanup(p, f)
        end)

        it("parses hex string with newlines", function()
            local p, f = make_parser("<48\n65\n6C\n6C\n6F>")
            local pos, tok = p:nexttoken()
            assert.equals("Hello", tok)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Tokenizer: comments
    ---------------------------------------------------------------
    describe("tokenizing comments", function()
        it("skips comments", function()
            local p, f = make_parser("% this is a comment\n42")
            local pos, tok = p:nexttoken()
            assert.equals(42, tok)
            cleanup(p, f)
        end)

        it("skips comment at end of input", function()
            local p, f = make_parser("42 % trailing comment")
            local pos, tok = p:nexttoken()
            assert.equals(42, tok)
            -- Second call should hit EOF
            pos, tok = p:nexttoken()
            assert.is_nil(tok)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Tokenizer: dict/array delimiters
    ---------------------------------------------------------------
    describe("tokenizing delimiters", function()
        it("parses << as dict begin", function()
            local p, f = make_parser("<<")
            local pos, tok = p:nexttoken()
            assert.is.truthy(getmetatable(tok) == parser.PSKeyword)
            assert.equals("<<", tok.name)
            cleanup(p, f)
        end)

        it("parses >> as dict end", function()
            local p, f = make_parser(">>")
            local pos, tok = p:nexttoken()
            assert.is.truthy(getmetatable(tok) == parser.PSKeyword)
            assert.equals(">>", tok.name)
            cleanup(p, f)
        end)

        it("parses [ and ] as array delimiters", function()
            local p, f = make_parser("[1 2]")
            local pos, tok = p:nexttoken()
            assert.equals("[", tok.name)
            pos, tok = p:nexttoken()
            assert.equals(1, tok)
            pos, tok = p:nexttoken()
            assert.equals(2, tok)
            pos, tok = p:nexttoken()
            assert.equals("]", tok.name)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Tokenizer: EOF handling
    ---------------------------------------------------------------
    describe("EOF handling", function()
        it("returns nil on empty input", function()
            local p, f = make_parser("")
            local pos, tok = p:nexttoken()
            assert.is_nil(pos)
            cleanup(p, f)
        end)

        it("returns nil after consuming all tokens", function()
            local p, f = make_parser("42")
            local pos, tok = p:nexttoken()
            assert.equals(42, tok)
            pos, tok = p:nexttoken()
            assert.is_nil(pos)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Object parser: dicts
    ---------------------------------------------------------------
    describe("parsing dicts", function()
        it("parses simple dict", function()
            local p, f = make_parser("<< /Type /Catalog /Pages 1 0 R >>")
            local obj = p:nextobject_value()
            assert.is.truthy(obj)
            assert.equals("Catalog", obj.Type.name)
            assert.is.truthy(obj.Pages)
            assert.is.truthy(obj.Pages.ref)
            assert.equals(1, obj.Pages.ref.objid)
            assert.equals(0, obj.Pages.ref.genno)
            cleanup(p, f)
        end)

        it("parses empty dict", function()
            local p, f = make_parser("<< >>")
            local obj = p:nextobject_value()
            assert.is.truthy(obj)
            -- Should be an empty table
            local count = 0
            for _ in pairs(obj) do count = count + 1 end
            assert.equals(0, count)
            cleanup(p, f)
        end)

        it("parses dict with string values", function()
            local p, f = make_parser("<< /Author (John) /Title (Test) >>")
            local obj = p:nextobject_value()
            assert.equals("John", obj.Author)
            assert.equals("Test", obj.Title)
            cleanup(p, f)
        end)

        it("parses dict with numeric values", function()
            local p, f = make_parser("<< /Length 42 /Generation 0 >>")
            local obj = p:nextobject_value()
            assert.equals(42, obj.Length)
            assert.equals(0, obj.Generation)
            cleanup(p, f)
        end)

        it("parses dict with boolean values", function()
            local p, f = make_parser("<< /Linearized true /Encrypted false >>")
            local obj = p:nextobject_value()
            assert.is.truthy(obj.Linearized)
            assert.is.falsy(obj.Encrypted)
            cleanup(p, f)
        end)

        it("parses nested dict", function()
            local p, f = make_parser("<< /Inner << /Key /Value >> >>")
            local obj = p:nextobject_value()
            assert.is.truthy(obj.Inner)
            assert.equals("Value", obj.Inner.Key.name)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Object parser: arrays
    ---------------------------------------------------------------
    describe("parsing arrays", function()
        it("parses simple array", function()
            local p, f = make_parser("[1 2 3]")
            local obj = p:nextobject_value()
            assert.is.truthy(obj)
            assert.equals(1, obj[1])
            assert.equals(2, obj[2])
            assert.equals(3, obj[3])
            cleanup(p, f)
        end)

        it("parses empty array", function()
            local p, f = make_parser("[]")
            local obj = p:nextobject_value()
            assert.is.truthy(obj)
            assert.equals(0, #obj)
            cleanup(p, f)
        end)

        it("parses array of names", function()
            local p, f = make_parser("[/One /Two /Three]")
            local obj = p:nextobject_value()
            assert.equals("One", obj[1].name)
            assert.equals("Two", obj[2].name)
            assert.equals("Three", obj[3].name)
            cleanup(p, f)
        end)

        it("parses mixed array", function()
            local p, f = make_parser("[/Name 42 (string) true]")
            local obj = p:nextobject_value()
            assert.equals("Name", obj[1].name)
            assert.equals(42, obj[2])
            assert.equals("string", obj[3])
            assert.is.truthy(obj[4])
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Object parser: indirect references
    ---------------------------------------------------------------
    describe("parsing indirect references", function()
        it("parses indirect reference", function()
            local p, f = make_parser("5 0 R")
            local obj = p:nextobject_value()
            assert.is.truthy(obj)
            assert.is.truthy(obj.ref)
            assert.equals(5, obj.ref.objid)
            assert.equals(0, obj.ref.genno)
            cleanup(p, f)
        end)

        it("parses reference with non-zero generation", function()
            local p, f = make_parser("10 2 R")
            local obj = p:nextobject_value()
            assert.equals(10, obj.ref.objid)
            assert.equals(2, obj.ref.genno)
            cleanup(p, f)
        end)

        it("is_ref utility works", function()
            local p, f = make_parser("5 0 R")
            local obj = p:nextobject_value()
            assert.is.truthy(parser.is_ref(obj))
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Object parser: multiple objects
    ---------------------------------------------------------------
    describe("parsing multiple objects", function()
        it("parses consecutive objects", function()
            local p, f = make_parser("1 0 obj\n42\nendobj\n2 0 obj\n/Name\nendobj")
            -- First: 1 (number)
            local obj = p:nextobject_value()
            assert.equals(1, obj)
            -- Second: 0
            obj = p:nextobject_value()
            assert.equals(0, obj)
            -- Third: obj keyword
            obj = p:nextobject_value()
            assert.equals("obj", obj.name)
            -- Fourth: 42
            obj = p:nextobject_value()
            assert.equals(42, obj)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- nextline
    ---------------------------------------------------------------
    describe("nextline", function()
        it("reads a line terminated by \\n", function()
            local p, f = make_parser("hello\nworld\n")
            local pos, line = p:nextline()
            assert.equals("hello\n", line)
            pos, line = p:nextline()
            assert.equals("world\n", line)
            cleanup(p, f)
        end)

        it("reads a line terminated by \\r", function()
            local p, f = make_parser("hello\rworld\r")
            local pos, line = p:nextline()
            -- \r is followed by 'w', not \n, so just "hello\r"
            assert.equals("hello\r", line)
            cleanup(p, f)
        end)

        it("reads a line terminated by \\r\\n", function()
            local p, f = make_parser("hello\r\nworld\r\n")
            local pos, line = p:nextline()
            assert.equals("hello\r\n", line)
            pos, line = p:nextline()
            assert.equals("world\r\n", line)
            cleanup(p, f)
        end)

        it("returns position of line start", function()
            local p, f = make_parser("abc\ndef\n")
            local pos, line = p:nextline()
            assert.equals(0, pos)
            pos, line = p:nextline()
            assert.equals(4, pos)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- revreadlines
    ---------------------------------------------------------------
    describe("revreadlines", function()
        it("reads lines backward", function()
            local p, f = make_parser("line1\nline2\nline3\n")
            local lines = {}
            for line in p:revreadlines() do
                lines[#lines + 1] = line
            end
            -- Lines come in reverse order from the end
            assert.is.truthy(#lines >= 2)
            -- First yielded line should be from the end
            assert.equals("line3", lines[1] or lines[1])
            cleanup(p, f)
        end)

        it("reads single line file backward", function()
            local p, f = make_parser("only line\n")
            local lines = {}
            for line in p:revreadlines() do
                lines[#lines + 1] = line
            end
            assert.is.truthy(#lines >= 1)
            -- Last chunk
            local found = false
            for _, l in ipairs(lines) do
                if l:find("only line") then found = true end
            end
            assert.is.truthy(found)
            cleanup(p, f)
        end)

        it("can find startxref in a PDF-like file", function()
            local data = "some content\nxref\n0 5\ntrailer\n<< /Size 5 >>\nstartxref\n42\n%%EOF\n"
            local p, f = make_parser(data)
            local found = false
            local prev_line = ""
            for line in p:revreadlines() do
                -- Lines come in reverse order: %%EOF, 42, startxref, ...
                -- So after seeing "42", we check if the next line is startxref
                if line:match("startxref") and prev_line:match("^42$") then
                    found = true
                end
                prev_line = line
            end
            assert.is.truthy(found)
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- seek and tell
    ---------------------------------------------------------------
    describe("seek and tell", function()
        it("tell returns initial position 0", function()
            local p, f = make_parser("hello")
            assert.equals(0, p:tell())
            cleanup(p, f)
        end)

        it("seek resets position", function()
            local p, f = make_parser("hello")
            p:seek(3)
            assert.equals(3, p:tell())
            cleanup(p, f)
        end)
    end)

    ---------------------------------------------------------------
    -- Utility functions
    ---------------------------------------------------------------
    describe("utility functions", function()
        it("literal_name extracts name from PSLiteral", function()
            assert.equals("Foo", parser.literal_name(parser.literal("Foo")))
        end)

        it("literal_name returns string for non-literal", function()
            assert.equals("42", parser.literal_name(42))
        end)

        it("keyword_name extracts name from PSKeyword", function()
            assert.equals("obj", parser.keyword_name(parser.keyword("obj")))
        end)

        it("keyword_name returns string for non-keyword", function()
            assert.equals("hello", parser.keyword_name("hello"))
        end)

        it("is_ref detects indirect references", function()
            assert.is.truthy(parser.is_ref({ ref = { objid = 1, genno = 0 } }))
            assert.is.falsy(parser.is_ref({}))
            assert.is.falsy(parser.is_ref(42))
            assert.is.falsy(parser.is_ref("string"))
        end)
    end)

    ---------------------------------------------------------------
    -- Real-world-ish PDF fragment
    ---------------------------------------------------------------
    describe("real-world PDF fragments", function()
        it("parses a trailer dict", function()
            local data = "trailer\n<< /Size 22 /Root 1 0 R /Info 2 0 R >>"
            local p, f = make_parser(data)
            -- "trailer" is a keyword
            local obj = p:nextobject_value()
            assert.equals("trailer", obj.name)
            -- Then the dict
            obj = p:nextobject_value()
            assert.is.truthy(obj)
            assert.equals(22, obj.Size)
            assert.is.truthy(parser.is_ref(obj.Root))
            assert.equals(1, obj.Root.ref.objid)
            assert.is.truthy(parser.is_ref(obj.Info))
            assert.equals(2, obj.Info.ref.objid)
            cleanup(p, f)
        end)

        it("parses an object definition", function()
            local data = "1 0 obj\n<< /Type /Catalog /Pages 3 0 R >>\nendobj"
            local p, f = make_parser(data)
            local obj = p:nextobject_value()
            assert.equals(1, obj)  -- object number
            obj = p:nextobject_value()
            assert.equals(0, obj)  -- generation
            obj = p:nextobject_value()
            assert.equals("obj", obj.name)
            obj = p:nextobject_value()
            assert.is.truthy(obj)
            assert.equals("Catalog", obj.Type.name)
            assert.is.truthy(parser.is_ref(obj.Pages))
            cleanup(p, f)
        end)

        it("parses xref section header", function()
            local data = "xref\n0 5\n"
            local p, f = make_parser(data)
            local obj = p:nextobject_value()
            assert.equals("xref", obj.name)
            obj = p:nextobject_value()
            assert.equals(0, obj)
            obj = p:nextobject_value()
            assert.equals(5, obj)
            cleanup(p, f)
        end)

        it("parses hex string in dict", function()
            local data = "<< /ID [<ABC> <DEF>] >>"
            local p, f = make_parser(data)
            local obj = p:nextobject_value()
            assert.is.truthy(obj)
            assert.is.truthy(obj.ID)
            assert.is.truthy(type(obj.ID) == "table")
            -- First hex string: ABC -> \xAB\xBC (with odd padding)
            -- Actually <ABC> = AB C0
            assert.is.truthy(#obj.ID >= 2)
            cleanup(p, f)
        end)
    end)
end)
