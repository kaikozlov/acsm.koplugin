--- PDF tokenizer and object parser.
-- Ported from ineptpdf.py (PSBaseParser + PSStackParser).
--
-- Provides low-level tokenization of PDF streams and high-level
-- parsing of PDF objects (dicts, arrays, indirect references, etc.).
--
-- Usage:
--   local pdfparser = require("adobe.pdf.parser")
--   local p = pdfparser.new(file_handle)
--   local obj = p:nextobject()

local parser = {}

------------------------------------------------------------------------
-- PDF object types
------------------------------------------------------------------------

--- PSLiteral — PDF name object (e.g. /Type, /Length).
local PSLiteral = {}
PSLiteral.__index = PSLiteral
parser.PSLiteral = PSLiteral

function PSLiteral:__tostring()
    return "/" .. (self.name or "?")
end

--- PSKeyword — PDF keyword token (e.g. obj, endobj, stream).
local PSKeyword = {}
PSKeyword.__index = PSKeyword
parser.PSKeyword = PSKeyword

function PSKeyword:__tostring()
    return self.name or "?"
end

--- Create a PSLiteral (name object).
function parser.literal(name)
    return setmetatable({ name = name }, PSLiteral)
end

--- Create a PSKeyword (keyword token).
function parser.keyword(name)
    return setmetatable({ name = name }, PSKeyword)
end

------------------------------------------------------------------------
-- Sentinel keyword objects used for dict/array delimiters
------------------------------------------------------------------------
local KEYWORD_DICT_BEGIN = parser.keyword("<<")
local KEYWORD_DICT_END = parser.keyword(">>")

------------------------------------------------------------------------
-- Character classification helpers
------------------------------------------------------------------------

local function is_whitespace(c)
    -- PDF whitespace: NUL, TAB, LF, FF, CR, SP
    return c == 0 or c == 9 or c == 10 or c == 12 or c == 13 or c == 32
end

local function is_eol(c)
    return c == 10 or c == 13 -- \n or \r
end

local function is_digit(c)
    return c >= 48 and c <= 57 -- '0'-'9'
end

local function is_hex(c)
    return (c >= 48 and c <= 57) -- 0-9
        or (c >= 65 and c <= 70) -- A-F
        or (c >= 97 and c <= 102) -- a-f
end

local function is_alpha(c)
    return (c >= 65 and c <= 90) or (c >= 97 and c <= 122)
end

--- Check if a byte is a valid end for a name/literal token.
local function is_name_delimiter(c)
    return is_whitespace(c)
        or c == 35 -- #
        or c == 47 -- /
        or c == 37 -- %
        or c == 40
        or c == 41 -- ( )
        or c == 60
        or c == 62 -- < >
        or c == 91
        or c == 93 -- [ ]
        or c == 123
        or c == 125 -- { }
end

--- Check if a byte is a valid end for a keyword token.
local function is_keyword_delimiter(c)
    return is_name_delimiter(c)
end

------------------------------------------------------------------------
-- Hex decoding helper
------------------------------------------------------------------------

local function hex_char_to_nibble(c)
    if c >= 48 and c <= 57 then
        return c - 48
    end -- '0'-'9'
    if c >= 65 and c <= 70 then
        return c - 55
    end -- 'A'-'F'
    if c >= 97 and c <= 102 then
        return c - 87
    end -- 'a'-'f'
    return nil
end

--- Decode a hex string (sequence of hex digit bytes) into a Lua string.
local function decode_hex_string(hex_bytes)
    -- hex_bytes is a string of hex digit characters
    -- Strip whitespace, then decode pairs
    local clean = {}
    for i = 1, #hex_bytes do
        local c = string.byte(hex_bytes, i)
        if is_hex(c) then
            clean[#clean + 1] = string.char(c)
        end
    end
    local s = table.concat(clean)
    -- Pad with trailing '0' if odd length
    if #s % 2 ~= 0 then
        s = s .. "0"
    end
    local result = {}
    for i = 1, #s, 2 do
        local hi = hex_char_to_nibble(string.byte(s, i))
        local lo = hex_char_to_nibble(string.byte(s, i + 1))
        result[#result + 1] = string.char(hi * 16 + lo)
    end
    return table.concat(result)
end

------------------------------------------------------------------------
-- Octal decode helper
------------------------------------------------------------------------

------------------------------------------------------------------------
-- Escape sequence table (match byte -> result byte)
------------------------------------------------------------------------
local ESC_TABLE = {
    [98] = 8, -- \b
    [116] = 9, -- \t
    [110] = 10, -- \n
    [102] = 12, -- \f
    [114] = 13, -- \r
    [40] = 40, -- \(
    [41] = 41, -- \)
    [92] = 92, -- \\
}

------------------------------------------------------------------------
-- Buffer size for file reads
------------------------------------------------------------------------
local BUFSIZ = 4096

------------------------------------------------------------------------
-- Main parser class
------------------------------------------------------------------------

function parser.new(fp)
    local self = setmetatable({}, { __index = parser })
    self.fp = fp
    self:_do_seek(0)
    return self
end

--- Internal seek: resets all parse state.
function parser:_do_seek(pos)
    self.fp:seek("set", pos)
    self.bufpos = pos
    self.buf = ""
    self.charpos = 0
    -- Tokenizer state
    self._parse_state = "main"
    self._tokens = {}
    -- Token accumulation
    self._token = ""
    self._tokenstart = 0
    -- String parse state
    self._paren = 0
    self._oct = ""
    self._hex = ""
    -- Object parser state
    self._context = {}
    self._curtype = nil
    self._curstack = {}
    self._results = {}
end

function parser:seek(pos)
    self:_do_seek(pos)
end

function parser:tell()
    return self.bufpos + self.charpos
end

------------------------------------------------------------------------
-- Buffer management
------------------------------------------------------------------------

--- Ensure self.buf has data available at self.charpos.
-- Returns false on EOF, true on success.
function parser:_fillbuf()
    if self.charpos < #self.buf then
        return true
    end
    self.bufpos = self.fp:seek()
    local data = self.fp:read(BUFSIZ)
    if not data or #data == 0 then
        return false
    end
    self.buf = data
    self.charpos = 0
    return true
end

------------------------------------------------------------------------
-- Low-level character access
------------------------------------------------------------------------

--- Get byte at current charpos (does NOT advance).
function parser:_peekbyte()
    if self.charpos >= #self.buf then
        if not self:_fillbuf() then
            return nil
        end
    end
    return string.byte(self.buf, self.charpos + 1) -- Lua 1-indexed
end

--- Get byte at current charpos and advance by 1.
function parser:_getbyte()
    local b = self:_peekbyte()
    if b then
        self.charpos = self.charpos + 1
    end
    return b
end

--- Advance charpos past any bytes consumed by current buffer.
function parser:_advance(n)
    self.charpos = self.charpos + n
end

------------------------------------------------------------------------
-- Tokenizer: scan from buffer, producing tokens into self._tokens
------------------------------------------------------------------------

--- Main dispatcher: look at the current byte in the buffer and
-- call the appropriate parse_* method. Returns:
--   true  if a token was produced (or comment consumed)
--   false if we need more data (should refill and retry)
--   nil   on EOF
function parser:_parse_step()
    local state = self._parse_state

    if state == "main" then
        return self:_parse_main()
    elseif state == "comment" then
        return self:_parse_comment()
    elseif state == "literal" then
        return self:_parse_literal()
    elseif state == "literal_hex" then
        return self:_parse_literal_hex()
    elseif state == "number" then
        return self:_parse_number()
    elseif state == "decimal" then
        return self:_parse_decimal()
    elseif state == "keyword" then
        return self:_parse_keyword()
    elseif state == "string" then
        return self:_parse_string()
    elseif state == "string_1" then
        return self:_parse_string_1()
    elseif state == "wopen" then
        return self:_parse_wopen()
    elseif state == "wclose" then
        return self:_parse_wclose()
    elseif state == "hexstring" then
        return self:_parse_hexstring()
    else
        error("Unknown parse state: " .. tostring(state))
    end
end

------------------------------------------------------------------------
-- Parse states
------------------------------------------------------------------------

function parser:_parse_main()
    -- Skip whitespace
    while true do
        local b = self:_peekbyte()
        if b == nil then
            self._parse_state = "main"
            return nil -- EOF
        end
        if not is_whitespace(b) then
            break
        end
        self:_advance(1)
    end

    -- Save token start position
    self._tokenstart = self.bufpos + self.charpos

    local b = self:_peekbyte()
    self:_advance(1) -- consume the character

    if b == 37 then -- '%': comment
        self._token = ""
        self._parse_state = "comment"
        return false -- continue parsing
    end

    if b == 47 then -- '/': name/literal
        self._token = ""
        self._parse_state = "literal"
        return false
    end

    if b == 45 or b == 43 then -- '-' or '+': could be number start
        self._token = string.char(b)
        self._parse_state = "number"
        return false
    end

    if is_digit(b) then
        self._token = string.char(b)
        self._parse_state = "number"
        return false
    end

    if b == 46 then -- '.': decimal
        self._token = string.char(b)
        self._parse_state = "decimal"
        return false
    end

    if is_alpha(b) then
        self._token = string.char(b)
        self._parse_state = "keyword"
        return false
    end

    if b == 40 then -- '(': literal string
        self._token = ""
        self._paren = 1
        self._parse_state = "string"
        return false
    end

    if b == 60 then -- '<': hex string or dict begin
        self._token = ""
        self._parse_state = "wopen"
        return false
    end

    if b == 62 then -- '>': dict end or wclose
        self._token = ""
        self._parse_state = "wclose"
        return false
    end

    -- Single-character keywords: [ ] { }
    self:_add_token(parser.keyword(string.char(b)))
    self._parse_state = "main"
    return true
end

function parser:_parse_comment()
    while true do
        local b = self:_peekbyte()
        if b == nil then
            -- EOF in comment, just discard
            self._parse_state = "main"
            return nil
        end
        self:_advance(1)
        if is_eol(b) then
            self._parse_state = "main"
            return false -- continue to main
        end
    end
end

function parser:_parse_literal()
    while true do
        local b = self:_peekbyte()
        if b == nil then
            -- EOF: emit what we have
            self:_add_token(parser.literal(self._token))
            self._parse_state = "main"
            return nil
        end
        if b == 35 then -- '#': hex escape in name
            self:_advance(1)
            self._hex = ""
            self._parse_state = "literal_hex"
            return false
        end
        if is_name_delimiter(b) then
            -- End of name
            self:_add_token(parser.literal(self._token))
            self._parse_state = "main"
            return true
        end
        self:_advance(1)
        self._token = self._token .. string.char(b)
    end
end

function parser:_parse_literal_hex()
    while true do
        local b = self:_peekbyte()
        if b == nil then
            -- EOF: flush any pending hex
            if #self._hex > 0 then
                self._token = self._token .. string.char(tonumber(self._hex, 16))
            end
            self:_add_token(parser.literal(self._token))
            self._parse_state = "main"
            return nil
        end
        if is_hex(b) and #self._hex < 2 then
            self:_advance(1)
            self._hex = self._hex .. string.char(b)
        else
            -- End of hex pair
            if #self._hex > 0 then
                self._token = self._token .. string.char(tonumber(self._hex, 16))
            end
            self._parse_state = "literal"
            return false -- don't consume b, let literal handle it
        end
    end
end

function parser:_parse_number()
    while true do
        local b = self:_peekbyte()
        if b == nil then
            -- EOF: emit integer
            local n = tonumber(self._token)
            if n then
                self:_add_token(n)
            end
            self._parse_state = "main"
            return nil
        end
        if b == 46 then -- '.': switch to decimal
            self:_advance(1)
            self._token = self._token .. "."
            self._parse_state = "decimal"
            return false
        end
        if is_digit(b) then
            self:_advance(1)
            self._token = self._token .. string.char(b)
        else
            -- End of integer
            local n = tonumber(self._token)
            if n then
                self:_add_token(n)
            end
            self._parse_state = "main"
            return true
        end
    end
end

function parser:_parse_decimal()
    while true do
        local b = self:_peekbyte()
        if b == nil then
            -- EOF: emit decimal
            local n = tonumber(self._token)
            if n then
                self:_add_token(n)
            end
            self._parse_state = "main"
            return nil
        end
        if is_digit(b) then
            self:_advance(1)
            self._token = self._token .. string.char(b)
        else
            -- End of decimal
            local n = tonumber(self._token)
            if n then
                self:_add_token(n)
            end
            self._parse_state = "main"
            return true
        end
    end
end

function parser:_parse_keyword()
    while true do
        local b = self:_peekbyte()
        if b == nil then
            -- EOF: emit keyword
            self:_add_token(self:_make_keyword_or_bool(self._token))
            self._parse_state = "main"
            return nil
        end
        if is_keyword_delimiter(b) then
            self:_add_token(self:_make_keyword_or_bool(self._token))
            self._parse_state = "main"
            return true
        end
        self:_advance(1)
        self._token = self._token .. string.char(b)
    end
end

function parser:_make_keyword_or_bool(tok)
    if tok == "true" then
        return true
    elseif tok == "false" then
        return false
    else
        return parser.keyword(tok)
    end
end

function parser:_parse_string()
    while true do
        local b = self:_peekbyte()
        if b == nil then
            -- EOF inside string
            self:_add_token(self._token)
            self._parse_state = "main"
            return nil
        end
        self:_advance(1)
        if b == 92 then -- '\': escape
            self._oct = ""
            self._parse_state = "string_1"
            return false
        elseif b == 40 then -- '(': nested open
            self._paren = self._paren + 1
            self._token = self._token .. "("
        elseif b == 41 then -- ')': close
            self._paren = self._paren - 1
            if self._paren > 0 then
                self._token = self._token .. ")"
            else
                -- End of string
                self:_add_token(self._token)
                self._parse_state = "main"
                return true
            end
        else
            self._token = self._token .. string.char(b)
        end
    end
end

function parser:_parse_string_1()
    -- After a backslash in a string. Accumulate octal digits or handle escape.
    while true do
        local b = self:_peekbyte()
        if b == nil then
            -- Flush octal
            if #self._oct > 0 then
                self._token = self._token .. string.char(tonumber(self._oct, 8))
            end
            self:_add_token(self._token)
            self._parse_state = "main"
            return nil
        end
        -- Octal digit?
        if b >= 48 and b <= 55 and #self._oct < 3 then -- '0'-'7'
            self:_advance(1)
            self._oct = self._oct .. string.char(b)
        else
            -- Not an octal digit (or we have 3 already)
            if #self._oct > 0 then
                self._token = self._token .. string.char(tonumber(self._oct, 8))
                self._parse_state = "string"
                return false -- don't consume b
            end
            -- Named escape
            self:_advance(1)
            local esc = ESC_TABLE[b]
            if esc then
                self._token = self._token .. string.char(esc)
            end
            -- If not a known escape, the backslash is ignored (PDF spec)
            -- and the character after it is consumed
            self._parse_state = "string"
            return false
        end
    end
end

function parser:_parse_wopen()
    -- After '<': could be hex string or '<<' (dict begin)
    local b = self:_peekbyte()
    if b == nil then
        self._parse_state = "main"
        return nil
    end
    if b == 60 then -- '<': dict begin '<<'
        self:_advance(1)
        self:_add_token(KEYWORD_DICT_BEGIN)
        self._parse_state = "main"
        return true
    end
    if is_whitespace(b) or is_hex(b) then
        -- Hex string
        self._parse_state = "hexstring"
        return false
    end
    if b == 62 then -- '>': empty hex string '<>'
        self:_advance(1)
        self:_add_token("") -- empty string
        self._parse_state = "main"
        return true
    end
    -- Unexpected char after '<', go back to main.
    self._parse_state = "main"
    return false
end

function parser:_parse_wclose()
    -- After '>': must be '>' for dict end '>>'
    local b = self:_peekbyte()
    if b == 62 then -- '>': dict end '>>'
        self:_advance(1)
        self:_add_token(KEYWORD_DICT_END)
        self._parse_state = "main"
        return true
    end
    -- Single '>' without another '>' — treat as a hex string terminator
    -- that got split. Just go back to main.
    self._parse_state = "main"
    return false
end

function parser:_parse_hexstring()
    while true do
        local b = self:_peekbyte()
        if b == nil then
            -- EOF: emit what we have
            self:_add_token(decode_hex_string(self._token))
            self._parse_state = "main"
            return nil
        end
        if b == 62 then -- '>': end of hex string
            self:_advance(1)
            self:_add_token(decode_hex_string(self._token))
            self._parse_state = "main"
            return true
        end
        if is_whitespace(b) then
            self:_advance(1)
            -- skip whitespace in hex strings
        elseif is_hex(b) then
            self:_advance(1)
            self._token = self._token .. string.char(b)
        else
            -- Non-hex, non-whitespace, non-'>': skip (permissive)
            self:_advance(1)
        end
    end
end

------------------------------------------------------------------------
-- Token queue management
------------------------------------------------------------------------

function parser:_add_token(obj)
    self._tokens[#self._tokens + 1] = { self._tokenstart, obj }
end

--- Get the next token from the stream.
-- Returns: pos, token   (pos is file position, token is the object)
-- Returns: nil on EOF.
function parser:nexttoken()
    while #self._tokens == 0 do
        local ok = self:_fillbuf()
        if not ok then
            -- Buffer exhausted; try to flush any partial token
            -- by simulating EOF in the current parse state
            if self._parse_state ~= "main" then
                -- Call parse_step one more time; parse states handle
                -- _peekbyte returning nil by emitting their token
                -- We need a special approach: temporarily make _fillbuf
                -- not loop, or just directly call the parse function
                -- with an EOF signal.
                -- Easiest: set buf to empty and charpos to 0 so
                -- _peekbyte returns nil
                self.buf = ""
                self.charpos = 0
                self:_parse_step()
                if #self._tokens > 0 then
                    break
                end
            end
            return nil
        end
        local result = self:_parse_step()
        if result == nil then
            -- EOF signal from parse step
            if #self._tokens > 0 then
                break
            end
            return nil
        end
    end
    local tok = self._tokens[1]
    table.remove(self._tokens, 1)
    return tok[1], tok[2]
end

------------------------------------------------------------------------
-- Line reading
------------------------------------------------------------------------

--- Read the next line (terminated by \r or \n).
-- Returns: position, line_string (includes the line terminator)
-- Returns: nil, nil on EOF
function parser:nextline()
    local linebuf = {}
    local linepos = self.bufpos + self.charpos
    local eol = false

    while true do
        if not self:_fillbuf() then
            -- EOF
            if #linebuf > 0 then
                return linepos, table.concat(linebuf)
            end
            return nil, nil
        end

        if eol then
            -- We saw \r last time; check for \n
            if self.charpos < #self.buf then
                local c = string.byte(self.buf, self.charpos + 1)
                if c == 10 then -- \n
                    linebuf[#linebuf + 1] = "\n"
                    self.charpos = self.charpos + 1
                end
            end
            break
        end

        -- Scan for EOL in remaining buffer
        local found_eol = false
        while self.charpos < #self.buf do
            local c = string.byte(self.buf, self.charpos + 1)
            if c == 10 or c == 13 then
                linebuf[#linebuf + 1] = string.char(c)
                self.charpos = self.charpos + 1
                if c == 13 then
                    eol = true
                end
                found_eol = true
                break
            else
                linebuf[#linebuf + 1] = string.char(c)
                self.charpos = self.charpos + 1
            end
        end

        if found_eol and not eol then
            -- Found \n, done
            break
        end
        -- If eol is true, we found \r and need to check for \r\n
    end

    return linepos, table.concat(linebuf)
end

--- Iterator that reads lines backwards from the current position.
-- Yields: line_string (one line at a time, from end toward beginning).
-- Each yielded line includes the trailing \r and/or \n.
-- Used to find startxref and trailer at the end of a PDF.
function parser:revreadlines()
    self.fp:seek("end")
    local pos = self.fp:seek()
    local buf = ""

    return function()
        while true do
            -- Try to find the rightmost line ending in buf
            local split_pos = 0
            for i = #buf, 1, -1 do
                local c = string.byte(buf, i)
                if c == 13 or c == 10 then -- \r or \n
                    split_pos = i
                    break
                end
            end

            if split_pos > 0 then
                -- Line is everything after split_pos (may be empty)
                local line = buf:sub(split_pos + 1)
                -- Trim buf to just before the line ending
                buf = buf:sub(1, split_pos - 1)
                -- Only return non-empty lines (skip bare line endings)
                if #line > 0 then
                    return line
                end
                -- Otherwise continue splitting buf
            else
                -- No line ending found in buf; need more data
                if pos <= 0 then
                    -- No more file data
                    if #buf > 0 then
                        local line = buf
                        buf = ""
                        return line
                    end
                    return nil
                end

                local prevpos = pos
                pos = math.max(0, pos - BUFSIZ)
                self.fp:seek("set", pos)
                local chunk = self.fp:read(prevpos - pos)
                if not chunk or #chunk == 0 then
                    if #buf > 0 then
                        local line = buf
                        buf = ""
                        return line
                    end
                    return nil
                end
                buf = chunk .. buf
            end
        end
    end
end

------------------------------------------------------------------------
-- Object parser (PSStackParser equivalent)
------------------------------------------------------------------------

function parser:_reset()
    self._context = {}
    self._curtype = nil
    self._curstack = {}
    self._results = {}
end

function parser:seek(pos)
    self:_do_seek(pos)
end

--- Push objects onto the current stack.
local function push(self, ...)
    local args = { ... }
    for _, obj in ipairs(args) do
        self._curstack[#self._curstack + 1] = obj
    end
end

--- Pop n objects from the current stack.
--- Pop all objects from the current stack.
local function popall(self)
    local objs = self._curstack
    self._curstack = {}
    return objs
end

--- Start a new context (for array or dict).
local function start_type(self, pos, typ)
    self._context[#self._context + 1] = { pos, self._curtype, self._curstack }
    self._curtype = typ
    self._curstack = {}
end

--- End a context, returning the position and collected objects.
local function end_type(self, typ)
    if self._curtype ~= typ then
        return nil, "type mismatch: expected " .. tostring(typ) .. " got " .. tostring(self._curtype)
    end
    local objs = {}
    for _, item in ipairs(self._curstack) do
        objs[#objs + 1] = item
    end
    local ctx = self._context[#self._context]
    self._context[#self._context] = nil
    local pos = ctx[1]
    self._curtype = ctx[2]
    self._curstack = ctx[3]
    return pos, objs
end

--- Add results to the output queue.
local function add_results(self, ...)
    local args = { ... }
    for _, obj in ipairs(args) do
        self._results[#self._results + 1] = obj
    end
end

--- Check if a value is a PSLiteral.
local function is_literal(x)
    return type(x) == "table" and getmetatable(x) == PSLiteral
end

--- Check if a value is a PSKeyword.
local function is_keyword(x)
    return type(x) == "table" and getmetatable(x) == PSKeyword
end

--- Helper: iterate objects in pairs (for dict building).
local function choplist(n, seq)
    local result = {}
    local batch = {}
    for _, x in ipairs(seq) do
        batch[#batch + 1] = x
        if #batch == n then
            result[#result + 1] = batch
            batch = {}
        end
    end
    return result
end

--- Parse the next complete PDF object from the stream.
-- Returns: {pos, value} where value is one of:
--   - number (integer or float)
--   - string
--   - PSLiteral (name)
--   - PSKeyword (keyword)
--   - table (array: integer keys)
--   - table (dict: string keys)
--   - {ref={objid=N, genno=N}} for indirect references
--   - true/false
-- Returns nil on EOF.
function parser:nextobject()
    while #self._results == 0 do
        local pos, token = self:nexttoken()
        if pos == nil then
            -- EOF: flush any remaining stack items
            if #self._curstack > 0 and #self._context == 0 then
                local all = popall(self)
                for _, item in ipairs(all) do
                    add_results(self, item)
                end
                break
            end
            return nil
        end

        local t = type(token)

        if t == "number" or t == "boolean" or t == "string" or is_literal(token) then
            push(self, { pos, token })
        elseif is_keyword(token) then
            local kw_name = token.name
            if kw_name == "[" then
                start_type(self, pos, "a")
            elseif kw_name == "]" then
                pcall(function()
                    local epos, objs = end_type(self, "a")
                    if not epos then
                        error("array context mismatch")
                    end
                    -- objs are {pos, value} tuples; unwrap values
                    local arr = {}
                    for _, item in ipairs(objs) do
                        arr[#arr + 1] = item[2]
                    end
                    if #self._context == 0 then
                        add_results(self, { epos, arr })
                    else
                        push(self, { epos, arr })
                    end
                end)
            elseif kw_name == "<<" then
                start_type(self, pos, "d")
            elseif kw_name == ">>" then
                pcall(function()
                    local epos, objs = end_type(self, "d")
                    if not epos then
                        error("dictionary context mismatch")
                    end
                    -- objs are {pos, value} tuples; unwrap values
                    local unwrapped = {}
                    for _, item in ipairs(objs) do
                        unwrapped[#unwrapped + 1] = item[2]
                    end
                    -- Build dict from key-value pairs
                    local d = {}
                    local pairs_list = choplist(2, unwrapped)
                    for _, kv in ipairs(pairs_list) do
                        local k, v = kv[1], kv[2]
                        -- Keys should be PSLiterals; use their name
                        local key
                        if is_literal(k) then
                            key = k.name
                        else
                            key = tostring(k)
                        end
                        d[key] = v
                    end
                    if #self._context == 0 then
                        -- Top level: peek next token to detect stream object.
                        -- This handles "<<...>> stream" sequence at top level
                        -- where the dict would otherwise be returned standalone.
                        local peek_pos, peek_tok = self:nexttoken()
                        if peek_pos and is_keyword(peek_tok) and peek_tok.name == "stream" then
                            -- It's a stream! Read raw data per /Length.
                            local objlen = 0
                            if type(d.Length) == "number" then
                                objlen = d.Length
                            end

                            -- Seek to the 'stream' keyword position and skip past EOL
                            self.fp:seek("set", peek_pos)
                            local stream_header = self.fp:read(256) or ""
                            local eol_offset = stream_header:find("[\r\n]", 1)
                            if eol_offset then
                                local after_eol
                                if stream_header:byte(eol_offset) == 13 then -- \r
                                    after_eol = eol_offset + 1
                                    if after_eol <= #stream_header and stream_header:byte(after_eol) == 10 then
                                        after_eol = after_eol + 1 -- \r\n
                                    end
                                else
                                    after_eol = eol_offset + 1 -- \n
                                end
                                local data_start = peek_pos + after_eol - 1
                                self.fp:seek("set", data_start)
                                local data = self.fp:read(objlen) or ""

                                local stream = {
                                    dic = d,
                                    rawdata = data,
                                    data = nil,
                                    decdata = nil,
                                    decdic = nil,
                                    objid = 0,
                                    genno = 0,
                                }

                                -- Reset parser state to after the stream data
                                local resume_pos = data_start + objlen
                                self.bufpos = resume_pos
                                self.buf = ""
                                self.charpos = 0
                                self._parse_state = "main"
                                self._tokens = {}
                                self.fp:seek("set", resume_pos)

                                add_results(self, { epos, stream })
                                return
                            end
                        end
                        -- Not a stream: put the peeked token back and add dict to results
                        if peek_pos then
                            table.insert(self._tokens, 1, { peek_pos, peek_tok })
                        end
                        add_results(self, { epos, d })
                    else
                        push(self, { epos, d })
                    end
                end)
            else
                -- Other keyword: check for indirect reference (N N R)
                -- or push onto stack
                self:_do_keyword(pos, token)
            end
        end
    end

    local obj = self._results[1]
    table.remove(self._results, 1)
    return obj
end

--- Check if a value is a dict (table with string keys, not a ref/stream/etc).
local function is_dict_obj(x)
    if type(x) ~= "table" then
        return false
    end
    if x.ref then
        return false
    end
    -- Check for string keys
    for k, _ in pairs(x) do
        if type(k) == "string" then
            return true
        end
    end
    return false
end

--- Handle keywords in the object parser.
-- Handles: 'R' (indirect ref), 'stream' (stream data), 'endobj', 'obj'.
-- Ported from ineptpdf.py PDFParser.do_keyword.
function parser:_do_keyword(pos, token)
    local kw = token.name

    -- Indirect reference: N N R
    if kw == "R" then
        local stack = self._curstack
        if #stack >= 2 then
            local gen = stack[#stack]
            local objid = stack[#stack - 1]
            if type(objid) == "table" and type(objid[2]) == "number" and type(gen) == "table" and type(gen[2]) == "number" then
                stack[#stack] = nil
                stack[#stack] = nil
                local ref = { pos, { ref = { objid = objid[2], genno = gen[2] } } }
                if #self._context == 0 then
                    add_results(self, ref)
                else
                    push(self, ref)
                end
                return
            end
        end
    end

    -- Stream object: dict followed by 'stream' keyword
    -- This is the critical integration point from ineptpdf.py
    if kw == "stream" then
        local stack = self._curstack
        if #stack >= 1 then
            local entry = stack[#stack]
            if type(entry) == "table" and type(entry[2]) == "table" and is_dict_obj(entry[2]) then
                stack[#stack] = nil -- pop the dict
                local dic = entry[2]
                local objlen = 0
                if dic.Length ~= nil and type(dic.Length) == "number" then
                    objlen = dic.Length
                elseif dic["length"] ~= nil and type(dic["length"]) == "number" then
                    objlen = dic["length"]
                end

                -- Seek back to the 'stream' keyword position and read raw data
                self.fp:seek("set", pos)
                -- Read past the 'stream' keyword and its EOL
                local stream_header = self.fp:read(256) or ""
                -- Find end of 'stream' keyword + line ending
                local header_end = stream_header:find("[\r\n]", 1)
                if header_end then
                    -- Skip past the line ending
                    local after_eol
                    if stream_header:byte(header_end) == 13 then -- \r
                        after_eol = header_end + 1
                        if after_eol <= #stream_header and stream_header:byte(after_eol) == 10 then
                            after_eol = after_eol + 1 -- \r\n
                        end
                    else
                        after_eol = header_end + 1 -- \n
                    end
                    local data_start = pos + after_eol - 1
                    self.fp:seek("set", data_start)
                    local data = self.fp:read(objlen)

                    -- Check for endstream after data
                    if data then
                        -- Create stream object
                        local stream = {
                            dic = dic,
                            rawdata = data,
                            data = nil,
                            decdata = nil,
                            decdic = nil,
                            objid = 0,
                            genno = 0,
                        }
                        -- Seek past endstream for parser continuity
                        self.fp:seek("set", data_start + objlen)
                        -- Re-initialize parser buffer state after manual fp:seek
                        self.bufpos = data_start + objlen
                        self.buf = ""
                        self.charpos = 0
                        self._parse_state = "main"
                        self._tokens = {}

                        if #self._context == 0 then
                            add_results(self, { pos, stream })
                        else
                            push(self, { pos, stream })
                        end
                        return
                    end
                end
                -- Failed to read stream data; fall through and push keyword
                push(self, { pos, dic }) -- put dict back
            end
        end
    end

    -- For other keywords, just push onto stack
    if #self._context == 0 then
        -- At top level, any keyword triggers a flush of preceding
        -- stack items as results, then the keyword itself
        if #self._curstack > 0 then
            local all = popall(self)
            for _, item in ipairs(all) do
                add_results(self, item)
            end
        end
        add_results(self, { pos, token })
    else
        push(self, { pos, token })
    end
end

--- Convenience: parse next object, unwrapping the (pos, obj) pair.
-- Returns just the object, or nil on EOF.
function parser:nextobject_value()
    local result = self:nextobject()
    if result == nil then
        return nil
    end
    return result[2]
end

------------------------------------------------------------------------
-- Utility: check if a table is a PDF stream object
------------------------------------------------------------------------
function parser.is_stream(obj)
    return type(obj) == "table" and obj.dic ~= nil and obj.rawdata ~= nil and not obj.ref
end

------------------------------------------------------------------------
-- Utility: check if a table is an indirect reference
------------------------------------------------------------------------
function parser.is_ref(obj)
    return type(obj) == "table" and obj.ref ~= nil
end

------------------------------------------------------------------------
-- Utility: check if a table is a dict object (not stream, not ref)
------------------------------------------------------------------------
function parser.is_dict(obj)
    return type(obj) == "table" and not obj.ref and obj.dic == nil
end

------------------------------------------------------------------------
-- Utility: get literal name from a PSLiteral
------------------------------------------------------------------------
function parser.literal_name(x)
    if is_literal(x) then
        return x.name
    end
    return tostring(x)
end

------------------------------------------------------------------------
-- Utility: get keyword name from a PSKeyword
------------------------------------------------------------------------
function parser.keyword_name(x)
    if is_keyword(x) then
        return x.name
    end
    return tostring(x)
end

return parser
