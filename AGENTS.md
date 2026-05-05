# Project: acsm.koplugin

## LuaJIT & LuaRocks Setup (host)

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

---

## Testing

All tests run inside Docker against **real KOReader** (headless). No mocks,
no host-only tier. The Docker image ships the official KOReader Linux release
with all native FFI libraries (`libcrypto.so.57`, `libz.so.1`, `libarchive`,
`libSDL3`, etc.) so tests exercise the exact same code paths as the plugin
on a real device.

```bash
make test                  # run all tests (excludes e2e network tests)
make test-e2e              # run e2e tests (hits real Adobe servers)
make test-all              # run everything including e2e
make test-filter FILTER="Crypto"  # run a subset by pattern
make docker-shell          # drop into bash inside the container
```

### Spec layout

All specs live under `spec/` and run together via `busted-koreader`:

| Location | What | Notes |
|---|---|---|
| `spec/*_spec.lua` | Module-level tests (epub, naming, fulfillment) | Real KOReader libs, real crypto |
| `spec/integration/*_spec.lua` | Cross-module tests (lifecycle, flows, DOM, crypto round-trips) | Real KOReader libs, real crypto |
| `spec/integration/e2e_spec.lua` | Full activation → fulfillment → decrypt | Tagged `#e2e`, requires network |

The only tag in use is `#e2e` — `make test` excludes it because it hits
Adobe's servers and needs network access.

### How it works

- **Image**: `ubuntu:22.04` + KOReader Linux release + `lua-busted` (apt).
- **KOReader**: extracted to `/opt/lib/koreader/`, includes bundled `luajit`.
- **Plugin**: bind-mounted at `/opt/acsm.koplugin`, symlinked into KOReader's
  plugins dir so `PluginLoader:_discover()` finds it.
- **Bootstrap**: `spec/commonrequire.lua` (busted `--helper`) sets up headless
  mode (`einkfb.dummy`, `Input.dummy`), isolated settings in `/tmp`, and
  exposes `load_plugin()`, `fastforward_ui_events()`, `disable_plugins()`.
- **Wrapper**: `/usr/local/bin/busted-koreader` invokes KOReader's `luajit`
  with `LUA_PATH` pointing at busted and KOReader modules.

Defaults: `KOREADER_VERSION=v2026.03`, `DOCKER_ARCH=arm64`. For x86_64 CI:
```bash
make docker-build DOCKER_ARCH=x86_64
```

### Why apt's lua-busted instead of `luarocks install busted`

LuaJIT has a hard 64K-constants-per-function limit. The luarocks.org
manifest exceeds that, so **any** `luarocks install` against a LuaJIT-built
LuaRocks fails with `main function has more than 65536 constants`. Ubuntu's
`lua-busted` package sidesteps this entirely — it ships busted as plain Lua
files that any Lua 5.1-compatible interpreter (including LuaJIT) can load.

### Key files

- `Dockerfile` — Ubuntu base + KOReader release + lua-busted
- `Makefile` — `test`, `test-e2e`, `test-all`, `test-filter`, `lint`, `clean`
- `.dockerignore` — keeps `REFERENCE/`, `.git/`, build artifacts out of context
- `spec/commonrequire.lua` — headless KOReader bootstrap (busted helper)
- `spec/integration/fixtures/` — test fixtures (sample ACSM, etc.)

### Reference

- `REFERENCE/koreader/spec/unit/commonrequire.lua` — the upstream pattern



