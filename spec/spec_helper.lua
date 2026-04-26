--- spec_helper.lua
-- Sets up mocks for KOReader framework modules so that the plugin's
-- adobe/* modules can be loaded and tested outside the KOReader runtime.

local lfs = require("lfs")

local TEST_DATA_DIR = "/tmp/acsm-test-" .. os.time()

-- Ensure test data dir exists
lfs.mkdir(TEST_DATA_DIR)

---------------------------------------------------------------------
-- Mock: logger
---------------------------------------------------------------------
package.preload["logger"] = function()
    local noop = function() end
    return {
        info  = noop,
        warn  = noop,
        dbg   = noop,
        err   = noop,
        setLevel = noop,
        levels = { warn = 1, info = 2, dbg = 3 },
    }
end

---------------------------------------------------------------------
-- Mock: datastorage
---------------------------------------------------------------------
package.preload["datastorage"] = function()
    return {
        getDataDir = function() return TEST_DATA_DIR end,
        getSettingsDir = function() return TEST_DATA_DIR end,
    }
end

---------------------------------------------------------------------
-- Mock: libs/libkoreader-lfs  →  real luafilesystem
---------------------------------------------------------------------
package.preload["libs/libkoreader-lfs"] = function()
    return lfs
end

---------------------------------------------------------------------
-- Mock: util  (KOReader's frontend/util.lua)
-- Provides the subset of functions used by our plugin.
---------------------------------------------------------------------
package.preload["util"] = function()
    local util = {}

    function util.readFromFile(filepath, mode)
        if not filepath then return end
        local file, err = io.open(filepath, mode)
        if not file then return nil, err end
        local data = file:read("*a")
        file:close()
        return data
    end

    function util.writeToFile(data, filepath)
        if not filepath then return end
        local file, err = io.open(filepath, "wb")
        if not file then return nil, err end
        file:write(data)
        file:close()
        return true
    end

    function util.makePath(path)
        if lfs.attributes(path, "mode") == "directory" then
            return true
        end
        local components
        if path:sub(1, 1) == "/" then
            components = "/"
        else
            components = ""
        end
        for component in path:gmatch("([^/]+)") do
            components = components .. component .. "/"
            if lfs.attributes(components, "mode") == nil then
                local ok, err = lfs.mkdir(components)
                if not ok then
                    return nil, err
                end
            end
        end
        return true
    end

    function util.getFileNameSuffix(file)
        if not file or file == "" then return "" end
        return file:match("%.([^%.]+)$") or ""
    end

    function util.pathExists(path)
        return lfs.attributes(path, "mode") ~= nil
    end

    function util.splitFilePathName(file)
        if file == nil or file == "" then return "", "" end
        if not file:find("/") then return "", file end
        return file:match("(.*/)(.*)") 
    end

    return util
end

---------------------------------------------------------------------
-- Mock: ffi/util
---------------------------------------------------------------------
package.preload["ffi/util"] = function()
    return {
        template = function(s, ...) return s end,
        orderedPairs = pairs,
    }
end

---------------------------------------------------------------------
-- Mock: ffi.sha2  (base64 helpers used by adobe.util.util)
---------------------------------------------------------------------
package.preload["ffi.sha2"] = function()
    -- Minimal base64 encode/decode for tests
    local b64chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

    local function base64_encode(data)
        local result = {}
        local pad = ""
        local len = #data
        if len % 3 == 1 then
            data = data .. "\0\0"
            pad = "=="
        elseif len % 3 == 2 then
            data = data .. "\0"
            pad = "="
        end
        for i = 1, #data, 3 do
            local a, b, c = data:byte(i, i + 2)
            local n = a * 65536 + b * 256 + c
            local c1 = math.floor(n / 262144) % 64
            local c2 = math.floor(n / 4096) % 64
            local c3 = math.floor(n / 64) % 64
            local c4 = n % 64
            result[#result + 1] = b64chars:sub(c1 + 1, c1 + 1)
                .. b64chars:sub(c2 + 1, c2 + 1)
                .. b64chars:sub(c3 + 1, c3 + 1)
                .. b64chars:sub(c4 + 1, c4 + 1)
        end
        local encoded = table.concat(result)
        if pad ~= "" then
            encoded = encoded:sub(1, -(#pad + 1)) .. pad
        end
        return encoded
    end

    local function base64_decode(data)
        data = data:gsub("[^A-Za-z0-9+/=]", "")
        local result = {}
        local pad = data:match("(=*)$")
        data = data:gsub("=", "A")
        for i = 1, #data, 4 do
            local c1, c2, c3, c4
            c1 = b64chars:find(data:sub(i, i)) - 1
            c2 = b64chars:find(data:sub(i + 1, i + 1)) - 1
            c3 = b64chars:find(data:sub(i + 2, i + 2)) - 1
            c4 = b64chars:find(data:sub(i + 3, i + 3)) - 1
            local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
            result[#result + 1] = string.char(
                math.floor(n / 65536) % 256,
                math.floor(n / 256) % 256,
                n % 256
            )
        end
        local decoded = table.concat(result)
        if #pad > 0 then
            decoded = decoded:sub(1, -(#pad + 1))
        end
        return decoded
    end

    return {
        bin2base64 = base64_encode,
        base642bin = base64_decode,
        bin_to_base64 = base64_encode,
        base64_to_bin = base64_decode,
    }
end

---------------------------------------------------------------------
-- Mock: ffi/loadlib  (no-op, only needed on device)
---------------------------------------------------------------------
package.preload["ffi/loadlib"] = function()
    return {}
end

---------------------------------------------------------------------
-- Mock: socket  (LuaSocket — stub for fulfillment.lua)
---------------------------------------------------------------------
package.preload["socket"] = function()
    return {
        tcp = function() return {} end,
        skip = function(n, ...) return select(n, ...) end,
    }
end

---------------------------------------------------------------------
-- Mock: socket.http
---------------------------------------------------------------------
package.preload["socket.http"] = function()
    return {
        request = function() return nil, "mock" end,
        USERAGENT = "mock-ua",
        TIMEOUT = 60,
    }
end

---------------------------------------------------------------------
-- Mock: socket.url
---------------------------------------------------------------------
package.preload["socket.url"] = function()
    return {
        parse = function(u)
            return { scheme = "https", host = "mock", path = "/mock", url = u }
        end,
        build = function(t)
            return t.url or "https://mock/mock"
        end,
    }
end

---------------------------------------------------------------------
-- Mock: ssl.https
---------------------------------------------------------------------
package.preload["ssl.https"] = function()
    return { TIMEOUT = 60 }
end

---------------------------------------------------------------------
-- Mock: ltn12
---------------------------------------------------------------------
package.preload["ltn12"] = function()
    return {
        source = { string = function(s) return function() return nil end end },
        sink = { table = function(t) return function() return 1 end, t end },
    }
end

---------------------------------------------------------------------
-- Mock: socketutil
---------------------------------------------------------------------
package.preload["socketutil"] = function()
    return {
        set_timeout = function() end,
        reset_timeout = function() end,
        table_sink = function(t) return function() return 1 end, t end,
        file_sink = function(h) return function() return 1 end end,
        USER_AGENT = "mock-ua",
        FILE_BLOCK_TIMEOUT = 15,
        FILE_TOTAL_TIMEOUT = 60,
    }
end

---------------------------------------------------------------------
-- Mock: ffi/archiver  (stub for tests that don't need real zip I/O)
---------------------------------------------------------------------
package.preload["ffi/archiver"] = function()
    local Reader = {}
    Reader.__index = Reader
    function Reader:new() return setmetatable({}, self) end
    function Reader:open() return true end
    function Reader:iterate() return function() return nil end end
    function Reader:extractToPath() return true end
    function Reader:extractToMemory() return "" end
    function Reader:close() end

    local Writer = {}
    Writer.__index = Writer
    function Writer:new() return setmetatable({}, self) end
    function Writer:open() return true end
    function Writer:setZipCompression() return true end
    function Writer:addFileFromMemory() return true end
    function Writer:addPath() return true end
    function Writer:close() end

    return { Reader = Reader, Writer = Writer }
end

---------------------------------------------------------------------
-- Helpers for tests
---------------------------------------------------------------------
-- Clean up test data dir on exit (best-effort)
local function removeTreeHelper(path)
    if not path or lfs.attributes(path, "mode") ~= "directory" then return end
    for entry in lfs.dir(path) do
        if entry ~= "." and entry ~= ".." then
            local child = path .. "/" .. entry
            local mode = lfs.attributes(child, "mode")
            if mode == "directory" then
                removeTreeHelper(child)
            else
                os.remove(child)
            end
        end
    end
    lfs.rmdir(path)
end

-- Export for use in specs
_G.TEST_DATA_DIR = TEST_DATA_DIR
_G.cleanupTestDir = function()
    removeTreeHelper(TEST_DATA_DIR)
end
