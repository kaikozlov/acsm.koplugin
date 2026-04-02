local dom = {}

local xml2lua = require("xml2lua")
local domhandler = require("xmlhandler.dom")

function dom.parse(xml_string)
    local handler = domhandler:new()
    handler.options.commentNode = 0
    handler.options.piNode = 0
    handler.options.dtdNode = 0
    handler.options.declNode = 0
    local parser = xml2lua.parser(handler)
    parser:parse(xml_string)
    return handler.root
end

function dom.nsMapFor(node, ns_map)
    local child_ns_map = {}
    for k, v in pairs(ns_map or {}) do
        child_ns_map[k] = v
    end
    for attr_key, attr_value in pairs(node._attr or {}) do
        if attr_key == "xmlns" then
            child_ns_map[""] = attr_value
        else
            local prefix = attr_key:match("^xmlns:(.+)$")
            if prefix then
                child_ns_map[prefix] = attr_value
            end
        end
    end
    return child_ns_map
end

function dom.resolveNodeName(node, ns_map)
    local own_ns = node._attr and node._attr.xmlns or nil
    local prefix, local_name = node._name:match("^(.-):(.+)$")
    if prefix then
        return ns_map[prefix] or "", local_name
    end
    return own_ns or ns_map[""] or "", node._name
end

function dom.firstElement(node, ns_map, local_name, namespace)
    for _, child in ipairs(node._children or {}) do
        if child._type == "ELEMENT" then
            local child_ns_map = dom.nsMapFor(child, ns_map)
            local child_ns, child_name = dom.resolveNodeName(child, ns_map)
            if child_name == local_name and (namespace == nil or child_ns == namespace) then
                return child, child_ns_map
            end
        end
    end
    return nil, nil
end

function dom.textOf(node)
    local parts = {}
    for _, child in ipairs(node._children or {}) do
        if child._type == "TEXT" then
            local trimmed = child._text and child._text:match("^%s*(.-)%s*$") or ""
            if trimmed ~= "" then
                parts[#parts + 1] = trimmed
            end
        end
    end
    return table.concat(parts)
end

function dom.childText(node, ns_map, local_name, namespace)
    local child = dom.firstElement(node, ns_map, local_name, namespace)
    if not child then
        return nil
    end
    return dom.textOf(child)
end

function dom.findDescendant(node, ns_map, local_name, namespace)
    local found, found_ns_map = dom.firstElement(node, ns_map, local_name, namespace)
    if found then
        return found, found_ns_map
    end

    for _, child in ipairs(node._children or {}) do
        if child._type == "ELEMENT" then
            local child_ns_map = dom.nsMapFor(child, ns_map)
            local desc, desc_ns_map = dom.findDescendant(child, child_ns_map, local_name, namespace)
            if desc then
                return desc, desc_ns_map
            end
        end
    end
    return nil, nil
end

function dom.firstElementChild(node)
    if node and node._type == "ELEMENT" then
        return node
    end
    for _, child in ipairs(node._children or {}) do
        if child._type == "ELEMENT" then
            return child
        end
    end
    return nil
end

function dom.xmlEscape(s)
    return (tostring(s)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;")
        :gsub('"', "&quot;"))
end

function dom.serializeNode(node)
    local attrs = {}
    for attr_key, attr_value in pairs(node._attr or {}) do
        attrs[#attrs + 1] = { attr_key, attr_value }
    end
    table.sort(attrs, function(a, b) return a[1] < b[1] end)

    local parts = { "<" .. node._name }
    for _, attr in ipairs(attrs) do
        parts[#parts + 1] = " " .. attr[1] .. '="' .. dom.xmlEscape(attr[2]) .. '"'
    end

    if not node._children or #node._children == 0 then
        parts[#parts + 1] = "/>"
        return table.concat(parts)
    end

    parts[#parts + 1] = ">"
    for _, child in ipairs(node._children) do
        if child._type == "TEXT" then
            parts[#parts + 1] = dom.xmlEscape(child._text or "")
        elseif child._type == "ELEMENT" then
            parts[#parts + 1] = dom.serializeNode(child)
        end
    end
    parts[#parts + 1] = "</" .. node._name .. ">"
    return table.concat(parts)
end

return dom
