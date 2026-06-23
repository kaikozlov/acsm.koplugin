--- Integration tests: ACSM patch routing + real fulfillment (#e2e)
--
-- Verifies the complete chain end-to-end through the user patch:
--   external open → patch routing → real FileManager → real ACSM plugin
--   openFile → real activation → real Adobe fulfillment → real decryption
--
-- This is the only test that exercises ACSM:openFile() (with its Trapper /
-- NetworkMgr / UIManager wrapping) rather than calling fulfillment.process()
-- directly. It proves that fulfillment works correctly when reached via the
-- external-open routing path.
--
-- Tagged #e2e — requires network. Run with:
--   just test-e2e

describe("ACSM patch + real fulfillment #e2e", function()
    local http, ltn12, koutil, lfs, DataStorage

    setup(function()
        http = require("socket.http")
        ltn12 = require("ltn12")
        koutil = require("util")
        lfs = require("libs/libkoreader-lfs")
        DataStorage = require("datastorage")
    end)

    local SAMPLE_ACSM_URL = "https://contentserver.adobe.com/fulfillment/URLLink.acsm"
        .. "?action=free&ordersource=operator"
        .. "&resid=urn%3Auuid%3A9cfb32c9-0976-4825-8a41-4512ab7c8c86"

    local function downloadAcsm(path)
        local socketutil = require("socketutil")
        socketutil:set_timeout(30, 60)
        local resp = {}
        local ok, code = http.request({
            url = SAMPLE_ACSM_URL,
            sink = ltn12.sink.table(resp),
            headers = { ["User-Agent"] = socketutil.USER_AGENT },
            redirect = true,
        })
        socketutil:reset_timeout()
        assert.is.truthy(ok, "Failed to download ACSM: " .. tostring(code))
        koutil.writeToFile(table.concat(resp), path)
    end

    it("routes through the patch and fulfills a real ACSM", function()
        local ReaderUI = require("apps/reader/readerui")
        local FileManager = require("apps/filemanager/filemanager")
        local UIManager = require("ui/uimanager")
        local NetworkMgr = require("ui/network/manager")
        local plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"

        --- Setup: isolated temp dir
        local tmpDir = DataStorage:getDataDir() .. "/test-patch-e2e-" .. tostring(os.time())
        koutil.makePath(tmpDir)
        local acsmPath = tmpDir .. "/sample.acsm"

        downloadAcsm(acsmPath)
        local acsm = io.open(acsmPath, "r")
        assert.is.truthy(acsm, "ACSM not written")
        assert.is.truthy(acsm:read("*a"):find("fulfillmentToken"), "Bad ACSM")
        acsm:close()

        --- Load the plugin into real KOReader
        disable_plugins()
        load_plugin("acsm.koplugin")

        --- Override NetworkMgr: headless emulator reports no wifi, but we have
        --- network via --network=host. Bypass the "connect to wifi" prompt.
        NetworkMgr.willRerunWhenOnline = function()
            return false -- we are online; do not rerun
        end

        --- Apply the patch
        local real_showReader = ReaderUI.showReader
        dofile(plugin_path .. "/patches/2-acsm-open-via-filemanager.lua")

        --- Cold-start: this is what PocketBook does on first launch.
        assert.is_nil(FileManager.instance)
        ReaderUI:showReader(acsmPath)

        --- showFiles ran synchronously; a real FileManager now exists.
        assert.is.truthy(FileManager.instance, "patch did not spin up FileManager")
        assert.is.truthy(FileManager.instance.acsm, "plugin not loaded")

        --- Configure the real plugin instance for an isolated, non-reuse run.
        local plugin = FileManager.instance.acsm
        plugin.settings_file = tmpDir .. "/settings/acsm.lua"
        plugin.settings = nil -- force reload from new path
        plugin.reuse_existing = false
        plugin.open_after_download = false

        --- Drain the patch's nextTick → triggers openFile → fulfillment.
        --- Trapper:wrap runs synchronously (first info() doesn't yield), so
        --- the entire activation + fulfillment + decryption happens here.
        local ok, err = pcall(function()
            fastforward_ui_events()
        end)

        --- Restore showReader so cleanup doesn't double-route.
        ReaderUI.showReader = real_showReader

        if not ok then
            if FileManager.instance then
                FileManager.instance:onClose()
            end
            UIManager:quit()
            assert.is.truthy(false, "fastforward errored: " .. tostring(err))
        end

        --- Find the generated EPUB. deriveOutputPath puts it next to the ACSM.
        local found_epub
        for f in lfs.dir(tmpDir) do
            if f:lower():match("%.epub$") and f ~= "sample.acsm" then
                found_epub = tmpDir .. "/" .. f
            end
        end

        assert.is.truthy(found_epub, "No EPUB generated in " .. tmpDir)

        local attr = lfs.attributes(found_epub)
        assert.is.truthy(attr, "Output EPUB missing")
        assert.is_true(attr.size > 0, "Output EPUB is empty")

        --- Verify it's a real EPUB (PK zip header)
        local fh = io.open(found_epub, "rb")
        local magic = fh and fh:read(2) or ""
        fh:close()
        assert.are.equal("PK", magic, "Output is not a valid EPUB zip")

        --- Cleanup
        if FileManager.instance then
            FileManager.instance:onClose()
        end
        UIManager:quit()
        os.execute("rm -rf " .. tmpDir)
    end)
end)
