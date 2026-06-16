--- Integration tests: fulfillment.lua internal helpers + stubbed fulfill()
-- Tests collectNotifyUrls, signXmlBody, and the full fulfill() function
-- with stubbed HTTP (canned Adobe server responses).

describe("Fulfillment internals", function()
    local fulfillment, crypto, dom, util

    setup(function()
        fulfillment = require("adobe.fulfillment")
        crypto = require("adobe.util.crypto")
        dom = require("adobe.util.dom")
        util = require("adobe.util.util")
    end)

    -- ================================================================
    -- signXmlBody
    -- ================================================================
    describe("signXmlBody", function()
        it("produces a base64 signature for valid XML", function()
            local keyWrapper = crypto.key.new()
            local signingKey = keyWrapper.pkey
            local xmlStr = '<?xml version="1.0"?><adept:test xmlns:adept="http://ns.adobe.com/adept"><adept:data>hello</adept:data></adept:test>'

            local sig, err = fulfillment._signXmlBody(xmlStr, signingKey)
            assert.is.truthy(sig, "signXmlBody failed: " .. tostring(err))
            -- Should be valid base64
            local decoded = util.base64.decode(sig)
            assert.is.truthy(decoded)
            assert.is_true(#decoded > 0)
        end)

        it("produces deterministic signatures for same input", function()
            local keyWrapper = crypto.key.new()
            local signingKey = keyWrapper.pkey
            local xmlStr = "<test>deterministic</test>"

            local sig1 = fulfillment._signXmlBody(xmlStr, signingKey)
            local sig2 = fulfillment._signXmlBody(xmlStr, signingKey)
            assert.are.equal(sig1, sig2)
        end)

        it("produces different signatures for different inputs", function()
            local keyWrapper = crypto.key.new()
            local signingKey = keyWrapper.pkey

            local sig1 = fulfillment._signXmlBody("<a>one</a>", signingKey)
            local sig2 = fulfillment._signXmlBody("<a>two</a>", signingKey)
            assert.are_not.equal(sig1, sig2)
        end)

        it("produces different signatures for different keys", function()
            local key1 = crypto.key.new().pkey
            local key2 = crypto.key.new().pkey
            local xmlStr = "<same>data</same>"

            local sig1 = fulfillment._signXmlBody(xmlStr, key1)
            local sig2 = fulfillment._signXmlBody(xmlStr, key2)
            assert.are_not.equal(sig1, sig2)
        end)
    end)

    -- ================================================================
    -- collectNotifyUrls
    -- ================================================================
    describe("collectNotifyUrls", function()
        local ADEPT = "http://ns.adobe.com/adept"

        --- Build a DOM tree from XML for testing.
        local function parseDom(xmlStr)
            return dom.parse(xmlStr)
        end

        it("collects notify URLs from fulfillment response", function()
            local xmlStr = [[<?xml version="1.0"?>
<adept:fulfillmentResult xmlns:adept="http://ns.adobe.com/adept">
  <adept:resourceItemInfo>
    <adept:licenseToken>
      <adept:encryptedKey>dGVzdA==</adept:encryptedKey>
    </adept:licenseToken>
  </adept:resourceItemInfo>
  <adept:notify>
    <adept:notifyURL>https://example.com/notify1</adept:notifyURL>
  </adept:notify>
  <adept:notify>
    <adept:notifyURL>https://example.com/notify2</adept:notifyURL>
  </adept:notify>
</adept:fulfillmentResult>]]

            local root = parseDom(xmlStr)
            local nsMap = { adept = ADEPT, [""] = ADEPT }
            local urls = fulfillment._collectNotifyUrls(root, nsMap, {})
            assert.are.equal(2, #urls)
            assert.are.equal("https://example.com/notify1", urls[1])
            assert.are.equal("https://example.com/notify2", urls[2])
        end)

        it("returns empty table when no notify elements", function()
            local xmlStr = [[<?xml version="1.0"?>
<adept:fulfillmentResult xmlns:adept="http://ns.adobe.com/adept">
  <adept:resourceItemInfo>
    <adept:src>https://example.com/book.epub</adept:src>
  </adept:resourceItemInfo>
</adept:fulfillmentResult>]]

            local root = parseDom(xmlStr)
            local nsMap = { adept = ADEPT, [""] = ADEPT }
            local urls = fulfillment._collectNotifyUrls(root, nsMap, {})
            assert.are.same({}, urls)
        end)

        it("skips notify elements with empty URL", function()
            local xmlStr = [[<?xml version="1.0"?>
<adept:fulfillmentResult xmlns:adept="http://ns.adobe.com/adept">
  <adept:notify>
    <adept:notifyURL></adept:notifyURL>
  </adept:notify>
  <adept:notify>
    <adept:notifyURL>https://example.com/valid</adept:notifyURL>
  </adept:notify>
</adept:fulfillmentResult>]]

            local root = parseDom(xmlStr)
            local nsMap = { adept = ADEPT, [""] = ADEPT }
            local urls = fulfillment._collectNotifyUrls(root, nsMap, {})
            assert.are.equal(1, #urls)
            assert.are.equal("https://example.com/valid", urls[1])
        end)

        it("handles node with no children", function()
            local root = { _children = {} }
            local urls = fulfillment._collectNotifyUrls(root, {}, {})
            assert.are.same({}, urls)
        end)
    end)

    -- ================================================================
    -- fulfill (stubbed HTTP)
    -- ================================================================
    describe("fulfill (stubbed HTTP)", function()
        local http_orig
        local koutil

        setup(function()
            koutil = require("util")
        end)

        before_each(function()
            local http = require("socket.http")
            http_orig = http.request
        end)

        after_each(function()
            local http = require("socket.http")
            http.request = http_orig
        end)

        it("parses fulfillment response and extracts fields", function()
            -- Create a temp ACSM file
            local DataStorage = require("datastorage")
            local tmpDir = DataStorage:getDataDir() .. "/test-fulfill-" .. tostring(os.time())
            koutil.makePath(tmpDir)
            local acsmPath = tmpDir .. "/test.acsm"

            local acsmContent = [[<?xml version="1.0"?>
<fulfillmentToken xmlns="http://ns.adobe.com/adept">
  <operatorURL>https://test.example.com/fulfillment</operatorURL>
  <resourceItemInfo>
    <resource>urn:uuid:test-resource</resource>
  </resourceItemInfo>
</fulfillmentToken>]]
            koutil.writeToFile(acsmContent, acsmPath)

            -- Stub HTTP to return a canned fulfillment response.
            -- Real Adobe responses wrap fulfillmentResult in <envelope>.
            -- Without the wrapper, dom.parse returns fulfillmentResult
            -- directly and findDescendant can't find it as its own child.
            local http = require("socket.http")
            http.request = function(req)
                if req.sink then
                    local respXml = [[<?xml version="1.0"?>
<envelope>
<fulfillmentResult xmlns="http://ns.adobe.com/adept">
  <resourceItemInfo>
    <src>https://test.example.com/download/book.epub</src>
    <licenseToken>
      <encryptedKey>dGVzdGtleQ==</encryptedKey>
      <keyType>2</keyType>
      <licenseURL>https://test.example.com/license</licenseURL>
    </licenseToken>
  </resourceItemInfo>
  <notify>
    <notifyURL>https://test.example.com/notify</notifyURL>
  </notify>
</fulfillmentResult>
</envelope>]]
                    req.sink(respXml)
                    req.sink(nil)
                end
                return 1, 200, {}
            end

            local keyWrapper = crypto.key.new()
            local signingKey = keyWrapper.pkey
            local result, err = fulfillment.fulfill(acsmPath, "urn:uuid:test-user", "urn:uuid:test-device", "test-fingerprint", signingKey)

            assert.is.truthy(result, "fulfill failed: " .. tostring(err))
            assert.are.equal("https://test.example.com/fulfillment", result.operatorURL)
            assert.are.equal("https://test.example.com/download/book.epub", result.src)
            assert.are.equal("dGVzdGtleQ==", result.encryptedKey)
            assert.are.equal("2", result.keyType)
            assert.are.equal("https://test.example.com/license", result.licenseURL)
            assert.are.equal(1, #result.notifyURLs)
            assert.are.equal("https://test.example.com/notify", result.notifyURLs[1])
            assert.is.truthy(result.response)
            assert.is.truthy(result.licenseTokenXml)

            os.execute("rm -rf " .. tmpDir)
        end)

        it("returns error for missing fulfillmentToken in ACSM", function()
            local DataStorage = require("datastorage")
            local tmpDir = DataStorage:getDataDir() .. "/test-fulfill-bad-" .. tostring(os.time())
            koutil.makePath(tmpDir)
            local acsmPath = tmpDir .. "/bad.acsm"
            koutil.writeToFile("<notAnAcsm/>", acsmPath)

            local keyWrapper = crypto.key.new()
            local result, err = fulfillment.fulfill(acsmPath, "u", "d", "f", keyWrapper.pkey)
            assert.is_nil(result)
            assert.is.truthy(err)

            os.execute("rm -rf " .. tmpDir)
        end)

        it("returns error for server error response", function()
            local DataStorage = require("datastorage")
            local tmpDir = DataStorage:getDataDir() .. "/test-fulfill-err-" .. tostring(os.time())
            koutil.makePath(tmpDir)
            local acsmPath = tmpDir .. "/test.acsm"

            local acsmContent = [[<?xml version="1.0"?>
<fulfillmentToken xmlns="http://ns.adobe.com/adept">
  <operatorURL>https://test.example.com/fulfillment</operatorURL>
  <resourceItemInfo><resource>urn:uuid:r</resource></resourceItemInfo>
</fulfillmentToken>]]
            koutil.writeToFile(acsmContent, acsmPath)

            local http = require("socket.http")
            http.request = function(req)
                if req.sink then
                    req.sink('<?xml version="1.0"?><error xmlns="http://ns.adobe.com/adept" data="E_ADEPT_INTERNAL Server error"/>')
                    req.sink(nil)
                end
                return 1, 200, {}
            end

            local keyWrapper = crypto.key.new()
            local result, err = fulfillment.fulfill(acsmPath, "u", "d", "f", keyWrapper.pkey)
            assert.is_nil(result)
            assert.is.truthy(err)
            assert.is.truthy(err:find("E_ADEPT_INTERNAL") or err:find("Fulfill error"))

            os.execute("rm -rf " .. tmpDir)
        end)
    end)
end)
