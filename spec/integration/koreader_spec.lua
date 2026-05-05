--- Integration tests for acsm.koplugin
-- These run inside a real KOReader environment (headless, via Docker).
--
-- Unlike the unit specs in spec/ which use mocks, these tests load
-- the real KOReader modules and the real native FFI libraries
-- (OpenSSL, zlib, etc.) via spec/commonrequire.lua.

describe("ACSM plugin module loading", function()
    it("loads nativecrypto with AES functions", function()
        local nc = require("adobe.util.nativecrypto")
        assert.is.truthy(nc.aes_cbc_encrypt)
        assert.is.truthy(nc.aes_cbc_decrypt)
    end)

    it("loads nativecrypto with SHA-1", function()
        local nc = require("adobe.util.nativecrypto")
        assert.is.truthy(nc.sha1)
    end)

    it("loads nativecrypto with RSA keygen", function()
        local nc = require("adobe.util.nativecrypto")
        assert.is.truthy(nc.generate_rsa_key)
    end)

    it("loads epub module", function()
        local epub = require("adobe.epub")
        assert.is.truthy(epub.decryptAdobeEpub)
        assert.is.truthy(epub._stripPkcs7Held)
        assert.is.truthy(epub._parseEncryptionXml)
    end)

    it("loads fulfillment module", function()
        local f = require("adobe.fulfillment")
        assert.is.truthy(f.process)
        assert.is.truthy(f.downloadBook)
        assert.is.truthy(f.decryptBookKey)
    end)

    it("loads adobe activation module", function()
        local a = require("adobe.adobe")
        assert.is.truthy(a.signIn)
        assert.is.truthy(a.activate)
    end)

    it("loads crypto module", function()
        local c = require("adobe.util.crypto")
        assert.is.truthy(c.deviceKey)
        assert.is.truthy(c.encryptLogin)
        assert.is.truthy(c.signXML)
    end)

    it("loads dom parser", function()
        local d = require("adobe.util.dom")
        assert.is.truthy(d.firstElement)
        assert.is.truthy(d.findDescendant)
        assert.is.truthy(d.childText)
    end)

    it("loads ASN.1 encoder", function()
        local a = require("adobe.util.asn1")
        assert.is.truthy(a.byte)
        assert.is.truthy(a.string)
        assert.is.truthy(a.tag)
        assert.is.truthy(a.element)
    end)

    it("loads zlib module", function()
        local z = require("adobe.util.zlib")
        assert.is.truthy(z.rawInflater)
    end)

    it("loads XML parser", function()
        local x = require("adobe.util.xml")
        assert.is.truthy(x.deserialize)
    end)

    it("loads naming utility", function()
        local n = require("adobe.util.naming")
        assert.is.truthy(n.sanitizeTitle)
    end)
end)

describe("Crypto round-trips (real OpenSSL)", function()
    it("AES-128-CBC encrypt/decrypt round-trip", function()
        local nc = require("adobe.util.nativecrypto")
        local key = string.rep("\1", 16)
        local iv  = string.rep("\0", 16)
        local plaintext = "Hello KOReader!"

        local encrypted = assert(nc.aes_cbc_encrypt(key, iv, plaintext, false))
        local decrypted = assert(nc.aes_cbc_decrypt(key, iv, encrypted, false))
        assert.are.equal(plaintext, decrypted)
    end)

    it("AES streaming decrypt matches one-shot", function()
        local ffi = require("ffi")
        local nc  = require("adobe.util.nativecrypto")
        local data = string.rep("Streaming test data. ", 100)
        local key  = string.rep("\2", 16)
        local iv   = string.rep("\0", 16)

        local pad = 16 - (#data % 16)
        local padded = data .. string.rep(string.char(pad), pad)
        local encrypted = assert(nc.aes_cbc_encrypt(key, iv, padded, true))
        local oneshot = assert(nc.aes_cbc_decrypt(key, iv, encrypted, true))

        local decryptor = assert(nc.aes_cbc_decryptor(key, iv, true))
        local parts = {}
        for i = 1, #encrypted, 256 do
            local chunk = encrypted:sub(i, math.min(i + 255, #encrypted))
            decryptor:update(chunk, function(ptr, len)
                parts[#parts + 1] = ffi.string(ptr, len)
                return true
            end)
        end
        decryptor:finalize(function(ptr, len)
            parts[#parts + 1] = ffi.string(ptr, len)
            return true
        end)

        assert.are.equal(oneshot, table.concat(parts))
    end)

    it("SHA-1 produces 20 bytes", function()
        local nc = require("adobe.util.nativecrypto")
        local hash = assert(nc.sha1("test"))
        assert.are.equal(20, #hash)
    end)

    it("RSA keygen + sign", function()
        local nc = require("adobe.util.nativecrypto")
        local key = assert(nc.generate_rsa_key(1025, 65537))
        local data = "sign this message please"
        local hash = assert(nc.sha1(data))
        local sig = assert(key:sign_raw(hash))
        assert.is_truthy(#sig > 0)
    end)

    it("Device key encrypt/decrypt round-trip", function()
        local crypto = require("adobe.util.crypto")
        local plaintext = "my-secret-device-key!"
        local devKey = crypto.deviceKey.new()
        local encrypted = assert(devKey:encrypt(plaintext))
        assert.is_not.equal(plaintext, encrypted)
        local decrypted = assert(devKey:decrypt(encrypted))
        assert.are.equal(plaintext, decrypted)
    end)
end)

describe("DOM parser", function()
    it("parses XML with namespaces", function()
        local xml = require("adobe.util.xml")
        local doc = xml.deserialize([[
            <test xmlns:adept="http://ns.adobe.com/adept">
                <adept:child>content</adept:child>
            </test>
        ]])
        assert.is.truthy(doc)
    end)

    it("dom.firstElement finds children", function()
        local dom = require("adobe.util.dom")
        local doc = dom.parse([[
            <root xmlns:adept="http://ns.adobe.com/adept">
                <adept:child>hello</adept:child>
            </root>
        ]])
        local ns_map = dom.nsMapFor(doc)
        local child = dom.firstElement(doc, ns_map, "child", "http://ns.adobe.com/adept")
        assert.is.truthy(child)
    end)

    it("dom.childText extracts text", function()
        local dom = require("adobe.util.dom")
        local doc = dom.parse([[
            <root xmlns:adept="http://ns.adobe.com/adept">
                <adept:name>Test Book Title</adept:name>
            </root>
        ]])
        local ns_map = dom.nsMapFor(doc)
        local text = dom.childText(doc, ns_map, "name", "http://ns.adobe.com/adept")
        assert.are.equal("Test Book Title", text)
    end)
end)

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

describe("Naming utility", function()
    it("sanitizeTitle handles unsafe chars", function()
        local naming = require("adobe.util.naming")
        assert.are.equal("a b c d e f g", naming.sanitizeTitle('a:b*c?d"e<f>g'))
    end)

    it("sanitizeTitle returns nil for empty/nil", function()
        local naming = require("adobe.util.naming")
        assert.is_nil(naming.sanitizeTitle(""))
        assert.is_nil(naming.sanitizeTitle(nil))
    end)

    it("sanitizeTitle truncates long titles", function()
        local naming = require("adobe.util.naming")
        local result = naming.sanitizeTitle(string.rep("A", 300))
        assert.is_true(#result <= 200)
    end)
end)
