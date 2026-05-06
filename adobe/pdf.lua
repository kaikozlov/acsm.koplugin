--- ADEPT PDF decryption orchestrator.
-- Analogous to adobe/epub.lua for EPUB files.
--
-- Architecture matches ineptpdf.py (DeDRM_tools) exactly:
--   1. PDFDocument opens the file, reads xref/trailer
--   2. A decipher function is set on the document
--   3. PDFDocument.getobj() transparently decrypts every object on load
--      - Strings get decrypted via decipher_all()
--      - Streams get their rawdata decrypted via PDFStream.get_decdata()
--      - Stream dict string values get decrypted via PDFStream.get_decdic()
--   4. The writer iterates all objects via getobj() and writes clean output
--
-- The key insight from ineptpdf.py: decryption is NOT a separate pass.
-- It is integrated into the object loading path so that every access
-- to any object transparently produces decrypted data.

local logger = require("logger")
local lfs = require("libs/libkoreader-lfs")

local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfcrypt = require("adobe.pdf.pdfcrypt")
local pdfparser = require("adobe.pdf.parser")
local writer = require("adobe.pdf.writer")
local rc4 = require("adobe.pdf.rc4")
local nativecrypto = require("adobe.util.nativecrypto")
local zlib = require("adobe.util.zlib")
local xml = require("adobe.util.xml")
local util = require("adobe.util.util")

local pdf = {}

------------------------------------------------------------------------
-- ADEPT_LICENSE extraction
------------------------------------------------------------------------

--- Extract and decode the ADEPT license from the PDF encryption dict.
-- @param encParam table the /Encrypt dictionary values
-- @return table parsed rights XML, or nil, error
local function extractRights(encParam)
    local adept_license = encParam.ADEPT_LICENSE or encParam["adept_license"]
    if type(adept_license) ~= "string" or #adept_license == 0 then
        return nil, "No ADEPT_LICENSE in encryption dictionary"
    end

    -- ADEPT_LICENSE is base64-encoded, then zlib-compressed
    local compressed = util.base64.decode(adept_license)
    if not compressed then
        return nil, "Failed to base64-decode ADEPT_LICENSE"
    end

    local inflater = zlib.rawInflater()
    local rights_xml = inflater:update(compressed)
    inflater:close()
    if not rights_xml or #rights_xml == 0 then
        return nil, "Failed to decompress ADEPT_LICENSE"
    end

    local rights = xml.deserialize(rights_xml)
    if not rights then
        return nil, "Failed to parse ADEPT_LICENSE XML"
    end

    return rights
end

--- Extract the encrypted key from the rights XML.
-- @param rights table parsed rights XML
-- @return string base64-encoded encrypted key
-- @return string keyType attribute (or "0")
-- @return table rights document (for hardening removal)
local function extractEncryptedKey(rights)
    local function findEncryptedKey(t)
        if type(t) ~= "table" then return nil end
        if t.encryptedKey then
            local ek = t.encryptedKey
            if type(ek) == "table" then
                local text = ek[1] or ek._text or ek
                if type(text) == "string" then
                    local keyType = ek.keyType or ek["keyType"] or "0"
                    return text, keyType
                end
            elseif type(ek) == "string" then
                return ek, "0"
            end
        end
        for k, v in pairs(t) do
            if type(v) == "table" then
                local found, kt = findEncryptedKey(v)
                if found then return found, kt end
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

--- Create an AES-CBC decipher function for per-object decryption.
-- Matches ineptpdf.py PDFDocument.decrypt_aes
local function make_aes_decipher(bookKey, genkey_fn)
    return function(objid, genno, data)
        local key = genkey_fn(bookKey, objid, genno)
        if #data < 32 then return data end -- too short for AES (16 IV + padding)
        local iv = data:sub(1, 16)
        local encrypted = data:sub(17)
        local decrypted = nativecrypto.aes_cbc_decrypt(key, iv, encrypted, true)
        if not decrypted then return data end
        -- Remove PKCS7 padding (unpad from ineptpdf.py)
        if #decrypted > 0 then
            local padLen = decrypted:byte(#decrypted)
            if padLen > 0 and padLen <= 16 then
                decrypted = decrypted:sub(1, #decrypted - padLen)
            end
        end
        return decrypted
    end
end

------------------------------------------------------------------------
-- Main entry point
------------------------------------------------------------------------

--- Decrypt an ADEPT-encrypted PDF.
-- Matches the architecture of ineptpdf.py decryptBook():
--   1. Open PDF, parse xref/trailer/encryption
--   2. Determine encryption params, create decipher function
--   3. Set decipher on document (getobj() now transparently decrypts)
--   4. Iterate all objects, write clean output
--
-- @param inputPath string path to the encrypted PDF
-- @param outputPath string path to write the decrypted PDF
-- @param bookKey string the decrypted book key (from RSA decryption in fulfillment)
-- @return table info about the decryption, or nil, error
function pdf.decryptAdobePdf(inputPath, outputPath, bookKey)
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

    -- 3. Extract ADEPT_LICENSE and decode it (for logging/diagnostics)
    local adeptLicense, ebxBookid = doc:extractAdeptLicense()
    if not adeptLicense then
        logger.info("[ACSM] pdf: no ADEPT_LICENSE in PDF, using provided book key directly")
    else
        logger.info("[ACSM] pdf: found ADEPT_LICENSE, extracting rights...")
        local rights, rightsErr = extractRights({ADEPT_LICENSE = adeptLicense})
        if rights then
            local encKeyB64, keyType, rightsDoc = extractEncryptedKey(rights)
            if encKeyB64 then
                logger.info("[ACSM] pdf: found encryptedKey, keyType=", keyType)
            end
        else
            logger.warn("[ACSM] pdf: could not parse ADEPT_LICENSE:", rightsErr)
        end
    end

    -- 4. Determine encryption parameters from /Encrypt dict
    --    Matches ineptpdf.py initialize_ebx_inept key derivation logic
    local encParam = doc.encryption and doc.encryption.param or {}
    local ebx_V = tonumber(encParam.V or encParam["v"] or 4)
    local ebx_type = tonumber(encParam.EBX_ENCRYPTIONTYPE or encParam["ebx_encryptiontype"] or 6)
    local length = math.floor(tonumber(encParam.Length or encParam["length"] or 128) / 8)

    logger.info("[ACSM] pdf: ebx_V=", ebx_V, "ebx_type=", ebx_type, "length=", length)

    local encInfo = pdfcrypt.determineEncryption(bookKey, ebx_V, ebx_type, length)
    logger.info("[ACSM] pdf: encryption V=", encInfo.V, "cipher=", encInfo.cipher)

    -- 5. Create and set the decipher function on the document
    --    After this, doc:getobj(objid) transparently decrypts every object
    local decipher_fn
    if encInfo.cipher == "aes" or encInfo.cipher == "aes256" then
        decipher_fn = make_aes_decipher(encInfo.key, encInfo.genkey)
    else
        decipher_fn = make_rc4_decipher(encInfo.key, encInfo.genkey)
    end
    doc:set_decipher(decipher_fn)

    -- 6. Collect all objects and write clean PDF
    --    This matches ineptpdf.py PDFSerializer.dump():
    --    - Iterate all objids from xrefs
    --    - Skip the Encrypt dict object
    --    - For each object, call doc:getobj() which transparently decrypts
    --    - Streams use get_decdata()/get_decdic()
    local ids = doc:allObjids()
    local cleanObjects = {}
    local maxId = 0
    local decryptCount = 0
    local streamCount = 0

    for _, objid in ipairs(ids) do
        if objid > maxId then maxId = objid end

        -- Skip the Encrypt dict itself (ineptpdf.py removes it from trailer)
        if objid == doc.encrypt_objid then goto continue end

        local obj = doc:getobj(objid)
        if not obj then goto continue end

        cleanObjects[objid] = obj
        decryptCount = decryptCount + 1

        -- Count streams for diagnostics
        if type(obj) == "table" and obj.dic ~= nil and obj.rawdata ~= nil then
            streamCount = streamCount + 1
        end

        ::continue::
    end

    logger.info("[ACSM] pdf: decrypted", decryptCount, "objects,", streamCount, "streams")

    -- 7. Build clean trailer (remove /Encrypt, /Prev, /XRefStm)
    local cleanTrailer = doc:getCleanTrailer()
    cleanTrailer.Size = cleanTrailer.Size or (maxId + 1)

    local writeDoc = {
        version = doc.header or "%PDF-1.4\n",
        objects = cleanObjects,
        trailer = cleanTrailer,
    }
    writer.writeCleanPdf(inputPath, outputPath, writeDoc, doc.encrypt_objid)
    logger.info("[ACSM] pdf: wrote clean PDF to", outputPath)

    doc:close()

    return {
        outputPath = outputPath,
        decryptedObjects = decryptCount,
        decryptedStreams = streamCount,
    }
end

return pdf
