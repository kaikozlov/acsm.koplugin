--- Integration tests: plugin lifecycle
-- Tests the plugin as KOReader sees it — loaded through PluginLoader,
-- initialized with real UIManager, menu items exercised, settings
-- persisted. Modeled on KOReader's exporter_plugin_main_spec.lua and
-- switch_plugin_spec.lua.

describe("ACSM plugin lifecycle", function()
    local UIManager, Screen, DocumentRegistry, DataStorage
    local plugin_path

    setup(function()
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        DocumentRegistry = require("document/documentregistry")
        DataStorage = require("datastorage")
        plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"
    end)

    describe("plugin loading", function()
        it("loads via PluginLoader without error", function()
            -- Discover and load just our plugin
            local PluginLoader = require("pluginloader")
            local discovered = PluginLoader:_discover()
            local found = false
            for _, v in ipairs(discovered) do
                if v.name == "acsm.koplugin" or v.name == "acsm" then
                    found = true
                    assert.is_false(v.disabled)
                    break
                end
            end
            assert.is_true(found, "acsm.koplugin not found in plugin discovery")
        end)

        it("has correct metadata", function()
            local meta = dofile(plugin_path .. "/_meta.lua")
            assert.are.equal("acsm", meta.name)
            assert.is.truthy(meta.fullname)
            assert.is.truthy(meta.description)
            assert.is.truthy(meta.version)
        end)
    end)

    describe("DocumentRegistry integration", function()
        it("registers .acsm extension", function()
            disable_plugins()
            load_plugin("acsm.koplugin")

            -- FileManager needs to be created to trigger plugin init
            local FileManager = require("apps/filemanager/filemanager")
            local fm = FileManager:new{
                dimen = Screen:getSize(),
                root_path = DataStorage:getDataDir(),
            }
            UIManager:show(fm)
            fastforward_ui_events()

            -- Check that .acsm files have a provider registered
            local providers = DocumentRegistry:getProviders("test.acsm")
            assert.is.truthy(providers)
            assert.is_true(#providers > 0, ".acsm should have at least one provider")

            local found_acsm = false
            for _, p in ipairs(providers) do
                if p.provider and p.provider.provider == "acsm" then
                    found_acsm = true
                    break
                end
            end
            assert.is_true(found_acsm, "acsm provider not registered for .acsm files")

            fm:onClose()
            UIManager:quit()
        end)
    end)

    describe("menu items", function()
        it("registers under more_tools", function()
            disable_plugins()
            load_plugin("acsm.koplugin")

            local FileManager = require("apps/filemanager/filemanager")
            local fm = FileManager:new{
                dimen = Screen:getSize(),
                root_path = DataStorage:getDataDir(),
            }
            UIManager:show(fm)
            fastforward_ui_events()

            -- Find the ACSM plugin instance
            local PluginLoader = require("pluginloader")
            local instance = PluginLoader:getPluginInstance("acsm")
            if instance then
                local menu_items = {}
                instance:addToMainMenu(menu_items)
                assert.is.truthy(menu_items.acsm, "acsm menu item not registered")
                assert.is.truthy(menu_items.acsm.text)
                assert.are.equal("more_tools", menu_items.acsm.sorting_hint)
                -- Verify sub-menu is generated
                assert.is.truthy(menu_items.acsm.sub_item_table_func)
                local sub_items = menu_items.acsm.sub_item_table_func()
                assert.is_true(#sub_items >= 3, "Expected at least 3 sub-menu items")
            end

            fm:onClose()
            UIManager:quit()
        end)
    end)

    describe("ACSM metadata parsing", function()
        it("parses title from sample.acsm fixture", function()
            -- Load the ACSM module directly (doesn't need full plugin init)
            local main = dofile(plugin_path .. "/main.lua")
            local fixture_path = plugin_path .. "/spec/integration/fixtures/sample.acsm"
            local meta = main.parseAcsmMetadata(main, fixture_path)
            assert.is.truthy(meta, "parseAcsmMetadata returned nil")
            assert.are.equal("The Adventures of Sherlock Holmes", meta.title)
        end)

        it("parses resourceId from sample.acsm fixture", function()
            local main = dofile(plugin_path .. "/main.lua")
            local fixture_path = plugin_path .. "/spec/integration/fixtures/sample.acsm"
            local meta = main.parseAcsmMetadata(main, fixture_path)
            assert.is.truthy(meta)
            assert.are.equal("urn:uuid:723caf6a-0e27-44be-8733-904cede39cd2", meta.resourceId)
        end)

        it("parses identifier from sample.acsm fixture", function()
            local main = dofile(plugin_path .. "/main.lua")
            local fixture_path = plugin_path .. "/spec/integration/fixtures/sample.acsm"
            local meta = main.parseAcsmMetadata(main, fixture_path)
            assert.is.truthy(meta)
            assert.are.equal("urn:isbn:978-0-00-000000-0", meta.identifier)
        end)

        it("returns nil for non-existent file", function()
            local main = dofile(plugin_path .. "/main.lua")
            local meta = main.parseAcsmMetadata(main, "/nonexistent/path.acsm")
            assert.is_nil(meta)
        end)
    end)

    describe("output path derivation", function()
        it("derives path from title", function()
            local main = dofile(plugin_path .. "/main.lua")
            local meta = { title = "The Adventures of Sherlock Holmes" }
            local path = main.deriveOutputPath(main, "/books/test.acsm", meta)
            assert.is.truthy(path)
            assert.is.truthy(path:find("The Adventures of Sherlock Holmes%.epub$"))
            assert.is.truthy(path:match("^/books/"))
        end)

        it("derives title-based name from URLLink.acsm (Overdrive-style)", function()
            local main = dofile(plugin_path .. "/main.lua")
            local meta = { title = "Great Expectations" }
            local path = main.deriveOutputPath(main, "/books/URLLink.acsm", meta)
            assert.are.equal("/books/Great Expectations.epub", path)
        end)

        it("derives title-based name from sample.acsm fixture end-to-end", function()
            local main = dofile(plugin_path .. "/main.lua")
            local fixture_path = plugin_path .. "/spec/integration/fixtures/sample.acsm"
            local meta = main.parseAcsmMetadata(main, fixture_path)
            assert.is.truthy(meta.title)
            local path = main.deriveOutputPath(main, "/downloads/URLLink.acsm", meta)
            assert.are.equal("/downloads/The Adventures of Sherlock Holmes.epub", path)
        end)

        it("falls back to acsm filename when no title", function()
            local main = dofile(plugin_path .. "/main.lua")
            local path = main.deriveOutputPath(main, "/books/my-loan.acsm", nil)
            assert.are.equal("/books/my-loan.epub", path)
        end)

        it("falls back when title is empty", function()
            local main = dofile(plugin_path .. "/main.lua")
            local meta = { title = "" }
            local path = main.deriveOutputPath(main, "/books/test.acsm", meta)
            assert.are.equal("/books/test.epub", path)
        end)
    end)

    describe("unique path finding", function()
        it("returns original path when it does not exist", function()
            local main = dofile(plugin_path .. "/main.lua")
            local tmpDir = DataStorage:getDataDir() .. "/test-unique-" .. tostring(os.time())
            require("util").makePath(tmpDir)
            local path = tmpDir .. "/unique-test.epub"
            local result = main.findUniquePath(main, path)
            assert.are.equal(path, result)
            -- Cleanup the placeholder file it created
            os.remove(result)
            os.execute("rm -rf " .. tmpDir)
        end)

        it("appends counter when path exists", function()
            local main = dofile(plugin_path .. "/main.lua")
            local tmpDir = DataStorage:getDataDir() .. "/test-unique2-" .. tostring(os.time())
            require("util").makePath(tmpDir)

            -- Create the base file
            local path = tmpDir .. "/book.epub"
            local f = io.open(path, "w")
            f:write("existing")
            f:close()

            local result = main.findUniquePath(main, path)
            assert.is_not.equal(path, result)
            assert.is.truthy(result:find("book %(1%)%.epub$"))

            -- Cleanup
            os.remove(path)
            os.remove(result)
            os.execute("rm -rf " .. tmpDir)
        end)
    end)

    describe("settings persistence", function()
        it("saves and loads settings", function()
            local main = dofile(plugin_path .. "/main.lua")
            local tmpDir = DataStorage:getDataDir() .. "/test-settings-" .. tostring(os.time())
            require("util").makePath(tmpDir)

            -- Override settings file path
            main.settings_file = tmpDir .. "/acsm-test.lua"

            -- Simulate loading and changing settings
            main:loadSettings()
            main.open_after_download = false
            main.reuse_existing = false
            main:saveSettings()

            -- Reload and verify
            main.settings = nil  -- force re-read
            main:loadSettings()
            assert.is_false(main.open_after_download)
            assert.is_false(main.reuse_existing)

            os.execute("rm -rf " .. tmpDir)
        end)
    end)
end)
