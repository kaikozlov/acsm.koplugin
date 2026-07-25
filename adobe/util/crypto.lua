local crypto = {}

local util = require("adobe.util.util")
local asn1 = require("adobe.util.asn1")
local nativecrypto = require("adobe.util.nativecrypto")

crypto.deviceKey = {}

function crypto.deviceKey.new(existingKey)
    local keyBytes = existingKey
    if keyBytes == nil then
        local err
        keyBytes, err = nativecrypto.rand_bytes(16)
        if not keyBytes then
            return nil, err
        end
    elseif type(keyBytes) ~= "string" or #keyBytes ~= 16 then
        return nil, "Device key must be exactly 16 bytes"
    end

    return setmetatable({ key = keyBytes }, { __index = crypto.deviceKey })
end

function crypto.deviceKey:encrypt(data)
    local iv, ivErr = nativecrypto.rand_bytes(16)
    if not iv then
        return nil, ivErr
    end
    local encrypted, err = nativecrypto.aes_cbc_encrypt(self.key, iv, data, false)
    if not encrypted then
        return nil, err
    end
    return iv .. encrypted
end

function crypto.deviceKey:decrypt(data)
    if type(data) ~= "string" or #data < 32 or #data % 16 ~= 0 then
        return nil, "Invalid device-key ciphertext"
    end
    local iv = data:sub(1, 16)
    local encrypted = data:sub(17)
    return nativecrypto.aes_cbc_decrypt(self.key, iv, encrypted, false)
end

function crypto.encryptLogin(username, password, deviceKey, authCert)
    local buffer = deviceKey.key
    buffer = buffer .. string.char(username:len())
    buffer = buffer .. username
    buffer = buffer .. string.char(password:len())
    buffer = buffer .. password
    local certDer = util.base64.decode(authCert)
    if not certDer or certDer == "" then
        return nil, "Invalid authentication certificate"
    end
    local encrypted, err = nativecrypto.encrypt_with_cert(certDer, buffer)
    if not encrypted then
        return nil, err
    end
    return util.base64.encode(encrypted)
end

function crypto.serial()
    local rand, err = nativecrypto.rand_bytes(20)
    if not rand then
        return nil, err
    end
    local serial = ""
    for i = 1, 20 do
        serial = serial .. string.format("%02x", rand:byte(i))
    end
    return serial
end

function crypto.nonce()
    local bytes, err = nativecrypto.rand_bytes(12)
    if not bytes then
        return nil, err
    end
    return util.base64.encode(bytes)
end

function crypto.fingerprint(serial, deviceKey)
    local digest, err = nativecrypto.sha1(serial .. deviceKey.key)
    if not digest then
        return nil, err
    end
    return util.base64.encode(digest)
end

crypto.key = {}

function crypto.key.new(k)
    local key, err
    if k ~= nil then
        key, err = nativecrypto.key_from_private_der(k)
    else
        -- Adobe ADE and the reference implementation use 1024-bit auth/license keys.
        key, err = nativecrypto.generate_rsa_key(1024, 65537)
    end
    if not key then
        return nil, err
    end

    local wrapped = {
        pkey = key,
    }
    local meta = { __index = crypto.key }
    setmetatable(wrapped, meta)
    return wrapped
end

function crypto.key:topkcs8()
    return self.pkey:to_pkcs8_der()
end

function crypto.decodepkcs12(pk, deviceKey)
    local der = util.base64.decode(pk)
    if not der or der == "" then
        return nil, "Invalid PKCS12 data"
    end
    local pass = util.base64.encode(deviceKey.key)
    local decoded, err = nativecrypto.parse_pkcs12(der, pass)
    if not decoded then
        return nil, err
    end
    return decoded.key
end

local function sign(key, data)
    local sig, err = key:sign_raw(data, nativecrypto.RSA_PKCS1_PADDING)
    if not sig then
        return nil, err
    end
    return util.base64.encode(sig)
end

function crypto.signXML(name, key, tb)
    local encoded = asn1.element(name, tb)
    local digest, err = nativecrypto.sha1(encoded)
    if not digest then
        return nil, err
    end
    return sign(key, digest)
end

return crypto
