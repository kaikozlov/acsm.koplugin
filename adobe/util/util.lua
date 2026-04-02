local util = {}

local ffiUtil = require("ffi/util")
local sha2 = require("ffi.sha2")

local base642bin = sha2.base642bin or sha2.base64_to_bin
local bin2base64 = sha2.bin2base64 or sha2.bin_to_base64

if not base642bin or not bin2base64 then
    error("ffi.sha2 base64 helpers unavailable")
end

-- light wrappers for more consistent naming
util.base64 = {}
function util.base64.encode(string)
    return bin2base64(string)
end

function util.base64.decode(string)
    return base642bin(string)
end

-- shallow copy a table (why is this not built-in?)
function util.tableShallowCopy(original)
    local copy = {}
    for key, value in pairs(original) do
        copy[key] = value
    end
    return copy
end

-- basic deep copy of a table
function util.deepTableCopy(orig)
    local orig_type = type(orig)
    local copy
    if orig_type == 'table' then
        copy = {}
        for orig_key, orig_value in next, orig, nil do
            copy[util.deepTableCopy(orig_key)] = util.deepTableCopy(orig_value)
        end
        setmetatable(copy, util.deepTableCopy(getmetatable(orig)))
    else -- number, string, boolean, etc
        copy = orig
    end
    return copy
end

function util.endpoint(base, path)
    local endpoint = util.tableShallowCopy(base)
    endpoint.path = endpoint.path .. "/" .. path
    return endpoint
end


function util.expiration(minutes)
    local t = os.date("*t")
    t.min = t.min + minutes
    return os.date("!%Y-%m-%dT%H:%M:%SZ", os.time(t))
end

function util.orderedPairs(t)
    return ffiUtil.orderedPairs(t)
end

return util
