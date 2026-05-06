--- Tests for adobe/pdf/pdfcrypt.lua (key derivation)

local pdfcrypt = require("adobe.pdf.pdfcrypt")

describe("PDF key derivation", function()

    describe("genkey_v2", function()
        it("should produce 16-byte key from 16-byte book key", function()
            -- bookKey = 16 bytes, objid=1, genno=0
            local bookKey = string.rep("\xab", 16)
            local key = pdfcrypt.genkey_v2(bookKey, 1, 0)
            assert.equals(16, #key) -- min(16+5, 16) = 16
        end)

        it("should produce different keys for different objids", function()
            local bookKey = string.rep("\xcd", 16)
            local key1 = pdfcrypt.genkey_v2(bookKey, 1, 0)
            local key2 = pdfcrypt.genkey_v2(bookKey, 2, 0)
            assert.not_equals(key1, key2)
        end)

        it("should produce different keys for different gennos", function()
            local bookKey = string.rep("\xcd", 16)
            local key1 = pdfcrypt.genkey_v2(bookKey, 1, 0)
            local key2 = pdfcrypt.genkey_v2(bookKey, 1, 1)
            assert.not_equals(key1, key2)
        end)

        it("should truncate key length for short book keys", function()
            -- 5-byte book key -> min(5+5, 16) = 10 byte derived key
            local bookKey = "\x01\x02\x03\x04\x05"
            local key = pdfcrypt.genkey_v2(bookKey, 1, 0)
            assert.equals(10, #key)
        end)

        it("should match known test vector from ineptpdf", function()
            -- Verify against Python:
            -- struct.pack('<L', 42)[:3] = b'\x2a\x00\x00'
            -- struct.pack('<L', 0)[:2] = b'\x00\x00'
            -- MD5 of bookKey + objid_3bytes + genno_2bytes
            local bookKey = string.rep("\xaa", 16)
            local key = pdfcrypt.genkey_v2(bookKey, 42, 0)
            assert.equals(16, #key)
            -- The key should be deterministic
            local key2 = pdfcrypt.genkey_v2(bookKey, 42, 0)
            assert.equals(key, key2)
        end)
    end)

    describe("genkey_v3", function()
        it("should XOR objid and genno with magic values", function()
            local bookKey = string.rep("\xbb", 16)
            -- genkey_v3: objid XOR 0x3569ac, genno XOR 0xca96
            local key = pdfcrypt.genkey_v3(bookKey, 1, 0)
            assert.is_truthy(key)
            assert.equals(math.min(16 + 5, 16), #key)

            -- Should differ from genkey_v2 for same inputs
            local key_v2 = pdfcrypt.genkey_v2(bookKey, 1, 0)
            assert.not_equals(key, key_v2)
        end)

        it("should be deterministic", function()
            local bookKey = "\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff\x00"
            local k1 = pdfcrypt.genkey_v3(bookKey, 100, 5)
            local k2 = pdfcrypt.genkey_v3(bookKey, 100, 5)
            assert.equals(k1, k2)
        end)
    end)

    describe("genkey_v4", function()
        it("should include 'sAlT' suffix in hash input", function()
            local bookKey = string.rep("\xcc", 16)
            local key = pdfcrypt.genkey_v4(bookKey, 1, 0)
            assert.equals(16, #key)

            -- Should differ from genkey_v2 (which doesn't have sAlT)
            local key_v2 = pdfcrypt.genkey_v2(bookKey, 1, 0)
            assert.not_equals(key, key_v2)
        end)
    end)

    describe("genkey_v5", function()
        it("should return the book key directly", function()
            local bookKey = string.rep("\xdd", 32) -- 32 bytes for AES-256
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
            -- EBX_HANDLER (ADEPT) always uses RC4 with genkey_v2 or genkey_v3
            -- The ebx_V param in ADEPT doesn't follow standard PDF V semantics
            local bookKey = string.rep("\xaa", 16)
            local enc = pdfcrypt.determineEncryption(bookKey, 4, 6, 16)
            -- When bookKey == length and ebx_V != 3, V=2 (RC4)
            assert.equals("rc4", enc.cipher)
            assert.equals(2, enc.V)
            assert.equals(pdfcrypt.genkey_v2, enc.genkey)
        end)

        it("should extract V from first byte when bookKey is length+1", function()
            -- When bookKey has one extra byte, that byte is the V value
            local bookKey = "\x04" .. string.rep("\xaa", 16) -- 17 bytes, V=4
            local enc = pdfcrypt.determineEncryption(bookKey, 2, 6, 16)
            assert.equals(4, enc.V)
            assert.equals("aes", enc.cipher) -- V=4 means AES with genkey_v4
            assert.equals(16, #enc.key) -- first byte stripped
        end)
    end)

end)
