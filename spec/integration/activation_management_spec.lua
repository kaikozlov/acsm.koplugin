--- Real KOReader widgets and crypto; synthetic activation, no Adobe requests.
describe("ACSM activation management", function()
    local adobe = require("adobe.adobe")
    local backup = require("adobe.activationbackup")
    local crypto = require("adobe.util.crypto")
    local base64 = require("adobe.util.util").base64
    local ffiUtil = require("ffi/util")
    local json = require("json")
    local lfs = require("libs/libkoreader-lfs")
    local LuaSettings = require("luasettings")
    local UIManager = require("ui/uimanager")
    local Screen = require("device").screen
    local util = require("util")
    local activation, tmp

    setup(function()
        activation = assert(adobe.serializeActivation({
            deviceKey = assert(crypto.deviceKey.new(string.rep("\0", 16))),
            licenseKey = assert(crypto.key.new()),
            user = "urn:uuid:synthetic-user",
            username = "activation@example.invalid",
            licenseCert = "synthetic-license-certificate",
            pkcs12 = require("spec.integration.fixtures.pkcs12").b64,
        }, "urn:uuid:synthetic-device", "synthetic-fingerprint", "synthetic-auth-certificate"))
    end)

    before_each(function()
        tmp = (_G.TEST_DATA_DIR or "/tmp/koreader-test-data") .. "/activation-" .. math.random(100000, 999999)
        assert(util.makePath(tmp))
    end)

    after_each(function()
        ffiUtil.purgeDir(tmp)
    end)

    local function copyActivation()
        return util.tableDeepCopy(activation)
    end

    local function envelope(blob)
        return json.encode({ format = "acsm-activation", version = 1, activation = blob })
    end

    local function writeFile(path, text)
        assert(util.writeToFile(text, path))
    end

    local function readFile(path)
        return assert(util.readFromFile(path))
    end

    local function entries(path)
        local names = {}
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                names[#names + 1] = name
            end
        end
        table.sort(names)
        return names
    end

    local function reject(text)
        local blob, err = backup.decode(text)
        assert.is_nil(blob)
        assert.is_truthy(err)
    end

    it("round-trips activation fields and restores the original private keys", function()
        local decoded = assert(backup.decode(assert(backup.encode(activation))))
        assert.are.same(activation, decoded)
        local restored = assert(adobe.restoreActivation(decoded))
        assert.are.equal(string.rep("\0", 16), restored.creds.deviceKey.key)
        assert.are.equal(base64.decode(activation.privateLicenseKey), restored.creds.licenseKey:topkcs8())
    end)

    it("accepts anonymous activation and imports only activation fields", function()
        local blob = copyActivation()
        for _, field in ipairs({ "username", "licenseCert", "authCert", "activationURL" }) do
            blob[field] = nil
        end
        blob.unrelated_setting = false
        local decoded = assert(backup.decode(envelope(blob)))
        blob.unrelated_setting = nil
        assert.are.same(blob, decoded)
    end)

    it("rejects executable data, invalid envelopes, field types and unusable keys", function()
        for _, text in ipairs({
            "",
            "{broken",
            "return { activation = {} }",
            "null",
            "false",
            "[]",
            "{}",
            json.encode(activation),
            json.encode({ format = "other", version = 1, activation = activation }),
            json.encode({ format = "acsm-activation", version = 2, activation = activation }),
            json.encode({ format = "acsm-activation", version = "1", activation = activation }),
            json.encode({ format = "acsm-activation", version = 1 }),
        }) do
            reject(text)
        end
        for _, field in ipairs({ "deviceKey", "privateLicenseKey", "user", "pkcs12", "deviceUUID", "fingerprint" }) do
            local blob = copyActivation()
            blob[field] = nil
            reject(envelope(blob))
            for _, value in ipairs({ "", false, 0, {} }) do
                blob[field] = value
                reject(envelope(blob))
            end
        end
        for _, field in ipairs({ "username", "licenseCert", "authCert", "activationURL" }) do
            local blob = copyActivation()
            blob[field] = {}
            reject(envelope(blob))
        end
        for field, value in pairs({ privateLicenseKey = "invalid DER", pkcs12 = "invalid PKCS#12", deviceKey = "short" }) do
            local blob = copyActivation()
            blob[field] = base64.encode(value)
            reject(envelope(blob))
        end
        local blob = copyActivation()
        blob.deviceKey = base64.encode(string.rep("x", 16))
        reject(envelope(blob)) -- correct key length, wrong PKCS#12 password
    end)

    it("includes the newline in the export size limit", function()
        local blob = copyActivation()
        blob.fingerprint = blob.fingerprint .. string.rep("x", backup.MAX_SIZE - #assert(backup.encode(blob)))
        local text = assert(backup.encode(blob))
        assert.are.equal(backup.MAX_SIZE, #text)
        assert.are.same(blob, assert(backup.decode(text)))
        blob.fingerprint = blob.fingerprint .. "x"
        assert.is_nil(backup.encode(blob))
        reject(text .. " ")
    end)

    it("replaces exports privately and preserves the destination on invalid data", function()
        local path = tmp .. "/backup.json"
        writeFile(path, "old contents")
        assert(backup.write(path, activation))
        assert.are.same(activation, assert(backup.read(path)))
        assert.are.equal("rw-------", lfs.attributes(path, "permissions"))
        local before = readFile(path)
        local invalid = copyActivation()
        invalid.deviceKey = "invalid"
        assert.is_nil(backup.write(path, invalid))
        assert.are.equal(before, readFile(path))
        assert.are.same({ "backup.json" }, entries(tmp))
    end)

    it("rejects missing, non-file, empty and oversized inputs and unwritable destinations", function()
        writeFile(tmp .. "/empty.json", "")
        writeFile(tmp .. "/large.json", string.rep(" ", backup.MAX_SIZE + 1))
        for _, path in ipairs({ tmp .. "/missing.json", tmp, tmp .. "/empty.json", tmp .. "/large.json" }) do
            assert.is_nil(backup.read(path))
        end
        local before = entries(tmp)
        assert.is_nil(backup.write(tmp, activation))
        assert.is_nil(backup.write(tmp .. "/missing/backup.json", activation))
        assert.are.same(before, entries(tmp))
    end)

    describe("FileManager activation menu", function()
        local fm, plugin

        before_each(function()
            disable_plugins()
            load_plugin("acsm.koplugin")
            fm = require("apps/filemanager/filemanager"):new({ dimen = Screen:getSize(), root_path = tmp })
            UIManager:show(fm)
            fastforward_ui_events()
            plugin = assert(require("pluginloader"):getPluginInstance("acsm"))
            plugin.settings_file = tmp .. "/acsm.lua"
            plugin.settings = nil
            plugin:loadSettings()
            plugin.reuse_existing = false
            plugin.open_after_download = false
        end)

        after_each(function()
            local widget = UIManager:getTopmostVisibleWidget()
            while widget and widget ~= fm do
                UIManager:close(widget)
                widget = UIManager:getTopmostVisibleWidget()
            end
            plugin.settings.file = plugin.settings_file
            fm:onClose()
            UIManager:quit()
        end)

        local function findButton(widget, text)
            if widget.text == text and widget.onTapSelectButton then
                return widget
            end
            for _, child in ipairs(widget) do
                if type(child) == "table" then
                    local button = findButton(child, text)
                    if button then
                        return button
                    end
                end
            end
        end

        local function press(text)
            for i = #UIManager._window_stack, 1, -1 do
                local button = findButton(UIManager._window_stack[i].widget, text)
                if button then
                    button:onTapSelectButton()
                    fastforward_ui_events()
                    return
                end
            end
            error("Missing rendered button: " .. text)
        end

        local function selectItem(menu, text)
            for _, item in ipairs(menu.item_table) do
                if item.text == text then
                    menu:onMenuSelect(item)
                    fastforward_ui_events()
                    return
                end
            end
            error("Missing menu entry: " .. text)
        end

        local function openMenu()
            fm.menu:onShowMenu()
            local menu = fm.menu.menu_container[1]
            menu:onMenuSelect(fm.menu.menu_items.acsm)
            selectItem(menu, "Adobe activation")
            return menu
        end

        local function choose(path)
            UIManager:getTopmostVisibleWidget():onMenuHold({ path = path })
            fastforward_ui_events()
            press("Choose")
        end

        local function inputDialog()
            for i = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[i].widget
                if widget.getInputText then
                    return widget
                end
            end
            error("Missing filename dialog")
        end

        local function assertSaved(blob)
            assert.are.same(blob, plugin.activation_blob)
            assert.are.same(blob, plugin.settings:readSetting("activation"))
            assert.are.same(blob, LuaSettings:open(plugin.settings_file):readSetting("activation"))
        end

        local function exportEnabled(menu)
            for _, row in ipairs(menu.item_group) do
                if row.item and row.item.text == "Export activation to file" then
                    return row:isEnabled()
                end
            end
            error("Missing rendered export entry")
        end

        it("loads validated data after confirmation and keeps preferences across reload", function()
            local path = tmp .. "/backup.json"
            assert(backup.write(path, activation))
            local menu = openMenu()
            selectItem(menu, "Load activation from file")
            choose(path)
            assertSaved(nil)
            writeFile(path, "invalid replacement") -- confirm the validated data, not a later file swap
            press("Load")
            assertSaved(activation)
            assert.is_true(exportEnabled(menu))
            plugin.settings = nil
            plugin:loadSettings()
            assertSaved(activation)
            assert.is_false(plugin.reuse_existing)
            assert.is_false(plugin.open_after_download)
        end)

        it("preserves activation on cancelled or invalid replacement, then replaces only activation", function()
            assert(plugin:saveActivation(activation))
            local before = readFile(plugin.settings_file)
            local candidate = copyActivation()
            candidate.user = "urn:uuid:replacement"
            local path = tmp .. "/candidate.json"
            assert(backup.write(path, candidate))
            local menu = openMenu()
            selectItem(menu, "Load activation from file")
            choose(path)
            press("Cancel")
            assertSaved(activation)
            assert.are.equal(before, readFile(plugin.settings_file))
            writeFile(path, "return { activation = {} }")
            selectItem(menu, "Load activation from file")
            choose(path)
            assertSaved(activation)
            assert.are.equal(before, readFile(plugin.settings_file))
            UIManager:close(UIManager:getTopmostVisibleWidget())
            assert(backup.write(path, candidate))
            selectItem(menu, "Load activation from file")
            choose(path)
            press("Replace")
            assertSaved(candidate)
            local disk = LuaSettings:open(plugin.settings_file)
            assert.is_false(disk:readSetting("reuse_existing"))
            assert.is_false(disk:readSetting("open_after_download"))
        end)

        it("rolls back failed replacement and forgetting in memory and on disk", function()
            assert(plugin:saveActivation(activation))
            local before = readFile(plugin.settings_file)
            local candidate = copyActivation()
            candidate.user = "urn:uuid:unsaved"
            local path = tmp .. "/candidate.json"
            assert(backup.write(path, candidate))
            plugin.settings.file = tmp -- a real directory cannot be replaced by settings
            local menu = openMenu()
            selectItem(menu, "Load activation from file")
            choose(path)
            press("Replace")
            assertSaved(activation)
            assert.are.equal(before, readFile(plugin.settings_file))
            UIManager:close(UIManager:getTopmostVisibleWidget())
            selectItem(menu, "Forget activation")
            press("Forget")
            assertSaved(activation)
            assert.are.equal(before, readFile(plugin.settings_file))
            assert.is_true(exportEnabled(menu))
            assert.are.same({ "acsm.lua", "candidate.json" }, entries(tmp))
        end)

        it("confirms forgetting, retains exports and refreshes the visible menu", function()
            assert(plugin:saveActivation(activation))
            local path = tmp .. "/backup.json"
            assert(backup.write(path, activation))
            local menu = openMenu()
            selectItem(menu, "Forget activation")
            press("Cancel")
            assertSaved(activation)
            selectItem(menu, "Forget activation")
            press("Forget")
            assertSaved(nil)
            assert.are.same(activation, assert(backup.read(path)))
            assert.is_false(exportEnabled(menu))
        end)

        it("exports through the native choosers with privacy, filename and overwrite confirmation", function()
            assert(plugin:saveActivation(activation))
            selectItem(openMenu(), "Export activation to file")
            press("Cancel")
            assert.are.same({ "acsm.lua" }, entries(tmp))
            selectItem(openMenu(), "Export activation to file")
            press("Choose folder")
            choose(tmp)
            local dialog = inputDialog()
            for _, name in ipairs({ "", ".", "..", "../outside.json", "folder/backup.json", "folder\\backup.json" }) do
                dialog:setInputText(name)
                press("Export")
                assert.are.same({ "acsm.lua" }, entries(tmp))
                UIManager:close(UIManager:getTopmostVisibleWidget())
            end
            local path = tmp .. "/existing.json"
            writeFile(path, "keep until confirmed")
            dialog:setInputText("existing.json")
            press("Export")
            assert.are.equal("keep until confirmed", readFile(path))
            press("Cancel")
            assert.are.equal("keep until confirmed", readFile(path))
            selectItem(openMenu(), "Export activation to file")
            press("Choose folder")
            choose(tmp)
            inputDialog():setInputText("existing.json")
            press("Export")
            press("Replace")
            assert.are.same(activation, assert(backup.read(path)))
            assertSaved(activation)
        end)
    end)
end)
