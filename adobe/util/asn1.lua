--- @module encodes table as ASN.1 DER

local bit = require("bit")
local util = require("adobe.util.util")

local ASN = {
    NONE = 0,
    TEXT_NODE = 4, -- TEXT
    ATTRIBUTE = 5, -- ATTRIBUTE
    END_ATTRIBUTES = 2, -- CHILD
    BEGIN_ELEMENT = 1, -- NS_TAG
    END_ELEMENT = 3, -- END_TAG
}

-- Adobe's XML-signing format chunks text at 0x7FFF bytes. This mirrors
-- adobe.util.adobehash, which signs serialized fulfillment requests.
local TEXT_CHUNK_SIZE = 0x7FFF

function ASN.byte(byte)
    return string.char(byte)
end

function ASN.bytes(bytes)
    local out = ""
    for i, byte in ipairs(bytes) do
        out = out .. ASN.byte(byte)
    end
    return out
end

function ASN.string(str)
    local length = string.len(str)
    assert(length <= 0xFFFF, "ASN.1 string length exceeds 65535 bytes")
    return ASN.bytes({
        math.floor(length / 256), -- upper length byte
        bit.band(length, 0xFF), -- lower length byte
    }) .. str -- contents of string
end

function ASN.text(str)
    if str == "" then
        return ASN.byte(ASN.TEXT_NODE) .. ASN.string(str)
    end

    local out = ""
    local offset = 1
    while offset <= #str do
        local chunk = str:sub(offset, offset + TEXT_CHUNK_SIZE - 1)
        out = out .. ASN.byte(ASN.TEXT_NODE) .. ASN.string(chunk)
        offset = offset + #chunk
    end
    return out
end

function ASN.namespacedTag(namespace, name)
    return ASN.string(namespace) .. ASN.string(name)
end

function ASN.tag(name)
    -- The first capture is greedy, so URI namespaces containing colons split
    -- on the final colon (for example, "http://ns.adobe.com/adept:activate").
    local ns, tag = string.match(name, "(.+):(.+)")
    -- there was no colon, so we just have a tag
    if ns == nil and tag == nil then
        ns = ""
        tag = name
    end
    return ASN.namespacedTag(ns, tag)
end

function ASN.attribute(name, value)
    -- don't add xmlns attributes, as namespaces are fully qualified
    if name == "xmlns" or string.find(name, "^xmlns:") then
        return ""
    end
    return ASN.byte(ASN.ATTRIBUTE) .. ASN.tag(name) .. ASN.string(value)
end

function ASN.element(name, content)
    local content_type = type(content)
    assert(content_type == "string" or content_type == "table", "ASN.1 element content must be a string or table")

    local out = ""
    out = out .. ASN.byte(ASN.BEGIN_ELEMENT)
    out = out .. ASN.tag(name)
    if content_type == "table" and content._attr ~= nil then
        for k, v in util.orderedPairs(content._attr) do
            out = out .. ASN.attribute(k, v)
        end
    end
    out = out .. ASN.byte(ASN.END_ATTRIBUTES)

    if content_type == "string" then
        out = out .. ASN.text(content)
    else
        -- xml2lua represents a leaf with attributes and text as
        -- { _attr = { ... }, "text" }.
        local text = content[1]
        local children = {}
        for k, v in pairs(content) do
            if k ~= "_attr" and type(k) ~= "number" then
                children[k] = v
            end
        end

        if text ~= nil then
            assert(#content == 1 and next(children) == nil, "ASN.1 mixed content is not supported")
            out = out .. ASN.text(tostring(text))
        end

        -- xml2lua.toXml uses the same orderedPairs implementation, so this
        -- order matches the XML sent to Adobe and therefore its signed form.
        for k, v in util.orderedPairs(children) do
            out = out .. ASN.element(k, v)
        end
    end

    out = out .. ASN.byte(ASN.END_ELEMENT)

    return out
end

return ASN
