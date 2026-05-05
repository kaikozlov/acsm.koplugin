local epub = {}

local ffi = require("ffi")
local Archiver = require("ffi/archiver")
local DataStorage = require("datastorage")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local koutil = require("util")

local dom = require("adobe.util.dom")
local nativecrypto = require("adobe.util.nativecrypto")
local zlib = require("adobe.util.zlib")

local XMLENC = "http://www.w3.org/2001/04/xmlenc#"
local AES128_CBC = "http://www.w3.org/2001/04/xmlenc#aes128-cbc"
local AES128_CBC_UNCOMPRESSED = "http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed"

local CHUNK_SIZE = 65536  -- 64KB chunks for streaming decrypt
local WATERMARK_SCAN_BYTES = 16384
local FILE_IOFBF = 0

require("ffi/posix_h")  -- FILE, fopen, fwrite, fclose, strerror
pcall(ffi.cdef, "int setvbuf(FILE *stream, char *buf, int mode, size_t size);")

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

local function stripPkcs7Held(buf, len)
    if len < 1 then
        return nil, "Invalid PKCS#7 padding"
    end
    local pad = tonumber(buf[len - 1])
    if not pad or pad < 1 or pad > 16 or pad > len then
        return nil, "Invalid PKCS#7 padding"
    end
    return len - pad
end

local function setLuaFileBuffer(file, size)
    if not file or type(file.setvbuf) ~= "function" then
        return
    end
    pcall(file.setvbuf, file, "full", size)
end

local function openBufferedOutput(path, size)
    local stream = ffi.C.fopen(path, "wb")
    if stream == nil then
        return nil, "Cannot create temp file: " .. ffi.string(ffi.C.strerror(ffi.errno()))
    end
    ffi.gc(stream, ffi.C.fclose)
    ffi.C.setvbuf(stream, nil, FILE_IOFBF, size)

    local writer = {}

    function writer:write(ptr, len)
        if len <= 0 then
            return true
        end
        local written = tonumber(ffi.C.fwrite(ptr, 1, len, stream))
        if written ~= len then
            return nil, "short write"
        end
        return true
    end

    function writer:close()
        if stream == nil then
            return true
        end
        ffi.gc(stream, nil)
        local rc = ffi.C.fclose(stream)
        stream = nil
        if rc ~= 0 then
            return nil, "close failed"
        end
        return true
    end

    return writer
end


--- Decrypt an Adobe ADEPT encrypted file in-place using streaming.
-- Reads the input in CHUNK_SIZE chunks, decrypts via streaming AES-CBC,
-- optionally inflates via streaming zlib, and writes to a temp file.
-- Peak memory: ~2 × CHUNK_SIZE regardless of file size.
local function decryptAdeptEntryFile(fullPath, bookKey, noDecomp)
    local inFile, inErr = io.open(fullPath, "rb")
    if not inFile then
        return nil, "Cannot open encrypted file: " .. tostring(inErr)
    end
    setLuaFileBuffer(inFile, CHUNK_SIZE)

    local tmpPath = fullPath .. ".dec"
    local outWriter, outErr = openBufferedOutput(tmpPath, CHUNK_SIZE)
    if not outWriter then
        inFile:close()
        return nil, outErr
    end

    -- Create streaming decryptor (zero IV, no padding — we handle PKCS7 manually)
    local decryptor, decErr = nativecrypto.aes_cbc_decryptor(bookKey, string.rep("\0", 16), true)
    if not decryptor then
        inFile:close()
        outWriter:close()
        os.remove(tmpPath)
        return nil, "Failed to create decryptor: " .. tostring(decErr)
    end

    -- Optionally create streaming inflater
    local inflater = nil
    if not noDecomp then
        local infErr
        inflater, infErr = zlib.rawInflater()
        if not inflater then
            inFile:close()
            outWriter:close()
            os.remove(tmpPath)
            return nil, "Failed to create inflater: " .. tostring(infErr)
        end
    end

    -- We need to:
    -- 1. Skip the first 16 bytes of decrypted output (random prefix)
    -- 2. Strip PKCS7 padding from the final block
    -- Strategy: skip first 16, hold back last 16 for PKCS7 check.
    -- Held bytes are flushed when new data arrives (proving they aren't final).
    local skipRemaining = 16  -- bytes to skip from start of decrypted stream
    local held = ffi.new("uint8_t[16]")
    local heldLen = 0

    local function writeThrough(ptr, len)
        if len <= 0 then
            return true
        end
        if inflater then
            return inflater:update(ptr, len, function(outPtr, outLen)
                return outWriter:write(outPtr, outLen)
            end)
        end
        return outWriter:write(ptr, len)
    end

    local function processDecrypted(ptr, len)
        -- Skip the first 16 bytes of the decrypted stream
        if skipRemaining > 0 then
            if len <= skipRemaining then
                skipRemaining = skipRemaining - len
                return true
            end
            ptr = ptr + skipRemaining
            len = len - skipRemaining
            skipRemaining = 0
        end

        -- Flush previously held bytes (they're not the final block since more data arrived)
        if heldLen > 0 then
            local ok, err = writeThrough(held, heldLen)
            if not ok then return nil, err end
            heldLen = 0
        end

        -- Hold back the last 16 bytes of this chunk for PKCS7 stripping
        if len <= 16 then
            ffi.copy(held, ptr, len)
            heldLen = len
            return true
        end
        ffi.copy(held, ptr + len - 16, 16)
        heldLen = 16

        return writeThrough(ptr, len - 16)
    end

    -- Read and process chunks
    local readErr = nil
    while true do
        local chunk = inFile:read(CHUNK_SIZE)
        if not chunk then break end

        local ok, updateErr = decryptor:update(chunk, processDecrypted)
        if not ok then
            readErr = "decrypt update failed: " .. tostring(updateErr)
            break
        end
    end
    inFile:close()

    if not readErr then
        -- Finalize decryption
        local ok, finErr = decryptor:finalize(processDecrypted)
        if not ok then
            readErr = "decrypt finalize failed: " .. tostring(finErr)
        end
    end

    if not readErr then
        -- Strip PKCS7 from held bytes and write remainder
        local strippedLen, pkcsErr = stripPkcs7Held(held, heldLen)
        if not strippedLen then
            readErr = "PKCS7 strip failed: " .. tostring(pkcsErr)
        elseif strippedLen > 0 then
            local ok, err = writeThrough(held, strippedLen)
            if not ok then
                readErr = "final write failed: " .. tostring(err)
            end
        end
    end

    if inflater then
        inflater:finalize()
    end
    local closeOk, closeErr = outWriter:close()
    if not readErr and not closeOk then
        readErr = "close failed: " .. tostring(closeErr)
    end

    if readErr then
        os.remove(tmpPath)
        return nil, readErr
    end

    -- Replace original with decrypted version
    os.remove(fullPath)
    local ok, renameErr = os.rename(tmpPath, fullPath)
    if not ok then
        os.remove(tmpPath)
        return nil, "Failed to rename decrypted file: " .. tostring(renameErr)
    end

    return true
end

local function makeTempDir()
    local cacheDir = DataStorage:getDataDir() .. "/cache/acsm.koplugin"
    koutil.makePath(cacheDir)
    local tmpDir = cacheDir .. "/epub_work"
    -- Clean up any previous run
    if lfs.attributes(tmpDir, "mode") == "directory" then
        removeTree(tmpDir)
    end
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
            if lfs.attributes(fullPath, "mode") ~= "file" then
                writer:close()
                return nil, "Missing repack input: " .. relPath
            end
            writer:addPath(relPath, fullPath, false, mtime)
            if writer.err then
                writer:close()
                return nil, writer.err
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
            local ok = reader:extractToPath(entry.path, fullPath)
            if not ok then
                reader:close()
                return nil, reader.err or ("Could not extract " .. entry.path)
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
        local lowerRelPath = relPath:lower()
        if lowerRelPath:match("%.xhtml$") or lowerRelPath:match("%.html$") or lowerRelPath:match("%.xml$") or lowerRelPath:match("%.opf$") then
            local fullPath = workDir .. "/" .. relPath
            local prefixFile = io.open(fullPath, "rb")
            if prefixFile then
                setLuaFileBuffer(prefixFile, WATERMARK_SCAN_BYTES)
                local prefix = prefixFile:read(WATERMARK_SCAN_BYTES) or ""
                prefixFile:close()

                if prefix:find("Adept.resource", 1, true) or prefix:find("Adept.expected.resource", 1, true) then
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
        end
    end

    return modifiedFiles
end

function epub.decryptAdobeEpub(inputPath, outputPath, bookKey)
    logger.info("[ACSM] decryptAdobeEpub: input=", inputPath, "output=", outputPath)
    local workDir = makeTempDir()
    logger.info("[ACSM] decryptAdobeEpub: workDir=", workDir)
    local ok, err = extractEpub(inputPath, workDir)
    if not ok then
        logger.warn("[ACSM] decryptAdobeEpub: failed to extract epub:", err)
        removeTree(workDir)
        return nil, err
    end
    logger.info("[ACSM] decryptAdobeEpub: extracted, reading encryption.xml...")

    local encryptionPath = workDir .. "/META-INF/encryption.xml"
    local encryptionXml = koutil.readFromFile(encryptionPath, "rb")
    if not encryptionXml then
        removeTree(workDir)
        return nil, "Missing META-INF/encryption.xml"
    end

    local parsed = parseEncryptionXml(encryptionXml)
    logger.info("[ACSM] decryptAdobeEpub: parsed encryption, decrypting entries...")

    local decryptCount = 0
    for relPath in pairs(parsed.encrypted) do
        local fullPath = workDir .. "/" .. relPath
        local decOk, decErr = decryptAdeptEntryFile(fullPath, bookKey, false)
        if not decOk then
            removeTree(workDir)
            return nil, "Failed to decrypt " .. relPath .. ": " .. decErr
        end
        decOk = nil
        collectgarbage("step", 200)
        decryptCount = decryptCount + 1
    end
    logger.info("[ACSM] decryptAdobeEpub: decrypted", decryptCount, "entries with decompression")

    local forceNoDecompCount = 0
    for relPath in pairs(parsed.encryptedForceNoDecomp) do
        local fullPath = workDir .. "/" .. relPath
        local decOk, decErr = decryptAdeptEntryFile(fullPath, bookKey, true)
        if not decOk then
            removeTree(workDir)
            return nil, "Failed to decrypt " .. relPath .. ": " .. decErr
        end
        decOk = nil
        collectgarbage("step", 200)
        forceNoDecompCount = forceNoDecompCount + 1
    end
    logger.info("[ACSM] decryptAdobeEpub: decrypted", forceNoDecompCount, "entries without decompression")

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
        logger.warn("[ACSM] decryptAdobeEpub: failed to repack:", repackErr)
        removeTree(workDir)
        return nil, repackErr
    end
    logger.info("[ACSM] decryptAdobeEpub: repacked successfully to", outputPath)

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

-- Export internal functions for testing (underscore-prefixed = internal API)
epub._parseEncryptionXml = parseEncryptionXml
epub._stripPkcs7Held = stripPkcs7Held
epub._stripAdeptWatermarksFromText = stripAdeptWatermarksFromText
epub._decryptAdeptEntryFile = decryptAdeptEntryFile

return epub
