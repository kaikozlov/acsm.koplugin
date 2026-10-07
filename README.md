## ACSM for KOReader

A KOReader plugin that lets you borrow ebooks from your public library and read them on your e-reader — no computer or Adobe Digital Editions required. Open an `.acsm` loan file directly on-device and get a standard EPUB or PDF you can keep in your library.

### Installation

1. Copy `acsm.koplugin/` to your KOReader plugins directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/.adds/koreader/plugins/`
2. Restart KOReader

### Usage

1. Borrow an ebook from your library and download the `.acsm` file. In Libby: **Shelf → Manage Loan → Read With... → Other Options → EPUB** (or PDF, when offered).

2. Tap the `.acsm` file in KOReader's file browser
3. When prompted for a provider, select **ACSM** — if it doesn't prompt, hold down the file and select "Open with"
4. Wait for the progress messages to finish, then read

The first time you open a loan, the plugin creates a one-time anonymous device activation with Adobe. This is saved and reused for all future loans — no Adobe account needed.

The resulting EPUB or PDF is saved next to the original `.acsm` file and works like any other book in your KOReader library. Opening the same `.acsm` again will reuse the existing file without re-downloading.

### Settings

| Setting | Description |
| ------- | ----------- |
| Open book after download | Open the downloaded book automatically (on by default) |
| Reuse existing file | Open the previously downloaded EPUB or PDF instead of re-fetching (on by default) |
| Adobe activation | View saved status, forget locally, export a backup, or load a backup |

#### Managing activation

Under **ACSM → Adobe activation**, status indicates whether an activation is
saved locally (it does not check Adobe's servers). Export uses KOReader's folder
chooser: long-press a folder to select it, then enter a filename. Loading uses
the file chooser: long-press an exported backup to select it. Both choosers also
support non-touch navigation. Replacing an existing file or activation requires
confirmation; cancelling or choosing an invalid backup leaves the current
activation unchanged.

Backups are versioned `.json` files produced by this plugin, not Adobe Digital
Editions files or executable KOReader `.lua` settings files. They contain
**unencrypted private keys and account information**. Keep them private and only
load backups you trust. Export requests owner-only permissions where supported;
removable filesystems may not enforce them. Writes use a temporary file beside
the destination and replace it only after writing and closing succeeds.

Forgetting removes the plugin's active saved activation locally; it does not
contact Adobe or erase exported files or KOReader's `.old` settings backups.
Previously borrowed books may need their original activation, so export it
before replacing or forgetting it if you may need it again.

### Compatibility

Tested on Kindle with KOReader v2026.07. Should work on any KOReader device (Kobo, reMarkable, PocketBook, etc.) — the plugin uses only libraries bundled with standard KOReader builds.

### Troubleshooting

**"cannot open document … `.acsm`" when opening from an external app** (e.g. the PocketBook library): this happens when KOReader is launched with the `.acsm` as a startup argument. An optional [user patch](./patches/) fixes it — see [`patches/README.md`](./patches/README.md) for details and installation.

### Acknowledgments

[acsm-calibre-plugin](https://github.com/Leseratte10/acsm-calibre-plugin) by Leseratte10 — reference implementation for the ADEPT protocol.

### License

MIT
