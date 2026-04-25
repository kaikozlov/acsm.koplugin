local source = debug.getinfo(1, "S").source
local plugin_root = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)/main%.lua$") or nil

-- xml2lua lives in a subdirectory not covered by pluginloader's plugin_root/?.lua
package.path = plugin_root .. "/dependencies/?.lua;" .. package.path

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
        self.settings:saveSetting("open_after_download", self.open_after_download)
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
    self.open_after_download = self.settings:nilOrTrue("open_after_download")
end

function ACSM:saveSettings()
    self:onFlushSettings()
end

function ACSM:addToMainMenu(menu_items)
    menu_items.acsm = {
        text = self.fullname,
        sorting_hint = "more_tools",
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
            text = _("Open book after download"),
            checked_func = function()
                return self.open_after_download
            end,
            callback = function()
                self.open_after_download = not self.open_after_download
                self:saveSettings()
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
    local provider = {
        provider_name = self.fullname,
        provider = self.name,
        order = 35,
        disable_file = true,
        disable_type = false,
    }
    -- Register as aux provider for the OpenWith dialog
    DocumentRegistry:addAuxProvider(provider)
    -- Also register the .acsm extension so files are visible without "show unsupported",
    -- and are automatically opened by our plugin without manual provider selection.
    DocumentRegistry:addProvider("acsm", "application/vnd.adobe.adept+xml", provider, 100)
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
        logger.info("[ACSM] restoreActivation: no saved activation blob")
        return nil, "No saved activation"
    end
    logger.info("[ACSM] restoreActivation: restoring from saved blob...")
    local restored, err = adobe.restoreActivation(self.activation_blob)
    if not restored then
        logger.warn("[ACSM] restoreActivation: failed:", err)
        self:clearActivation()
        return nil, err
    end
    logger.info("[ACSM] restoreActivation: success")
    return restored, nil
end

function ACSM:createActivation()
    Trapper:info(_("Creating Adobe activation..."), false, true)
    logger.info("[ACSM] createActivation: fetching authentication service info...")
    local auth_info = adobe.getAuthenticationServiceInfo()
    logger.info("[ACSM] createActivation: got auth service info, signing in anonymously...")
    local creds = adobe.signIn("anonymous", "", "", auth_info.certificate)
    logger.info("[ACSM] createActivation: sign-in successful, user=", creds.user)

    Trapper:info(_("Registering device..."), false, true)
    logger.info("[ACSM] createActivation: sending device activation request...")
    local device_uuid, fingerprint = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12)
    logger.info("[ACSM] createActivation: device activated, uuid=", device_uuid)
    local activation = {
        creds = creds,
        deviceUUID = device_uuid,
        fingerprint = fingerprint,
        authCert = auth_info.certificate,
    }

    logger.info("[ACSM] createActivation: serializing and saving activation...")
    self.activation_blob = adobe.serializeActivation(
        creds,
        device_uuid,
        fingerprint,
        auth_info.certificate,
        creds.activationURL
    )
    self:saveSettings()
    logger.info("[ACSM] createActivation: complete")

    return activation
end

function ACSM:getActivation(force_new)
    logger.info("[ACSM] getActivation: force_new=", force_new)
    if not force_new then
        local restored = self:restoreActivation()
        if restored then
            logger.info("[ACSM] getActivation: using restored activation")
            return restored, true
        end
    end
    logger.info("[ACSM] getActivation: creating new activation")
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
    logger.info("[ACSM] fulfillLoan: acsm_path=", acsm_path, "output_path=", output_path)
    local activation, reused = self:getActivation(false)

    Trapper:info(_("Downloading book..."), false, true)
    logger.info("[ACSM] fulfillLoan: starting fulfillment.process...")
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
        Trapper:info(_("Retrying with new activation..."), false, true)
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
        Trapper:info(_("Preparing loan..."), false, true)
        local result, fulfill_err = self:fulfillLoan(file, output_path)
        if not result then
            logger.warn("[ACSM] Processing failed:", fulfill_err)
            Trapper:reset()
            UIManager:show(InfoMessage:new{
                text = T(_("ACSM processing failed:\n%1"), trimError(fulfill_err)),
            })
            return
        end

        if self.ui.file_chooser then
            self.ui.file_chooser:refreshPath()
        end

        Trapper:clear()
        if self.open_after_download then
            UIManager:nextTick(function()
                self:openGeneratedBook(result.outputPath)
            end)
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Book downloaded:\n%1"), result.outputPath),
            })
        end
    end)
end

return ACSM
