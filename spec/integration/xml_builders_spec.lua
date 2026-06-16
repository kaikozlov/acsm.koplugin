--- Integration tests: XML request builders (P1)
-- Verifies xml.adobe() and xml.adobeSigned() produce well-formed
-- Adobe Adept XML with correct namespaces, headers, and signatures.

local function plain(str, sub)
    return str:find(sub, 1, true)
end

describe("xml.deserialize edge cases", function()
    local xml

    setup(function()
        xml = require("adobe.util.xml")
    end)

    it("returns a table for empty string", function()
        local result = xml.deserialize("")
        assert.is.truthy(type(result) == "table")
    end)

    it("errors on non-XML plain text", function()
        local ok, err = pcall(xml.deserialize, "hello world this is not xml")
        assert.is_false(ok)
        assert.is.truthy(tostring(err):find("Error"))
    end)

    it("errors on truncated XML (unclosed tags)", function()
        local ok, err = pcall(xml.deserialize, "<root><child>")
        assert.is_false(ok)
        assert.is.truthy(tostring(err):find("Incomplete"))
    end)

    it("errors on nil input", function()
        local ok = pcall(xml.deserialize, nil)
        assert.is_false(ok)
    end)

    it("parses well-formed XML into a table tree", function()
        local result = xml.deserialize("<root><child>text</child></root>")
        assert.is.truthy(type(result) == "table")
        assert.is.truthy(result.root)
        assert.are.equal("text", result.root.child)
    end)

    it("handles attributes correctly", function()
        local result = xml.deserialize('<item attr="val">content</item>')
        assert.is.truthy(result.item)
        assert.are.equal("val", result.item._attr.attr)
        assert.are.equal("content", result.item[1])
    end)
end)

describe("XML builders", function()
    local xml, crypto, util

    setup(function()
        xml = require("adobe.util.xml")
        crypto = require("adobe.util.crypto")
        util = require("adobe.util.util")
    end)

    describe("xml.adobe", function()
        it("produces XML with header, adept namespace, and serialized fields", function()
            local result = xml.adobe({
                _attr = { method = "bar" },
                signInData = "test-data",
            }, "signIn")

            -- Must have XML header
            assert.is.truthy(plain(result, '<?xml version="1.0"?>'))

            -- Must have adept namespace
            assert.is.truthy(plain(result, 'xmlns:adept="http://ns.adobe.com/adept"'))

            -- Must have the root element with adept: prefix
            assert.is.truthy(plain(result, "adept:signIn"))

            -- Must have attributes preserved
            assert.is.truthy(plain(result, 'method="bar"'))

            -- Must have child elements with adept: prefix
            assert.is.truthy(plain(result, "adept:signInData"))
            assert.is.truthy(plain(result, "test-data"))
        end)

        it("uses adept: prefix on all child elements", function()
            local result = xml.adobe({
                _attr = {},
                child1 = "val1",
                child2 = "val2",
            }, "test")

            assert.is.truthy(plain(result, "adept:child1"))
            assert.is.truthy(plain(result, "adept:child2"))
            assert.is.truthy(plain(result, "val1"))
            assert.is.truthy(plain(result, "val2"))
        end)
    end)

    describe("xml.adobeSigned", function()
        it("produces XML containing an adept:signature element", function()
            -- crypto.signXML expects raw PKey, not crypto.key wrapper
            local key = crypto.key.new().pkey
            local result = xml.adobeSigned("activate", key, {
                _attr = { requestType = "initial" },
                fingerprint = "abc123",
            })

            -- Must have XML header
            assert.is.truthy(plain(result, '<?xml version="1.0"?>'))

            -- Must have adept namespace
            assert.is.truthy(plain(result, 'xmlns:adept="http://ns.adobe.com/adept"'))

            -- Must have the root element
            assert.is.truthy(plain(result, "adept:activate"))

            -- Must contain a signature element
            assert.is.truthy(plain(result, "adept:signature"))

            -- The signature should be valid base64
            local sig = result:match("<adept:signature>([^<]+)</adept:signature>")
            assert.is.truthy(sig)
            local decoded = util.base64.decode(sig)
            assert.is.truthy(#decoded > 0)

            -- Must have the fingerprint field
            assert.is.truthy(plain(result, "adept:fingerprint"))
            assert.is.truthy(plain(result, "abc123"))
        end)

        it("produces deterministic output for same key + input", function()
            local key = crypto.key.new().pkey

            -- adobeSigned modifies the input table (adds .signature),
            -- so use fresh tables each call
            local function makeTb()
                return {
                    _attr = { requestType = "initial" },
                    data = "test-payload",
                }
            end

            local result1 = xml.adobeSigned("test", key, makeTb())
            local result2 = xml.adobeSigned("test", key, makeTb())

            -- Extract just the signatures for comparison
            local sig1 = result1:match("<adept:signature>([^<]+)</adept:signature>")
            local sig2 = result2:match("<adept:signature>([^<]+)</adept:signature>")
            assert.are.equal(sig1, sig2)
        end)

        it("signature changes when input data changes", function()
            local key = crypto.key.new().pkey

            local result_a = xml.adobeSigned("test", key, {
                _attr = { requestType = "initial" },
                data = "aaa",
            })
            local result_b = xml.adobeSigned("test", key, {
                _attr = { requestType = "initial" },
                data = "bbb",
            })

            local sig_a = result_a:match("<adept:signature>([^<]+)</adept:signature>")
            local sig_b = result_b:match("<adept:signature>([^<]+)</adept:signature>")
            assert.is_not.equal(sig_a, sig_b)
        end)

        it("preserves all original fields in output", function()
            local key = crypto.key.new().pkey
            local result = xml.adobeSigned("activate", key, {
                _attr = { requestType = "initial" },
                fingerprint = "abc",
                deviceType = "standalone",
            })

            assert.is.truthy(plain(result, "adept:fingerprint"))
            assert.is.truthy(plain(result, "adept:deviceType"))
            assert.is.truthy(plain(result, "standalone"))
        end)
    end)
end)
