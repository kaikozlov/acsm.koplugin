#!/usr/bin/env luajit
--- Batch fulfillment script for Adobe sample library PDFs.
-- Fulfills all ACSM files, decrypts with Lua, saves book keys and outputs
-- for cross-validation against the Python reference implementation.
--
-- Usage (inside Docker): luajit tools/batch_fulfill.lua
--
-- Output: tools/batch_output/manifest.json + per-book files

local http = require("socket.http")
local ltn12 = require("ltn12")
local socket = require("socket")
local lfs = require("libs/libkoreader-lfs")
local koutil = require("util")

local adobe = require("adobe.adobe")
local fulfillment = require("adobe.fulfillment")
local pdf = require("adobe.pdf")
local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfcrypt = require("adobe.pdf.pdfcrypt")
local nativecrypto = require("adobe.util.nativecrypto")

local ACSM_DIR = "spec/integration/fixtures/pdf_acsm"
local OUTPUT_DIR = "tools/batch_output"

-- Ensure output directory exists
koutil.makePath(OUTPUT_DIR)

-- Collect ACSM files
local acsm_files = {}
for fname in lfs.dir(ACSM_DIR) do
    if fname:match("%.acsm$") then
        table.insert(acsm_files, {name = fname, path = ACSM_DIR .. "/" .. fname})
    end
end

if #acsm_files == 0 then
    print("[batch] No ACSM files found in " .. ACSM_DIR)
    os.exit(1)
end

print("[batch] Found " .. #acsm_files .. " ACSM files")
for _, f in ipairs(acsm_files) do
    print("  " .. f.name)
end

-- Shared activation (one per run, reused for all books)
print("[batch] Creating anonymous activation...")
local socketutil = require("socketutil")
socketutil:set_timeout(30, 60)

local auth_info = adobe.getAuthenticationServiceInfo()
assert(auth_info.certificate, "Missing auth certificate")

local creds = adobe.signIn("anonymous", "", "", auth_info.certificate)
assert(creds.user, "Sign-in failed")

local deviceUUID, fingerprint = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12)
assert(deviceUUID, "Activation failed")
print("[batch] Device activated: " .. tostring(deviceUUID))

-- Process each ACSM
local results = {}
local success_count = 0
local fail_count = 0

for i, f in ipairs(acsm_files) do
    local book_name = f.name:gsub("%.acsm$", "")
    local book_dir = OUTPUT_DIR .. "/" .. book_name
    koutil.makePath(book_dir)
    
    local manifest_entry = {
        name = book_name,
        acsm = f.path,
        dir = book_dir,
        status = "unknown",
    }
    
    print(string.format("\n[batch] [%d/%d] Processing: %s", i, #acsm_files, book_name))
    
    -- Step 1: Read ACSM from file (already downloaded)
    local acsmBody = koutil.readFromFile(f.path)
    local acsmFile = book_dir .. "/" .. book_name .. ".acsm"
    koutil.writeToFile(acsmBody, acsmFile)
    
    -- Step 2: Fulfillment creates the download URL
    print("  Fulfilling...")
    local outputPath = book_dir .. "/" .. book_name .. "_encrypted.pdf"
    
    local result, err = fulfillment.process(
        acsmFile, outputPath,
        creds, deviceUUID, fingerprint,
        auth_info.certificate)
    
    if not result then
        print("  FAILED fulfillment: " .. tostring(err))
        manifest_entry.status = "fulfillment_failed"
        manifest_entry.error = tostring(err)
        fail_count = fail_count + 1
        table.insert(results, manifest_entry)
        goto next_book
    end
    
    -- fulfillment.process saves encrypted PDF to outputPath
    local encrypted_path = result.outputPath
    local attr = lfs.attributes(encrypted_path)
    if not attr then
        print("  FAILED: encrypted PDF not found at " .. encrypted_path)
        manifest_entry.status = "encrypted_missing"
        manifest_entry.error = "Encrypted PDF not found"
        fail_count = fail_count + 1
        table.insert(results, manifest_entry)
        goto next_book
    end
    
    manifest_entry.encrypted_path = encrypted_path
    manifest_entry.encrypted_size = attr.size
    print(string.format("  Encrypted PDF: %d bytes", attr.size))
    
    -- Step 3: Inspect encryption parameters
    local doc = pdfdoc.PDFDocument:new()
    local ok, openErr = doc:open(encrypted_path)
    if not ok then
        print("  WARNING: Could not open PDF: " .. tostring(openErr))
        doc:close()
    else
        local encFilter = doc:getEncryptionFilter()
        manifest_entry.enc_filter = encFilter
        
        -- Extract encryption parameters
        local encParam = doc.encryption and doc.encryption.param
        if type(encParam) == "table" and encParam.dic then
            encParam = encParam.dic
        end
        if type(encParam) == "table" then
            manifest_entry.ebx_V = tonumber(encParam.V or encParam["v"] or 4)
            manifest_entry.ebx_type = tonumber(encParam.EBX_ENCRYPTIONTYPE or encParam["ebx_encryptiontype"] or 6)
            manifest_entry.length = math.floor(tonumber(encParam.Length or encParam["length"] or 128) / 8)
        end
        
        print(string.format("  Filter: %s, V=%s, type=%s, length=%s",
            encFilter or "none",
            tostring(manifest_entry.ebx_V),
            tostring(manifest_entry.ebx_type),
            tostring(manifest_entry.length)))
    end
    
    -- Step 4: Decrypt with Lua
    local decrypted_path = book_dir .. "/" .. book_name .. "_lua_decrypted.pdf"
    print("  Decrypting (Lua)...")
    
    local bookKey = nil  -- Let pdf.decryptAdobePdf extract it from the PDF
    local decInfo, decErr = pdf.decryptAdobePdf(
        encrypted_path, decrypted_path,
        nil,  -- bookKey: nil → extract from PDF
        creds.licenseKey,  -- RSA key for decrypting the book key
        result.encryptedKey  -- fallback encrypted key from fulfillment
    )
    
    if not decInfo then
        print("  FAILED Lua decryption: " .. tostring(decErr))
        manifest_entry.status = "lua_decrypt_failed"
        manifest_entry.error = tostring(decErr)
        fail_count = fail_count + 1
        doc:close()
        table.insert(results, manifest_entry)
        goto next_book
    end
    
    local decAttr = lfs.attributes(decrypted_path)
    manifest_entry.lua_decrypted_path = decrypted_path
    manifest_entry.lua_decrypted_size = decAttr and decAttr.size or 0
    manifest_entry.decrypted_objects = decInfo.decryptedObjects
    manifest_entry.decrypted_streams = decInfo.decryptedStreams
    
    print(string.format("  Lua decrypted: %d bytes, %d objects (%d streams)",
        manifest_entry.lua_decrypted_size,
        manifest_entry.decryptedObjects,
        manifest_entry.decryptedStreams))
    
    -- Step 5: Extract the book key + V for Python reference
    -- Re-open and extract book key the same way pdf.decryptAdobePdf does
    local doc2 = pdfdoc.PDFDocument:new()
    local ok2, err2 = doc2:open(encrypted_path)
    if ok2 and doc2.encryption then
        -- Extract ADEPT_LICENSE
        local encParam2 = doc2.encryption.param
        if type(encParam2) == "table" and encParam2.dic then
            encParam2 = encParam2.dic
        end
        
        -- Parse rights XML to get encryptedKey
        local util = require("adobe.util.util")
        local xml = require("adobe.util.xml")
        local adept_license = nil
        
        if type(encParam2) == "table" then
            adept_license = encParam2.ADEPT_LICENSE or encParam2["adept_license"]
        end
        
        if type(adept_license) == "table" and adept_license.ref then
            local licObj = doc2:_loadRawObject(adept_license.ref.objid)
            if licObj then
                if type(licObj) == "string" then
                    adept_license = licObj
                elseif type(licObj) == "table" and licObj.dic then
                    adept_license = licObj.rawdata
                end
            end
        end
        
        -- Also check if Encrypt is a stream (rawdata IS the license)
        if type(encParam2) == "table" and encParam2.dic and not adept_license then
            adept_license = encParam2.rawdata
        end
        
        if type(adept_license) == "string" and #adept_license > 0 then
            local zlib_mod = require("adobe.util.zlib")
            local inflated, inflErr = zlib_mod.inflate(adept_license)
            if inflated then
                local rightsXml, parseErr = xml.parse(inflated)
                if rightsXml then
                    -- Find encryptedKey
                    local function findText(node, tag)
                        if not node then return nil end
                        if node.tag and node.tag:find(tag .. "$") then
                            return node.text
                        end
                        if node.children then
                            for _, child in ipairs(node.children) do
                                local t = findText(child, tag)
                                if t then return t end
                            end
                        end
                        return nil
                    end
                    
                    local encKeyB64 = findText(rightsXml.root, "encryptedKey")
                    if encKeyB64 then
                        local bookKeyRaw = util.base64.decode(encKeyB64)
                        if bookKeyRaw then
                            -- RSA decrypt the book key
                            local bookKey, rsaErr = creds.licenseKey.pkey:decrypt(
                                bookKeyRaw, nativecrypto.RSA_PKCS1_PADDING)
                            if bookKey then
                                manifest_entry.book_key_hex = sha2_hex(bookKey)
                                manifest_entry.book_key_len = #bookKey
                                print(string.format("  Book key: %d bytes", #bookKey))
                            end
                        end
                    end
                end
            end
        end
        
        -- Determine V for genkey
        local ebx_V = tonumber(
            (type(encParam2) == "table" and encParam2.V) or
            (encParam2 and encParam2["v"]) or 4)
        local ebx_type = tonumber(
            (type(encParam2) == "table" and encParam2.EBX_ENCRYPTIONTYPE) or
            (encParam2 and encParam2["ebx_encryptiontype"]) or 6)
        local length = math.floor(tonumber(
            (type(encParam2) == "table" and encParam2.Length) or
            (encParam2 and encParam2["length"]) or 128) / 8)
        
        local encInfo = pdfcrypt.determineEncryption(bookKey or "", ebx_V, ebx_type, length)
        manifest_entry.V = encInfo.V
        manifest_entry.cipher = encInfo.cipher
        print(string.format("  V=%d, cipher=%s", encInfo.V, encInfo.cipher))
        
        doc2:close()
    end
    
    manifest_entry.status = "success"
    success_count = success_count + 1
    table.insert(results, manifest_entry)
    
    doc:close()
    
    ::next_book::
end

-- Write manifest
local manifest_path = OUTPUT_DIR .. "/manifest.json"
local json = require("json")
local manifest_json = json.encode({
    activation = { deviceUUID = deviceUUID },
    total = #acsm_files,
    success = success_count,
    failed = fail_count,
    books = results,
})
koutil.writeToFile(manifest_json, manifest_path)

print(string.format("\n[batch] Done: %d success, %d failed", success_count, fail_count))
print("[batch] Manifest: " .. manifest_path)

-- Helper: SHA256 hex of binary data
function sha2_hex(data)
    local sha2 = require("ffi/sha2")
    return sha2.sha256(data)
end
