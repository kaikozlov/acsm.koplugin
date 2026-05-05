--- Integration tests: end-to-end with real Adobe Content Server
-- Downloads a real .acsm from Adobe's free sample library and runs
-- the full activation → fulfillment → download → decrypt pipeline.
--
-- Tagged #e2e — requires network access. Run selectively:
--   make docker-busted ARGS="--filter=e2e ..."
--
-- Uses Adobe's smallest free EPUB sample: "God Is A Salesman" (100 Kb)
-- to minimize download time in CI.

describe("End-to-end fulfillment #e2e", function()
    local http, socket, ltn12, koutil, lfs

    setup(function()
        http = require("socket.http")
        socket = require("socket")
        ltn12 = require("ltn12")
        koutil = require("util")
        lfs = require("libs/libkoreader-lfs")
    end)

    -- Adobe's free sample ACSM endpoints (these return .acsm XML directly)
    local SAMPLE_ACSM_URL = "https://contentserver.adobe.com/fulfillment/URLLink.acsm"
        .. "?action=free&ordersource=operator"
        .. "&resid=urn%3Auuid%3A9cfb32c9-0976-4825-8a41-4512ab7c8c86"
    -- "God Is A Salesman (Chapter 1)" — smallest EPUB at 100 Kb

    it("downloads a real .acsm file from Adobe", function()
        local DataStorage = require("datastorage")
        local tmpDir = DataStorage:getDataDir() .. "/test-e2e-" .. tostring(os.time())
        koutil.makePath(tmpDir)
        local acsmPath = tmpDir .. "/sample.acsm"

        -- Download the ACSM
        local socketutil = require("socketutil")
        socketutil:set_timeout(30, 60)
        local resp = {}
        local ok, code = http.request{
            url = SAMPLE_ACSM_URL,
            sink = ltn12.sink.table(resp),
            headers = { ["User-Agent"] = socketutil.USER_AGENT },
            redirect = true,
        }
        socketutil:reset_timeout()

        assert.is.truthy(ok, "HTTP request failed: " .. tostring(code))
        local body = table.concat(resp)
        assert.is_true(#body > 0, "Empty response body")

        -- Write to file
        koutil.writeToFile(body, acsmPath)

        -- Verify it's valid ACSM XML
        assert.is.truthy(body:find("fulfillmentToken"), "Response doesn't look like ACSM XML")

        -- Parse metadata from the ACSM
        local xml = require("adobe.util.xml")
        local parsed = xml.deserialize(body)
        assert.is.truthy(parsed, "Failed to parse ACSM XML")
        assert.is.truthy(parsed.fulfillmentToken, "No fulfillmentToken in ACSM")
        assert.is.truthy(parsed.fulfillmentToken.operatorURL, "No operatorURL in ACSM")

        os.execute("rm -rf " .. tmpDir)
    end)

    it("performs full activation + fulfillment + decryption", function()
        local DataStorage = require("datastorage")
        local adobe = require("adobe.adobe")
        local fulfillment = require("adobe.fulfillment")
        local epub = require("adobe.epub")

        local tmpDir = DataStorage:getDataDir() .. "/test-e2e-full-" .. tostring(os.time())
        koutil.makePath(tmpDir)
        local acsmPath = tmpDir .. "/sample.acsm"
        local outputPath = tmpDir .. "/decrypted.epub"

        -- Step 1: Download ACSM
        local socketutil = require("socketutil")
        socketutil:set_timeout(30, 60)
        local resp = {}
        local ok, code = http.request{
            url = SAMPLE_ACSM_URL,
            sink = ltn12.sink.table(resp),
            headers = { ["User-Agent"] = socketutil.USER_AGENT },
            redirect = true,
        }
        socketutil:reset_timeout()
        assert.is.truthy(ok, "Failed to download ACSM: " .. tostring(code))
        koutil.writeToFile(table.concat(resp), acsmPath)

        -- Step 2: Create anonymous activation
        print("[e2e] Getting authentication service info...")
        local auth_info = adobe.getAuthenticationServiceInfo()
        assert.is.truthy(auth_info.certificate, "Missing auth certificate")

        print("[e2e] Signing in anonymously...")
        local creds = adobe.signIn("anonymous", "", "", auth_info.certificate)
        assert.is.truthy(creds.user, "Sign-in failed: no user")
        assert.is.truthy(creds.deviceKey, "Sign-in failed: no device key")

        print("[e2e] Activating device...")
        local deviceUUID, fingerprint = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12)
        assert.is.truthy(deviceUUID, "Activation failed")
        assert.is.truthy(fingerprint, "No fingerprint")

        -- Step 3: Fulfill the loan
        print("[e2e] Processing fulfillment...")
        local result, err = fulfillment.process(
            acsmPath, outputPath,
            creds, deviceUUID, fingerprint,
            auth_info.certificate)
        assert.is.truthy(result, "Fulfillment failed: " .. tostring(err))
        assert.are.equal(outputPath, result.outputPath)
        assert.is_true(result.decryptedEntries > 0, "No entries were decrypted")

        -- Step 4: Verify the output EPUB
        local attr = lfs.attributes(outputPath)
        assert.is.truthy(attr, "Output EPUB not found")
        assert.is_true(attr.size > 0, "Output EPUB is empty")

        -- Verify it's a valid EPUB (starts with PK zip signature)
        local head = koutil.readFromFile(outputPath, "rb")
        assert.is.truthy(head)
        assert.are.equal("PK", head:sub(1, 2), "Output is not a valid ZIP/EPUB")

        print(string.format("[e2e] Success! Decrypted %d entries, output: %d bytes",
            result.decryptedEntries, attr.size))

        os.execute("rm -rf " .. tmpDir)
    end)
end)
