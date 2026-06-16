--- Integration tests: nativecrypto edge cases
-- Tests error handling, key serialization round-trips, and edge cases
-- for nativecrypto functions not covered by crypto_spec.lua.

describe("nativecrypto edge cases", function()
    local nc, ffi, libcrypto

    setup(function()
        nc = require("adobe.util.nativecrypto")
        ffi = require("ffi")

        -- Load libcrypto (same way nativecrypto does)
        if ffi.loadlib then
            libcrypto = ffi.loadlib("crypto", "57", "crypto")
        else
            libcrypto = ffi.load("crypto")
        end

        -- X509 creation helpers (for encrypt_with_cert tests)
        pcall(
            ffi.cdef,
            [[
            typedef struct X509_name_st X509_NAME;
            X509 *X509_new(void);
            int X509_set_version(void *x, long version);
            int ASN1_INTEGER_set(void *a, long v);
            void *X509_get0_serialNumber(void *x);
            int X509_set_pubkey(void *x, void *pkey);
            int X509_sign(void *x, void *pkey, const void *evp_md);
            void *X509_get0_notBefore(void *x);
            void *X509_get0_notAfter(void *x);
            void *X509_time_adj(void *s, long offset_day, long *offset_sec);
            const void *EVP_sha256(void);
            X509_NAME *X509_NAME_new(void);
            void X509_NAME_free(X509_NAME *a);
            int X509_NAME_add_entry_by_NID(X509_NAME *name, int nid, int type,
                const unsigned char *bytes, int len, int loc, int set);
            int X509_set_subject_name(void *x, X509_NAME *name);
            int X509_set_issuer_name(void *x, X509_NAME *name);
        ]]
        )
    end)

    --- Helper: create a minimal self-signed X509 cert and export as DER.
    -- Used to test encrypt_with_cert with real X509 certificates.
    local function makeSelfSignedCert(pkey)
        local cert = libcrypto.X509_new()
        assert(cert ~= nil, "X509_new failed")
        ffi.gc(cert, libcrypto.X509_free)

        assert(libcrypto.X509_set_version(cert, 2) == 1, "set_version failed")
        assert(libcrypto.ASN1_INTEGER_set(libcrypto.X509_get0_serialNumber(cert), 1) == 1, "set_serial failed")

        local name = libcrypto.X509_NAME_new()
        assert(name ~= nil, "X509_NAME_new failed")
        ffi.gc(name, libcrypto.X509_NAME_free)
        -- NID_commonName = 13, MBSTRING_ASC = 0x1001
        local cn = "test"
        assert(libcrypto.X509_NAME_add_entry_by_NID(name, 13, 0x1001, cn, #cn, -1, 0) == 1, "add_entry failed")
        assert(libcrypto.X509_set_subject_name(cert, name) == 1, "set_subject failed")
        assert(libcrypto.X509_set_issuer_name(cert, name) == 1, "set_issuer failed")

        assert(libcrypto.X509_set_pubkey(cert, pkey.ctx) == 1, "set_pubkey failed")

        libcrypto.X509_time_adj(libcrypto.X509_get0_notBefore(cert), 0, nil)
        libcrypto.X509_time_adj(libcrypto.X509_get0_notAfter(cert), 365, nil)

        local md = libcrypto.EVP_sha256()
        assert(md ~= nil, "EVP_sha256 failed")
        local sigLen = libcrypto.X509_sign(cert, pkey.ctx, md)
        assert(sigLen > 0, "X509_sign failed")

        -- Export DER via i2d_X509 (already declared in nativecrypto)
        local out = ffi.new("unsigned char *[1]")
        local len = libcrypto.i2d_X509(cert, out)
        assert(len > 0, "i2d_X509 failed")
        local der = ffi.string(out[0], len)
        libcrypto.CRYPTO_free(out[0])
        return der
    end

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
            for i = 1, #hash do
                hex = hex .. string.format("%02x", hash:byte(i))
            end
            assert.are.equal("a9993e364706816aba3e25717850c26c9cd0d89d", hex)
        end)
        it("produces correct hash for empty string", function()
            local hash = assert(nc.sha1(""))
            local hex = ""
            for i = 1, #hash do
                hex = hex .. string.format("%02x", hash:byte(i))
            end
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

    describe("encrypt_with_cert", function()
        it("round-trips: encrypt with X509 cert, decrypt with matching private key", function()
            local key = assert(nc.generate_rsa_key(1025, 65537))
            local certDer = makeSelfSignedCert(key)

            local plaintext = "Hello, certificate encryption!"
            local encrypted = assert(nc.encrypt_with_cert(certDer, plaintext))

            local decrypted = assert(key:decrypt(encrypted, nc.RSA_PKCS1_PADDING))
            assert.are.equal(plaintext, decrypted)
        end)

        it("produces different ciphertext for different certs", function()
            local k1 = assert(nc.generate_rsa_key(1025, 65537))
            local k2 = assert(nc.generate_rsa_key(1025, 65537))
            local cert1 = makeSelfSignedCert(k1)
            local cert2 = makeSelfSignedCert(k2)

            local plaintext = "same data, different certs"
            local enc1 = assert(nc.encrypt_with_cert(cert1, plaintext))
            local enc2 = assert(nc.encrypt_with_cert(cert2, plaintext))

            assert.are_not.equal(enc1, enc2)
        end)

        it("errors on invalid cert data", function()
            local ok, err = nc.encrypt_with_cert("not-a-valid-cert", "test")
            assert.is_nil(ok)
            assert.is.truthy(err)
        end)

        it("errors on empty cert data", function()
            local ok, err = nc.encrypt_with_cert("", "test")
            assert.is_nil(ok)
            assert.is.truthy(err)
        end)

        it("ciphertext size equals RSA key size", function()
            local key = assert(nc.generate_rsa_key(1025, 65537))
            local certDer = makeSelfSignedCert(key)

            local encrypted = assert(nc.encrypt_with_cert(certDer, "short"))
            -- RSA-1025 produces 129-byte ciphertext
            assert.are.equal(129, #encrypted)
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
            local key, iv = string.rep("\x04", 16), string.rep("\x00", 16)
            local pt = string.rep("X", 256)
            local enc = assert(nc.aes_cbc_encrypt(key, iv, pt, true))
            local dec = assert(nc.aes_cbc_decryptor(key, iv, true))
            local parts = {}
            for i = 1, #enc, 48 do
                dec:update(enc:sub(i, math.min(i + 47, #enc)), function(ptr, len)
                    parts[#parts + 1] = ffi.string(ptr, len)
                    return true
                end)
            end
            dec:finalize(function(ptr, len)
                if len > 0 then
                    parts[#parts + 1] = ffi.string(ptr, len)
                end
                return true
            end)
            assert.are.equal(pt, table.concat(parts))
        end)
    end)
end)
