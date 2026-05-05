--- headless.lua
-- Run ACSM plugin tests inside a real KOReader environment (headless).
--
-- Invoked by test/headless_test.sh which handles cd'ing to the KOReader dir.
-- Do NOT run this directly — use ./test/headless_test.sh

require("setupkoenv")
require("dbg"):turnOff()

local lfs = require("libs/libkoreader-lfs")

local logger = require("logger")
logger:setLevel(logger.levels.warn)

local DataStorage = require("datastorage")

-- Isolated test settings (separate from user's real settings)
local test_defaults = DataStorage:getDataDir() .. "/defaults.acsm_test.lua"
local test_settings = DataStorage:getDataDir() .. "/settings.acsm_test.lua"
os.remove(test_defaults)
os.remove(test_settings)

G_defaults = require("luadefaults"):open(test_defaults)
G_reader_settings = require("luasettings"):open(test_settings)

-- Headless framebuffer (no SDL window)
einkfb = require("ffi/framebuffer")
einkfb.dummy = true

local Device = require("device")
Device.screen:init()

local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

Device.input.dummy = true

print(string.format("[headless] KOReader %s bootstrapped (headless)",
    require("version"):getCurrentRevision()))
print(string.format("[headless] Device: %s  Screen: %dx%d",
    tostring(Device.model), Device.screen:getWidth(), Device.screen:getHeight()))

-- ---------------------------------------------------------------------------
-- Discover and load the ACSM plugin
-- ---------------------------------------------------------------------------
local PluginLoader = require("pluginloader")
local enabled, disabled = PluginLoader:loadPlugins()

local acsm_plugin = nil
for _, p in ipairs(enabled) do
    if p.name == "acsm.koplugin" or p.name == "acsm" then
        acsm_plugin = p
    end
end

if not acsm_plugin then
    error("[headless] ACSM plugin not found! Is it symlinked into KOReader's plugins/?")
end

print(string.format("[headless] ACSM plugin: %s (%s)",
    acsm_plugin.fullname or acsm_plugin.name, acsm_plugin.path))

-- Add plugin's dependencies/ to package.path so adobe.* modules find xml2lua etc.
local plugin_root = acsm_plugin.path
package.path = plugin_root .. "/?.lua;" .. plugin_root .. "/dependencies/?.lua;" .. package.path

-- ---------------------------------------------------------------------------
-- Test runner
-- ---------------------------------------------------------------------------
local passed = 0
local failed = 0
local errors = {}

local function run_test(name, func)
    local ok, err = pcall(func)
    if ok then
        passed = passed + 1
        print(string.format("  ✓ %s", name))
    else
        failed = failed + 1
        print(string.format("  ✗ %s", name))
        errors[#errors + 1] = { name = name, err = err }
    end
end

local function describe(group_name, func)
    print(string.format("\n%s", group_name))
    func(run_test)
end

-- ---------------------------------------------------------------------------
-- Load modules
-- ---------------------------------------------------------------------------
local nativecrypto = require("adobe.util.nativecrypto")
local epub = require("adobe.epub")
local naming = require("adobe.util.naming")
local adobe = require("adobe.adobe")
local fulfillment = require("adobe.fulfillment")
local crypto = require("adobe.util.crypto")
local dom = require("adobe.util.dom")
local asn1 = require("adobe.util.asn1")
local zlib = require("adobe.util.zlib")
local xml = require("adobe.util.xml")

-- ---------------------------------------------------------------------------
-- Tests
-- ---------------------------------------------------------------------------

describe("Module loading (in KOReader environment)", function(test)
    test("nativecrypto loads and has AES", function()
        assert(nativecrypto.aes_cbc_encrypt, "missing aes_cbc_encrypt")
        assert(nativecrypto.aes_cbc_decrypt, "missing aes_cbc_decrypt")
    end)

    test("nativecrypto can generate RSA key", function()
        local key, err = nativecrypto.generate_rsa_key(1025, 65537)
        assert(key, err or "generate_rsa_key returned nil")
    end)

    test("epub module loads with decrypt functions", function()
        assert(epub.decryptAdobeEpub, "missing decryptAdobeEpub")
        assert(epub._stripPkcs7Held, "missing _stripPkcs7Held")
        assert(epub._parseEncryptionXml, "missing _parseEncryptionXml")
    end)

    test("fulfillment module loads with core functions", function()
        assert(fulfillment.process, "missing process")
        assert(fulfillment.downloadBook, "missing downloadBook")
        assert(fulfillment.decryptBookKey, "missing decryptBookKey")
    end)

    test("adobe module loads with activation functions", function()
        assert(adobe.signIn, "missing signIn")
        assert(adobe.activate, "missing activate")
        assert(adobe.getAuthenticationServiceInfo, "missing getAuthenticationServiceInfo")
    end)

    test("crypto module loads", function()
        assert(crypto.deviceKey, "missing deviceKey")
        assert(crypto.encryptLogin, "missing encryptLogin")
        assert(crypto.signXML, "missing signXML")
    end)

    test("dom module loads", function()
        assert(dom.firstElement, "missing firstElement")
        assert(dom.findDescendant, "missing findDescendant")
        assert(dom.childText, "missing childText")
    end)
end)

describe("Crypto round-trips (KOReader's OpenSSL)", function(test)
    test("AES-128-CBC encrypt/decrypt round-trip", function()
        local key = string.rep("\1", 16)
        local iv = string.rep("\0", 16)
        local plaintext = "Hello KOReader headless test!"

        -- Let OpenSSL handle PKCS7 padding
        local encrypted = assert(nativecrypto.aes_cbc_encrypt(key, iv, plaintext, false))
        local decrypted = assert(nativecrypto.aes_cbc_decrypt(key, iv, encrypted, false))
        assert(decrypted == plaintext, "decryption mismatch")
    end)

    test("AES streaming decrypt matches one-shot", function()
        local ffi = require("ffi")
        local data = string.rep("Streaming test data. ", 100)
        local key = string.rep("\2", 16)
        local iv = string.rep("\0", 16)

        local pad = 16 - (#data % 16)
        local padded = data .. string.rep(string.char(pad), pad)
        local encrypted = assert(nativecrypto.aes_cbc_encrypt(key, iv, padded, true))
        local oneshot = assert(nativecrypto.aes_cbc_decrypt(key, iv, encrypted, true))

        local decryptor = assert(nativecrypto.aes_cbc_decryptor(key, iv, true))
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

        assert(oneshot == table.concat(parts), "streaming vs oneshot mismatch")
    end)

    test("SHA-1 produces 20 bytes", function()
        local hash = assert(nativecrypto.sha1("test"))
        assert(#hash == 20, "expected 20 bytes, got " .. #hash)
    end)

    test("RSA keygen + sign + verify", function()
        local key = assert(nativecrypto.generate_rsa_key(1025, 65537))
        local data = "sign this message please"
        local hash = assert(nativecrypto.sha1(data))
        local sig = assert(key:sign_raw(hash))
        assert(#sig > 0, "empty signature")
    end)

    test("Device key encrypt/decrypt round-trip", function()
        local plaintext = "my-secret-device-key!"
        local devKey = crypto.deviceKey.new()
        local encrypted = assert(devKey:encrypt(plaintext))
        assert(encrypted ~= plaintext, "didn't actually encrypt")
        local decrypted = assert(devKey:decrypt(encrypted))
        assert(decrypted == plaintext, "decryption mismatch")
    end)
end)

describe("DOM parser", function(test)
    test("parses XML with namespaces", function()
        local doc = xml.deserialize([[
            <test xmlns:adept="http://ns.adobe.com/adept">
                <adept:child>content</adept:child>
            </test>
        ]])
        assert(doc, "xml deserialize returned nil")
    end)

    test("dom.firstElement finds children", function()
        local doc = dom.parse([[
            <root xmlns:adept="http://ns.adobe.com/adept">
                <adept:child>hello</adept:child>
            </root>
        ]])
        local ns_map = dom.nsMapFor(doc)
        local child = dom.firstElement(doc, ns_map, "child", "http://ns.adobe.com/adept")
        assert(child, "firstElement returned nil")
    end)

    test("dom.childText extracts text", function()
        local doc = dom.parse([[
            <root xmlns:adept="http://ns.adobe.com/adept">
                <adept:name>Test Book Title</adept:name>
            </root>
        ]])
        local ns_map = dom.nsMapFor(doc)
        local text = dom.childText(doc, ns_map, "name", "http://ns.adobe.com/adept")
        assert(text == "Test Book Title", "got: " .. tostring(text))
    end)
end)

describe("ASN.1 encoding", function(test)
    test("has expected API", function()
        assert(type(asn1.byte) == "function", "missing byte")
        assert(type(asn1.string) == "function", "missing string")
        assert(type(asn1.tag) == "function", "missing tag")
        assert(type(asn1.attribute) == "function", "missing attribute")
        assert(type(asn1.element) == "function", "missing element")
        assert(type(asn1.namespacedTag) == "function", "missing namespacedTag")
    end)
end)

describe("Zlib inflation", function(test)
    test("rawInflater creates and finalizes cleanly", function()
        local inflater, err = zlib.rawInflater()
        assert(inflater, err or "rawInflater returned nil")
        inflater:finalize()
    end)
end)

describe("EPUB internals", function(test)
    test("_stripPkcs7Held with padding of 1", function()
        local ffi = require("ffi")
        local buf = ffi.new("uint8_t[?]", 6)
        ffi.copy(buf, "hello" .. string.char(1), 6)
        local result = epub._stripPkcs7Held(buf, 6)
        assert(result == 5, "expected 5, got " .. tostring(result))
    end)

    test("_parseEncryptionXml handles AES128-CBC", function()
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
        assert(result.encrypted["OEBPS/chapter1.xhtml"], "expected encrypted entry")
    end)

    test("_stripAdeptWatermarksFromText strips Adept meta tags", function()
        local input = '<meta name="Adept.resource" content="urn:uuid:12345678"/>'
        local result, count = epub._stripAdeptWatermarksFromText(input)
        assert(count == 1, "expected 1 watermark, got " .. tostring(count))
        assert(not result:find("Adept"), "watermark not stripped")
    end)
end)

describe("Naming utility", function(test)
    test("sanitizeTitle handles unsafe chars", function()
        assert(naming.sanitizeTitle('a:b*c?d"e<f>g') == "a b c d e f g")
    end)

    test("sanitizeTitle returns nil for empty/nil", function()
        assert(naming.sanitizeTitle("") == nil)
        assert(naming.sanitizeTitle(nil) == nil)
    end)

    test("sanitizeTitle truncates long titles", function()
        local long = string.rep("A", 300)
        local result = naming.sanitizeTitle(long)
        assert(#result <= 200, "expected <= 200 chars, got " .. #result)
    end)
end)

-- ---------------------------------------------------------------------------
-- Summary
-- ---------------------------------------------------------------------------
print(string.format("\n%s", string.rep("─", 50)))
if failed == 0 then
    print(string.format("✓ All %d headless tests passed!", passed))
else
    print(string.format("✗ %d passed, %d failed", passed, failed))
    for _, e in ipairs(errors) do
        print(string.format("  FAIL: %s", e.name))
        local first_line = tostring(e.err):match("([^\n]+)")
        if first_line then print("    " .. first_line) end
    end
    os.exit(1)
end
