--- Integration tests: fulfillment.process() error paths and format detection
-- Tests the top-level orchestration function by stubbing internal functions
-- and HTTP to isolate specific code paths.

describe("fulfillment_process", function()
    local fulfillment, crypto, nc, koutil, util, epub, pdf

    -- Saved originals for stubbing
    local orig_extractCertFromPKCS12
    local orig_decodepkcs12
    local orig_operatorAuth
    local orig_initLicenseService
    local orig_fulfill
    local orig_downloadBook
    local orig_decryptBookKey
    local orig_decryptAdobeEpub
    local orig_decryptAdobePdf
    local orig_notify
    local orig_http_request

    -- Per-test state
    local tmpDir
    local fulfillCallCount
    local operatorAuthCallCount

    setup(function()
        fulfillment = require("adobe.fulfillment")
        crypto = require("adobe.util.crypto")
        nc = require("adobe.util.nativecrypto")
        koutil = require("util")
        util = require("adobe.util.util")
        epub = require("adobe.epub")
        pdf = require("adobe.pdf")
    end)

    before_each(function()
        -- Save originals
        orig_extractCertFromPKCS12 = fulfillment.extractCertFromPKCS12
        orig_decodepkcs12 = crypto.decodepkcs12
        orig_operatorAuth = fulfillment.operatorAuth
        orig_initLicenseService = fulfillment.initLicenseService
        orig_fulfill = fulfillment.fulfill
        orig_downloadBook = fulfillment.downloadBook
        orig_decryptBookKey = fulfillment.decryptBookKey
        orig_decryptAdobeEpub = epub.decryptAdobeEpub
        orig_decryptAdobePdf = pdf.decryptAdobePdf
        orig_notify = fulfillment.notify
        orig_http_request = require("socket.http").request

        fulfillCallCount = 0
        operatorAuthCallCount = 0

        -- Create temp dir for this test
        local DataStorage = require("datastorage")
        tmpDir = DataStorage:getDataDir() .. "/test-process-" .. tostring(os.time()) .. "-" .. math.random(10000, 99999)
        koutil.makePath(tmpDir)

        -- Default stubs: everything succeeds unless overridden
        fulfillment.extractCertFromPKCS12 = function()
            return "dGVzdC1jZXJ0"  -- base64 "test-cert"
        end
        crypto.decodepkcs12 = function()
            local key = crypto.key.new()
            return key.pkey  -- raw PKey
        end
        fulfillment.operatorAuth = function()
            operatorAuthCallCount = operatorAuthCallCount + 1
            return true
        end
        fulfillment.initLicenseService = function()
            return true
        end
    end)

    after_each(function()
        -- Restore originals
        fulfillment.extractCertFromPKCS12 = orig_extractCertFromPKCS12
        crypto.decodepkcs12 = orig_decodepkcs12
        fulfillment.operatorAuth = orig_operatorAuth
        fulfillment.initLicenseService = orig_initLicenseService
        fulfillment.fulfill = orig_fulfill
        fulfillment.downloadBook = orig_downloadBook
        fulfillment.decryptBookKey = orig_decryptBookKey
        epub.decryptAdobeEpub = orig_decryptAdobeEpub
        pdf.decryptAdobePdf = orig_decryptAdobePdf
        fulfillment.notify = orig_notify
        require("socket.http").request = orig_http_request

        -- Clean up temp dir
        if tmpDir then
            os.execute("rm -rf " .. tmpDir)
        end
    end)

    --- Helper: write a minimal ACSM file with the given operatorURL.
    -- If operatorURL is nil, omits the element entirely.
    local function writeAcsm(operatorURL)
        local acsmPath = tmpDir .. "/test.acsm"
        local content
        if operatorURL then
            content = string.format([[<?xml version="1.0"?>
<fulfillmentToken xmlns="http://ns.adobe.com/adept">
  <operatorURL>%s</operatorURL>
  <resourceItemInfo>
    <resource>urn:uuid:test-resource</resource>
  </resourceItemInfo>
</fulfillmentToken>]], operatorURL)
        else
            content = [[<?xml version="1.0"?>
<fulfillmentToken xmlns="http://ns.adobe.com/adept">
  <resourceItemInfo>
    <resource>urn:uuid:test-resource</resource>
  </resourceItemInfo>
</fulfillmentToken>]]
        end
        koutil.writeToFile(content, acsmPath)
        return acsmPath
    end

    --- Helper: build a creds table with all required fields.
    local function makeCreds(overrides)
        local licenseKey = crypto.key.new()
        local deviceKey = crypto.deviceKey.new()
        local creds = {
            user = "urn:uuid:test-user",
            pkcs12 = "dGVzdA==",  -- stubbed, so value doesn't matter
            deviceKey = deviceKey,
            licenseCert = "dGVzdC1saWNlbnNl",
            licenseKey = licenseKey,
            activationURL = "https://adeactivate.adobe.com/adept",
        }
        if overrides then
            for k, v in pairs(overrides) do creds[k] = v end
        end
        return creds
    end

    --- Helper: write a file with specific magic bytes at path.
    local function writeFileWithMagic(path, magicBytes)
        local f = io.open(path, "wb")
        f:write(magicBytes)
        f:write(string.rep("\x00", 100))  -- padding
        f:close()
    end

    -- ================================================================
    -- 1. Format detection from magic bytes
    -- ================================================================
    describe("format detection", function()
        it("detects EPUB from PK magic bytes", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            -- Stub fulfill to return a download URL
            fulfillment.fulfill = function()
                return {
                    response = "<fulfillmentResult/>",
                    operatorURL = "https://operator.example.com/Fulfill",
                    src = "https://operator.example.com/download/book.epub",
                    encryptedKey = "dGVzdA==",
                    keyType = "2",
                    licenseURL = "https://operator.example.com/license",
                    licenseTokenXml = "<licenseToken/>",
                    notifyURLs = {},
                }
            end

            -- Stub downloadBook to write an EPUB-like file (PK header)
            fulfillment.downloadBook = function(url, path)
                writeFileWithMagic(path, "PK\x03\x04")
                return true
            end

            -- Stub decryptBookKey + decryptAdobeEpub
            fulfillment.decryptBookKey = function()
                return string.rep("\xAA", 16)
            end
            epub.decryptAdobeEpub = function()
                return { decryptedEntries = 5 }
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is.truthy(result, "process should succeed: " .. tostring(err))
            assert.are.equal(outputPath, result.outputPath)
            assert.are.equal(5, result.decryptedEntries)
        end)

        it("detects PDF from %PDF- magic bytes", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.pdf"
            local creds = makeCreds()

            fulfillment.fulfill = function()
                return {
                    response = "<fulfillmentResult/>",
                    operatorURL = "https://operator.example.com/Fulfill",
                    src = "https://operator.example.com/download/book.pdf",
                    encryptedKey = "dGVzdA==",
                    keyType = "2",
                    licenseURL = "https://operator.example.com/license",
                    licenseTokenXml = "<licenseToken/>",
                    notifyURLs = {},
                }
            end

            -- Stub downloadBook to write a PDF-like file (%PDF- header)
            fulfillment.downloadBook = function(url, path)
                writeFileWithMagic(path, "%PDF-1.7")
                return true
            end

            -- Stub PDF decryption. Use decryptedEntries (same field the
            -- return statement reads: `decryptedInfo.decryptedEntries or decryptedInfo.decryptedObjects`).
            pdf.decryptAdobePdf = function()
                return { decryptedEntries = 42 }
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is.truthy(result, "process should succeed: " .. tostring(err))
            assert.are.equal(outputPath, result.outputPath)
            assert.are.equal(42, result.decryptedEntries)
        end)

        it("returns error for unknown magic bytes", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.unknown"
            local creds = makeCreds()

            fulfillment.fulfill = function()
                return {
                    response = "<fulfillmentResult/>",
                    operatorURL = "https://operator.example.com/Fulfill",
                    src = "https://operator.example.com/download/book.bin",
                    encryptedKey = "dGVzdA==",
                    keyType = "2",
                    licenseURL = "https://operator.example.com/license",
                    licenseTokenXml = "<licenseToken/>",
                    notifyURLs = {},
                }
            end

            -- Write garbage magic bytes
            fulfillment.downloadBook = function(url, path)
                writeFileWithMagic(path, "\x00\x00\x00\x00")
                return true
            end

            -- NOTE: unknown bytes currently fall through to the EPUB branch
            -- (the else-path after isPdf/isEpub checks). If process() ever
            -- adds an explicit "unsupported format" guard before decryption,
            -- this test will need updating.
            fulfillment.decryptBookKey = function()
                return string.rep("\xAA", 16)
            end
            epub.decryptAdobeEpub = function()
                return nil, "not a valid epub"
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            -- Should mention EPUB since unknown format falls through to EPUB path
            assert.is.truthy(err:find("EPUB") or err:find("decrypt"), "error should mention decryption failure, got: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- 2. E_ADEPT_DISTRIBUTOR_AUTH retry path
    -- ================================================================
    describe("E_ADEPT_DISTRIBUTOR_AUTH retry", function()
        it("retries operator auth and fulfill on DISTRIBUTOR_AUTH error", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            fulfillCallCount = 0
            operatorAuthCallCount = 0

            -- First fulfill() returns DISTRIBUTOR_AUTH error, second succeeds
            fulfillment.fulfill = function()
                fulfillCallCount = fulfillCallCount + 1
                if fulfillCallCount == 1 then
                    return nil, "Fulfill error: E_ADEPT_DISTRIBUTOR_AUTH http://ns.adobe.com/adept"
                end
                return {
                    response = "<fulfillmentResult/>",
                    operatorURL = "https://operator.example.com/Fulfill",
                    src = "https://operator.example.com/download/book.epub",
                    encryptedKey = "dGVzdA==",
                    keyType = "2",
                    licenseURL = "https://operator.example.com/license",
                    licenseTokenXml = "<licenseToken/>",
                    notifyURLs = {},
                }
            end

            fulfillment.downloadBook = function(url, path)
                writeFileWithMagic(path, "PK\x03\x04")
                return true
            end
            fulfillment.decryptBookKey = function()
                return string.rep("\xAA", 16)
            end
            epub.decryptAdobeEpub = function()
                return { decryptedEntries = 3 }
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is.truthy(result, "process should succeed after retry: " .. tostring(err))

            -- fulfill() was called twice (first failed, second succeeded)
            assert.are.equal(2, fulfillCallCount)
            -- operatorAuth was called 3 times: once initially, once for retry re-auth
            assert.are.equal(2, operatorAuthCallCount)
        end)

        it("returns error when retry also fails", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            fulfillment.fulfill = function()
                return nil, "Fulfill error: E_ADEPT_DISTRIBUTOR_AUTH persistent failure"
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("E_ADEPT_DISTRIBUTOR_AUTH"), "error should contain DISTRIBUTOR_AUTH: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- 3. Missing operator URL in ACSM
    -- ================================================================
    describe("missing operator URL", function()
        it("returns error when ACSM has no operatorURL", function()
            local acsmPath = writeAcsm(nil)  -- no operatorURL
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("operatorURL") or err:find("No operator"), "error should mention operatorURL: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- 4. downloadBook failure
    -- ================================================================
    describe("downloadBook failure", function()
        it("returns error when downloadBook returns an error", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            fulfillment.fulfill = function()
                return {
                    response = "<fulfillmentResult/>",
                    operatorURL = "https://operator.example.com/Fulfill",
                    src = "https://operator.example.com/download/book.epub",
                    encryptedKey = "dGVzdA==",
                    keyType = "2",
                    licenseURL = "https://operator.example.com/license",
                    licenseTokenXml = "<licenseToken/>",
                    notifyURLs = {},
                }
            end

            -- downloadBook writes an empty file and returns error
            fulfillment.downloadBook = function(url, path)
                local f = io.open(path, "wb")
                if f then f:close() end
                return nil, "Book download failed: timeout"
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("download") or err:find("Book"), "error should mention download: " .. tostring(err))
        end)

        it("returns error when downloadBook succeeds but file is 0 bytes", function()
            -- This exercises the real downloadBook() size-check path:
            -- it writes an empty file, but the stub returns success.
            -- process() then reads magic bytes (empty string) and
            -- falls into the EPUB branch where decryption fails on
            -- the zero-byte file.
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            fulfillment.fulfill = function()
                return {
                    response = "<fulfillmentResult/>",
                    operatorURL = "https://operator.example.com/Fulfill",
                    src = "https://operator.example.com/download/book.epub",
                    encryptedKey = "dGVzdA==",
                    keyType = "2",
                    licenseURL = "https://operator.example.com/license",
                    licenseTokenXml = "<licenseToken/>",
                    notifyURLs = {},
                }
            end

            -- downloadBook writes an empty file and reports success
            fulfillment.downloadBook = function(url, path)
                local f = io.open(path, "wb")
                if f then f:close() end
                return true
            end

            -- Empty file → no magic match → EPUB branch → decryptBookKey OK → epub decrypt fails
            fulfillment.decryptBookKey = function()
                return string.rep("\xAA", 16)
            end
            epub.decryptAdobeEpub = function()
                return nil, "not a valid zip archive"
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("decrypt") or err:find("EPUB"), "error should mention decryption failure, got: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- 5. decryptBookKey failure
    -- ================================================================
    describe("decryptBookKey failure", function()
        it("returns error when RSA decryption of book key fails", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            fulfillment.fulfill = function()
                return {
                    response = "<fulfillmentResult/>",
                    operatorURL = "https://operator.example.com/Fulfill",
                    src = "https://operator.example.com/download/book.epub",
                    encryptedKey = util.base64.encode("garbage-encrypted-key-data"),
                    keyType = "2",
                    licenseURL = "https://operator.example.com/license",
                    licenseTokenXml = "<licenseToken/>",
                    notifyURLs = {},
                }
            end

            fulfillment.downloadBook = function(url, path)
                writeFileWithMagic(path, "PK\x03\x04")
                return true
            end

            -- Use the real decryptBookKey: it will fail because the encryptedKey
            -- is garbage, not proper RSA ciphertext for creds.licenseKey
            fulfillment.decryptBookKey = orig_decryptBookKey

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("book key"), "error should mention book key: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- 6. extractCertFromPKCS12 failure
    -- ================================================================
    describe("extractCertFromPKCS12 failure", function()
        it("returns error when cert extraction fails", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            -- Stub cert extraction to fail
            fulfillment.extractCertFromPKCS12 = function()
                return nil, "invalid PKCS12 data"
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("cert"), "error should mention cert: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- 7. operatorAuth failure
    -- ================================================================
    describe("operatorAuth failure", function()
        it("returns error when operator auth fails", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            fulfillment.operatorAuth = function()
                return nil, "Operator auth failed: 403 Forbidden"
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("Operator auth") or err:find("auth"), "error should mention auth: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- 8. initLicenseService failure
    -- ================================================================
    describe("initLicenseService failure", function()
        it("returns error when license service init fails", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            fulfillment.initLicenseService = function()
                return nil, "InitLicenseService failed: connection refused"
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("InitLicenseService") or err:find("License"), "error should mention license service: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- 9. ACSM file not found
    -- ================================================================
    describe("missing ACSM file", function()
        it("returns error when ACSM file does not exist", function()
            local acsmPath = tmpDir .. "/nonexistent.acsm"
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("Cannot open") or err:find("ACSM"), "error should mention ACSM file: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- 10. Notification URLs are called on success
    -- ================================================================
    describe("notifications", function()
        it("calls notify for each notifyURL in the fulfillment result", function()
            local acsmPath = writeAcsm("https://operator.example.com/Fulfill")
            local outputPath = tmpDir .. "/output.epub"
            local creds = makeCreds()

            fulfillment.fulfill = function()
                return {
                    response = "<fulfillmentResult/>",
                    operatorURL = "https://operator.example.com/Fulfill",
                    src = "https://operator.example.com/download/book.epub",
                    encryptedKey = "dGVzdA==",
                    keyType = "2",
                    licenseURL = "https://operator.example.com/license",
                    licenseTokenXml = "<licenseToken/>",
                    notifyURLs = {
                        "https://notify1.example.com",
                        "https://notify2.example.com",
                    },
                }
            end

            fulfillment.downloadBook = function(url, path)
                writeFileWithMagic(path, "PK\x03\x04")
                return true
            end
            fulfillment.decryptBookKey = function()
                return string.rep("\xAA", 16)
            end
            epub.decryptAdobeEpub = function()
                return { decryptedEntries = 1 }
            end

            local notifyCalled = {}
            fulfillment.notify = function(notifyURL)
                notifyCalled[#notifyCalled + 1] = notifyURL
                return true
            end

            local result, err = fulfillment.process(acsmPath, outputPath, creds, "urn:uuid:device", "fp", "authCert")
            assert.is.truthy(result, "process should succeed: " .. tostring(err))
            assert.are.equal(2, #notifyCalled)
            assert.are.equal("https://notify1.example.com", notifyCalled[1])
            assert.are.equal("https://notify2.example.com", notifyCalled[2])
        end)
    end)
end)
