--- Integration tests: crypto round-trips with real OpenSSL
-- Verifies AES, SHA-1, RSA, and device key operations using
-- KOReader's bundled native crypto libraries.

describe("Crypto round-trips (real OpenSSL)", function()
    it("AES-128-CBC encrypt/decrypt round-trip", function()
        local nc = require("adobe.util.nativecrypto")
        local key = string.rep("\1", 16)
        local iv = string.rep("\0", 16)
        local plaintext = "Hello KOReader!"

        local encrypted = assert(nc.aes_cbc_encrypt(key, iv, plaintext, false))
        local decrypted = assert(nc.aes_cbc_decrypt(key, iv, encrypted, false))
        assert.are.equal(plaintext, decrypted)
    end)

    it("AES streaming decrypt matches one-shot", function()
        local ffi = require("ffi")
        local nc = require("adobe.util.nativecrypto")
        local data = string.rep("Streaming test data. ", 100)
        local key = string.rep("\2", 16)
        local iv = string.rep("\0", 16)

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

describe("crypto.serial()", function()
    it("returns a 40-character lowercase hex string", function()
        local crypto = require("adobe.util.crypto")
        local s = crypto.serial()
        assert.is_truthy(#s > 0)
        assert.are.equal(40, #s)
        assert.is_truthy(s:match("^[0-9a-f]+$"))
    end)

    it("returns different values on successive calls", function()
        local crypto = require("adobe.util.crypto")
        local s1 = crypto.serial()
        local s2 = crypto.serial()
        assert.are_not.equal(s1, s2)
    end)
end)

describe("crypto.nonce()", function()
    it("returns a non-empty base64 string", function()
        local crypto = require("adobe.util.crypto")
        local n = crypto.nonce()
        assert.is_truthy(#n > 0)
        assert.is_truthy(n:match("^[A-Za-z0-9+/]+=*$"))
    end)

    it("returns different values on successive calls", function()
        local crypto = require("adobe.util.crypto")
        local n1 = crypto.nonce()
        local n2 = crypto.nonce()
        assert.are_not.equal(n1, n2)
    end)

    it("decodes to exactly 12 bytes", function()
        local crypto = require("adobe.util.crypto")
        local util = require("adobe.util.util")
        local n = crypto.nonce()
        local decoded = util.base64.decode(n)
        assert.are.equal(12, #decoded)
    end)
end)

describe("crypto.fingerprint(serial, deviceKey)", function()
    it("returns deterministic hash for known inputs", function()
        local crypto = require("adobe.util.crypto")
        local devKey = crypto.deviceKey.new(string.rep("\0", 16))
        local fp = crypto.fingerprint("test-serial", devKey)
        assert.are.equal("6n05KpnBFobTR+NMDEs7OEVBzyg=", fp)
    end)

    it("decoded result is 20 bytes (SHA-1 output length)", function()
        local crypto = require("adobe.util.crypto")
        local util = require("adobe.util.util")
        local devKey = crypto.deviceKey.new()
        local fp = crypto.fingerprint(crypto.serial(), devKey)
        local raw = util.base64.decode(fp)
        assert.are.equal(20, #raw)
    end)

    it("different serials produce different fingerprints", function()
        local crypto = require("adobe.util.crypto")
        local devKey = crypto.deviceKey.new(string.rep("\0", 16))
        local fp1 = crypto.fingerprint("serial-A", devKey)
        local fp2 = crypto.fingerprint("serial-B", devKey)
        assert.are_not.equal(fp1, fp2)
    end)

    it("different device keys produce different fingerprints", function()
        local crypto = require("adobe.util.crypto")
        local devKey1 = crypto.deviceKey.new(string.rep("\x01", 16))
        local devKey2 = crypto.deviceKey.new(string.rep("\x02", 16))
        local fp1 = crypto.fingerprint("same-serial", devKey1)
        local fp2 = crypto.fingerprint("same-serial", devKey2)
        assert.are_not.equal(fp1, fp2)
    end)
end)

describe("crypto.key:topkcs8()", function()
    it("exports non-empty binary DER data", function()
        local crypto = require("adobe.util.crypto")
        local key = crypto.key.new()
        local pkcs8 = key:topkcs8()
        assert.is_truthy(#pkcs8 > 0)
    end)

    it("round-trips: topkcs8 → reimport → encrypt/decrypt", function()
        local crypto = require("adobe.util.crypto")
        local nc = require("adobe.util.nativecrypto")
        local key = crypto.key.new()
        local pkcs8 = key:topkcs8()
        local reimported = assert(nc.key_from_private_der(pkcs8))
        local plaintext = "topkcs8 round-trip test"
        local encrypted = assert(key.pkey:encrypt(plaintext, nc.RSA_PKCS1_PADDING))
        local decrypted = assert(reimported:decrypt(encrypted, nc.RSA_PKCS1_PADDING))
        assert.are.equal(plaintext, decrypted)
    end)

    it("reimported key can sign and verify", function()
        local crypto = require("adobe.util.crypto")
        local nc = require("adobe.util.nativecrypto")
        local key = crypto.key.new()
        local pkcs8 = key:topkcs8()
        local reimported = assert(nc.key_from_private_der(pkcs8))
        local data = "sign with reimported key"
        local hash = assert(nc.sha1(data))
        local sig = assert(reimported:sign_raw(hash, nc.RSA_PKCS1_PADDING))
        assert.is_truthy(#sig > 0)
    end)
end)

describe("crypto.encryptLogin(username, password, deviceKey, authCert)", function()
    -- Self-signed X.509 cert (1024-bit RSA) for testing RSA encryption
    local testCert = "MIIB+jCCAWOgAwIBAgIUJRe4soWVrZWEbjEhDD7+2XPx0QgwDQYJKoZIhvcNAQEL"
        .. "BQAwDzENMAsGA1UEAwwEdGVzdDAeFw0yNjA1MDcwMDEyMDZaFw0yNzA1MDcwMDEy"
        .. "MDZaMA8xDTALBgNVBAMMBHRlc3QwgZ8wDQYJKoZIhvcNAQEBBQADgY0AMIGJAoGB"
        .. "AONF2jZjHnDTFSTYbEkuUvIFfKeGjHEV5GcE3ys67nid26Hm1JkF3tbaNtFgrimq"
        .. "0bZZXSZKrrSdx3VpYn8RrWyTBUF2skMoV2joKSrdtOyXHS5qf8O1QVprVrZi7xQq"
        .. "5AVOP2xhhFx9coEHjB3F93Sib49vC6yA/BusNOdjjpupAgMBAAGjUzBRMB0GA1Ud"
        .. "DgQWBBQP2NlxUi7yRawggfFiuu4mVwiR2zAfBgNVHSMEGDAWgBQP2NlxUi7yRawg"
        .. "gfFiuu4mVwiR2zAPBgNVHRMBAf8EBTADAQH/MA0GCSqGSIb3DQEBCwUAA4GBAG5K"
        .. "tOrCMej6+Aap6j9cxSitwPJa8ci7MCPba49w9iNHz63a3kDYGxz3hmcsV3KxofW4"
        .. "WCVF2wHA+W+IRfixc8gQKAJhs4BgivPRmfOjfcA7MuDiqD2/I0bP2eLANPdgG5RI"
        .. "FtST+uxgHQIXVqddx0oZMFJIBVBFbBQUYsyh8LWs"

    it("returns non-nil base64 result with valid inputs", function()
        local crypto = require("adobe.util.crypto")
        local devKey = crypto.deviceKey.new()
        local result = crypto.encryptLogin("user", "pass", devKey, testCert)
        assert.is_truthy(result)
        assert.is_truthy(#result > 0)
        assert.is_truthy(result:match("^[A-Za-z0-9+/]+=*$"))
    end)

    it("works with empty username", function()
        local crypto = require("adobe.util.crypto")
        local devKey = crypto.deviceKey.new()
        local result = crypto.encryptLogin("", "pass", devKey, testCert)
        assert.is_truthy(result)
        assert.is_truthy(#result > 0)
    end)

    it("works with empty password", function()
        local crypto = require("adobe.util.crypto")
        local devKey = crypto.deviceKey.new()
        local result = crypto.encryptLogin("user", "", devKey, testCert)
        assert.is_truthy(result)
        assert.is_truthy(#result > 0)
    end)

    it("handles special characters in credentials", function()
        local crypto = require("adobe.util.crypto")
        local devKey = crypto.deviceKey.new()
        local result = crypto.encryptLogin("user@t\195\169st.jp", "p@$$w\195\182rd!", devKey, testCert)
        assert.is_truthy(result)
        assert.is_truthy(#result > 0)
    end)

    it("different device keys produce different ciphertexts", function()
        local crypto = require("adobe.util.crypto")
        local devKey1 = crypto.deviceKey.new()
        local devKey2 = crypto.deviceKey.new()
        local r1 = crypto.encryptLogin("user", "pass", devKey1, testCert)
        local r2 = crypto.encryptLogin("user", "pass", devKey2, testCert)
        assert.are_not.equal(r1, r2)
    end)
end)

describe("crypto.decodepkcs12(pk, deviceKey)", function()
    -- PKCS#12 blob created with password = base64(16 zero bytes) = "AAAAAAAAAAAAAAAAAAAAAA=="
    -- Contains a 1024-bit RSA key + self-signed cert
    local pkcs12_b64 = "MIIGpwIBAzCCBlUGCSqGSIb3DQEHAaCCBkYEggZCMIIGPjCCAvoGCSqGSIb3DQEH"
        .. "BqCCAuswggLnAgEAMIIC4AYJKoZIhvcNAQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqG"
        .. "SIb3DQEFDDAkBBD2QrcpnDLGado6wxRZTRBJAgIIADAMBggqhkiG9w0CCQUAMB0G"
        .. "CWCGSAFlAwQBKgQQpQP0/25IWnXTMUTPVR4HPICCAnAhkiorBZui0UHnb1NWTnJ0"
        .. "wWQPnYUgqbrDLdhcnUxM8q8gqML8dxN8afAjK5lVbY1KB/rygP7rZFaZwNPkQXTK"
        .. "I9QUfwbKMBmYYZFZKB7QNncQBR+AiG7Bn/stLN1EU7ECs/iQY8JDXtw+bpuWIDfH"
        .. "7+Zco1cUKUfJi8cdYZMqwlKOmCfhbDndcPeuwDD9wlJrMer9vO3aYrodqzakThq+"
        .. "ziSjoCzokiJR/Md0DTDvosHEQhQMUOrhzCQCnH4fK5L8nD977T4HlNySlzVAV9TbF"
        .. "bkbet93hutKxVh8KoPMUKc3/wHUYV5MkL/ZGIm51lkkPGAX4ZwbugKsuKflUw5j8"
        .. "M2ZA+SI1z6DUHRBzQruj9MnW8I7iM+yPMYypAXEHKIB4YEzv3D8K7l6Abz1UOrPM"
        .. "aP94622ZG1rCelh/nqBY9Tqea0DQ0yaXLOiFELf5JY8w1ogwOxOO+DNqUxFt1ePT"
        .. "Ktn9HF4R+Eix8tRVLWQJncxLUNuPKe9ML7zX/ftgT7Zq6UUPCnyndk+98uRx0CJ5"
        .. "tDPZ9VQwotwLC+/JIGPXqHVQIsIeMfauP/0rSEZzL1wGi07VnkrxFeWSlQ8/nigG"
        .. "poWkosPc+9RtxYdE2jQXnGo2tAEl5WaC9ihhzBai7PzWuNp86eGNHYDPJjtbhwaG"
        .. "EIsHqgwCT4WviKFxwmgEK0R34Krh63Zl1JTc1EFO/o1NZWM5t1xfte8GgIuvHYfC"
        .. "CjYD+LcMjqDxh5GgwyW/UTC2RLkL2SxvZjjgvU6awl68LzhECYICQOeJBtnaa39o"
        .. "Nl+yg23DB4IBeP4ASS93gQwzt6PDcd9H3ei3AWqOSQwggM8BgkqhkiG9w0BBwGg"
        .. "ggMtBIIDKTCCAyUwggMhBgsqhkiG9w0BDAoBAqCCAukwggLlMF8GCSqGSIb3DQEF"
        .. "DTBSMDEGCSqGSIb3DQEFDDAkBBDuCqIC2HTvFp+zyXe8dbY3AgIIADAMBggqhkiG"
        .. "9w0CCQUAMB0GCWCGSAFlAwQBKgQQX6h5wh+U+Maa4s/cGhAMVQSCAoDUTGlvCccl"
        .. "vxh6Iei2v1bNV+lm0r2wYIoZPusVYy5XVp7dxycoLA7+grBEAY1UEsyNum8H8rPb"
        .. "iEUd8BH1ubpWf7H0mdGRsSMkafX0++qGuAn3iFX7KkrYJfgiP3ss7pl7S2BkPq8Z"
        .. "TzI7KUXLYNoA7flcAphRmTi7g3GZjk+JzjFjKwpSDOdvwtdTVQAWDmxyBZR5X6GX"
        .. "i9UGnI1gVEfOueXHa4+ufNd8XtZk/vYOQBP/WBPLZiBGlOD+ypUuTmZA30w8SkMM"
        .. "7OIjWttvXJ/5QmXsC2IZ471H7hIGunDuWHXKpLrRpJfOuX+NG3IJx9nW2sClIv8e"
        .. "2/8/nRhD9LFxtWERGoHcoSz9yZE7I+ndTG5t6TONUHj95lZb6F31BELh+bSWXUT9"
        .. "kRinbRTZQBaw852DQCFtNPrdCD8XxXj47AVjbnP+PMsxqH+ZSosH/DGdhjutKeos"
        .. "MsCgc0Dk3+4K8yFuggAhJzkDaqNLP5DNNwKICALg1/MdVrlwKv/odTqhLXWBTMaK"
        .. "wFGibNYz12afdUagbnRW2PgnZZ2ZEHigzO99+vRIcjqR6XzAd96JGpvHZgxh0YU6"
        .. "DuDmgqvFEybgN8k32iNfnCn4Mkd9GONW5Luxu/3qylZQr+ZZpwO10WaOG+pkXTpm"
        .. "tBzosqdQbqnD6znf+2/d6gPnkB0cqsCiWl3Xfy2aFwReS4xByCOsJQrK5XJgwf4Z"
        .. "PyOr7WJ9nuLpGCFUuL/7mj7W2yUEJb4cyJgh6F8RmH8ytpxU6hmIKU3X84DN8kW4"
        .. "uOhMaM84BJPZGW7xoQUHBgE8hNZixk9nmN/YJHAqN0RVCj4LMeuk2Ec6RXNn1WYp"
        .. "enuu0+FGs86QMSUwIwYJKoZIhvcNAQkVMRYEFF7UYerEclzDSGxj0WWwoG8mT3cM"
        .. "MEkwMTANBglghkgBZQMEAgEFAAQgeSNZrkg0rbit2CT4fvAlDB0he4YMydFcwUeD"
        .. "qz41/n4EELq0JR3dx5ouZgZMH2gVMdQCAggA"

    it("extracts a usable private key from PKCS#12", function()
        local crypto = require("adobe.util.crypto")
        local nc = require("adobe.util.nativecrypto")

        -- deviceKey with 16 zero bytes → password "AAAAAAAAAAAAAAAAAAAAAA=="
        local devKey = crypto.deviceKey.new(string.rep("\0", 16))
        local key = crypto.decodepkcs12(pkcs12_b64, devKey)

        assert.is_truthy(key)
        -- Verify it's a usable PKey by signing
        local hash = assert(nc.sha1("decodepkcs12 test"))
        local sig = assert(key:sign_raw(hash, nc.RSA_PKCS1_PADDING))
        assert.is_truthy(#sig > 0)
    end)

    it("errors on wrong deviceKey (wrong password)", function()
        local crypto = require("adobe.util.crypto")

        local wrongKey = crypto.deviceKey.new(string.rep("\xFF", 16))
        assert.has_error(function()
            crypto.decodepkcs12(pkcs12_b64, wrongKey)
        end)
    end)
end)
