--- End-to-end test: the ENTIRE Adobe sample library catalog.
--- Parses REFERENCE/test_books/adobe_sample.md and runs the full
--- activation -> fulfillment -> download -> decrypt pipeline for every
--- ACSM sample it lists (direct /store/ downloads are not ACSM and are
--- skipped). One anonymous activation is shared by all books, mirroring
--- real multi-book usage.
---
--- Catalog metadata can be stale: formats are asserted from the output's
--- magic bytes, not the catalog's claimed format (e.g. Der Schimmelreiter
--- is listed as EPUB but ships as PDF).
---
--- Tagged #e2e — requires network access. Run selectively:
---   just test-e2e
---   just test-filter "sample library"
--- Expect ~80s: 26 books, ~15 MB of downloads against Adobe's servers.

local plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"
local CATALOG = plugin_path .. "/REFERENCE/test_books/adobe_sample.md"

--- Extract (title, uuid) pairs from the catalog markdown.
--- Each sample appears twice (title link + "Download eBook" link); keep the
--- first occurrence per uuid. Sorted for deterministic test order.
local function parseCatalog(path)
    local f = io.open(path, "rb")
    assert(f, "cannot open sample catalog: " .. path)
    local body = f:read("*a")
    f:close()

    local samples, seen = {}, {}
    for title, uuid in body:gmatch("%[([^%]]+)%]%([^)]*URLLink%.acsm%?action=free&ordersource=operator&resid=urn%%3Auuid%%3A([%x%-]+)%)") do
        if not seen[uuid] and title ~= "Download eBook" then
            seen[uuid] = true
            samples[#samples + 1] = { title = title, uuid = uuid }
        end
    end
    table.sort(samples, function(a, b)
        return a.title < b.title
    end)
    return samples
end

local SAMPLES = parseCatalog(CATALOG)

describe("Adobe sample library e2e #e2e", function()
    local http, ltn12, koutil, lfs, socketutil
    local creds, deviceUUID, fingerprint, authCert

    setup(function()
        assert.is_true(#SAMPLES >= 20, "catalog parse looks wrong: " .. #SAMPLES .. " samples")
        print(string.format("[library-e2e] %d ACSM samples in catalog", #SAMPLES))

        http = require("socket.http")
        ltn12 = require("ltn12")
        koutil = require("util")
        lfs = require("libs/libkoreader-lfs")
        socketutil = require("socketutil")

        local adobe = require("adobe.adobe")

        print("[library-e2e] Activating anonymously (one activation, reused for all books)...")
        local auth_info = adobe.getAuthenticationServiceInfo()
        assert.is.truthy(auth_info.certificate, "Missing auth certificate")
        creds = adobe.signIn("anonymous", "", "", auth_info.certificate)
        assert.is.truthy(creds.user, "Sign-in failed: no user")
        deviceUUID, fingerprint = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12)
        assert.is.truthy(deviceUUID, "Activation failed")
        authCert = auth_info.certificate
        print("[library-e2e] Activation OK")
    end)

    local function downloadAcsm(uuid, path)
        socketutil:set_timeout(30, 120)
        local resp = {}
        local ok, code = http.request({
            url = "https://contentserver.adobe.com/fulfillment/URLLink.acsm" .. "?action=free&ordersource=operator&resid=urn%3Auuid%3A" .. uuid,
            sink = ltn12.sink.table(resp),
            headers = { ["User-Agent"] = socketutil.USER_AGENT },
            redirect = true,
        })
        socketutil:reset_timeout()
        assert.is.truthy(ok, "ACSM download failed: " .. tostring(code))
        local body = table.concat(resp)
        assert.is.truthy(body:find("fulfillmentToken"), "Response is not ACSM XML")
        koutil.writeToFile(body, path)
    end

    for _, sample in ipairs(SAMPLES) do
        it("fulfills + decrypts: " .. sample.title, function()
            local DataStorage = require("datastorage")
            local fulfillment = require("adobe.fulfillment")

            local tmpDir = DataStorage:getDataDir() .. "/test-library-e2e-" .. sample.uuid:sub(1, 8)
            koutil.makePath(tmpDir)
            finally(function()
                os.execute("rm -rf " .. tmpDir)
            end)

            local acsmPath = tmpDir .. "/sample.acsm"
            local outputPath = tmpDir .. "/decrypted.out"

            downloadAcsm(sample.uuid, acsmPath)

            local result, err = fulfillment.process(acsmPath, outputPath, creds, deviceUUID, fingerprint, authCert)
            assert.is.truthy(result, "Fulfillment failed: " .. tostring(err))
            assert.are.equal(outputPath, result.outputPath)
            assert.is_true(result.decryptedEntries > 0, "No entries were decrypted")

            local attr = lfs.attributes(outputPath)
            assert.is.truthy(attr, "Output file not found")
            assert.is_true(attr.size > 0, "Output file is empty")

            -- Format from magic bytes, not the catalog (its metadata is stale
            -- for at least one sample).
            local head = koutil.readFromFile(outputPath, "rb")
            assert.is.truthy(head)
            local magic
            if head:sub(1, 2) == "PK" then
                magic = "EPUB"
            elseif head:sub(1, 4) == "%PDF" then
                magic = "PDF"
            else
                error("Output has bad magic bytes: " .. head:sub(1, 5))
            end

            print(
                string.format(
                    "[library-e2e] OK: %-55s %s  %4d entries  %8d bytes",
                    sample.title:sub(1, 55),
                    magic,
                    result.decryptedEntries,
                    attr.size
                )
            )
        end)
    end
end)
