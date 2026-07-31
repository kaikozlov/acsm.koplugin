local ffi = require("ffi")

--- Resolve the system library directory for a given architecture.
-- KOReader ships separate APKs for 32-bit (arm) and 64-bit (arm64). On a 64-bit
-- device running the 32-bit APK, the process is 32-bit and /system/lib64/ contains
-- the wrong architecture. Detect via jit.arch which system lib path to use.
-- @param arch string jit.arch value (e.g. "arm64", "arm", "x64", "x86")
-- @return string "/system/lib64" or "/system/lib"
local function systemLibDir(arch)
    if arch == "arm64" or arch == "x64" then
        return "/system/lib64"
    else
        return "/system/lib"
    end
end

--- Copy a system .so to the app's data dir and load it via FFI.
-- Uses an arch-tagged cache filename (e.g. libcrypto.arm64.so) to prevent stale
-- wrong-arch caches after switching between 32-bit and 64-bit APKs.
-- Cleans up any legacy untagged cache (libcrypto.so) on sight.
local function androidCopyLoad(lib_name, arch, data_dir)
    local sys_dir = systemLibDir(arch)
    local sys_path = sys_dir .. "/lib" .. lib_name .. ".so"
    local tagged_name = "lib" .. lib_name .. "." .. arch .. ".so"
    local local_path = data_dir .. "/" .. tagged_name

    -- Clean up legacy untagged cache (libcrypto.so)
    local legacy = data_dir .. "/lib" .. lib_name .. ".so"
    local f = io.open(legacy, "rb")
    if f then
        f:close()
        os.remove(legacy)
    end

    -- Check if we already have a cached copy for this arch
    local cached = io.open(local_path, "rb")
    if cached then
        cached:close()
    else
        -- Copy system library to app data dir
        local src = io.open(sys_path, "rb")
        if src then
            local data = src:read("*a")
            src:close()
            local dst = io.open(local_path, "wb")
            if dst then
                dst:write(data)
                dst:close()
            end
        end
    end

    return ffi.load(local_path)
end

-- Exposed for testing: arch-aware system lib directory resolver and copy-and-load.
-- Must be global so they're accessible before the local nativecrypto table is created
-- and so zlib.lua's test can reference them without cross-module require on Android.
_nativecrypto_systemLibDir = systemLibDir
_nativecrypto_androidCopyLoad = androidCopyLoad

local isAndroid = pcall(require, "android")

pcall(require, "ffi/loadlib")

local libcrypto
if isAndroid then
    -- On Android, KOReader's monolbtic only exports a tiny subset of crypto symbols.
    -- Use the system BoringSSL instead, which has everything we need.
    -- androidCopyLoad handles arch detection, arch-tagged caching, and legacy cleanup.
    local android = require("android")
    libcrypto = androidCopyLoad("crypto", jit.arch, android.dir)
elseif ffi.loadlib then
    -- On Kindle/etc, KOReader ships a standalone LibreSSL with full symbols.
    libcrypto = ffi.loadlib("crypto", "57", "crypto")
else
    libcrypto = ffi.load("crypto")
end

ffi.cdef([[
typedef struct evp_pkey_st EVP_PKEY;
typedef struct rsa_st RSA;
typedef struct x509_st X509;
typedef struct pkcs12_st PKCS12;
typedef struct bio_st BIO;
typedef struct bignum_st BIGNUM;
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
typedef struct evp_cipher_st EVP_CIPHER;
typedef struct pkcs8_priv_key_info_st PKCS8_PRIV_KEY_INFO;

void OPENSSL_add_all_algorithms_noconf(void);
void OpenSSL_add_all_ciphers(void);
void OpenSSL_add_all_digests(void);

int RAND_bytes(unsigned char *buf, int num);
unsigned char *SHA1(const unsigned char *d, size_t n, unsigned char *md);

EVP_CIPHER_CTX *EVP_CIPHER_CTX_new(void);
void EVP_CIPHER_CTX_free(EVP_CIPHER_CTX *c);
const EVP_CIPHER *EVP_aes_128_cbc(void);
int EVP_EncryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *type, void *impl, const unsigned char *key, const unsigned char *iv);
int EVP_EncryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl, const unsigned char *in, int inl);
int EVP_EncryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *outm, int *outl);
int EVP_DecryptInit_ex(EVP_CIPHER_CTX *ctx, const EVP_CIPHER *type, void *impl, const unsigned char *key, const unsigned char *iv);
int EVP_DecryptUpdate(EVP_CIPHER_CTX *ctx, unsigned char *out, int *outl, const unsigned char *in, int inl);
int EVP_DecryptFinal_ex(EVP_CIPHER_CTX *ctx, unsigned char *outm, int *outl);
int EVP_CIPHER_CTX_set_padding(EVP_CIPHER_CTX *c, int pad);

BIO *BIO_new_mem_buf(const void *buf, int len);
void BIO_free(BIO *a);

X509 *d2i_X509(X509 **a, const unsigned char **in, long len);
void X509_free(X509 *a);
EVP_PKEY *X509_get_pubkey(X509 *x);

EVP_PKEY *d2i_AutoPrivateKey(EVP_PKEY **a, const unsigned char **pp, long length);
void EVP_PKEY_free(EVP_PKEY *pkey);
RSA *EVP_PKEY_get1_RSA(EVP_PKEY *pkey);
int i2d_PUBKEY(EVP_PKEY *a, unsigned char **pp);
PKCS8_PRIV_KEY_INFO *EVP_PKEY2PKCS8(EVP_PKEY *pkey);
int i2d_PKCS8_PRIV_KEY_INFO(PKCS8_PRIV_KEY_INFO *a, unsigned char **pp);
void PKCS8_PRIV_KEY_INFO_free(PKCS8_PRIV_KEY_INFO *a);

RSA *RSA_new(void);
void RSA_free(RSA *r);
int RSA_generate_key_ex(RSA *rsa, int bits, BIGNUM *e, void *cb);
int RSA_public_encrypt(int flen, const unsigned char *from, unsigned char *to, RSA *rsa, int padding);
int RSA_private_decrypt(int flen, const unsigned char *from, unsigned char *to, RSA *rsa, int padding);
int RSA_private_encrypt(int flen, const unsigned char *from, unsigned char *to, RSA *rsa, int padding);
int RSA_size(const RSA *rsa);

BIGNUM *BN_new(void);
void BN_free(BIGNUM *a);
int BN_set_word(BIGNUM *a, unsigned long w);

EVP_PKEY *EVP_PKEY_new(void);
int EVP_PKEY_set1_RSA(EVP_PKEY *pkey, RSA *key);

int i2d_X509(X509 *a, unsigned char **pp);
PKCS12 *d2i_PKCS12_bio(BIO *bp, PKCS12 **p12);
int PKCS12_parse(PKCS12 *p12, const char *pass, EVP_PKEY **pkey, X509 **cert, void *ca);
void PKCS12_free(PKCS12 *a);

]])

-- Old Android OpenSSL 1.0.x builds need their global cipher/digest lookup
-- tables populated before APIs like PKCS12_parse can resolve PBES2 algorithms
-- by OID. Newer Android crypto stacks may not expose these symbols, so this is
-- intentionally best-effort.
if isAndroid then
    local ok = pcall(function()
        libcrypto.OPENSSL_add_all_algorithms_noconf()
    end)
    if not ok then
        pcall(function()
            libcrypto.OpenSSL_add_all_ciphers()
        end)
        pcall(function()
            libcrypto.OpenSSL_add_all_digests()
        end)
    end
end

local nativecrypto = {
    RSA_PKCS1_PADDING = 1,
}

local uchar_pp = ffi.typeof("unsigned char *[1]")
local const_uchar_pp = ffi.typeof("const unsigned char *[1]")

--- Serialize an object to a DER string via a two-pass i2d_* call.
-- First pass: call with NULL output pointer to get the required length.
-- Second pass: provide our own GC-managed buffer to receive the output.
-- This avoids relying on the library's allocator (CRYPTO_free/OPENSSL_free),
-- whose exported symbol and ABI vary across BoringSSL/LibreSSL/OpenSSL builds.
local function i2d_to_string(fn, obj)
    local len = fn(obj, nil)
    if len == nil or len <= 0 then
        return nil, "DER serialization failed"
    end

    local buf = ffi.new("unsigned char[?]", len)
    local out = uchar_pp()
    out[0] = buf

    local written = fn(obj, out)
    if written == nil or written ~= len then
        return nil, string.format("DER serialization failed: expected %d bytes, wrote %s", len, tostring(written))
    end

    return ffi.string(buf, written)
end

local function der_pointer(data)
    return const_uchar_pp(ffi.cast("const unsigned char *", data))
end

local PKey = {}
PKey.__index = PKey

function PKey:tostring(which, format)
    if which == "public" and format == "DER" then
        return i2d_to_string(libcrypto.i2d_PUBKEY, self.ctx)
    end
    return nil, "Unsupported key export"
end

function PKey:to_pkcs8_der()
    local info = libcrypto.EVP_PKEY2PKCS8(self.ctx)
    if info == nil then
        return nil, "EVP_PKEY2PKCS8 failed"
    end
    local data, err = i2d_to_string(libcrypto.i2d_PKCS8_PRIV_KEY_INFO, info)
    libcrypto.PKCS8_PRIV_KEY_INFO_free(info)
    return data, err
end

function PKey:with_rsa(fn)
    local rsa = libcrypto.EVP_PKEY_get1_RSA(self.ctx)
    if rsa == nil then
        return nil, "EVP_PKEY_get1_RSA failed"
    end
    ffi.gc(rsa, libcrypto.RSA_free)
    return fn(rsa)
end

function PKey:encrypt(data, padding)
    return self:with_rsa(function(rsa)
        local out = ffi.new("unsigned char[?]", libcrypto.RSA_size(rsa))
        local len = libcrypto.RSA_public_encrypt(#data, data, out, rsa, padding or nativecrypto.RSA_PKCS1_PADDING)
        if len <= 0 then
            return nil, "RSA_public_encrypt failed"
        end
        return ffi.string(out, len)
    end)
end

function PKey:decrypt(data, padding)
    return self:with_rsa(function(rsa)
        local out = ffi.new("unsigned char[?]", libcrypto.RSA_size(rsa))
        local len = libcrypto.RSA_private_decrypt(#data, data, out, rsa, padding or nativecrypto.RSA_PKCS1_PADDING)
        if len <= 0 then
            return nil, "RSA_private_decrypt failed"
        end
        return ffi.string(out, len)
    end)
end

function PKey:sign_raw(data, padding)
    return self:with_rsa(function(rsa)
        local out = ffi.new("unsigned char[?]", libcrypto.RSA_size(rsa))
        local len = libcrypto.RSA_private_encrypt(#data, data, out, rsa, padding or nativecrypto.RSA_PKCS1_PADDING)
        if len <= 0 then
            return nil, "RSA_private_encrypt failed"
        end
        return ffi.string(out, len)
    end)
end

local function wrap_pkey(ctx)
    if ctx == nil then
        return nil, "EVP_PKEY is nil"
    end
    ffi.gc(ctx, libcrypto.EVP_PKEY_free)
    return setmetatable({ ctx = ctx }, PKey)
end

function nativecrypto.rand_bytes(n)
    local buf = ffi.new("unsigned char[?]", n)
    if libcrypto.RAND_bytes(buf, n) ~= 1 then
        return nil, "RAND_bytes failed"
    end
    return ffi.string(buf, n)
end

function nativecrypto.sha1(data)
    local buf = ffi.new("unsigned char[20]")
    if libcrypto.SHA1(ffi.cast("const unsigned char *", data), #data, buf) == nil then
        return nil, "SHA1 failed"
    end
    return ffi.string(buf, 20)
end

local function evp_cipher(do_encrypt, key, iv, input, no_padding)
    local ctx = libcrypto.EVP_CIPHER_CTX_new()
    if ctx == nil then
        return nil, "EVP_CIPHER_CTX_new failed"
    end
    ffi.gc(ctx, libcrypto.EVP_CIPHER_CTX_free)

    local ok
    if do_encrypt then
        ok = libcrypto.EVP_EncryptInit_ex(ctx, libcrypto.EVP_aes_128_cbc(), nil, key, iv)
    else
        ok = libcrypto.EVP_DecryptInit_ex(ctx, libcrypto.EVP_aes_128_cbc(), nil, key, iv)
    end
    if ok ~= 1 then
        return nil, "EVP_*Init_ex failed"
    end
    if no_padding then
        libcrypto.EVP_CIPHER_CTX_set_padding(ctx, 0)
    end

    local out = ffi.new("unsigned char[?]", #input + 32)
    local outl = ffi.new("int[1]")
    local finall = ffi.new("int[1]")
    if do_encrypt then
        ok = libcrypto.EVP_EncryptUpdate(ctx, out, outl, input, #input)
        if ok ~= 1 then
            return nil, "EVP_EncryptUpdate failed"
        end
        ok = libcrypto.EVP_EncryptFinal_ex(ctx, out + outl[0], finall)
        if ok ~= 1 then
            return nil, "EVP_EncryptFinal_ex failed"
        end
    else
        ok = libcrypto.EVP_DecryptUpdate(ctx, out, outl, input, #input)
        if ok ~= 1 then
            return nil, "EVP_DecryptUpdate failed"
        end
        ok = libcrypto.EVP_DecryptFinal_ex(ctx, out + outl[0], finall)
        if ok ~= 1 then
            return nil, "EVP_DecryptFinal_ex failed"
        end
    end

    return ffi.string(out, outl[0] + finall[0])
end

function nativecrypto.aes_cbc_encrypt(key, iv, data, no_padding)
    return evp_cipher(true, key, iv, data, no_padding)
end

function nativecrypto.aes_cbc_decrypt(key, iv, data, no_padding)
    return evp_cipher(false, key, iv, data, no_padding)
end

--- Create a streaming AES-128-CBC decryptor.
-- Returns an object with :update(chunk) and :finalize() methods.
-- Each :update() returns the decrypted output for that chunk.
-- :finalize() returns any remaining bytes and frees the context.
-- The output buffer is allocated once and reused across update() calls.
function nativecrypto.aes_cbc_decryptor(key, iv, no_padding)
    local ctx = libcrypto.EVP_CIPHER_CTX_new()
    if ctx == nil then
        return nil, "EVP_CIPHER_CTX_new failed"
    end
    ffi.gc(ctx, libcrypto.EVP_CIPHER_CTX_free)

    local ok = libcrypto.EVP_DecryptInit_ex(ctx, libcrypto.EVP_aes_128_cbc(), nil, key, iv)
    if ok ~= 1 then
        return nil, "EVP_DecryptInit_ex failed"
    end
    if no_padding then
        libcrypto.EVP_CIPHER_CTX_set_padding(ctx, 0)
    end

    local outl = ffi.new("int[1]")
    local out = nil -- lazily allocated, reused across update() calls
    local out_cap = 0 -- capacity of the current buffer
    local finalized = false

    local decryptor = {}

    --- Decrypt a chunk of data.
    -- If sink is provided, calls sink(ptr, len) with the output buffer.
    -- If no sink, returns (ptr, len) directly.
    function decryptor:update(chunk, sink)
        if finalized then
            return nil, "decryptor already finalized"
        end
        local needed = #chunk + 32
        if needed > out_cap then
            out = ffi.new("unsigned char[?]", needed)
            out_cap = needed
        end
        if libcrypto.EVP_DecryptUpdate(ctx, out, outl, chunk, #chunk) ~= 1 then
            return nil, "EVP_DecryptUpdate failed"
        end
        if sink and outl[0] > 0 then
            return sink(out, outl[0])
        end
        return out, outl[0]
    end

    --- Finalize decryption and return remaining bytes.
    -- If sink is provided, calls sink(ptr, len) with any final output.
    -- If no sink, returns (ptr, len) directly.
    function decryptor:finalize(sink)
        if finalized then
            return nil, "decryptor already finalized"
        end
        finalized = true
        if out_cap < 32 then
            out = ffi.new("unsigned char[32]")
            out_cap = 32
        end
        if libcrypto.EVP_DecryptFinal_ex(ctx, out, outl) ~= 1 then
            return nil, "EVP_DecryptFinal_ex failed"
        end
        if sink and outl[0] > 0 then
            return sink(out, outl[0])
        end
        return out, outl[0]
    end

    return decryptor
end

function nativecrypto.key_from_private_der(der)
    local p = der_pointer(der)
    local ctx = libcrypto.d2i_AutoPrivateKey(nil, p, #der)
    if ctx == nil then
        return nil, "d2i_AutoPrivateKey failed"
    end
    return wrap_pkey(ctx)
end

function nativecrypto.generate_rsa_key(bits, exp)
    local rsa = libcrypto.RSA_new()
    local bn = libcrypto.BN_new()
    if rsa == nil or bn == nil then
        if rsa ~= nil then
            libcrypto.RSA_free(rsa)
        end
        if bn ~= nil then
            libcrypto.BN_free(bn)
        end
        return nil, "RSA_new/BN_new failed"
    end

    local ok = libcrypto.BN_set_word(bn, exp)
    if ok ~= 1 or libcrypto.RSA_generate_key_ex(rsa, bits, bn, nil) ~= 1 then
        libcrypto.BN_free(bn)
        libcrypto.RSA_free(rsa)
        return nil, "RSA_generate_key_ex failed"
    end
    libcrypto.BN_free(bn)

    local pkey = libcrypto.EVP_PKEY_new()
    if pkey == nil or libcrypto.EVP_PKEY_set1_RSA(pkey, rsa) ~= 1 then
        if pkey ~= nil then
            libcrypto.EVP_PKEY_free(pkey)
        end
        libcrypto.RSA_free(rsa)
        return nil, "EVP_PKEY_set1_RSA failed"
    end
    libcrypto.RSA_free(rsa)

    return wrap_pkey(pkey)
end

function nativecrypto.encrypt_with_cert(cert_der, data)
    local p = der_pointer(cert_der)
    local cert = libcrypto.d2i_X509(nil, p, #cert_der)
    if cert == nil then
        return nil, "d2i_X509 failed"
    end
    ffi.gc(cert, libcrypto.X509_free)

    local pkey = libcrypto.X509_get_pubkey(cert)
    if pkey == nil then
        return nil, "X509_get_pubkey failed"
    end
    local wrapped = wrap_pkey(pkey)
    return wrapped:encrypt(data)
end

function nativecrypto.parse_pkcs12(der, password)
    local bio = libcrypto.BIO_new_mem_buf(der, #der)
    if bio == nil then
        return nil, "BIO_new_mem_buf failed"
    end
    ffi.gc(bio, libcrypto.BIO_free)

    local p12 = libcrypto.d2i_PKCS12_bio(bio, nil)
    if p12 == nil then
        return nil, "d2i_PKCS12_bio failed"
    end
    ffi.gc(p12, libcrypto.PKCS12_free)

    local pkey_pp = ffi.new("EVP_PKEY*[1]")
    local cert_pp = ffi.new("X509*[1]")
    if libcrypto.PKCS12_parse(p12, password, pkey_pp, cert_pp, nil) ~= 1 then
        return nil, "PKCS12_parse failed"
    end
    local key = wrap_pkey(pkey_pp[0])

    local cert_der, cert_err = i2d_to_string(libcrypto.i2d_X509, cert_pp[0])
    libcrypto.X509_free(cert_pp[0])
    if not cert_der then
        return nil, cert_err
    end

    return {
        key = key,
        cert_der = cert_der,
    }
end

return nativecrypto
