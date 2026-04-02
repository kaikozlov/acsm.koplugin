local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")

local adobe = require("adobe.adobe")
local fulfillment = require("adobe.fulfillment")

local ACSMService = {}
ACSMService.__index = ACSMService

local function isActivationError(err)
    if type(err) ~= "string" then
        return false
    end
    return err:find("E_ADEPT_USER_AUTH", 1, true)
        or err:find("E_ADEPT_DISTRIBUTOR_AUTH", 1, true)
        or err:find("E_ADEPT", 1, true)
end

local function emitStatus(status_callback, text)
    if status_callback then
        status_callback(text)
    end
end

function ACSMService:new(opts)
    opts = opts or {}
    local instance = setmetatable({}, self)
    instance.settings_file = opts.settings_file or (DataStorage:getSettingsDir() .. "/acsm.lua")
    instance.settings = nil
    instance.activation_blob = nil
    instance.reuse_existing = true
    return instance
end

function ACSMService:loadSettings()
    if self.settings then
        return
    end
    self.settings = LuaSettings:open(self.settings_file)
    self.activation_blob = self.settings:readSetting("activation")
    self.reuse_existing = self.settings:nilOrTrue("reuse_existing")
end

function ACSMService:flushSettings()
    if not self.settings then
        return
    end
    self.settings:saveSetting("activation", self.activation_blob)
    self.settings:saveSetting("reuse_existing", self.reuse_existing)
    self.settings:flush()
end

function ACSMService:saveSettings()
    self:flushSettings()
end

function ACSMService:hasActivation()
    self:loadSettings()
    return self.activation_blob ~= nil
end

function ACSMService:getReuseExisting()
    self:loadSettings()
    return self.reuse_existing
end

function ACSMService:setReuseExisting(value)
    self:loadSettings()
    self.reuse_existing = not not value
    self:saveSettings()
end

function ACSMService:isFileTypeSupported(file)
    return util.getFileNameSuffix(file):lower() == "acsm"
end

function ACSMService:deriveOutputPath(acsm_path)
    local output_path = acsm_path:gsub("%.[Aa][Cc][Ss][Mm]$", ".epub")
    if output_path == acsm_path then
        output_path = acsm_path .. ".epub"
    end
    return output_path
end

function ACSMService:clearActivation()
    self:loadSettings()
    self.activation_blob = nil
    self:saveSettings()
end

function ACSMService:restoreActivation()
    self:loadSettings()
    if not self.activation_blob then
        return nil, "No saved activation"
    end
    local restored, err = adobe.restoreActivation(self.activation_blob)
    if not restored then
        logger.warn("[ACSM] Failed to restore activation:", err)
        self:clearActivation()
        return nil, err
    end
    return restored, nil
end

function ACSMService:createActivation(status_callback)
    emitStatus(status_callback, _("Creating Adobe activation..."))
    local auth_info = adobe.getAuthenticationServiceInfo()
    local creds = adobe.signIn("anonymous", "", "", auth_info.certificate)

    emitStatus(status_callback, _("Registering device..."))
    local device_uuid, fingerprint = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12)
    local activation = {
        creds = creds,
        deviceUUID = device_uuid,
        fingerprint = fingerprint,
        authCert = auth_info.certificate,
    }

    self.activation_blob = adobe.serializeActivation(
        creds,
        device_uuid,
        fingerprint,
        auth_info.certificate,
        creds.activationURL
    )
    self:saveSettings()

    return activation
end

function ACSMService:getActivation(force_new, status_callback)
    if not force_new then
        local restored = self:restoreActivation()
        if restored then
            return restored, true
        end
    end
    return self:createActivation(status_callback), false
end

function ACSMService:fulfillLoan(acsm_path, output_path, status_callback)
    local activation, reused = self:getActivation(false, status_callback)

    emitStatus(status_callback, _("Downloading book..."))
    local result, err = fulfillment.process(
        acsm_path,
        output_path,
        activation.creds,
        activation.deviceUUID,
        activation.fingerprint,
        activation.authCert
    )

    if not result and reused and isActivationError(err) then
        logger.warn("[ACSM] Saved activation failed, retrying with a new activation:", err)
        self:clearActivation()
        activation = self:createActivation(status_callback)
        emitStatus(status_callback, _("Retrying with new activation..."))
        result, err = fulfillment.process(
            acsm_path,
            output_path,
            activation.creds,
            activation.deviceUUID,
            activation.fingerprint,
            activation.authCert
        )
    end

    if not result then
        return nil, err
    end

    return result
end

function ACSMService:saveLoanFile(acsm_path, contents)
    local ok, err = util.writeToFile(contents, acsm_path)
    if not ok then
        return nil, err
    end
    return acsm_path
end

return ACSMService
