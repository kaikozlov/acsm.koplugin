# Project: acsm.koplugin

## Testing

All tests run inside Docker against **real KOReader** (headless). No mocks,
no host-only tier. Uses the [koplugin-dev](https://github.com/kaikozlov/koplugin-dev)
Docker image (`ghcr.io/kaikozlov/koplugin-dev`) which ships the official
KOReader Linux release with all native FFI libraries (`libcrypto.so.57`,
`libz.so.1`, `libarchive`, `libSDL3`, etc.) so tests exercise the exact same
code paths as the plugin on a real device.

```bash
just setup                 # install git hooks and pull the koplugin-dev image (one-time)
just verify                # read-only fmt + lint + all non-e2e tests (pre-push/CI)
just verify-static         # read-only fmt + lint checks (pre-commit)
just test                  # run all tests (quiet; excludes e2e)
V=1 just test              # same, with full busted --verbose output
just test-e2e              # run e2e tests (hits real Adobe servers)
just test-all              # run everything including e2e
just test-filter Crypto    # run a subset by pattern
just build                 # build a release zip (versioned from _meta.lua)
just shell                 # drop into bash inside the container
just lint                  # run luacheck inside the container
just fmt-check             # check Lua formatting with stylua
just fmt                   # format Lua code with stylua
just check                 # mutating fmt + lint + test pass in one container
```

Shared recipes are vendored at `just/shared.just` (from koplugin-dev). Refresh with
`just sync-shared` when upstream recipes change, then commit the file.
Product packaging stays local: `just build`.

### Spec layout

All specs live under `spec/` and run together via `busted-koreader`:

| Location | What | Notes |
|---|---|---|
| `spec/*_spec.lua` | Module-level tests (epub, naming, fulfillment) | Real KOReader libs, real crypto |
| `spec/integration/*_spec.lua` | Cross-module tests (lifecycle, flows, DOM, crypto round-trips) | Real KOReader libs, real crypto |
| `spec/integration/e2e_spec.lua` | Full activation → fulfillment → decrypt | Tagged `#e2e`, requires network |

The only tag in use is `#e2e` — `just test` excludes it because it hits
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

- **Image**: `ghcr.io/kaikozlov/koplugin-dev:v2026.07_1` — unified dev image
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

### Driving real KOReader in tests

The Docker environment runs the **real KOReader binary, headless** — it is not a
mocked host tier. Every busted spec can `require()` any real KOReader module
(`FileManager`, `ReaderUI`, `UIManager`, `DocumentRegistry`, `PluginLoader`,
`BookInfo`, …) and drive it directly, exactly as a device would. **Prefer this
over hand-rolled stubs.** When KOReader is how your code gets called, make the
test call it the same way.

The bootstrap (`commonrequire.lua`) exposes three globals for this:

| Helper | What it does |
|---|---|
| `disable_plugins()` | Wipes the PluginLoader cache so only what you explicitly load runs |
| `load_plugin("acsm.koplugin")` | Discovers and loads just our plugin |
| `fastforward_ui_events()` | Drains `UIManager`'s scheduled tasks and runs one input loop. Call this **after** `UIManager:show(widget)` so the widget actually initializes |

Canonical pattern (see `spec/integration/plugin_lifecycle_spec.lua`):

```lua
disable_plugins()
load_plugin("acsm.koplugin")

local FileManager = require("apps/filemanager/filemanager")
local fm = FileManager:new({
    dimen = Screen:getSize(),
    root_path = DataStorage:getDataDir(),
})
UIManager:show(fm)
fastforward_ui_events()  -- widget is not ready until this runs

-- Now drive the real object the same way the UI does:
local props = fm.bookinfo:getDocProps(fixture, nil, true)

fm:onClose()
UIManager:quit()
```

#### Test the entry point, not the function

A common trap: your unit test calls the plugin function in isolation, it passes,
but the feature still breaks on-device because **KOReader reaches it through a
different path**. Test through KOReader's real entry point whenever one exists.

Concrete case from this project: `BookInfo:getDocProps()` returned correct ACSM
metadata when called directly, but the actual Book Information screen is opened
via `BookInfo:show(file, book_props)` where the caller (FileManager / CoverBrowser)
supplies `book_props` — often an empty/stale table — which **bypasses**
`getDocProps()` entirely. The bug was invisible until a test constructed a real
`FileManager` and called `fm.bookinfo:show(fixture, {})`, then read back the
rendered rows.

When integrating with a KOReader subsystem:

1. Find the real caller in `REFERENCE/koreader/` (grep for the method/event).
2. Reproduce that caller's invocation in a spec — including the arguments it
   actually passes (e.g. an empty `book_props` table, not `nil`).
3. Inspect rendered output, not just return values.

#### Inspecting widgets and KOReader internals

After `UIManager:show(widget)` + `fastforward_ui_events()`, the widget's internal
state is live and readable. For `KeyValuePage` (used by Book Information):

```lua
fm.bookinfo:show(fixture, {})
fastforward_ui_events()

local rows = {}
for _, row in ipairs(fm.bookinfo.kvp_widget.kv_pairs) do
    if type(row) == "table" then rows[row[1]] = row[2] end
end
assert.are.equal("The Adventures of Sherlock Holmes", rows["Title:"])
```

#### Throwaway probe specs

For debugging, write an ad-hoc spec, mount it into the container, and read
`print()` output to see what KOReader actually returns. Useful for tracing
“when is X called, with what arguments, what does it return?”

```bash
# write /tmp/probe_spec.lua, then:
docker run --rm -e SDL_VIDEODRIVER=dummy \
  -v "$PWD:/opt/plugin" \
  -v /tmp/probe_spec.lua:/tmp/probe_spec.lua \
  -e PLUGIN_NAME=acsm \
  ghcr.io/kaikozlov/koplugin-dev:v2026.07_1 \
  busted-koreader --verbose --helper=/opt/koplugin-dev/commonrequire.lua \
  /tmp/probe_spec.lua
```

`print()` lines appear inline in the busted output. Keep these out of
`spec/` — they are scratch space, not committed tests.

### Key files

- `justfile` — imports `./just/shared.just`; local `build` zip + `sync-shared`
- `just/shared.just` — vendored shared recipes from koplugin-dev
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

KOReader's Plugin Manager (v2026.07+) lets users delete plugins via long-press.
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
