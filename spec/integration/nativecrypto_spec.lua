--- Integration tests: nativecrypto edge cases
-- Tests error handling, key serialization round-trips, and edge cases
-- for nativecrypto functions not covered by crypto_spec.lua.

describe("nativecrypto edge cases", function()
    local nc

    setup(function()
        nc = require("adobe.util.nativecrypto")
    end)

    describe("rand_bytes", function()
        it("produces requested length", function()
            assert.are.equal(32, #assert(nc.rand_bytes(32)))
        end)
        it("produces different values each call", function()
            assert.are_not.equal(assert(nc.rand_bytes(16)), assert(nc.rand_bytes(16)))
        end)
        it("handles small sizes", function()
            assert.are.equal(1, #assert(nc.rand_bytes(1)))
        end)
    end)

    describe("sha1", function()
        it("produces correct hash for 'abc'", function()
            local hash = assert(nc.sha1("abc"))
            local hex = ""
            for i = 1, #hash do hex = hex .. string.format("%02x", hash:byte(i)) end
            assert.are.equal("a9993e364706816aba3e25717850c26c9cd0d89d", hex)
        end)
        it("produces correct hash for empty string", function()
            local hash = assert(nc.sha1(""))
            local hex = ""
            for i = 1, #hash do hex = hex .. string.format("%02x", hash:byte(i)) end
            assert.are.equal("da39a3ee5e6b4b0d3255bfef95601890afd80709", hex)
        end)
    end)

    describe("RSA key operations", function()
        it("encrypt/decrypt round-trip", function()
            local key = assert(nc.generate_rsa_key(1025, 65537))
            local pt = "Hello RSA!"
            assert.are.equal(pt, assert(key:decrypt(assert(key:encrypt(pt, nc.RSA_PKCS1_PADDING)), nc.RSA_PKCS1_PADDING)))
        end)
        it("public DER export produces non-empty data", function()
            local key = assert(nc.generate_rsa_key(1025, 65537))
            assert.is_true(#assert(key:tostring("public", "DER")) > 0)
        end)
        it("PKCS8 export + reimport round-trip", function()
            local key = assert(nc.generate_rsa_key(1025, 65537))
            local pkcs8 = assert(key:to_pkcs8_der())
            local reimported = assert(nc.key_from_private_der(pkcs8))
            local enc = assert(key:encrypt("test", nc.RSA_PKCS1_PADDING))
            assert.are.equal("test", assert(reimported:decrypt(enc, nc.RSA_PKCS1_PADDING)))
        end)
        it("decrypt with wrong key fails", function()
            local k1 = assert(nc.generate_rsa_key(1025, 65537))
            local k2 = assert(nc.generate_rsa_key(1025, 65537))
            local enc = assert(k1:encrypt("s", nc.RSA_PKCS1_PADDING))
            local dec, err = k2:decrypt(enc, nc.RSA_PKCS1_PADDING)
            assert.is_nil(dec)
            assert.is.truthy(err)
        end)
    end)

    describe("key_from_private_der", function()
        it("returns error for invalid DER data", function()
            local key, err = nc.key_from_private_der("not-valid")
            assert.is_nil(key)
            assert.is.truthy(err)
        end)
    end)

    describe("AES-128-CBC edge cases", function()
        it("handles exactly one block with padding", function()
            local key, iv = string.rep("\x01", 16), string.rep("\x00", 16)
            local pt = "0123456789ABCDEF"
            assert.are.equal(pt, assert(nc.aes_cbc_decrypt(key, iv, assert(nc.aes_cbc_encrypt(key, iv, pt, false)), false)))
        end)
        it("different IVs produce different ciphertexts", function()
            local key = string.rep("\x03", 16)
            local pt = "same plaintext!!"
            local e1 = assert(nc.aes_cbc_encrypt(key, string.rep("\x00", 16), pt, true))
            local e2 = assert(nc.aes_cbc_encrypt(key, string.rep("\xFF", 16), pt, true))
            assert.are_not.equal(e1, e2)
        end)
        it("streaming decryptor handles multiple chunks", function()
            local ffi = require("ffi")
            local key, iv = string.rep("\x04", 16), string.rep("\x00", 16)
            local pt = string.rep("X", 256)
            local enc = assert(nc.aes_cbc_encrypt(key, iv, pt, true))
            local dec = assert(nc.aes_cbc_decryptor(key, iv, true))
            local parts = {}
            for i = 1, #enc, 48 do
                dec:update(enc:sub(i, math.min(i+47, #enc)), function(ptr, len)
                    parts[#parts+1] = ffi.string(ptr, len); return true
                end)
            end
            dec:finalize(function(ptr, len)
                if len > 0 then parts[#parts+1] = ffi.string(ptr, len) end; return true
            end)
            assert.are.equal(pt, table.concat(parts))
        end)
    end)
end)
