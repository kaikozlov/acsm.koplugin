--- Integration tests: module loading smoke checks
-- Verifies all adobe.* modules load correctly with real KOReader
-- native FFI libraries (OpenSSL, zlib, etc.) available.

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
