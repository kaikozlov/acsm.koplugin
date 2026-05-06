--- Tests for adobe/pdf/pdfcrypt.lua (key derivation)
-- All genkey test vectors are verified against Python ineptpdf.py.
-- removeHardening tests use round-trip AES-CBC to verify correctness,
-- not just type-equality or nil-tolerance checks.

local pdfcrypt = require("adobe.pdf.pdfcrypt")

-- Helper: convert hex string to raw bytes for test vectors
local function hex2bin(hex)
    local parts = {}
    for i = 1, #hex, 2 do
        parts[#parts + 1] = string.char(tonumber(hex:sub(i, i+1), 16))
    end
    return table.concat(parts)
end

-- Build known-answer book keys from Python test vectors
local BOOKKEY_AA16 = hex2bin("aa"):rep(16)
local BOOKKEY_CD16 = hex2bin("cd"):rep(16)
local BOOKKEY_MIXED16 = hex2bin("112233445566778899aabbccddeeff00")
local BOOKKEY_5BYTES = hex2bin("0102030405")

describe("PDF key derivation", function()

    describe("genkey_v2", function()
        it("should match Python for \\xaa*16, objid=1, genno=0", function()
            local key = pdfcrypt.genkey_v2(BOOKKEY_AA16, 1, 0)
            local expected = hex2bin("3916ec921c6defb0e6aac563c463b585")
            assert.equals(expected, key)
            assert.equals(16, #key)
        end)

        it("should match Python for \\xcd*16, objid=1, genno=0", function()
            local key = pdfcrypt.genkey_v2(BOOKKEY_CD16, 1, 0)
            local expected = hex2bin("5716e1886b5287055abaf08ac1b00c9e")
            assert.equals(expected, key)
        end)

        it("should match Python for \\xcd*16, objid=2, genno=0", function()
            local key = pdfcrypt.genkey_v2(BOOKKEY_CD16, 2, 0)
            local expected = hex2bin("22aa9e52690aa105de58a053d89ababb")
            assert.equals(expected, key)
        end)

        it("should match Python for \\xcd*16, objid=1, genno=1", function()
            local key = pdfcrypt.genkey_v2(BOOKKEY_CD16, 1, 1)
            local expected = hex2bin("3fb37256ff8d69045f438d6a4511516b")
            assert.equals(expected, key)
        end)

        it("should match Python for 5-byte key, objid=1, genno=0 (truncation)", function()
            local key = pdfcrypt.genkey_v2(BOOKKEY_5BYTES, 1, 0)
            local expected = hex2bin("7e1a77f3ede500fa210b")
            assert.equals(expected, key)
            assert.equals(10, #key)
        end)

        it("should match Python for \\xaa*16, objid=42, genno=0", function()
            local key = pdfcrypt.genkey_v2(BOOKKEY_AA16, 42, 0)
            local expected = hex2bin("37993001344a007cac14aabec97ff9eb")
            assert.equals(expected, key)
            assert.equals(16, #key)
        end)
    end)

    describe("genkey_v3", function()
        it("should match Python for mixed 16-byte key, objid=100, genno=5", function()
            local key = pdfcrypt.genkey_v3(BOOKKEY_MIXED16, 100, 5)
            local expected = hex2bin("3e807d93ae949d4ab3a8368cd56cf580")
            assert.equals(expected, key)
            assert.equals(16, #key)
        end)

        it("should be deterministic (same inputs -> same output)", function()
            local k1 = pdfcrypt.genkey_v3(BOOKKEY_MIXED16, 100, 5)
            local k2 = pdfcrypt.genkey_v3(BOOKKEY_MIXED16, 100, 5)
            assert.equals(k1, k2)
        end)

        it("should differ from genkey_v2 for same inputs", function()
            local key_v3 = pdfcrypt.genkey_v3(BOOKKEY_AA16, 1, 0)
            local key_v2 = pdfcrypt.genkey_v2(BOOKKEY_AA16, 1, 0)
            assert.not_equals(key_v3, key_v2)
        end)
    end)

    describe("genkey_v4", function()
        it("should match Python for \\xaa*16, objid=1, genno=0", function()
            local key = pdfcrypt.genkey_v4(BOOKKEY_AA16, 1, 0)
            local expected = hex2bin("6d391ce5e0a480d55095f87e5e661213")
            assert.equals(expected, key)
            assert.equals(16, #key)
        end)

        it("should differ from genkey_v2 (sAlT suffix)", function()
            local key_v4 = pdfcrypt.genkey_v4(BOOKKEY_AA16, 1, 0)
            local key_v2 = pdfcrypt.genkey_v2(BOOKKEY_AA16, 1, 0)
            assert.not_equals(key_v4, key_v2)
        end)
    end)

    describe("genkey_v5", function()
        it("should return the book key directly", function()
            local bookKey = string.rep("\xdd", 32)
            local key = pdfcrypt.genkey_v5(bookKey, 1, 0)
            assert.equals(bookKey, key)
        end)

        it("should ignore objid and genno", function()
            local bookKey = "\x01\x02\x03"
            local k1 = pdfcrypt.genkey_v5(bookKey, 1, 0)
            local k2 = pdfcrypt.genkey_v5(bookKey, 999, 99)
            assert.equals(k1, k2)
        end)
    end)

    describe("determineEncryption", function()
        it("should return RC4 with genkey_v2 for V=2 by default", function()
            local bookKey = string.rep("\xaa", 16)
            local enc = pdfcrypt.determineEncryption(bookKey, 2, 6, 16)
            assert.equals("rc4", enc.cipher)
            assert.equals(2, enc.V)
            assert.equals(pdfcrypt.genkey_v2, enc.genkey)
        end)

        it("should return RC4 with genkey_v3 when ebx_V=3", function()
            local bookKey = string.rep("\xaa", 16)
            local enc = pdfcrypt.determineEncryption(bookKey, 3, 6, 16)
            assert.equals("rc4", enc.cipher)
            assert.equals(3, enc.V)
            assert.equals(pdfcrypt.genkey_v3, enc.genkey)
        end)

        it("should fall back to V=2/RC4 for EBX even with ebx_V=4", function()
            local bookKey = string.rep("\xaa", 16)
            local enc = pdfcrypt.determineEncryption(bookKey, 4, 6, 16)
            assert.equals("rc4", enc.cipher)
            assert.equals(2, enc.V)
            assert.equals(pdfcrypt.genkey_v2, enc.genkey)
        end)

        it("should extract V from first byte when bookKey is length+1", function()
            local bookKey = "\x04" .. string.rep("\xaa", 16)
            local enc = pdfcrypt.determineEncryption(bookKey, 2, 6, 16)
            assert.equals(4, enc.V)
            assert.equals("rc4", enc.cipher)
            assert.equals(16, #enc.key)
            assert.equals(pdfcrypt.genkey_v2, enc.genkey)
        end)
    end)

    describe("removeHardening", function()
        local nativecrypto = require("adobe.util.nativecrypto")

        -- UUIDs used across all removeHardening tests
        local RES_UUID = "00000000-0000-0000-0000-000000000001"
        local DEV_UUID = "00000000-0000-0000-0000-000000000002"
        local FUL_UUID = "00000000-0000-0000-0000-000000000003"

        -- Helper: compute the KEK and IV that removeHardening will derive,
        -- then AES-CBC encrypt plaintext so removeHardening can decrypt it.
        -- This is a TRUE round-trip test — no nil-tolerance hacks.
        local function encrypt_for_removeHardening(keyType, plaintext, res, dev, ful)
            local ffi = require("ffi")
            local sha2 = require("ffi/sha2")

            -- Derive KEK (same as removeHardening)
            local rem = tonumber(keyType) % 16
            local Hbytes = sha2.hex2bin(sha2.sha256(keyType))
            local kek = Hbytes:sub(2 * rem + 1, 16 + rem) .. Hbytes:sub(rem + 1, 2 * rem)

            -- Derive IV from XOR of 3 UUIDs (same as removeHardening)
            local function uuidToBytes(str)
                str = str:gsub("-", "")
                local bytes = {}
                for i = 1, 32, 2 do
                    bytes[#bytes + 1] = string.char(tonumber(str:sub(i, i+1), 16))
                end
                return table.concat(bytes)
            end
            local rBytes = uuidToBytes(res)
            local dBytes = uuidToBytes(dev)
            local fBytes = uuidToBytes(ful)
            local ivParts = {}
            for i = 1, 16 do
                ivParts[i] = string.char(
                    bit.bxor(rBytes:byte(i), bit.bxor(dBytes:byte(i), fBytes:byte(i))))
            end
            local iv = table.concat(ivParts)

            -- PKCS7-pad the plaintext
            local padLen = 16 - (#plaintext % 16)
            if padLen == 0 then padLen = 16 end
            local padded = plaintext .. string.rep(string.char(padLen), padLen)

            -- AES-CBC encrypt (no_padding=true = we provide pre-padded data)
            local ciphertext = nativecrypto.aes_cbc_encrypt(kek, iv, padded, true)
            return ciphertext
        end

        it("should round-trip: encrypt then decrypt for keyType=3", function()
            local plaintext = "Hello, World! DRM"
            local keyType = "3"
            local ciphertext = encrypt_for_removeHardening(
                keyType, plaintext, RES_UUID, DEV_UUID, FUL_UUID)

            local result = pdfcrypt.removeHardening(
                ciphertext, keyType, RES_UUID, DEV_UUID, FUL_UUID,
                nativecrypto.aes_cbc_decrypt)
            assert.is_truthy(result, "removeHardening returned nil")
            assert.equals("string", type(result))
            assert.equals(plaintext, result)
        end)

        it("should round-trip for keyType=10", function()
            local plaintext = "Different key type test!"
            local keyType = "10"
            local ciphertext = encrypt_for_removeHardening(
                keyType, plaintext, RES_UUID, DEV_UUID, FUL_UUID)

            local result = pdfcrypt.removeHardening(
                ciphertext, keyType, RES_UUID, DEV_UUID, FUL_UUID,
                nativecrypto.aes_cbc_decrypt)
            assert.is_truthy(result, "removeHardening returned nil")
            assert.equals(plaintext, result)
        end)

        it("should produce different results for different resource UUIDs", function()
            local plaintext = "UUID sensitivity check"
            local keyType = "3"
            local altRes = "00000000-0000-0000-0000-000000000004"

            -- Encrypt with RES_UUID (the "correct" UUID)
            local ciphertext = encrypt_for_removeHardening(
                keyType, plaintext, RES_UUID, DEV_UUID, FUL_UUID)

            -- Decrypt with the CORRECT UUIDs (should work)
            local correct = pdfcrypt.removeHardening(
                ciphertext, keyType, RES_UUID, DEV_UUID, FUL_UUID,
                nativecrypto.aes_cbc_decrypt)
            assert.is_truthy(correct)
            assert.equals(plaintext, correct)

            -- Decrypt with a DIFFERENT resource UUID (IV mismatch → garbage/corruption)
            local wrong = pdfcrypt.removeHardening(
                ciphertext, keyType, altRes, DEV_UUID, FUL_UUID,
                nativecrypto.aes_cbc_decrypt)
            -- With mismatched IV, the first block decrypts wrong but CBC recovers
            -- remaining blocks. The result will differ from the original.
            assert.is_truthy(wrong, "Different UUID shouldn't crash, just produce wrong output")
            assert.not_equals(plaintext, wrong,
                "Different resource UUID should produce different decryption output")
        end)

        it("should produce different results for different keyTypes", function()
            local plaintext = "KeyType sensitivity test!!!"
            local keyType3 = "3"
            local keyType7 = "7"

            local ct3 = encrypt_for_removeHardening(
                keyType3, plaintext, RES_UUID, DEV_UUID, FUL_UUID)
            local ct7 = encrypt_for_removeHardening(
                keyType7, plaintext, RES_UUID, DEV_UUID, FUL_UUID)

            -- Decrypt each with its matching keyType
            local r3 = pdfcrypt.removeHardening(
                ct3, keyType3, RES_UUID, DEV_UUID, FUL_UUID, nativecrypto.aes_cbc_decrypt)
            local r7 = pdfcrypt.removeHardening(
                ct7, keyType7, RES_UUID, DEV_UUID, FUL_UUID, nativecrypto.aes_cbc_decrypt)

            -- Both should recover the same plaintext with their matching keyTypes
            assert.is_truthy(r3)
            assert.equals(plaintext, r3)
            assert.is_truthy(r7)
            assert.equals(plaintext, r7)

            -- But cross-decrypting (keyType3's ciphertext with keyType7's key)
            -- should produce WRONG output (different KEK)
            local cross = pdfcrypt.removeHardening(
                ct3, keyType7, RES_UUID, DEV_UUID, FUL_UUID, nativecrypto.aes_cbc_decrypt)
            -- Cross-decrypt may return nil (bad padding) or wrong plaintext
            -- Either way, it should NOT equal the original
            if cross then
                assert.not_equals(plaintext, cross,
                    "Cross-keyType decryption should not produce correct plaintext")
            end
        end)

        it("should be deterministic (same inputs -> same output)", function()
            local plaintext = "Determinism test string!!!!"
            local keyType = "5"
            local ciphertext = encrypt_for_removeHardening(
                keyType, plaintext, RES_UUID, DEV_UUID, FUL_UUID)

            local r1 = pdfcrypt.removeHardening(
                ciphertext, keyType, RES_UUID, DEV_UUID, FUL_UUID,
                nativecrypto.aes_cbc_decrypt)
            local r2 = pdfcrypt.removeHardening(
                ciphertext, keyType, RES_UUID, DEV_UUID, FUL_UUID,
                nativecrypto.aes_cbc_decrypt)
            assert.equals(plaintext, r1)
            assert.equals(r1, r2)
        end)
    end)

end)
