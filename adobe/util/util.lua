local util = {}

-- load required modules
local base642bin = require("ffi.sha2").base642bin
local bin2base64 = require("ffi.sha2").bin2base64

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

-- Example:
-- for _, k in ipairs(util.sortedKeys(tb)) do
--     print(k, tb[k])
-- end
function util.sortedKeys(tb)
    local keys = {}
    for k in pairs(tb) do
        table.insert(keys, k)
    end

    table.sort(keys)
    return keys
end

local function __genOrderedIndex( t )
    local orderedIndex = {}
    for key in pairs(t) do
        table.insert( orderedIndex, key )
    end
    table.sort( orderedIndex )
    return orderedIndex
end

local function orderedNext(t, state)
    -- Equivalent of the next function, but returns the keys in the alphabetic
    -- order. We use a temporary ordered key table that is stored in the
    -- table being iterated.

    local key = nil
    --print("orderedNext: state = "..tostring(state) )
    if state == nil then
        -- the first time, generate the index
        t.__orderedIndex = __genOrderedIndex( t )
        key = t.__orderedIndex[1]
    else
        -- fetch the next value
        for i = 1,table.getn(t.__orderedIndex) do
            if t.__orderedIndex[i] == state then
                key = t.__orderedIndex[i+1]
            end
        end
    end

    if key then
        return key, t[key]
    end

    -- no more value to return, cleanup
    t.__orderedIndex = nil
    return
end

function util.orderedPairs(t)
    -- Equivalent of the pairs() function on tables. Allows to iterate
    -- in order
    return orderedNext, t, nil
end


return util
