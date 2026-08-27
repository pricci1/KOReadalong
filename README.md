# KoReadalong

KoReadalong is a [KOReader](https://github.com/koreader/koreader) plugin for reading EPUB 3 books alongside their embedded audio. The Linux desktop MVP plays EPUB Media Overlays and underlines the sentence or paragraph currently being narrated.

The current implementation targets KOReader's Linux desktop build. A jailbroken Kindle with Bluetooth audio is the planned hardware target, but Kindle playback is not implemented yet.

## Install on Linux

KoReadalong currently requires `mpv` on `PATH`. On Debian or Ubuntu:

```sh
sudo apt install mpv
```

Copy `koreadalong.koplugin` into KOReader's `plugins` directory, preserving the
directory name, then restart KOReader:

```text
koreader/
└── plugins/
    └── koreadalong.koplugin/
        ├── _meta.lua
        ├── main.lua
        └── …
```

Open an EPUB containing EPUB 3 Media Overlays. Supported books gain a
**Read along** panel with playback progress, 15-second seek buttons, and
**Start**, **Pause/Resume**, **Stop**, and **Close** controls. Books without
media overlays are unaffected and do not show the menu.

The panel can also be assigned to any native KOReader gesture. In **Gesture
manager**, choose a gesture such as **Long-press on corner → Bottom right**,
then select **Reader → KoReadalong: show playback controls**.

While reading a supported book, hold a word and choose **Read from here** in
KOReader's highlight dialog to start narration at that word's overlay segment.
The selection is transient and is not saved as an annotation.

The current MVP supports ordinary Storyteller-style SMIL targets using XHTML
element IDs and follows narration onto the page containing the active target.
Web Text Fragment targets, complex DOM ranges, and Kindle audio are not yet
supported. Underlines are ephemeral and never create KOReader annotations.

## Development

Fresh Amp orbs are prepared by `.agents/setup`. On another Debian-based machine, run it directly:

```sh
./.agents/setup
make check
make mpv-integration
make smoke-integration
make run
```

`make run` launches the checksum-pinned KOReader desktop runtime with `koreadalong.koplugin` linked into its plugin directory. `make run-headless` provides a short Xvfb smoke run for environments without a display.

The project follows KOReader's upstream Luacheck configuration. LuaLS settings are included for editor assistance, but KOReader does not define an authoritative Lua type-checking gate or autoformatter.

`make mpv-integration` runs the production LuaJIT mpv process and Unix IPC
transport against a temporary WAV fixture. It uses `--ao=null` only for this
test, so it is suitable for headless development environments.

`make smoke-integration` generates a synthetic EPUB and exercises the complete
pinned-KOReader pipeline: package and SMIL parsing, private audio extraction,
real mpv IPC, timeline lookup, CRe fragment resolution, ephemeral underline,
EOF handling, and cleanup.

See [docs/architecture.md](docs/architecture.md) for the MVP boundaries and compatibility findings.
