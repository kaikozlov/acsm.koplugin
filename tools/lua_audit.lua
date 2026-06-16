--- Deep audit: decrypt individual PDF streams and report per-object hashes.
--- Compares against tools/deep_audit.py output.
---
--- Usage inside Docker:
---   just shell
---   cd /opt/lib/koreader
---   luajit /opt/acsm.koplugin/tools/lua_audit.lua <encrypted.pdf> <book_key_hex> <V>

------------------------------------------------------------------------
-- Bootstrap: headless KOReader environment
------------------------------------------------------------------------

package.path = "common/?.lua;frontend/?.lua;" .. package.path
package.cpath = "common/?.so;common/?.dll;/usr/lib/lua/?.so;" .. package.cpath
require("ffi/loadlib")
require("dbg"):turnOff()
local logger = require("logger")
logger:setLevel(logger.levels.warn)

local DataStorage = require("datastorage")
local test_data_dir = "/tmp/koreader-test-audit"
os.execute("mkdir -p " .. test_data_dir)
os.getenv = (function()
    local orig = os.getenv
    return function(key)
        if key == "KO_HOME" then return test_data_dir end
        return orig(key)
    end
end)()
package.loaded["datastorage"] = nil
DataStorage = require("datastorage")
local data_dir = DataStorage:getDataDir()
os.remove(data_dir .. "/defaults.tests.lua")
G_defaults = require("luadefaults"):open(data_dir .. "/defaults.tests.lua")
os.remove(data_dir .. "/settings.tests.lua")
G_reader_settings = require("luasettings"):open(data_dir .. "/settings.tests.lua")
einkfb = require("ffi/framebuffer")
einkfb.dummy = true
local Device = require("device")
Device.screen:init()
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)
Device.input.dummy = true

local plugin_path = "/opt/acsm.koplugin"
package.path = plugin_path .. "/?.lua;" ..
               plugin_path .. "/dependencies/?.lua;" ..
               package.path

------------------------------------------------------------------------
-- Imports
------------------------------------------------------------------------

local lfs = require("libs/libkoreader-lfs")
local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfcrypt = require("adobe.pdf.pdfcrypt")
local nativecrypto = require("adobe.util.nativecrypto")
local sha2 = require("ffi/sha2")

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function hex(s)
    return (s:gsub('.', function(c) return string.format('%02x', c:byte()) end))
end

local function fromHex(h)
    local bytes = {}
    for i = 1, #h, 2 do
        bytes[#bytes+1] = string.char(tonumber(h:sub(i, i+1), 16))
    end
    return table.concat(bytes)
end

local function sha256hex(data)
    return sha2.sha256(data)
end

local function sha256short(data)
    return sha256hex(data):sub(1, 16)
end

------------------------------------------------------------------------
-- Genkey v2 (ADEPT RC4)
------------------------------------------------------------------------

local function genkey_v2(bookKey, objid, genno)
    -- book_key + 3 bytes objid (LE) + 2 bytes genno (LE)
    local key = bookKey:sub(1, 16)
    key = key ..
        string.char(objid % 256) ..
        string.char(math.floor(objid / 256) % 256) ..
        string.char(math.floor(objid / 65536) % 256) ..
        string.char(0) .. string.char(0)
    return key:sub(1, 16)
end

local function rc4(key, data)
    -- Pure Lua RC4 or use nativecrypto
    -- Use nativecrypto rc4 if available
    if nativecrypto.rc4 then
        return nativecrypto.rc4(key, #key, data)
    end

    -- Fallback: pure Lua RC4
    local S = {}
    for i = 0, 255 do S[i] = i end
    local j = 0
    for i = 0, 255 do
        j = (j + S[i] + key:byte((i % #key) + 1)) % 256
        S[i], S[j] = S[j], S[i]
    end
    local i, j = 0, 0
    local result = {}
    for k = 1, #data do
        i = (i + 1) % 256
        j = (j + S[i]) % 256
        S[i], S[j] = S[j], S[i]
        local kk = S[(S[i] + S[j]) % 256]
        result[k] = string.char(bit.bxor(data:byte(k), kk))
    end
    return table.concat(result)
end

local function decryptStreamV2(data, objid, bookKey)
    if #data < 16 then
        return data
    end

    local key = genkey_v2(bookKey, objid, 0)
    local s = data:sub(1, 16)

    -- XOR s with key to get per-object RC4 key
    local obj_key = {}
    for i = 1, 16 do
        obj_key[i] = string.char(bit.bxor(s:byte(i), key:byte(i)))
    end
    obj_key = table.concat(obj_key)

    return rc4(obj_key, data)
end

------------------------------------------------------------------------
-- Main
------------------------------------------------------------------------

local function audit(encPath, bookKeyHex, V)
    local bookKey = fromHex(bookKeyHex)
    V = tonumber(V)

    print(string.format("=== %s ===", encPath:match("([^/]+)$")))
    print(string.format("  Book key: %d bytes, V=%d", #bookKey, V))

    local doc = pdfdoc.PDFDocument:new()
    if not doc:open(encPath) then
        print("  ERROR: cannot open PDF")
        return
    end

    local encFilter = doc:getEncryptionFilter()
    print(string.format("  Filter: %s", encFilter))

    local encParam = doc.encryption.param
    if type(encParam) == "table" and encParam.dic then
        encParam = encParam.dic
    end

    local ebx_V = tonumber(encParam.V or encParam["v"] or 4)
    local ebx_type = tonumber(encParam.EBX_ENCRYPTIONTYPE or encParam["ebx_encryptiontype"] or 6)
    local length = math.floor(tonumber(encParam.Length or encParam["length"] or 128) / 8)
    print(string.format("  V=%d, type=%d, length=%d", ebx_V, ebx_type, length))

    -- Get all object IDs
    local objids = doc:allObjids()
    table.sort(objids)

    print(string.format("  Total objs in xref: %d", #objids))

    local streamCount = 0
    for _, objid in ipairs(objids) do
        if objid <= 0 then goto continue end

        local obj = doc:_loadRawObject(objid)
        if not obj then goto continue end

        -- Check if it's a stream (has rawdata + dic) or a string (raw string obj)
        local is_stream = (type(obj) == "table" and obj.rawdata ~= nil)
        local is_string = (type(obj) == "string" or type(obj) == "bytearray")
        
        if is_stream then
            -- Decrypt the stream
            local data = obj.rawdata
            if type(data) == "table" then
                local parts = {}
                for j = 1, #data do
                    parts[j] = string.char(data[j])
                end
                data = table.concat(parts)
            end

            local decrypted = decryptStreamV2(data, objid, bookKey)
            local h = sha256short(decrypted)
            print(string.format("    obj %6d → %s (stream, %d bytes)", objid, h, #data))
            streamCount = streamCount + 1
        elseif is_string then
            -- Decrypt string objects
            local data = obj
            if type(data) == "table" then
                local parts = {}
                for j = 1, #data do parts[j] = string.char(data[j]) end
                data = table.concat(parts)
            end
            -- For EBX_HANDLER strings, they're not individually encrypted
            -- (only streams are)
        end

        ::continue::
    end

    doc:close()
    print(string.format("  Decrypted %d streams", streamCount))
end

------------------------------------------------------------------------

if arg and #arg >= 3 then
    audit(arg[1], arg[2], arg[3])
elseif ... then
    -- Called via dofile
    audit(...)
else
    print("Usage: luajit lua_audit.lua <encrypted.pdf> <book_key_hex> <V>")
end
