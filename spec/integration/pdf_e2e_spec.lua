--- End-to-end test: PDF fulfillment with real Adobe Content Server
-- Downloads a real PDF .acsm from Adobe's free sample library and runs
-- the full activation → fulfillment → download → decrypt pipeline.
--
-- Tagged #e2e — requires network access. Run selectively:
--   just test-e2e
--   just test-filter "PDF e2e"
--
-- Uses "Daisy Miller" by Henry James (Public Domain, 802 KB PDF):
-- https://contentserver.adobe.com/fulfillment/URLLink.acsm?action=free&ordersource=operator&resid=urn%3Auuid%3A91797970-de30-4775-a139-7eb160a6688b

describe("End-to-end PDF fulfillment #e2e", function()
    local http, ltn12, koutil, lfs

    setup(function()
        http = require("socket.http")
        ltn12 = require("ltn12")
        koutil = require("util")
        lfs = require("libs/libkoreader-lfs")
    end)

    -- Daisy Miller (Public Domain) — PDF, 802 KB
    local SAMPLE_PDF_ACSM_URL = "https://contentserver.adobe.com/fulfillment/URLLink.acsm"
        .. "?action=free&ordersource=operator"
        .. "&resid=urn%3Auuid%3A91797970-de30-4775-a139-7eb160a6688b"

    it("downloads a PDF .acsm file from Adobe sample library", function()
        local DataStorage = require("datastorage")
        local tmpDir = DataStorage:getDataDir() .. "/test-pdf-e2e-" .. tostring(os.time())
        koutil.makePath(tmpDir)
        local acsmPath = tmpDir .. "/sample_pdf.acsm"

        local socketutil = require("socketutil")
        socketutil:set_timeout(30, 60)
        local resp = {}
        local ok, code = http.request({
            url = SAMPLE_PDF_ACSM_URL,
            sink = ltn12.sink.table(resp),
            headers = { ["User-Agent"] = socketutil.USER_AGENT },
            redirect = true,
        })
        socketutil:reset_timeout()

        assert.is.truthy(ok, "HTTP request failed: " .. tostring(code))
        local body = table.concat(resp)
        assert.is_true(#body > 0, "Empty response body")
        assert.is.truthy(body:find("fulfillmentToken"), "Response doesn't look like ACSM XML")

        -- Check dc:format for PDF
        if body:find("application/pdf") then
            print("[pdf-e2e] ACSM confirms format: application/pdf")
        else
            print("[pdf-e2e] Warning: ACSM doesn't explicitly state application/pdf format")
        end

        koutil.writeToFile(body, acsmPath)
        os.execute("rm -rf " .. tmpDir)
    end)

    it("performs full activation + fulfillment + PDF decryption", function()
        local DataStorage = require("datastorage")
        local adobe = require("adobe.adobe")
        local fulfillment = require("adobe.fulfillment")

        local tmpDir = DataStorage:getDataDir() .. "/test-pdf-e2e-full-" .. tostring(os.time())
        koutil.makePath(tmpDir)
        local acsmPath = tmpDir .. "/daisy_miller.acsm"
        local outputPath = tmpDir .. "/daisy_miller.pdf"

        -- Step 1: Download ACSM
        print("[pdf-e2e] Downloading ACSM...")
        local socketutil = require("socketutil")
        socketutil:set_timeout(30, 60)
        local resp = {}
        local ok, code = http.request({
            url = SAMPLE_PDF_ACSM_URL,
            sink = ltn12.sink.table(resp),
            headers = { ["User-Agent"] = socketutil.USER_AGENT },
            redirect = true,
        })
        socketutil:reset_timeout()
        assert.is.truthy(ok, "Failed to download ACSM: " .. tostring(code))
        local acsmBody = table.concat(resp)
        koutil.writeToFile(acsmBody, acsmPath)
        print("[pdf-e2e] ACSM downloaded (" .. #acsmBody .. " bytes)")

        -- Step 2: Create anonymous activation
        print("[pdf-e2e] Activating device...")
        local auth_info = adobe.getAuthenticationServiceInfo()
        assert.is.truthy(auth_info.certificate, "Missing auth certificate")

        local creds = adobe.signIn("anonymous", "", "", auth_info.certificate)
        assert.is.truthy(creds.user, "Sign-in failed")

        local deviceUUID, fingerprint = adobe.activate(creds.user, creds.deviceKey, creds.pkcs12)
        assert.is.truthy(deviceUUID, "Activation failed")
        print("[pdf-e2e] Device activated: " .. tostring(deviceUUID))

        -- Step 3: Fulfill and decrypt
        print("[pdf-e2e] Processing fulfillment...")
        local result, err = fulfillment.process(acsmPath, outputPath, creds, deviceUUID, fingerprint, auth_info.certificate)

        -- If fulfillment fails, it might be because the PDF format
        -- is not fully supported yet. Report the error clearly.
        if not result then
            print("[pdf-e2e] Fulfillment failed: " .. tostring(err))
            -- Don't fail the test if it's a known limitation
            if err and (err:find("PDF") or err:find("EBX_HANDLER") or err:find("Not an ADEPT")) then
                print("[pdf-e2e] This appears to be a PDF decryption issue — expected if implementation is incomplete")
            end
            assert.is.truthy(result, "Fulfillment failed: " .. tostring(err))
        end

        assert.are.equal(outputPath, result.outputPath)
        print("[pdf-e2e] Fulfillment succeeded, output: " .. result.outputPath)

        -- Step 4: Verify the output PDF
        local attr = lfs.attributes(outputPath)
        assert.is.truthy(attr, "Output PDF not found at " .. outputPath)
        assert.is_true(attr.size > 0, "Output PDF is empty")

        -- Verify it's a valid PDF (starts with %PDF)
        local head = koutil.readFromFile(outputPath, "rb")
        assert.is.truthy(head)
        assert.are.equal("%PDF", head:sub(1, 4), "Output is not a valid PDF")

        -- Parse the output PDF structure to verify proper decryption
        local pdfdoc = require("adobe.pdf.pdfdoc")
        local outDoc = pdfdoc.PDFDocument:new()
        local parseOk, parseErr = outDoc:open(outputPath)
        assert.is.truthy(parseOk, "Output PDF failed to parse: " .. tostring(parseErr))

        -- Must have a valid Root (Catalog) object
        local trailer = outDoc:getCleanTrailer()
        assert.is.truthy(trailer.Root, "Output PDF missing /Root in trailer")

        -- Must have xrefs
        local objids = outDoc:allObjids()
        assert.is_true(#objids > 0, "Output PDF has no objects")

        -- The output should NOT have an /Encrypt dictionary
        assert.is.falsy(outDoc.encryption, "Output PDF still has /Encrypt dict — decryption didn't strip it")

        -- Load all objects and verify stream content is valid
        local loaded = 0
        local streams = 0
        local stream_decode_errors = 0
        local zlib_mod = require("adobe.util.zlib")
        for _, objid in ipairs(objids) do
            local obj = outDoc:getobj(objid)
            if obj then
                loaded = loaded + 1
                if type(obj) == "table" and obj.dic and obj.rawdata then
                    streams = streams + 1
                    -- Verify stream decryption produced valid content:
                    -- Decrypted streams should decompress without error
                    -- (or at minimum the raw data should be non-empty).
                    local decoded_ok, decdata = pcall(obj.get_decdata, obj)
                    if decoded_ok and decdata and #decdata > 0 then
                        -- If the stream has FlateDecode, verify it decompresses
                        local filter = obj.dic.Filter or obj.dic["filter"]
                        if filter and tostring(filter) == "FlateDecode" then
                            local inflater = zlib_mod.inflater()
                            local parts = {}
                            local decomp_ok, decomp_err = inflater:update(decdata, #decdata, function(ptr, len)
                                parts[#parts + 1] = require("ffi").string(ptr, len)
                            end)
                            inflater:close()
                            if not decomp_ok then
                                stream_decode_errors = stream_decode_errors + 1
                                print(string.format("[pdf-e2e] WARNING: stream %d failed to decompress: %s", objid, tostring(decomp_err)))
                            end
                        end
                    else
                        stream_decode_errors = stream_decode_errors + 1
                    end
                end
            end
        end
        assert.is_true(loaded > 3, "Output PDF has too few objects: " .. loaded)
        assert.is_true(streams > 0, "Output PDF has no stream objects")
        -- CRITICAL: no stream should fail to decrypt/decompress
        if stream_decode_errors > 0 then
            error(string.format("Output PDF has %d streams that failed decryption/decompression", stream_decode_errors))
        end

        print(string.format("[pdf-e2e] Success! Output PDF: %d bytes, %d objects (%d streams, 0 corrupt)", attr.size, loaded, streams))

        outDoc:close()
        os.execute("rm -rf " .. tmpDir)
    end)
end)
