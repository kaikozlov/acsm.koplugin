--- Integration tests: adobe/util/util.lua
-- Tests base64 encode/decode, table copy helpers, endpoint builder,
-- expiration timestamp generation, and orderedPairs iteration.

describe("util", function()
    local util

    setup(function()
        util = require("adobe.util.util")
    end)

    -- ================================================================
    -- base64
    -- ================================================================
    describe("base64", function()
        it("round-trips a plain string", function()
            local input = "hello world"
            local encoded = util.base64.encode(input)
            assert.is.truthy(encoded)
            assert.are_not.equal(input, encoded)
            assert.are.equal(input, util.base64.decode(encoded))
        end)

        it("round-trips an empty string", function()
            local encoded = util.base64.encode("")
            assert.is.truthy(encoded)
            assert.are.equal("", util.base64.decode(encoded))
        end)

        it("round-trips binary data with all byte values", function()
            local bytes = {}
            for i = 0, 255 do
                bytes[i + 1] = string.char(i)
            end
            local input = table.concat(bytes)
            assert.are.equal(256, #input)
            local decoded = util.base64.decode(util.base64.encode(input))
            assert.are.equal(input, decoded)
        end)

        it("produces known output for 'Man'", function()
            -- RFC 4648 test vector
            assert.are.equal("TWFu", util.base64.encode("Man"))
        end)
    end)

    -- ================================================================
    -- tableShallowCopy
    -- ================================================================
    describe("tableShallowCopy", function()
        it("copies key-value pairs", function()
            local orig = { a = 1, b = "two", c = true }
            local copy = util.tableShallowCopy(orig)
            assert.are.equal(1, copy.a)
            assert.are.equal("two", copy.b)
            assert.are.equal(true, copy.c)
        end)

        it("mutating copy does not affect original", function()
            local orig = { x = 10 }
            local copy = util.tableShallowCopy(orig)
            copy.x = 99
            copy.y = "new"
            assert.are.equal(10, orig.x)
            assert.is_nil(orig.y)
        end)

        it("nested tables are shared (shallow)", function()
            local inner = { val = 42 }
            local orig = { nested = inner }
            local copy = util.tableShallowCopy(orig)
            -- Same reference
            assert.are.equal(orig.nested, copy.nested)
            -- Mutation through copy affects original's inner table
            copy.nested.val = 99
            assert.are.equal(99, orig.nested.val)
        end)
    end)

    -- ================================================================
    -- deepTableCopy
    -- ================================================================
    describe("deepTableCopy", function()
        it("copies key-value pairs", function()
            local orig = { a = 1, b = "two" }
            local copy = util.deepTableCopy(orig)
            assert.are.equal(1, copy.a)
            assert.are.equal("two", copy.b)
        end)

        it("mutating copy does not affect original", function()
            local orig = { x = 10 }
            local copy = util.deepTableCopy(orig)
            copy.x = 99
            assert.are.equal(10, orig.x)
        end)

        it("nested mutation is isolated", function()
            local orig = { nested = { val = 42 } }
            local copy = util.deepTableCopy(orig)
            -- Different reference
            assert.are_not.equal(orig.nested, copy.nested)
            -- Mutation is isolated
            copy.nested.val = 99
            assert.are.equal(42, orig.nested.val)
        end)

        it("copies metatables", function()
            local mt = {
                __index = function()
                    return "meta"
                end,
            }
            local orig = setmetatable({}, mt)
            local copy = util.deepTableCopy(orig)
            -- Metatable is copied (not same reference)
            local origMt = getmetatable(orig)
            local copyMt = getmetatable(copy)
            assert.is.truthy(copyMt)
            assert.are_not.equal(origMt, copyMt)
        end)
    end)

    -- ================================================================
    -- endpoint
    -- ================================================================
    describe("endpoint", function()
        it("appends path segment to base", function()
            local base = { scheme = "https", host = "example.com", path = "/api" }
            local ep = util.endpoint(base, "activate")
            assert.are.equal("/api/activate", ep.path)
            assert.are.equal("https", ep.scheme)
            assert.are.equal("example.com", ep.host)
        end)

        it("does not mutate the original base table", function()
            local base = { scheme = "https", host = "example.com", path = "/api" }
            util.endpoint(base, "activate")
            assert.are.equal("/api", base.path)
        end)
    end)

    -- ================================================================
    -- expiration
    -- ================================================================
    describe("expiration", function()
        it("returns ISO8601 UTC format", function()
            local result = util.expiration(10)
            -- Pattern: YYYY-MM-DDTHH:MM:SSZ
            assert.is.truthy(result:match("^%d%d%d%d%-%d%d%-%d%dT%d%d:%d%d:%d%dZ$"), "Expected ISO8601 format, got: " .. result)
        end)

        it("advances by the specified minutes", function()
            local before = os.time()
            local result = util.expiration(5)
            -- Parse the result back to a timestamp
            local y, mo, d, h, mi, s = result:match("^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)Z$")
            local resultTime = os.time({
                year = tonumber(y),
                month = tonumber(mo),
                day = tonumber(d),
                hour = tonumber(h),
                min = tonumber(mi),
                sec = tonumber(s),
                isdst = false,
            })

            -- The result should be ~5 minutes (300s) in the future,
            -- with some tolerance for timezone offset calculation.
            -- We check it's at least 4 minutes and at most 6 minutes ahead.
            local diff = resultTime - before
            assert.is_true(diff >= 240 and diff <= 360, "Expected ~300s offset, got: " .. tostring(diff))
        end)
    end)

    -- ================================================================
    -- orderedPairs
    -- ================================================================
    describe("orderedPairs", function()
        it("iterates keys in alphabetical order", function()
            local t = { banana = 2, apple = 1, cherry = 3 }
            local keys = {}
            for k in util.orderedPairs(t) do
                keys[#keys + 1] = k
            end
            assert.are.same({ "apple", "banana", "cherry" }, keys)
        end)

        it("handles empty table", function()
            local keys = {}
            for k in util.orderedPairs({}) do
                keys[#keys + 1] = k
            end
            assert.are.same({}, keys)
        end)
    end)
end)
