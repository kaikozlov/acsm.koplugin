-- Luacheck config for acsm.koplugin
-- Target: LuaJIT (Lua 5.1) as used by KOReader

std = "luajit"

-- unused args are normal in KOReader plugin callbacks
unused_args = false

-- ignore implicit self
self = false

-- KOReader-provided globals
globals = {
    "G_reader_settings",
    "G_defaults",
    "table.pack",
    "table.unpack",
}

read_globals = {
    "_ENV",
}

-- dependencies/ is vendored third-party code
-- REFERENCE/, build/, dot-dirs are not project source
exclude_files = {
    "dependencies/",
    "REFERENCE/",
    "build/",
    ".luarocks/",
    ".luajitrocks/",
}

-- spec files use busted
files["spec/"].std = "+busted"
files["spec/"].globals = {
    "match",
    "package",
    "TEST_DATA_DIR",
}

-- 211 - unused local starting with __ (placeholder)
-- 231 - unused __ self vararg
-- 631 - line too long
ignore = {
    "211/__*",
    "231/__",
    "631",
}
