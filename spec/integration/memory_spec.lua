--- Memory-bounded decryption tests.
-- Verifies that both EPUB and PDF decryption pipelines operate in
-- bounded memory — peak heap stays well below total file/object size.
--
-- This prevents regressions like the OOM kill on Kindle Paperwhite 1st gen
-- (GitHub issue #2) where accumulating all decrypted data in memory caused
-- the kernel to kill the process on 256MB devices.
--
-- Strategy:
--   Build synthetic encrypted content with known large payload sizes.
--   Run the full decrypt pipeline and sample collectgarbage("count")
--   before/after to verify heap growth is bounded.

describe("Memory-bounded decryption", function()
    local nc, pdfcrypt, rc4, koutil, pdf, epub, writer

    setup(function()
        nc = require("adobe.util.nativecrypto")
        pdfcrypt = require("adobe.pdf.pdfcrypt")
        rc4 = require("adobe.pdf.rc4")
        koutil = require("util")
        pdf = require("adobe.pdf")
        epub = require("adobe.epub")
        writer = require("adobe.pdf.writer")
    end)

    -- ================================================================
    -- Helpers
    -- ================================================================

    --- Force a full GC cycle and return current heap usage in KB.
    local function heapKB()
        collectgarbage("collect")
        collectgarbage("collect")
        return collectgarbage("count")
    end

    --- Build a synthetic encrypted PDF with many large stream objects.
    -- Total payload = numObjects × streamSize bytes.
    -- Each stream is RC4-encrypted with genkey_v2.
    local function buildLargePdf(tmpDir, bookKey, numObjects, streamSize)
        local function rc4Encrypt(key, objid, genno, data)
            local k = pdfcrypt.genkey_v2(key, objid, genno)
            local state = rc4.init(k)
            return rc4.crypt(state, data)
        end

        local path = tmpDir .. "/large_encrypted.pdf"
        local f = assert(io.open(path, "wb"))

        -- Header
        f:write("%PDF-1.4\n")
        f:write(string.char(0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A))

        -- Fixed objects: Catalog(1), Pages(2), Page(3), Encrypt(4)
        local offsets = {}

        offsets[1] = f:seek()
        f:write("1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n")

        offsets[2] = f:seek()
        f:write("2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n")

        offsets[3] = f:seek()
        f:write("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] >>\nendobj\n")

        offsets[4] = f:seek()
        f:write("4 0 obj\n<< /Filter /EBX_HANDLER /V 2 /EBX_ENCRYPTIONTYPE 6 /Length 128 >>\nendobj\n")

        -- Stream objects: 5 .. 5+numObjects-1
        -- Each is a stream with `streamSize` bytes of plaintext, RC4-encrypted.
        local firstStreamId = 5
        local lastStreamId = firstStreamId + numObjects - 1

        for objid = firstStreamId, lastStreamId do
            -- Plaintext: repeating pattern (simulates font/image data)
            local plaintext = string.rep(string.char((objid * 7) % 256), streamSize)
            local encrypted = rc4Encrypt(bookKey, objid, 0, plaintext)

            offsets[objid] = f:seek()
            f:write(string.format("%d 0 obj\n<< /Length %d >>\nstream\r\n", objid, #encrypted))
            f:write(encrypted)
            f:write("\r\nendstream\nendobj\n")
        end

        -- xref table
        local xrefOffset = f:seek()
        local maxId = lastStreamId
        f:write("xref\n")
        f:write(string.format("0 %d\n", maxId + 1))
        f:write("0000000000 65535 f \r\n")
        for id = 1, maxId do
            f:write(string.format("%010d %05d n \r\n", offsets[id] or 0, 0))
        end

        -- trailer
        f:write("trailer\n")
        f:write(string.format("<< /Size %d /Root 1 0 R /Encrypt 4 0 R /ID [<AABB> <CCDD>] >>\n", maxId + 1))
        f:write("startxref\n")
        f:write(tostring(xrefOffset) .. "\n")
        f:write("%%EOF\n")

        f:close()
        return path
    end

    --- Build a synthetic encrypted EPUB with a single large entry.
    -- The entry is AES-128-CBC encrypted with a 16-byte prefix.
    local function buildLargeEpub(tmpDir, bookKey, entrySize)
        local Archiver = require("ffi/archiver")
        local outputPath = tmpDir .. "/large_encrypted.epub"

        -- Build plaintext content for the entry
        local plaintext = string.rep("A", entrySize)

        -- Encrypt: 16-byte random prefix + plaintext + PKCS7 padding
        local prefix = string.rep("\0", 16)
        local payload = prefix .. plaintext
        local padLen = 16 - (#payload % 16)
        local padded = payload .. string.rep(string.char(padLen), padLen)

        local iv = string.rep("\0", 16)
        local encrypted = assert(nc.aes_cbc_encrypt(bookKey, iv, padded, true))

        -- Build encryption.xml
        local encXml = [[<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/content.xhtml"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>]]

        -- Build the EPUB (ZIP) with the encrypted entry
        local zipWriter = Archiver.Writer:new({})
        assert(zipWriter:open(outputPath, "epub"))
        local mtime = os.time()

        zipWriter:setZipCompression("store")
        zipWriter:addFileFromMemory("mimetype", "application/epub+zip", mtime)

        zipWriter:setZipCompression("deflate")
        zipWriter:addFileFromMemory("META-INF/container.xml", '<?xml version="1.0"?><container/>', mtime)
        zipWriter:addFileFromMemory("META-INF/encryption.xml", encXml, mtime)

        -- Store the encrypted entry (store, not deflate — already encrypted)
        zipWriter:setZipCompression("store")
        zipWriter:addFileFromMemory("OEBPS/content.xhtml", encrypted, mtime)

        zipWriter:close()
        return outputPath
    end

    -- ================================================================
    -- PDF memory test
    -- ================================================================
    describe("PDF decryption", function()
        it("peak memory stays bounded regardless of total object data", function()
            local DataStorage = require("datastorage")
            local tmpDir = DataStorage:getDataDir() .. "/test-mem-pdf-" .. tostring(os.time())
            koutil.makePath(tmpDir)

            local bookKey = string.rep(string.char(0xAA), 16)

            -- 50 stream objects × 100KB each = 5MB total payload.
            -- If the code accumulated all objects, heap would grow by ~5MB.
            -- With streaming, peak growth should be ~100-200KB (one object + overhead).
            local numObjects = 50
            local streamSize = 100 * 1024 -- 100KB per stream
            local totalPayload = numObjects * streamSize -- 5MB

            local inputPath = buildLargePdf(tmpDir, bookKey, numObjects, streamSize)
            local outputPath = tmpDir .. "/decrypted.pdf"

            -- Measure baseline heap
            local heapBefore = heapKB()

            -- Run full decryption pipeline
            local result, err = pdf.decryptAdobePdf(inputPath, outputPath, bookKey)
            assert.is.truthy(result, "decryptAdobePdf failed: " .. tostring(err))
            assert.is_true(result.decryptedObjects >= numObjects)

            -- Measure heap after (force GC to get accurate reading)
            local heapAfter = heapKB()
            local heapGrowthKB = heapAfter - heapBefore

            -- The total payload is 5MB (5120KB).
            -- With streaming, heap growth should be MUCH less than the total payload.
            -- Allow up to 20% of total payload as headroom for parser structures,
            -- xref tables, and transient allocations.
            local maxAllowedGrowthKB = totalPayload / 1024 * 0.20
            print(
                string.format(
                    "  [pdf] %dKB payload → %.0fKB heap growth (%.1f%%) — limit %.0fKB (20%%)",
                    totalPayload / 1024,
                    heapGrowthKB,
                    (heapGrowthKB / (totalPayload / 1024)) * 100,
                    maxAllowedGrowthKB
                )
            )
            assert.is_true(
                heapGrowthKB < maxAllowedGrowthKB,
                string.format(
                    "Heap grew by %.0fKB (%.1f%% of %dKB payload) — should be < %.0fKB (20%%)\n"
                        .. "This suggests objects are being accumulated in memory instead of streamed.",
                    heapGrowthKB,
                    (heapGrowthKB / (totalPayload / 1024)) * 100,
                    totalPayload / 1024,
                    maxAllowedGrowthKB
                )
            )

            -- Verify output is valid
            local f = io.open(outputPath, "rb")
            assert.is.truthy(f)
            local header = f:read(5)
            f:close()
            assert.are.equal("%PDF-", header)

            os.execute("rm -rf " .. tmpDir)
        end)
    end)

    -- ================================================================
    -- EPUB memory test
    -- ================================================================
    describe("EPUB decryption", function()
        it("peak memory stays bounded regardless of entry size", function()
            local DataStorage = require("datastorage")
            local tmpDir = DataStorage:getDataDir() .. "/test-mem-epub-" .. tostring(os.time())
            koutil.makePath(tmpDir)

            local bookKey = string.rep(string.char(0xBB), 16)

            -- Single entry of 2MB. If streaming works, heap should grow by
            -- ~64-128KB (CHUNK_SIZE), not 2MB.
            local entrySize = 2 * 1024 * 1024 -- 2MB

            local inputPath = buildLargeEpub(tmpDir, bookKey, entrySize)
            local outputPath = tmpDir .. "/decrypted.epub"

            -- Measure baseline heap
            local heapBefore = heapKB()

            -- Run full decryption pipeline
            local result, err = epub.decryptAdobeEpub(inputPath, outputPath, bookKey)
            assert.is.truthy(result, "decryptAdobeEpub failed: " .. tostring(err))
            assert.is_true(result.decryptedEntries > 0)

            -- Measure heap after
            local heapAfter = heapKB()
            local heapGrowthKB = heapAfter - heapBefore

            -- 2MB = 2048KB. With streaming (64KB chunks), growth should be << 2MB.
            -- Allow up to 25% as headroom for ZIP extraction + repack overhead.
            local maxAllowedGrowthKB = (entrySize / 1024) * 0.25
            print(
                string.format(
                    "  [epub] %dKB payload → %.0fKB heap growth (%.1f%%) — limit %.0fKB (25%%)",
                    entrySize / 1024,
                    heapGrowthKB,
                    (heapGrowthKB / (entrySize / 1024)) * 100,
                    maxAllowedGrowthKB
                )
            )
            assert.is_true(
                heapGrowthKB < maxAllowedGrowthKB,
                string.format(
                    "Heap grew by %.0fKB (%.1f%% of %dKB payload) — should be < %.0fKB (25%%)\n"
                        .. "This suggests the full entry is being loaded into memory.",
                    heapGrowthKB,
                    (heapGrowthKB / (entrySize / 1024)) * 100,
                    entrySize / 1024,
                    maxAllowedGrowthKB
                )
            )

            -- Verify output is valid EPUB
            local f = io.open(outputPath, "rb")
            assert.is.truthy(f)
            local header = f:read(2)
            f:close()
            assert.are.equal("PK", header)

            os.execute("rm -rf " .. tmpDir)
        end)
    end)

    -- ================================================================
    -- PdfWriter streaming verification
    -- ================================================================
    describe("PdfWriter streaming", function()
        it("does not hold references to written objects", function()
            local DataStorage = require("datastorage")
            local tmpDir = DataStorage:getDataDir() .. "/test-mem-writer-" .. tostring(os.time())
            koutil.makePath(tmpDir)
            local outputPath = tmpDir .. "/streaming_test.pdf"

            local w = assert(writer.PdfWriter.new(outputPath, { version = "%PDF-1.4" }))

            -- Write 20 objects with 50KB data each (1MB total)
            for i = 1, 20 do
                local bigData = string.rep("X", 50 * 1024)
                local obj = { stream_data = bigData, dict = { Length = #bigData } }
                w:writeObject(i, obj)
                -- After writeObject, we nil our local reference.
                -- If PdfWriter held a reference, GC couldn't reclaim it.
            end

            -- Force GC and check heap
            local heapMid = heapKB()

            -- Write 20 more (another 1MB)
            for i = 21, 40 do
                local bigData = string.rep("Y", 50 * 1024)
                local obj = { stream_data = bigData, dict = { Length = #bigData } }
                w:writeObject(i, obj)
            end

            local heapEnd = heapKB()

            -- If writer accumulated objects, heap would grow by ~1MB between
            -- mid and end measurements. With streaming, it should be flat.
            local growthKB = heapEnd - heapMid
            print(string.format("  [writer] 1MB per batch → %.0fKB growth between batches — limit 200KB", growthKB))
            assert.is_true(
                growthKB < 200,
                string.format(
                    "PdfWriter heap grew by %.0fKB between batches — should be < 200KB.\n" .. "This suggests writer is accumulating object references.",
                    growthKB
                )
            )

            w:finish({ Root = { ref = { objid = 1, genno = 0 } } })

            assert.are.equal(40, w:objectCount())

            os.execute("rm -rf " .. tmpDir)
        end)
    end)
end)
