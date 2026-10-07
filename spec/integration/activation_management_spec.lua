--- Activation backup and menu integration with real KOReader widgets and crypto.
-- Synthetic credentials only: these tests never activate a device or use the network.

describe("ACSM activation management", function()
    local adobe, backup, base64, ffiUtil, json, koutil, lfs, LuaSettings
    local UIManager, Screen, DataStorage, PluginLoader
    local activation, tmp

    -- Same synthetic PKCS#12 fixture as crypto_spec.lua, encrypted with base64(16 zero bytes).
    local pkcs12_b64 = "MIIGpwIBAzCCBlUGCSqGSIb3DQEHAaCCBkYEggZCMIIGPjCCAvoGCSqGSIb3DQEH"
        .. "BqCCAuswggLnAgEAMIIC4AYJKoZIhvcNAQcBMF8GCSqGSIb3DQEFDTBSMDEGCSqG"
        .. "SIb3DQEFDDAkBBD2QrcpnDLGado6wxRZTRBJAgIIADAMBggqhkiG9w0CCQUAMB0G"
        .. "CWCGSAFlAwQBKgQQpQP0/25IWnXTMUTPVR4HPICCAnAhkiorBZui0UHnb1NWTnJ0"
        .. "wWQPnYUgqbrDLdhcnUxM8q8gqML8dxN8afAjK5lVbY1KB/rygP7rZFaZwNPkQXTK"
        .. "I9QUfwbKMBmYYZFZKB7QNncQBR+AiG7Bn/stLN1EU7ECs/iQY8JDXtw+bpuWIDfH"
        .. "7+Zco1cUKUfJi8cdYZMqwlKOmCfhbDndcPeuwDD9wlJrMer9vO3aYrodqzakThq+"
        .. "ziSjoCzokiJR/Md0DTDvosHEQhQMUOrhzCQCnH4fK5L8nD977T4HlNySlzVAV9TbF"
        .. "bkbet93hutKxVh8KoPMUKc3/wHUYV5MkL/ZGIm51lkkPGAX4ZwbugKsuKflUw5j8"
        .. "M2ZA+SI1z6DUHRBzQruj9MnW8I7iM+yPMYypAXEHKIB4YEzv3D8K7l6Abz1UOrPM"
        .. "aP94622ZG1rCelh/nqBY9Tqea0DQ0yaXLOiFELf5JY8w1ogwOxOO+DNqUxFt1ePT"
        .. "Ktn9HF4R+Eix8tRVLWQJncxLUNuPKe9ML7zX/ftgT7Zq6UUPCnyndk+98uRx0CJ5"
        .. "tDPZ9VQwotwLC+/JIGPXqHVQIsIeMfauP/0rSEZzL1wGi07VnkrxFeWSlQ8/nigG"
        .. "poWkosPc+9RtxYdE2jQXnGo2tAEl5WaC9ihhzBai7PzWuNp86eGNHYDPJjtbhwaG"
        .. "EIsHqgwCT4WviKFxwmgEK0R34Krh63Zl1JTc1EFO/o1NZWM5t1xfte8GgIuvHYfC"
        .. "CjYD+LcMjqDxh5GgwyW/UTC2RLkL2SxvZjjgvU6awl68LzhECYICQOeJBtnaa39o"
        .. "Nl+yg23DB4IBeP4ASS93gQwzt6PDcd9H3ei3AWqOSQwggM8BgkqhkiG9w0BBwGg"
        .. "ggMtBIIDKTCCAyUwggMhBgsqhkiG9w0BDAoBAqCCAukwggLlMF8GCSqGSIb3DQEF"
        .. "DTBSMDEGCSqGSIb3DQEFDDAkBBDuCqIC2HTvFp+zyXe8dbY3AgIIADAMBggqhkiG"
        .. "9w0CCQUAMB0GCWCGSAFlAwQBKgQQX6h5wh+U+Maa4s/cGhAMVQSCAoDUTGlvCccl"
        .. "vxh6Iei2v1bNV+lm0r2wYIoZPusVYy5XVp7dxycoLA7+grBEAY1UEsyNum8H8rPb"
        .. "iEUd8BH1ubpWf7H0mdGRsSMkafX0++qGuAn3iFX7KkrYJfgiP3ss7pl7S2BkPq8Z"
        .. "TzI7KUXLYNoA7flcAphRmTi7g3GZjk+JzjFjKwpSDOdvwtdTVQAWDmxyBZR5X6GX"
        .. "i9UGnI1gVEfOueXHa4+ufNd8XtZk/vYOQBP/WBPLZiBGlOD+ypUuTmZA30w8SkMM"
        .. "7OIjWttvXJ/5QmXsC2IZ471H7hIGunDuWHXKpLrRpJfOuX+NG3IJx9nW2sClIv8e"
        .. "2/8/nRhD9LFxtWERGoHcoSz9yZE7I+ndTG5t6TONUHj95lZb6F31BELh+bSWXUT9"
        .. "kRinbRTZQBaw852DQCFtNPrdCD8XxXj47AVjbnP+PMsxqH+ZSosH/DGdhjutKeos"
        .. "MsCgc0Dk3+4K8yFuggAhJzkDaqNLP5DNNwKICALg1/MdVrlwKv/odTqhLXWBTMaK"
        .. "wFGibNYz12afdUagbnRW2PgnZZ2ZEHigzO99+vRIcjqR6XzAd96JGpvHZgxh0YU6"
        .. "DuDmgqvFEybgN8k32iNfnCn4Mkd9GONW5Luxu/3qylZQr+ZZpwO10WaOG+pkXTpm"
        .. "tBzosqdQbqnD6znf+2/d6gPnkB0cqsCiWl3Xfy2aFwReS4xByCOsJQrK5XJgwf4Z"
        .. "PyOr7WJ9nuLpGCFUuL/7mj7W2yUEJb4cyJgh6F8RmH8ytpxU6hmIKU3X84DN8kW4"
        .. "uOhMaM84BJPZGW7xoQUHBgE8hNZixk9nmN/YJHAqN0RVCj4LMeuk2Ec6RXNn1WYp"
        .. "enuu0+FGs86QMSUwIwYJKoZIhvcNAQkVMRYEFF7UYerEclzDSGxj0WWwoG8mT3cM"
        .. "MEkwMTANBglghkgBZQMEAgEFAAQgeSNZrkg0rbit2CT4fvAlDB0he4YMydFcwUeD"
        .. "qz41/n4EELq0JR3dx5ouZgZMH2gVMdQCAggA"

    setup(function()
        adobe = require("adobe.adobe")
        backup = require("adobe.activationbackup")
        base64 = require("adobe.util.util").base64
        ffiUtil = require("ffi/util")
        json = require("json")
        koutil = require("util")
        lfs = require("libs/libkoreader-lfs")
        LuaSettings = require("luasettings")
        UIManager = require("ui/uimanager")
        Screen = require("device").screen
        DataStorage = require("datastorage")
        PluginLoader = require("pluginloader")

        local crypto = require("adobe.util.crypto")
        activation = assert(adobe.serializeActivation({
            deviceKey = assert(crypto.deviceKey.new(string.rep("\0", 16))),
            licenseKey = assert(crypto.key.new()),
            licenseCert = "synthetic-license-certificate",
            user = "urn:uuid:synthetic-backup-user",
            username = "activation-test@example.invalid",
            pkcs12 = pkcs12_b64,
        }, "urn:uuid:synthetic-backup-device", "synthetic-fingerprint", "synthetic-auth-certificate"))
    end)

    before_each(function()
        local base = _G.TEST_DATA_DIR or os.getenv("TEST_DATA_DIR") or "/tmp/koreader-test-data"
        tmp = base .. "/acsm-activation-management-" .. tostring(os.time()) .. "-" .. math.random(100000, 999999)
        koutil.makePath(tmp)
    end)

    after_each(function()
        if tmp then
            ffiUtil.purgeDir(tmp)
            tmp = nil
        end
    end)

    local function copyActivation()
        local copy = {}
        for key, value in pairs(activation) do
            copy[key] = value
        end
        return copy
    end

    local function envelope(blob)
        return json.encode({ format = "acsm-activation", version = 1, activation = blob })
    end

    local function writeFile(path, text)
        local file = assert(io.open(path, "wb"))
        assert(file:write(text))
        assert(file:close())
    end

    local function readFile(path)
        local file = assert(io.open(path, "rb"))
        local text = assert(file:read("*a"))
        assert(file:close())
        return text
    end

    local function directoryEntries(path)
        local entries = {}
        for name in lfs.dir(path) do
            if name ~= "." and name ~= ".." then
                entries[#entries + 1] = name
            end
        end
        table.sort(entries)
        return entries
    end

    local function assertRejected(text)
        local decoded, err = backup.decode(text)
        assert.is_nil(decoded)
        assert.are.equal("string", type(err))
        assert.is_true(#err > 0)
    end

    describe("portable backup format", function()
        it("round-trips every activation field through versioned JSON and real key restoration", function()
            local encoded = assert(backup.encode(activation))
            local container = json.decode(encoded)
            assert.are.equal("acsm-activation", container.format)
            assert.are.equal(1, container.version)
            assert.are.same(activation, container.activation)

            local decoded = assert(backup.decode(encoded))
            assert.are.same(activation, decoded)
            local original = assert(adobe.restoreActivation(activation))
            local restored = assert(adobe.restoreActivation(decoded))
            assert.are.equal(original.creds.deviceKey.key, restored.creds.deviceKey.key)
            assert.are.equal(original.creds.licenseKey:topkcs8(), restored.creds.licenseKey:topkcs8())
        end)

        it("accepts anonymous activation without optional fields and drops unknown fields", function()
            local blob = copyActivation()
            for _, field in ipairs({ "username", "licenseCert", "authCert", "activationURL" }) do
                blob[field] = nil
            end
            blob.unrelated_setting = "must not import arbitrary settings"
            local decoded = assert(backup.decode(envelope(blob)))
            blob.unrelated_setting = nil
            assert.are.same(blob, decoded)
            assert.are.same(blob, assert(backup.decode(assert(backup.encode(blob)))))
        end)

        it("rejects malformed JSON, executable settings, wrong envelopes and unsupported versions", function()
            for _, text in ipairs({
                "",
                "{broken json",
                "return { activation = {} }",
                "null",
                "false",
                "42",
                '"activation"',
                "[]",
                "{}",
                json.encode(activation),
                json.encode({ format = "other-format", version = 1, activation = activation }),
                json.encode({ format = "acsm-activation", version = 2, activation = activation }),
                json.encode({ format = "acsm-activation", version = "1", activation = activation }),
                json.encode({ format = "acsm-activation", version = 1 }),
            }) do
                assertRejected(text)
            end
        end)

        it("requires nonempty strings for every required field", function()
            for _, field in ipairs({ "deviceKey", "privateLicenseKey", "user", "pkcs12", "deviceUUID", "fingerprint" }) do
                local blob = copyActivation()
                blob[field] = nil
                assertRejected(envelope(blob))
                for _, invalid in ipairs({ "", false, 0, {} }) do
                    blob[field] = invalid
                    assertRejected(envelope(blob))
                    local encoded, err = backup.encode(blob)
                    assert.is_nil(encoded)
                    assert.is_truthy(err)
                end
            end
        end)

        it("rejects nonstring optional fields and invalid real key material", function()
            for _, field in ipairs({ "username", "licenseCert", "authCert", "activationURL" }) do
                local blob = copyActivation()
                blob[field] = { "unexpected nested value" }
                assertRejected(envelope(blob))
            end
            local blob = copyActivation()
            blob.privateLicenseKey = base64.encode("not a DER private key")
            assertRejected(envelope(blob))
            blob = copyActivation()
            blob.deviceKey = base64.encode("short")
            assertRejected(envelope(blob))
            blob = copyActivation()
            blob.pkcs12 = base64.encode("invalid PKCS#12")
            assertRejected(envelope(blob))
            blob = copyActivation()
            blob.deviceKey = base64.encode(string.rep("x", 16))
            assertRejected(envelope(blob))
        end)

        it("counts the trailing newline in the size bound so every successful export is loadable", function()
            local blob = copyActivation()
            local initial = assert(backup.encode(blob))
            blob.fingerprint = blob.fingerprint .. string.rep("x", backup.MAX_SIZE - #initial)
            local largest = assert(backup.encode(blob))
            assert.are.equal(backup.MAX_SIZE, #largest)
            assert.are.same(blob, assert(backup.decode(largest)))

            blob.fingerprint = blob.fingerprint .. "x"
            local encoded, err = backup.encode(blob)
            assert.is_nil(encoded)
            assert.is_truthy(err)
            assertRejected(largest .. " ")
        end)
    end)

    describe("backup files", function()
        it("writes a private file that round-trips without leaving temporary files", function()
            local path = tmp .. "/activation.json"
            assert.is_true(backup.write(path, activation))
            assert.are.same(activation, assert(backup.read(path)))
            assert.are.equal("rw-------", lfs.attributes(path, "permissions"))
            assert.are.same({ "activation.json" }, directoryEntries(tmp))
        end)

        it("atomically replaces a regular destination and preserves it if validation fails", function()
            local path = tmp .. "/activation.json"
            writeFile(path, "old contents")
            assert.is_true(backup.write(path, activation))
            local saved = readFile(path)
            local invalid = copyActivation()
            invalid.deviceKey = "invalid"
            local ok, err = backup.write(path, invalid)
            assert.is_nil(ok)
            assert.is_truthy(err)
            assert.are.equal(saved, readFile(path))
            assert.are.same({ "activation.json" }, directoryEntries(tmp))
        end)

        it("rejects missing files, directories, empty files and oversized files", function()
            writeFile(tmp .. "/empty.json", "")
            writeFile(tmp .. "/large.json", string.rep(" ", backup.MAX_SIZE + 1))
            for _, path in ipairs({ tmp .. "/missing.json", tmp, tmp .. "/empty.json", tmp .. "/large.json" }) do
                local decoded, err = backup.read(path)
                assert.is_nil(decoded)
                assert.is_truthy(err)
            end
        end)

        it("reports unwritable destinations without creating leftover backup files", function()
            local before = directoryEntries(tmp)
            for _, path in ipairs({ tmp, tmp .. "/missing-directory/activation.json" }) do
                local ok, err = backup.write(path, activation)
                assert.is_nil(ok)
                assert.is_truthy(err)
            end
            assert.are.same(before, directoryEntries(tmp))
        end)
    end)

    describe("real FileManager activation menu", function()
        local fm, plugin

        before_each(function()
            disable_plugins()
            load_plugin("acsm.koplugin")
            local FileManager = require("apps/filemanager/filemanager")
            fm = FileManager:new({ dimen = Screen:getSize(), root_path = DataStorage:getDataDir() })
            UIManager:show(fm)
            fastforward_ui_events()
            plugin = PluginLoader:getPluginInstance("acsm")
            assert.is_truthy(plugin, "ACSM must be initialized by the real FileManager")
            plugin.settings_file = tmp .. "/acsm.lua"
            plugin.settings = nil
            plugin:loadSettings()
        end)

        after_each(function()
            local widget = UIManager:getTopmostVisibleWidget()
            while widget and widget ~= fm do
                UIManager:close(widget)
                widget = UIManager:getTopmostVisibleWidget()
            end
            if fm then
                fm:onClose()
                fm = nil
            end
            UIManager:quit()
            plugin = nil
        end)

        local function menuItems()
            local registered = {}
            plugin:addToMainMenu(registered)
            return registered.acsm.sub_item_table_func()
        end

        local function activationItems()
            local items = menuItems()
            assert.are.equal("Adobe activation", items[1].text)
            return items[1].sub_item_table_func()
        end

        local function findItem(items, text)
            for _, item in ipairs(items) do
                if item.text == text then
                    return item
                end
            end
            error("Missing menu entry: " .. text)
        end

        -- Traverse real rendered children, then use the same button handler as a tap.
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
            -- The virtual keyboard may be above an InputDialog in the window stack.
            for index = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[index].widget
                if widget == fm then
                    break
                end
                local button = findButton(widget, text)
                if button then
                    button:onTapSelectButton()
                    fastforward_ui_events()
                    return
                end
            end
            error("Missing rendered button: " .. text)
        end

        local function inputDialog()
            for index = #UIManager._window_stack, 1, -1 do
                local widget = UIManager._window_stack[index].widget
                if widget.getInputText then
                    return widget
                end
            end
            error("Missing activation filename dialog")
        end

        local function showItem(text)
            findItem(activationItems(), text).callback()
            fastforward_ui_events()
            return UIManager:getTopmostVisibleWidget()
        end

        local function setActivation(blob)
            plugin.activation_blob = blob
            plugin:saveSettings()
        end

        local function savedActivation()
            return LuaSettings:open(plugin.settings_file):readSetting("activation")
        end

        local function choosePath(chooser, path)
            chooser:onMenuHold({ path = path })
            fastforward_ui_events()
            press("Choose")
            return UIManager:getTopmostVisibleWidget()
        end

        it("groups activation controls, updates their state and preserves download preferences", function()
            local items = menuItems()
            assert.are.equal(3, #items)
            local activation_items = activationItems()
            assert.are.equal(4, #activation_items)
            assert.are.equal("Status: not set", activation_items[1].text_func())
            assert.is_false(activation_items[1].enabled)
            assert.is_false(findItem(activation_items, "Forget activation").enabled_func())
            assert.is_false(findItem(activation_items, "Export activation to file").enabled_func())
            assert.are.equal("function", type(findItem(activation_items, "Load activation from file").callback))

            findItem(items, "Open book after download").callback()
            findItem(items, "Reuse existing file").callback()
            local disk = LuaSettings:open(plugin.settings_file)
            assert.is_false(disk:readSetting("open_after_download"))
            assert.is_false(disk:readSetting("reuse_existing"))

            setActivation(copyActivation())
            assert.are.equal("Status: saved", activation_items[1].text_func())
            assert.is_true(findItem(activation_items, "Forget activation").enabled_func())
            assert.is_true(findItem(activation_items, "Export activation to file").enabled_func())
        end)

        it("requires confirmation to forget and leaves exported files intact", function()
            setActivation(copyActivation())
            local path = tmp .. "/backup.json"
            assert(backup.write(path, activation))
            showItem("Forget activation")
            press("Cancel")
            assert.are.same(activation, plugin.activation_blob)
            assert.are.same(activation, savedActivation())

            showItem("Forget activation")
            press("Forget")
            assert.is_nil(plugin.activation_blob)
            assert.is_nil(savedActivation())
            assert.are.same(activation, assert(backup.read(path)))
            assert.are.equal("Status: not set", activationItems()[1].text_func())
        end)

        it("loads through the file chooser only after confirmation and persists the validated candidate", function()
            local path = tmp .. "/backup.json"
            assert(backup.write(path, activation))
            local chooser = showItem("Load activation from file")
            assert.is_false(chooser.select_directory)
            assert.is_true(chooser.select_file)
            local confirmation = choosePath(chooser, path)
            assert.are.equal("Load", confirmation.ok_text)
            assert.is_nil(plugin.activation_blob)
            assert.is_nil(savedActivation())

            -- The user confirms the already-validated data, not a later file replacement.
            writeFile(path, "invalid replacement")
            press("Load")
            assert.are.same(activation, plugin.activation_blob)
            assert.are.same(activation, savedActivation())
            plugin.settings = nil
            plugin.activation_blob = nil
            plugin:loadSettings()
            assert.are.same(activation, plugin.activation_blob)
        end)

        it("keeps current activation and preferences when replacement is cancelled or invalid", function()
            setActivation(copyActivation())
            plugin.reuse_existing = false
            plugin.open_after_download = false
            plugin:saveSettings()
            local before = readFile(plugin.settings_file)
            local candidate = copyActivation()
            candidate.user = "urn:uuid:different-synthetic-user"
            local path = tmp .. "/candidate.json"
            assert(backup.write(path, candidate))

            local chooser = showItem("Load activation from file")
            local confirmation = choosePath(chooser, path)
            assert.are.equal("Replace", confirmation.ok_text)
            press("Cancel")
            assert.are.same(activation, plugin.activation_blob)
            assert.are.equal(before, readFile(plugin.settings_file))

            candidate.pkcs12 = base64.encode("invalid authentication key")
            writeFile(path, envelope(candidate))
            chooser = showItem("Load activation from file")
            local message = choosePath(chooser, path)
            assert.is_truthy(message.text:find("Could not load activation", 1, true))
            assert.are.same(activation, plugin.activation_blob)
            assert.are.equal(before, readFile(plugin.settings_file))
            assert.is_false(plugin.reuse_existing)
            assert.is_false(plugin.open_after_download)
        end)

        it("replaces activation after confirmation without changing other saved preferences", function()
            setActivation(copyActivation())
            plugin.reuse_existing = false
            plugin.open_after_download = false
            plugin:saveSettings()
            local candidate = copyActivation()
            candidate.user = "urn:uuid:replacement-synthetic-user"
            local path = tmp .. "/replacement.json"
            assert(backup.write(path, candidate))
            local chooser = showItem("Load activation from file")
            choosePath(chooser, path)
            assert.are.same(activation, plugin.activation_blob)
            press("Replace")
            assert.are.same(candidate, plugin.activation_blob)
            assert.are.same(candidate, savedActivation())
            local disk = LuaSettings:open(plugin.settings_file)
            assert.is_false(disk:readSetting("reuse_existing"))
            assert.is_false(disk:readSetting("open_after_download"))
        end)

        it("keeps current activation in memory and on disk when replacement or forgetting cannot be saved", function()
            setActivation(copyActivation())
            local settings_path = plugin.settings_file
            local original = readFile(settings_path)
            local candidate = copyActivation()
            candidate.user = "urn:uuid:unsaved-synthetic-user"
            local path = tmp .. "/candidate.json"
            assert(backup.write(path, candidate))

            -- A real directory cannot be atomically replaced by the settings file.
            plugin.settings_file = tmp .. "/blocked-settings"
            koutil.makePath(plugin.settings_file)
            local chooser = showItem("Load activation from file")
            choosePath(chooser, path)
            press("Replace")
            local message = UIManager:getTopmostVisibleWidget()
            assert.is_truthy(message.text:find("Could not save activation", 1, true))
            assert.are.same(activation, plugin.activation_blob)
            assert.are.same(activation, plugin.settings:readSetting("activation"))
            assert.are.equal(original, readFile(settings_path))
            UIManager:close(message)

            showItem("Forget activation")
            press("Forget")
            message = UIManager:getTopmostVisibleWidget()
            assert.is_truthy(message.text:find("Could not forget activation", 1, true))
            assert.are.same(activation, plugin.activation_blob)
            assert.are.same(activation, plugin.settings:readSetting("activation"))
            assert.are.equal(original, readFile(settings_path))
            assert.are.same({}, directoryEntries(plugin.settings_file))
            plugin.settings_file = settings_path
        end)

        it("warns about private keys before choosing a folder and exports the selected filename", function()
            setActivation(copyActivation())
            local warning = showItem("Export activation to file")
            assert.is_truthy(warning.text:find("private activation keys", 1, true))
            press("Cancel")
            assert.is_nil(lfs.attributes(tmp .. "/acsm-activation.json"))

            showItem("Export activation to file")
            press("Choose folder")
            local chooser = UIManager:getTopmostVisibleWidget()
            assert.is_true(chooser.select_directory)
            assert.is_false(chooser.select_file)
            choosePath(chooser, tmp)
            local dialog = inputDialog()
            assert.are.equal("acsm-activation.json", dialog:getInputText())
            dialog:setInputText("my-activation.json")
            press("Export")
            assert.are.same(activation, assert(backup.read(tmp .. "/my-activation.json")))
            assert.are.same(activation, plugin.activation_blob)
        end)

        it("does not overwrite an existing export until Replace is pressed", function()
            setActivation(copyActivation())
            local path = tmp .. "/existing.json"
            writeFile(path, "keep these contents until confirmed")
            plugin:confirmExportActivation(path)
            fastforward_ui_events()
            assert.are.equal("keep these contents until confirmed", readFile(path))
            press("Cancel")
            assert.are.equal("keep these contents until confirmed", readFile(path))

            plugin:confirmExportActivation(path)
            fastforward_ui_events()
            press("Replace")
            assert.are.same(activation, assert(backup.read(path)))
        end)

        it("rejects folder separators and empty export filenames without creating files", function()
            setActivation(copyActivation())
            plugin:showExportActivationName(tmp)
            fastforward_ui_events()
            local dialog = inputDialog()
            local before = directoryEntries(tmp)
            for _, name in ipairs({ "", ".", "..", "../outside.json", "folder/backup.json", "folder\\backup.json" }) do
                dialog:setInputText(name)
                press("Export")
                local message = UIManager:getTopmostVisibleWidget()
                assert.is_truthy(message.text:find("Enter a filename", 1, true))
                assert.are.same(before, directoryEntries(tmp))
                UIManager:close(message)
                fastforward_ui_events()
            end
            press("Cancel")
        end)
    end)
end)
