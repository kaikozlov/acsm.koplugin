local source = debug.getinfo(1, "S").source
local plugin_root = source:sub(1, 1) == "@" and source:sub(2):match("^(.*)/main%.lua$") or nil

-- xml2lua lives in a subdirectory not covered by pluginloader's plugin_root/?.lua
package.path = plugin_root .. "/dependencies/?.lua;" .. package.path

local ConfirmBox = require("ui/widget/confirmbox")
local DocumentRegistry = require("document/documentregistry")
local InfoMessage = require("ui/widget/infomessage")
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

local ACSMService = require("acsm_service")
local libby_state = require("libby_state")
local LibbyStore = require("libby_store")
local LibbyUI = require("libby_ui")

local ACSM = WidgetContainer:extend{
    name = "acsm",
    fullname = _("ACSM"),
    is_doc_only = false,
}

local function trimError(err)
    if type(err) ~= "string" then
        return tostring(err)
    end
    return err:gsub("^.-: ", "")
end

function ACSM:init()
    self.acsm_service = ACSMService:new()
    self.libby_store = LibbyStore:new()
    self.libby_ui = LibbyUI:new{
        plugin = self,
        store = self.libby_store,
        state = libby_state,
        acsm_service = self.acsm_service,
    }
    self.ui.menu:registerToMainMenu(self)
    self:registerDocumentRegistryAuxProvider()
end

function ACSM:onFlushSettings()
    if self.acsm_service then
        self.acsm_service:flushSettings()
    end
    if self.libby_store then
        self.libby_store:flush()
    end
end

function ACSM:saveSettings()
    self:onFlushSettings()
end

function ACSM:addToMainMenu(menu_items)
    menu_items.acsm = {
        text = self.fullname,
        sorting_hint = "tools",
        sub_item_table_func = function()
            return self:getSubMenuItems()
        end,
    }
end

function ACSM:getSubMenuItems()
    local items = {
        {
            text_func = function()
                if self.acsm_service:hasActivation() then
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
                return self.acsm_service:getReuseExisting()
            end,
            callback = function()
                self.acsm_service:setReuseExisting(not self.acsm_service:getReuseExisting())
            end,
        },
        {
            text = _("Forget Adobe activation"),
            enabled_func = function()
                return self.acsm_service:hasActivation()
            end,
            callback = function()
                UIManager:show(ConfirmBox:new{
                    text = _("Forget the saved Adobe activation?"),
                    ok_text = _("Forget"),
                    ok_callback = function()
                        self.acsm_service:clearActivation()
                        UIManager:show(Notification:new{
                            text = _("Saved Adobe activation cleared."),
                        })
                    end,
                })
            end,
        },
        {
            text = _("Libby"),
            sub_item_table_func = function()
                return self.libby_ui:getSubMenuItems()
            end,
        },
    }
    return items
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
    return self.acsm_service:isFileTypeSupported(file)
end

function ACSM:deriveOutputPath(acsm_path)
    return self.acsm_service:deriveOutputPath(acsm_path)
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
    return self.acsm_service:fulfillLoan(acsm_path, output_path, function(text)
        Trapper:info(text, false, true)
    end)
end

function ACSM:openFile(file)
    if not self:isFileTypeSupported(file) then
        return
    end

    local output_path = self:deriveOutputPath(file)

    if self.acsm_service:getReuseExisting() and util.pathExists(output_path) then
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
        UIManager:nextTick(function()
            self:openGeneratedBook(result.outputPath)
        end)
    end)
end

return ACSM
