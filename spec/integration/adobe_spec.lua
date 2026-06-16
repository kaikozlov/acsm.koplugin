--- Integration tests: adobe/adobe.lua (isolated, no network)
-- Tests serializeActivation, restoreActivation, and targetDevice
-- using real KOReader crypto — no mocking needed.

describe("adobe", function()
    local adobe, crypto, util

    setup(function()
        adobe = require("adobe.adobe")
        crypto = require("adobe.util.crypto")
        util = require("adobe.util.util")
    end)

    -- ================================================================
    -- serializeActivation
    -- ================================================================
    describe("serializeActivation", function()
        it("serializes all credential fields", function()
            local deviceKey = crypto.deviceKey.new()
            local licenseKey = crypto.key.new()
            local creds = {
                deviceKey = deviceKey,
                licenseKey = licenseKey,
                licenseCert = "test-license-cert",
                user = "urn:uuid:test-user",
                username = "testuser@example.com",
                pkcs12 = "test-pkcs12-blob",
            }

            local result = adobe.serializeActivation(creds, "device-uuid-123", "fingerprint-abc", "auth-cert-xyz")

            assert.are.equal("test-license-cert", result.licenseCert)
            assert.are.equal("urn:uuid:test-user", result.user)
            assert.are.equal("testuser@example.com", result.username)
            assert.are.equal("test-pkcs12-blob", result.pkcs12)
            assert.are.equal("device-uuid-123", result.deviceUUID)
            assert.are.equal("fingerprint-abc", result.fingerprint)
            assert.are.equal("auth-cert-xyz", result.authCert)

            -- Keys should be base64-encoded strings
            assert.is.truthy(type(result.deviceKey) == "string")
            assert.is.truthy(type(result.privateLicenseKey) == "string")
            -- Verify they're valid base64 by round-tripping
            assert.is.truthy(util.base64.decode(result.deviceKey))
            assert.is.truthy(util.base64.decode(result.privateLicenseKey))
        end)

        it("uses default activation URL when none provided", function()
            local creds = {
                deviceKey = crypto.deviceKey.new(),
                licenseKey = crypto.key.new(),
                licenseCert = "cert",
                user = "user",
                username = "user",
                pkcs12 = "pk",
            }
            local result = adobe.serializeActivation(creds, "dev", "fp", "ac")
            assert.are.equal("https://adeactivate.adobe.com/adept", result.activationURL)
        end)

        it("uses explicit activation URL when provided", function()
            local creds = {
                deviceKey = crypto.deviceKey.new(),
                licenseKey = crypto.key.new(),
                licenseCert = "cert",
                user = "user",
                username = "user",
                pkcs12 = "pk",
            }
            local customURL = "https://custom.example.com/adept"
            local result = adobe.serializeActivation(creds, "dev", "fp", "ac", customURL)
            assert.are.equal(customURL, result.activationURL)
        end)
    end)

    -- ================================================================
    -- restoreActivation
    -- ================================================================
    describe("restoreActivation", function()
        it("round-trips through serialize → restore", function()
            local deviceKey = crypto.deviceKey.new()
            local licenseKey = crypto.key.new()
            local creds = {
                deviceKey = deviceKey,
                licenseKey = licenseKey,
                licenseCert = "test-cert",
                user = "urn:uuid:round-trip-user",
                username = "roundtrip@test.com",
                pkcs12 = "roundtrip-pkcs12",
            }

            local serialized = adobe.serializeActivation(creds, "dev-uuid", "fp-hash", "auth-cert", "https://example.com/adept")
            local restored = adobe.restoreActivation(serialized)

            assert.is.truthy(restored)
            assert.are.equal("urn:uuid:round-trip-user", restored.creds.user)
            assert.are.equal("roundtrip@test.com", restored.creds.username)
            assert.are.equal("roundtrip-pkcs12", restored.creds.pkcs12)
            assert.are.equal("test-cert", restored.creds.licenseCert)
            assert.are.equal("dev-uuid", restored.deviceUUID)
            assert.are.equal("fp-hash", restored.fingerprint)
            assert.are.equal("auth-cert", restored.authCert)

            -- Verify the restored license key can export to the same PKCS8
            local originalPkcs8 = licenseKey:topkcs8()
            local restoredPkcs8 = restored.creds.licenseKey:topkcs8()
            assert.are.equal(originalPkcs8, restoredPkcs8)
        end)

        it("returns nil + error for nil input", function()
            local result, err = adobe.restoreActivation(nil)
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("missing"), "Error should mention missing: " .. err)
        end)

        it("returns nil + error for non-table input", function()
            local result, err = adobe.restoreActivation("not a table")
            assert.is_nil(result)
            assert.is.truthy(err)
        end)

        it("returns nil + error for incomplete table", function()
            local result, err = adobe.restoreActivation({
                deviceKey = "key",
                -- missing privateLicenseKey, user, pkcs12, deviceUUID, fingerprint
            })
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("incomplete"), "Error should mention incomplete: " .. err)
        end)

        it("restores activationURL from serialized data", function()
            local deviceKey = crypto.deviceKey.new()
            local licenseKey = crypto.key.new()
            local creds = {
                deviceKey = deviceKey,
                licenseKey = licenseKey,
                licenseCert = "cert",
                user = "user",
                username = "user",
                pkcs12 = "pk",
            }
            local serialized = adobe.serializeActivation(creds, "dev", "fp", "ac", "https://custom.url/adept")
            local restored = adobe.restoreActivation(serialized)
            assert.are.equal("https://custom.url/adept", restored.creds.activationURL)
        end)
    end)

    -- ================================================================
    -- targetDevice
    -- ================================================================
    describe("targetDevice", function()
        it("returns correct structure with VERSION fields", function()
            local result = adobe.targetDevice("my-fingerprint")
            assert.are.equal(adobe.VERSION.hobbes, result.softwareVersion)
            assert.are.equal(adobe.VERSION.os, result.clientOS)
            assert.are.equal("en", result.clientLocale)
            assert.are.equal(adobe.VERSION.version, result.clientVersion)
            assert.are.equal("standalone", result.deviceType)
            assert.are.equal("Adobe Digitial Editions", result.productName)
            assert.are.equal("my-fingerprint", result.fingerprint)
        end)

        it("includes activationToken when provided", function()
            local token = { user = "user-1", device = "device-1" }
            local result = adobe.targetDevice("fp", token)
            assert.are.same(token, result.activationToken)
        end)
    end)
end)
