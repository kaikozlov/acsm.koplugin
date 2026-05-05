--- Lightweight EPUB naming utilities.
-- Extracts book titles from EPUB metadata and sanitizes them for use as filenames.
-- No heavy dependencies — only needs a zip-reader object to inspect EPUBs.

local naming = {}

--- Extract the dc:title from an EPUB file's OPF metadata.
-- Reads container.xml to find the OPF path, then parses the OPF for dc:title.
-- @param reader a zip-reader object with :open(path)->bool, :extractToMemory(entry)->string, :close()
-- @string epub_path path to the EPUB file
-- @treturn string title, or nil if not found
-- @treturn string error message on failure
function naming.extractTitle(reader, epub_path)
    if not reader:open(epub_path) then
        return nil, reader.err or "Could not open EPUB"
    end

    -- Step 1: read container.xml to find the OPF path
    local container_xml = reader:extractToMemory("META-INF/container.xml")
    if not container_xml then
        reader:close()
        return nil, "Missing META-INF/container.xml"
    end

    local opf_path = container_xml:match('full%-path="([^"]+)"')
    if not opf_path then
        reader:close()
        return nil, "No rootfile in container.xml"
    end

    -- Step 2: read the OPF and extract dc:title
    local opf_xml = reader:extractToMemory(opf_path)
    reader:close()
    if not opf_xml then
        return nil, "Could not read OPF: " .. opf_path
    end

    local title = opf_xml:match("<dc:title[^>]*>([^<]+)</dc:title>")
    if not title then
        return nil, "No dc:title in OPF metadata"
    end

    -- Trim whitespace
    title = title:match("^%s*(.-)%s*$")
    if title == "" then
        return nil, "Empty dc:title"
    end

    return title
end

--- Sanitize a book title into a safe filename.
-- Replaces filesystem-unsafe characters, collapses whitespace, trims.
-- @string title the raw title string
-- @treturn string sanitized filename-safe string, or nil if nothing remains
function naming.sanitizeTitle(title)
    if not title or title == "" then
        return nil
    end

    -- Replace characters that are unsafe in filenames: / \ : * ? " < > |
    local safe = title:gsub('[/\\:*?"<>|]', " ")

    -- Collapse multiple spaces into one
    safe = safe:gsub("%s+", " ")

    -- Trim leading/trailing whitespace and dots (dots at start are hidden files on unix)
    safe = safe:match("^[%.%s]*(.-)[%.%s]*$")

    -- Limit length to 200 chars (generous but avoids filesystem limits)
    if #safe > 200 then
        safe = safe:sub(1, 200):match("^(.-)%s*$")
    end

    if safe == "" then
        return nil
    end

    return safe
end

return naming
