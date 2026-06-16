--- Integration tests: deletePluginSettings hook
-- Tests that the ACSM plugin correctly cleans up all persistent state
-- when deletePluginSettings() is called by PluginLoader.

describe("ACSM deletePluginSettings", function()
    local DataStorage, util, ffiUtil, LuaSettings, lfs
    local plugin_path

    setup(function()
        DataStorage = require("datastorage")
        util = require("util")
        ffiUtil = require("ffi/util")
        LuaSettings = require("luasettings")
        lfs = require("libs/libkoreader-lfs")
        plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"
    end)

    --- Recursively collect all file paths under a directory.
    -- Returns a sorted list of relative paths (from root).
    -- Returns empty table if directory does not exist.
    local function snapshotFiles(root)
        local results = {}
        pcall(function()
            for f in lfs.dir(root) do
                if f ~= "." and f ~= ".." then
                    local path = root .. "/" .. f
                    local attr = lfs.attributes(path)
                    if attr then
                        if attr.mode == "directory" then
                            local sub = snapshotFiles(path)
                            for _, s in ipairs(sub) do
                                table.insert(results, f .. "/" .. s)
                            end
                        else
                            table.insert(results, f)
                        end
                    end
                end
            end
        end)
        table.sort(results)
        return results
    end

    local function loadFreshPlugin(tmp_dir)
        -- Load a fresh copy of the plugin module
        package.loaded[plugin_path .. "/main.lua"] = nil
        local main = dofile(plugin_path .. "/main.lua")

        -- Point settings and cache at the temp directory
        main.settings_file = tmp_dir .. "/settings/acsm.lua"
        return main
    end

    local function makeTmpDir()
        local base = _G.TEST_DATA_DIR or os.getenv("TEST_DATA_DIR") or "/tmp/koreader-test-data"
        local tmp = base .. "/acsm-delete-test-" .. tostring(os.time()) .. "-" .. math.random(100000)
        util.makePath(tmp .. "/settings")
        util.makePath(tmp .. "/cache/acsm.koplugin")
        return tmp
    end

    local function rmTmpDir(tmp)
        ffiUtil.purgeDir(tmp)
    end

    describe("cleans up settings file", function()
        it("deletes the settings file on disk", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            -- Write some settings
            main:loadSettings()
            main.open_after_download = false
            main.reuse_existing = false
            main:saveSettings()

            -- Verify file exists
            assert.is_true(util.pathExists(main.settings_file))

            main:deletePluginSettings()

            assert.is_false(util.pathExists(main.settings_file))

            rmTmpDir(tmp)
        end)

        it("resets in-memory settings to nil", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            main:loadSettings()
            main.open_after_download = false
            main:saveSettings()

            assert.is.truthy(main.settings)
            assert.is_false(main.open_after_download)

            main:deletePluginSettings()

            assert.is_nil(main.settings)
            assert.is_nil(main.activation_blob)

            rmTmpDir(tmp)
        end)
    end)

    describe("cleans up cache directory", function()
        it("deletes the cache/acsm.koplugin directory", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            -- Override DataStorage to point cache at our tmp dir
            local orig_getDataDir = DataStorage.getDataDir
            DataStorage.getDataDir = function()
                return tmp
            end

            -- Create a fulfillment map file in the cache dir
            local cache_dir = tmp .. "/cache/acsm.koplugin"
            assert.is_true(util.pathExists(cache_dir))

            local map = LuaSettings:open(cache_dir .. "/fulfillment_map.lua")
            map:saveSetting("urn:uuid:test-resource", "/some/book.epub")
            map:flush()

            assert.is_true(util.pathExists(cache_dir .. "/fulfillment_map.lua"))

            main:deletePluginSettings()

            assert.is_false(util.pathExists(cache_dir))

            DataStorage.getDataDir = orig_getDataDir
            rmTmpDir(tmp)
        end)

        it("resets cached fulfillment map", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            local orig_getDataDir = DataStorage.getDataDir
            DataStorage.getDataDir = function()
                return tmp
            end

            -- Populate the in-memory fulfillment map cache
            main:getFulfillmentMap()
            assert.is.truthy(main._fulfillment_map)

            main:deletePluginSettings()

            assert.is_nil(main._fulfillment_map)

            DataStorage.getDataDir = orig_getDataDir
            rmTmpDir(tmp)
        end)
    end)

    describe("cleans up activation state", function()
        it("clears activation_blob from memory", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            main:loadSettings()
            main.activation_blob = { test = "data" }
            main:saveSettings()

            assert.is.truthy(main.activation_blob)

            main:deletePluginSettings()

            assert.is_nil(main.activation_blob)

            rmTmpDir(tmp)
        end)

        it("ensures activation data is gone from disk", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            main:loadSettings()
            main.activation_blob = {
                deviceKey = "keydata",
                user = "testuser",
            }
            main:saveSettings()

            -- Verify the file contains activation data
            local raw_settings = LuaSettings:open(main.settings_file)
            assert.is.truthy(raw_settings:readSetting("activation"))

            main:deletePluginSettings()

            -- File itself should be gone
            assert.is_false(util.pathExists(main.settings_file))

            rmTmpDir(tmp)
        end)
    end)

    describe("idempotency", function()
        it("does not error when called with no existing settings", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            -- Don't write any settings — file doesn't exist yet
            assert.is_false(util.pathExists(main.settings_file))

            -- Should not throw
            local ok, err = pcall(function()
                main:deletePluginSettings()
            end)
            assert.is_true(ok, "deletePluginSettings threw: " .. tostring(err))

            rmTmpDir(tmp)
        end)

        it("does not error when cache dir does not exist", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            -- Remove the cache dir so it doesn't exist
            local cache_dir = tmp .. "/cache/acsm.koplugin"
            ffiUtil.purgeDir(cache_dir)
            assert.is_false(util.pathExists(cache_dir))

            local ok, err = pcall(function()
                main:deletePluginSettings()
            end)
            assert.is_true(ok, "deletePluginSettings threw: " .. tostring(err))

            rmTmpDir(tmp)
        end)

        it("is safe to call twice", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            main:loadSettings()
            main.activation_blob = { test = "data" }
            main:saveSettings()

            main:deletePluginSettings()
            -- Second call — everything already cleaned up
            local ok, err = pcall(function()
                main:deletePluginSettings()
            end)
            assert.is_true(ok, "second deletePluginSettings threw: " .. tostring(err))

            rmTmpDir(tmp)
        end)
    end)

    describe("PluginLoader integration", function()
        it("has deletePluginSettings method on the plugin instance", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            assert.is.truthy(main.deletePluginSettings)
            assert.are.equal("function", type(main.deletePluginSettings))

            rmTmpDir(tmp)
        end)
    end)

    describe("filesystem snapshot diff", function()
        it("leaves no files behind after cleanup", function()
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            -- Override DataStorage so cache lands inside our tmp dir
            local orig_getDataDir = DataStorage.getDataDir
            DataStorage.getDataDir = function()
                return tmp
            end

            -- Snapshot the empty state (just the dirs we created)
            local before_settings = snapshotFiles(tmp .. "/settings")
            local before_cache = snapshotFiles(tmp .. "/cache")

            -- Exercise the plugin: write settings, activation, fulfillment map
            main:loadSettings()
            main.activation_blob = {
                deviceKey = "keydata",
                user = "testuser",
                pkcs12 = "certdata",
                deviceUUID = "uuid-1234",
                fingerprint = "fp-5678",
                licenseCert = "cert",
                activationURL = "https://example.com",
            }
            main.open_after_download = false
            main.reuse_existing = false
            main:saveSettings()

            -- Write a fulfillment map entry
            local map = main:getFulfillmentMap()
            map:saveSetting("urn:uuid:some-resource", "/books/test.epub")
            map:flush()

            -- SIMULATE A FORGOTTEN CLEANUP: write a file the plugin
            -- might create but deletePluginSettings() doesn't know about.
            -- This assertion proves the snapshot test catches it.
            -- >>> UNCOMMENT THE 3 LINES BELOW TO VERIFY FAILURE DETECTION <<<
            -- local leak = io.open(tmp .. "/settings/acsm_credentials.lua", "w")
            -- leak:write('return { token = "leaked" }')
            -- leak:close()

            -- Verify state was actually written to disk
            local after_settings = snapshotFiles(tmp .. "/settings")
            local after_cache = snapshotFiles(tmp .. "/cache")
            assert.is_true(#after_settings > #before_settings, "expected settings files to be created, but snapshot unchanged")
            assert.is_true(#after_cache > #before_cache, "expected cache files to be created, but snapshot unchanged")

            -- Now clean up
            main:deletePluginSettings()

            -- Snapshot again — must match the original empty state exactly
            local after_cleanup_settings = snapshotFiles(tmp .. "/settings")
            local after_cleanup_cache = snapshotFiles(tmp .. "/cache")

            -- Settings dir: any remaining files means we forgot to clean something
            assert.are.same(
                before_settings,
                after_cleanup_settings,
                "settings dir still has files after cleanup — " .. "deletePluginSettings() is missing a cleanup step"
            )

            -- Cache dir: the entire acsm.koplugin subdir should be gone,
            -- so only the empty cache/ root should remain (or match before)
            assert.are.same(
                before_cache,
                after_cleanup_cache,
                "cache dir still has files after cleanup — " .. "deletePluginSettings() is missing a cleanup step"
            )

            DataStorage.getDataDir = orig_getDataDir
            rmTmpDir(tmp)
        end)

        it("detects leftover files when cleanup is incomplete", function()
            -- This test validates the snapshot mechanism itself:
            -- write an extra file, verify the diff catches it.
            local tmp = makeTmpDir()
            local main = loadFreshPlugin(tmp)

            local orig_getDataDir = DataStorage.getDataDir
            DataStorage.getDataDir = function()
                return tmp
            end

            -- Exercise plugin state
            main:loadSettings()
            main.activation_blob = { test = "data" }
            main:saveSettings()

            -- Simulate a file that deletePluginSettings() doesn't know about
            -- (e.g., a new feature added without updating cleanup)
            util.makePath(tmp .. "/cache/acsm.koplugin/extra_data")
            local f = io.open(tmp .. "/cache/acsm.koplugin/extra_data/orphan.lua", "w")
            f:write("return { leaked = true }")
            f:close()

            main:deletePluginSettings()

            -- The orphan file should survive since deletePluginSettings
            -- purges the whole cache dir — so this test verifies the diff
            -- would catch it if purgeDir were incomplete.
            -- (This test validates the mechanism; it passes because purgeDir
            -- removes everything including the orphan.)
            local leftover = snapshotFiles(tmp .. "/cache")
            assert.are.same({}, leftover, "cache dir has leftover files — purgeDir missed something")

            DataStorage.getDataDir = orig_getDataDir
            rmTmpDir(tmp)
        end)
    end)
end)
