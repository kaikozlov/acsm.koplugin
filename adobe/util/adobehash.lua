--- Adobe hash buffer construction for XML signing.
-- Builds the ASN.1-like hash buffer from a parsed DOM tree,
-- then SHA-1 digests it for use in Adobe's XML signature scheme.
--
-- Extracted from fulfillment.lua for testability.

local dom = require("adobe.util.dom")
local nativecrypto = require("adobe.util.nativecrypto")

local ADEPT = "http://ns.adobe.com/adept"

local ASN_NS_TAG = 1
local ASN_CHILD = 2
local ASN_END_TAG = 3
local ASN_TEXT = 4
local ASN_ATTRIBUTE = 5

local function appendHashString(buf, value)
    local len = #value
    buf[#buf + 1] = string.char(math.floor(len / 256))
    buf[#buf + 1] = string.char(len % 256)
    buf[#buf + 1] = value
end

--- Build the Adobe hash buffer from a DOM node.
-- Walks the DOM tree, appending ASN.1-like tokens to `buf`.
-- Skips <adept:hmac> and <adept:signature> elements.
-- @param node   DOM node
-- @param nsMap  namespace map (prefix → URI)
-- @param buf    accumulator table (strings)
local function buildHashBuffer(node, nsMap, buf)
    local childNsMap = dom.nsMapFor(node, nsMap)
    local namespace, localname = dom.resolveNodeName(node, childNsMap)

    if namespace == ADEPT and (localname == "hmac" or localname == "signature") then
        return
    end

    buf[#buf + 1] = string.char(ASN_NS_TAG)
    appendHashString(buf, namespace)
    appendHashString(buf, localname)

    local attrs = {}
    for ak, av in pairs(node._attr or {}) do
        if not ak:match("^xmlns") then
            attrs[#attrs + 1] = { ak = ak, av = av }
        end
    end
    table.sort(attrs, function(a, b) return a.ak < b.ak end)

    for _, attr in ipairs(attrs) do
        buf[#buf + 1] = string.char(ASN_ATTRIBUTE)
        local prefix, attrLocal = attr.ak:match("^(.-):(.+)$")
        if prefix then
            appendHashString(buf, childNsMap[prefix] or "")
            appendHashString(buf, attrLocal)
        else
            appendHashString(buf, "")
            appendHashString(buf, attr.ak)
        end
        appendHashString(buf, attr.av)
    end

    buf[#buf + 1] = string.char(ASN_CHILD)
    for _, child in ipairs(node._children or {}) do
        if child._type == "TEXT" then
            local trimmed = (child._text or ""):match("^%s*(.-)%s*$")
            if trimmed and trimmed ~= "" then
                local offset = 1
                while offset <= #trimmed do
                    local chunk = trimmed:sub(offset, offset + 0x7FFE)
                    buf[#buf + 1] = string.char(ASN_TEXT)
                    appendHashString(buf, chunk)
                    offset = offset + #chunk
                end
            end
        elseif child._type == "ELEMENT" then
            buildHashBuffer(child, childNsMap, buf)
        end
    end

    buf[#buf + 1] = string.char(ASN_END_TAG)
end

--- Compute the Adobe digest (SHA-1 hash of the hash buffer) of an XML string.
-- @param xmlString  well-formed XML string
-- @return 20-byte SHA-1 digest, or nil + error
local function digest(xmlString)
    local document = dom.parse(xmlString)
    local root = dom.firstElementChild(document)
    if not root then
        return nil, "Missing XML root element"
    end

    local buf = {}
    buildHashBuffer(root, {}, buf)

    return nativecrypto.sha1(table.concat(buf))
end

return {
    buildHashBuffer = buildHashBuffer,
    digest = digest,
    appendHashString = appendHashString,
    ADEPT = ADEPT,
}
