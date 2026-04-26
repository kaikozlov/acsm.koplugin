local ffi = require("ffi")
local epub = require("adobe.epub")
local nativecrypto = require("adobe.util.nativecrypto")
local zlib = require("adobe.util.zlib")

describe("epub module", function()

    -- ---------------------------------------------------------------
    -- stripPkcs7Held (operates on FFI buffer)
    -- ---------------------------------------------------------------
    describe("_stripPkcs7Held", function()
        local function makeBuf(str)
            local buf = ffi.new("uint8_t[?]", #str)
            ffi.copy(buf, str, #str)
            return buf, #str
        end

        it("should strip padding of 1", function()
            local buf, len = makeBuf("hello world" .. string.char(1))
            local result = epub._stripPkcs7Held(buf, len)
            assert.are.equal(#"hello world", result)
        end)

        it("should strip padding of 16", function()
            local buf, len = makeBuf(string.rep(string.char(16), 16))
            local result = epub._stripPkcs7Held(buf, len)
            assert.are.equal(0, result)
        end)

        it("should strip padding of 5", function()
            local buf, len = makeBuf("test" .. string.rep(string.char(5), 5))
            local result = epub._stripPkcs7Held(buf, len)
            assert.are.equal(#"test", result)
        end)

        it("should reject padding of 0", function()
            local buf, len = makeBuf("hello" .. string.char(0))
            local result, err = epub._stripPkcs7Held(buf, len)
            assert.is_nil(result)
            assert.is.truthy(err:find("PKCS"))
        end)

        it("should reject padding > 16", function()
            local buf, len = makeBuf("hello" .. string.char(17))
            local result, err = epub._stripPkcs7Held(buf, len)
            assert.is_nil(result)
            assert.is.truthy(err:find("PKCS"))
        end)

        it("should handle single byte with padding 1", function()
            local buf, len = makeBuf(string.char(1))
            local result = epub._stripPkcs7Held(buf, len)
            assert.are.equal(0, result)
        end)

        it("should reject empty buffer", function()
            local buf = ffi.new("uint8_t[1]")
            local result, err = epub._stripPkcs7Held(buf, 0)
            assert.is_nil(result)
            assert.is.truthy(err:find("PKCS"))
        end)
    end)

    -- ---------------------------------------------------------------
    -- stripAdeptWatermarksFromText
    -- ---------------------------------------------------------------
    describe("_stripAdeptWatermarksFromText", function()
        it("should strip Adept.resource with content attr", function()
            local input = '<html><head><meta name="Adept.resource" content="urn:uuid:12345678-1234-1234-1234-123456789abc"/></head></html>'
            local result, count = epub._stripAdeptWatermarksFromText(input)
            assert.are.equal("<html><head></head></html>", result)
            assert.are.equal(1, count)
        end)

        it("should strip Adept.resource with value attr", function()
            local input = '<meta name="Adept.resource" value="urn:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"/>'
            local result, count = epub._stripAdeptWatermarksFromText(input)
            assert.are.equal("", result)
            assert.are.equal(1, count)
        end)

        it("should strip Adept.expected.resource", function()
            local input = '<meta name="Adept.expected.resource" content="urn:uuid:12345678-1234-1234-1234-123456789abc"/>'
            local result, count = epub._stripAdeptWatermarksFromText(input)
            assert.are.equal("", result)
            assert.are.equal(1, count)
        end)

        it("should strip reversed attr order (content before name)", function()
            local input = '<meta content="urn:uuid:12345678-1234-1234-1234-123456789abc" name="Adept.resource"/>'
            local result, count = epub._stripAdeptWatermarksFromText(input)
            assert.are.equal("", result)
            assert.are.equal(1, count)
        end)

        it("should strip multiple watermarks", function()
            local input = '<meta name="Adept.resource" content="urn:uuid:11111111-2222-3333-4444-555555555555"/>'
                .. '<p>hello</p>'
                .. '<meta name="Adept.expected.resource" value="urn:uuid:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"/>'
            local result, count = epub._stripAdeptWatermarksFromText(input)
            assert.are.equal("<p>hello</p>", result)
            assert.are.equal(2, count)
        end)

        it("should not strip non-Adept meta tags", function()
            local input = '<meta name="author" content="Test Author"/>'
            local result, count = epub._stripAdeptWatermarksFromText(input)
            assert.are.equal(input, result)
            assert.are.equal(0, count)
        end)

        it("should handle text with no meta tags", function()
            local input = "<html><body><p>Hello world</p></body></html>"
            local result, count = epub._stripAdeptWatermarksFromText(input)
            assert.are.equal(input, result)
            assert.are.equal(0, count)
        end)
    end)

    -- ---------------------------------------------------------------
    -- parseEncryptionXml
    -- ---------------------------------------------------------------
    describe("_parseEncryptionXml", function()
        it("should parse AES128-CBC encrypted entries", function()
            local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/chapter1.xhtml"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>]]
            local result = epub._parseEncryptionXml(xml)
            assert.is.truthy(result.encrypted["OEBPS/chapter1.xhtml"])
            assert.is_nil(result.rewrittenXml)
        end)

        it("should parse uncompressed encrypted entries", function()
            local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/cover.jpg"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>]]
            local result = epub._parseEncryptionXml(xml)
            assert.is.truthy(result.encryptedForceNoDecomp["OEBPS/cover.jpg"])
            assert.is_nil(result.rewrittenXml)
        end)

        it("should handle mixed entries", function()
            local xml = [[<?xml version="1.0" encoding="UTF-8"?>
<encryption xmlns="urn:oasis:names:tc:opendocument:xmlns:container"
            xmlns:enc="http://www.w3.org/2001/04/xmlenc#">
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://www.w3.org/2001/04/xmlenc#aes128-cbc"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/ch1.xhtml"/>
    </enc:CipherData>
  </enc:EncryptedData>
  <enc:EncryptedData>
    <enc:EncryptionMethod Algorithm="http://ns.adobe.com/adept/xmlenc#aes128-cbc-uncompressed"/>
    <enc:CipherData>
      <enc:CipherReference URI="OEBPS/img.jpg"/>
    </enc:CipherData>
  </enc:EncryptedData>
</encryption>]]
            local result = epub._parseEncryptionXml(xml)
            assert.is.truthy(result.encrypted["OEBPS/ch1.xhtml"])
            assert.is.truthy(result.encryptedForceNoDecomp["OEBPS/img.jpg"])
        end)
    end)

    -- ---------------------------------------------------------------
    -- decryptAdeptEntryFile (streaming file-to-file)
    -- ---------------------------------------------------------------
    describe("_decryptAdeptEntryFile", function()
        it("should decrypt a file in-place", function()
            local plaintext = "Streaming decryption test with enough data to be meaningful. "
            plaintext = string.rep(plaintext, 20) -- ~1.2KB

            -- Build encrypted blob: 16-byte prefix + plaintext + PKCS7 padding
            local prefix = string.rep("\0", 16)
            local padLen = 16 - (#plaintext % 16)
            local padded = prefix .. plaintext .. string.rep(string.char(padLen), padLen)

            local key = string.rep("\2", 16)
            local iv = string.rep("\0", 16)
            local encrypted = assert(nativecrypto.aes_cbc_encrypt(key, iv, padded, true))

            -- Write encrypted data to a temp file
            local testDir = TEST_DATA_DIR .. "/decrypt_test"
            require("util").makePath(testDir)
            local testFile = testDir .. "/test_entry.bin"
            local f = assert(io.open(testFile, "wb"))
            f:write(encrypted)
            f:close()

            -- Decrypt in-place (noDecomp=true since we didn't compress)
            local ok, err = epub._decryptAdeptEntryFile(testFile, key, true)
            assert.is.truthy(ok, err)

            -- Read back and compare
            local f2 = assert(io.open(testFile, "rb"))
            local result = f2:read("*a")
            f2:close()

            assert.are.equal(plaintext, result)
        end)

        it("should handle large files without excessive memory", function()
            -- Generate ~256KB of plaintext (enough to test chunking)
            local plaintext = string.rep("X", 256 * 1024)

            local prefix = string.rep("\0", 16)
            local padLen = 16 - (#plaintext % 16)
            local padded = prefix .. plaintext .. string.rep(string.char(padLen), padLen)

            local key = string.rep("\3", 16)
            local iv = string.rep("\0", 16)
            local encrypted = assert(nativecrypto.aes_cbc_encrypt(key, iv, padded, true))

            local testDir = TEST_DATA_DIR .. "/decrypt_large_test"
            require("util").makePath(testDir)
            local testFile = testDir .. "/large_entry.bin"
            local f = assert(io.open(testFile, "wb"))
            f:write(encrypted)
            f:close()

            local ok, err = epub._decryptAdeptEntryFile(testFile, key, true)
            assert.is.truthy(ok, err)

            local f2 = assert(io.open(testFile, "rb"))
            local result = f2:read("*a")
            f2:close()

            assert.are.equal(#plaintext, #result)
            assert.are.equal(plaintext, result)
        end)
    end)

    -- ---------------------------------------------------------------
    -- Streaming AES decryptor
    -- ---------------------------------------------------------------
    describe("streaming AES decryptor", function()
        it("should produce same output as one-shot decrypt via sink", function()
            local data = string.rep("A", 1024)
            local key = string.rep("\4", 16)
            local iv = string.rep("\0", 16)

            -- Encrypt
            local encrypted = assert(nativecrypto.aes_cbc_encrypt(key, iv, data, true))

            -- One-shot decrypt
            local oneshot = assert(nativecrypto.aes_cbc_decrypt(key, iv, encrypted, true))

            -- Streaming decrypt in 128-byte chunks with sink
            local decryptor = assert(nativecrypto.aes_cbc_decryptor(key, iv, true))
            local parts = {}
            local chunkSize = 128
            for i = 1, #encrypted, chunkSize do
                local chunk = encrypted:sub(i, math.min(i + chunkSize - 1, #encrypted))
                local ok, err = decryptor:update(chunk, function(ptr, len)
                    parts[#parts + 1] = ffi.string(ptr, len)
                    return true
                end)
                assert.is_truthy(ok, err)
            end
            local ok, err = decryptor:finalize(function(ptr, len)
                parts[#parts + 1] = ffi.string(ptr, len)
                return true
            end)
            assert.is_truthy(ok, err)
            local streamed = table.concat(parts)

            assert.are.equal(oneshot, streamed)
        end)

        it("should return ptr and len without sink", function()
            local data = string.rep("B", 256)
            local key = string.rep("\5", 16)
            local iv = string.rep("\0", 16)

            local encrypted = assert(nativecrypto.aes_cbc_encrypt(key, iv, data, true))
            local oneshot = assert(nativecrypto.aes_cbc_decrypt(key, iv, encrypted, true))

            local decryptor = assert(nativecrypto.aes_cbc_decryptor(key, iv, true))
            local parts = {}

            local ptr, len = decryptor:update(encrypted)
            assert.is_truthy(ptr)
            if len > 0 then
                parts[#parts + 1] = ffi.string(ptr, len)
            end

            ptr, len = decryptor:finalize()
            assert.is_truthy(ptr)
            if len > 0 then
                parts[#parts + 1] = ffi.string(ptr, len)
            end

            assert.are.equal(oneshot, table.concat(parts))
        end)
    end)

    -- ---------------------------------------------------------------
    -- Streaming zlib inflater
    -- ---------------------------------------------------------------
    describe("streaming zlib inflater", function()
        it("should initialize and finalize cleanly", function()
            local inflater, err = zlib.rawInflater()
            assert.is.truthy(inflater, err)
            inflater:finalize()
        end)
    end)
end)
