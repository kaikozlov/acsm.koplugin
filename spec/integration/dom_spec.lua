--- Integration tests: DOM/XML parsing and manipulation (P2)
-- Verifies XML namespace resolution, element traversal, text
-- extraction, serialization round-trips, and deep tree navigation.

describe("DOM parser", function()
    local dom

    setup(function()
        dom = require("adobe.util.dom")
    end)

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

describe("DOM round-trip", function()
    local dom

    setup(function()
        dom = require("adobe.util.dom")
    end)

    it("parse → serializeNode → re-parse preserves structure", function()
        local xmlStr = '<root attr="value"><child>text</child></root>'
        local doc = dom.parse(xmlStr)
        local root = dom.firstElementChild(doc)
        assert.is.truthy(root)

        local serialized = dom.serializeNode(root)
        assert.is.truthy(serialized)

        -- Re-parse the serialized output
        local doc2 = dom.parse(serialized)
        local root2 = dom.firstElementChild(doc2)
        assert.is.truthy(root2)

        -- Verify structure survived round-trip
        local ns_map = dom.nsMapFor(root2)
        local child = dom.firstElement(root2, ns_map, "child")
        assert.is.truthy(child)
        assert.are.equal("text", dom.textOf(child))

        -- Verify attribute survived
        assert.are.equal("value", (root2._attr or {}).attr)
    end)

    it("findDescendant locates deeply nested elements", function()
        local xmlStr = [[
            <root xmlns:adept="http://ns.adobe.com/adept">
                <adept:level1>
                    <adept:level2>
                        <adept:target>found-it</adept:target>
                    </adept:level2>
                </adept:level1>
            </root>
        ]]
        local doc = dom.parse(xmlStr)
        local ns_map = dom.nsMapFor(doc)

        local target, targetNsMap = dom.findDescendant(doc, ns_map, "target", "http://ns.adobe.com/adept")
        assert.is.truthy(target)
        assert.are.equal("found-it", dom.textOf(target))
    end)

    it("serializeNode handles self-closing elements", function()
        local xmlStr = '<root><empty/></root>'
        local doc = dom.parse(xmlStr)
        local root = dom.firstElementChild(doc)
        local serialized = dom.serializeNode(root)

        -- Should contain <empty/> or <empty></empty>
        assert.is.truthy(serialized:find("empty"))
    end)

    it("serializeNode handles mixed text and element children", function()
        local xmlStr = '<root>before<child>inner</child>after</root>'
        local doc = dom.parse(xmlStr)
        local root = dom.firstElementChild(doc)
        local serialized = dom.serializeNode(root)

        -- Both text nodes and child element should appear
        assert.is.truthy(serialized:find("before"))
        assert.is.truthy(serialized:find("inner"))
        assert.is.truthy(serialized:find("after"))
        assert.is.truthy(serialized:find("child"))
    end)

    it("xmlEscape escapes special characters", function()
        assert.are.equal("&amp;", dom.xmlEscape("&"))
        assert.are.equal("&lt;", dom.xmlEscape("<"))
        assert.are.equal("&gt;", dom.xmlEscape(">"))
        assert.are.equal("&quot;", dom.xmlEscape('"'))
        assert.are.equal("a&amp;b&lt;c", dom.xmlEscape("a&b<c"))
    end)

    it("serializeNode escapes attribute values", function()
        local xmlStr = '<root val="a&amp;b"><child/></root>'
        local doc = dom.parse(xmlStr)
        local root = dom.firstElementChild(doc)
        local serialized = dom.serializeNode(root)

        -- The attribute value should be escaped in output
        assert.is.truthy(serialized:find("a&amp;b"))
    end)

    it("namespaces resolve correctly across nested elements", function()
        local xmlStr = [[
            <root xmlns:a="http://a.com" xmlns:b="http://b.com">
                <a:child>
                    <b:grandchild>deep</b:grandchild>
                </a:child>
            </root>
        ]]
        local doc = dom.parse(xmlStr)
        local ns_map = dom.nsMapFor(doc)

        local aChild = dom.firstElement(doc, ns_map, "child", "http://a.com")
        assert.is.truthy(aChild)

        local aNsMap = dom.nsMapFor(aChild, ns_map)
        local bGrand = dom.firstElement(aChild, aNsMap, "grandchild", "http://b.com")
        assert.is.truthy(bGrand)
        assert.are.equal("deep", dom.textOf(bGrand))
    end)
end)
