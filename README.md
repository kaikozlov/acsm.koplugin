## ACSM for KOReader

A KOReader plugin that lets you borrow ebooks from your public library and read them on your e-reader — no computer or Adobe Digital Editions required. Open an `.acsm` loan file directly on-device and get a standard EPUB or PDF you can keep in your library.

### Installation

1. Copy `acsm.koplugin/` to your KOReader plugins directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/.adds/koreader/plugins/`
2. Restart KOReader

### Usage

1. Borrow an ebook from your library and download the `.acsm` file. In Libby: **Shelf → Manage Loan → Read With... → Other Options → EPUB** (or PDF, when offered).

   > **Tip:** On Kindle, you can do this entirely on-device — open the Kindle's built-in web browser, go to [libbyapp.com](https://libbyapp.com), borrow a book, and download the `.acsm` file directly.

2. Tap the `.acsm` file in KOReader's file browser
3. When prompted for a provider, select **ACSM** — if it doesn't prompt, hold down the file and select "Open with"
4. Wait for the progress messages to finish, then read

The first time you open a loan, the plugin creates a one-time anonymous device activation with Adobe. This is saved and reused for all future loans — no Adobe account needed.

The resulting EPUB or PDF is saved next to the original `.acsm` file and works like any other book in your KOReader library. Opening the same `.acsm` again will reuse the existing file without re-downloading.

### Settings

| Setting | Description |
| ------- | ----------- |
| Activation status | Whether the plugin has an active Adobe device registration |
| Reuse existing file | Open the previously downloaded EPUB or PDF instead of re-fetching (on by default) |
| Forget Adobe activation | Clear the saved activation to start fresh |

### Compatibility

Tested on Kindle with KOReader v2026.03. Should work on any KOReader device (Kobo, reMarkable, PocketBook, etc.) — the plugin uses only libraries bundled with standard KOReader builds.

### Troubleshooting

**"cannot open document … `.acsm`" when opening from an external app** (e.g. the PocketBook library): this happens when KOReader is launched with the `.acsm` as a startup argument. An optional [user patch](./patches/) fixes it — see [`patches/README.md`](./patches/README.md) for details and installation.

### Acknowledgments

[acsm-calibre-plugin](https://github.com/Leseratte10/acsm-calibre-plugin) by Leseratte10 — reference implementation for the ADEPT protocol.

### License

MIT
