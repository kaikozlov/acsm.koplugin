# Project: acsm.koplugin

## LuaJIT & LuaRocks Setup

### Installed versions
- **LuaJIT 2.1** (Lua 5.1) — `/opt/homebrew/bin/luajit`
- **Lua 5.5** — `/opt/homebrew/bin/lua` (default)
- **LuaRocks 3.13.0** — `/opt/homebrew/bin/luarocks`

### Commands

| What | Command |
|---|---|
| Run LuaJIT | `luajit script.lua` |
| Install a rock (LuaJIT/Lua 5.1) | `luarocks --lua-version 5.1 install <name>` |
| List rocks (Lua 5.1) | `luarocks --lua-version 5.1 list` |
| Run Lua 5.5 (default) | `lua script.lua` |
| Install a rock (Lua 5.5) | `luarocks install <name>` |

### Config
- LuaRocks LuaJIT config: `~/.luarocks/config-5.1.lua`
- The `--lua-version 5.1` flag tells LuaRocks to use the LuaJIT config instead of the default Lua 5.5.
