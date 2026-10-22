# KOReadalong reference guide

For installation, start with the [README](../README.md) or the
[Kindle tester guide](kindle.md). This reference preserves the detailed controls,
backend behavior, and historical validation findings. Test results below describe
specific checkpoints, not a guarantee for every device or a published release.

KOReadalong is a [KOReader](https://github.com/koreader/koreader) plugin for reading EPUB 3 books alongside their embedded audio. The Linux desktop MVP plays EPUB Media Overlays and marks the sentence or paragraph currently being narrated with a vertical margin bar or underline.

The current implementation targets KOReader's Linux desktop build. Experimental
Kindle playback is available through KinAMP with degraded timing; the tested
device, versions, and coverage are listed below.

## Install on Linux

KOReadalong currently requires `mpv` on `PATH`. On Debian or Ubuntu:

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
   KOReader plugin. For Opus-in-MP4 narration, see the
   [experimental player fork](#experimental-opus-in-mp4-player) below.
   KOReadalong does not bundle or copy KinAMP source.
3. Install `koreadalong.koplugin` in KOReader and restart KOReader.
4. Connect your Bluetooth audio device. **KinAMP setup and help → Bluetooth
   setup** opens the official plugin's existing device settings.
5. Open a narrated EPUB and press **Start here** (or saved **Resume**) in
   **Read along → Playback controls**. KOReadalong starts an absent KinAMP service in idle mode and
   waits for readiness before loading narration. No terminal or separate player
   start/stop step is needed.

The embedded audio must also be supported by the installed player. The tested
upstream KinAMP player routes local `.m4a`, `.m4b`, and `.mp4` files through its
MP4/AAC reader and FAAD2; it cannot decode Opus inside MP4, even when the EPUB
declares `audio/mp4`. Changing the extension or installing a GStreamer Opus
plugin does not fix that decoder path. The experimental fork below adds
Opus-in-MP4 decoding. Without it, use AAC-in-M4A/MP4 audio or the desktop mpv
backend. Any conversion should produce a separate book copy and preserve the
overlay references and timing; KOReadalong does not transcode or modify the
original book automatically.

An already-running idle service is reused. Playing or paused external audio is
left untouched and produces a busy prompt. **Pause/Resume**, seeks, **Stop**,
and closing the book work through KOReadalong. Stop/close release only the
read-along session; they never kill or quit a shared daemon. KinAMP's official
plugin may close an idle daemon on reader/file-manager transitions or exit;
the next Start arranges readiness again. Opening a book never starts audio.

If KOReader crashes during narration, reopening and pressing **Start** can
recover its orphaned track without quitting KinAMP. KOReadalong records the
reader and daemon process start identities and private audio/playlist paths.
Recovery requires a dead recorded reader, the same daemon generation, and
fresh status matching that exact single-entry music track. It stops that track,
waits for stopped acknowledgement, cleans its recorded temporary files, then
loads the new session. Unknown ownership is still refused as busy.

KinAMP still owns its installation, Bluetooth, saved playlists, and player
settings. KOReadalong does not pair devices or change the radio automatically.
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
produces a playback prompt. If this is detected before KOReadalong creates a playlist or
delivers a playback command, correct the condition and press **Start** again
without reopening the EPUB. Once resource ownership is uncertain, playback
remains terminal for that document.

### Experimental Opus-in-MP4 player

The [pricci1/KinAMP-fork `prototype/opus-mp4` source branch](https://github.com/pricci1/KinAMP-fork/tree/prototype/opus-mp4)
adds Opus-in-MP4 decoding while retaining AAC playback and the existing KinAMP
plugin/FIFO interface. Its v2 minimal player was installed and tested on a
Paperwhite 6, firmware 5.19.3.0.1, with KOReader v2026.07.1 and native GStreamer
0.10 Bluetooth output. Native acceptance covered AAC and synthetic Opus
playback, pause/resume, seeks, chapter handoff across a non-narrated spine item,
EOF/restart, close-during-playback cleanup, and silent reopening. The owner
also confirmed clear audible output and working pauses during standalone tests.

This section records the earlier Opus-only candidate. The first KOReadalong
beta provides a separate, optional Opus-and-speed player from the later candidate
below; see the [current download and installation guide](kindle.md#choose-your-downloads).
It is not an automatic upgrade. Keep the official KinAMP KOReader plugin and
its libraries; replace only `KinAMP-minimal` with the exact compatible package.
Do not use a desktop or differently targeted binary on Kindle.

The player is being dogfooded on that one device. Long-session reliability,
battery use, other Kindle models, and fragmented/encrypted MP4 support are not
certified. Existing LIPC keepalive warnings, status-position limitations, and
the legacy AAC descriptor leak remain; this is not an upstream KinAMP release
or a whole-book audio-quality guarantee.

### Playback-speed prototype

KOReadalong also interoperates with the opt-in
[KinAMP-fork `prototype/playback-speed` source branch](https://github.com/pricci1/KinAMP-fork/tree/prototype/playback-speed).
This is **not part of the installed/tested Opus player above** and is not a
drop-in upgrade for every Kindle. The exact native-tested executable is available
as an [optional first-beta download](kindle.md#install-the-optional-opusspeed-player).
A compatible player advertises `capabilities=speed-v1` and
the current resource's speed support. Only then does **More** reveal speed
controls on Kindle. Stock KinAMP receives no speed commands and keeps its
existing panel and resume workaround.

The prototype supports 0.5–3× for AAC-in-MP4 and Opus-in-MP4 using pitch-preserving
PCM processing. KOReadalong applies the saved per-book speed before starting
each track; live changes do not resume paused playback. The displayed rate is
the requested speed, not a measurement of already-audible audio: queued audio
at the old rate drains first, so change latency is not guaranteed. Positions
remain source-media time, with millisecond estimates from the prototype; seeks
still round to whole seconds. Neither this clock nor the UI measures Bluetooth
output latency.

Host synthetic player tests and KOReadalong's real-daemon adapter checks cover
speed, pause/resume, seeks, AAC/Opus handoff, EOF, and cleanup. The speed
candidate builds against the supplied PW6 runtime, passes static ABI
preflight, and passes a synthetic ARM/QEMU speed matrix with GStreamer 0.10.25
and silent sinks. QEMU does not exercise native mixersink output.

A separately staged speed candidate was also tested on the same PW6 and firmware
with KOReader v2026.07.1, native mixersink libraries, and connected Bluetooth
output. Public synthetic speech exercised both codecs, 0.5–3× limits, live
changes, paused speed changes/seeks, AAC→Opus chapter handoff, EOF, and silent
close/reopen with saved 1.5× applied to a fresh daemon. The owner listened at
1× and 1.5× and reported that both sounded right; this is subjective feedback,
not a whole-book speech-quality guarantee.

Native testing exposed two client issues that are now fixed: paused clocks
reconcile late backend observations and repaint their actual screen rectangles;
Exit cancels narration callbacks before KinAMP can quit a paused daemon.
Focused single-Exit trials while paused and playing both closed KOReader with
exit code 0, released session files, and showed no daemon-disappeared prompt.
These are bounded shutdown checks, not a power-off/reboot test.

Comparable standalone measurements used the same fixtures and native libraries:

| Measurement | Accepted player 1× | Speed candidate 1× | Speed candidate 2× |
| --- | ---: | ---: | ---: |
| AAC observed EOF interval | 28.07 s | 28.07 s | 14.03 s |
| Opus observed EOF interval | 30.06 s | 30.08 s | 15.03 s |
| AAC CPU, median % of one core | 8.80% | 10.96% | 27.45% |
| Opus CPU, median % of one core | 7.49% | 9.48% | 24.92% |

EOF intervals are single-run status observations, not audible-output timing;
CPU medians use three comparable runs, measuring process user+system tick deltas
between the second and eighth one-second samples (about six seconds per window,
excluding startup and EOF). Sending `speed 2` to the accepted player left its EOF
intervals unchanged, as expected. Both players still exhibited the legacy AAC
descriptor growth. These bounded tests do not establish battery life,
long-session reliability, precise Bluetooth latency, or support for other Kindle
models. At that testing checkpoint the accepted installation was not upgraded;
the speed candidate was subsequently installed on the owner's main profile for
dogfooding. Do not install a desktop or differently targeted binary on Kindle.

### Tested configuration

Physical validation used a Kindle Paperwhite 6 with KOReader v2026.07.1 and
KinAMP 3.0.0. It covered Bluetooth playback, playback controls, synchronized
ephemeral highlighting, pause/resume, ±15-second seeks, chapter handoff, clip
handoff, stop/restart, and document-close cleanup.

The first-version candidate's automatic service startup was additionally tested
on this device on October 8, 2026: absent-daemon startup, pause/resume, seeks,
browse/return, stop, missing-player and startup-timeout recovery, busy-client
refusal, and native close/reopen with automatic restart. The synthetic
chapter-transition fixture crossed spine index 3 → a non-overlay item at 4 →
the next narrated item at 5, reached EOF, and released its temporary audio.
The integrated Bluetooth prompt/settings and closed-handle recovery were also
verified. The user subsequently confirmed audible headphone playback with
approximately one second of delay, but reported repeated native KOReader
crashes with audio continuing. A kernel core from a never-debugger-attached
reader, with Audiobook disabled, identified a KOReadalong heap overwrite:
string-initialized variable-length FFI buffers omitted the terminating NUL's
space. The FIFO and playlist allocations are fixed without sending that NUL.
The short-command/garbage-collection regression crashed with the old port on
the Kindle and passed with the fix. Connected native acceptance on the final
fixed build then passed pause/resume, both 15-second seeks, six Stop/Start
cycles, and three Home → Continue → Start → close cycles without a crash.
The same reader process survived throughout; reopening did not start audio,
and close released the session receipt and left the daemon absent. This is
bounded stability evidence, not a guarantee against every crash. Listening
confirmation was still pending at that checkpoint; the later fork acceptance
and its remaining limits are described above. Neither establishes a broad
release-readiness or whole-book audio-quality claim.

Orphan recovery passed automated regressions, a real-KinAMP backend test, and
native Start in a reopened reader: it stopped the exact recorded orphan in the
same daemon generation, cleaned its old audio/M3U and started a new session.
The backend test also refused a live-owner attempt without writes and verified
pause/resume/seek/stop. The installed full player identifies 3.0.0; the minimal
daemon's exact version remains unverified.

### Troubleshooting

From a KOReadalong checkout copied to the Kindle, run the read-only diagnostic
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

KOReader's optional HTTP inspector is unauthenticated and can invoke arbitrary
methods. Use it only on a trusted LAN for testing, never expose it publicly,
and stop it and disable autostart afterward. Prefer native book opening during
device tests. The heap-overwrite crash was reproduced through native controls
with the inspector stopped; disabling the inspector alone does not fix it.

| Symptom | Check | Remedy |
| --- | --- | --- |
| KinAMP's launcher reports `libfaad.so.2 => not found` | From the KinAMP directory, run `LD_LIBRARY_PATH=libs_hf ldd ./KinAMP-minimal`. Check the extracted package for `KinAMP/libs_hf` and `KinAMP/libs_pw2`. | The KinAMP 3.0.0 `kinamp.zip` tested on August 28, 2026 omitted both library directories required by its launchers. On an armhf Kindle, copy `KinAMP/libs_hf` from the 3.0 beta archive when this diagnostic reports the missing library. Preserve the newer 3.0.0 binaries and launchers. |
| Read along reports a missing KinAMP installation | Check that the official plugin is enabled and its player binaries and bundled libraries are installed. | Complete the separate KinAMP installation and restart KOReader. Start in Read along handles service startup. |
| KinAMP did not become ready | Run the read-only diagnostic and check player dependencies. A process with broken IPC is not replaced. | Correct the installation/dependency problem and press **Start** again. Startup waits are bounded and do not block the reader. |
| Read along times out waiting for KinAMP audio | A timeout alone is not a codec diagnosis. Check the selected extracted media with `ffprobe` and the player's decoder evidence; an Opus MP4 produces `atom 'mp4a' not found` and `Failed to open file with mp4read` in the tested upstream player. | For confirmed Opus-in-MP4, consider the [experimental player fork](#experimental-opus-in-mp4-player), a separately prepared AAC book copy, or the desktop backend. Switching upstream KinAMP's GStreamer flavour does not add Opus decoding. |
| Read along reports that KinAMP is busy | Check whether KinAMP is already playing or paused, or whether another client is using it. | Stop the current KinAMP playback or other client, leave KinAMP idle, and press **Start** again. Concurrent KinAMP clients are not supported. |
| KinAMP disappears after changing between the file manager and reader | The official plugin can quit an idle KinAMP daemon during that switch. | Open the EPUB and use **Start here** or saved **Resume**; KOReadalong arranges service readiness again. |
| Timing or seeks are slightly coarse | Stock KinAMP publishes whole seconds; the speed prototype adds millisecond estimates. Both round seek requests to the nearest second. | Treat Kindle timing as degraded; fractional estimates do not establish an exact audible playhead. |
| Resume jumps backward after a pause | KinAMP 3.0.0's `play` command can rewind its synthetic clock. | Use KOReadalong's **Pause/Resume**. The adapter works around this by resuming with a whole-second `seek` to the last published paused position. |
| Playback appears to finish after an external stop, or the final position is stale | KinAMP's protocol cannot distinguish an external stop from natural EOF. | Treat the result as ambiguous; avoid stopping the daemon from another client when reliable EOF detection matters. |
| Audio continues after the controls disappear | **Hide** only hides the controls; it does not stop playback. | Reopen **Read along → Playback controls** to show the controls. Use **Stop** to stop narration and reset playback to the first clip. |
| Audio continues after a reader crash | KinAMP is independent and does not monitor reader death. | Reopen KOReader and the EPUB, then press **Start**. A positively identified orphan is recovered automatically; unknown or other-client playback is left untouched. |

### Workarounds and limitations

- **Resume workaround:** Stock KinAMP 3.0.0 can rewind its synthetic clock when
  `play` resumes; KOReadalong uses a whole-second `seek` to the last published
  paused position instead. The speed-v1 prototype resumes with `play` and
  preserves pause when seeking.
- **Timing:** Stock KinAMP publishes whole seconds. The speed-v1 prototype
  publishes fractional estimates in source-media time; both still round seeks
  to the nearest second. Output latency is not measured or compensated.
- **Clients:** Only one KinAMP client is supported at a time. Do not start another
  player concurrently: KinAMP has no atomic claim/startup protocol, and its
  separate launcher can replace an existing daemon.
- **Stop versus EOF:** An external stop and natural EOF are indistinguishable
  to KOReadalong.
- **Daemon ownership:** KOReadalong starts only an absent service, in idle mode,
  and verifies fresh idle status before playback. Existing processes without
  working IPC are left alone. Stop/close never quit or kill a daemon; the
  official plugin owns idle shutdown. Bluetooth connection remains a user action.
- **Crashes:** KinAMP can continue audio until the next explicit Start reclaims
  a recorded orphan. Recovery is not an atomic cross-client lease: do not run
  competing clients concurrently. Sessions from older versions without an
  ownership receipt cannot be automatically reclaimed.
- **Controls:** **Hide** leaves playback running; use **Stop** to stop narration
  and reset playback to the first clip.

## Use

Open an EPUB containing EPUB 3 Media Overlays. Choose **Read along → Playback
controls** to open the compact, bottom-anchored panel with 15-second seek buttons,
**Pause/Resume** (or **Start here** when idle), **Follow**, and **Hide**.
**More** reveals **Stop**, saved **Resume**, **Start here**, **Start over**, and
**Return to narration**; **Less** collapses those extra actions. Unavailable
actions remain disabled. On supported backends, **More** also shows speed controls:
**−0.1×** and **+0.1×** adjust from **0.5× to 3×**, and the middle **Reset**
button returns to **1×**. On desktop speed can be changed before starting,
while playing, or while paused, and is remembered per book across reopening
and chapter changes. On Kindle the controls appear only after discovery of a
supported track in the [speed prototype](#playback-speed-prototype); a saved
speed is applied on start even before the controls appear.
The compact status line shows the selected speed. Track and book times stay in
original media seconds, so seeks and text synchronization remain unchanged.
Stock Kindle/KinAMP omits speed controls and plays at its normal rate.
**Hide** leaves narration running; the assigned
gesture reopens the compact panel. Opening a book
or the panel never starts audio automatically. **Start here** finds the first
valid narrated segment at or after the reader's current logical position;
**Stop** stops narration and resets the session to the first clip.

Overlay clips whose end time is at or before their start time are skipped
without changing the EPUB or inventing corrected timestamps. A warning once
per book opening reports the count; valid clips remain usable. Skipped text
has no synchronized overlay, but the underlying audio may still play. If no
valid clips remain, the warning explains that Read along is unavailable.
Malformed clocks, broken references, and other structural errors remain fatal.

After narration has confirmed a location, the panel also offers **Resume**,
**Start here**, and **Start over**. **Resume** restores the saved clip and
audio position after the book or KOReader has been closed. The saved value is
kept in the book's KOReader settings sidecar as an EPUB clip identity and
XPointers, never as screen coordinates or a reader annotation. If the EPUB,
target clip, or saved XPointer no longer matches, KOReadalong discards the
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
following without stopping audio, timing, or chapter handoff, except when moving
forward within the pages covered by the current narrated passage. You can turn
through a passage spanning several pages without switching Follow off; its
narration mark stays visible on the continuation pages unless marks are off. Moving backward, jumping
within the same page, or moving beyond the passage still suspends following.
The panel labels this state **Playing · browsing** or **Paused · browsing** and
retains the latest valid narrated XPointer range. Choose **Return to narration** in the
panel, or assign **Reader → KOReadalong: return to narration** in Gesture
manager/Dispatcher, to jump back once and resume Following. Browsing is a
transient session state and is not restored when the book is reopened.

The panel's **Follow: on/off** control explicitly switches this same transient
state while playing or paused, without changing audio or saved progress. Turning
it on returns to the active text if available; otherwise it waits for the next
valid narrated range. **Text highlighting unavailable** means narration is active
but no current text range is resolved, not an audio failure. Embedded SMIL timing
is used unchanged, even for unusually long clips.

### Narration marks

Choose **Read along → Narration mark** to select **Margin bar** (the default),
**Underline**, or **Off**. This preference is saved for all books and takes
effect immediately, including while paused. Off hides only the mark: audio,
page following, and Return to narration continue to work.

The margin bar sits just outside the page's text column and spans the visible
lines of the active narration target. A two-page spread gets a separate bar on
each affected page. Unlike an underline, the bar identifies lines rather than
exact word boundaries. With no room in the page margin, the bar is omitted
rather than drawn over the text. Neither style creates a saved annotation.

### Assign a gesture

The panel can be opened with any gesture supported by KOReader:

1. Open **Gesture manager**.
2. Choose a gesture, for example **Long-press on corner → Bottom right**.
3. Select **Reader → KOReadalong: show playback controls**.

The assignment is saved by KOReader. The action remains available in Gesture
manager for all reader documents, but only opens the panel when the current
book contains usable Media Overlays.

The **KOReadalong: return to narration** action is likewise available for
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

For experimental phone-audio following, including setup, timing correction,
trusted-LAN requirements, and physical-device test limits, see
[remote playback](remote-playback.md). That mode has its own controls and does
not use the local mpv/KinAMP transport described above.

From the repository root on a Debian-based development machine, install the
development dependencies and checksum-pinned KOReader runtime, then run the checks:

```sh
./.agents/setup
make check
make mpv-integration
make kinamp-integration
make smoke-integration
make remote-integration
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
ephemeral narration mark, browse-away without snap-back, Return to narration,
following across a resource transition, EOF handling, and cleanup.

For native panel captures, create a scratch output directory and set
`KOREADALONG_SMOKE_SCREENSHOT_DIR` to its absolute path when running
`make smoke-integration`. The optional capture sequence exercises More/Less,
Pause/Resume, speed adjustment while paused, Follow off, resource transition,
and Finished; its missing-text
frame temporarily removes the synthetic book's resolved range while paused.
The run uses an isolated HOME and mpv's test-only null sink. To repeat at a
narrower size, also set `EMULATE_READER_VIEWPORT='{x=0,y=0,w=400,h=700}'`.
Only synthetic fixture text/audio is generated, never private book content.

See [architecture.md](architecture.md) for the MVP boundaries and compatibility findings.
