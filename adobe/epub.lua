local epub = {}

local Archiver = require("ffi/archiver")
local lfs = require("libs/libkoreader-lfs")
local koutil = require("util")

local dom = require("adobe.util.dom")
local nativecrypto = require("adobe.util.nativecrypto")
local zlib = require("adobe.util.zlib")

local XMLENC = "http://www.w3.org/2001/04/xmlenc#"
local AES128_CBC = "http://www.w3.org/2001/04/xmlenc#aes128-cbc"
local AES128_CBC_UNCOMPRESSED = "http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed"

local function removeTree(path)
    if not path or path == "" or lfs.attributes(path, "mode") ~= "directory" then
        return
    end
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
end

local function parseEncryptionXml(encryptionXml)
    local root = dom.parse(encryptionXml)
    local rootNsMap = dom.nsMapFor(root, { [""] = "urn:oasis:names:tc:opendocument:xmlns:container" })

    local encrypted = {}
    local encryptedForceNoDecomp = {}
    local remainingEncryptedData = 0
    local keptChildren = {}

    for _, child in ipairs(root._children or {}) do
        if child._type ~= "ELEMENT" then
            keptChildren[#keptChildren + 1] = child
        else
            local childNsMap = dom.nsMapFor(child, rootNsMap)
            local childNs, childName = dom.resolveNodeName(child, rootNsMap)
            if childNs == XMLENC and childName == "EncryptedData" then
                local methodNode = dom.firstElement(child, childNsMap, "EncryptionMethod", XMLENC)
                local cipherDataNode, cipherDataNsMap = dom.firstElement(child, childNsMap, "CipherData", XMLENC)
                local cipherRefNode = cipherDataNode and dom.firstElement(cipherDataNode, cipherDataNsMap, "CipherReference", XMLENC)

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
        rewrittenXml = '<?xml version="1.0" encoding="UTF-8"?>\n' .. dom.serializeNode(root)
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
    local ok, err = koutil.makePath(tmpDir)
    assert(ok, err)
    return tmpDir
end

local function listFiles(workDir)
    local files = {}
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

    table.sort(files)
    return files
end

local function repackEpub(workDir, outputPath)
    os.remove(outputPath)
    local writer = Archiver.Writer:new{}
    if not writer:open(outputPath, "epub") then
        return nil, writer.err or "Could not open EPUB writer"
    end

    local mtime = os.time()
    local mimetype = koutil.readFromFile(workDir .. "/mimetype", "rb")
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
            local content = koutil.readFromFile(fullPath, "rb")
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

local function extractEpub(inputPath, workDir)
    local reader = Archiver.Reader:new()
    if not reader:open(inputPath) then
        return nil, reader.err or "Could not open EPUB archive"
    end

    for entry in reader:iterate() do
        if entry.mode == "file" then
            local fullPath = workDir .. "/" .. entry.path
            local parent = fullPath:match("^(.*)/[^/]+$")
            if parent and parent ~= "" then
                local ok, err = koutil.makePath(parent)
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
            local ok, err = koutil.writeToFile(content, fullPath)
            if not ok then
                reader:close()
                return nil, err
            end
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
            local data = koutil.readFromFile(fullPath, "rb")
            if data then
                local updated, count = stripAdeptWatermarksFromText(data)
                if count > 0 then
                    assert(koutil.writeToFile(updated, fullPath))
                    modifiedFiles = modifiedFiles + 1
                end
            end
        end
    end

    return modifiedFiles
end

function epub.decryptAdobeEpub(inputPath, outputPath, bookKey)
    local workDir = makeTempDir()
    local ok, err = extractEpub(inputPath, workDir)
    if not ok then
        removeTree(workDir)
        return nil, err
    end

    local encryptionPath = workDir .. "/META-INF/encryption.xml"
    local encryptionXml = koutil.readFromFile(encryptionPath, "rb")
    if not encryptionXml then
        removeTree(workDir)
        return nil, "Missing META-INF/encryption.xml"
    end

    local parsed = parseEncryptionXml(encryptionXml)

    for relPath in pairs(parsed.encrypted) do
        local fullPath = workDir .. "/" .. relPath
        local encryptedData = koutil.readFromFile(fullPath, "rb")
        if not encryptedData then
            removeTree(workDir)
            return nil, "Missing encrypted file: " .. relPath
        end
        local decryptedData, err = decryptAdeptEntry(encryptedData, bookKey, false)
        if not decryptedData then
            removeTree(workDir)
            return nil, "Failed to decrypt " .. relPath .. ": " .. err
        end
        assert(koutil.writeToFile(decryptedData, fullPath))
    end

    for relPath in pairs(parsed.encryptedForceNoDecomp) do
        local fullPath = workDir .. "/" .. relPath
        local encryptedData = koutil.readFromFile(fullPath, "rb")
        if not encryptedData then
            removeTree(workDir)
            return nil, "Missing encrypted file: " .. relPath
        end
        local decryptedData, err = decryptAdeptEntry(encryptedData, bookKey, true)
        if not decryptedData then
            removeTree(workDir)
            return nil, "Failed to decrypt " .. relPath .. ": " .. err
        end
        assert(koutil.writeToFile(decryptedData, fullPath))
    end

    os.remove(workDir .. "/META-INF/rights.xml")
    if parsed.rewrittenXml then
        assert(koutil.writeToFile(parsed.rewrittenXml, encryptionPath))
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
