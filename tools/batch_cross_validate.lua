--- Cross-validation batch test v3: Downloads fresh ACSMs from Adobe
--- sample library, fulfills, saves encrypted + decrypted PDFs, extracts
--- book keys for Python reference comparison.
---
--- Fresh ACSMs per run → no expiration issues.
---
--- Run inside Docker:
---   make docker-shell
---   cd /opt/lib/koreader
---   luajit /opt/acsm.koplugin/tools/batch_cross_validate.lua

------------------------------------------------------------------------
-- Bootstrap: headless KOReader environment (adapted from commonrequire.lua)
------------------------------------------------------------------------

package.path = "common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;common/?.dll;/usr/lib/lua/?.so;" .. package.cpath
require("ffi/loadlib")
require("dbg"):turnOff()
local logger = require("logger")
logger:setLevel(logger.levels.warn)

local DataStorage = require("datastorage")
local test_data_dir = "/tmp/koreader-test-batch"
os.execute("mkdir -p " .. test_data_dir)
os.getenv = (function()
    local orig = os.getenv
    return function(key)
        if key == "KO_HOME" then return test_data_dir end
        return orig(key)
    end
end)()
package.loaded["datastorage"] = nil
DataStorage = require("datastorage")
local data_dir = DataStorage:getDataDir()
os.remove(data_dir .. "/defaults.tests.lua")
G_defaults = require("luadefaults"):open(data_dir .. "/defaults.tests.lua")
os.remove(data_dir .. "/settings.tests.lua")
G_reader_settings = require("luasettings"):open(data_dir .. "/settings.tests.lua")
einkfb = require("ffi/framebuffer")
einkfb.dummy = true
local Device = require("device")
Device.screen:init()
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
Device.input.dummy = true

local plugin_path = "/opt/acsm.koplugin"
package.path = plugin_path .. "/?.lua;" ..
               plugin_path .. "/dependencies/?.lua;" ..
               package.path

------------------------------------------------------------------------
-- Imports
------------------------------------------------------------------------

local http = require("socket.http")
local ltn12 = require("ltn12")
local lfs = require("libs/libkoreader-lfs")
local socketutil = require("socketutil")

local adobe = require("adobe.adobe")
local fulfillment = require("adobe.fulfillment")
local pdf_mod = require("adobe.pdf")
local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfcrypt = require("adobe.pdf.pdfcrypt")
local nativecrypto = require("adobe.util.nativecrypto")
local adobe_util = require("adobe.util.util")
local zlib_mod = require("adobe.util.zlib")
local xml_mod = require("adobe.util.xml")
local sha2 = require("ffi/sha2")
local crypto = require("adobe.util.crypto")

-- Simple file helpers
local function readFile(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local c = f:read("*a")
    f:close()
    return c
end
local function writeFile(path, content)
    local f = io.open(path, "wb")
    if not f then return false end
    f:write(content)
    f:close()
    return true
end
local function hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end
local function sha256hex(data)
    return sha2.sha256(data)
end
local function fileSha256(path)
    return sha256hex(readFile(path) or "")
end

------------------------------------------------------------------------
-- PDF ACSM URLs from Adobe Sample Library
------------------------------------------------------------------------

local PDF_ACSM_URLS = {
    {name = "goodbye_summer",        url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3A115ab68e-be42-42bb-99a9-d15168879e30"},
    {name = "daisy_miller",          url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3A91797970-de30-4775-a139-7eb160a6688b"},
    {name = "dracula",               url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3A98cdb717-fa80-407c-a076-b520eb149de8"},
    {name = "my_antonia",            url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3Ac8cfc0c4-9805-4f1e-9c24-aee61753da6b"},
    {name = "this_side_paradise",    url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3Af3d9bc3e-e673-4c03-a091-0e7c8d26014e"},
    {name = "princess_diaries",      url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3A85e0bf96-a8aa-4508-8acc-c5d40c3f21c8"},
    {name = "vingt_mille_lieues",    url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3A4541d3ee-c40b-49be-850a-41a4172a958f"},
    {name = "boule_de_suif",         url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3Abb099fd5-0f50-4224-8c19-6f3c081b02a4"},
    {name = "isabella",              url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3A9a93a7eb-a594-4e39-ae4f-496973a182a0"},
    {name = "don_quijote",           url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3A39a50f6e-fb34-4c8e-82fd-7b38630604d4"},
    {name = "tony_hillerman",        url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3A2d3bea66-b956-454b-86a2-c46b4d4ab10b"},
}

local OUT = "/opt/acsm.koplugin/tools/batch_output"
os.execute("mkdir -p " .. OUT)
os.execute("rm -rf " .. OUT .. "/*")  -- clean previous runs

------------------------------------------------------------------------
-- Download ACSM helper
------------------------------------------------------------------------

local function downloadACSM(url)
    local resp = {}
    local ok, code = http.request{
        url = url,
        sink = ltn12.sink.table(resp),
        headers = { ["User-Agent"] = socketutil.USER_AGENT },
        redirect = true,
    }
    if not ok then
        return nil, "HTTP " .. tostring(code)
    end
    local body = table.concat(resp)
    if not body or #body == 0 then
        return nil, "Empty response"
    end
    return body, nil
end

------------------------------------------------------------------------
-- Process each book
------------------------------------------------------------------------

local results = {}
local ready = 0

for i, book in ipairs(PDF_ACSM_URLS) do
    local name = book.name
    local book_dir = OUT .. "/" .. name
    os.execute("mkdir -p " .. book_dir)

    local entry = { name = name, dir = book_dir }
    print(string.format("\n[%d/%d] %s", i, #PDF_ACSM_URLS, name))

    -- Download fresh ACSM
    print("  Downloading ACSM...")
    local acsmBody, acsmErr = downloadACSM(book.url)
    if not acsmBody then
        print("  SKIP: ACSM download failed: " .. tostring(acsmErr))
        entry.status = "skip"; entry.error = "ACSM: " .. tostring(acsmErr)
        table.insert(results, entry); goto next_book
    end
    print(string.format("  ACSM: %d bytes", #acsmBody))

    -- Fresh activation per book
    print("  Activating...")
    local auth_info = adobe.getAuthenticationServiceInfo()
    local creds = adobe.signIn("anonymous", "", "", auth_info.certificate)
    local deviceUUID, fingerprint = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12)
    print("  Activated: " .. tostring(deviceUUID):sub(1, 20) .. "...")

    local pkcs12Key = crypto.decodepkcs12(creds.pkcs12, creds.deviceKey)
    local userUUID = creds.user
    if type(userUUID) == "table" then userUUID = userUUID[1] end
    local userCert = fulfillment.extractCertFromPKCS12(creds.pkcs12, creds.deviceKey)

    -- Parse ACSM
    local acsmParsed = xml_mod.deserialize(acsmBody)
    local operatorURL = acsmParsed.fulfillmentToken.operatorURL
    if type(operatorURL) == "table" then operatorURL = operatorURL[1] end
    if not operatorURL then
        print("  SKIP: no operatorURL")
        entry.status = "skip"; entry.error = "no operatorURL"
        table.insert(results, entry); goto next_book
    end

    -- Operator auth
    local ok, err = fulfillment.operatorAuth(operatorURL, userUUID, userCert, creds.licenseCert, auth_info.certificate)
    if not ok then
        print("  SKIP: operator auth failed: " .. tostring(err or "nil"))
        entry.status = "skip"; entry.error = "operator auth"
        table.insert(results, entry); goto next_book
    end

    -- Init license service
    local activationURL = "https://adeactivate.adobe.com/adept"
    ok, err = fulfillment.initLicenseService(activationURL, operatorURL, userUUID, pkcs12Key)
    if not ok then
        print("  SKIP: init license failed: " .. tostring(err or "nil"))
        entry.status = "skip"; entry.error = "init license"
        table.insert(results, entry); goto next_book
    end

    -- Save ACSM file for fulfillment
    local acsmTmp = book_dir .. "/" .. name .. ".acsm"
    writeFile(acsmTmp, acsmBody)

    -- Fulfill
    local fulfillResult, fulfillErr = fulfillment.fulfill(acsmTmp, userUUID, deviceUUID, fingerprint, pkcs12Key)
    if not fulfillResult then
        print("  SKIP: fulfill failed: " .. tostring(fulfillErr or "nil"))
        entry.status = "skip"; entry.error = "fulfill: " .. tostring(fulfillErr or "nil")
        table.insert(results, entry); goto next_book
    end
    print(string.format("  Fulfill OK, download URL: %s", fulfillResult.src:sub(1, 60)))

    -- Download encrypted PDF
    local encPath = book_dir .. "/encrypted.pdf"
    local _, dlErr = fulfillment.downloadBook(fulfillResult.src, encPath)
    if dlErr then
        print("  SKIP: download failed: " .. tostring(dlErr))
        entry.status = "skip"; entry.error = "download: " .. tostring(dlErr)
        table.insert(results, entry); goto next_book
    end

    local encSize = lfs.attributes(encPath).size
    print(string.format("  Encrypted PDF: %d bytes", encSize))
    entry.encrypted_path = encPath
    entry.encrypted_size = encSize

    -- Verify it's a PDF
    local magic = readFile(encPath):sub(1, 5)
    if magic ~= "%PDF-" then
        print("  SKIP: not a PDF (magic=" .. magic .. ")")
        entry.status = "skip"; entry.error = "not PDF"
        table.insert(results, entry); goto next_book
    end

    -- Inspect encryption
    local doc = pdfdoc.PDFDocument:new()
    local ok2 = doc:open(encPath)
    if not ok2 then
        print("  SKIP: can't open PDF")
        entry.status = "skip"; entry.error = "open failed"
        doc:close()
        table.insert(results, entry); goto next_book
    end

    local encFilter = doc:getEncryptionFilter()
    if encFilter ~= "EBX_HANDLER" then
        print("  SKIP: filter=" .. tostring(encFilter))
        entry.status = "skip"; entry.error = "filter: " .. tostring(encFilter)
        doc:close()
        table.insert(results, entry); goto next_book
    end

    -- Extract encryption params
    local encParam = doc.encryption.param
    if type(encParam) == "table" and encParam.dic then
        encParam = encParam.dic
    end
    local ebx_V = tonumber(encParam.V or encParam["v"] or 4)
    local ebx_type = tonumber(encParam.EBX_ENCRYPTIONTYPE or encParam["ebx_encryptiontype"] or 6)
    local length = math.floor(tonumber(encParam.Length or encParam["length"] or 128) / 8)
    print(string.format("  V=%d, type=%d, length=%d", ebx_V, ebx_type, length))

    -- Try ADEPT_LICENSE path first for book key
    local bookKey = nil
    local adept_license = encParam.ADEPT_LICENSE or encParam["adept_license"]

    if type(adept_license) == "table" and adept_license.ref then
        local licObj = doc:_loadRawObject(adept_license.ref.objid)
        if licObj then
            if type(licObj) == "string" then adept_license = licObj
            elseif type(licObj) == "table" and licObj.dic then adept_license = licObj.rawdata end
        end
    end
    if not adept_license and type(encParam) == "table" and encParam.dic and encParam.rawdata then
        -- If encParam is actually the stream with dic/rawdata (not the extracted dict)
        local origParam = doc.encryption.param
        if type(origParam) == "table" and origParam.dic and origParam.rawdata then
            adept_license = origParam.rawdata
        end
    end

    if type(adept_license) == "string" and #adept_license > 0 then
        local inflated = zlib_mod.inflate(adept_license)
        if inflated then
            local rightsXml = xml_mod.parse(inflated)
            if rightsXml then
                local function findText(node, tag)
                    if not node then return nil end
                    if node.tag and node.tag:find(tag .. "$") then return node.text end
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
                    local bookKeyRaw = adobe_util.base64.decode(encKeyB64)
                    if bookKeyRaw then
                        local keyType = "0"
                        local function findAttr(node, tag, attr)
                            if not node then return nil end
                            if node.tag and node.tag:find(tag .. "$") and node.attrs and node.attrs[attr] then
                                return node.attrs[attr]
                            end
                            if node.children then
                                for _, child in ipairs(node.children) do
                                    local a = findAttr(child, tag, attr)
                                    if a then return a end
                                end
                            end
                            return nil
                        end
                        keyType = findAttr(rightsXml.root, "encryptedKey", "keyType") or "0"

                        if tonumber(keyType) > 2 then
                            print("  Hardening (keyType=" .. keyType .. "), removing...")
                            local ruuid = findText(rightsXml.root, "resource") or ""
                            local duuid = findText(rightsXml.root, "device") or ""
                            local fuuid = findText(rightsXml.root, "fulfillment") or ""
                            ruuid = ruuid:match("uuid:(.+)") or ruuid
                            duuid = duuid:match("uuid:(.+)") or duuid
                            fuuid = fuuid:match("uuid:(.+)") or fuuid
                            fuuid = fuuid:sub(1, 36)

                            bookKeyRaw = pdfcrypt.removeHardening(
                                bookKeyRaw, keyType,
                                ruuid, duuid, fuuid,
                                nativecrypto.aes_cbc_decrypt)
                            if not bookKeyRaw then
                                print("  SKIP: hardening removal failed")
                                entry.status = "skip"; entry.error = "hardening removal"
                                doc:close()
                                table.insert(results, entry); goto next_book
                            end
                        end

                        local bk, rsaErr = creds.licenseKey.pkey:decrypt(
                            bookKeyRaw, nativecrypto.RSA_PKCS1_PADDING)
                        if bk then
                            bookKey = bk
                            print(string.format("  Book key: %d bytes", #bk))
                        end
                    end
                end
            end
        end
    end

    -- Fallback: fulfillment encryptedKey
    if not bookKey and fulfillResult.encryptedKey then
        print("  Fallback: fulfillment encryptedKey...")
        local bookKeyRaw = adobe_util.base64.decode(fulfillResult.encryptedKey)
        if bookKeyRaw then
            local bk, rsaErr = creds.licenseKey.pkey:decrypt(
                bookKeyRaw, nativecrypto.RSA_PKCS1_PADDING)
            if bk then
                bookKey = bk
                print(string.format("  Book key (fallback): %d bytes", #bk))
            end
        end
    end

    if not bookKey then
        print("  SKIP: could not extract book key")
        entry.status = "skip"; entry.error = "no book key"
        doc:close()
        table.insert(results, entry); goto next_book
    end

    -- Determine V
    local encInfo = pdfcrypt.determineEncryption(bookKey, ebx_V, ebx_type, length)
    local V = encInfo.V

    -- Save artifacts for Python
    writeFile(book_dir .. "/book_key.hex", hex(bookKey))
    writeFile(book_dir .. "/V.txt", tostring(V) .. "\n")

    entry.book_key_hex = hex(bookKey)
    entry.V = V
    entry.book_key_len = #bookKey
    entry.book_key_sha256 = sha256hex(bookKey)
    entry.ebx_V = ebx_V
    entry.ebx_type = ebx_type
    entry.length = length
    entry.cipher = encInfo.cipher

    -- Lua decryption
    local decPath = book_dir .. "/lua_decrypted.pdf"
    print("  Decrypting (Lua)...")
    local decInfo, decErr = pdf_mod.decryptAdobePdf(
        encPath, decPath,
        bookKey,
        nil, nil
    )

    doc:close()

    if not decInfo then
        print("  WARNING: Lua decrypt failed: " .. tostring(decErr))
        entry.status = "lua_decrypt_failed"
        entry.error = tostring(decErr)
    else
        entry.lua_decrypted_path = decPath
        local decAttr = lfs.attributes(decPath)
        entry.lua_decrypted_size = decAttr and decAttr.size or 0
        entry.decrypted_objects = decInfo.decryptedObjects or 0
        entry.decrypted_streams = decInfo.decryptedStreams or 0
        entry.lua_sha256 = fileSha256(decPath)
        print(string.format("  Lua: %d bytes, %d objects (%d streams)",
            entry.lua_decrypted_size, entry.decrypted_objects, entry.decrypted_streams))
        print(string.format("  SHA256: %s", entry.lua_sha256:sub(1, 32) .. "..."))
        entry.status = "ready_for_python"
        ready = ready + 1
    end

    table.insert(results, entry)

    ::next_book::
end

------------------------------------------------------------------------
-- Manifest
------------------------------------------------------------------------

local json_mod = require("json")
local manifest = {
    total = #PDF_ACSM_URLS,
    ready = ready,
    results = results,
}
writeFile(OUT .. "/manifest.json", json_mod.encode(manifest) .. "\n")

print(string.format("\n[cross-val] %d/%d books ready for Python cross-validation.", ready, #PDF_ACSM_URLS))
print("[cross-val] Now run on host: python3 tools/batch_compare.py")
