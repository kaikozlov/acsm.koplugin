--- Integration tests: ACSM external-open user patch (real instances)
--
-- These exercise the patch against REAL KOReader FileManager instances and
-- the REAL ACSM plugin (loaded by PluginLoader), covering the two external
-- open paths that match the actual PocketBook bug (issue #16):
--
--   1. Cold start: KOReader launched with a .acsm file argument
--      (platform/pocketbook/koreader.app → reader.lua → showReader)
--   2. Already running: KOReader in FileManager, OS sends another .acsm
--      (PocketBook tryOpenBook → showReader)
--
-- Network is the only thing stubbed: we replace the real plugin instance's
-- openFile with a spy at the last mile, so the full real dispatch chain
-- (patch → FileManager:openFile → DocumentRegistry:getProvider(include_aux)
-- → self.acsm:openFile) is exercised without hitting Adobe servers.

describe("ACSM external-open user patch (real instances)", function()
    local ReaderUI, FileManager, UIManager, Screen, DataStorage
    local plugin_path, patch_path, acsm_fixture
    local real_showReader

    setup(function()
        plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"
        ReaderUI = require("apps/reader/readerui")
        FileManager = require("apps/filemanager/filemanager")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        DataStorage = require("datastorage")
        patch_path = plugin_path .. "/patches/2-acsm-open-via-filemanager.lua"
        acsm_fixture = plugin_path .. "/spec/integration/fixtures/sample.acsm"
        real_showReader = ReaderUI.showReader
    end)

    after_each(function()
        ReaderUI.showReader = real_showReader
        if FileManager.instance then
            FileManager.instance:onClose()
        end
        if ReaderUI.instance then
            ReaderUI.instance:onClose()
        end
        UIManager:quit()
    end)

    --- Spy the real plugin instance's openFile to intercept just before network.
    -- Returns a reset function.
    local function spyPluginOpenFile(fm)
        assert.is.truthy(fm.acsm, "real ACSM plugin not registered on FileManager")
        local opened
        local real_open = fm.acsm.openFile
        fm.acsm.openFile = function(_, file)
            opened = file
        end
        return function()
            fm.acsm.openFile = real_open
            return opened
        end
    end

    it("cold start: spins up real FileManager and routes to its plugin", function()
        disable_plugins()
        load_plugin("acsm.koplugin")

        -- Apply the patch fresh (no instance exists yet).
        ReaderUI.showReader = real_showReader
        dofile(patch_path)
        assert.is_nil(FileManager.instance)
        assert.is_nil(ReaderUI.instance)

        -- This is what koreader.app does on a cold launch with a file arg.
        ReaderUI:showReader(acsm_fixture)

        -- showFiles ran synchronously → a real FileManager now exists with the
        -- real plugin instantiated by PluginLoader inside FileManager:init.
        assert.is.truthy(FileManager.instance, "patch did not spin up FileManager")

        -- Intercept before the nextTick fires so we don't hit the network.
        local reset = spyPluginOpenFile(FileManager.instance)

        -- Drain the patch's UIManager:nextTick dispatch.
        fastforward_ui_events()

        assert.are.equal(acsm_fixture, reset(), "real FileManager:openFile did not reach the ACSM plugin")
    end)

    it("running FileManager: routes to its existing plugin instance", function()
        disable_plugins()
        load_plugin("acsm.koplugin")

        -- Stand up a real FileManager first (simulates KOReader already open).
        local fm = FileManager:new({
            dimen = Screen:getSize(),
            root_path = DataStorage:getDataDir(),
        })
        UIManager:show(fm)
        fastforward_ui_events()
        assert.is.truthy(fm.acsm, "real plugin not loaded into FileManager")

        -- Apply the patch now that an instance exists.
        ReaderUI.showReader = real_showReader
        dofile(patch_path)

        local reset = spyPluginOpenFile(fm)

        -- This is what PocketBook's tryOpenBook does to a running instance.
        ReaderUI:showReader(acsm_fixture)

        assert.are.equal(acsm_fixture, reset(), "patch did not dispatch via the running FileManager's plugin")
    end)
end)
