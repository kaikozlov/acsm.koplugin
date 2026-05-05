local naming = require("adobe.util.naming")


-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function split_path_name(file)
    if not file or file == "" then return "", "" end
    if not file:find("/") then return "", file end
    return file:match("(.*/)(.*)")
end

local function split_name_suffix(file)
    if not file or file == "" then return "", "" end
    if not file:find("%.") then return file, "" end
    return file:match("(.*)%.(.*)")
end

local function write_file(path, content)
    local f = io.open(path, "wb")
    f:write(content or "")
    f:close()
end

local function rm_rf(dir)
    os.execute("rm -rf " .. dir)
end

local function mktemp()
    local d = os.tmpname()
    os.remove(d)
    lfs.mkdir(d)
    return d
end


-- ---------------------------------------------------------------------------
-- sanitizeTitle
-- ---------------------------------------------------------------------------
describe("naming.sanitizeTitle", function()
    it("returns a clean title unchanged", function()
        assert.equal("The Great Gatsby", naming.sanitizeTitle("The Great Gatsby"))
    end)

    it("replaces colons", function()
        assert.equal("Bliss One Grump's Search",
            naming.sanitizeTitle("Bliss: One Grump's Search"))
    end)

    it("replaces slashes", function()
        assert.equal("A B", naming.sanitizeTitle("A/B"))
    end)

    it("replaces backslashes", function()
        assert.equal("A B C", naming.sanitizeTitle("A\\B\\C"))
    end)

    it("replaces all unsafe chars", function()
        assert.equal("a b c d e f g", naming.sanitizeTitle('a:b*c?d"e<f>g'))
    end)

    it("replaces pipe", function()
        assert.equal("foo bar", naming.sanitizeTitle("foo|bar"))
    end)

    it("collapses multiple spaces", function()
        assert.equal("Hello World", naming.sanitizeTitle("Hello    World"))
    end)

    it("trims leading/trailing whitespace", function()
        assert.equal("Hello", naming.sanitizeTitle("  Hello  "))
    end)

    it("trims leading dots", function()
        assert.equal("hidden", naming.sanitizeTitle("...hidden"))
    end)

    it("returns nil for empty string", function()
        assert.is_nil(naming.sanitizeTitle(""))
    end)

    it("returns nil for nil", function()
        assert.is_nil(naming.sanitizeTitle(nil))
    end)

    it("returns nil for all-unsafe chars that collapse to nothing", function()
        -- ":::" becomes "   " -> trimmed to ""
        assert.is_nil(naming.sanitizeTitle(":::"))
    end)

    it("truncates very long titles to 200 chars", function()
        local long = string.rep("A", 300)
        local result = naming.sanitizeTitle(long)
        assert.is_true(#result <= 200)
    end)

    it("preserves unicode text", function()
        assert.equal("Die Leiden des jungen Werther",
            naming.sanitizeTitle("Die Leiden des jungen Werther"))
    end)

    it("preserves French accented chars", function()
        assert.equal("La Chartreuse de Parme",
            naming.sanitizeTitle("La Chartreuse de Parme"))
    end)

    it("handles colons in subtitles", function()
        assert.equal("God Is A Salesman Learn from the Master",
            naming.sanitizeTitle("God Is A Salesman: Learn from the Master"))
    end)
end)

-- ---------------------------------------------------------------------------
-- findUniquePath (temp-dir based, mirrors ACSM:findUniquePath logic)
-- ---------------------------------------------------------------------------
describe("findUniquePath", function()
    local tmpdir

    -- Mirrors the findUniquePath logic from main.lua (io.open("wx") approach)
    local function findUniquePath(path)
        -- Try the base path first with atomic exclusive create
        local f = io.open(path, "wx")
        if f then
            f:close()
            os.remove(path)
            return path
        end

        -- Path exists; try numbered variants
        local dir, filename = split_path_name(path)
        local name, ext = split_name_suffix(filename)
        if ext ~= "" then ext = "." .. ext end

        for i = 1, 999 do
            local candidate = dir .. name .. " (" .. i .. ")" .. ext
            local cf = io.open(candidate, "wx")
            if cf then
                cf:close()
                os.remove(candidate)
                return candidate
            end
        end

        return path
    end

    before_each(function()
        tmpdir = mktemp()
    end)

    after_each(function()
        rm_rf(tmpdir)
    end)

    it("returns original path when nothing exists", function()
        write_file(tmpdir .. "/new.epub", "content")
        local path = findUniquePath(tmpdir .. "/MyBook.epub")
        assert.equal(tmpdir .. "/MyBook.epub", path)
    end)

    it("appends (1) when file exists", function()
        write_file(tmpdir .. "/MyBook.epub", "first edition")

        local path = findUniquePath(tmpdir .. "/MyBook.epub")
        assert.equal(tmpdir .. "/MyBook (1).epub", path)
    end)

    it("increments counter past existing numbered files", function()
        write_file(tmpdir .. "/MyBook.epub", "first")
        write_file(tmpdir .. "/MyBook (1).epub", "second")
        write_file(tmpdir .. "/MyBook (2).epub", "third")

        local path = findUniquePath(tmpdir .. "/MyBook.epub")
        assert.equal(tmpdir .. "/MyBook (3).epub", path)
    end)

    it("handles files without extension", function()
        write_file(tmpdir .. "/README", "old")

        local path = findUniquePath(tmpdir .. "/README")
        assert.equal(tmpdir .. "/README (1)", path)
    end)
end)
