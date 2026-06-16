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
no host-only tier. Uses the [koplugin-dev](https://github.com/kaikozlov/koplugin-dev)
Docker image (`ghcr.io/kaikozlov/koplugin-dev`) which ships the official
KOReader Linux release with all native FFI libraries (`libcrypto.so.57`,
`libz.so.1`, `libarchive`, `libSDL3`, etc.) so tests exercise the exact same
code paths as the plugin on a real device.

```bash
just setup                 # pull the koplugin-dev image (one-time)
just test                  # run all tests (excludes e2e network tests)
just test-e2e              # run e2e tests (hits real Adobe servers)
just test-all              # run everything including e2e
just test-filter Crypto    # run a subset by pattern
just build                 # build a release zip (versioned from _meta.lua)
just shell                 # drop into bash inside the container
just lint                  # run luacheck inside the container
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

### E2E tests

The e2e suite (`spec/integration/e2e_spec.lua`) hits **real Adobe Content
Server** end-to-end. It exercises the entire pipeline that a user would go
through:

1. Download a real `.acsm` from Adobe's free sample library
2. Anonymous sign-in via `adobe.signIn`
3. Device activation via `adobe.activate`
4. Fulfillment: ACSM → encrypted EPUB download
5. Decryption: remove Adobe DRM, produce a valid EPUB

The test uses Adobe's smallest free sample ("God Is A Salesman" chapter 1,
~100 KB) to minimize download time. It validates the output is a real EPUB
(PK zip header) and that decryption produced >0 entries.

```bash
just test-e2e   # must have network; uses --network=host
```

No credentials or configuration are needed — anonymous sign-in works for
free samples. If Adobe's servers are down or rate-limiting, the test will
fail with a network or HTTP error.

### How it works

- **Image**: `ghcr.io/kaikozlov/koplugin-dev:v2026.03_2` — unified dev image
  with KOReader + busted + luacheck + stylua.
- **KOReader**: extracted to `/opt/lib/koreader/`, includes bundled `luajit`.
- **Plugin**: bind-mounted at `/opt/plugin`, auto-symlinked into KOReader's
  plugins dir by `entrypoint.sh` so `PluginLoader:_discover()` finds it.
- **Bootstrap**: `/opt/koplugin-dev/commonrequire.lua` (busted `--helper`)
  sets up headless mode (`einkfb.dummy`, `Input.dummy`), isolated settings
  in `/tmp`, and exposes `load_plugin()`, `fastforward_ui_events()`,
  `disable_plugins()`.
- **Wrapper**: `/usr/local/bin/busted-koreader` invokes KOReader's `luajit`
  with `LUA_PATH` pointing at busted and KOReader modules.

### Key files

- `justfile` — `test`, `test-e2e`, `test-all`, `test-filter`, `lint`, `build`, `shell`
- `spec/integration/fixtures/` — test fixtures (sample ACSM, etc.)
- `adobe/util/adobehash.lua` — extracted hash buffer construction (testable separately from fulfillment)

### Format support

The plugin supports **EPUB** and **PDF** — the only two formats Adobe DRMs via ACSM.

Format detection happens at two levels:
1. **ACSM metadata** (`dc:format`): `application/epub+zip` or `application/pdf`
2. **Magic bytes after download**: `PK` (ZIP/EPUB) or `%PDF-` (PDF)

The fulfillment pipeline (activation → auth → fulfill → RSA decrypt book key) is
shared between both formats. After download, format-specific decryption takes over.

**EPUB** (`adobe/epub.lua`):
- ZIP container with `META-INF/encryption.xml` listing encrypted resources
- AES-128-CBC on listed resources (16-byte random prefix + PKCS7 padding)
- Removes `rights.xml`, rewrites `encryption.xml`, strips watermarks

**PDF** (`adobe/pdf.lua` + `adobe/pdf/` directory):
- Native PDF with per-object encryption (RC4 or AES)
- Book key extracted via RSA; per-object keys derived with MD5 (genkey v2-v5)
- PDF structure (xref, trailer, objects) parsed by pure-Lua tokenizer
- Writes clean unencrypted PDF without `/Encrypt` dictionary

Key PDF modules:

| File | Role |
|---|---|
| `adobe/pdf.lua` | PDF decrypt orchestrator (like epub.lua) |
| `adobe/pdf/parser.lua` | PDF tokenizer + object parser |
| `adobe/pdf/writer.lua` | PDF serializer (clean output) |
| `adobe/pdf/pdfdoc.lua` | Document-level reader (xref, trailer, objects) |
| `adobe/pdf/pdfcrypt.lua` | Key derivation (genkey v2-v5) + hardening removal |
| `adobe/pdf/rc4.lua` | Pure-Lua RC4 stream cipher |

### Test coverage overview

442 tests total (excluding e2e). Key areas:

| Area | Spec file | Tests |
|---|---|---|
| ASN.1 encoding + signing | `integration/signing_spec.lua` | 22 (10 byte-level, 3 pipeline, 9 negative) |
| Adobe hash buffer + digest | `integration/hashbuffer_spec.lua` | 11 |
| XML request builders | `integration/xml_builders_spec.lua` | 6 |
| Crypto round-trips | `integration/crypto_spec.lua` | 5 |
| DOM parse/serialize round-trip | `integration/dom_spec.lua` | 10 |
| EPUB decryption pipeline | `integration/epub_spec.lua` | 7 |
| Fulfillment flow (stubbed HTTP) | `integration/fulfillment_flow_spec.lua` | 7 |
| Fulfillment internals (sign, notify) | `integration/fulfillment_internals_spec.lua` | 11 |
| Plugin lifecycle | `integration/plugin_lifecycle_spec.lua` | 18 |
| main.lua helpers (metadata, paths) | `integration/main_spec.lua` | 10 |
| Module loading | `integration/module_loading_spec.lua` | 12 |
| Naming utilities | `integration/naming_spec.lua` + `naming_spec.lua` | 23 |
| zlib inflate round-trip | `integration/zlib_spec.lua` | 10 |
| EPUB internals | `epub_spec.lua` | 22 |
| Fulfillment smoke | `fulfillment_spec.lua` | 3 |
| deletePluginSettings hook | `integration/delete_settings_spec.lua` | 12 |
| RC4 cipher | `integration/rc4_spec.lua` | 18 |
| PDF key derivation | `integration/pdfcrypt_spec.lua` | 22 |
| PDF tokenizer/parser | `integration/pdf_parser_spec.lua` | 81 |
| PDF serializer/writer | `integration/pdf_writer_spec.lua` | 34 |
| PDF document reader | `integration/pdfdoc_spec.lua` | 9 |
| PDF decrypt internals | `integration/pdf_decrypt_spec.lua` | 21 |
| PDF decrypt pipeline (synthetic) | `integration/pdf_pipeline_spec.lua` | 4 |
| nativecrypto edge cases | `integration/nativecrypto_spec.lua` | 13 |
| util.lua (base64, copy, endpoint) | `integration/util_spec.lua` | 17 |
| adobe.lua isolated (serialize, restore) | `integration/adobe_spec.lua` | 10 |
| Cross-validation | `integration/cross_validate_spec.lua` | 33 |
| E2E EPUB (Adobe servers) | `integration/e2e_spec.lua` | 2 |
| E2E PDF (Adobe servers) | `integration/pdf_e2e_spec.lua` | 2 |

### Key API note: crypto.key wrapper vs raw PKey

`crypto.key.new()` returns a **wrapper** with `.pkey` holding the raw
`nativecrypto.PKey` object. The wrapper only exposes construction and
DER export (`topkcs8`). All signing/encryption/decryption methods
(`sign_raw`, `encrypt`, `decrypt`) live on the raw PKey.

Callers must use `.pkey` when passing to functions that sign:

```lua
local key = crypto.key.new()
local sig = crypto.signXML("name", key.pkey, { ... })  -- correct
local sig = crypto.signXML("name", key, { ... })       -- ERROR: no sign_raw
```

This is consistent with all real call sites (`adobe.activate`,
`fulfillment.process`) which receive raw PKeys from `crypto.decodepkcs12`
(which returns `decoded.key` — already raw).

---

## Plugin Cleanup: `deletePluginSettings()`

KOReader's Plugin Manager (v2026.03+) lets users delete plugins via long-press.
A checkbox "Also delete plugin settings" appears; it is **grayed out** unless the
plugin implements `deletePluginSettings()` on its instance. PluginLoader calls it
via `pcall(fn, instance)` — no parameters, no return value needed.

### What to clean up

Our `deletePluginSettings()` must remove **all** persistent state the plugin
creates. Currently that is:

| On-disk path | Type | Content |
|---|---|---|
| `settings/acsm.lua` | LuaSettings file | `activation`, `reuse_existing`, `open_after_download` |
| `cache/acsm.koplugin/` | Directory | `fulfillment_map.lua` + temp fulfillment/epub work files |

**No `G_reader_settings` keys are used** — all state is in the plugin's own files.

(There are also Android-only side effects copying system `.so` files into the
app data directory, but those are shared system libraries, not plugin state.)

### Adding new persistent state

When adding any new file, directory, or `G_reader_settings` key, you **must**
also add its cleanup to `ACSM:deletePluginSettings()` in `main.lua` and add a
test to `spec/integration/delete_settings_spec.lua`.

The test file uses isolated temp directories — each test creates its own,
and cleans up at the end.

### Reference

- `REFERENCE/koreader/spec/unit/commonrequire.lua` — the upstream pattern
- koreader/koreader#15240 — PR that added `deletePluginSettings` to PluginLoader
- koreader/koreader#15245 — follow-up separating built-in vs user plugins



