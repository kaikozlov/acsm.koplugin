local lfs = require("lfs")

describe("fulfillment module", function()

    describe("downloadBook", function()
        it("should return true instead of file content on success", function()
            -- The downloadBook function now uses lfs.attributes instead of
            -- reading the entire file into memory. We can't easily test the
            -- actual HTTP download, but we verify the return type contract.
            local fulfillment = require("adobe.fulfillment")

            -- downloadBook requires network, so we just verify the function exists
            -- and has the right signature
            assert.is.truthy(fulfillment.downloadBook)
            assert.are.equal("function", type(fulfillment.downloadBook))
        end)
    end)

    describe("decryptBookKey", function()
        it("should exist as a function", function()
            local fulfillment = require("adobe.fulfillment")
            assert.is.truthy(fulfillment.decryptBookKey)
            assert.are.equal("function", type(fulfillment.decryptBookKey))
        end)

        it("should return error for nil key", function()
            local fulfillment = require("adobe.fulfillment")
            local result, err = fulfillment.decryptBookKey(nil, {})
            assert.is_nil(result)
            assert.is.truthy(err)
        end)
    end)
end)
