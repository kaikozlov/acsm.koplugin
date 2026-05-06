--- Integration tests: Adobe hash buffer construction and digest (P1)
-- Verifies buildHashBuffer and digest (extracted from fulfillment.lua).
-- These are pure logic: parse XML → build ASN.1-like hash buffer → SHA-1 digest.

describe("Adobe hash buffer (adobehash)", function()
    local adobehash, dom

    setup(function()
        adobehash = require("adobe.util.adobehash")
        dom = require("adobe.util.dom")
    end)

    describe("buildHashBuffer", function()
        it("encodes a simple element with text content", function()
            local xmlStr = '<root>Hello</root>'
            local doc = dom.parse(xmlStr)
            local root = dom.firstElementChild(doc)
            local buf = {}
            adobehash.buildHashBuffer(root, {}, buf)
            local result = table.concat(buf)

            -- Expected: NS_TAG + ns("") + name("root") + CHILD + TEXT("Hello") + END_TAG
            local expected = "\x01"            -- NS_TAG
                .. "\x00\x00"                   -- namespace "" (length 0)
                .. "\x00\x04root"              -- local name "root" (length 4)
                .. "\x02"                       -- CHILD
                .. "\x04"                       -- TEXT
                .. "\x00\x05Hello"             -- text content (length 5)
                .. "\x03"                       -- END_TAG
            assert.are.equal(expected, result)
        end)

        it("encodes attributes sorted alphabetically", function()
            local xmlStr = '<root beta="2" alpha="1"><child>text</child></root>'
            local doc = dom.parse(xmlStr)
            local root = dom.firstElementChild(doc)
            local buf = {}
            adobehash.buildHashBuffer(root, {}, buf)
            local result = table.concat(buf)

            -- Attributes sorted: alpha, beta
            -- alpha has no prefix → ns="" name="alpha"
            -- beta has no prefix → ns="" name="beta"
            local expected = "\x01"            -- NS_TAG
                .. "\x00\x00\x00\x04root"     -- namespace + name
                .. "\x05"                       -- ATTRIBUTE
                .. "\x00\x00\x00\x05alpha"    -- attr ns + name
                .. "\x00\x011"                 -- attr value "1"
                .. "\x05"                       -- ATTRIBUTE
                .. "\x00\x00\x00\x04beta"     -- attr ns + name
                .. "\x00\x012"                 -- attr value "2"
                .. "\x02"                       -- CHILD
                .. "\x01"                       -- NS_TAG for child
                .. "\x00\x00\x00\x05child"
                .. "\x02"                       -- CHILD
                .. "\x04\x00\x04text"          -- TEXT "text"
                .. "\x03"                       -- END_TAG child
                .. "\x03"                       -- END_TAG root
            assert.are.equal(expected, result)
        end)

        it("resolves namespaced elements and attributes", function()
            local xmlStr = '<adept:signIn xmlns:adept="http://ns.adobe.com/adept" method="bar"></adept:signIn>'
            local doc = dom.parse(xmlStr)
            local root = dom.firstElementChild(doc)
            local nsMap = dom.nsMapFor(root)
            local buf = {}
            adobehash.buildHashBuffer(root, nsMap, buf)
            local result = table.concat(buf)

            -- Element: ns="http://ns.adobe.com/adept" name="signIn"
            -- Attribute "method": no prefix → ns="" name="method"
            local ADEPT = "http://ns.adobe.com/adept"
            local expected = "\x01"
                .. "\x00\x19" .. ADEPT         -- namespace (length 25)
                .. "\x00\x06signIn"            -- name (length 6)
                .. "\x05"                       -- ATTRIBUTE
                .. "\x00\x00"                   -- attr ns ""
                .. "\x00\x06method"            -- attr name
                .. "\x00\x03bar"               -- attr value
                .. "\x02"                       -- CHILD
                .. "\x03"                       -- END_TAG
            assert.are.equal(expected, result)
        end)

        it("skips adept:signature and adept:hmac elements", function()
            local xmlStr = [[
                <root xmlns:adept="http://ns.adobe.com/adept">
                    <adept:data>payload</adept:data>
                    <adept:signature>should-be-skipped</adept:signature>
                    <adept:hmac>also-skipped</adept:hmac>
                </root>
            ]]
            local doc = dom.parse(xmlStr)
            local root = dom.firstElementChild(doc)
            local nsMap = dom.nsMapFor(root)
            local buf = {}
            adobehash.buildHashBuffer(root, nsMap, buf)
            local result = table.concat(buf)

            -- Should contain "data" but NOT "signature" or "hmac"
            assert.is.truthy(result:find("data"))
            assert.is_nil(result:find("should%-be%-skipped"))
            assert.is_nil(result:find("also%-skipped"))
        end)

        it("skips xmlns attributes", function()
            local xmlStr = '<root xmlns:foo="http://example.com" id="123"></root>'
            local doc = dom.parse(xmlStr)
            local root = dom.firstElementChild(doc)
            local buf = {}
            adobehash.buildHashBuffer(root, {}, buf)
            local result = table.concat(buf)

            -- Should contain id="123" but NOT xmlns:foo
            assert.is.truthy(result:find("id"))
            assert.is.truthy(result:find("123"))
            -- The namespace URI should NOT appear as an attribute
            assert.is_nil(result:find("http://example.com"))
        end)

        it("trims whitespace from text nodes", function()
            local xmlStr = '<root>  hello world  </root>'
            local doc = dom.parse(xmlStr)
            local root = dom.firstElementChild(doc)
            local buf = {}
            adobehash.buildHashBuffer(root, {}, buf)
            local result = table.concat(buf)

            -- Text should be trimmed to "hello world"
            assert.is.truthy(result:find("hello world"))
            -- Should NOT contain leading/trailing spaces around the text
            -- The text is encoded as ASN_TEXT with length-prefixed string
            -- "hello world" = 11 bytes → \x00\x0Bhello world
            assert.is.truthy(result:find("\x00\x0Bhello world"))
        end)
    end)

    describe("digest", function()
        it("produces a 20-byte SHA-1 hash from XML", function()
            local xmlStr = '<?xml version="1.0"?><root><child>test</child></root>'
            local hash, err = adobehash.digest(xmlStr)
            assert.is_nil(err)
            assert.are.equal(20, #hash)
        end)

        it("is deterministic for the same XML", function()
            local xmlStr = '<?xml version="1.0"?><root><data>payload</data></root>'
            local hash1 = assert(adobehash.digest(xmlStr))
            local hash2 = assert(adobehash.digest(xmlStr))
            assert.are.equal(hash1, hash2)
        end)

        it("produces different hashes for different XML", function()
            local hash_a = assert(adobehash.digest('<root><data>a</data></root>'))
            local hash_b = assert(adobehash.digest('<root><data>b</data></root>'))
            assert.is_not.equal(hash_a, hash_b)
        end)

        it("handles invalid input gracefully", function()
            -- dom.parse may throw on invalid XML; digest should either
            -- return nil+err or let the error propagate (caller's responsibility)
            local ok, hash, err = pcall(adobehash.digest, '<invalid')
            if ok then
                assert.is_nil(hash)
                assert.is.truthy(err)
            end
            -- If pcall caught an error, that's also acceptable
        end)

        it("excludes signature from digest calculation", function()
            local xmlWithSig = '<root xmlns:adept="http://ns.adobe.com/adept"><adept:data>payload</adept:data><adept:signature>ABC123==</adept:signature></root>'
            local xmlNoSig = '<root xmlns:adept="http://ns.adobe.com/adept"><adept:data>payload</adept:data></root>'
            local hash_with = assert(adobehash.digest(xmlWithSig))
            local hash_without = assert(adobehash.digest(xmlNoSig))
            -- The signature element should be excluded from hash computation
            assert.are.equal(hash_with, hash_without)
        end)
    end)
end)
