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

Kindle playback is experimental and degraded. The procedure and findings below
apply to the one physical configuration listed in [Tested
configuration](#tested-configuration); they are not a support claim for other
Kindle models or firmware.

### Setup

1. Use a jailbroken Kindle running KOReader.
2. Install KinAMP separately according to
   [kbarni/KinAMP](https://github.com/kbarni/KinAMP). KinAMP is a separate
   GPLv3+ dependency; KoReadalong bundles or copies no KinAMP source.
3. Install `koreadalong.koplugin` in KOReader and restart KOReader.
4. Open the EPUB in KOReader **before** starting KinAMP.
5. From KinAMP's own installation/plugin, start the idle daemon:
   `startkinamp_koreader.sh --idle`.
6. Leave the EPUB open and leave KinAMP idle/stopped before starting playback
   from **Read along**.

With the tested Zen UI configuration, KinAMP's own KOReader plugin quits an
idle daemon when switching between the file manager and reader. The ordering in
steps 4–6 avoids that shutdown: keep the document open while using Read along.

KinAMP's command FIFO and status file are
`${KINAMP_RUNTIME_DIR:-/tmp}/kinamp_cmd` and
`${KINAMP_RUNTIME_DIR:-/tmp}/kinamp_status`. If `KINAMP_RUNTIME_DIR` is unset,
both default to `/tmp`. KoReadalong does not launch, kill, or quit KinAMP.

### Tested configuration

Physical validation used a Kindle Paperwhite 6 with KOReader v2026.07.1 and
KinAMP 3.0.0. It covered Bluetooth playback, playback controls, synchronized
ephemeral highlighting, pause/resume, ±15-second seeks, chapter handoff, clip
handoff, stop/restart, and document-close cleanup.

### Troubleshooting

| Symptom | Check | Remedy |
| --- | --- | --- |
| KinAMP's launcher reports `libfaad.so.2 => not found` | From the KinAMP directory, run `LD_LIBRARY_PATH=libs_hf ldd ./KinAMP-minimal`. Also check for `KinAMP/libs_hf` and `KinAMP/libs_pw2`. | The KinAMP 3.0.0 `kinamp.zip` tested on August 28, 2026 omitted both library directories required by its launchers. On an armhf Kindle, copy `KinAMP/libs_hf` from the 3.0 beta archive for this diagnostic result. Preserve the newer 3.0.0 binaries and launchers. |
| Read along reports that KinAMP is not running | Check that the daemon is running and that `kinamp_cmd` and `kinamp_status` exist under `${KINAMP_RUNTIME_DIR:-/tmp}`. | Start KinAMP manually with `startkinamp_koreader.sh --idle`, then retry. KoReadalong never starts, kills, or quits the daemon. |
| Read along reports that KinAMP is busy | Check whether KinAMP is already playing or paused, or whether another client is using it. | Stop the other playback, leave the daemon idle/stopped, and retry. Concurrent KinAMP clients are not supported. |
| KinAMP disappears after changing between the file manager and reader | The tested Zen UI configuration can quit an idle KinAMP daemon during that switch. | Open the EPUB first, start `startkinamp_koreader.sh --idle`, and keep the document open while using Read along. |
| Timing or seeks are slightly coarse | KinAMP publishes positions in whole seconds and rounds seek requests to the nearest second. | Treat Kindle timing as degraded; this is expected for the KinAMP path. |
| Resume jumps backward after a pause | KinAMP 3.0.0's `play` command can rewind its synthetic clock. | Use KoReadalong's **Pause/Resume**. The adapter works around this by resuming with a whole-second `seek` to the last published paused position. |
| Playback appears to finish after an external stop, or the final position is stale | KinAMP's protocol cannot distinguish an external stop from natural EOF. | Treat the result as ambiguous; avoid stopping the daemon from another client when reliable EOF detection matters. |
| Audio continues after the controls disappear | **Hide** only hides the controls; it does not stop playback. | Reopen **Read along** to show the controls. Use **Stop** to stop narration and reset playback to the first clip. |

### Workarounds and limitations

- KinAMP timing is whole-second only; fractional positions are not reported.
- Only one KinAMP client is supported at a time.
- An external stop and natural EOF are indistinguishable to KoReadalong.
- The KinAMP daemon must be running before playback starts, and its initial
  state must be idle/stopped. KoReadalong does not manage the daemon or
  Bluetooth.

## Use

Open an EPUB containing EPUB 3 Media Overlays. Supported books gain a
**Read along** panel with playback progress, 15-second seek buttons, and
**Start**, **Pause/Resume**, **Stop**, and **Hide** controls. Books without media
overlays are unaffected and do not show the menu. **Hide** hides the controls
without interrupting narration; **Stop** stops narration and resets the session
to the first clip.

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
