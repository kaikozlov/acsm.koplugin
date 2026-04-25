local ffi = require("ffi")

local isAndroid = pcall(require, "android")

pcall(require, "ffi/loadlib")

local libcrypto
if isAndroid then
    -- On Android, KOReader's monolibtic only exports a tiny subset of crypto symbols.
    -- Use the system BoringSSL instead, which has everything we need.
    --
    -- The app's linker namespace blocks dlopen of /system/lib64/libcrypto.so directly,
    -- so we copy it to the app's data directory (which IS in the permitted namespace)
    -- and load from there.
    local android = require("android")
    local sys_crypto = "/system/lib64/libcrypto.so"
    local local_crypto = android.dir .. "/libcrypto.so"

    -- Check if we already have a copy
    local cached = io.open(local_crypto, "rb")
    if cached then
        cached:close()
    else
        -- Copy system BoringSSL to app data dir
        local src = io.open(sys_crypto, "rb")
        if src then
            local data = src:read("*a")
            src:close()
            local dst = io.open(local_crypto, "wb")
            if dst then
                dst:write(data)
                dst:close()
            end
        end
    end
    libcrypto = ffi.load(local_crypto)
elseif ffi.loadlib then
    -- On Kindle/etc, KOReader ships a standalone LibreSSL with full symbols.
    libcrypto = ffi.loadlib("crypto", "57", "crypto")
else
    libcrypto = ffi.load("crypto")
end

ffi.cdef [[
typedef struct evp_pkey_st EVP_PKEY;
typedef struct rsa_st RSA;
typedef struct x509_st X509;
typedef struct pkcs12_st PKCS12;
typedef struct bio_st BIO;
typedef struct bignum_st BIGNUM;
typedef struct evp_cipher_ctx_st EVP_CIPHER_CTX;
typedef struct evp_cipher_st EVP_CIPHER;
typedef struct pkcs8_priv_key_info_st PKCS8_PRIV_KEY_INFO;

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

void CRYPTO_free(void *ptr);
]]

local nativecrypto = {
    RSA_PKCS1_PADDING = 1,
}

local uchar_pp = ffi.typeof("unsigned char *[1]")
local const_uchar_pp = ffi.typeof("const unsigned char *[1]")

local function crypto_free(ptr)
    if ptr ~= nil then
        libcrypto.CRYPTO_free(ptr)
    end
end

local function i2d_to_string(fn, obj)
    local out = uchar_pp()
    local len = fn(obj, out)
    if len == nil or len <= 0 or out[0] == nil then
        return nil, "DER serialization failed"
    end
    local data = ffi.string(out[0], len)
    crypto_free(out[0])
    return data
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
        if rsa ~= nil then libcrypto.RSA_free(rsa) end
        if bn ~= nil then libcrypto.BN_free(bn) end
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
        if pkey ~= nil then libcrypto.EVP_PKEY_free(pkey) end
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
