--- Integration tests: main.lua pure function helpers
-- Tests parseAcsmMetadata, deriveOutputPath, findUniquePath.
-- Uses dofile() pattern (same as plugin_lifecycle_spec) since
-- load_plugin() requires full UIManager/FileManager setup.

describe("main.lua helpers", function()
    local koutil, DataStorage, ACSM, plugin_path

    setup(function()
        koutil = require("util")
        DataStorage = require("datastorage")
        plugin_path = os.getenv("PLUGIN_PATH") or "/opt/plugin"
    end)

    before_each(function()
        -- Load a fresh copy of main.lua for each test group
        ACSM = dofile(plugin_path .. "/main.lua")
    end)

    -- ================================================================
    -- parseAcsmMetadata
    -- ================================================================
    describe("parseAcsmMetadata", function()
        it("extracts title and resource from EPUB ACSM", function()
            local fixture = plugin_path .. "/spec/integration/fixtures/sample.acsm"
            local meta = ACSM.parseAcsmMetadata(ACSM, fixture)
            assert.is.truthy(meta)
            assert.are.equal("The Adventures of Sherlock Holmes", meta.title)
            assert.are.equal("urn:uuid:723caf6a-0e27-44be-8733-904cede39cd2", meta.resourceId)
        end)

        it("extracts format from PDF ACSM", function()
            local fixture = plugin_path .. "/spec/integration/fixtures/pdf_acsm/boule_de_suif.acsm"
            local meta = ACSM.parseAcsmMetadata(ACSM, fixture)
            assert.is.truthy(meta)
            assert.are.equal("Boule de Suif", meta.title)
            assert.is.truthy(meta.format)
            -- format could be string or table
            local fmt = type(meta.format) == "table" and meta.format[1] or meta.format
            assert.are.equal("application/pdf", fmt)
        end)

        it("returns nil for non-existent file", function()
            local meta = ACSM.parseAcsmMetadata(ACSM, "/nonexistent/file.acsm")
            assert.is_nil(meta)
        end)

        it("returns nil for invalid XML", function()
            local tmpDir = DataStorage:getDataDir() .. "/test-meta-" .. tostring(os.time())
            koutil.makePath(tmpDir)
            local path = tmpDir .. "/bad.acsm"
            koutil.writeToFile("not xml at all {{{", path)
            local meta = ACSM.parseAcsmMetadata(ACSM, path)
            assert.is_nil(meta)
            os.execute("rm -rf " .. tmpDir)
        end)
    end)

    -- ================================================================
    -- deriveOutputPath
    -- ================================================================
    describe("deriveOutputPath", function()
        it("uses title from ACSM metadata for EPUB", function()
            local path = ACSM.deriveOutputPath(ACSM, "/books/test.acsm", {
                title = "My Great Book",
                format = "application/epub+zip",
            })
            assert.is.truthy(path:find("My Great Book", 1, true))
            assert.is.truthy(path:find("%.epub$"))
        end)

        it("uses .pdf extension for PDF format", function()
            local path = ACSM.deriveOutputPath(ACSM, "/books/test.acsm", {
                title = "PDF Book",
                format = "application/pdf",
            })
            assert.is.truthy(path:find("%.pdf$"))
        end)

        it("falls back to filename swap when no title", function()
            local path = ACSM.deriveOutputPath(ACSM, "/books/myfile.acsm", nil)
            assert.are.equal("/books/myfile.epub", path)
        end)

        it("falls back to filename swap with PDF format", function()
            local path = ACSM.deriveOutputPath(ACSM, "/books/myfile.acsm", {
                format = "application/pdf",
            })
            assert.are.equal("/books/myfile.pdf", path)
        end)
    end)

    -- ================================================================
    -- findUniquePath
    -- ================================================================
    describe("findUniquePath", function()
        it("returns original path when file does not exist", function()
            local tmpDir = DataStorage:getDataDir() .. "/test-unique-" .. tostring(os.time())
            koutil.makePath(tmpDir)
            local path = tmpDir .. "/newfile.epub"
            local result = ACSM.findUniquePath(ACSM, path)
            assert.are.equal(path, result)
            os.remove(result) -- clean up placeholder
            os.execute("rm -rf " .. tmpDir)
        end)

        it("appends counter when file exists", function()
            local tmpDir = DataStorage:getDataDir() .. "/test-unique2-" .. tostring(os.time())
            koutil.makePath(tmpDir)
            local path = tmpDir .. "/existing.epub"
            -- Create the existing file
            local f = io.open(path, "w")
            f:write("existing")
            f:close()

            local result = ACSM.findUniquePath(ACSM, path)
            assert.are_not.equal(path, result)
            assert.is.truthy(result:find("existing %(1%)%.epub$"))

            os.remove(result)
            os.remove(path)
            os.execute("rm -rf " .. tmpDir)
        end)
    end)
end)
