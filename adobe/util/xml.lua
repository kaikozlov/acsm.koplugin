-- light wrapper around xml2lua, providing a simple interface

local xml = {}

-- load required modules
local xml2lua = require("xml2lua")
local treehandler = require("xmlhandler.tree")
local crypto = require("adobe.util.crypto")
local util = require("adobe.util.util")

-- add an xml namespace to the table
function xml.addNamespace(tb, prefix, namespace)
    tb._attr["xmlns:" .. prefix] = namespace
    local newtable = {}
    for k, v in pairs(tb) do
        if k ~= "_attr" then
            -- FIXME: this is a hack to make sure that the namespace is added to the children of the tag
            if type(v) == "table" then
                newv = {}
                for j, i in pairs(v) do
                    if j ~= "_attr" then
                        j = prefix .. ":" .. j
                    end
                    newv[j] = i
                end
                v = newv
            end
            k = prefix .. ":" .. k
        end
        newtable[k] = v
    end
    return newtable
end

-- serialize a table into an XML string
function xml.serialize(table, name)
    local name = name or ""
    return xml2lua.toXml(table, name)
end

-- add the xml version header to the string
function xml.addHeader(string)
    return "<?xml version=\"1.0\"?>\n" .. string
end

-- shorthand for creating an xml request for adobe
function xml.adobe(tb, name)
    tb = xml.addNamespace(tb, "adept", "http://ns.adobe.com/adept")
    tb = xml.serialize(tb, "adept:" .. name)
    tb = xml.addHeader(tb)
    return tb
end

-- shorthand for creating a sign xml request for adobe
function xml.adobeSigned(name, pkey, tb)
    -- make a temporary copy of the table to avoid modifying the original
    local tosign = xml.addNamespace(util.deepTableCopy(tb), "http://ns.adobe.com/adept", "http://ns.adobe.com/adept")
    tb.signature = crypto.signXML("http://ns.adobe.com/adept:" .. name, pkey, tosign)
    tb = xml.addNamespace(tb, "adept", "http://ns.adobe.com/adept")
    tb = xml.serialize(tb, "adept:" .. name)
    tb = xml.addHeader(tb)
    return tb
end

-- deserialize an XML string into a table
function xml.deserialize(string)
    local handler = treehandler:new()
    local parser = xml2lua.parser(handler)
    parser:parse(string)
    return handler.root
end

return xml
