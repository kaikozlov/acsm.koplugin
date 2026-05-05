--- Integration tests: DOM/XML parsing
-- Verifies XML namespace resolution, element traversal, and text
-- extraction using the real KOReader XML infrastructure.

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
