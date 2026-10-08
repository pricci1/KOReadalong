# KoReadalong

KoReadalong is a [KOReader](https://github.com/koreader/koreader) plugin for reading EPUB 3 books alongside their embedded audio. The Linux desktop MVP plays EPUB Media Overlays and underlines the sentence or paragraph currently being narrated.

The current implementation targets KOReader's Linux desktop build. Experimental
Kindle playback is available through KinAMP with degraded timing; the tested
device, versions, and coverage are listed below.

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
   GPLv3+ dependency; install both its player binaries/libraries and its enabled
   KOReader plugin. KoReadalong does not bundle or copy KinAMP source.
3. Install `koreadalong.koplugin` in KOReader and restart KOReader.
4. Connect your Bluetooth audio device. **KinAMP setup and help → Bluetooth
   setup** opens the official plugin's existing device settings.
5. Open a narrated EPUB and press **Start here** (or saved **Resume**) in
   **Read along**. KoReadalong starts an absent KinAMP service in idle mode and
   waits for readiness before loading narration. No terminal or separate player
   start/stop step is needed.

An already-running idle service is reused. Playing or paused external audio is
left untouched and produces a busy prompt. **Pause/Resume**, seeks, **Stop**,
and closing the book work through KoReadalong. Stop/close release only the
read-along session; they never kill or quit a shared daemon. KinAMP's official
plugin may close an idle daemon on reader/file-manager transitions or exit;
the next Start arranges readiness again. Opening a book never starts audio.

KinAMP still owns its installation, Bluetooth, saved playlists, and player
settings. KoReadalong does not pair devices or change the radio automatically.
Its **KinAMP setup and help** menu provides the integrated Bluetooth route and the
[official KinAMP documentation](https://github.com/kbarni/KinAMP/blob/master/README.md).
When the official Bluetooth API confirms that no audio device is connected,
Start offers **Bluetooth setup** before acquiring playback. Connect your device,
close those settings, and press Start again. Unknown or unsupported connection
reporting does not block playback and cannot confirm audible output.

KinAMP's command FIFO and status file are
`${KINAMP_RUNTIME_DIR:-/tmp}/kinamp_cmd` and
`${KINAMP_RUNTIME_DIR:-/tmp}/kinamp_status`. If `KINAMP_RUNTIME_DIR` is unset,
both default to `/tmp`. Missing installation, startup timeout, or a busy daemon
produces a playback prompt. If this is detected before KoReadalong creates a playlist or
delivers a playback command, correct the condition and press **Start** again
without reopening the EPUB. Once resource ownership is uncertain, playback
remains terminal for that document.

### Tested configuration

Physical validation used a Kindle Paperwhite 6 with KOReader v2026.07.1 and
KinAMP 3.0.0. It covered Bluetooth playback, playback controls, synchronized
ephemeral highlighting, pause/resume, ±15-second seeks, chapter handoff, clip
handoff, stop/restart, and document-close cleanup.

The automatic service-start path is a new release-candidate change. Its
missing-installation, timeout, readiness, and busy behavior is regression-tested;
end-to-end validation of that new path on the physical Kindle is still required.

### Troubleshooting

From a KoReadalong checkout copied to the Kindle, run the read-only diagnostic
over SSH before changing the installation:

```sh
sh scripts/kinamp-diagnostic \
    --runtime-dir "${KINAMP_RUNTIME_DIR:-/tmp}" \
    --kinamp-dir /path/to/KinAMP
```

It never opens the command FIFO, starts or signals KinAMP, or changes runtime
files. Exit status 0 means the selected checks passed, 2 identifies a known
problem, and 3 means a check was unavailable or inconclusive. Its report
sanitizes media paths and is suitable for attaching to a bug report. Use
`sh scripts/kinamp-diagnostic --help` for path overrides and all checks.

| Symptom | Check | Remedy |
| --- | --- | --- |
| KinAMP's launcher reports `libfaad.so.2 => not found` | From the KinAMP directory, run `LD_LIBRARY_PATH=libs_hf ldd ./KinAMP-minimal`. Check the extracted package for `KinAMP/libs_hf` and `KinAMP/libs_pw2`. | The KinAMP 3.0.0 `kinamp.zip` tested on August 28, 2026 omitted both library directories required by its launchers. On an armhf Kindle, copy `KinAMP/libs_hf` from the 3.0 beta archive when this diagnostic reports the missing library. Preserve the newer 3.0.0 binaries and launchers. |
| Read along reports a missing KinAMP installation | Check that the official plugin is enabled and its player binaries and bundled libraries are installed. | Complete the separate KinAMP installation and restart KOReader. Start in Read along handles service startup. |
| KinAMP did not become ready | Run the read-only diagnostic and check player dependencies. A process with broken IPC is not replaced. | Correct the installation/dependency problem and press **Start** again. Startup waits are bounded and do not block the reader. |
| Read along reports that KinAMP is busy | Check whether KinAMP is already playing or paused, or whether another client is using it. | Stop the current KinAMP playback or other client, leave KinAMP idle, and press **Start** again. Concurrent KinAMP clients are not supported. |
| KinAMP disappears after changing between the file manager and reader | The official plugin can quit an idle KinAMP daemon during that switch. | Open the EPUB and use **Start here** or saved **Resume**; KoReadalong arranges service readiness again. |
| Timing or seeks are slightly coarse | KinAMP publishes positions in whole seconds and rounds seek requests to the nearest second. | Treat Kindle timing as degraded; this is expected for the KinAMP path. |
| Resume jumps backward after a pause | KinAMP 3.0.0's `play` command can rewind its synthetic clock. | Use KoReadalong's **Pause/Resume**. The adapter works around this by resuming with a whole-second `seek` to the last published paused position. |
| Playback appears to finish after an external stop, or the final position is stale | KinAMP's protocol cannot distinguish an external stop from natural EOF. | Treat the result as ambiguous; avoid stopping the daemon from another client when reliable EOF detection matters. |
| Audio continues after the controls disappear | **Hide** only hides the controls; it does not stop playback. | Reopen **Read along** to show the controls. Use **Stop** to stop narration and reset playback to the first clip. |

### Workarounds and limitations

- **Resume workaround:** KinAMP 3.0.0 can rewind its synthetic clock when
  `play` resumes; KoReadalong uses a whole-second `seek` to the last published
  paused position instead.
- **Timing:** KinAMP publishes whole seconds and rounds seeks to the nearest
  second; fractional positions are not reported.
- **Clients:** Only one KinAMP client is supported at a time. Do not start another
  player concurrently: KinAMP has no atomic claim/startup protocol, and its
  separate launcher can replace an existing daemon.
- **Stop versus EOF:** An external stop and natural EOF are indistinguishable
  to KoReadalong.
- **Daemon ownership:** KoReadalong starts only an absent service, in idle mode,
  and verifies fresh idle status before playback. Existing processes without
  working IPC are left alone. Stop/close never quit or kill a daemon; the
  official plugin owns idle shutdown. Bluetooth connection remains a user action.
- **Controls:** **Hide** leaves playback running; use **Stop** to stop narration
  and reset playback to the first clip.

## Use

Open an EPUB containing EPUB 3 Media Overlays. Supported books gain a
compact, bottom-anchored **Read along** panel with 15-second seek buttons,
**Pause/Resume** (or **Start here** when idle), **Follow**, and **Hide**.
**More** reveals **Stop**, saved **Resume**, **Start here**, **Start over**, and
**Return to narration**; **Less** collapses those extra actions. Unavailable
actions remain disabled. **Hide** leaves narration running; the assigned
gesture reopens the compact panel. Opening a book
or the panel never starts audio automatically. **Start here** finds the first
valid narrated segment at or after the reader's current logical position;
**Stop** stops narration and resets the session to the first clip.

After narration has confirmed a location, the panel also offers **Resume**,
**Start here**, and **Start over**. **Resume** restores the saved clip and
audio position after the book or KOReader has been closed. The saved value is
kept in the book's KOReader settings sidecar as an EPUB clip identity and
XPointers, never as screen coordinates or a reader annotation. If the EPUB,
target clip, or saved XPointer no longer matches, KoReadalong discards the
stale state and **Resume** falls back to the current-position start path.
After narration reaches the end, **Start over** remains available for replay.

**Track time** is the current audio resource's position/duration, not the whole
book. The seek buttons still seek by 15 seconds within that resource.
**Book (overlays)** and its progress bar use SMIL-derived audio spans: each
distinct resource is counted once in first-appearance order, from its earliest
clip begin to its latest clip end, including internal gaps. Unreferenced audio
before/after these spans is excluded, so this is not a claim about the duration
of every full audio file. No eager extraction or duration probing is needed.
**Narrated chapter** is the current overlay-bearing spine item's ordinal/count,
not a TOC title or the count of all chapters. Gaps have no current narrated
chapter. Unknown elapsed times show **—**, including idle/loading and after
completed audio has been released; **Finished** still identifies EOF.

While narration is playing or paused, a deliberate page turn or reader jump
through the table of contents, search results, or a link suspends automatic
following without stopping audio, timing, or chapter handoff. The panel labels
this state **Playing · browsing** or **Paused · browsing** and retains the
latest valid narrated XPointer range. Choose **Return to narration** in the
panel, or assign **Reader → KoReadalong: return to narration** in Gesture
manager/Dispatcher, to jump back once and resume Following. Browsing is a
transient session state and is not restored when the book is reopened.

The panel's **Follow: on/off** control explicitly switches this same transient
state while playing or paused, without changing audio or saved progress. Turning
it on returns to the active text if available; otherwise it waits for the next
valid narrated range. **Text highlighting unavailable** means narration is active
but no current text range is resolved, not an audio failure. Embedded SMIL timing
is used unchanged, even for unusually long clips.

### Assign a gesture

The panel can be opened with any gesture supported by KOReader:

1. Open **Gesture manager**.
2. Choose a gesture, for example **Long-press on corner → Bottom right**.
3. Select **Reader → KoReadalong: show playback controls**.

The assignment is saved by KOReader. The action remains available in Gesture
manager for all reader documents, but only opens the panel when the current
book contains usable Media Overlays.

The **KoReadalong: return to narration** action is likewise available for
reader gesture/Dispatcher assignment. It is disabled when no active narrated
range is available and does not create a persistent annotation.

While reading a supported book, hold a word and choose **Read from here** in
KOReader's highlight dialog to start narration at that word's overlay segment.
This explicit XPointer selection overrides the current-position lookup. The
selection is transient and is not saved as an annotation.

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
make kinamp-integration
make smoke-integration
make run
```

`make run` launches the checksum-pinned KOReader desktop runtime with `koreadalong.koplugin` linked into its plugin directory. `make run-headless` provides a short Xvfb smoke run for environments without a display.

The project follows KOReader's upstream Luacheck configuration. LuaLS settings are included for editor assistance, but KOReader does not define an authoritative Lua type-checking gate or autoformatter.

`make mpv-integration` runs the production LuaJIT mpv process and Unix IPC
transport against a temporary WAV fixture. It uses `--ao=null` only for this
test, so it is suitable for headless development environments.

`make kinamp-integration` runs the Kindle adapter under the pinned KOReader
LuaJIT against a forked fake KinAMP daemon. The test uses a real nonblocking
command FIFO, atomically replaced status file, and temporary one-entry M3U;
it needs no KinAMP binary, audio device, Bluetooth, or Kindle. The same
lightweight test is included in `make check`.

`make smoke-integration` generates a synthetic EPUB and exercises the complete
pinned-KOReader pipeline: package and SMIL parsing, private audio extraction,
real mpv IPC, timeline lookup, CRe fragment resolution, the playback panel,
ephemeral underline, browse-away without snap-back, Return to narration,
following across a resource transition, EOF handling, and cleanup.

For native panel captures, create a scratch output directory and set
`KOREADALONG_SMOKE_SCREENSHOT_DIR` to its absolute path when running
`make smoke-integration`. The optional capture sequence exercises More/Less,
Pause/Resume, Follow off, resource transition, and Finished; its missing-text
frame temporarily removes the synthetic book's resolved range while paused.
The run uses an isolated HOME and mpv's test-only null sink. To repeat at a
narrower size, also set `EMULATE_READER_VIEWPORT='{x=0,y=0,w=400,h=700}'`.
Only synthetic fixture text/audio is generated, never private book content.

See [docs/architecture.md](docs/architecture.md) for the MVP boundaries and compatibility findings.
