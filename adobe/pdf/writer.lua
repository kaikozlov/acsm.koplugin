--- PDF serializer / clean writer.
-- Ported from ineptpdf.py PDFSerializer (lines 2141-2350).
--
-- Writes a clean unencrypted PDF from parsed objects.
-- All objects are assumed to already be decrypted.

local writer = {}

local ok, pdfparser = pcall(require, "adobe.pdf.parser")
if not ok then
    pdfparser = nil
end

------------------------------------------------------------------------
-- Internal helpers
------------------------------------------------------------------------

--- Escape a string for PDF literal-string output (parenthesized).
-- Escapes: backslash, parens, newline, CR, and control chars as octal.
local function escapeString(s)
    local parts = {}
    for i = 1, #s do
        local c = s:byte(i)
        if c == 92 then
            parts[#parts + 1] = "\\\\"
        elseif c == 40 then
            parts[#parts + 1] = "\\("
        elseif c == 41 then
            parts[#parts + 1] = "\\)"
        elseif c == 10 then
            parts[#parts + 1] = "\\n"
        elseif c == 13 then
            parts[#parts + 1] = "\\r"
        elseif c < 32 or c == 127 then
            parts[#parts + 1] = string.format("\\%03o", c)
        else
            parts[#parts + 1] = string.char(c)
        end
    end
    return table.concat(parts)
end

--- Serialize a PDF name to /Name with #XX hex escaping for special chars.
local function serializeName(name)
    local parts = { "/" }
    for i = 1, #name do
        local c = name:byte(i)
        if (c >= 65 and c <= 90) or (c >= 97 and c <= 122) or
           (c >= 48 and c <= 57) or c == 95 or c == 45 or c == 46 then
            parts[#parts + 1] = string.char(c)
        else
            parts[#parts + 1] = string.format("#%02X", c)
        end
    end
    return table.concat(parts)
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
-- Public API
------------------------------------------------------------------------

--- Serialize a PDF object to a string.
-- Handles: numbers, booleans, strings, names (PSLiteral or {name=...}),
-- keywords (PSKeyword or {keyword=...}), arrays, dicts, streams,
-- and indirect references.
-- Streams use get_decdata()/get_decdic() matching ineptpdf.py PDFSerializer.
-- @param obj the PDF object
-- @return string serialized representation
function writer.serializeObject(obj)
    local t = type(obj)

    if t == "number" then
        if obj == math.floor(obj) and math.abs(obj) < 2^53 then
            return tostring(math.floor(obj))
        end
        -- Use enough precision to round-trip a Lua double (64-bit float)
        -- without losing digits. "%.14g" gives ~15 significant figures which
        -- is the full precision of double-precision floating point.
        local s = string.format("%.14g", obj)
        -- Ensure the output looks like a PDF number, not scientific notation
        if s:find("e") or s:find("E") then
            s = string.format("%.14f", obj)
            s = s:gsub("0+$", "")
            s = s:gsub("%.$", "")
        end
        -- Strip unnecessary trailing zeros for cleanliness
        if s:find("%.") then
            s = s:gsub("0+$", "")
            s = s:gsub("%.$", "")
        end
 return s

    elseif t == "boolean" then
        return obj and "true" or "false"

    elseif t == "string" then
        return "(" .. escapeString(obj) .. ")"

    elseif t == "table" then
        -- 1. Indirect reference: { ref = { objid=N, genno=N } }
        if obj.ref then
            return string.format("%d %d R", obj.ref.objid, obj.ref.genno)
        end

        -- 2. PDFStream: use get_decdata() + get_decdic() like ineptpdf.py
        if obj.dic ~= nil and obj.rawdata ~= nil then
            local data = obj.get_decdata and obj:get_decdata() or obj.rawdata
            local dic = obj.get_decdic and obj:get_decdic() or obj.dic
            -- Update /Length to match actual decrypted data
            if type(dic) == "table" then
                dic.Length = #data
            end
            local s = writer.serializeObject(dic)
            s = s .. "\nstream\n" .. data .. "\nendstream"
            return s
        end

        -- Fallback: stream with explicit stream_data field (old API)
        if obj.stream_data ~= nil then
            local data = obj.stream_data
            local dict = obj.dict or {}
            dict.Length = #data
            local s = writer.serializeObject(dict)
            s = s .. "\nstream\n" .. data .. "\nendstream"
            return s
        end

        -- 3. Name (PSLiteral metatable from parser)
        if pdfparser and getmetatable(obj) == pdfparser.PSLiteral then
            return serializeName(obj.name)
        end

        -- 4. Keyword (PSKeyword metatable from parser)
        if pdfparser and getmetatable(obj) == pdfparser.PSKeyword then
            return obj.name
        end

        -- 5. Fallback name: plain table with ONLY a 'name' field (for tests)
        if type(obj.name) == "string" then
            local n = 0
            for _ in pairs(obj) do n = n + 1 end
            if n == 1 then
                return serializeName(obj.name)
            end
        end

        -- 6. Fallback keyword: plain table with ONLY a 'keyword' field
        if type(obj.keyword) == "string" then
            local n = 0
            for _ in pairs(obj) do n = n + 1 end
            if n == 1 then
                return obj.keyword
            end
        end

        -- 7. Dict (has string keys) or Array (has only integer keys)
        if isDict(obj) then
            -- Correct malformed Mac OS resource fork metadata
            -- (matches ineptpdf.py PDFSerializer.serialize_object):
            -- If dict has /ResFork + /Type (integer) but no /Subtype,
            -- rename /Type → /Subtype.
            if obj.ResFork ~= nil and obj.Type ~= nil
                    and obj.Subtype == nil and type(obj.Type) == "number" then
                obj.Subtype = obj.Type
                obj.Type = nil
            end
            -- Sort dict keys for deterministic output
            local keys = {}
            for k, _ in pairs(obj) do
                if type(k) == "string" then
                    keys[#keys + 1] = k
                end
            end
            table.sort(keys)
            local parts = {}
            for _, k in ipairs(keys) do
                parts[#parts + 1] = serializeName(k) .. " " .. writer.serializeObject(obj[k])
            end
            return "<<" .. table.concat(parts) .. ">>"
        else
            local parts = {}
            for i = 1, #obj do
                parts[i] = writer.serializeObject(obj[i])
            end
            return "[" .. table.concat(parts, " ") .. "]"
        end
    end

    -- Fallback for nil or unexpected types
    return tostring(obj)
end

--- Write a clean unencrypted PDF.
-- @param inPath string path to the source PDF (unused, kept for API compat)
-- @param outPath string path to write the output
-- @param doc table document info with:
--   doc.version  - PDF version string (e.g. "%%PDF-1.6")
--   doc.trailer  - trailer dict
--   doc.xref_entries - table (will be filled with objid -> {offset,genno})
--   doc.objects  - table mapping objid -> parsed object
-- @param encrypt_objid number|nil objid of the /Encrypt dictionary to skip
function writer.writeCleanPdf(inPath, outPath, doc, encrypt_objid)
    local out, err = io.open(outPath, "wb")
    if not out then
        error("Cannot open output file: " .. outPath .. ": " .. tostring(err))
    end

    -- Write header: version line + binary comment (4 high bytes > 128)
    out:write(doc.version)
    out:write("\n%\xe2\xe3\xcf\xd3\n")

    -- Collect and sort object IDs, excluding the Encrypt dict
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

    -- Write each object as an indirect object; record byte offsets for xref
    local xrefs = {}

    -- Reset xref_entries if caller provided the table
    if doc.xref_entries then
        for k, _ in pairs(doc.xref_entries) do
            doc.xref_entries[k] = nil
        end
    end

    -- Track last byte written so we can decide whether to emit \n
    -- before endobj (can't read back from a "wb" file handle).
    local lastByte = "\n"

    --- Write helper that tracks last byte.
    local function emit(s)
        if #s > 0 then
            out:write(s)
            lastByte = s:sub(-1)
        end
    end

    for _, objid in ipairs(objids) do
        local obj = doc.objects[objid]
        local offset = out:seek()
        xrefs[objid] = offset

        if doc.xref_entries then
            doc.xref_entries[objid] = { offset = offset, genno = 0 }
        end

        -- Write "N 0 obj" (no trailing newline — matches ineptpdf.py)
        emit(string.format("%d 0 obj", objid))

        -- Write the object body
        if type(obj) == "table" and obj.dic ~= nil and obj.rawdata ~= nil then
            -- PDFStream: use get_decdata()/get_decdic() like ineptpdf.py
            local data = obj.get_decdata and obj:get_decdata() or obj.rawdata
            local dic = obj.get_decdic and obj:get_decdic() or obj.dic
            -- Update /Length to match actual decrypted data
            if type(dic) == "table" then
                dic.Length = #data
            end
            emit(writer.serializeObject(dic))
            emit("stream\n")
            emit(data)
            emit("\nendstream")
        elseif type(obj) == "table" and obj.stream_data ~= nil then
            -- Legacy stream API
            local data = obj.stream_data
            local dict = obj.dict or {}
            dict.Length = #data
            emit(writer.serializeObject(dict))
            emit("stream\n")
            emit(data)
            emit("\nendstream")
        else
            emit(writer.serializeObject(obj))
        end

        -- Conditional newline before endobj (matches ineptpdf.py):
        -- only emit \n if last written byte was alphanumeric
        if lastByte:match("%w") then
            emit("\n")
        end
        emit("endobj\n")
    end

    -- Cross-reference table
    local startxref = out:seek()
    out:write("xref\n")
    out:write(string.format("0 %d\n", size))

    -- Entry 0 is always the free head
    out:write("0000000000 65535 f \n")

    -- Entries 1..maxobj
    for objid = 1, maxobj do
        if xrefs[objid] then
            out:write(string.format("%010d 00000 n \n", xrefs[objid]))
        else
            out:write("0000000000 65535 f \n")
        end
    end

    -- Trailer: strip /Encrypt, set /Size
    local trailer = {}
    for k, v in pairs(doc.trailer) do
        if k ~= "Encrypt" then
            trailer[k] = v
        end
    end
    trailer.Size = size

    out:write("trailer\n")
    out:write(writer.serializeObject(trailer))
    out:write(string.format("\nstartxref\n%d\n%%%%EOF\n", startxref))

    out:close()
end

return writer
