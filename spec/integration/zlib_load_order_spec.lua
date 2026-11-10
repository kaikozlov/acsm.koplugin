-- FFI declarations cannot be unloaded, so test each order in a fresh KOReader LuaJIT.
describe("zlib plugin load order", function()
    for _, order in ipairs({ "fastdict-first", "acsm-first" }) do
        it("keeps both plugins working with " .. order, function()
            local plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"
            local script = plugin_path .. "/spec/integration/fixtures/zlib_load_order.lua"
            assert.are.equal(0, os.execute(string.format("./luajit %q %q", script, order)))
        end)
    end
end)
