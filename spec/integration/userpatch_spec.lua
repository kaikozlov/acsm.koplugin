--- Integration tests: ACSM external-open user patch
-- Tests that the user patch in patches/2-acsm-open-via-filemanager.lua
-- correctly routes .acsm files opened via external launchers (PocketBook,
-- Android intents, CLI file args) through the FileManager/plugin dispatch
-- path instead of KOReader's document-engine path (which crashes because
-- ACSM has no provider.new).
--
-- All five routing branches in the patch are covered:
--   1. Non-ACSM passthrough
--   2. ReaderUI already open (book loaded)
--   3. FileManager already running
--   4. Cold start (no instance)
--   5. Fallback (ACSM plugin unavailable)

describe("ACSM external-open user patch", function()
    local ReaderUI, FileManager, UIManager
    local plugin_path, patch_path, acsm_fixture
    local real_showReader, real_showFiles
    local saved_rui_instance, saved_fm_instance

    setup(function()
        plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"
        ReaderUI = require("apps/reader/readerui")
        FileManager = require("apps/filemanager/filemanager")
        UIManager = require("ui/uimanager")
        patch_path = plugin_path .. "/patches/2-acsm-open-via-filemanager.lua"
        acsm_fixture = plugin_path .. "/spec/integration/fixtures/sample.acsm"
        real_showReader = ReaderUI.showReader
        real_showFiles = FileManager.showFiles
    end)

    before_each(function()
        saved_rui_instance = ReaderUI.instance
        saved_fm_instance = FileManager.instance
        ReaderUI.instance = nil
        FileManager.instance = nil
    end)

    after_each(function()
        ReaderUI.showReader = real_showReader
        FileManager.showFiles = real_showFiles
        ReaderUI.instance = saved_rui_instance
        FileManager.instance = saved_fm_instance
        UIManager:quit()
    end)

    --- Apply the patch fresh, capturing `spy` as orig_showReader.
    local function applyPatchWithSpy(spy)
        ReaderUI.showReader = spy
        dofile(patch_path)
    end

    describe("non-ACSM files", function()
        it("passes straight through to original showReader", function()
            local calls = {}
            applyPatchWithSpy(function(_, file)
                table.insert(calls, file)
            end)

            ReaderUI:showReader("/tmp/whatever.epub")

            assert.are.equal(1, #calls)
            assert.are.equal("/tmp/whatever.epub", calls[1])
        end)
    end)

    describe("ACSM with ReaderUI already open", function()
        it("dispatches to ReaderUI.instance.acsm:openFile", function()
            local orig_called = false
            applyPatchWithSpy(function()
                orig_called = true
            end)

            local opened
            ReaderUI.instance = {
                acsm = {
                    openFile = function(_, file)
                        opened = file
                    end,
                },
            }

            ReaderUI:showReader(acsm_fixture)

            assert.are.equal(acsm_fixture, opened)
            assert.is_false(orig_called, "orig showReader must not be called")
        end)
    end)

    describe("ACSM with FileManager already running", function()
        it("dispatches via FileManager.instance:openFile", function()
            local orig_called = false
            applyPatchWithSpy(function()
                orig_called = true
            end)

            local opened
            FileManager.instance = {
                acsm = true,
                openFile = function(_, file)
                    opened = file
                end,
            }

            ReaderUI:showReader(acsm_fixture)

            assert.are.equal(acsm_fixture, opened)
            assert.is_false(orig_called, "orig showReader must not be called")
        end)
    end)

    describe("ACSM cold start (no instance)", function()
        it("spins up FileManager then dispatches", function()
            local orig_called = false
            applyPatchWithSpy(function()
                orig_called = true
            end)

            local showfiles_args
            local opened
            FileManager.showFiles = function(_, dir, focused_file)
                showfiles_args = { dir = dir, focused_file = focused_file }
                -- Simulate FM instantiation with plugin loaded
                FileManager.instance = {
                    acsm = true,
                    openFile = function(_, file)
                        opened = file
                    end,
                }
            end

            ReaderUI:showReader(acsm_fixture)
            -- Drain the nextTick scheduled by the patch
            fastforward_ui_events()

            assert.is.truthy(showfiles_args, "FileManager.showFiles was not called")
            assert.are.equal(acsm_fixture, opened, "openFile was not dispatched")
            assert.is_false(orig_called, "orig showReader must not be called")
        end)
    end)

    describe("ACSM with plugin unavailable", function()
        it("falls back to original showReader", function()
            local calls = {}
            applyPatchWithSpy(function(_, file)
                table.insert(calls, file)
            end)

            -- Cold start, but FM does NOT set up the acsm plugin
            FileManager.showFiles = function()
                FileManager.instance = {} -- no .acsm
            end

            ReaderUI:showReader(acsm_fixture)
            fastforward_ui_events()

            assert.are.equal(1, #calls, "fallback should call orig showReader once")
            assert.are.equal(acsm_fixture, calls[1])
        end)
    end)
end)
