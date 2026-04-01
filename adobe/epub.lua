local epub = {}

local xml2lua = require("xml2lua")
local domhandler = require("xmlhandler.dom")
local zlib = require("adobe.util.zlib")
local nativecrypto = require("adobe.util.nativecrypto")
local hasArchiver, Archiver = pcall(require, "ffi/archiver")
local hasLfs, lfs = pcall(require, "libs/libkoreader-lfs")

local XMLENC = "http://www.w3.org/2001/04/xmlenc#"
local AES128_CBC = "http://www.w3.org/2001/04/xmlenc#aes128-cbc"
local AES128_CBC_UNCOMPRESSED = "http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed"

local function shellQuote(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local data = f:read("*a")
    f:close()
    return data
end

local function writeFile(path, data)
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
end

local function ensureDir(path)
    if path == nil or path == "" then
        return true
    end
    if hasLfs then
        local current = ""
        if path:sub(1, 1) == "/" then
            current = "/"
        end
        for part in path:gmatch("[^/]+") do
            if current == "" or current == "/" then
                current = current .. part
            else
                current = current .. "/" .. part
            end
            if lfs.attributes(current, "mode") ~= "directory" then
                local ok, err = lfs.mkdir(current)
                if not ok and lfs.attributes(current, "mode") ~= "directory" then
                    return nil, err or ("Could not create directory " .. current)
                end
            end
        end
        return true
    end
    local ok = os.execute("mkdir -p " .. shellQuote(path))
    if not ok then
        return nil, "Could not create directory " .. path
    end
    return true
end

local function removeTree(path)
    if not path or path == "" then
        return
    end
    if hasLfs and lfs.attributes(path, "mode") == "directory" then
        for entry in lfs.dir(path) do
            if entry ~= "." and entry ~= ".." then
                local child = path .. "/" .. entry
                local mode = lfs.attributes(child, "mode")
                if mode == "directory" then
                    removeTree(child)
                else
                    os.remove(child)
                end
            end
        end
        lfs.rmdir(path)
        return
    end
    os.execute("rm -rf " .. shellQuote(path))
end

local function parseXmlDom(xmlString)
    local handler = domhandler:new()
    handler.options.commentNode = 0
    handler.options.piNode = 0
    handler.options.dtdNode = 0
    handler.options.declNode = 0
    local parser = xml2lua.parser(handler)
    parser:parse(xmlString)
    return handler.root
end

local function nsMapFor(node, nsMap)
    local childNsMap = {}
    for k, v in pairs(nsMap or {}) do
        childNsMap[k] = v
    end
    for ak, av in pairs(node._attr or {}) do
        if ak == "xmlns" then
            childNsMap[""] = av
        else
            local prefix = ak:match("^xmlns:(.+)$")
            if prefix then
                childNsMap[prefix] = av
            end
        end
    end
    return childNsMap
end

local function resolveNodeName(node, nsMap)
    local ownNs = node._attr and node._attr.xmlns or nil
    local prefix, localname = node._name:match("^(.-):(.+)$")
    if prefix then
        return nsMap[prefix] or "", localname
    end
    return ownNs or nsMap[""] or "", node._name
end

local function firstElement(node, nsMap, localname, namespace)
    for _, child in ipairs(node._children or {}) do
        if child._type == "ELEMENT" then
            local childNsMap = nsMapFor(child, nsMap)
            local childNs, childName = resolveNodeName(child, nsMap)
            if childName == localname and (namespace == nil or childNs == namespace) then
                return child, childNsMap
            end
        end
    end
    return nil, nil
end

local function textOf(node)
    local parts = {}
    for _, child in ipairs(node._children or {}) do
        if child._type == "TEXT" then
            local trimmed = child._text and child._text:match("^%s*(.-)%s*$") or ""
            if trimmed ~= "" then
                parts[#parts + 1] = trimmed
            end
        end
    end
    return table.concat(parts)
end

local function xmlEscape(s)
    return (tostring(s)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

local function serializeNode(node)
    local attrs = {}
    for ak, av in pairs(node._attr or {}) do
        attrs[#attrs + 1] = { ak, av }
    end
    table.sort(attrs, function(a, b) return a[1] < b[1] end)

    local parts = { "<" .. node._name }
    for _, attr in ipairs(attrs) do
        parts[#parts + 1] = " " .. attr[1] .. '="' .. xmlEscape(attr[2]) .. '"'
    end

    if not node._children or #node._children == 0 then
        parts[#parts + 1] = "/>"
        return table.concat(parts)
    end

    parts[#parts + 1] = ">"
    for _, child in ipairs(node._children) do
        if child._type == "TEXT" then
            parts[#parts + 1] = xmlEscape(child._text or "")
        elseif child._type == "ELEMENT" then
            parts[#parts + 1] = serializeNode(child)
        end
    end
    parts[#parts + 1] = "</" .. node._name .. ">"
    return table.concat(parts)
end

local function parseEncryptionXml(encryptionXml)
    local root = parseXmlDom(encryptionXml)
    local rootNsMap = nsMapFor(root, { [""] = "urn:oasis:names:tc:opendocument:xmlns:container" })

    local encrypted = {}
    local encryptedForceNoDecomp = {}
    local remainingEncryptedData = 0
    local keptChildren = {}

    for _, child in ipairs(root._children or {}) do
        if child._type ~= "ELEMENT" then
            keptChildren[#keptChildren + 1] = child
        else
            local childNsMap = nsMapFor(child, rootNsMap)
            local childNs, childName = resolveNodeName(child, rootNsMap)
            if childNs == XMLENC and childName == "EncryptedData" then
                local methodNode = firstElement(child, childNsMap, "EncryptionMethod", XMLENC)
                local cipherDataNode, cipherDataNsMap = firstElement(child, childNsMap, "CipherData", XMLENC)
                local cipherRefNode = cipherDataNode and firstElement(cipherDataNode, cipherDataNsMap, "CipherReference", XMLENC)

                local algorithm = methodNode and methodNode._attr and methodNode._attr.Algorithm or nil
                local uri = cipherRefNode and cipherRefNode._attr and cipherRefNode._attr.URI or nil

                if uri and algorithm == AES128_CBC then
                    encrypted[uri] = true
                elseif uri and algorithm == AES128_CBC_UNCOMPRESSED then
                    encryptedForceNoDecomp[uri] = true
                else
                    keptChildren[#keptChildren + 1] = child
                    remainingEncryptedData = remainingEncryptedData + 1
                end
            else
                keptChildren[#keptChildren + 1] = child
            end
        end
    end

    root._children = keptChildren

    local rewrittenXml = nil
    if remainingEncryptedData > 0 then
        rewrittenXml = '<?xml version="1.0" encoding="UTF-8"?>\n' .. serializeNode(root)
    end

    return {
        encrypted = encrypted,
        encryptedForceNoDecomp = encryptedForceNoDecomp,
        rewrittenXml = rewrittenXml,
    }
end

local function stripPkcs7(data)
    local pad = data:byte(-1)
    if not pad or pad < 1 or pad > 16 then
        return nil, "Invalid PKCS#7 padding"
    end
    return data:sub(1, #data - pad)
end

local function decryptAdeptEntry(data, bookKey, noDecomp)
    local decrypted, err = nativecrypto.aes_cbc_decrypt(bookKey, string.rep("\0", 16), data, true)
    if err then
        return nil, err
    end
    decrypted = decrypted:sub(17)

    decrypted, err = stripPkcs7(decrypted)
    if not decrypted then
        return nil, err
    end

    if not noDecomp then
        local inflated, inflateErr = zlib.inflateRaw(decrypted)
        if not inflated then
            inflated = decrypted
        end
        decrypted = inflated
    end

    return decrypted
end

local function makeTempDir()
    local tmpDir = os.tmpname()
    os.remove(tmpDir)
    local ok, err = ensureDir(tmpDir)
    assert(ok, err)
    return tmpDir
end

local function listFiles(workDir)
    local files = {}

    if hasLfs then
        local function walk(dir, relBase)
            for entry in lfs.dir(dir) do
                if entry ~= "." and entry ~= ".." then
                    local fullPath = dir .. "/" .. entry
                    local relPath = relBase ~= "" and (relBase .. "/" .. entry) or entry
                    local mode = lfs.attributes(fullPath, "mode")
                    if mode == "directory" then
                        walk(fullPath, relPath)
                    elseif mode == "file" then
                        files[#files + 1] = relPath
                    end
                end
            end
        end
        walk(workDir, "")
    else
        local pipe = io.popen(
            "find " .. shellQuote(workDir) .. " -type f -print | LC_ALL=C sort",
            "r"
        )
        if not pipe then
            return nil, "Could not enumerate EPUB files"
        end
        for fullPath in pipe:lines() do
            files[#files + 1] = fullPath:sub(#workDir + 2)
        end
        pipe:close()
    end

    table.sort(files)
    return files
end

local function repackEpubWithArchiver(workDir, outputPath)
    local writer = Archiver.Writer:new{}
    if not writer:open(outputPath, "epub") then
        return nil, writer.err or "Could not open EPUB writer"
    end

    local mtime = os.time()
    local mimetype = readFile(workDir .. "/mimetype")
    if not mimetype then
        writer:close()
        return nil, "Missing mimetype"
    end

    writer:setZipCompression("store")
    if not writer:addFileFromMemory("mimetype", mimetype, mtime) then
        writer:close()
        return nil, writer.err or "Could not write mimetype"
    end

    writer:setZipCompression("deflate")
    local files, listErr = listFiles(workDir)
    if not files then
        writer:close()
        return nil, listErr
    end

    for _, relPath in ipairs(files) do
        if relPath ~= "mimetype" then
            local fullPath = workDir .. "/" .. relPath
            local content = readFile(fullPath)
            if not content then
                writer:close()
                return nil, "Missing repack input: " .. relPath
            end
            if not writer:addFileFromMemory(relPath, content, mtime) then
                writer:close()
                return nil, writer.err or ("Could not write " .. relPath)
            end
        end
    end

    writer:close()
    return true
end

local function repackEpub(workDir, outputPath)
    os.remove(outputPath)
    if hasArchiver then
        local ok, err = repackEpubWithArchiver(workDir, outputPath)
        if ok then
            return true
        end
        return nil, err
    end

    local ok = os.execute(
        "cd " .. shellQuote(workDir)
        .. " && zip -X0q " .. shellQuote(outputPath) .. " mimetype"
        .. " && find . -type f ! -name mimetype -print | LC_ALL=C sort | sed 's#^\\./##' | zip -X9qD " .. shellQuote(outputPath) .. " -@"
    )
    if not ok then
        return nil, "zip failed"
    end
    return true
end

local function extractEpubWithArchiver(inputPath, workDir)
    local reader = Archiver.Reader:new()
    if not reader:open(inputPath) then
        return nil, reader.err or "Could not open EPUB archive"
    end

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local fullPath = workDir .. "/" .. entry.path
            local parent = fullPath:match("^(.*)/[^/]+$")
            if parent and parent ~= "" then
                local ok, err = ensureDir(parent)
                if not ok then
                    reader:close()
                    return nil, err
                end
            end
            local content = reader:extractToMemory(entry.path)
            if content == nil then
                reader:close()
                return nil, reader.err or ("Could not extract " .. entry.path)
            end
            writeFile(fullPath, content)
        end
    end

    reader:close()
    return true
end

local function stripAdeptWatermarksFromText(text)
    local stripped = text
    local total = 0
    local patterns = {
        '<meta%s+name="Adept%.resource"%s+content="urn:uuid:[0-9a-fA-F%-]+"%s*/>',
        '<meta%s+name="Adept%.resource"%s+value="urn:uuid:[0-9a-fA-F%-]+"%s*/>',
        '<meta%s+content="urn:uuid:[0-9a-fA-F%-]+"%s+name="Adept%.resource"%s*/>',
        '<meta%s+value="urn:uuid:[0-9a-fA-F%-]+"%s+name="Adept%.resource"%s*/>',
        '<meta%s+name="Adept%.expected%.resource"%s+content="urn:uuid:[0-9a-fA-F%-]+"%s*/>',
        '<meta%s+name="Adept%.expected%.resource"%s+value="urn:uuid:[0-9a-fA-F%-]+"%s*/>',
        '<meta%s+content="urn:uuid:[0-9a-fA-F%-]+"%s+name="Adept%.expected%.resource"%s*/>',
        '<meta%s+value="urn:uuid:[0-9a-fA-F%-]+"%s+name="Adept%.expected%.resource"%s*/>',
    }

    for _, pattern in ipairs(patterns) do
        local count
        stripped, count = stripped:gsub(pattern, "")
        total = total + count
    end

    return stripped, total
end

local function stripAdeptWatermarks(workDir)
    local files, listErr = listFiles(workDir)
    if not files then
        return nil, listErr
    end
    local modifiedFiles = 0
    for _, relPath in ipairs(files) do
        if relPath:match("%.x?html$") or relPath:match("%.xml$") then
            local fullPath = workDir .. "/" .. relPath
            local data = readFile(fullPath)
            if data then
                local updated, count = stripAdeptWatermarksFromText(data)
                if count > 0 then
                    writeFile(fullPath, updated)
                    modifiedFiles = modifiedFiles + 1
                end
            end
        end
    end

    return modifiedFiles
end

function epub.decryptAdobeEpub(inputPath, outputPath, bookKey)
    local workDir = makeTempDir()
    if hasArchiver then
        local ok, err = extractEpubWithArchiver(inputPath, workDir)
        if not ok then
            removeTree(workDir)
            return nil, err
        end
    else
        assert(os.execute("unzip -qq " .. shellQuote(inputPath) .. " -d " .. shellQuote(workDir)))
    end

    local encryptionPath = workDir .. "/META-INF/encryption.xml"
    local encryptionXml = readFile(encryptionPath)
    if not encryptionXml then
        removeTree(workDir)
        return nil, "Missing META-INF/encryption.xml"
    end

    local parsed = parseEncryptionXml(encryptionXml)

    for relPath in pairs(parsed.encrypted) do
        local fullPath = workDir .. "/" .. relPath
        local encryptedData = readFile(fullPath)
        if not encryptedData then
            removeTree(workDir)
            return nil, "Missing encrypted file: " .. relPath
        end
        local decryptedData, err = decryptAdeptEntry(encryptedData, bookKey, false)
        if not decryptedData then
            removeTree(workDir)
            return nil, "Failed to decrypt " .. relPath .. ": " .. err
        end
        writeFile(fullPath, decryptedData)
    end

    for relPath in pairs(parsed.encryptedForceNoDecomp) do
        local fullPath = workDir .. "/" .. relPath
        local encryptedData = readFile(fullPath)
        if not encryptedData then
            removeTree(workDir)
            return nil, "Missing encrypted file: " .. relPath
        end
        local decryptedData, err = decryptAdeptEntry(encryptedData, bookKey, true)
        if not decryptedData then
            removeTree(workDir)
            return nil, "Failed to decrypt " .. relPath .. ": " .. err
        end
        writeFile(fullPath, decryptedData)
    end

    os.remove(workDir .. "/META-INF/rights.xml")
    if parsed.rewrittenXml then
        writeFile(encryptionPath, parsed.rewrittenXml)
    else
        os.remove(encryptionPath)
    end

    local watermarkFiles, watermarkErr = stripAdeptWatermarks(workDir)
    if not watermarkFiles then
        removeTree(workDir)
        return nil, watermarkErr
    end

    local ok, repackErr = repackEpub(workDir, outputPath)
    if not ok then
        removeTree(workDir)
        return nil, repackErr
    end

    removeTree(workDir)

    return {
        outputPath = outputPath,
        decryptedEntries = (function()
            local count = 0
            for _ in pairs(parsed.encrypted) do count = count + 1 end
            for _ in pairs(parsed.encryptedForceNoDecomp) do count = count + 1 end
            return count
        end)(),
        remainingEncryptionXml = parsed.rewrittenXml ~= nil,
        strippedWatermarkFiles = watermarkFiles,
    }
end

return epub
