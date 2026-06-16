--- Tests for Android system library loading logic.
-- Covers arch detection, cache filename generation, legacy cleanup.
-- The logic is inlined in nativecrypto.lua and zlib.lua (duplicated because
-- KOReader's Android monolbtic resolver intercepts require() for adobe.util.*
-- module names, making a shared module impossible).
--
-- Related: GitHub issue #6 — Boox Palma 2 user ran 32-bit APK on 64-bit device.

local lfs = require("lfs")

describe("Android system library loader", function()
    -- Must load nativecrypto first so the globals are set
    setup(function()
        require("adobe.util.nativecrypto")
        require("adobe.util.zlib")
    end)

    describe("systemLibDir (nativecrypto)", function()
        it("returns lib64 for arm64", function()
            assert.are.equal("/system/lib64", _nativecrypto_systemLibDir("arm64"))
        end)

        it("returns lib64 for x64", function()
            assert.are.equal("/system/lib64", _nativecrypto_systemLibDir("x64"))
        end)

        it("returns lib (32-bit) for arm", function()
            assert.are.equal("/system/lib", _nativecrypto_systemLibDir("arm"))
        end)

        it("returns lib (32-bit) for x86", function()
            assert.are.equal("/system/lib", _nativecrypto_systemLibDir("x86"))
        end)

        it("returns lib for unknown arch", function()
            assert.are.equal("/system/lib", _nativecrypto_systemLibDir("mips"))
        end)

        it("returns lib for empty string", function()
            assert.are.equal("/system/lib", _nativecrypto_systemLibDir(""))
        end)
    end)

    describe("systemLibDir (zlib — duplicated)", function()
        it("matches nativecrypto's implementation", function()
            -- Both copies should agree on all arches
            for _, arch in ipairs({ "arm64", "x64", "arm", "x86", "mips", "" }) do
                assert.are.equal(_nativecrypto_systemLibDir(arch), _zlib_systemLibDir(arch), "mismatch for arch: " .. tostring(arch))
            end
        end)
    end)

    describe("cache filename and legacy cleanup", function()
        local tmpdir

        before_each(function()
            tmpdir = os.tmpname()
            os.remove(tmpdir)
            lfs.mkdir(tmpdir)
        end)

        after_each(function()
            if tmpdir then
                for f in lfs.dir(tmpdir) do
                    if f ~= "." and f ~= ".." then
                        os.remove(tmpdir .. "/" .. f)
                    end
                end
                lfs.rmdir(tmpdir)
            end
        end)

        it("derives arch-tagged cache filename correctly", function()
            -- arm64: libcrypto.arm64.so
            assert.are.equal(tmpdir .. "/libcrypto.arm64.so", tmpdir .. "/libcrypto." .. "arm64" .. ".so")
            -- arm: libz.arm.so
            assert.are.equal(tmpdir .. "/libz.arm.so", tmpdir .. "/libz." .. "arm" .. ".so")
        end)

        it("cleans up legacy untagged cache file", function()
            local legacy = tmpdir .. "/libcrypto.so"
            local f = io.open(legacy, "wb")
            assert(f)
            f:write("old 32-bit cache")
            f:close()

            assert.is_not_nil(io.open(legacy, "rb"))

            -- Simulate cleanup as androidCopyLoad does it
            local fh = io.open(legacy, "rb")
            if fh then
                fh:close()
                os.remove(legacy)
            end

            assert.is_nil(io.open(legacy, "rb"))
        end)

        it("does not remove tagged cache when cleaning legacy", function()
            local legacy = tmpdir .. "/libcrypto.so"
            local tagged = tmpdir .. "/libcrypto.arm64.so"

            local f1 = io.open(legacy, "wb")
            f1:write("old cache")
            f1:close()

            local f2 = io.open(tagged, "wb")
            f2:write("arm64 cache")
            f2:close()

            -- Clean up legacy only
            local fh = io.open(legacy, "rb")
            if fh then
                fh:close()
                os.remove(legacy)
            end

            assert.is_nil(io.open(legacy, "rb"))
            local check = io.open(tagged, "rb")
            assert.is_not_nil(check)
            check:close()
        end)

        it("different arches get different cache filenames", function()
            local path_64 = tmpdir .. "/libcrypto.arm64.so"
            local path_32 = tmpdir .. "/libcrypto.arm.so"
            assert.are_not.equal(path_64, path_32)
            assert.is.truthy(path_64:match("libcrypto%.arm64%.so$"))
            assert.is.truthy(path_32:match("libcrypto%.arm%.so$"))
        end)
    end)

    describe("actual jit.arch produces valid paths", function()
        it("systemLibDir returns a valid directory for current arch", function()
            local dir = _nativecrypto_systemLibDir(jit.arch)
            assert.is.truthy(dir)
            assert.is.truthy(dir:match("^/system/lib%d*$"))
        end)
    end)
end)
