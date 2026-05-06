-- Dump per-stream hashes from Lua's actual decryptor.
local pdfdoc = require("adobe.pdf.pdfdoc")
local pdfcrypt = require("adobe.pdf.pdfcrypt")
local rc4 = require("adobe.pdf.rc4")
local zlib = require("adobe.util.zlib")

local sha2 = require("ffi/sha2")
local function hex_hash(data)
    return sha2.sha256(data):sub(1, 16)
end

local enc_path = "/opt/acsm.koplugin/tools/batch_output/goodbye_summer/encrypted.pdf"
local book_key_hex = "eea140a43b3d81cef1aa0c944f4aa86e"
local book_key = sha2.hex2bin(book_key_hex)

local doc = pdfdoc.PDFDocument:new()
local ok, err = doc:open(enc_path)
assert(ok, "open failed: " .. tostring(err))

-- Set up decipher (same as pdf.lua decrypt)
doc:set_decipher(function(objid, genno, data)
    if type(data) ~= "string" or #data == 0 then return data end
    local key = pdfcrypt.genkey_v2(book_key, objid, genno)
    local state = rc4.init(key)
    return rc4.crypt(state, data)
end)

local ids = doc:allObjids()
local enc_objid = doc.encrypt_objid

local stream_hashes = {}
for _, objid in ipairs(ids) do
    if objid == enc_objid then goto continue end
    local obj = doc:getobj(objid)
    if not obj then goto continue end
    if type(obj) == "table" and obj.dic and obj.rawdata then
        local data = obj:get_decdata()
        if data and #data > 0 then
            stream_hashes[objid] = hex_hash(data)
        else
            stream_hashes[objid] = "EMPTY"
        end
    end
    ::continue::
end

print("Decrypted " .. #stream_hashes .. " streams (enc_objid=" .. tostring(enc_objid) .. ")")
-- Need to count properly
local count = 0
for _ in pairs(stream_hashes) do count = count + 1 end
print("Decrypted " .. count .. " streams (enc_objid=" .. tostring(enc_objid) .. ")")

-- Sort and print
local sorted = {}
for objid, h in pairs(stream_hashes) do sorted[#sorted+1] = objid end
table.sort(sorted)
for _, objid in ipairs(sorted) do
    print(string.format("  %6d -> %s", objid, stream_hashes[objid]))
end

-- Check 5852 and 6120
for _, oid in ipairs({5852, 6120}) do
    local obj = doc:getobj(oid)
    if obj then
        if type(obj) == "table" and obj.dic then
            local data = obj:get_decdata()
            local dlen = data and #data or 0
            print(string.format("\n  SPECIAL %d: STREAM rawdata_len=%d decdata_len=%d hash=%s",
                oid, obj.rawdata and #obj.rawdata or 0, dlen,
                data and #data > 0 and hex_hash(data) or "EMPTY"))
        elseif type(obj) == "table" then
            local keys = {}
            for k, _ in pairs(obj) do
                if type(k) == "string" then keys[#keys+1] = k end
            end
            print(string.format("\n  SPECIAL %d: dict, keys=%s", oid, table.concat(keys, ",")))
        end
    else
        print(string.format("\n  SPECIAL %d: nil", oid))
    end
end

doc:close()
print("\nDONE")
