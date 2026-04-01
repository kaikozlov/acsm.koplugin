-- Direct ASN.1 canonical hasher that operates on parsed xml2lua tables
-- with proper namespace context tracking (mirrors Python's hash_node_ctx)

local directHash = {}

local ASN_NS_TAG = 1
local ASN_CHILD = 2
local ASN_END_TAG = 3
local ASN_TEXT = 4
local ASN_ATTRIBUTE = 5

local ADEPT = "http://ns.adobe.com/adept"
local DC = "http://purl.org/dc/elements/1.1/"

function directHash.hashTree(root, skipHmacSig)
    local buf = {}

    local function appendTag(tag)
        buf[#buf+1] = string.char(tag)
    end

    local function appendString(str)
        local len = #str
        buf[#buf+1] = string.char(math.floor(len / 256))
        buf[#buf+1] = string.char(len % 256)
        buf[#buf+1] = str
    end

    local function hashNode(key, value, nsMap)
        -- Check if this element has its own xmlns declaration
        -- In XML, an element's namespace is determined by its own xmlns first
        local ownNs = nil
        if type(value) == "table" and value._attr then
            if value._attr.xmlns then
                ownNs = value._attr.xmlns
            end
        end

        -- Resolve namespace for this element
        local ns, localname
        local colonPos = key:find(":")
        if colonPos then
            local prefix = key:sub(1, colonPos - 1)
            localname = key:sub(colonPos + 1)
            ns = nsMap[prefix] or ""
        else
            localname = key
            -- Use own xmlns if present, otherwise parent's default namespace
            ns = ownNs or nsMap[""] or ""
        end

        -- Skip hmac/signature in adept namespace
        if skipHmacSig and ns == ADEPT and (localname == "hmac" or localname == "signature") then
            return
        end

        appendTag(ASN_NS_TAG)
        appendString(ns)
        appendString(localname)

        if type(value) == "string" then
            appendTag(ASN_CHILD)
            appendTag(ASN_TEXT)
            appendString(value)
        elseif type(value) == "table" then
            -- Build new namespace map from this element's xmlns declarations
            local childNsMap = {}
            for k, v in pairs(nsMap) do childNsMap[k] = v end

            if value._attr then
                for ak, av in pairs(value._attr) do
                    if ak == "xmlns" then
                        childNsMap[""] = av
                    elseif ak:find("^xmlns:") then
                        local prefix = ak:sub(6)
                        childNsMap[prefix] = av
                    end
                end
            end

            -- Hash attributes (sorted, excluding xmlns)
            local attrs = {}
            if value._attr then
                for ak, av in pairs(value._attr) do
                    if not ak:find("^xmlns") then
                        attrs[#attrs+1] = {ak, av}
                    end
                end
            end
            table.sort(attrs, function(a, b) return a[1] < b[1] end)
            for _, attr in ipairs(attrs) do
                appendTag(ASN_ATTRIBUTE)
                local attrColon = attr[1]:find(":")
                if attrColon then
                    local attrPrefix = attr[1]:sub(1, attrColon - 1)
                    local attrLocal = attr[1]:sub(attrColon + 1)
                    appendString(childNsMap[attrPrefix] or "")
                    appendString(attrLocal)
                else
                    appendString("")
                    appendString(attr[1])
                end
                appendString(attr[2])
            end

            appendTag(ASN_CHILD)

            -- Hash text content (xml2lua stores as numeric key)
            for k, v in pairs(value) do
                if type(k) == "number" and type(v) == "string" then
                    appendTag(ASN_TEXT)
                    appendString(v)
                end
            end

            -- Hash child elements (sorted alphabetically)
            local children = {}
            for k, v in pairs(value) do
                if type(k) == "string" and k ~= "_attr" then
                    children[#children+1] = {k, v}
                end
            end
            table.sort(children, function(a, b) return a[1] < b[1] end)
            for _, child in ipairs(children) do
                hashNode(child[1], child[2], childNsMap)
            end
        end

        appendTag(ASN_END_TAG)
    end

    -- Hash the root element
    -- For the fulfill request, root key is "adept:fulfill"
    hashNode("adept:fulfill", root, {["adept"] = ADEPT, ["dc"] = DC})

    return table.concat(buf)
end

return directHash
