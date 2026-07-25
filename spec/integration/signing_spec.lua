--- Integration tests: ASN.1 encoding and XML signing (P0 — the linchpin)
-- Verifies the exact byte output of asn1.element() with known inputs,
-- and validates that crypto.signXML composes ASN.1 → SHA-1 → RSA sign correctly.
-- Every Adobe request depends on this pipeline.

describe("ASN.1 encoding (asn1.element)", function()
    local asn1

    setup(function()
        asn1 = require("adobe.util.asn1")
    end)

    describe("primitives", function()
        it("ASN.string encodes with 2-byte big-endian length prefix", function()
            local result = asn1.string("hello")
            assert.are.equal("\x00\x05hello", result)
        end)

        it("ASN.string handles empty string", function()
            assert.are.equal("\x00\x00", asn1.string(""))
        end)

        it("ASN.string rejects values that cannot fit in its two-byte length", function()
            assert.has.errors(function()
                asn1.string(string.rep("x", 0x10000))
            end)
        end)

        it("ASN.tag splits namespace:name correctly", function()
            local result = asn1.tag("adept:signIn")
            -- namespace "adept" (length 5) + name "signIn" (length 7)
            assert.are.equal("\x00\x05adept\x00\x06signIn", result)
        end)

        it("ASN.tag handles bare name (no colon) as empty namespace", function()
            local result = asn1.tag("root")
            assert.are.equal("\x00\x00\x00\x04root", result)
        end)

        it("ASN.attribute skips xmlns: attributes entirely", function()
            assert.are.equal("", asn1.attribute("xmlns:foo", "http://example.com"))
            assert.are.equal("", asn1.attribute("xmlns", "http://example.com"))
        end)

        it("ASN.attribute encodes non-xmlns attribute", function()
            local result = asn1.attribute("method", "bar")
            -- ATTRIBUTE byte + tag("method") + string("bar")
            local expected = "\x05"
                .. "\x00\x00" -- namespace "" for attribute name
                .. "\x00\x06method" -- attribute local name
                .. "\x00\x03bar" -- attribute value
            assert.are.equal(expected, result)
        end)
    end)

    describe("asn1.element", function()
        it("encodes a simple text element", function()
            local result = asn1.element("root", "hello")
            -- BEGIN_ELEMENT + tag("root") + END_ATTRIBUTES + TEXT_NODE + string("hello") + END_ELEMENT
            local expected = "\x01" -- BEGIN_ELEMENT
                .. "\x00\x00" -- namespace ""
                .. "\x00\x04root" -- tag "root"
                .. "\x02" -- END_ATTRIBUTES
                .. "\x04" -- TEXT_NODE
                .. "\x00\x05hello" -- text content
                .. "\x03" -- END_ELEMENT
            assert.are.equal(expected, result)
        end)

        it("encodes an element with attributes", function()
            local result = asn1.element("root", {
                _attr = { method = "bar" },
            })
            local expected = "\x01" -- BEGIN_ELEMENT
                .. "\x00\x00" -- namespace ""
                .. "\x00\x04root" -- tag "root"
                .. "\x05" -- ATTRIBUTE
                .. "\x00\x00" -- attr namespace ""
                .. "\x00\x06method" -- attr name "method"
                .. "\x00\x03bar" -- attr value "bar"
                .. "\x02" -- END_ATTRIBUTES
                .. "\x03" -- END_ELEMENT (empty body)
            assert.are.equal(expected, result)
        end)

        it("encodes a text leaf with attributes", function()
            local result = asn1.element("root", {
                _attr = { lang = "en" },
                "hello",
            })
            local expected = "\x01" -- BEGIN_ELEMENT
                .. "\x00\x00\x00\x04root"
                .. "\x05" -- ATTRIBUTE
                .. "\x00\x00\x00\x04lang"
                .. "\x00\x02en"
                .. "\x02" -- END_ATTRIBUTES
                .. "\x04\x00\x05hello" -- TEXT_NODE
                .. "\x03" -- END_ELEMENT
            assert.are.equal(expected, result)
        end)

        it("does not mutate the input attributes", function()
            local content = { _attr = { method = "bar" }, child = "text" }
            asn1.element("root", content)
            assert.are.same({ method = "bar" }, content._attr)
        end)

        it("chunks text longer than 0x7FFF bytes", function()
            local first = string.rep("x", 0x7FFF)
            local result = asn1.element("root", first .. "y")
            local expected = "\x01\x00\x00\x00\x04root\x02" .. "\x04\x7F\xFF" .. first .. "\x04\x00\x01y" .. "\x03"
            assert.are.equal(expected, result)
        end)

        it("encodes a namespaced element", function()
            local result = asn1.element("adept:signIn", {
                _attr = { method = "bar" },
            })
            local expected = "\x01" -- BEGIN_ELEMENT
                .. "\x00\x05adept" -- namespace "adept" (5)
                .. "\x00\x06signIn" -- tag "signIn" (6)
                .. "\x05" -- ATTRIBUTE
                .. "\x00\x00" -- attr namespace ""
                .. "\x00\x06method" -- attr name "method"
                .. "\x00\x03bar" -- attr value "bar"
                .. "\x02" -- END_ATTRIBUTES
                .. "\x03" -- END_ELEMENT
            assert.are.equal(expected, result)
        end)

        it("encodes nested child elements (alphabetical key order)", function()
            local result = asn1.element("root", {
                child = "text",
            })
            local expected = "\x01" -- BEGIN_ELEMENT root
                .. "\x00\x00" -- namespace ""
                .. "\x00\x04root" -- tag "root"
                .. "\x02" -- END_ATTRIBUTES
                .. "\x01" -- BEGIN_ELEMENT child
                .. "\x00\x00" -- namespace ""
                .. "\x00\x05child" -- tag "child"
                .. "\x02" -- END_ATTRIBUTES
                .. "\x04" -- TEXT_NODE
                .. "\x00\x04text" -- text "text"
                .. "\x03" -- END_ELEMENT child
                .. "\x03" -- END_ELEMENT root
            assert.are.equal(expected, result)
        end)

        it("encodes multiple children in alphabetical key order", function()
            local result = asn1.element("root", {
                beta = "b",
                alpha = "a",
            })
            -- orderedPairs sorts keys alphabetically: alpha, beta
            local expected = "\x01" -- BEGIN_ELEMENT root
                .. "\x00\x00\x00\x04root"
                .. "\x02" -- END_ATTRIBUTES
                .. "\x01" -- BEGIN_ELEMENT alpha
                .. "\x00\x00\x00\x05alpha"
                .. "\x02\x04\x00\x01a\x03" -- TEXT "a" + END
                .. "\x01" -- BEGIN_ELEMENT beta
                .. "\x00\x00\x00\x04beta"
                .. "\x02\x04\x00\x01b\x03" -- TEXT "b" + END
                .. "\x03" -- END_ELEMENT root
            assert.are.equal(expected, result)
        end)

        it("skips xmlns attributes while preserving non-xmlns attributes", function()
            local result = asn1.element("root", {
                _attr = { ["xmlns:foo"] = "http://example.com", bar = "baz" },
            })
            -- Only "bar" attribute should appear (xmlns:foo is skipped)
            local expected = "\x01" -- BEGIN_ELEMENT
                .. "\x00\x00" -- namespace ""
                .. "\x00\x04root" -- tag "root"
                .. "\x05" -- ATTRIBUTE
                .. "\x00\x00" -- attr namespace ""
                .. "\x00\x03bar" -- attr name "bar"
                .. "\x00\x03baz" -- attr value "baz"
                .. "\x02" -- END_ATTRIBUTES
                .. "\x03" -- END_ELEMENT
            assert.are.equal(expected, result)
        end)

        it("encodes full URI as namespace for Adobe-style names", function()
            -- This is how crypto.signXML passes the element name
            local result = asn1.element("http://ns.adobe.com/adept:activate", {
                _attr = { requestType = "initial" },
            })
            -- tag splits on last colon: ns="http://ns.adobe.com/adept" name="activate"
            local ADEPT = "http://ns.adobe.com/adept"
            local expected = "\x01"
                .. "\x00\x19"
                .. ADEPT -- namespace (length 25)
                .. "\x00\x08activate" -- tag (length 8)
                .. "\x05" -- ATTRIBUTE
                .. "\x00\x00" -- attr namespace ""
                .. "\x00\x0BrequestType" -- attr name (length 11)
                .. "\x00\x07initial" -- attr value (length 7)
                .. "\x02" -- END_ATTRIBUTES
                .. "\x03" -- END_ELEMENT
            assert.are.equal(expected, result)
        end)
    end)
end)

describe("ASN.1 table encoder conformance", function()
    local ADEPT = "http://ns.adobe.com/adept"
    local adobehash, asn1, dom, util, xml

    setup(function()
        adobehash = require("adobe.util.adobehash")
        asn1 = require("adobe.util.asn1")
        dom = require("adobe.util.dom")
        util = require("adobe.util.util")
        xml = require("adobe.util.xml")
    end)

    local function encodeSerialized(xml_string)
        local document = dom.parse(xml_string)
        local root = dom.firstElementChild(document)
        local buf = {}
        adobehash.buildHashBuffer(root, {}, buf)
        return table.concat(buf)
    end

    local function compareTableAndSerialized(payload)
        local signing_payload = xml.addNamespace(util.deepTableCopy(payload), ADEPT, ADEPT)
        local table_encoded = asn1.element(ADEPT .. ":activate", signing_payload)

        local wire_payload = xml.addNamespace(util.deepTableCopy(payload), "adept", ADEPT)
        local serialized = xml.serialize(wire_payload, "adept:activate")
        assert.are.equal(encodeSerialized(serialized), table_encoded)
    end

    it("matches the DOM encoder for an activation-shaped request", function()
        compareTableAndSerialized({
            _attr = { requestType = "initial" },
            user = "urn:uuid:test-user",
            fingerprint = "abc123",
            deviceType = "standalone",
            targetDevice = {
                clientLocale = "en",
                clientOS = "Linux",
                deviceType = "standalone",
            },
        })
    end)

    it("matches the DOM encoder when long text requires chunking", function()
        compareTableAndSerialized({
            _attr = { requestType = "initial" },
            data = string.rep("x", 0x7FFF) .. "y",
        })
    end)
end)

describe("asn1.element negative cases", function()
    local asn1

    setup(function()
        asn1 = require("adobe.util.asn1")
    end)

    it("throws on nil content", function()
        assert.has.errors(function()
            asn1.element("root", nil)
        end)
    end)

    it("throws on non-string/table content (number)", function()
        assert.has.errors(function()
            asn1.element("root", 42)
        end)
    end)

    it("throws on non-string/table content (boolean)", function()
        assert.has.errors(function()
            asn1.element("root", true)
        end)
    end)

    it("throws on nil element name", function()
        assert.has.errors(function()
            asn1.element(nil, "text")
        end)
    end)

    it("handles empty table content (no crash, produces empty element)", function()
        local result = asn1.element("root", {})
        -- BEGIN + tag + END_ATTRS + END
        assert.is.truthy(result:find("root"))
    end)

    it("handles empty string content", function()
        local result = asn1.element("root", "")
        assert.is.truthy(#result > 0)
    end)

    it("handles unicode values correctly", function()
        local result = asn1.element("root", { child = "日本語テスト" })
        assert.is.truthy(result:find("日本語テスト"))
    end)

    it("handles deeply nested tables", function()
        local result = asn1.element("root", {
            a = { b = { c = "deep" } },
        })
        assert.is.truthy(result:find("deep"))
    end)

    it("handles strings longer than 255 bytes", function()
        local longstr = string.rep("x", 300)
        local result = asn1.element("root", longstr)
        assert.is.truthy(#result > 300)
    end)
end)

describe("crypto.signXML", function()
    local crypto, asn1, nc, util

    setup(function()
        crypto = require("adobe.util.crypto")
        asn1 = require("adobe.util.asn1")
        nc = require("adobe.util.nativecrypto")
        util = require("adobe.util.util")
    end)

    -- Helper: crypto.key.new() creates a wrapper with .pkey;
    -- crypto.signXML expects the raw PKey (which has :sign_raw)
    local function makeKey()
        return crypto.key.new().pkey
    end

    it("produces a deterministic base64 signature for same key + input", function()
        local key = makeKey()
        local function makeTb()
            return { _attr = { method = "bar" }, child = "hello" }
        end
        local name = "http://ns.adobe.com/adept:signIn"

        local sig1 = crypto.signXML(name, key, makeTb())
        local sig2 = crypto.signXML(name, key, makeTb())
        assert.are.equal(sig1, sig2)

        -- Should be valid base64
        local decoded = util.base64.decode(sig1)
        -- 1024-bit RSA key produces 128-byte signatures
        assert.are.equal(128, #decoded)
    end)

    it("matches manual ASN.1 → SHA-1 → RSA sign pipeline", function()
        local key = makeKey()
        local function makeTb()
            return {
                _attr = { requestType = "initial" },
                fingerprint = "abc123def456",
            }
        end
        local name = "http://ns.adobe.com/adept:activate"

        local sig_b64 = crypto.signXML(name, key, makeTb())

        -- Manually reproduce what signXML does
        local tb = makeTb()
        local encoded = asn1.element(name, tb)
        local hash = assert(nc.sha1(encoded))
        local expected_sig = util.base64.encode(key:sign_raw(hash, nc.RSA_PKCS1_PADDING))

        assert.are.equal(expected_sig, sig_b64)
    end)

    it("different inputs produce different signatures", function()
        local key = makeKey()
        local function makeTb(val)
            return { _attr = { method = "test" }, data = val }
        end

        local sig_a = crypto.signXML("ns:root", key, makeTb("aaa"))
        local sig_b = crypto.signXML("ns:root", key, makeTb("bbb"))
        assert.is_not.equal(sig_a, sig_b)
    end)
end)

describe("crypto.signXML negative cases", function()
    local crypto

    setup(function()
        crypto = require("adobe.util.crypto")
    end)

    local function makeKey()
        return crypto.key.new().pkey
    end

    it("throws on nil key", function()
        assert.has.errors(function()
            crypto.signXML("name", nil, { _attr = {} })
        end)
    end)

    it("throws on string key (wrong type)", function()
        assert.has.errors(function()
            crypto.signXML("name", "not-a-key", { _attr = {} })
        end)
    end)

    it("throws on crypto.key wrapper instead of raw pkey", function()
        local wrapper = crypto.key.new()
        assert.has.errors(function()
            crypto.signXML("name", wrapper, { _attr = {} })
        end)
    end)

    it("throws on nil element name", function()
        local key = makeKey()
        assert.has.errors(function()
            crypto.signXML(nil, key, { _attr = {} })
        end)
    end)

    it("throws on nil table", function()
        local key = makeKey()
        assert.has.errors(function()
            crypto.signXML("name", key, nil)
        end)
    end)

    it("succeeds with empty table (no _attr, no children)", function()
        local key = makeKey()
        local sig = crypto.signXML("name", key, {})
        assert.is.truthy(sig)
        assert.is.truthy(#sig > 0)
    end)
end)
