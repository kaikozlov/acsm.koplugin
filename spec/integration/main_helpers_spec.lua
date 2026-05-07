--- Integration tests: main.lua helpers, activation lifecycle,
--- fulfillment mapping, and orchestration methods.
-- Uses dofile() pattern (same as main_spec) to load a fresh ACSM table.
-- Temp directories are used for settings/cache isolation.

describe("main.lua helpers & orchestration", function()
    local koutil, DataStorage, ffiUtil, LuaSettings, lfs
    local plugin_path

    setup(function()
        koutil = require("util")
        DataStorage = require("datastorage")
        ffiUtil = require("ffi/util")
        LuaSettings = require("luasettings")
        lfs = require("libs/libkoreader-lfs")
        plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"
    end)

    --- Load a fresh copy of main.lua.
    local function loadFresh()
        package.loaded[plugin_path .. "/main.lua"] = nil
        return dofile(plugin_path .. "/main.lua")
    end

    --- Create an isolated temp dir with settings/ and cache/ subdirs.
    -- Returns the tmp dir path.
    local function makeTmpDir(tag)
        local base = _G.TEST_DATA_DIR
            or os.getenv("TEST_DATA_DIR")
            or "/tmp/koreader-test-data"
        local tmp = base .. "/acsm-main-test-" .. tag .. "-"
            .. tostring(os.time()) .. "-" .. math.random(100000, 999999)
        koutil.makePath(tmp .. "/settings")
        koutil.makePath(tmp .. "/cache/acsm.koplugin")
        return tmp
    end

    local function rmTmpDir(tmp)
        ffiUtil.purgeDir(tmp)
    end

    --- Load a fresh plugin with settings/cache pointed at tmp.
    local function loadInTmpDir(tag)
        local tmp = makeTmpDir(tag)
        local main = loadFresh()
        main.settings_file = tmp .. "/settings/acsm.lua"
        return main, tmp
    end

    -- ================================================================
    -- isActivationError (exported as ACSM._isActivationError)
    -- ================================================================
    describe("_isActivationError", function()
        local ACSM

        before_each(function()
            ACSM = loadFresh()
        end)

        it("matches E_ADEPT_USER_AUTH", function()
            assert.is.truthy(ACSM._isActivationError(
                "E_ADEPT_USER_AUTH something went wrong"))
        end)

        it("matches E_ADEPT_DISTRIBUTOR_AUTH", function()
            assert.is.truthy(ACSM._isActivationError(
                "E_ADEPT_DISTRIBUTOR_AUTH expired token"))
        end)

        it("matches generic E_ADEPT error", function()
            assert.is.truthy(ACSM._isActivationError(
                "E_ADEPT unknown device"))
        end)

        it("returns falsy for non-activation error strings", function()
            assert.is_nil(ACSM._isActivationError("network timeout"))
            assert.is_nil(ACSM._isActivationError("file not found"))
        end)

        it("returns false for nil", function()
            assert.is_false(ACSM._isActivationError(nil))
        end)

        it("returns false for non-string types", function()
            assert.is_false(ACSM._isActivationError(42))
            assert.is_false(ACSM._isActivationError({}))
        end)
    end)

    -- ================================================================
    -- trimError (exported as ACSM._trimError)
    -- ================================================================
    describe("_trimError", function()
        local ACSM

        before_each(function()
            ACSM = loadFresh()
        end)

        it("strips leading 'module: ' prefix", function()
            assert.are.equal("something failed",
                ACSM._trimError("adobe.lua: something failed"))
        end)

        it("strips only the first prefix", function()
            assert.are.equal("foo: bar",
                ACSM._trimError("module: foo: bar"))
        end)

        it("returns unchanged string when no prefix", function()
            assert.are.equal("plain error",
                ACSM._trimError("plain error"))
        end)

        it("converts nil to string 'nil'", function()
            assert.are.equal("nil", ACSM._trimError(nil))
        end)

        it("converts number to string", function()
            assert.are.equal("42", ACSM._trimError(42))
        end)

        it("converts table via tostring", function()
            local t = { "a" }
            local result = ACSM._trimError(t)
            assert.are.equal(tostring(t), result)
        end)

        it("handles empty string", function()
            assert.are.equal("", ACSM._trimError(""))
        end)
    end)

    -- ================================================================
    -- clearActivation
    -- ================================================================
    describe("clearActivation", function()
        it("nullifies activation_blob in memory", function()
            local main, tmp = loadInTmpDir("clear-act")
            main:loadSettings()
            main.activation_blob = { deviceKey = "test-key" }
            main:saveSettings()
            assert.is.truthy(main.activation_blob)

            main:clearActivation()

            assert.is_nil(main.activation_blob)
            rmTmpDir(tmp)
        end)

        it("persists nil activation to settings file", function()
            local main, tmp = loadInTmpDir("clear-persist")
            main:loadSettings()
            main.activation_blob = { deviceKey = "test-key" }
            main:saveSettings()

            main:clearActivation()

            -- Reload settings from disk to verify persistence
            local disk = LuaSettings:open(main.settings_file)
            assert.is_nil(disk:readSetting("activation"))
            rmTmpDir(tmp)
        end)
    end)

    -- ================================================================
    -- restoreActivation
    -- ================================================================
    describe("restoreActivation", function()
        it("returns nil with message when no saved activation", function()
            local main, tmp = loadInTmpDir("restore-none")
            main:loadSettings()
            -- No activation_blob set
            local result, err = main:restoreActivation()
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("No saved activation"))
            rmTmpDir(tmp)
        end)

        it("restores activation from valid serialized data", function()
            local main, tmp = loadInTmpDir("restore-valid")

            -- Build a valid serialized activation blob using real crypto
            local crypto = require("adobe.util.crypto")
            local base64 = require("adobe.util.util").base64

            local deviceKey = crypto.deviceKey.new()
            local licenseKey = crypto.key.new()
            local authKey = crypto.key.new()

            -- Build a minimal pkcs12 that decodepkcs12 can handle.
            -- For restoreActivation we just need the blob to contain
            -- the right fields so adobe.restoreActivation can reconstruct.
            local serialized = {
                deviceKey = base64.encode(deviceKey.key),
                privateLicenseKey = base64.encode(licenseKey:topkcs8()),
                licenseCert = "dummy-cert",
                user = "urn:uuid:test-user",
                username = "testuser",
                pkcs12 = authKey:topkcs8(),  -- not valid pkcs12 but structurally present
                deviceUUID = "urn:uuid:test-device",
                fingerprint = "test-fp",
                authCert = "dummy-auth-cert",
                activationURL = "https://adeactivate.adobe.com/adept",
            }

            main:loadSettings()
            main.activation_blob = serialized
            main:saveSettings()

            local result, err = main:restoreActivation()
            assert.is.truthy(result, "restoreActivation failed: " .. tostring(err))
            assert.is.truthy(result.creds)
            assert.are.equal("urn:uuid:test-device", result.deviceUUID)
            assert.are.equal("test-fp", result.fingerprint)

            rmTmpDir(tmp)
        end)

        it("returns nil for incomplete serialized data", function()
            local main, tmp = loadInTmpDir("restore-incomplete")
            main:loadSettings()
            main.activation_blob = { deviceKey = "only-key" }  -- missing fields
            main:saveSettings()

            local result, err = main:restoreActivation()
            assert.is_nil(result)
            assert.is.truthy(err)

            rmTmpDir(tmp)
        end)

        it("clears activation when restore fails with corrupt data", function()
            local main, tmp = loadInTmpDir("restore-corrupt")
            main:loadSettings()
            main.activation_blob = { deviceKey = "bad" }  -- incomplete
            main:saveSettings()

            local result, err = main:restoreActivation()
            assert.is_nil(result)

            -- restoreActivation calls clearActivation on failure
            assert.is_nil(main.activation_blob)

            rmTmpDir(tmp)
        end)
    end)

    -- ================================================================
    -- createActivation (error paths only — stubs network modules)
    -- ================================================================
    describe("createActivation", function()
        it("errors when network is unavailable", function()
            local main, tmp = loadInTmpDir("create-no-net")
            main:loadSettings()

            -- Stub adobe.getAuthenticationServiceInfo to error
            local adobe = require("adobe.adobe")
            local orig = adobe.getAuthenticationServiceInfo
            adobe.getAuthenticationServiceInfo = function()
                error("network unreachable")
            end

            local ok, err = pcall(function() main:createActivation() end)
            assert.is_false(ok)
            assert.is.truthy(tostring(err):find("network unreachable"))

            adobe.getAuthenticationServiceInfo = orig
            rmTmpDir(tmp)
        end)
    end)

    -- ================================================================
    -- getActivation
    -- ================================================================
    describe("getActivation", function()
        it("returns existing activation when restore succeeds", function()
            local main, tmp = loadInTmpDir("get-existing")

            -- Build a valid activation blob
            local crypto = require("adobe.util.crypto")
            local base64 = require("adobe.util.util").base64
            local deviceKey = crypto.deviceKey.new()
            local licenseKey = crypto.key.new()

            main:loadSettings()
            main.activation_blob = {
                deviceKey = base64.encode(deviceKey.key),
                privateLicenseKey = base64.encode(licenseKey:topkcs8()),
                licenseCert = "cert",
                user = "urn:uuid:user",
                username = "user",
                pkcs12 = licenseKey:topkcs8(),
                deviceUUID = "urn:uuid:dev",
                fingerprint = "fp",
                authCert = "ac",
                activationURL = "https://adeactivate.adobe.com/adept",
            }
            main:saveSettings()

            local activation, reused = main:getActivation(false)
            assert.is.truthy(activation)
            assert.is_true(reused, "should have reused existing activation")

            rmTmpDir(tmp)
        end)

        it("calls createActivation when force_new is true", function()
            local main, tmp = loadInTmpDir("get-force")
            main:loadSettings()

            -- Track whether createActivation was called
            local create_called = false
            local fake_activation = {
                creds = { user = "test" },
                deviceUUID = "uuid",
                fingerprint = "fp",
                authCert = "cert",
            }
            main.createActivation = function(self)
                create_called = true
                return fake_activation
            end

            local activation, reused = main:getActivation(true)
            assert.is_true(create_called)
            assert.is_false(reused)
            assert.are.equal(fake_activation, activation)

            rmTmpDir(tmp)
        end)

        it("calls createActivation when no saved activation exists", function()
            local main, tmp = loadInTmpDir("get-nosaved")
            main:loadSettings()

            local create_called = false
            local fake_activation = {
                creds = { user = "test" },
                deviceUUID = "uuid",
                fingerprint = "fp",
                authCert = "cert",
            }
            main.createActivation = function(self)
                create_called = true
                return fake_activation
            end

            local activation, reused = main:getActivation(false)
            assert.is_true(create_called)
            assert.is_false(reused)

            rmTmpDir(tmp)
        end)
    end)

    -- ================================================================
    -- Fulfillment mapping
    -- ================================================================
    describe("getFulfillmentMapPath", function()
        it("returns path ending in fulfillment_map.lua", function()
            local main = loadFresh()
            local path = main:getFulfillmentMapPath()
            assert.is.truthy(path:find("fulfillment_map%.lua$"))
        end)

        it("contains cache/acsm.koplugin in path", function()
            local main = loadFresh()
            local path = main:getFulfillmentMapPath()
            assert.is.truthy(path:find("cache/acsm%.koplugin"))
        end)
    end)

    describe("saveFulfillmentMapping + lookupFulfillmentMapping", function()
        it("round-trips a resource ID to output path", function()
            local main, tmp = loadInTmpDir("map-roundtrip")

            -- Point DataStorage at our tmp dir for the cache path
            local orig_getDataDir = DataStorage.getDataDir
            DataStorage.getDataDir = function() return tmp end

            main:saveFulfillmentMapping("urn:uuid:test-resource", "/books/my-book.epub")

            local path = main:lookupFulfillmentMapping("urn:uuid:test-resource")
            assert.are.equal("/books/my-book.epub", path)

            DataStorage.getDataDir = orig_getDataDir
            rmTmpDir(tmp)
        end)

        it("returns nil for unknown resource ID", function()
            local main, tmp = loadInTmpDir("map-miss")

            local orig_getDataDir = DataStorage.getDataDir
            DataStorage.getDataDir = function() return tmp end

            local path = main:lookupFulfillmentMapping("urn:uuid:nonexistent")
            assert.is_nil(path)

            DataStorage.getDataDir = orig_getDataDir
            rmTmpDir(tmp)
        end)

        it("persists mapping to disk", function()
            local main, tmp = loadInTmpDir("map-persist")

            local orig_getDataDir = DataStorage.getDataDir
            DataStorage.getDataDir = function() return tmp end

            main:saveFulfillmentMapping("urn:uuid:persist-test", "/books/persisted.epub")

            -- Load a fresh instance and verify the mapping is on disk
            local main2 = loadFresh()
            main2.settings_file = tmp .. "/settings/acsm.lua"
            local path = main2:lookupFulfillmentMapping("urn:uuid:persist-test")
            assert.are.equal("/books/persisted.epub", path)

            DataStorage.getDataDir = orig_getDataDir
            rmTmpDir(tmp)
        end)

        it("handles nil resource_id gracefully", function()
            local main, tmp = loadInTmpDir("map-nil")

            local orig_getDataDir = DataStorage.getDataDir
            DataStorage.getDataDir = function() return tmp end

            local path = main:lookupFulfillmentMapping(nil)
            assert.is_nil(path)

            DataStorage.getDataDir = orig_getDataDir
            rmTmpDir(tmp)
        end)

        it("overwrites existing mapping", function()
            local main, tmp = loadInTmpDir("map-overwrite")

            local orig_getDataDir = DataStorage.getDataDir
            DataStorage.getDataDir = function() return tmp end

            main:saveFulfillmentMapping("urn:uuid:overwrite", "/books/old.epub")
            main:saveFulfillmentMapping("urn:uuid:overwrite", "/books/new.epub")

            local path = main:lookupFulfillmentMapping("urn:uuid:overwrite")
            assert.are.equal("/books/new.epub", path)

            DataStorage.getDataDir = orig_getDataDir
            rmTmpDir(tmp)
        end)
    end)

    -- ================================================================
    -- fulfillLoan (stubbed network)
    -- ================================================================
    describe("fulfillLoan", function()
        it("errors when getActivation returns nil", function()
            local main, tmp = loadInTmpDir("fulfill-no-act")
            main:loadSettings()

            -- Stub getActivation to return nil
            main.getActivation = function(self, force_new)
                return nil, "No activation"
            end

            -- fulfillLoan will error trying to index nil activation
            local ok, err = pcall(function()
                main:fulfillLoan("/test/book.acsm", {
                    title = "Test Book",
                    resourceId = "urn:uuid:test",
                })
            end)
            assert.is_false(ok)
            assert.is.truthy(tostring(err):find("nil value"))

            rmTmpDir(tmp)
        end)

        it("returns error when fulfillment.process fails", function()
            local main, tmp = loadInTmpDir("fulfill-fail")
            main:loadSettings()

            -- Stub getActivation to return fake activation
            main.getActivation = function(self, force_new)
                return {
                    creds = { user = "test" },
                    deviceUUID = "uuid",
                    fingerprint = "fp",
                    authCert = "cert",
                }, false
            end

            -- Stub fulfillment.process to fail
            local fulfillment = require("adobe.fulfillment")
            local orig_process = fulfillment.process
            fulfillment.process = function()
                return nil, "fulfillment server error"
            end

            local result, err = main:fulfillLoan("/test/book.acsm", {
                title = "Test Book",
                resourceId = "urn:uuid:test",
            })
            assert.is_nil(result)
            assert.is.truthy(err)

            fulfillment.process = orig_process
            rmTmpDir(tmp)
        end)

        it("retries with new activation on E_ADEPT error", function()
            local main, tmp = loadInTmpDir("fulfill-retry")
            main:loadSettings()

            local call_count = 0
            -- First call returns fake activation (reused), second gets new
            main.getActivation = function(self, force_new)
                if not force_new then
                    return {
                        creds = { user = "test" },
                        deviceUUID = "uuid",
                        fingerprint = "fp",
                        authCert = "cert",
                    }, true  -- reused
                else
                    return {
                        creds = { user = "test2" },
                        deviceUUID = "uuid2",
                        fingerprint = "fp2",
                        authCert = "cert2",
                    }, false
                end
            end

            -- Stub createActivation for the retry path
            main.createActivation = function(self)
                return {
                    creds = { user = "test2" },
                    deviceUUID = "uuid2",
                    fingerprint = "fp2",
                    authCert = "cert2",
                }
            end

            local fulfillment = require("adobe.fulfillment")
            local orig_process = fulfillment.process
            fulfillment.process = function()
                call_count = call_count + 1
                if call_count == 1 then
                    return nil, "E_ADEPT_USER_AUTH expired"
                end
                return { outputPath = "/test/book.epub" }
            end

            local result, err = main:fulfillLoan("/test/book.acsm", {
                title = "Test Book",
                resourceId = "urn:uuid:test",
            })
            assert.is.truthy(result)
            assert.are.equal(2, call_count)

            fulfillment.process = orig_process
            rmTmpDir(tmp)
        end)

        it("saves fulfillment mapping on success", function()
            local main, tmp = loadInTmpDir("fulfill-map")
            main:loadSettings()

            main.getActivation = function(self, force_new)
                return {
                    creds = { user = "test" },
                    deviceUUID = "uuid",
                    fingerprint = "fp",
                    authCert = "cert",
                }, false
            end

            local fulfillment = require("adobe.fulfillment")
            local orig_process = fulfillment.process
            fulfillment.process = function()
                return { outputPath = "/test/book.epub" }
            end

            local result = main:fulfillLoan("/test/book.acsm", {
                title = "Test Book",
                resourceId = "urn:uuid:mapped-resource",
            })
            assert.is.truthy(result)

            -- Verify mapping was saved (via in-memory cache)
            local mapped = main:lookupFulfillmentMapping("urn:uuid:mapped-resource")
            assert.is.truthy(mapped)

            fulfillment.process = orig_process
            rmTmpDir(tmp)
        end)

        it("does not retry non-activation errors", function()
            local main, tmp = loadInTmpDir("fulfill-no-retry")
            main:loadSettings()

            local call_count = 0
            main.getActivation = function(self, force_new)
                return {
                    creds = { user = "test" },
                    deviceUUID = "uuid",
                    fingerprint = "fp",
                    authCert = "cert",
                }, true  -- reused so retry path is eligible
            end

            main.createActivation = function(self)
                call_count = call_count + 100  -- should NOT be called
                return {
                    creds = { user = "test2" },
                    deviceUUID = "uuid2",
                    fingerprint = "fp2",
                    authCert = "cert2",
                }
            end

            local fulfillment = require("adobe.fulfillment")
            local orig_process = fulfillment.process
            fulfillment.process = function()
                call_count = call_count + 1
                return nil, "network timeout"
            end

            local result, err = main:fulfillLoan("/test/book.acsm", {
                title = "Test Book",
                resourceId = "urn:uuid:test",
            })
            assert.is_nil(result)
            assert.are.equal(1, call_count)  -- createActivation not called (no +100)

            fulfillment.process = orig_process
            rmTmpDir(tmp)
        end)
    end)

    -- ================================================================
    -- openFile
    -- ================================================================
    describe("openFile", function()
        it("is a no-op for non-acsm files", function()
            local main, tmp = loadInTmpDir("openfile-noacsm")
            main:loadSettings()

            -- Should not error, should not attempt fulfillment
            local ok, err = pcall(function()
                main:openFile("/books/book.epub")
            end)
            assert.is_true(ok, "openFile threw: " .. tostring(err))

            rmTmpDir(tmp)
        end)

        it("is a no-op for files with wrong extension", function()
            local main, tmp = loadInTmpDir("openfile-wrongext")
            main:loadSettings()

            local ok, err = pcall(function()
                main:openFile("/books/document.pdf")
            end)
            assert.is_true(ok)

            rmTmpDir(tmp)
        end)

        it("handles isFileTypeSupported correctly", function()
            local main = loadFresh()
            assert.is_true(main:isFileTypeSupported("test.acsm"))
            assert.is_true(main:isFileTypeSupported("TEST.ACSM"))
            assert.is_false(main:isFileTypeSupported("test.epub"))
            assert.is_false(main:isFileTypeSupported("test.pdf"))
        end)
    end)
end)
