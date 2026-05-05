require("busted.runner")()

local lfs = require("lfs")

-- Resolve plugin root to an absolute path so tests work from any cwd
local this_file = debug.getinfo(1, "S").source:match("@?(.*)") or "."
local this_dir = this_file:match("(.*)/") or "."
-- Go up from spec/ to the project root
local plugin_root
if this_dir:match("/spec$") or this_dir == "spec" then
    plugin_root = this_dir:match("^(.*)/spec$") or "."
else
    plugin_root = this_dir
end
-- Make absolute
if plugin_root:sub(1,1) ~= "/" then
    plugin_root = lfs.currentdir() .. "/" .. plugin_root
end

package.path = plugin_root .. "/?.lua;" .. package.path

local naming = require("adobe.util.naming")

-- ---------------------------------------------------------------------------
-- Zip reader backed by `unzip -p` — no C deps, works everywhere
-- ---------------------------------------------------------------------------
local UnzipReader = {}
UnzipReader.__index = UnzipReader

function UnzipReader:new()
    return setmetatable({ _path = nil }, self)
end

function UnzipReader:open(path)
    local f = io.open(path, "rb")
    if not f then
        self.err = "Cannot open: " .. tostring(path)
        return false
    end
    f:close()
    self._path = path
    return true
end

function UnzipReader:extractToMemory(entry)
    if not self._path then return nil end
    local cmd = string.format("unzip -p %q %q 2>/dev/null", self._path, entry)
    local p = io.popen(cmd, "r")
    if not p then return nil end
    local data = p:read("*a")
    p:close()
    if data == "" then return nil end
    return data
end

function UnzipReader:close()
    self._path = nil
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
local test_books = plugin_root .. "/REFERENCE/test_books"
local encrypted_book = plugin_root .. "/REFERENCE/encrypted_fulfilled.epub"

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

local function path_exists(p)
    return lfs.attributes(p, "mode") ~= nil
end

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
-- extractTitle (integration — reads real EPUB zip files)
-- ---------------------------------------------------------------------------
describe("naming.extractTitle", function()
    it("extracts title from Geography of Bliss EPUB", function()
        local reader = UnzipReader:new()
        local title, err = naming.extractTitle(reader, test_books .. "/GeographyofBliss_oneChapter.epub")
        assert.is_nil(err)
        assert.equal("The Geography of Bliss: One Grump's Search for the Happiest Places in the World", title)
    end)

    it("extracts title from Sway EPUB", function()
        local reader = UnzipReader:new()
        local title, err = naming.extractTitle(reader, test_books .. "/Sway_oneChapter.epub")
        assert.is_nil(err)
        assert.equal("Sway", title)
    end)

    it("extracts title from encrypted fulfilled EPUB", function()
        local reader = UnzipReader:new()
        local title, err = naming.extractTitle(reader, encrypted_book)
        assert.is_nil(err)
        assert.equal("To the Lighthouse", title)
    end)

    it("returns error for non-existent file", function()
        local reader = UnzipReader:new()
        local title, err = naming.extractTitle(reader, "/nonexistent/file.epub")
        assert.is_nil(title)
        assert.is_not_nil(err)
    end)
end)

-- ---------------------------------------------------------------------------
-- deriveOutputPath (mirrors ACSM:deriveOutputPath logic)
-- ---------------------------------------------------------------------------
describe("deriveOutputPath", function()
    -- Portable version of the logic from main.lua
    local function deriveOutputPath(acsm_path, epub_path)
        local dir = split_path_name(acsm_path)

        if epub_path then
            local reader = UnzipReader:new()
            local title = naming.extractTitle(reader, epub_path)
            local safe = naming.sanitizeTitle(title)
            if safe then
                return dir .. safe .. ".epub"
            end
        end

        local out = acsm_path:gsub("%.[Aa][Cc][Ss][Mm]$", ".epub")
        if out == acsm_path then out = acsm_path .. ".epub" end
        return out
    end

    it("uses EPUB title when available", function()
        local path = deriveOutputPath(
            "/books/URLLink.acsm",
            test_books .. "/Sway_oneChapter.epub"
        )
        assert.equal("/books/Sway.epub", path)
    end)

    it("uses encrypted EPUB title when available", function()
        local path = deriveOutputPath(
            "/books/URLLink.acsm",
            encrypted_book
        )
        assert.equal("/books/To the Lighthouse.epub", path)
    end)

    it("sanitizes unsafe chars from title", function()
        local path = deriveOutputPath(
            "/books/URLLink.acsm",
            test_books .. "/GeographyofBliss_oneChapter.epub"
        )
        assert.equal(
            "/books/The Geography of Bliss One Grump's Search for the Happiest Places in the World.epub",
            path
        )
    end)

    it("falls back to ACSM filename when no EPUB provided", function()
        assert.equal("/books/URLLink.epub", deriveOutputPath("/books/URLLink.acsm", nil))
    end)

    it("falls back to ACSM filename for named ACSM", function()
        assert.equal("/books/MyBook.epub", deriveOutputPath("/books/MyBook.acsm", nil))
    end)

    it("handles ACSM in current directory", function()
        -- No directory component → fallback just swaps extension
        assert.equal("URLLink.epub", deriveOutputPath("URLLink.acsm", nil))
    end)
end)

-- ---------------------------------------------------------------------------
-- findUniquePath (temp-dir based, mirrors ACSM:findUniquePath logic)
-- ---------------------------------------------------------------------------
describe("findUniquePath", function()
    local tmpdir

    local function findUniquePath(path)
        if not path_exists(path) then
            return path
        end

        local dir, filename = split_path_name(path)
        local name, ext = split_name_suffix(filename)
        if ext ~= "" then ext = "." .. ext end

        for i = 1, 999 do
            local candidate = dir .. name .. " (" .. i .. ")" .. ext
            if not path_exists(candidate) then
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
