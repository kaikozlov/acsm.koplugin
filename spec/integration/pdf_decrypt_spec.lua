--- Integration tests: adobe/pdf.lua internal helpers
-- Tests the underscore-exported helpers for PDF ADEPT decryption:
-- findRightsText, extractEncryptedKey, extractRights,
-- make_rc4_decipher, make_aes_decipher.
-- Uses real KOReader crypto and zlib — no mocking.

describe("PDF decryption helpers", function()
    local pdf, pdfcrypt, rc4, nc, util

    setup(function()
        pdf = require("adobe.pdf")
        pdfcrypt = require("adobe.pdf.pdfcrypt")
        rc4 = require("adobe.pdf.rc4")
        nc = require("adobe.util.nativecrypto")
        util = require("adobe.util.util")
    end)

    -- ================================================================
    -- findRightsText
    -- ================================================================
    describe("findRightsText", function()
        it("finds bare element name at top level", function()
            local rights = { resource = "urn:uuid:abc-123" }
            assert.are.equal("urn:uuid:abc-123", pdf._findRightsText(rights, "resource"))
        end)

        it("finds bare element as table with text child", function()
            local rights = { resource = { "urn:uuid:abc-123" } }
            assert.are.equal("urn:uuid:abc-123", pdf._findRightsText(rights, "resource"))
        end)

        it("finds namespaced element name", function()
            local nsKey = "{http://ns.adobe.com/adept}resource"
            local rights = { [nsKey] = "urn:uuid:ns-456" }
            assert.are.equal("urn:uuid:ns-456", pdf._findRightsText(rights, "resource"))
        end)

        it("recurses into nested tables", function()
            local rights = {
                outer = {
                    inner = {
                        device = "urn:uuid:nested-device",
                    },
                },
            }
            assert.are.equal("urn:uuid:nested-device", pdf._findRightsText(rights, "device"))
        end)

        it("returns nil for missing element", function()
            local rights = { resource = "value" }
            assert.is_nil(pdf._findRightsText(rights, "nonexistent"))
        end)

        it("returns nil for non-table input", function()
            assert.is_nil(pdf._findRightsText("not a table", "resource"))
            assert.is_nil(pdf._findRightsText(nil, "resource"))
        end)
    end)

    -- ================================================================
    -- extractEncryptedKey
    -- ================================================================
    describe("extractEncryptedKey", function()
        it("extracts from table with text child", function()
            local rights = {
                licenseToken = {
                    encryptedKey = { "dGVzdC1rZXk=", keyType = "2" },
                },
            }
            local encKey, keyType = pdf._extractEncryptedKey(rights)
            assert.are.equal("dGVzdC1rZXk=", encKey)
            assert.are.equal("2", keyType)
        end)

        it("extracts from bare string value", function()
            local rights = {
                encryptedKey = "dGVzdC1rZXk=",
            }
            local encKey, keyType = pdf._extractEncryptedKey(rights)
            assert.are.equal("dGVzdC1rZXk=", encKey)
            assert.are.equal("0", keyType) -- default keyType
        end)

        it("returns nil when no encryptedKey present", function()
            local rights = { somethingElse = "value" }
            local encKey = pdf._extractEncryptedKey(rights)
            assert.is_nil(encKey)
        end)

        it("extracts from namespaced key", function()
            local nsKey = "{http://ns.adobe.com/adept}encryptedKey"
            local rights = {
                [nsKey] = { "c2VjcmV0", keyType = "5" },
            }
            local encKey, keyType = pdf._extractEncryptedKey(rights)
            assert.are.equal("c2VjcmV0", encKey)
            assert.are.equal("5", keyType)
        end)
    end)

    -- ================================================================
    -- extractRights
    -- ================================================================
    describe("extractRights", function()
        local ffi

        --- Raw deflate using zlib FFI (matching epub_spec approach).
        local function rawDeflate(data)
            ffi = ffi or require("ffi")
            pcall(
                ffi.cdef,
                [[
                int deflateInit2_(z_stream *strm, int level, int method, int windowBits,
                                  int memLevel, int strategy, const char *version, int stream_size);
                int deflate(z_stream *strm, int flush);
                int deflateEnd(z_stream *strm);
            ]]
            )
            local libz
            if ffi.loadlib then
                libz = ffi.loadlib("z", "1")
            else
                libz = ffi.load("z")
            end
            local stream = ffi.new("z_stream[1]")
            local rc = libz.deflateInit2_(stream, 6, 8, -15, 8, 0, libz.zlibVersion(), ffi.sizeof(stream[0]))
            assert(rc == 0, "deflateInit2 failed: " .. tostring(rc))
            stream[0].next_in = ffi.cast("Bytef *", data)
            stream[0].avail_in = #data
            local CHUNK = 32768
            local outbuf = ffi.new("uint8_t[?]", CHUNK)
            local chunks = {}
            repeat
                stream[0].next_out = outbuf
                stream[0].avail_out = CHUNK
                rc = libz.deflate(stream, 4) -- Z_FINISH
                local produced = CHUNK - tonumber(stream[0].avail_out)
                if produced > 0 then
                    chunks[#chunks + 1] = ffi.string(outbuf, produced)
                end
            until rc == 1 -- Z_STREAM_END
            libz.deflateEnd(stream)
            return table.concat(chunks)
        end

        --- Helper to build a fake ADEPT_LICENSE string:
        -- XML → raw deflate → base64 encode
        local function makeAdeptLicense(xmlStr)
            local compressed = rawDeflate(xmlStr)
            return util.base64.encode(compressed)
        end

        it("extracts rights from direct ADEPT_LICENSE string", function()
            local rightsXml = [[<?xml version="1.0"?>
<rights>
  <licenseToken>
    <encryptedKey>dGVzdA==</encryptedKey>
  </licenseToken>
</rights>]]

            local license = makeAdeptLicense(rightsXml)
            local mockDoc = {
                _loadRawObject = function()
                    return nil
                end,
            }
            local encParam = { ADEPT_LICENSE = license }
            local rights, err = pdf._extractRights(mockDoc, encParam)
            assert.is.truthy(rights, "extractRights failed: " .. tostring(err))
        end)

        it("returns error for missing ADEPT_LICENSE", function()
            local mockDoc = {
                _loadRawObject = function()
                    return nil
                end,
            }
            local encParam = { Filter = "EBX_HANDLER", V = 4 }
            local rights, err = pdf._extractRights(mockDoc, encParam)
            assert.is_nil(rights)
            assert.is.truthy(err)
            assert.is.truthy(err:find("No ADEPT_LICENSE"))
        end)

        it("handles stream object encParam (rawdata is ADEPT_LICENSE)", function()
            local rightsXml = [[<?xml version="1.0"?><rights><data>ok</data></rights>]]
            local license = makeAdeptLicense(rightsXml)
            local mockDoc = {
                _loadRawObject = function()
                    return nil
                end,
            }
            -- Stream object: has dic and rawdata, no direct ADEPT_LICENSE key
            local encParam = {
                dic = { Filter = "EBX_HANDLER" },
                rawdata = license,
            }
            local rights, err = pdf._extractRights(mockDoc, encParam)
            assert.is.truthy(rights, "extractRights (stream) failed: " .. tostring(err))
        end)
    end)

    -- ================================================================
    -- make_rc4_decipher
    -- ================================================================
    describe("make_rc4_decipher", function()
        it("deciphers with genkey_v2 and RC4", function()
            local bookKey = string.rep(string.char(0xAA), 16)
            local decipher = pdf._make_rc4_decipher(bookKey, pdfcrypt.genkey_v2)

            -- Encrypt some test data with the same key derivation
            local objid, genno = 42, 0
            local plaintext = "Hello PDF World!"
            local key = pdfcrypt.genkey_v2(bookKey, objid, genno)
            local state = rc4.init(key)
            local encrypted = rc4.crypt(state, plaintext)

            -- Decipher should recover the plaintext
            local decrypted = decipher(objid, genno, encrypted)
            assert.are.equal(plaintext, decrypted)
        end)

        it("produces different output for different objids", function()
            local bookKey = string.rep(string.char(0xBB), 16)
            local decipher = pdf._make_rc4_decipher(bookKey, pdfcrypt.genkey_v2)

            local data = "same data for both"
            local result1 = decipher(1, 0, data)
            local result2 = decipher(2, 0, data)
            assert.are_not.equal(result1, result2)
        end)
    end)

    -- ================================================================
    -- make_aes_decipher
    -- ================================================================
    describe("make_aes_decipher", function()
        -- genkey_v5 returns the book key unchanged (for AES-256)
        local function genkey_identity(bookKey, objid, genno)
            return bookKey
        end

        it("deciphers AES-CBC with IV prefix and PKCS7 padding", function()
            local bookKey = string.rep(string.char(0xCC), 16)
            local plaintext = "Hello AES PDF!"

            -- Build encrypted data: 16-byte IV + AES-CBC(plaintext + PKCS7)
            local iv = string.rep(string.char(0x00), 16)

            -- PKCS7 pad
            local padLen = 16 - (#plaintext % 16)
            local padded = plaintext .. string.rep(string.char(padLen), padLen)

            local encrypted = nc.aes_cbc_encrypt(bookKey, iv, padded, true)
            assert.is.truthy(encrypted)

            -- Prepend IV to create the data format that make_aes_decipher expects
            local ciphertext = iv .. encrypted

            local decipher = pdf._make_aes_decipher(bookKey, genkey_identity)
            local decrypted = decipher(1, 0, ciphertext)
            assert.are.equal(plaintext, decrypted)
        end)

        it("returns short data unchanged (< 32 bytes)", function()
            local bookKey = string.rep(string.char(0xDD), 16)
            local decipher = pdf._make_aes_decipher(bookKey, genkey_identity)

            local shortData = "too short"
            assert.is_true(#shortData < 32)
            assert.are.equal(shortData, decipher(1, 0, shortData))
        end)

        it("does not accept inconsistent PKCS7 padding bytes", function()
            local bookKey = string.rep(string.char(0xEF), 16)
            local iv = string.rep(string.char(0), 16)
            local malformed = string.rep("A", 14) .. string.char(0x99, 0x02)
            local encrypted = nc.aes_cbc_encrypt(bookKey, iv, malformed, true)
            local ciphertext = iv .. encrypted

            local decipher = pdf._make_aes_decipher(bookKey, genkey_identity)
            assert.are.equal(ciphertext, decipher(1, 0, ciphertext))
        end)

        it("handles exact block-size plaintext (full padding block)", function()
            local bookKey = string.rep(string.char(0xEE), 16)
            -- 16 bytes exactly → PKCS7 adds a full 16-byte padding block
            local plaintext = "0123456789ABCDEF"
            assert.are.equal(16, #plaintext)

            local iv = nc.rand_bytes(16)
            local padded = plaintext .. string.rep(string.char(16), 16)
            local encrypted = nc.aes_cbc_encrypt(bookKey, iv, padded, true)
            local ciphertext = iv .. encrypted

            local decipher = pdf._make_aes_decipher(bookKey, genkey_identity)
            local decrypted = decipher(1, 0, ciphertext)
            assert.are.equal(plaintext, decrypted)
        end)

        it("produces different output for different objids with genkey_v2", function()
            local bookKey = string.rep(string.char(0xFF), 16)
            local decipher = pdf._make_aes_decipher(bookKey, pdfcrypt.genkey_v2)

            -- Create two ciphertexts with different per-object keys
            local iv = string.rep(string.char(0), 16)
            local plain = "test data here!!" -- 16 bytes
            local padded = plain .. string.rep(string.char(16), 16)

            local key1 = pdfcrypt.genkey_v2(bookKey, 1, 0)
            local key2 = pdfcrypt.genkey_v2(bookKey, 2, 0)
            local enc1 = iv .. nc.aes_cbc_encrypt(key1, iv, padded, true)
            local enc2 = iv .. nc.aes_cbc_encrypt(key2, iv, padded, true)

            local dec1 = decipher(1, 0, enc1)
            local dec2 = decipher(2, 0, enc2)
            -- Both should decrypt to the same plaintext
            assert.are.equal(plain, dec1)
            assert.are.equal(plain, dec2)
        end)
    end)
end)
