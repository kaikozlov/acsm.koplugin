-- FFI declarations cannot be unloaded, so test each order in a fresh KOReader LuaJIT.
local function luajit_bin()
    -- busted-koreader execs /opt/lib/koreader/luajit, so arg[-1] is that interpreter.
    return arg[-1] or os.getenv("LUAJIT") or "/opt/lib/koreader/luajit"
end

local function run_in_fresh_luajit(script, order)
    -- LuaJIT's file:close() does not return the child exit status, so append it.
    local cmd = string.format("%q %q %q 2>&1; echo EXIT:$?", luajit_bin(), script, order)
    local pipe = assert(io.popen(cmd))
    local output = pipe:read("*a") or ""
    pipe:close()
    local body, code = output:match("^(.*)EXIT:(%d+)%s*$")
    assert.is_not_nil(code, "failed to run load-order helper:\n" .. output)
    assert.are.equal(0, tonumber(code), body)
end

describe("zlib plugin load order", function()
    for _, order in ipairs({ "fastdict-first", "acsm-first" }) do
        it("keeps both plugins working with " .. order, function()
            local plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"
            local script = plugin_path .. "/spec/integration/fixtures/zlib_load_order.lua"
            run_in_fresh_luajit(script, order)
        end)
    end
end)
