--- Tests for adobe/pdf/rc4.lua (RC4 stream cipher)

local rc4 = require("adobe.pdf.rc4")

describe("RC4 cipher", function()

    it("should handle empty input", function()
        local state = rc4.init("Key")
        local result = rc4.crypt(state, "")
        assert.equals("", result)
    end)

    it("should match RFC 6229 test vector for Key='Key', Plaintext='Plaintext'", function()
        -- Known RC4 test: key="Key", plaintext="Plaintext"
        -- Expected ciphertext (hex): bbf316e8d940af0ad3
        local state = rc4.init("Key")
        local cipher = rc4.crypt(state, "Plaintext")
        local expected = string.char(0xbb, 0xf3, 0x16, 0xe8, 0xd9, 0x40, 0xaf, 0x0a, 0xd3)
        assert.equals(expected, cipher)
    end)

    it("should be self-inverse (encrypt then decrypt)", function()
        local key = "testkey123"
        local plaintext = "Hello, World! This is a test of RC4."
        local enc_state = rc4.init(key)
        local encrypted = rc4.crypt(enc_state, plaintext)
        assert.not_equals(plaintext, encrypted)  -- should be different

        local dec_state = rc4.init(key)
        local decrypted = rc4.crypt(dec_state, encrypted)
        assert.equals(plaintext, decrypted)
    end)

    it("should produce same output for same key and data", function()
        local key = "SecretKey"
        local data = "Some data to encrypt"
        local s1 = rc4.init(key)
        local r1 = rc4.crypt(s1, data)
        local s2 = rc4.init(key)
        local r2 = rc4.crypt(s2, data)
        assert.equals(r1, r2)
    end)

    it("should handle binary data", function()
        local key = "\x00\x01\x02\x03"
        local data = ""
        for i = 0, 255 do
            data = data .. string.char(i)
        end
        local enc_state = rc4.init(key)
        local encrypted = rc4.crypt(enc_state, data)
        assert.equals(256, #encrypted)

        local dec_state = rc4.init(key)
        local decrypted = rc4.crypt(dec_state, encrypted)
        assert.equals(data, decrypted)
    end)

    it("should handle single-byte key", function()
        local key = "\x00"
        local data = "\x00\x00\x00\x00"
        local state = rc4.init(key)
        local result = rc4.crypt(state, data)
        assert.equals(4, #result)
        -- Should not be all zeros
        assert.not_equals("\x00\x00\x00\x00", result)
    end)

    it("should handle streaming (multiple crypt calls on same state)", function()
        local key = "StreamKey"
        local s1 = rc4.init(key)
        local full = rc4.crypt(s1, "HelloWorld")

        local s2 = rc4.init(key)
        local part1 = rc4.crypt(s2, "Hello")
        local part2 = rc4.crypt(s2, "World")
        local streamed = part1 .. part2

        assert.equals(full, streamed)
    end)

end)
