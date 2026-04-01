local source = debug.getinfo(1, "S").source
local plugin_root = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)/main%.lua$") or nil
local app_root = plugin_root and plugin_root:match("^(.*)/plugins/[^/]+%.koplugin$")
if not app_root and plugin_root and plugin_root:match("^plugins/[^/]+%.koplugin$") then
    app_root = "."
end

local function prependPackagePath(path)
    if not package.path:find(path, 1, true) then
        package.path = path .. ";" .. package.path
    end
end

prependPackagePath(plugin_root .. "/?.lua")
prependPackagePath(plugin_root .. "/?/init.lua")
prependPackagePath(plugin_root .. "/dependencies/?.lua")
prependPackagePath(plugin_root .. "/dependencies/?/init.lua")

local function compactCandidates(list)
    local compacted = {}
    for _, candidate in ipairs(list) do
        if candidate and candidate.crypto and candidate.ssl then
            compacted[#compacted + 1] = candidate
        end
    end
    return compacted
end

_G.KO_ACSM_OPENSSL_CANDIDATES = compactCandidates({
    { crypto = "./libs/libcrypto.so.57", ssl = "./libs/libssl.so.60" },
    { crypto = "./libs/libcrypto.so.3", ssl = "./libs/libssl.so.3" },
    { crypto = "libs/libcrypto.so.57", ssl = "libs/libssl.so.60" },
    { crypto = "libs/libcrypto.so.3", ssl = "libs/libssl.so.3" },
    app_root and {
        crypto = app_root .. "/libs/libcrypto.so.57",
        ssl = app_root .. "/libs/libssl.so.60",
    } or nil,
    app_root and {
        crypto = app_root .. "/libs/libcrypto.so.3",
        ssl = app_root .. "/libs/libssl.so.3",
    } or nil,
    { crypto = "libcrypto.so.57", ssl = "libssl.so.60" },
    { crypto = "libcrypto.so.3", ssl = "libssl.so.3" },
    { crypto = "libcrypto.so.1.1", ssl = "libssl.so.1.1" },
    { crypto = "libcrypto.so", ssl = "libssl.so" },
    { crypto = "crypto", ssl = "ssl" },
})

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local Notification = require("ui/widget/notification")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ffiUtil = require("ffi/util")
local logger = require("logger")
local util = require("util")
local _ = require("gettext")
local T = ffiUtil.template

local adobe = require("adobe.adobe")
local fulfillment = require("adobe.fulfillment")

local ACSM = WidgetContainer:extend{
    name = "acsm",
    fullname = _("ACSM"),
    is_doc_only = false,
    settings_file = DataStorage:getSettingsDir() .. "/acsm.lua",
    settings = nil,
    reuse_existing = true,
}

local function trimError(err)
    if type(err) ~= "string" then
        return tostring(err)
    end
    return err:gsub("^.-: ", "")
end

local function isActivationError(err)
    if type(err) ~= "string" then
        return false
    end
    return err:find("E_ADEPT_USER_AUTH", 1, true)
        or err:find("E_ADEPT_DISTRIBUTOR_AUTH", 1, true)
        or err:find("E_ADEPT", 1, true)
end

function ACSM:init()
    self.ui.menu:registerToMainMenu(self)
    self:registerDocumentRegistryAuxProvider()
end

function ACSM:onFlushSettings()
    if self.settings then
        self.settings:saveSetting("activation", self.activation_blob)
        self.settings:saveSetting("reuse_existing", self.reuse_existing)
        self.settings:flush()
    end
end

function ACSM:loadSettings()
    if self.settings then
        return
    end
    self.settings = LuaSettings:open(self.settings_file)
    self.activation_blob = self.settings:readSetting("activation")
    self.reuse_existing = self.settings:nilOrTrue("reuse_existing")
end

function ACSM:saveSettings()
    self:onFlushSettings()
end

function ACSM:addToMainMenu(menu_items)
    menu_items.acsm = {
        text = self.fullname,
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
    }
end

function ACSM:getSubMenuItems()
    self:loadSettings()
    return {
        {
            text_func = function()
                if self.activation_blob then
                    return _("Adobe activation: ready")
                end
                return _("Adobe activation: not set")
            end,
            enabled_func = function()
                return false
            end,
        },
        {
            text = _("Reuse existing EPUB"),
            checked_func = function()
                return self.reuse_existing
            end,
            callback = function()
                self.reuse_existing = not self.reuse_existing
                self:saveSettings()
            end,
        },
        {
            text = _("Forget Adobe activation"),
            enabled_func = function()
                return self.activation_blob ~= nil
            end,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Forget the saved Adobe activation?"),
                    ok_text = _("Forget"),
                    ok_callback = function()
                        self:clearActivation()
                        UIManager:show(Notification:new{
                            text = _("Saved Adobe activation cleared."),
                        })
                    end,
                })
            end,
        },
    }
end

function ACSM:registerDocumentRegistryAuxProvider()
    DocumentRegistry:addAuxProvider({
        provider_name = self.fullname,
        provider = self.name,
        order = 35,
        disable_file = true,
        disable_type = false,
    })
end

function ACSM:isFileTypeSupported(file)
    return util.getFileNameSuffix(file):lower() == "acsm"
end

function ACSM:deriveOutputPath(acsm_path)
    local output_path = acsm_path:gsub("%.[Aa][Cc][Ss][Mm]$", ".epub")
    if output_path == acsm_path then
        output_path = acsm_path .. ".epub"
    end
    return output_path
end

function ACSM:clearActivation()
    self:loadSettings()
    self.activation_blob = nil
    self:saveSettings()
end

function ACSM:restoreActivation()
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

function ACSM:createActivation()
    Trapper:info(_("Authorizing anonymous Adobe account..."), false, true)
    local auth_info = adobe.getAuthenticationServiceInfo()
    local creds = adobe.signIn("anonymous", "", "", auth_info.certificate)

    Trapper:info(_("Activating device with Adobe..."), false, true)
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

function ACSM:getActivation(force_new)
    if not force_new then
        local restored = self:restoreActivation()
        if restored then
            return restored, true
        end
    end
    return self:createActivation(), false
end

function ACSM:openGeneratedBook(path)
    if self.ui.file_chooser then
        local dir = util.splitFilePathName(path)
        self.ui.file_chooser:changeToPath(dir, path)
    end
    if self.ui.document then
        self.ui:switchDocument(path)
    else
        self.ui:openFile(path)
    end
end

function ACSM:fulfillLoan(acsm_path, output_path)
    local activation, reused = self:getActivation(false)

    Trapper:info(_("Fulfilling ACSM and decrypting EPUB..."), false, true)
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
        activation = self:createActivation()
        Trapper:info(_("Retrying fulfillment with a fresh activation..."), false, true)
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

function ACSM:openFile(file)
    if not self:isFileTypeSupported(file) then
        return
    end

    self:loadSettings()
    local output_path = self:deriveOutputPath(file)

    if self.reuse_existing and util.pathExists(output_path) then
        self:openGeneratedBook(output_path)
        return
    end

    if NetworkMgr:willRerunWhenOnline(function() self:openFile(file) end) then
        return
    end

    Trapper:wrap(function()
        local ok, err = xpcall(function()
            Trapper:info(T(_("Preparing %1"), file), false, true)
            local result, fulfill_err = self:fulfillLoan(file, output_path)
            if not result then
                error(fulfill_err)
            end

            if self.ui.file_chooser then
                self.ui.file_chooser:refreshPath()
            end

            Trapper:clear()
            UIManager:nextTick(function()
                self:openGeneratedBook(result.outputPath)
            end)
        end, debug.traceback)

        if not ok then
            logger.warn("[ACSM] Processing failed:", err)
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("ACSM processing failed:\n%1"), trimError(err)),
            })
        end
    end)
end

return ACSM
