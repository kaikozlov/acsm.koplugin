local crypto = {}

local util = require("adobe.util.util")
local asn1 = require("adobe.util.asn1")
local nativecrypto = require("adobe.util.nativecrypto")

crypto.deviceKey = {}

function crypto.deviceKey.new(existingKey)
    local key = {}
    local meta = { __index = crypto.deviceKey }
    setmetatable(key, meta)
    key.key = existingKey or assert(nativecrypto.rand_bytes(16))
    return key
end

function crypto.deviceKey:encrypt(data)
    local iv = assert(nativecrypto.rand_bytes(16))
    local encrypted, err = nativecrypto.aes_cbc_encrypt(self.key, iv, data, false)
    if err ~= nil then error(err) end
    return iv .. encrypted
end

function crypto.deviceKey:decrypt(data)
    local iv = data:sub(1, 16)
    local encrypted = data:sub(17)
    local decrypted, err = nativecrypto.aes_cbc_decrypt(self.key, iv, encrypted, false)
    if err ~= nil then error(err) end
    return decrypted
end

function crypto.encryptLogin(username, password, deviceKey, authCert)
    local buffer = deviceKey.key
    buffer = buffer .. string.char(username:len())
    buffer = buffer .. username
    buffer = buffer .. string.char(password:len())
    buffer = buffer .. password
    local encrypted, err = nativecrypto.encrypt_with_cert(util.base64.decode(authCert), buffer)
    if err ~= nil then error(err) end
    return util.base64.encode(encrypted)
end

function crypto.serial()
    local rand = assert(nativecrypto.rand_bytes(20))
    local serial = ""
    for i = 1, 20 do
        serial = serial .. string.format("%02x", rand:byte(i))
    end
    return serial
end

function crypto.nonce()
    return util.base64.encode(assert(nativecrypto.rand_bytes(12)))
end

function crypto.fingerprint(serial, deviceKey)
    return util.base64.encode(assert(nativecrypto.sha1(serial .. deviceKey.key)))
end

crypto.key = {}

function crypto.key.new(k)
    local key, err
    if k ~= nil then
        key, err = nativecrypto.key_from_private_der(k)
    else
        key, err = nativecrypto.generate_rsa_key(1025, 65537)
    end
    if err ~= nil then error(err) end

    local wrapped = {
        pkey = key,
    }
    local meta = { __index = crypto.key }
    setmetatable(wrapped, meta)
    return wrapped
end

function crypto.key:topkcs8()
    local pkcs8, err = self.pkey:to_pkcs8_der()
    if err ~= nil then error(err) end
    return pkcs8
end

function crypto.decodepkcs12(pk, deviceKey)
    local pass = util.base64.encode(deviceKey.key)
    local decoded, err = nativecrypto.parse_pkcs12(util.base64.decode(pk), pass)
    if err ~= nil then error(err) end
    return decoded.key
end

local function sign(key, data)
    local sig, err = key:sign_raw(data, nativecrypto.RSA_PKCS1_PADDING)
    if err ~= nil then error(err) end
    return util.base64.encode(sig)
end

local function sha1(data)
    return assert(nativecrypto.sha1(data))
end

function crypto.signXML(name, key, tb)
    local encoded = asn1.element(name, tb)
    return sign(key, sha1(encoded))
end

return crypto
