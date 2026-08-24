--- End-to-end test: the entire Adobe Digital Editions sample library.
--- Runs activation -> fulfillment -> download -> decrypt for all 26 public
--- ACSM samples. Direct /store/ downloads are not ACSM and are excluded.
--- One anonymous activation is shared by all books, mirroring real
--- multi-book usage.
---
--- Catalog metadata can be stale: formats are asserted from the output's
--- magic bytes, not a declared format (e.g. Der Schimmelreiter is listed
--- as EPUB but ships as PDF).
---
--- Tagged #e2e — requires network access. Run selectively:
---   just test-e2e
---   just test-filter "sample library"
--- Expect ~80s and ~15 MB of downloads against Adobe's servers.

-- Public Adobe sample resource IDs, validated against the full library on
-- 2026-08-24. Keep this list self-contained: tests must not depend on the
-- intentionally untracked REFERENCE/ directory.
local SAMPLES = {
    {
        title = "20,000 Lieues Sous les Mers",
        uuid = "4541d3ee-c40b-49be-850a-41a4172a958f",
    },
    {
        title = "20.000 Mijlen onder zee",
        uuid = "9d185bc0-6a6c-4598-bdf5-7249552a2545",
    },
    {
        title = "Boule de Suif",
        uuid = "bb099fd5-0f50-4224-8c19-6f3c081b02a4",
    },
    {
        title = "Daisy Miller",
        uuid = "91797970-de30-4775-a139-7eb160a6688b",
    },
    {
        title = "Death and the Senator",
        uuid = "c0385b71-bcd6-44dd-9a69-ec8a931d25e2",
    },
    {
        title = "Der Prozeá",
        uuid = "61dfb84d-cc76-412a-9acd-a30d4f6ecdbc",
    },
    {
        title = "Der Schimmelreiter",
        uuid = "62dd32e3-6c1f-4841-a422-c40c2fd7f43f",
    },
    {
        title = "Die Leiden des jungen Werther",
        uuid = "818e9fcb-dfbe-4972-b41c-c5fcbf73735c",
    },
    {
        title = "Dracula",
        uuid = "98cdb717-fa80-407c-a076-b520eb149de8",
    },
    {
        title = "El ingenioso hidalgo Don Quijote de la Mancha",
        uuid = "39a50f6e-fb34-4c8e-82fd-7b38630604d4",
    },
    {
        title = "God Is A Salesman: Learn from the Master (Chapter 1)",
        uuid = "9cfb32c9-0976-4825-8a41-4512ab7c8c86",
    },
    {
        title = "Historia de la vida del Buscón",
        uuid = "7f133948-600c-40f8-9379-e82542fc8757",
    },
    {
        title = "Hot (Chapter 1)",
        uuid = "d6a4181d-1e69-461e-b1a3-480246fa91f0",
    },
    {
        title = "Isabella von Aegypten",
        uuid = "9a93a7eb-a594-4e39-ae4f-496973a182a0",
    },
    {
        title = "La Chartreuse de Parme",
        uuid = "c3e2a856-7235-40b6-9558-720e45d3cb68",
    },
    {
        title = "Les Diaboliques",
        uuid = "03a5b0ac-9676-45c0-8436-10cacef9d20d",
    },
    {
        title = "My Antonia",
        uuid = "c8cfc0c4-9805-4f1e-9c24-aee61753da6b",
    },
    {
        title = "The Adventures of Sherlock Holmes",
        uuid = "723caf6a-0e27-44be-8733-904cede39cd2",
    },
    {
        title = "The Father Thing",
        uuid = "cf432b4c-cd6e-4cf5-a3a5-95656d628f27",
    },
    {
        title = "The Goodbye Summer",
        uuid = "115ab68e-be42-42bb-99a9-d15168879e30",
    },
    {
        title = "The Princess Diaries",
        uuid = "85e0bf96-a8aa-4508-8acc-c5d40c3f21c8",
    },
    {
        title = "Thirteen Moons",
        uuid = "00bde5cc-7cdb-4799-af67-15a8c21c9dcf",
    },
    {
        title = "This Side of Paradise",
        uuid = "f3d9bc3e-e673-4c03-a091-0e7c8d26014e",
    },
    {
        title = "Tony Hillerman E-Reader – expires in 30 minutes",
        uuid = "2d3bea66-b956-454b-86a2-c46b4d4ab10b",
    },
    {
        title = "Trail of Crumbs: Hunger, Love, and the Search for Home (Chapter 1)",
        uuid = "d976a1af-582e-4fad-adb4-f08c878fc550",
    },
    {
        title = "Voyage autour de ma chambre",
        uuid = "941ab558-d4c1-4fc2-b6e1-cf39f2efb9ad",
    },
}

describe("Adobe sample library e2e #e2e", function()
    local http, ltn12, koutil, lfs, socketutil
    local creds, deviceUUID, fingerprint, authCert

    setup(function()
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
