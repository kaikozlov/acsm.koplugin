# Patches

Optional [user patches](https://github.com/koreader/koreader/wiki/User-patches)

They are **not required** for normal use — install one only if you're hitting the
problem it describes.

- [`2-acsm-open-via-filemanager.lua`](./2-acsm-open-via-filemanager.lua) — fixes
  "cannot open document … `.acsm`" when opening a loan from an external app
  (e.g. the PocketBook library).

### Installation

1. Download [`2-acsm-open-via-filemanager.lua`](./2-acsm-open-via-filemanager.lua).
2. Connect your e-reader (or access its filesystem).
3. Open your KOReader directory — the one that contains the `patches/`,
   `settings/`, etc. folders. On PocketBook this is typically the `koreader/`
   folder.
4. Create a `patches/` folder inside it if one doesn't already exist.
5. Copy the `.lua` file into `koreader/patches/`.
6. Restart KOReader.

The result should look like:

```
koreader/
└── patches/
    └── 2-acsm-open-via-filemanager.lua
```

> Keep the `2-` prefix. KOReader loads patches in numeric order, and this one
> needs to run before the launch file is opened.

### Verifying it works

After restarting, try opening the `.acsm` the way you normally do. If it still
fails, check `crash.log` (in your KOReader directory) for `[ACSM patch]` lines —
they record which code path the patch took. If the lines are absent, the patch
didn't load; if they're present but the open still fails, grab the log and open
an [issue](https://github.com/kaikozlov/acsm.koplugin/issues).
