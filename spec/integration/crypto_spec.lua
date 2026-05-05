--- Integration tests: crypto round-trips with real OpenSSL
-- Verifies AES, SHA-1, RSA, and device key operations using
-- KOReader's bundled native crypto libraries.

describe("Crypto round-trips (real OpenSSL)", function()
    it("AES-128-CBC encrypt/decrypt round-trip", function()
        local nc = require("adobe.util.nativecrypto")
        local key = string.rep("\1", 16)
        local iv  = string.rep("\0", 16)
        local plaintext = "Hello KOReader!"

        local encrypted = assert(nc.aes_cbc_encrypt(key, iv, plaintext, false))
        local decrypted = assert(nc.aes_cbc_decrypt(key, iv, encrypted, false))
        assert.are.equal(plaintext, decrypted)
    end)

    it("AES streaming decrypt matches one-shot", function()
        local ffi = require("ffi")
        local nc  = require("adobe.util.nativecrypto")
        local data = string.rep("Streaming test data. ", 100)
        local key  = string.rep("\2", 16)
        local iv   = string.rep("\0", 16)

        local pad = 16 - (#data % 16)
        local padded = data .. string.rep(string.char(pad), pad)
        local encrypted = assert(nc.aes_cbc_encrypt(key, iv, padded, true))
        local oneshot = assert(nc.aes_cbc_decrypt(key, iv, encrypted, true))

        local decryptor = assert(nc.aes_cbc_decryptor(key, iv, true))
        local parts = {}
        for i = 1, #encrypted, 256 do
            local chunk = encrypted:sub(i, math.min(i + 255, #encrypted))
            decryptor:update(chunk, function(ptr, len)
                parts[#parts + 1] = ffi.string(ptr, len)
                return true
            end)
        end
        decryptor:finalize(function(ptr, len)
            parts[#parts + 1] = ffi.string(ptr, len)
            return true
        end)

        assert.are.equal(oneshot, table.concat(parts))
    end)

    it("SHA-1 produces 20 bytes", function()
        local nc = require("adobe.util.nativecrypto")
        local hash = assert(nc.sha1("test"))
        assert.are.equal(20, #hash)
    end)

    it("RSA keygen + sign", function()
        local nc = require("adobe.util.nativecrypto")
        local key = assert(nc.generate_rsa_key(1025, 65537))
        local data = "sign this message please"
        local hash = assert(nc.sha1(data))
        local sig = assert(key:sign_raw(hash))
        assert.is_truthy(#sig > 0)
    end)

    it("Device key encrypt/decrypt round-trip", function()
        local crypto = require("adobe.util.crypto")
        local plaintext = "my-secret-device-key!"
        local devKey = crypto.deviceKey.new()
        local encrypted = assert(devKey:encrypt(plaintext))
        assert.is_not.equal(plaintext, encrypted)
        local decrypted = assert(devKey:decrypt(encrypted))
        assert.are.equal(plaintext, decrypted)
    end)
end)
