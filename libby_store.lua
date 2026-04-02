local DataStorage = require("datastorage")
local LuaSettings = require("luasettings")
local util = require("util")

local LibbyStore = {}
LibbyStore.__index = LibbyStore

function LibbyStore:new(opts)
    opts = opts or {}
    local instance = setmetatable({}, self)
    instance.settings_file = opts.settings_file or (DataStorage:getSettingsDir() .. "/acsm_libby.lua")
    instance.settings = nil
    return instance
end

function LibbyStore:load()
    if self.settings then
        return
    end
    self.settings = LuaSettings:open(self.settings_file)
end

function LibbyStore:flush()
    if self.settings then
        self.settings:flush()
    end
end

function LibbyStore:read(key, default)
    self:load()
    local value = self.settings:readSetting(key)
    if value == nil then
        return default
    end
    return value
end

function LibbyStore:write(key, value)
    self:load()
    if value == nil then
        self.settings:delSetting(key)
    else
        self.settings:saveSetting(key, value)
    end
end

function LibbyStore:getIdentityToken()
    return self:read("identity_token")
end

function LibbyStore:setIdentityToken(token)
    self:write("identity_token", token)
end

function LibbyStore:getSetupCode()
    return self:read("setup_code")
end

function LibbyStore:setSetupCode(code)
    self:write("setup_code", code)
end

function LibbyStore:getLastSyncTime()
    return self:read("last_sync_time")
end

function LibbyStore:setLastSyncTime(timestamp)
    self:write("last_sync_time", timestamp)
end

function LibbyStore:getSyncState()
    return self:read("sync_state", {})
end

function LibbyStore:setSyncState(sync_state)
    self:write("sync_state", util.tableDeepCopy(sync_state or {}))
end

function LibbyStore:getSelectedSearchLibraries()
    return self:read("selected_search_libraries", {})
end

function LibbyStore:setSelectedSearchLibraries(library_keys)
    self:write("selected_search_libraries", util.tableDeepCopy(library_keys or {}))
end

function LibbyStore:clearAccount()
    self:load()
    self.settings:delSetting("identity_token")
    self.settings:delSetting("setup_code")
    self.settings:delSetting("last_sync_time")
    self.settings:delSetting("sync_state")
    self.settings:delSetting("selected_search_libraries")
end

function LibbyStore:isConfigured()
    local token = self:getIdentityToken()
    return type(token) == "string" and token ~= ""
end

return LibbyStore
