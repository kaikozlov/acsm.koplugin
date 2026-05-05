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
local naming = require("adobe.util.naming")
local xml = require("adobe.util.xml")

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

--- Parse metadata from an ACSM file.
-- Extracts dc:title and resource UUID directly from the ACSM XML —
-- no need to download the EPUB first.
-- @string acsm_path path to the ACSM file
-- @treturn table{ title, resourceId, identifier } or nil on failure
function ACSM:parseAcsmMetadata(acsm_path)
    local content = io.open(acsm_path, "rb")
    if not content then return nil end
    local acsm_data = content:read("*a")
    content:close()

    local ok, parsed = pcall(xml.deserialize, acsm_data)
    if not ok or not parsed then return nil end

    local token = parsed.fulfillmentToken
    if not token then return nil end

    local rii = token.resourceItemInfo
    if not rii then return nil end

    local resource = rii.resource
    local meta = rii.metadata

    local title
    if meta then
        local raw = meta["dc:title"]
        if type(raw) == "table" then
            title = raw[1]
        elseif type(raw) == "string" then
            title = raw
        end
    end

    local identifier
    if meta then
        local raw = meta["dc:identifier"]
        if type(raw) == "table" then
            identifier = raw[1]
        elseif type(raw) == "string" then
            identifier = raw
        end
    end

    return {
        title = title,
        resourceId = resource, -- e.g. "urn:uuid:d976a1af-..."
        identifier = identifier, -- e.g. ISBN
    }
end

--- Build the output path for a fulfilled EPUB.
-- Extracts title from the ACSM metadata (no EPUB download needed).
-- Falls back to the ACSM filename with .epub extension.
function ACSM:deriveOutputPath(acsm_path, acsm_meta)
    local dir = util.splitFilePathName(acsm_path)
    if dir == "" then dir = "./" end

    -- Title from ACSM metadata (parsed before fulfillment)
    if acsm_meta and acsm_meta.title then
        local safe = naming.sanitizeTitle(acsm_meta.title)
        if safe then
            logger.info("[ACSM] deriveOutputPath: title=", acsm_meta.title)
            return dir .. safe .. ".epub"
        end
    end

    -- Fallback: swap .acsm -> .epub
    local output_path = acsm_path:gsub("%.[Aa][Cc][Ss][Mm]$", ".epub")
    if output_path == acsm_path then
        output_path = acsm_path .. ".epub"
    end
    return output_path
end

--- Find a unique output path, avoiding overwrites.
-- If the target path does not exist, returns it as-is.
-- Otherwise appends a counter: "Book (1).epub", "Book (2).epub", etc.
-- @string path desired output path
-- @treturn string unique path to use
function ACSM:findUniquePath(path)
    if not util.pathExists(path) then
        return path
    end

    local dir, filename = util.splitFilePathName(path)
    local name, ext = util.splitFileNameSuffix(filename)
    if ext ~= "" then ext = "." .. ext end

    for i = 1, 999 do
        local candidate = dir .. name .. " (" .. i .. ")" .. ext
        if not util.pathExists(candidate) then
            return candidate
        end
    end

    -- Extremely unlikely, but fall back to original path
    logger.warn("[ACSM] Could not find unique path after 999 attempts")
    return path
end

--- Get the path to the fulfillment mapping file.
-- Stores resource_id → output_path mappings for reuse detection.
function ACSM:getFulfillmentMapPath()
    local cache_dir = DataStorage:getDataDir() .. "/cache/acsm.koplugin"
    return cache_dir .. "/fulfillment_map.lua"
end

--- Look up a previously fulfilled EPUB by resource ID.
-- @string resource_id the ACSM resource UUID (e.g. "urn:uuid:...")
-- @treturn string output path, or nil
function ACSM:lookupFulfillmentMapping(resource_id)
    local map_path = self:getFulfillmentMapPath()
    local map = LuaSettings:open(map_path)
    return map:readSetting(resource_id)
end

--- Store a resource_id → output_path mapping after fulfillment.
-- @string resource_id the ACSM resource UUID
-- @string output_path where the EPUB was saved
function ACSM:saveFulfillmentMapping(resource_id, output_path)
    local map_path = self:getFulfillmentMapPath()
    local map = LuaSettings:open(map_path)
    map:saveSetting(resource_id, output_path)
    map:flush()
    logger.info("[ACSM] Saved fulfillment mapping:", resource_id, "→", output_path)
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

function ACSM:fulfillLoan(acsm_path, acsm_meta)
    logger.info("[ACSM] fulfillLoan: acsm_path=", acsm_path)
    local activation, reused = self:getActivation(false)

    -- Title-based output path derived from ACSM metadata (not EPUB)
    local desired_path = self:deriveOutputPath(acsm_path, acsm_meta)
    local output_path = self:findUniquePath(desired_path)
    logger.info("[ACSM] fulfillLoan: output_path=", output_path)

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

    -- Store resource → output mapping for reuse detection
    if acsm_meta and acsm_meta.resourceId then
        self:saveFulfillmentMapping(acsm_meta.resourceId, output_path)
    end

    return result
end

function ACSM:openFile(file)
    if not self:isFileTypeSupported(file) then
        return
    end

    self:loadSettings()

    -- Parse ACSM metadata for title and resource ID
    local acsm_meta = self:parseAcsmMetadata(file)

    -- For "reuse existing", look up the previous output path by resource ID
    if self.reuse_existing and acsm_meta and acsm_meta.resourceId then
        local existing_path = self:lookupFulfillmentMapping(acsm_meta.resourceId)
        if existing_path and util.pathExists(existing_path) then
            logger.info("[ACSM] Reusing existing EPUB:", existing_path)
            self:openGeneratedBook(existing_path)
            return
        end
    end

    if NetworkMgr:willRerunWhenOnline(function() self:openFile(file) end) then
        return
    end

    Trapper:wrap(function()
        Trapper:info(_("Preparing loan..."), false, true)
        local result, fulfill_err = self:fulfillLoan(file, acsm_meta)
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
