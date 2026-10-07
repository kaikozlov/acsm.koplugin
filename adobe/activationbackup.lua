-- Portable, data-only activation backups. Never evaluate an imported settings file.
local adobe = require("adobe.adobe")
local crypto = require("adobe.util.crypto")
local ffi = require("ffi")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")

require("ffi/posix_h")
ffi.cdef("int mkstemp(char *template);")

local backup = { MAX_SIZE = 1024 * 1024 }
local required = { "deviceKey", "privateLicenseKey", "user", "pkcs12", "deviceUUID", "fingerprint" }
local optional = { "username", "licenseCert", "authCert", "activationURL" }

local function validate(blob)
    if type(blob) ~= "table" then
        return nil, "Missing activation data"
    end
    local clean = {}
    for _, key in ipairs(required) do
        if type(blob[key]) ~= "string" or blob[key] == "" then
            return nil, "Missing or invalid activation field: " .. key
        end
        clean[key] = blob[key]
    end
    for _, key in ipairs(optional) do
        if blob[key] ~= nil then
            if type(blob[key]) ~= "string" then
                return nil, "Invalid activation field: " .. key
            end
            clean[key] = blob[key]
        end
    end
    -- Validate the candidate in isolation. ACSM:restoreActivation() would clear
    -- the CURRENT activation on failure, so it must not be used for importing.
    local ok, restored = pcall(adobe.restoreActivation, clean)
    if not ok or not restored then
        return nil, "Activation keys could not be restored"
    end
    local decoded, key = pcall(crypto.decodepkcs12, clean.pkcs12, restored.creds.deviceKey)
    if not decoded or not key then
        return nil, "Activation authentication key could not be restored"
    end
    return clean
end

function backup.encode(blob)
    local clean, err = validate(blob)
    if not clean then
        return nil, err
    end
    local ok, encoded = pcall(json.encode, { format = "acsm-activation", version = 1, activation = clean })
    if not ok or type(encoded) ~= "string" or #encoded + 1 > backup.MAX_SIZE then
        return nil, "Could not encode activation backup"
    end
    return encoded .. "\n"
end

function backup.decode(text)
    if type(text) ~= "string" or #text > backup.MAX_SIZE then
        return nil, "Activation backup is too large"
    end
    local ok, envelope = pcall(json.decode, text)
    if not ok or type(envelope) ~= "table" then
        return nil, "Not a JSON activation backup"
    end
    if envelope.format ~= "acsm-activation" or envelope.version ~= 1 then
        return nil, "Unsupported activation backup format or version"
    end
    return validate(envelope.activation)
end

function backup.read(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or attr.size > backup.MAX_SIZE then
        return nil, "Choose a regular activation backup file smaller than 1 MiB"
    end
    local file = io.open(path, "rb")
    if not file then
        return nil, "Could not open activation backup"
    end
    local text = file:read(backup.MAX_SIZE + 1)
    local closed = file:close()
    if not text or not closed then
        return nil, "Could not read activation backup"
    end
    return backup.decode(text)
end

function backup.write(path, blob)
    local encoded, err = backup.encode(blob)
    if not encoded then
        return nil, err
    end
    return backup.writeFile(path, encoded)
end

-- Shared checked writer for an exported backup or a candidate settings file.
function backup.writeFile(path, encoded)
    local attr = lfs.symlinkattributes(path)
    if attr and attr.mode ~= "file" then
        return nil, "Destination is not a regular file"
    end
    -- Same-directory temporary file: exclusive creation, mode 0600 where the
    -- filesystem supports permissions, then atomic replacement after checks.
    local template = path .. ".tmp.XXXXXX"
    local name = ffi.new("char[?]", #template + 1, template)
    local fd = ffi.C.mkstemp(name)
    if fd < 0 then
        return nil, "Could not create activation backup"
    end
    local temp = ffi.string(name)
    local offset = 0
    local bytes = ffi.cast("const char *", encoded)
    while offset < #encoded do
        local written = tonumber(ffi.C.write(fd, bytes + offset, #encoded - offset))
        if written <= 0 then
            ffi.C.close(fd)
            os.remove(temp)
            return nil, "Could not write activation backup"
        end
        offset = offset + written
    end
    local synced = ffi.C.fsync(fd) == 0
    local closed = ffi.C.close(fd) == 0
    if not synced or not closed then
        os.remove(temp)
        return nil, "Could not finish writing activation backup"
    end
    local renamed = os.rename(temp, path)
    if not renamed then
        os.remove(temp)
        return nil, "Could not replace activation backup"
    end
    return true
end

return backup
