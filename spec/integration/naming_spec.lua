--- Integration tests: naming utility
-- Verifies title sanitization, truncation, and edge case handling.

describe("Naming utility", function()
    it("sanitizeTitle handles unsafe chars", function()
        local naming = require("adobe.util.naming")
        assert.are.equal("a b c d e f g", naming.sanitizeTitle('a:b*c?d"e<f>g'))
    end)

    it("sanitizeTitle returns nil for empty/nil", function()
        local naming = require("adobe.util.naming")
        assert.is_nil(naming.sanitizeTitle(""))
        assert.is_nil(naming.sanitizeTitle(nil))
    end)

    it("sanitizeTitle truncates long titles", function()
        local naming = require("adobe.util.naming")
        local result = naming.sanitizeTitle(string.rep("A", 300))
        assert.is_true(#result <= 200)
    end)
end)
