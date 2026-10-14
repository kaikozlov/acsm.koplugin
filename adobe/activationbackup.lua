-- Portable, data-only activation backups. Never evaluate an imported settings file.
local adobe = require("adobe.adobe")
local crypto = require("adobe.util.crypto")
local ffi = require("ffi")
local ffiUtil = require("ffi/util")
local json = require("json")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local _ = require("gettext")
local T = ffiUtil.template

require("ffi/posix_h")

local backup = { MAX_SIZE = 1024 * 1024 }
local required = { "deviceKey", "privateLicenseKey", "user", "pkcs12", "deviceUUID", "fingerprint" }
local optional = { "username", "licenseCert", "authCert", "activationURL" }

local function validate(blob)
    if type(blob) ~= "table" then
        return nil, _("Missing activation data")
    end
    local clean = {}
    for __, key in ipairs(required) do
        if type(blob[key]) ~= "string" or blob[key] == "" then
            return nil, T(_("Missing or invalid activation field: %1"), key)
        end
        clean[key] = blob[key]
    end
    for __, key in ipairs(optional) do
        if blob[key] ~= nil and type(blob[key]) ~= "string" then
            return nil, T(_("Invalid activation field: %1"), key)
        end
        clean[key] = blob[key]
    end
    -- Restore directly: the plugin's restoreActivation discards invalid saved state.
    local ok, restored = pcall(adobe.restoreActivation, clean)
    if not ok or not restored then
        return nil, _("Activation keys could not be restored")
    end
    local decoded, key = pcall(crypto.decodepkcs12, clean.pkcs12, restored.creds.deviceKey)
    if not decoded or not key then
        return nil, _("Activation authentication key could not be restored")
    end
    return clean
end

function backup.encode(blob)
    local clean, err = validate(blob)
    if not clean then
        return nil, err
    end
    local ok, encoded = pcall(json.encode, { format = "acsm-activation", version = 1, activation = clean })
    if not ok or #encoded + 1 > backup.MAX_SIZE then
        return nil, _("Could not encode activation backup")
    end
    return encoded .. "\n"
end

function backup.decode(text)
    if type(text) ~= "string" or #text > backup.MAX_SIZE then
        return nil, _("Activation backup is too large")
    end
    local ok, envelope = pcall(json.decode, text)
    if not ok or type(envelope) ~= "table" then
        return nil, _("Not a JSON activation backup")
    end
    if envelope.format ~= "acsm-activation" or envelope.version ~= 1 then
        return nil, _("Unsupported activation backup format or version")
    end
    return validate(envelope.activation)
end

function backup.read(path)
    local attr = lfs.attributes(path)
    if not attr or attr.mode ~= "file" or attr.size > backup.MAX_SIZE then
        return nil, _("Choose a regular activation backup file no larger than 1 MiB")
    end
    local file = io.open(path, "rb")
    if not file then
        return nil, _("Could not open activation backup")
    end
    local text = file:read(backup.MAX_SIZE + 1)
    file:close()
    if not text then
        return nil, _("Could not read activation backup")
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
function backup.writeFile(path, text)
    local attr = lfs.symlinkattributes(path)
    if attr and attr.mode ~= "file" then
        return nil, _("Destination is not a regular file")
    end
    -- Same-directory temp file: exclusively created with 0600 permissions and
    -- renamed over the destination only after write, fsync and close all succeed.
    local template = path .. ".tmp.XXXXXX"
    local buf = ffi.new("char[?]", #template + 1, template)
    local fd = ffi.C.mkstemps(buf, 0)
    if fd < 0 then
        return nil, _("Could not create temporary file")
    end
    local temp = ffi.string(buf)
    local ok = ffiUtil.writeToFD(fd, text) and ffiUtil.fsyncOpenedFile(fd, true)
    local closed = ffi.C.close(fd) == 0
    if not ok or not closed or not os.rename(temp, path) then
        os.remove(temp)
        return nil, _("Could not write file")
    end
    -- Committed: the destination is already replaced, so only warn if the
    -- directory entry cannot be synced.
    local synced, err = ffiUtil.fsyncDirectory(path)
    if not synced then
        logger.warn("[activationbackup] directory sync failed after write:", path, err)
    end
    return true
end

return backup
