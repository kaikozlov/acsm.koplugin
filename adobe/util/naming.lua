--- Lightweight filename sanitization utilities for book titles.

local naming = {}

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

    -- Limit length to 200 bytes but avoid splitting a multi-byte UTF-8 sequence
    if #safe > 200 then
        safe = safe:sub(1, 200)
        -- A trailing continuation byte (10xxxxxx) means we split a multi-byte char.
        -- Remove bytes until the leading byte is gone too.
        while #safe > 0 and safe:byte(#safe) >= 0x80 and safe:byte(#safe) <= 0xBF do
            safe = safe:sub(1, #safe - 1)
        end
        -- If the last byte is now a multi-byte lead byte (11xxxxxx) with no
        -- continuation bytes following it, remove that too.
        if #safe > 0 and safe:byte(#safe) >= 0xC0 then
            safe = safe:sub(1, #safe - 1)
        end
        -- Truncate at the last space to avoid mid-word cuts
        local last_space = safe:match(".*() ")
        if last_space then
            safe = safe:sub(1, last_space - 1)
        end
    end

    if safe == "" then
        return nil
    end

    return safe
end

return naming
