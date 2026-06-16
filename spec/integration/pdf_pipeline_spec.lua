--- Integration test: PDF decryptAdobePdf pipeline with synthetic encrypted PDF
-- Builds a minimal ADEPT-encrypted PDF on the fly, then runs the full
-- decryptAdobePdf pipeline to verify end-to-end decryption.

describe("PDF decryptAdobePdf pipeline (synthetic PDF)", function()
    local pdf, nc, pdfcrypt, rc4, koutil, crypto

    setup(function()
        pdf = require("adobe.pdf")
        nc = require("adobe.util.nativecrypto")
        pdfcrypt = require("adobe.pdf.pdfcrypt")
        rc4 = require("adobe.pdf.rc4")
        koutil = require("util")
        crypto = require("adobe.util.crypto")
    end)

    --- Build a minimal PDF with EBX_HANDLER encryption.
    -- Objects are RC4-encrypted with a known book key using genkey_v2.
    -- The /Encrypt dict has V=2, EBX_ENCRYPTIONTYPE=6, Length=128.
    local function buildEncryptedPdf(tmpDir, bookKey)
        -- Object layout:
        --   1 0 obj: Catalog (root)
        --   2 0 obj: Pages
        --   3 0 obj: Page
        --   4 0 obj: Encrypt dict
        --   5 0 obj: a text string object (to verify decryption)

        local function rc4Encrypt(key, objid, genno, data)
            local k = pdfcrypt.genkey_v2(key, objid, genno)
            local state = rc4.init(k)
            return rc4.crypt(state, data)
        end

        -- Build PDF content
        local lines = {}
        local offsets = {}

        -- Header
        lines[#lines + 1] = "%PDF-1.4\n"

        -- Object 1: Catalog
        offsets[1] = #table.concat(lines)
        lines[#lines + 1] = "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n"

        -- Object 2: Pages
        offsets[2] = #table.concat(lines)
        lines[#lines + 1] = "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n"

        -- Object 3: Page
        offsets[3] = #table.concat(lines)
        lines[#lines + 1] = "3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n"

        -- Object 4: Encrypt dict (EBX_HANDLER)
        offsets[4] = #table.concat(lines)
        lines[#lines + 1] = "4 0 obj\n<< /Filter /EBX_HANDLER /V 2 /EBX_ENCRYPTIONTYPE 6 /Length 128 >>\nendobj\n"

        -- Object 5: String object with encrypted content
        offsets[5] = #table.concat(lines)
        local testString = "Decrypted PDF content works!"
        local encString = rc4Encrypt(bookKey, 5, 0, testString)
        -- Hex-encode the encrypted string for the PDF
        local hexStr = ""
        for i = 1, #encString do
            hexStr = hexStr .. string.format("%02X", encString:byte(i))
        end
        lines[#lines + 1] = "5 0 obj\n<" .. hexStr .. ">\nendobj\n"

        -- xref table
        local xrefOffset = #table.concat(lines)
        lines[#lines + 1] = "xref\n"
        lines[#lines + 1] = "0 6\n"
        lines[#lines + 1] = string.format("%010d %05d f \n", 0, 65535)
        for id = 1, 5 do
            lines[#lines + 1] = string.format("%010d %05d n \n", offsets[id], 0)
        end

        -- trailer
        lines[#lines + 1] = "trailer\n"
        lines[#lines + 1] = "<< /Size 6 /Root 1 0 R /Encrypt 4 0 R /ID [<AABB> <CCDD>] >>\n"
        lines[#lines + 1] = "startxref\n"
        lines[#lines + 1] = tostring(xrefOffset) .. "\n"
        lines[#lines + 1] = "%%EOF\n"

        local pdfContent = table.concat(lines)
        local pdfPath = tmpDir .. "/test_encrypted.pdf"
        koutil.writeToFile(pdfContent, pdfPath)
        return pdfPath
    end

    it("decrypts a synthetic RC4-encrypted PDF", function()
        local DataStorage = require("datastorage")
        local tmpDir = DataStorage:getDataDir() .. "/test-pdf-pipeline-" .. tostring(os.time())
        koutil.makePath(tmpDir)

        local bookKey = string.rep(string.char(0xAA), 16)
        local inputPath = buildEncryptedPdf(tmpDir, bookKey)
        local outputPath = tmpDir .. "/decrypted.pdf"

        local result, err = pdf.decryptAdobePdf(inputPath, outputPath, bookKey)
        assert.is.truthy(result, "decryptAdobePdf failed: " .. tostring(err))
        assert.are.equal(outputPath, result.outputPath)
        assert.is_true(result.decryptedObjects > 0)

        -- Verify output is a valid PDF
        local f = io.open(outputPath, "rb")
        assert.is.truthy(f, "Output file not created")
        local header = f:read(8)
        f:close()
        assert.is.truthy(header:find("%%PDF"), "Output should start with %PDF")

        os.execute("rm -rf " .. tmpDir)
    end)

    it("decrypts using licenseKey extraction path", function()
        -- This tests the path where bookKey is nil and licenseKey is provided,
        -- but the PDF doesn't have ADEPT_LICENSE, so it falls back to
        -- fulfillmentEncryptedKey. This simulates older ADEPT PDFs.
        local DataStorage = require("datastorage")
        local tmpDir = DataStorage:getDataDir() .. "/test-pdf-lk-" .. tostring(os.time())
        koutil.makePath(tmpDir)

        local licenseKey = crypto.key.new()
        local bookKey = string.rep(string.char(0xBB), 16)

        -- Encrypt the book key with the license key's public key
        local encBookKey = assert(licenseKey.pkey:encrypt(bookKey, nc.RSA_PKCS1_PADDING))
        local util = require("adobe.util.util")
        local encBookKeyB64 = util.base64.encode(encBookKey)

        local inputPath = buildEncryptedPdf(tmpDir, bookKey)
        local outputPath = tmpDir .. "/decrypted.pdf"

        local result, err = pdf.decryptAdobePdf(inputPath, outputPath, nil, licenseKey, encBookKeyB64)
        assert.is.truthy(result, "decryptAdobePdf (licenseKey) failed: " .. tostring(err))
        assert.is_true(result.decryptedObjects > 0)

        os.execute("rm -rf " .. tmpDir)
    end)

    it("returns error for non-encrypted PDF", function()
        local DataStorage = require("datastorage")
        local tmpDir = DataStorage:getDataDir() .. "/test-pdf-noenc-" .. tostring(os.time())
        koutil.makePath(tmpDir)

        -- Minimal unencrypted PDF (no /Encrypt)
        local pdfContent = "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n"
            .. "xref\n0 2\n0000000000 65535 f \n0000000010 00000 n \n"
            .. "trailer\n<< /Size 2 /Root 1 0 R >>\nstartxref\n56\n%%EOF\n"
        local pdfPath = tmpDir .. "/plain.pdf"
        koutil.writeToFile(pdfContent, pdfPath)

        local result, err = pdf.decryptAdobePdf(pdfPath, tmpDir .. "/out.pdf", nil, nil, nil)
        assert.is_nil(result)
        assert.is.truthy(err)

        os.execute("rm -rf " .. tmpDir)
    end)
end)
