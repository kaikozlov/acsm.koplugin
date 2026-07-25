--- PDF per-object key derivation for ADEPT decryption.
-- Implements genkey_v2, genkey_v3, genkey_v4, genkey_v5
-- as used by Adobe ADEPT PDF encryption.
-- Reference: DeDRM_tools/ineptpdf.py

local ffi = require("ffi")
local sha2 = require("ffi/sha2")

local pdfcrypt = {}

--- MD5 hash, returns 16 RAW bytes (not hex string).
-- Note: sha2.md5() returns a HEX string, so we must convert to binary.
local function md5(data)
    return sha2.hex2bin(sha2.md5(data))
end

--- SHA-256 hash, returns 32 RAW bytes (not hex string).
local function sha256_bin(data)
    return sha2.hex2bin(sha2.sha256(data))
end

local function unpadPkcs7(data)
    local padLen = #data > 0 and data:byte(#data) or nil
    if not padLen or padLen < 1 or padLen > 16 or padLen > #data then
        return nil, "Invalid PKCS#7 padding"
    end
    for i = #data - padLen + 1, #data do
        if data:byte(i) ~= padLen then
            return nil, "Invalid PKCS#7 padding"
        end
    end
    return data:sub(1, #data - padLen)
end

--- Pack an integer as little-endian, returning only the first N bytes.
local function packLE(value, nbytes)
    local buf = ffi.new("uint8_t[4]")
    buf[0] = bit.band(value, 0xFF)
    buf[1] = bit.band(bit.rshift(value, 8), 0xFF)
    buf[2] = bit.band(bit.rshift(value, 16), 0xFF)
    buf[3] = bit.band(bit.rshift(value, 24), 0xFF)
    return ffi.string(buf, nbytes)
end

--- genkey_v2: Standard PDF key derivation (V=1, V=2)
-- key = MD5(bookkey + objid[0:3] + genno[0:2])[:min(len(bookkey)+5, 16)]
function pdfcrypt.genkey_v2(bookKey, objid, genno)
    local data = bookKey .. packLE(objid, 3) .. packLE(genno, 2)
    local hash = md5(data)
    local keyLen = math.min(#bookKey + 5, 16)
    return hash:sub(1, keyLen)
end

--- genkey_v3: Obfuscated key derivation (V=3)
-- XOR objid/genno with magic values, take 5 bytes + 'sAlT'
function pdfcrypt.genkey_v3(bookKey, objid, genno)
    local objidPacked = packLE(bit.bxor(objid, 0x3569ac), 4)
    local gennoPacked = packLE(bit.bxor(genno, 0xca96), 4)
    local data = bookKey
        .. string.char(objidPacked:byte(1), gennoPacked:byte(1), objidPacked:byte(2), gennoPacked:byte(2), objidPacked:byte(3))
        .. "sAlT"
    local hash = md5(data)
    local keyLen = math.min(#bookKey + 5, 16)
    return hash:sub(1, keyLen)
end

--- genkey_v4: AES key derivation (V=4)
-- key = MD5(bookkey + objid[0:3] + genno[0:2] + 'sAlT')[:min(len(bookkey)+5, 16)]
function pdfcrypt.genkey_v4(bookKey, objid, genno)
    local data = bookKey .. packLE(objid, 3) .. packLE(genno, 2) .. "sAlT"
    local hash = md5(data)
    local keyLen = math.min(#bookKey + 5, 16)
    return hash:sub(1, keyLen)
end

--- genkey_v5: Direct key (V=5, AES-256)
-- No per-object key derivation, just return the book key as-is.
function pdfcrypt.genkey_v5(bookKey, objid, genno)
    return bookKey
end

--- Determine encryption parameters from EBX_HANDLER dict values.
-- @param bookKey string raw book key (already RSA-decrypted, hardening removed)
-- @param ebx_V number V value from /Encrypt dict (default 4)
-- @param ebx_type number EBX_ENCRYPTIONTYPE (default 6)
-- @param length number Length value from /Encrypt dict in bytes (default 16)
-- @return table { genkey=fn, cipher="rc4"|"aes", key=bookKey }
function pdfcrypt.determineEncryption(bookKey, ebx_V, ebx_type, length)
    length = length or 16
    ebx_V = ebx_V or 4

    local V
    if length > 0 then
        if #bookKey == length then
            V = (ebx_V == 3) and 3 or 2
        elseif #bookKey == length + 1 then
            V = bookKey:byte(1)
            bookKey = bookKey:sub(2)
        else
            -- Mismatched length — try our best
            V = (ebx_V == 3) and 3 or 2
        end
    else
        V = (ebx_V == 3) and 3 or 2
    end

    -- EBX_HANDLER (ADEPT) always uses RC4 regardless of V.
    -- This matches ineptpdf.py initialize_ebx_inept lines 1757-1759:
    --   self.genkey = self.genkey_v3 if V == 3 else self.genkey_v2
    --   self.decipher = self.decrypt_rc4
    -- genkey_v4/genkey_v5 and AES are only used by Standard encryption,
    -- never by ADEPT.
    local genkey, cipher
    if V == 3 then
        genkey = pdfcrypt.genkey_v3
    else
        genkey = pdfcrypt.genkey_v2
    end
    cipher = "rc4"

    return {
        genkey = genkey,
        cipher = cipher,
        key = bookKey,
        V = V,
    }
end

--- Remove ADEPT hardening (RMSDK >= 10, keyType > 2).
-- @param bookKey string encrypted book key (base64-decoded, pre-RSA-decrypt)
-- @param keyType string keyType attribute value from encryptedKey element
-- @param resourceUUID string resource UUID
-- @param deviceUUID string device UUID
-- @param fulfillmentUUID string fulfillment UUID (first 36 chars)
-- @param aesDecrypt function(key, iv, data, no_padding) -> decrypted data
-- @return string unhardened book key (still RSA-encrypted), or nil
function pdfcrypt.removeHardening(bookKey, keyType, resourceUUID, deviceUUID, fulfillmentUUID, aesDecrypt)
    -- Parse a UUID hex string to 16 raw bytes.
    -- Matches Python's UUID.int → UUID.bytes (both big-endian for the IV).
    -- We do byte-level XOR instead of 64-bit integer XOR to avoid
    -- Lua double precision loss (53-bit mantissa < 64-bit UUID half).
    local function uuidToBytes(str)
        str = str:gsub("-", "")
        local bytes = {}
        for i = 1, 32, 2 do
            bytes[#bytes + 1] = string.char(tonumber(str:sub(i, i + 1), 16))
        end
        return table.concat(bytes)
    end

    -- XOR three UUIDs byte-by-byte to derive the IV.
    -- Equivalent to Python: UUID(int=resourceuuid.int ^ deviceuuid.int ^ fullfillmentuuid.int).bytes
    local rBytes = uuidToBytes(resourceUUID)
    local dBytes = uuidToBytes(deviceUUID)
    local fBytes = uuidToBytes(fulfillmentUUID)

    local ivParts = {}
    for i = 1, 16 do
        ivParts[i] = string.char(bit.bxor(rBytes:byte(i), bit.bxor(dBytes:byte(i), fBytes:byte(i))))
    end
    local iv = table.concat(ivParts)

    -- Derive KEK from keyType
    local rem = tonumber(keyType) % 16
    local Hbytes = sha256_bin(keyType)

    local kek = Hbytes:sub(2 * rem + 1, 16 + rem) .. Hbytes:sub(rem + 1, 2 * rem)

    -- AES-CBC decrypt (matches Python: AES.new(kek, AES.MODE_CBC, kekiv).decrypt(keydata))
    -- no_padding=true because we handle PKCS7 unpad ourselves (matching Python's unpad())
    local decrypted, decryptErr = aesDecrypt(kek, iv, bookKey, true)
    if not decrypted then
        return nil, decryptErr
    end
    return unpadPkcs7(decrypted)
end

return pdfcrypt
