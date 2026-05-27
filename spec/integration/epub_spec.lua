--- Integration tests: EPUB internals and decryption pipeline
-- Tests both low-level EPUB helpers (PKCS7, encryption.xml parsing,
-- watermark stripping) and the full decryptAdobeEpub pipeline using
-- on-the-fly generated encrypted EPUB fixtures.

describe("EPUB internals", function()
    it("_stripPkcs7Held strips padding of 1", function()
        local ffi  = require("ffi")
        local epub = require("adobe.epub")
        local buf = ffi.new("uint8_t[?]", 6)
        ffi.copy(buf, "hello" .. string.char(1), 6)
        assert.are.equal(5, epub._stripPkcs7Held(buf, 6))
    end)

    it("_parseEncryptionXml handles AES128-CBC", function()
        local epub = require("adobe.epub")
        local xml_str = [[<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/chapter1.xhtml"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>]]
        local result = epub._parseEncryptionXml(xml_str)
        assert.is.truthy(result.encrypted["OEBPS/chapter1.xhtml"])
    end)

    it("_stripAdeptWatermarksFromText strips Adept meta tags", function()
        local epub = require("adobe.epub")
        local input = '<meta name="Adept.resource" content="urn:uuid:12345678"/>'
        local result, count = epub._stripAdeptWatermarksFromText(input)
        assert.are.equal(1, count)
        assert.is_false(result:find("Adept") ~= nil)
    end)
end)

describe("EPUB decryption pipeline (real crypto + real zip I/O)", function()
    local epub, nc, ffi, lfs, koutil

    --- Raw deflate using zlib FFI (no zlib header, matching inflate -15).
    -- This mirrors what Adobe ADEPT does: deflate content before encrypting.
    local function rawDeflate(data)
        local _ffi = require("ffi")
        -- Declare deflate functions if not yet declared
        pcall(_ffi.cdef, [[
            int deflateInit2_(z_stream *strm, int level, int method, int windowBits,
                              int memLevel, int strategy, const char *version, int stream_size);
            int deflate(z_stream *strm, int flush);
            int deflateEnd(z_stream *strm);
        ]])
        -- Load zlib (same discovery logic as adobe/util/zlib.lua)
        local libz
        if _ffi.loadlib then
            libz = _ffi.loadlib("z", "1")
        else
            libz = _ffi.load("z")
        end

        local stream = _ffi.new("z_stream[1]")
        -- Z_DEFLATED=8, windowBits=-15 (raw), memLevel=8, Z_DEFAULT_STRATEGY=0
        local rc = libz.deflateInit2_(stream, 6, 8, -15, 8, 0,
                                       libz.zlibVersion(), _ffi.sizeof(stream[0]))
        assert(rc == 0, "deflateInit2 failed: " .. tostring(rc))

        stream[0].next_in = _ffi.cast("Bytef *", data)
        stream[0].avail_in = #data

        local CHUNK = 32768
        local outbuf = _ffi.new("uint8_t[?]", CHUNK)
        local chunks = {}

        -- Z_FINISH=4
        repeat
            stream[0].next_out = outbuf
            stream[0].avail_out = CHUNK
            rc = libz.deflate(stream, 4) -- Z_FINISH
            local produced = CHUNK - tonumber(stream[0].avail_out)
            if produced > 0 then
                chunks[#chunks + 1] = _ffi.string(outbuf, produced)
            end
        until rc == 1 -- Z_STREAM_END

        libz.deflateEnd(stream)
        return table.concat(chunks)
    end

    setup(function()
        epub = require("adobe.epub")
        nc = require("adobe.util.nativecrypto")
        ffi = require("ffi")
        lfs = require("libs/libkoreader-lfs")
        koutil = require("util")
    end)

    -- Known test key: 16 bytes of 0xAA
    local TEST_KEY = string.rep(string.char(0xAA), 16)
    local CHAPTER_TEXT = [[<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head><title>Test Chapter</title></head>
<body>
<h1>Chapter 1</h1>
<p>This is a test paragraph for the ACSM plugin decryption pipeline.
It needs to be long enough to exercise the streaming decrypt and inflate
paths properly, so here is some additional padding text to make sure we
have enough data to work with across multiple AES blocks.</p>
</body>
</html>]]

    --- Build a minimal encrypted EPUB on the fly.
    -- Returns the path to the encrypted EPUB and the original chapter text.
    local function buildEncryptedEpub(tmpDir, opts)
        opts = opts or {}
        local workDir = tmpDir .. "/build"
        koutil.makePath(workDir .. "/META-INF")
        koutil.makePath(workDir .. "/OEBPS")

        -- mimetype (must be uncompressed, first entry)
        koutil.writeToFile("application/epub+zip", workDir .. "/mimetype")

        -- container.xml
        koutil.writeToFile([[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], workDir .. "/META-INF/container.xml")

        -- content.opf
        koutil.writeToFile([[<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:identifier id="uid">urn:uuid:test-12345</dc:identifier>
    <dc:title>Test Book</dc:title>
  </metadata>
  <manifest>
    <item id="ch1" href="chapter1.xhtml" media-type="application/xhtml+xml"/>
  </manifest>
  <spine><itemref idref="ch1"/></spine>
</package>]], workDir .. "/OEBPS/content.opf")

        -- Encrypt the chapter content using Adobe ADEPT format:
        -- 16 random prefix bytes + deflate(plaintext) + PKCS7 padding, then AES-128-CBC
        local chapterText = opts.chapter_text or CHAPTER_TEXT

        -- Compress the plaintext (raw deflate, no zlib header)
        local deflated = rawDeflate(chapterText)

        -- Prepend 16 random prefix bytes (Adobe ADEPT format)
        local prefix = ""
        for _ = 1, 16 do
            prefix = prefix .. string.char(math.random(0, 255))
        end
        local payload = prefix .. deflated

        -- PKCS7 pad to AES block boundary
        local padLen = 16 - (#payload % 16)
        local padded = payload .. string.rep(string.char(padLen), padLen)

        -- Encrypt with AES-128-CBC, zero IV, no OpenSSL padding (we did PKCS7 manually)
        local iv = string.rep("\0", 16)
        local encrypted = assert(nc.aes_cbc_encrypt(TEST_KEY, iv, padded, true))

        koutil.writeToFile(encrypted, workDir .. "/OEBPS/chapter1.xhtml")

        -- encryption.xml listing the encrypted entry
        local encXmlContent = [[<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/chapter1.xhtml"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>]]

        if opts.extra_encrypted_entry then
            -- Add a second encrypted entry (uncompressed variant)
            koutil.makePath(workDir .. "/OEBPS/images")
            local prefix2 = ""
            for _ = 1, 16 do
                prefix2 = prefix2 .. string.char(math.random(0, 255))
            end
            local payload2 = prefix2 .. opts.extra_encrypted_entry
            local padLen2 = 16 - (#payload2 % 16)
            local padded2 = payload2 .. string.rep(string.char(padLen2), padLen2)
            local encrypted2 = assert(nc.aes_cbc_encrypt(TEST_KEY, iv, padded2, true))
            koutil.writeToFile(encrypted2, workDir .. "/OEBPS/images/cover.svg")

            encXmlContent = [[<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/chapter1.xhtml"/>
    </enc:CipherData>
  </enc:EncryptedData>
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/images/cover.svg"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>]]
        end

        koutil.writeToFile(encXmlContent, workDir .. "/META-INF/encryption.xml")

        -- Pack into an EPUB zip
        local Archiver = require("ffi/archiver")
        local epubPath = tmpDir .. "/test_encrypted.epub"
        local writer = Archiver.Writer:new{}
        assert(writer:open(epubPath, "epub"))
        local mtime = os.time()

        writer:setZipCompression("store")
        assert(writer:addFileFromMemory("mimetype", "application/epub+zip", mtime))

        writer:setZipCompression("deflate")
        writer:addPath("META-INF/container.xml", workDir .. "/META-INF/container.xml", false, mtime)
        assert(not writer.err, "Failed to add container.xml: " .. tostring(writer.err))
        writer:addPath("META-INF/encryption.xml", workDir .. "/META-INF/encryption.xml", false, mtime)
        assert(not writer.err, "Failed to add encryption.xml: " .. tostring(writer.err))
        writer:addPath("OEBPS/content.opf", workDir .. "/OEBPS/content.opf", false, mtime)
        assert(not writer.err, "Failed to add content.opf: " .. tostring(writer.err))

        -- Encrypted entries stored uncompressed (as Adobe does)
        writer:setZipCompression("store")
        writer:addPath("OEBPS/chapter1.xhtml", workDir .. "/OEBPS/chapter1.xhtml", false, mtime)
        assert(not writer.err, "Failed to add chapter1.xhtml: " .. tostring(writer.err))
        if opts.extra_encrypted_entry then
            writer:addPath("OEBPS/images/cover.svg", workDir .. "/OEBPS/images/cover.svg", false, mtime)
            assert(not writer.err, "Failed to add cover.svg: " .. tostring(writer.err))
        end

        writer:close()
        return epubPath, chapterText
    end

    --- Extract an EPUB and return the path to the extracted directory.
    local function extractEpub(epubPath, destDir)
        koutil.makePath(destDir)
        local Archiver = require("ffi/archiver")
        local reader = Archiver.Reader:new()
        assert(reader:open(epubPath))
        for entry in reader:iterate() do
            if entry.mode == "file" then
                local fullPath = destDir .. "/" .. entry.path
                local parent = fullPath:match("^(.*)/[^/]+$")
                if parent then koutil.makePath(parent) end
                reader:extractToPath(entry.path, fullPath)
            end
        end
        reader:close()
        return destDir
    end

    it("decrypts a single-chapter encrypted EPUB", function()
        local DataStorage = require("datastorage")
        local tmpDir = DataStorage:getDataDir() .. "/test-epub-decrypt-" .. tostring(os.time())
        koutil.makePath(tmpDir)

        local inputPath, originalText = buildEncryptedEpub(tmpDir)
        local outputPath = tmpDir .. "/decrypted.epub"

        local result, err = epub.decryptAdobeEpub(inputPath, outputPath, TEST_KEY)
        assert.is.truthy(result, "decryptAdobeEpub failed: " .. tostring(err))
        assert.are.equal(outputPath, result.outputPath)
        assert.are.equal(1, result.decryptedEntries)
        assert.is_false(result.remainingEncryptionXml)

        -- Extract and verify decrypted chapter matches original
        local verifyDir = extractEpub(outputPath, tmpDir .. "/verify")
        local decryptedText = koutil.readFromFile(verifyDir .. "/OEBPS/chapter1.xhtml", "rb")
        assert.is.truthy(decryptedText, "Decrypted chapter not found")
        assert.are.equal(originalText, decryptedText)

        -- Verify encryption.xml was removed
        local encXml = koutil.readFromFile(verifyDir .. "/META-INF/encryption.xml", "rb")
        assert.is_nil(encXml, "encryption.xml should be removed when all entries decrypted")

        os.execute("rm -rf " .. tmpDir)
    end)

    it("handles multiple encrypted entries", function()
        local DataStorage = require("datastorage")
        local tmpDir = DataStorage:getDataDir() .. "/test-epub-multi-" .. tostring(os.time())
        koutil.makePath(tmpDir)

        local extraContent = "<svg>test image content here for testing</svg>"
        local inputPath = buildEncryptedEpub(tmpDir, { extra_encrypted_entry = extraContent })
        local outputPath = tmpDir .. "/decrypted.epub"

        local result, err = epub.decryptAdobeEpub(inputPath, outputPath, TEST_KEY)
        assert.is.truthy(result, "decryptAdobeEpub failed: " .. tostring(err))
        assert.are.equal(2, result.decryptedEntries)

        -- Verify the uncompressed entry was decrypted correctly
        local verifyDir = extractEpub(outputPath, tmpDir .. "/verify")
        local svgContent = koutil.readFromFile(verifyDir .. "/OEBPS/images/cover.svg", "rb")
        assert.is.truthy(svgContent)
        assert.are.equal(extraContent, svgContent)

        os.execute("rm -rf " .. tmpDir)
    end)

    it("extracts EPUBs whose first content entry needs nested directories", function()
        local DataStorage = require("datastorage")
        local Archiver = require("ffi/archiver")
        local tmpDir = DataStorage:getDataDir() .. "/test-epub-nested-" .. tostring(os.time())
        koutil.makePath(tmpDir)

        local workDir = tmpDir .. "/build"
        koutil.makePath(workDir .. "/META-INF")
        koutil.makePath(workDir .. "/OPS/Text")

        koutil.writeToFile("application/epub+zip", workDir .. "/mimetype")
        koutil.writeToFile([[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]], workDir .. "/META-INF/container.xml")
        koutil.writeToFile([[<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:title>Nested Book</dc:title></metadata>
  <manifest><item id="ch1" href="Text/chapter1.xhtml" media-type="application/xhtml+xml"/></manifest>
  <spine><itemref idref="ch1"/></spine>
</package>]], workDir .. "/OPS/content.opf")

        local deflated = rawDeflate(CHAPTER_TEXT)
        local payload = string.rep("\0", 16) .. deflated
        local padLen = 16 - (#payload % 16)
        local padded = payload .. string.rep(string.char(padLen), padLen)
        local encrypted = assert(nc.aes_cbc_encrypt(TEST_KEY, string.rep("\0", 16), padded, true))
        koutil.writeToFile(encrypted, workDir .. "/OPS/Text/chapter1.xhtml")

        koutil.writeToFile([[<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:CipherData><enc:CipherReference URI="OPS/Text/chapter1.xhtml"/></enc:CipherData>
  </enc:EncryptedData>
</encryption>]], workDir .. "/META-INF/encryption.xml")

        local inputPath = tmpDir .. "/test_nested.epub"
        local writer = Archiver.Writer:new{}
        assert(writer:open(inputPath, "epub"))
        local mtime = os.time()
        writer:setZipCompression("store")
        assert(writer:addFileFromMemory("mimetype", "application/epub+zip", mtime))
        writer:setZipCompression("deflate")
        writer:addPath("META-INF/container.xml", workDir .. "/META-INF/container.xml", false, mtime)
        assert(not writer.err, "Failed to add container.xml: " .. tostring(writer.err))
        writer:addPath("META-INF/encryption.xml", workDir .. "/META-INF/encryption.xml", false, mtime)
        assert(not writer.err, "Failed to add encryption.xml: " .. tostring(writer.err))
        writer:setZipCompression("store")
        writer:addPath("OPS/Text/chapter1.xhtml", workDir .. "/OPS/Text/chapter1.xhtml", false, mtime)
        assert(not writer.err, "Failed to add chapter1.xhtml: " .. tostring(writer.err))
        writer:setZipCompression("deflate")
        writer:addPath("OPS/content.opf", workDir .. "/OPS/content.opf", false, mtime)
        assert(not writer.err, "Failed to add content.opf: " .. tostring(writer.err))
        writer:close()

        local outputPath = tmpDir .. "/decrypted.epub"
        local result, err = epub.decryptAdobeEpub(inputPath, outputPath, TEST_KEY)
        assert.is.truthy(result, "decryptAdobeEpub failed: " .. tostring(err))

        local verifyDir = extractEpub(outputPath, tmpDir .. "/verify")
        local content = koutil.readFromFile(verifyDir .. "/OPS/Text/chapter1.xhtml", "rb")
        assert.are.equal(CHAPTER_TEXT, content)

        os.execute("rm -rf " .. tmpDir)
    end)

    it("preserves non-encrypted entries unchanged", function()
        local DataStorage = require("datastorage")
        local tmpDir = DataStorage:getDataDir() .. "/test-epub-preserve-" .. tostring(os.time())
        koutil.makePath(tmpDir)

        local inputPath = buildEncryptedEpub(tmpDir)
        local outputPath = tmpDir .. "/decrypted.epub"

        local result, err = epub.decryptAdobeEpub(inputPath, outputPath, TEST_KEY)
        assert.is.truthy(result, "decryptAdobeEpub failed: " .. tostring(err))

        local verifyDir = extractEpub(outputPath, tmpDir .. "/verify")
        local opf = koutil.readFromFile(verifyDir .. "/OEBPS/content.opf", "rb")
        assert.is.truthy(opf)
        assert.is.truthy(opf:find("Test Book", 1, true))

        os.execute("rm -rf " .. tmpDir)
    end)

    it("strips Adept watermarks from decrypted content", function()
        local DataStorage = require("datastorage")
        local tmpDir = DataStorage:getDataDir() .. "/test-epub-watermark-" .. tostring(os.time())
        koutil.makePath(tmpDir)

        local watermarked_chapter = [[<?xml version="1.0" encoding="UTF-8"?>
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<title>Test</title>
<meta name="Adept.resource" content="urn:uuid:12345678-1234-1234-1234-123456789012"/>
</head>
<body><p>Content</p></body>
</html>]]

        local inputPath = buildEncryptedEpub(tmpDir, { chapter_text = watermarked_chapter })
        local outputPath = tmpDir .. "/decrypted.epub"

        local result, err = epub.decryptAdobeEpub(inputPath, outputPath, TEST_KEY)
        assert.is.truthy(result, "decryptAdobeEpub failed: " .. tostring(err))
        assert.are.equal(1, result.strippedWatermarkFiles)

        local verifyDir = extractEpub(outputPath, tmpDir .. "/verify")
        local content = koutil.readFromFile(verifyDir .. "/OEBPS/chapter1.xhtml", "rb")
        assert.is.truthy(content)
        assert.is_nil(content:find("Adept.resource", 1, true))

        os.execute("rm -rf " .. tmpDir)
    end)
end)
