# KoReadalong

KoReadalong is a [KOReader](https://github.com/koreader/koreader) plugin for reading EPUB 3 books alongside their embedded audio. The Linux desktop MVP plays EPUB Media Overlays and underlines the sentence or paragraph currently being narrated.

The current implementation targets KOReader's Linux desktop build. Experimental
Kindle playback is available through KinAMP with degraded timing. Playback,
Bluetooth audio, controls, chapter handoff, and cleanup have been validated on
a Kindle Paperwhite 6 with KOReader v2026.07.1 and KinAMP 3.0.0.

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

## Experimental Kindle/KinAMP support

Kindle playback is experimental and degraded. It requires:

1. A jailbroken Kindle running KOReader.
2. KinAMP installed separately according to
   [kbarni/KinAMP](https://github.com/kbarni/KinAMP).
3. The KoReadalong plugin installed in KOReader, followed by a KOReader
   restart.
4. KinAMP manually started through its own installation/plugin, with its
   daemon left idle/stopped before using KoReadalong.

The KinAMP 3.0.0 `kinamp.zip` tested on August 28, 2026 omitted the
`KinAMP/libs_hf` and `KinAMP/libs_pw2` directories required by its launchers.
On an armhf Kindle, copy `KinAMP/libs_hf` from the 3.0 beta archive if
`LD_LIBRARY_PATH=libs_hf ldd ./KinAMP-minimal` reports
`libfaad.so.2 => not found`. Preserve the newer 3.0.0 binaries and launchers.

KinAMP's command FIFO and status file live under
`${KINAMP_RUNTIME_DIR:-/tmp}`. KoReadalong does not launch, kill, or quit
KinAMP. A missing or busy KinAMP daemon produces a clear playback error.
Observed timing is in whole seconds, and seeks are rounded to the nearest
second. Concurrent KinAMP clients are not supported. KinAMP's protocol cannot
distinguish an external stop from natural EOF, so those outcomes are
indistinguishable to KoReadalong. KinAMP 3.0.0 can rewind its synthetic clock
when resuming with `play`, so KoReadalong resumes with a whole-second `seek` to
the last paused position instead.

With the tested Zen UI configuration, KinAMP's own KOReader plugin quits an
idle daemon while switching between the file manager and reader. Open the EPUB
first, then start `startkinamp_koreader.sh --idle`, and leave the document open
while using Read along.

KinAMP is a separate GPLv3+ dependency from kbarni/KinAMP; no KinAMP source is
bundled or copied into KoReadalong.

## Use

Open an EPUB containing EPUB 3 Media Overlays. Supported books gain a
**Read along** panel with playback progress, 15-second seek buttons, and
**Start**, **Pause/Resume**, **Stop**, and **Close** controls. Books without
media overlays are unaffected and do not show the menu. **Close** hides the
panel without interrupting narration; **Stop** stops narration and resets the
session to the first clip.

### Assign a gesture

The panel can be opened with any gesture supported by KOReader:

1. Open **Gesture manager**.
2. Choose a gesture, for example **Long-press on corner → Bottom right**.
3. Select **Reader → KoReadalong: show playback controls**.

The assignment is saved by KOReader. The action remains available in Gesture
manager for all reader documents, but only opens the panel when the current
book contains usable Media Overlays.

While reading a supported book, hold a word and choose **Read from here** in
KOReader's highlight dialog to start narration at that word's overlay segment.
The selection is transient and is not saved as an annotation.

The current MVP supports ordinary Storyteller-style SMIL targets using XHTML
element IDs and follows narration onto the page containing the active target.
Web Text Fragment targets and complex DOM ranges are not yet supported.
Kindle playback is available only through the experimental/degraded KinAMP
path described above. Underlines are ephemeral and never create KOReader
annotations.

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
real mpv IPC, timeline lookup, CRe fragment resolution, the playback panel,
ephemeral underline, EOF handling, and cleanup.

See [docs/architecture.md](docs/architecture.md) for the MVP boundaries and compatibility findings.
