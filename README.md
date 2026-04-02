## ACSM for KOReader

A KOReader plugin that fulfills Adobe ACSM library loans directly on your e-reader. Borrow a book from Libby or OverDrive, transfer the `.acsm` file to your device, and start reading — no Adobe Digital Editions or computer required.

### Installation

1. Copy the `acsm.koplugin/` directory to your KOReader plugins directory:
   - Kindle: `/mnt/us/koreader/plugins/`
   - Kobo: `/.adds/koreader/plugins/`
2. Restart KOReader

### Usage

1. Borrow an ebook from your library (Libby, OverDrive, etc.) and download the `.acsm` file to your device

   > **Tip:** On Kindle (and potentially other e-readers), you can do this entirely on-device — open the e-reader's web browser, go to [libbyapp.com](https://libbyapp.com), borrow a book, and download the `.acsm` file directly. No computer needed.

2. Tap the `.acsm` file in KOReader's file browser
3. When prompted for a provider, select **ACSM** - if it does not prompt, you may need to hold down the file and select "Open with"
4. Wait for the progress messages to finish, then read

The first time you fulfill a loan, the plugin creates a one-time device activation with Adobe. This is saved and reused automatically for all future loans — no Adobe account needed.

The resulting `.epub` is saved next to the original `.acsm` file. Tapping the same `.acsm` again opens the existing EPUB without re-downloading.

### Settings

The ACSM entry in KOReader's main menu shows:

| Setting                 | Description                                                            |
| ----------------------- | ---------------------------------------------------------------------- |
| Activation status       | Whether the plugin has an active Adobe device registration             |
| Reuse existing EPUB     | Open previously downloaded EPUB instead of re-fetching (on by default) |
| Forget Adobe activation | Clear the saved activation to start fresh                              |

### Requirements

- KOReader with OpenSSL/libcrypto (included in most builds)
- WiFi connection when fulfilling a loan
- An `.acsm` file from a supported library service (tested with OverDrive/Libby)

### Acknowledgments

- [acsm-calibre-plugin](https://github.com/Leseratte10/acsm-calibre-plugin) by Leseratte10 — reference implementation for the ADEPT protocol
- [KOReader](https://github.com/koreader/koreader) — the e-reader framework this plugin targets

### License

MIT
