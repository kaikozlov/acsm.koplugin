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

We have a **two-tier test system**, modeled after KOReader's official approach
(`spec/unit/commonrequire.lua` + busted) but adapted for plugin development:

| Tier | Location | Runs against | Run with |
|---|---|---|---|
| Unit specs | `spec/*_spec.lua` | Hand-written mocks (`spec/spec_helper.lua`) | `make test` (host busted) |
| Integration specs | `spec/integration/*_spec.lua` | Real KOReader (headless, in Docker) | `make docker-test` |

### Unit specs (host)

Fast, no Docker, no KOReader. Uses `spec/spec_helper.lua` to mock KOReader
modules (`logger`, `datastorage`, `util`, `ffi/util`, `socket.*`, etc.) so
the plugin's `adobe.*` modules can be loaded and tested in isolation.

```bash
make test                  # busted --verbose --pattern=_spec spec/
```

### Integration specs (Docker, real KOReader)

Boots the **official KOReader Linux release** (downloaded from GitHub) inside
a headless Ubuntu container, then runs busted against the plugin with all
real KOReader modules and native FFI libraries available
(`libcrypto.so.57`, `libSDL3.so.0`, `libwrap-mupdf.so`, `libsqlite3`, …).

```bash
make docker-build          # one-time build (cached after first run)
make docker-test           # run all integration specs
make docker-shell          # drop into bash inside the container
make docker-busted ARGS="--filter=Crypto"   # run a subset
```

Defaults: `KOREADER_VERSION=v2026.03`, `DOCKER_ARCH=arm64`. For x86_64 CI:
```bash
make docker-build DOCKER_ARCH=x86_64
```

### How the Docker setup works

- **Base image**: `ubuntu:22.04` (matches KOReader's own CI base — `koreader/kobase:0.5.4-22.04`).
- **KOReader**: downloaded from
  `https://github.com/koreader/koreader/releases/download/${KOREADER_VERSION}/koreader-linux-${ARCH}-${KOREADER_VERSION}.tar.xz`
  and extracted to `/opt/lib/koreader/`. This includes the bundled `luajit`
  binary and all native `.so` libraries.
- **Busted**: installed via apt (`lua-busted`), which puts pure-Lua busted +
  all transitive deps (luassert, say, mediator, cliargs, dkjson, penlight,
  term) under `/usr/share/lua/5.1/`.
- **Wrapper**: `/usr/local/bin/busted-koreader` invokes KOReader's bundled
  `luajit` with `LUA_PATH` pointing at both `/usr/share/lua/5.1/` (busted)
  and `${KOREADER_DIR}/{common,frontend}/` (KOReader modules).
- **Plugin**: symlinked into `/opt/lib/koreader/plugins/acsm.koplugin/` so
  `PluginLoader:_discover()` finds it.
- **Bootstrap**: `spec/commonrequire.lua` is passed as busted's `--helper`,
  ported from KOReader's `spec/unit/commonrequire.lua`. It sets
  `einkfb.dummy = true` (headless framebuffer), `Input.dummy = true`,
  isolates `G_reader_settings` / `G_defaults` in a temp dir, and exposes
  `load_plugin()` and `fastforward_ui_events()` helpers.

### Why apt's lua-busted instead of `luarocks install busted`

LuaJIT has a hard 64K-constants-per-function limit. The luarocks.org
manifest exceeds that, so **any** `luarocks install` against a LuaJIT-built
LuaRocks fails with `main function has more than 65536 constants`. Ubuntu's
`lua-busted` package sidesteps this entirely — it ships busted as plain Lua
files that any Lua 5.1-compatible interpreter (including LuaJIT) can load.

### Files

- `Dockerfile` — Ubuntu base + KOReader release + lua-busted + plugin source
- `Makefile` — `test`, `docker-{build,test,shell,busted}`, `lint`, `clean`
- `.dockerignore` — keeps `REFERENCE/`, `.git/`, build artifacts out of context
- `spec/commonrequire.lua` — headless KOReader bootstrap (busted helper)
- `spec/spec_helper.lua` — mocks for unit specs (no KOReader needed)
- `spec/integration/` — integration specs that run inside Docker
- `test/headless.lua`, `test/headless_test.sh` — legacy custom test runner
  that uses the macOS KOReader.app (kept as a fallback / debugging tool).

### Reference

- `REFERENCE/koreader/spec/unit/commonrequire.lua` — the upstream pattern
- `REFERENCE/kobo.koplugin/spec/helper.lua` — alternative pure-mocks approach
  (kobo.koplugin uses Nix + busted with no KOReader at all; useful to study
  but our integration specs are higher-fidelity)
