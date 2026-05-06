-- Dump Lua objects for debugging — run via busted-koreader
local pdfdoc = require("adobe.pdf.pdfdoc")
local doc = pdfdoc.PDFDocument:new()

local enc_path = "/opt/acsm.koplugin/tools/batch_output/goodbye_summer/encrypted.pdf"
local ok, err = doc:open(enc_path)
assert(ok, "open failed: " .. tostring(err))

-- All objids in range
local ids = doc:allObjids()
print("Total objids: " .. #ids)

local found = {}
for _, id in ipairs(ids) do
    if id >= 6080 and id <= 6130 then found[#found+1] = id end
end
table.sort(found)
print("Objects 6080-6130 (" .. #found .. "): " .. table.concat(found, ", "))

-- Check specific objects
for _, oid in ipairs({5852, 6119, 6120}) do
    local obj = doc:getobj(oid)
    if obj then
        if type(obj) == "table" and obj.dic then
            local keys = {}
            for k, _ in pairs(obj.dic) do
                if type(k) == "string" then keys[#keys+1] = k end
            end
            print(oid .. ": STREAM, keys=" .. table.concat(keys, ",") ..
                " rawdata_len=" .. tostring(obj.rawdata and #obj.rawdata or "nil"))
        elseif type(obj) == "table" then
            local keys = {}
            for k, _ in pairs(obj) do
                if type(k) == "string" then keys[#keys+1] = k end
            end
            print(oid .. ": dict, keys=" .. table.concat(keys, ","))
        else
            print(oid .. ": " .. type(obj))
        end
    else
        print(oid .. ": nil")
    end
end

-- Check ObjStm 6089 children
local obj6089 = doc:getobj(6089)
if obj6089 and type(obj6089) == "table" and obj6089.dic then
    print("\n6089 (ObjStm):")
    print("  N=" .. tostring(obj6089.dic.N or obj6089.dic["n"]))
    print("  First=" .. tostring(obj6089.dic.First or obj6089.dic["first"]))
end

-- What about 6118?
local obj6118 = doc:getobj(6118)
print("\n6118: " .. (obj6118 and type(obj6118) or "nil"))

doc:close()
print("\nDONE")
