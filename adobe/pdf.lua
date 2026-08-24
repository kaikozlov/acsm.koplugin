--- ADEPT PDF decryption orchestrator.
-- Analogous to adobe/epub.lua for EPUB files.
--
-- Architecture matches ineptpdf.py (DeDRM_tools) exactly:
--   1. PDFDocument opens the file, reads xref/trailer
--   2. Extract book key from ADEPT_LICENSE (with hardening removal if needed)
--   3. A decipher function is set on the document
--   4. PDFDocument.getobj() transparently decrypts every object on load
--      - Strings get decrypted via decipher_all()
--      - Streams get their rawdata decrypted via PDFStream.get_decdata()
--      - Stream dict string values get decrypted via PDFStream.get_decdic()
--   5. The writer iterates all objects via getobj() and writes clean output
--
-- The key insight from ineptpdf.py: decryption is NOT a separate pass.
-- It is integrated into the object loading path so that every access
-- to any object transparently produces decrypted data.

local logger = require("logger")

local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfcrypt = require("adobe.pdf.pdfcrypt")
local writer = require("adobe.pdf.writer")
local rc4 = require("adobe.pdf.rc4")
local nativecrypto = require("adobe.util.nativecrypto")
local zlib = require("adobe.util.zlib")
local xml = require("adobe.util.xml")
local util = require("adobe.util.util")

local pdf = {}

local removeHardeningFromRights

------------------------------------------------------------------------
-- Rights XML helpers
------------------------------------------------------------------------

--- Extract and decode the ADEPT license from the PDF encryption dict.
-- @param doc PDFDocument (needed for resolving indirect references)
-- @param encParam table the /Encrypt dictionary values (may be a stream object)
-- @return table parsed rights XML, or nil, error
local function extractRights(doc, encParam)
    local adept_license = nil

    -- Case 1: ADEPT_LICENSE is a direct string key in the dict
    if type(encParam.ADEPT_LICENSE) == "string" then
        adept_license = encParam.ADEPT_LICENSE
    end

    -- Case 2: ADEPT_LICENSE is an indirect reference — dereference it
    if not adept_license then
        local licRef = encParam.ADEPT_LICENSE
        if type(licRef) == "table" and licRef.ref then
            local licObj = doc:_loadRawObject(licRef.ref.objid)
            if licObj then
                -- The referenced object might be a string or a stream
                if type(licObj) == "string" then
                    adept_license = licObj
                elseif type(licObj) == "table" and licObj.dic then
                    -- Stream: use rawdata as the license
                    adept_license = licObj.rawdata
                end
            end
        end
    end

    -- Case 3: Encrypt dict is a stream object — the rawdata IS the ADEPT_LICENSE
    if not adept_license and type(encParam) == "table" and encParam.dic then
        adept_license = encParam.rawdata
    end

    if type(adept_license) ~= "string" or #adept_license == 0 then
        -- Build a diagnostic message with available keys for debugging
        local hasStream, keyList = false, {}
        if type(encParam) == "table" then
            if encParam.dic then
                hasStream = true
                for k in pairs(encParam.dic) do
                    keyList[#keyList + 1] = tostring(k)
                end
            else
                for k in pairs(encParam) do
                    keyList[#keyList + 1] = tostring(k)
                end
            end
        end
        local diag = "No ADEPT_LICENSE in encryption dict" .. (hasStream and " (stream)" or "") .. " keys=[" .. table.concat(keyList, ",") .. "]"
        return nil, diag
    end

    -- ADEPT_LICENSE is base64-encoded, then zlib-compressed
    local compressed = util.base64.decode(adept_license)
    if not compressed then
        return nil, "Failed to base64-decode ADEPT_LICENSE"
    end

    local rights_xml, infErr = zlib.inflateRaw(compressed)
    if not rights_xml or #rights_xml == 0 then
        return nil, "Failed to decompress ADEPT_LICENSE" .. (infErr and (": " .. infErr) or "")
    end

    local rights = xml.deserialize(rights_xml)
    if not rights then
        return nil, "Failed to parse ADEPT_LICENSE XML"
    end

    return rights
end

--- Find a text value in a rights XML tree by element name.
-- Handles both namespaced ({http://ns.adobe.com/adept}resource) and
-- bare (resource) element names.
local function findRightsText(t, name)
    if type(t) ~= "table" then
        return nil
    end

    -- Try direct access with common name variants
    local direct = t[name] or t["{" .. "http://ns.adobe.com/adept" .. "}" .. name]
    if direct then
        if type(direct) == "string" then
            return direct
        end
        if type(direct) == "table" then
            local text = direct[1] or direct._text
            if type(text) == "string" then
                return text
            end
        end
    end

    -- Recurse into sub-tables
    for _, v in pairs(t) do
        if type(v) == "table" then
            local found = findRightsText(v, name)
            if found then
                return found
            end
        end
    end
    return nil
end

--- Extract the encrypted key and key metadata from the rights XML.
-- @param rights table parsed rights XML
-- @return string base64-encoded encrypted key, or nil
-- @return string keyType attribute (or "0")
-- @return table rights document (for hardening removal)
local function extractEncryptedKey(rights)
    local function findEncryptedKey(t)
        if type(t) ~= "table" then
            return nil
        end
        -- Check for encryptedKey with possible namespace prefixes
        for k, v in pairs(t) do
            if type(k) == "string" and k:find("encryptedKey", 1, true) then
                if type(v) == "table" then
                    local text = v[1] or v._text
                    if type(text) == "string" then
                        local keyType = v.keyType or "0"
                        return text, keyType
                    end
                elseif type(v) == "string" then
                    return v, "0"
                end
            end
        end
        -- Also check bare "encryptedKey" field
        if t.encryptedKey then
            local ek = t.encryptedKey
            if type(ek) == "table" then
                local text = ek[1] or ek._text
                if type(text) == "string" then
                    local keyType = ek.keyType or "0"
                    return text, keyType
                end
            elseif type(ek) == "string" then
                return ek, "0"
            end
        end
        for _, v in pairs(t) do
            if type(v) == "table" then
                local found, kt = findEncryptedKey(v)
                if found then
                    return found, kt
                end
            end
        end
        return nil
    end

    local encKeyB64, keyType = findEncryptedKey(rights)
    if not encKeyB64 then
        return nil, "Could not find encryptedKey in rights XML", "0"
    end
    return encKeyB64, keyType, rights
end

------------------------------------------------------------------------
-- Book key extraction from PDF's ADEPT_LICENSE
------------------------------------------------------------------------

--- Extract the book key for ADEPT-encrypted PDFs.
-- Attempts to extract from the PDF's /Encrypt dict first (supports hardening removal).
-- Falls back to decrypting the fulfillment response's encrypted key directly.
--
-- @param doc PDFDocument (already opened)
-- @param licenseKey table {pkey = rawPKey} for RSA decryption
-- @param fulfillmentEncryptedKey string optional: base64-encoded encrypted key from fulfillment response
-- @return string decrypted book key, or nil, error
local function extractBookKey(doc, licenseKey, fulfillmentEncryptedKey)
    local encParam = doc.encryption and doc.encryption.param
    if not encParam then
        return nil, "No /Encrypt dict in PDF"
    end

    local bookKeyRaw = nil

    -- Try to extract ADEPT_LICENSE from the PDF (supports hardening removal)
    local rights, rightsErr = extractRights(doc, encParam)
    if rights then
        -- Found ADEPT_LICENSE — full path with hardening support
        local encKeyB64, kt, rightsDoc = extractEncryptedKey(rights)
        if encKeyB64 then
            logger.info("[ACSM] pdf: encryptedKey found in PDF, keyType=", kt)
            bookKeyRaw = util.base64.decode(encKeyB64)

            -- Handle hardening if needed
            if tonumber(kt) > 2 then
                bookKeyRaw = removeHardeningFromRights(bookKeyRaw, kt, rightsDoc)
                if not bookKeyRaw then
                    return nil, "Hardening removal failed"
                end
            end
        end
    elseif rightsErr then
        logger.warn("[ACSM] pdf: could not extract ADEPT_LICENSE:", rightsErr)
    end

    -- Fallback: use fulfillment response encrypted key
    if not bookKeyRaw and fulfillmentEncryptedKey then
        logger.info("[ACSM] pdf: using fulfillment encryptedKey (no ADEPT_LICENSE in PDF)")
        bookKeyRaw = util.base64.decode(fulfillmentEncryptedKey)
        if not bookKeyRaw then
            return nil, "Failed to base64-decode fulfillment encryptedKey"
        end
        -- When using fulfillment key, we can't do hardening removal
        -- (needs UUIDs from rights XML which isn't available)
        -- This is acceptable for older ADEPT books (keyType <= 2)
    end

    if not bookKeyRaw then
        return nil, "No encrypted key available (neither in PDF nor from fulfillment)"
    end

    -- RSA-decrypt the book key
    local bookKey, rsaErr = licenseKey.pkey:decrypt(bookKeyRaw, nativecrypto.RSA_PKCS1_PADDING)
    if not bookKey then
        return nil, "RSA decrypt of book key failed: " .. tostring(rsaErr)
    end

    logger.info("[ACSM] pdf: book key extracted successfully, length=", #bookKey)
    return bookKey
end

--- Extract UUIDs from rights XML and call removeHardening.
function removeHardeningFromRights(bookKeyRaw, keyType, rights)
    local resourceUUID = findRightsText(rights, "resource")
    local deviceUUID = findRightsText(rights, "device")
    local fulfillmentUUID = findRightsText(rights, "fulfillment")

    if not resourceUUID or not deviceUUID or not fulfillmentUUID then
        logger.warn("[ACSM] pdf: missing UUIDs in rights XML for hardening removal")
        return nil
    end

    resourceUUID = resourceUUID:match("uuid:(.+)") or resourceUUID
    deviceUUID = deviceUUID:match("uuid:(.+)") or deviceUUID
    fulfillmentUUID = fulfillmentUUID:match("uuid:(.+)") or fulfillmentUUID
    fulfillmentUUID = fulfillmentUUID:sub(1, 36)

    logger.info("[ACSM] pdf: removing ADEPT hardening (keyType=", keyType, ")")
    return pdfcrypt.removeHardening(bookKeyRaw, keyType, resourceUUID, deviceUUID, fulfillmentUUID, nativecrypto.aes_cbc_decrypt)
end

------------------------------------------------------------------------
-- Decipher function creation
------------------------------------------------------------------------

--- Create an RC4 decipher function for per-object decryption.
-- Matches ineptpdf.py PDFDocument.decrypt_rc4
local function make_rc4_decipher(bookKey, genkey_fn)
    return function(objid, genno, data)
        local key = genkey_fn(bookKey, objid, genno)
        local state = rc4.init(key)
        return rc4.crypt(state, data)
    end
end

local function unpadPkcs7(data)
    local padLen = #data > 0 and data:byte(#data) or nil
    if not padLen or padLen < 1 or padLen > 16 or padLen > #data then
        return nil, "Invalid PKCS#7 padding"
    end
    for i = #data - padLen + 1, #data do
        if data:byte(i) ~= padLen then
            return nil, "Invalid PKCS#7 padding"
        end
    end
    return data:sub(1, #data - padLen)
end

--- Create an AES-CBC decipher function for per-object decryption.
-- Matches ineptpdf.py PDFDocument.decrypt_aes
local function make_aes_decipher(bookKey, genkey_fn)
    return function(objid, genno, data)
        local key = genkey_fn(bookKey, objid, genno)
        if #data < 32 then
            return data
        end -- too short for AES (16 IV + padding)
        local iv = data:sub(1, 16)
        local encrypted = data:sub(17)
        local decrypted = nativecrypto.aes_cbc_decrypt(key, iv, encrypted, true)
        if not decrypted then
            return data
        end
        local unpadded = unpadPkcs7(decrypted)
        if not unpadded then
            return data
        end
        return unpadded
    end
end

------------------------------------------------------------------------
-- Main entry point
------------------------------------------------------------------------

--- Decrypt an ADEPT-encrypted PDF.
-- Matches the architecture of ineptpdf.py decryptBook():
--   1. Open PDF, parse xref/trailer/encryption
--   2. Extract book key (with hardening removal if available)
--   3. Determine encryption params, create decipher function
--   4. Set decipher on document (getobj() now transparently decrypts)
--   5. Iterate all objects, write clean output
--
-- @param inputPath string path to the encrypted PDF
-- @param outputPath string path to write the decrypted PDF
-- @param bookKey string the decrypted book key, OR nil if licenseKey is provided
-- @param licenseKey table optional: {pkey = rawPKey} for extracting book key from PDF
-- @param fulfillmentEncryptedKey string optional: base64-encoded encrypted key from fulfillment response
--        Used as fallback when PDF doesn't contain ADEPT_LICENSE (older ADEPT scheme).
-- @return table info about the decryption, or nil, error
function pdf.decryptAdobePdf(inputPath, outputPath, bookKey, licenseKey, fulfillmentEncryptedKey)
    logger.info("[ACSM] pdf.decryptAdobePdf: input=", inputPath, "output=", outputPath)

    -- 1. Open and parse the PDF structure
    local doc = pdfdoc.PDFDocument:new()
    local ok, err = doc:open(inputPath)
    if not ok then
        doc:close()
        return nil, "Failed to open PDF: " .. tostring(err)
    end

    -- 2. Check encryption type
    local encFilter = doc:getEncryptionFilter()
    if encFilter and encFilter ~= "EBX_HANDLER" then
        doc:close()
        return nil, "Unknown PDF encryption filter: " .. tostring(encFilter)
    end
    if encFilter == "EBX_HANDLER" then
        logger.info("[ACSM] pdf: encryption filter is EBX_HANDLER")
    else
        if not doc.encryption then
            logger.warn("[ACSM] pdf: no /Encrypt dict found — PDF may not be encrypted")
        end
    end

    -- 3. Extract or use the book key
    --    If licenseKey is provided, extract the book key from the PDF's
    --    ADEPT_LICENSE with full hardening removal support.
    if licenseKey and not bookKey then
        logger.info("[ACSM] pdf: licenseKey provided, extracting book key from PDF...")
        local extractedKey, keyErr = extractBookKey(doc, licenseKey, fulfillmentEncryptedKey)
        if not extractedKey then
            doc:close()
            return nil, "Book key extraction failed: " .. tostring(keyErr)
        end
        bookKey = extractedKey
    elseif not bookKey then
        doc:close()
        return nil, "No bookKey or licenseKey provided"
    end

    -- 4. Log ADEPT_LICENSE for diagnostics
    local adeptLicense = doc:extractAdeptLicense()
    if adeptLicense then
        logger.info("[ACSM] pdf: ADEPT_LICENSE present in PDF")
        local rights = extractRights(doc, { ADEPT_LICENSE = adeptLicense })
        if rights then
            local encKeyB64, keyType = extractEncryptedKey(rights)
            if encKeyB64 then
                logger.info("[ACSM] pdf: encryptedKey in PDF, keyType=", keyType)
            end
        end
    end

    -- 5. Determine encryption parameters from /Encrypt dict
    --    Matches ineptpdf.py initialize_ebx_inept key derivation logic
    local encParam = doc.encryption and doc.encryption.param or {}
    -- If Encrypt is a stream object, use its dictionary
    if type(encParam) == "table" and encParam.dic then
        encParam = encParam.dic
    end
    local ebx_V = tonumber(encParam.V or 4)
    local ebx_type = tonumber(encParam.EBX_ENCRYPTIONTYPE or 6)
    local length = math.floor(tonumber(encParam.Length or 128) / 8)

    logger.info("[ACSM] pdf: ebx_V=", ebx_V, "ebx_type=", ebx_type, "length=", length)

    local encInfo = pdfcrypt.determineEncryption(bookKey, ebx_V, ebx_type, length)
    logger.info("[ACSM] pdf: encryption V=", encInfo.V, "cipher=", encInfo.cipher)

    -- 6. Create and set the decipher function on the document
    --    After this, doc:getobj(objid) transparently decrypts every object
    local decipher_fn
    if encInfo.cipher == "aes" or encInfo.cipher == "aes256" then
        decipher_fn = make_aes_decipher(encInfo.key, encInfo.genkey)
    else
        decipher_fn = make_rc4_decipher(encInfo.key, encInfo.genkey)
    end
    doc:set_decipher(decipher_fn)

    -- 7+8. Stream objects to output one at a time.
    --    Memory discipline: each object is loaded (decrypted), written to
    --    the output file, then released from the cache so GC can reclaim it.
    --    Peak memory: bounded to the largest single object, not their sum.
    --    This matches the EPUB streaming approach (64KB chunks per entry)
    --    and prevents OOM kills on memory-constrained devices (Kindle PW1).
    local ids = doc:allObjids()

    local w, wErr = writer.PdfWriter.new(outputPath, {
        version = doc.header or "%PDF-1.4",
    })
    if not w then
        doc:close()
        return nil, "Failed to open output: " .. tostring(wErr)
    end

    local decryptCount = 0
    local streamCount = 0

    for _, objid in ipairs(ids) do
        -- Skip the Encrypt dict itself (ineptpdf.py removes it from trailer)
        if objid == doc.encrypt_objid then
            goto continue
        end

        local obj = doc:getobj(objid)
        if not obj then
            goto continue
        end

        -- Write immediately — after this call, `obj` can be GC'd
        w:writeObject(objid, obj)
        decryptCount = decryptCount + 1

        -- Count streams for diagnostics
        if type(obj) == "table" and obj.dic ~= nil then
            streamCount = streamCount + 1
        end

        -- Release from document cache so Lua can reclaim the memory.
        -- The writer has already serialized everything to disk.
        doc.objs[objid] = nil

        ::continue::
    end

    logger.info("[ACSM] pdf: decrypted", decryptCount, "objects,", streamCount, "streams")

    -- Finish: write xref table + trailer (remove /Encrypt, /Prev, /XRefStm)
    local cleanTrailer = doc:getCleanTrailer()
    w:finish(cleanTrailer)
    logger.info("[ACSM] pdf: wrote clean PDF to", outputPath)

    doc:close()

    return {
        outputPath = outputPath,
        decryptedObjects = decryptCount,
        decryptedStreams = streamCount,
    }
end

-- Export internal functions for testing (underscore-prefixed = internal API)
pdf._extractRights = extractRights
pdf._findRightsText = findRightsText
pdf._extractEncryptedKey = extractEncryptedKey
pdf._extractBookKey = extractBookKey
pdf._make_rc4_decipher = make_rc4_decipher
pdf._make_aes_decipher = make_aes_decipher

return pdf
