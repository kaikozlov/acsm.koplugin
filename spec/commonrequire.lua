--- commonrequire.lua
-- Bootstrap for running busted tests inside a real KOReader environment.
--
-- Ported from KOReader's spec/unit/commonrequire.lua. This file is loaded
-- by busted via `--helper` and sets up the headless KOReader environment:
--   - Real KOReader modules (no mocks)
--   - einkfb.dummy = true → framebuffer skips SDL window
--   - Input.dummy = true → no input device polling
--   - Isolated G_reader_settings and G_defaults in temp files
--
-- This runs INSIDE KOReader's bundled LuaJIT, so all native FFI libs
-- (OpenSSL, zstd, sqlite, etc.) are available for real.

-- Set up package paths so `require()` finds KOReader modules
package.path =
    "common/?.lua;frontend/?.lua;" ..
    package.path
package.cpath =
    "common/?.so;common/?.dll;/usr/lib/lua/?.so;" ..
    package.cpath

-- Set up ffi.load override for native library discovery
require("ffi/loadlib")

-- Turn off debug tracing and quiet the logs
require("dbg"):turnOff()
local logger = require("logger")
logger:setLevel(logger.levels.warn)

-- KOReader's datastorage will pick up KO_MULTIUSER from the env,
-- but we want isolated test data, so set KO_HOME explicitly
local DataStorage = require("datastorage")

-- Use a temp directory for test settings (isolated from any real data)
local test_data_dir = os.getenv("TEST_DATA_DIR") or "/tmp/koreader-test-data"
os.execute("mkdir -p " .. test_data_dir)
os.getenv = (function()
    local orig = os.getenv
    local overrides = {
        KO_HOME = test_data_dir,
    }
    return function(key)
        if overrides[key] ~= nil then
            return overrides[key]
        end
        return orig(key)
    end
end)()

-- Re-init datastorage after setting KO_HOME
package.loaded["datastorage"] = nil
DataStorage = require("datastorage")

-- Create isolated test settings files
local data_dir = DataStorage:getDataDir()

-- Global defaults (isolated)
os.remove(data_dir .. "/defaults.tests.lua")
os.remove(data_dir .. "/defaults.tests.lua.old")
G_defaults = require("luadefaults"):open(data_dir .. "/defaults.tests.lua")

-- Global reader settings (isolated)
os.remove(data_dir .. "/settings.tests.lua")
os.remove(data_dir .. "/settings.tests.lua.old")
G_reader_settings = require("luasettings"):open(data_dir .. "/settings.tests.lua")

-- Headless framebuffer — no SDL window creation
einkfb = require("ffi/framebuffer") -- luacheck: ignore
einkfb.dummy = true                 -- luacheck: ignore

local Device = require("device")

-- Init output device (dummy screen)
local Screen = Device.screen
Screen:init()

local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

-- Init input device (headless)
local Input = Device.input
Input.dummy = true

-- Module reloading helpers (from KOReader's commonrequire)
package.unload = function(module) -- luacheck: ignore
    if type(module) ~= "string" then return false end
    package.loaded[module] = nil
    _G[module] = nil
    return true
end

package.replace = function(name, module) -- luacheck: ignore
    if type(name) ~= "string" then return false end
    assert(package.unload(name))
    package.loaded[name] = module
    return true
end

package.reload = function(name) -- luacheck: ignore
    if type(name) ~= "string" then return false end
    assert(package.unload(name))
    return require(name)
end

--- Load a specific KOReader plugin by name.
-- Useful for testing plugin interaction with real KOReader infrastructure.
function load_plugin(name) -- luacheck: ignore
    local PluginLoader = require("pluginloader")
    local t = PluginLoader:_discover()
    local plugin_id = name:gsub("%.koplugin$", "")
    for _, v in ipairs(t) do
        if v.name == plugin_id then
            PluginLoader:_load({ v })
            return
        end
    end
    assert(false, "Plugin not found: " .. name)
end

--- Fast-forward all scheduled UI tasks and run the input loop once.
-- Essential for testing async/UI code without blocking.
function fastforward_ui_events() -- luacheck: ignore
    local UIManager = require("ui/uimanager")
    UIManager:shiftScheduledTasksBy(-1e9)
    UIManager:setInputTimeout(0)
    UIManager:handleInput()
end

-- Add our plugin's source to package.path so `require("adobe.*")` works
local plugin_path = os.getenv("PLUGIN_PATH") or "/opt/acsm.koplugin"
package.path = plugin_path .. "/?.lua;" ..
               plugin_path .. "/dependencies/?.lua;" ..
               package.path

print(string.format("[commonrequire] KOReader %s (headless)  Device: %s  Screen: %dx%d",
    require("version"):getCurrentRevision(),
    tostring(Device.model),
    Screen:getWidth(), Screen:getHeight()))
print(string.format("[commonrequire] Data dir: %s", data_dir))
print(string.format("[commonrequire] Plugin path: %s", plugin_path))
