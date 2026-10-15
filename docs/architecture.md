# KoReadalong architecture

## MVP outcome

Open a Storyteller-compatible EPUB in KOReader, start or pause its embedded narration, seek with the book/audio controls, and underline the active text target as playback advances. Desktop Linux is the first implementation environment; the experimental Kindle adapter uses the same backend contract.

## Input contract

Storyteller emits standard EPUB 3 Media Overlays:

1. The package OPF manifest associates an XHTML item with a SMIL item through `media-overlay`.
2. SMIL `par` leaves pair a text target (`text src="chapter.xhtml#fragment"`) with an audio clip (`audio src="track.mp3" clipBegin="…" clipEnd="…"`).
3. `seq` nodes provide grouping; read-along timing comes from ordered `par` leaves.
4. Storyteller normally targets sentence/word span IDs and may instead emit Web Text Fragments (`#:~:text=`). The MVP supports ordinary ID fragments first.

All resource paths are resolved relative to the file containing the reference. Clock parsing must accept colon clocks and `h`, `min`, `s`, and `ms` units. The parser should tolerate `%23` where a fragment separator was URL-encoded.

## Components

```text
EPUB package ──▶ Media-overlay parser ──▶ ordered clip timeline
                                                  │
                                                  ▼
KOReader reader ◀── XPointer/overlay adapter ◀── playback coordinator
                                                  │
                              ┌───────────────────┴───────────────────┐
                              ▼                                       ▼
                     desktop audio adapter                   Kindle audio adapter
                     (Linux development)                    (daemon + IPC)
```

- **Media-overlay parser:** reads OPF/SMIL and returns platform-neutral clips. It must not depend on rendering or playback.
- **Playback coordinator:** maps audio position to a clip with binary search,
  chooses the first valid target at or after a reader XPointer, validates and
  resumes saved clip locations, updates the active text target, and coordinates
  chapter/audio transitions.
- **Reader adapter:** converts EPUB fragment IDs to CRe XPointers, derives current screen boxes, and paints ephemeral underlines. It recomputes boxes on page/position updates and document rerenders.
- **Narration state store:** stores a content-identified clip, its XPointers,
  and confirmed audio position in KOReader's per-book `DocSettings` sidecar.
  It rejects changed clip timelines and is independent of annotations and
  rendered screen geometry.
- **Audio adapter:** exposes `open(path, { position = 0, paused = false, speed = 1 })`,
  `setPaused`, `seek`, `stop`, `getStatus`, and `close`, with optional `setSpeed`
  and dynamic `supportsSpeed`. Desktop and Kindle implementations share this
  contract; speed changes never change pause intent or media-time units.

## Parser and timeline contract

The platform-neutral parser is `mediaoverlays.lua` inside the plugin directory. It
accepts the extracted OPF XML, the OPF containing path, and a map from normalized
ZIP-entry paths to extracted SMIL XML:

```lua
local clips, error_message = MediaOverlays.parse(
    opf_xml,
    "book/package.opf",
    {
        ["book/media/chapter.smil"] = smil_xml,
    }
)
```

Each returned clip has `text_path`, `text_fragment`, `spine_index`,
`audio_path`, `clip_begin`, and `clip_end`. `spine_index` is the exact
zero-based index CRe assigns after filtering the OPF spine: every preceding
itemref resolving to a manifest item with a non-empty `id` and `href` counts,
including `linear="no"`, non-overlay, unsupported or unavailable content, and
repeated valid entries. Unresolved itemrefs and manifest items missing an `id`
or `href` do not count. Paths are normalized relative to the containing
document and remain ZIP-entry paths; the parser does not assume an `OEBPS/`
root. Repeated normalized content hrefs in the spine are rejected as
unsupported because CRe's path substitution cannot provide an exact mapping.
A parse failure returns `nil, error_message`.

Production integration uses the same parser through an archive-entry callback:

```lua
local clips, error_message = MediaOverlays.load(function(path)
    return document:getDocumentFileContent(path)
end)
```

`load` follows `META-INF/container.xml` to the package document and reads only
the SMIL files referenced by spine media overlays. Archive access remains
injected so parser tests do not depend on KOReader or a physical EPUB file.

`timeline.lua` provides `Timeline.new(clips):lookup(audio_path, playback_time)`.
Construction groups clips by `audio_path` and rejects non-monotonic clip clocks
within a resource. Lookup uses binary search and half-open clip intervals,
`[clip_begin, clip_end)`: a shared boundary selects the following clip, a gap
returns `nil`, and an unknown resource returns `nil`.

## Current fragment-resolution slice

`fragmentresolver.lua` is a platform-neutral, plugin-only resolver for the
current Storyteller ID-fragment form. It builds
`#_doc_fragment_<spine_index>_ <text_fragment>` (including the literal space
after the underscore) and uses only the injected CRe operations
`isXPointerInDocument`, `getTextFromXPointer`,
`getNextVisibleChar`, `getTextFromXPointers`, and `compareXPointers`.

The resolver supports ordinary unique sentence/word IDs whose target has
non-empty, visibly rendered inline text, including formatted inline children.
Inline node transitions may advance the XPointer without adding extracted
bytes; every transition must strictly advance in document order and counts
toward the total 4096-step cap. Decreasing lengths and byte-prefix mismatches
still fail closed. Consecutive audio clips may repeat the same sentence ID:
the coordinator keeps the next distinct target as the boundary, stopping its
lookahead at a change in text path or spine context.
It accepts a range only when the
recovered text is an exact byte-for-byte match, with ordered XPointers and an
optional next-target boundary. It does not normalize text, search globally,
or approximate a match. Web Text Fragments, empty/whitespace, hidden,
image-only, duplicate/ambiguous, ruby, block, and generated-content targets
are outside this boundary and fail closed. The parser rejects duplicate
manifest IDs and duplicate XHTML content hrefs rather than claiming an exact
CRe mapping.

This slice deliberately does not add a native CRe node-range binding. If
differential fixtures ever show that this exact invariant accepts a wrongly
bounded range, native node-range binding is the fallback rather than dynamic
CSS, which would rerender on narration cadence.

## KOReader integration

`koreadalong.koplugin/main.lua` is a document-only plugin. Expected lifecycle hooks are `onReaderReady`, `onPageUpdate`, `onPosUpdate`, `onDocumentRerendered`, and `onCloseDocument`.

The reader supplies `document:getXPointer()` to the coordinator when the user
chooses **Start here**. The coordinator compares that logical position with
resolved clip ranges, so page numbers, screen boxes, and transient rendering
state do not affect start selection. Opening the document only constructs the
coordinator; it never starts audio.

Current-position and selection lookups ask `fragmentresolver.getSpineIndex`
for an optional exact chapter context. The resolver calls CRe's
`getNormalizedXPointer` and recognizes only `/body/DocFragment[N]/body`
wrappers, mapping one-based `N` to the parser's zero-based spine index.
Unknown layouts, missing APIs, and normalization failures retain the generic
timeline search. The coordinator filters clip metadata before requesting
ranges: current-position lookup excludes earlier spine items; selection
lookup also excludes items beyond its recognized end context. Non-overlay
items remain real spine positions, so Start here in a gap advances to the next
valid narrated chapter. Candidates retain timeline order, without assuming
monotonic targets within a chapter. Existing lazy range caching serves both
paths; no startup or polling precomputation is introduced. Metadata filtering
is still linear in clip count, but expensive text resolution is chapter-local.

Reader following is a transient session state owned by `main.lua`. New starts,
explicit **Read from here**, **Stop**, EOF, errors, and document close reset it
to **Following**; **Browsing** is never persisted. While Following, an active
range outside the visible page uses the existing `GotoXPointer` path. A
deliberate reader move while playing or paused changes only this state: audio,
adapter polling, confirmed narration persistence, and timeline/resource
handoff continue normally.

KOReader's pinned runtime emits one `InputEvent` per input frame without source
metadata, followed by `PageUpdate`/`PosUpdate` notifications for page turns and
programmatic jumps. `main.lua` therefore correlates those events with the
current XPointer and uses a bounded expected-navigation guard containing the
plugin target's XPointer, page, position, input sequence, and event budget.
Duplicate page/position notifications are consumed by that target-aware guard;
newer input invalidates it. Rerender, rotation, dimensions, zoom, font, and
partial-rerender hooks suppress their resulting position events instead of
classifying them as browsing. This avoids both the old one-event race and
false suspension from asynchronous reader redraws.

The latest valid active range remains in XPointers while Browsing even when its
ephemeral screen underline is off-page. **Return to narration** jumps to that
range once, refreshes the underline, and returns to Following; it is disabled
or reports one calm localized message when no valid current range exists. The
playback dialog renders the state and action with normal KOReader button sizing,
and Dispatcher/Gesture Manager exposes the return action statically while its
runtime handler performs the current-range check.

**Follow: on/off** switches the same transient Following/Browsing state, never a
persisted preference or audio mode. Off retains the latest valid range; on uses
Return to narration when a range exists, otherwise enables future following
without a navigation event. The coordinator status exposes `has_text_range`
independently of transport state. Playing/paused with no range shows a calm text
highlighting hint, not a backend error or repeated dialog. Clip duration does not
imply timing confidence and no SMIL retiming or global offset is applied.

The coordinator remains platform-neutral. Its only reader-facing additions are
the narrow current-range accessor and range-cleared signal used to retain or
discard the active XPointer; `mpvaudio.lua`, `kindleaudio.lua`, and
`kinampport.lua` do not own reader navigation.

Dynamic read-along marks should be a registered reader view module with a `paintTo` method. Persisted highlights are intentionally avoided because narration state must not enter KOReader's annotations/bookmarks/export systems. Text anchors are stored as XPointers; rendered boxes are display-dependent cache entries only. Confirmed narration state is stored separately in the book's `DocSettings` sidecar and is cleared when the user chooses **Stop**, **Start over**, or reaches EOF.

### Compact controls and overlay progress

`playbackdialog.lua` retains sole ownership of the native `ButtonDialog`.
Its `MovableContainer` anchor is a point near the current screen's bottom,
with a scaled inset to keep the entire border visible, centered using the
dialog's computed width. This uses the shipped anchor API
instead of wrapping the existing center container in `BottomContainer` or
introducing a second panel framework. It remains a movable/dismissable native
dialog (not a dock that changes the reader viewport). Two standard button rows
hold seek/transport and Follow/Hide/More. More/Less uses ButtonDialog's reinit
with the same added status widgets and refresh callback; extra rows expose
Stop/Return and start choices. The status group's `parent` marker opts into
ButtonDialog's added-widget preservation during reinit (without it native
TextBox buffers are freed). Disabled choices stay present so saved Resume
and Start over become available as the session state changes. Hide/close
unschedules refresh; an already-dequeued callback checks ownership before
doing anything. Collapse dirties all window layers to repaint the entire old
footprint, not just refresh pixels over the old panel without redrawing text.

Speed control is an optional adapter capability (`setSpeed`, or a dynamic
`supportsSpeed` when discovery is needed). The
coordinator validates 0.5–3×, keeps the chosen speed separate from media clocks,
and supplies it on every resource open. mpv applies speed before unpausing the
new track and supports live changes without seeking or changing pause intent.
The expanded panel offers 0.1× steps and a reset; unsupported adapters omit the
row and speed label. Discovery can add/remove the row while the expanded panel
is open; reinit preserves status widgets and dirties the old footprint.
`main.lua` persists the choice in the per-book DocSettings
key `koreadalong_playback_speed`, independently of resumable narration location.
Stopping, starting over, or reaching EOF clears location, not speed.

Pausing changes intent immediately, but adapter pause/seek commands can complete
asynchronously. The coordinator keeps polling confirmed paused positions so the
track/book clocks, range, and saved location converge to the backend observation.
The panel likewise keeps checking paused status, but does not repaint unchanged
paused text/progress. Partial refreshes use the text and progress bar's painted
rectangles: their `VerticalGroup` provides layout, not a screen rectangle.
Hide and document close still cancel their owned callbacks.

Exit and Close broadcasts run the same idempotent cleanup synchronously, without
consuming the event. Official KinAMP may quit paused audio during Exit while
KOReader defers CloseDocument to the next tick; waiting for that later event
lets a due narration poll show a daemon-disappeared prompt during shutdown.
Early cleanup cancels active polling; it does not take over global daemon quit.

Status text reserves measured height including the optional missing-text hint.
Translated labels and long time samples are measured at the actual width;
if a later string exceeds the reserve, an unbounded TextBoxWidget measurement
grows the reserve and rebuilds parent layouts after updating the text. Neither
polling nor More/Less relies on stale VerticalGroup offsets.

`Timeline:getBookProgress` derives metadata once from ordered clips. For each
distinct archive audio path it stores the minimum/first begin and maximum end,
and accumulates these extents once in first-resource-appearance order. The
span includes interior gaps but excludes unreferenced leading/trailing audio;
repeated text targets and multiple XHTML chapters do not duplicate resources.
Elapsed overlay time is the preceding resource spans plus the current observed
track time minus that resource's first begin, clamped to the span. This is an
overlay-derived traversal metric, not actual whole-file runtime; publications
that reuse/interleave a resource follow this same distinct-resource convention.
There is no audio extraction/probe, clip retiming, global offset, or change to
track fields/seek semantics. Unknown resources or clocks yield unknown elapsed
time, never guessed progress. Idle, loading, stopping and error expose no book
elapsed time; after EOF releases the resource, Finished likewise shows unknown
elapsed time rather than inventing an observation of the final clock.

The coordinator exposes book elapsed/duration and narrated-spine ordinal/count
alongside unchanged track fields. Chapter lookup uses the timeline's active
half-open clip, so gaps/exact final boundaries have no chapter. Only distinct
spine items with overlay clips count. KOReader's `ReaderToc:getTocTitleByPage`
exists at the reader boundary, but this panel intentionally uses the truthful
metadata ordinal rather than a title derived from the user's browsing position.
No document or TOC access is added to audio adapters.

## Audio adapters

The desktop adapter is `mpvaudio.lua`. It owns one `mpv` process per adapter
session and exposes the platform-neutral `open(path, options)`, `setPaused`,
`seek`, `stop`, `getStatus`, and idempotent `close` contract. `open` accepts a
finite non-negative initial position and a boolean paused intent. It is valid
only while the adapter has no active resource; it does not replace a resource
that is loading, playing, paused, or ended. Its states are `idle`, `loading`,
`playing`, `paused`, `ended`, `error`, and `closed` (the desktop implementation
may expose `startup` before its first open). Opening is accepted before mpv
has converged: readiness is reported only after observed properties confirm a
decoded, non-idle resource and the requested paused state. `setPaused` is an
idempotent set operation rather than a toggle. `end-file`, property changes,
process exit, and IPC failures reconcile the status.

The process uses the `mpv` package installed by `.agents/setup`, argv-only
`execvp`, `--no-config`, idle/no-video/no-terminal mode, disabled input
bindings, a private Unix-domain JSON IPC socket, and
`--audio-fallback-to-null=no`. The transport keeps a newline-delimited JSON
connection with nonblocking connect, reads, and writes; UI polling is scheduled
through KOReader's `UIManager:scheduleIn` at roughly 180 ms and never waits on
IPC. A per-session `mkdtemp` directory is mode 0700, the socket path is bounded
below `sockaddr_un.sun_path`, and the adapter cleans the socket and directory
after waitpid reaping. The process has an exec-status pipe, a tracked PID and
process group, and bounded quit/close, SIGTERM, then SIGKILL teardown.

Each opened resource gets fresh mpv `observe_property` IDs. After the
coordinator has stopped the previous resource and observed `idle`, the adapter
unobserves the old IDs, sends `loadfile ... replace`, and waits for mpv's
`file-loaded` event before observing the new resource and issuing the staged
initial seek and paused-state request. In pinned mpv 0.35.1, the `loadfile`
reply only acknowledges command handling and `file-loaded` has no request or
session id. During that unresolved boundary, old `end-file` events are
ignored, property changes are accepted only when their real mpv observer ID
belongs to the current generation, and both `stop` and a second `open` are
rejected. `close` is the cancellation path and tears down the IPC session; the
coordinator therefore disables Stop while it is `LOADING`.

The adapter receives an already-materialized local audio path. It never opens
TCP, parses stderr, injects keyboard input, or extracts EPUB resources. The
integration test alone opts into `--ao=null` as a clocked test sink; production
does not add a null sink and reports a real no-sink failure. Deterministic
tests inject process, transport, and timer boundaries. The playback coordinator
consumes only the high-level adapter contract and owns resource transitions,
timeline synchronization, and the state exposed to the reader controls.

An adapter error is terminal for the current document session once adapter
resource ownership is uncertain: the playback panel disables its transport
actions and reports that the document must be reopened to retry. The Kindle
adapter marks failures before playlist creation or playback-command delivery
as recoverable; the coordinator stops that unclaimed adapter session, removes
the materialized file, reports the error, and returns to idle so **Start** can
be pressed again. Resource replacement and final EOF first wait for the
adapter's idle acknowledgement before removing the private extracted file.

The Kindle adapter is `kindleaudio.lua`, backed by the narrow
`kinampport.lua` seam. `KindleAudio` owns one adapter-created, one-entry M3U,
reconciles desired pause state and one-shot seek intents against fresh KinAMP
status publications, and uses the FIFO as a liveness probe rather than
trusting a stale status file. Before loading, it forces a status publication
and requires a newly published idle snapshot; stop and close require a fresh
stopped publication for the exact audio path. Publication identity is carried
by a KinAMPPort token derived from the atomically replaced status file's inode
and modification metadata, not by a poll counter. A missing or busy daemon is
handled before playback acquisition: the native startup boundary arranges an
absent service, while a busy daemon is left alone. The adapter never kills or
quits a daemon.

KinAMP's seek targets remain whole seconds: fractional requests are rounded to
the nearest non-negative second. Stock positions are observed whole seconds
rather than predicted fractions. KinAMP 3.0.0's `play` command can subtract
stale pipeline running time when resuming, rewinding the published and audible
position. For stock daemons the adapter therefore resumes by seeking to the
last published paused second; that seek starts a replacement playing pipeline
without the faulty resume clock adjustment.

The opt-in KinAMP-fork speed prototype advertises an exact `speed-v1` capability
token, speed limits, supported formats, and current-resource `speed_supported`.
The adapter sends the saved speed between `load` and `index` only to a capable
daemon, and exposes live controls only for a supported owned resource. Stock
daemons receive no speed command. The prototype retains requested session speed
across stop/load/seek, preserves pause on seeks, and resumes with `play`, so the
stock seek-to-resume workaround must not be used with this protocol.
`pos_ms` is converted to original-media seconds only for `speed-v1`; it is a
clock/epoch estimate, not a Bluetooth playhead. Sonic pitch-preserving PCM
processing and old-rate audio draining are owned by the external player;
KoReadalong never predicts positions using the latest requested rate. The UI
shows the per-book requested speed, not the rate already reaching the listener.
These additions have host synthetic/real-daemon, supplied-runtime ARM/QEMU, and
bounded native PW6 coverage described in the [reference guide](guide.md#playback-speed-prototype). None establishes exact
Bluetooth playhead correspondence, battery life, or long-session reliability.

KinAMP's protocol can make external stop and natural EOF indistinguishable, so
an owned fresh playing-to-stopped transition with a positive duration is
treated as EOF even when the final position is stale; the last active observed
position is retained. A stopped transition from paused playback is terminal
for the document session.

`kinampport.lua` resolves the command FIFO `kinamp_cmd` and status file
`kinamp_status` under `${KINAMP_RUNTIME_DIR:-/tmp}`. It requires an
already-running KinAMP daemon, writes only bounded newline-delimited text
commands to the nonblocking command FIFO, and parses bounded atomically
replaced status snapshots. It fails closed when FIFO type or publication
metadata cannot be verified, uses SIGPIPE-safe EINTR/EAGAIN-aware writes, and
never sends `quit`, launches or kills a daemon, or manages Bluetooth. This
initial integration assumes Kindle/Linux `PIPE_BUF=4096` atomic writes. KinAMP
is an external GPLv3+ dependency; protocol interoperability is based on the
public [KinAMP project](https://github.com/kbarni/KinAMP), and no KinAMP source
is bundled or copied into KoReadalong.

`kinampservice.lua` supplies the Kindle adapter's native startup boundary. It
reuses the enabled official plugin's `kinamp_config.bin_folder` discovery and
the installed player flavour/library contract. The official shell launcher
terminates existing daemons, while its private Lua startup helper changes
Bluetooth; neither offers a safe public idle-start API. Instead, this boundary
starts the externally installed minimal executable with `--idle`, asynchronously,
only after FIFO and process absence checks. A shared startup PID guard covers
reader transitions before IPC is published. Existing processes with broken IPC
are not replaced. The adapter polls for readiness for six seconds, then requires
fresh stopped status before creating a playlist or sending playback commands.
Missing installation, startup failure, and busy playback are recoverable before
resource acquisition. There is no atomic cross-client claim in KinAMP's protocol;
concurrent external launchers are not supported.

The native boundary also writes a bounded, atomically replaced ownership receipt
under the runtime directory before sending a load command. It contains Linux
reader/daemon PID and process-start identities, the private audio path and M3U.
A new reader may reclaim only a dead reader's exact single-entry music resource
in the same daemon generation. The adapter requires a fresh matching publication,
sends stop once, and waits for fresh stopped acknowledgement before removing the
recorded private files and loading its new session. Cleanup never recursively
deletes a directory. Normal release removes only this reader's exact receipt.
This is recovery on explicit Start, not a daemon monitor or an atomic lease;
another client can still race a check because KinAMP has no owner-scoped command.
Unknown ownership, unavailable process metadata and replaced playback fail closed.

The same native boundary reads the official `kinamp_bt` connection API before
startup/acquisition. A confirmed empty connected-device list without a connected
name produces a recoverable Bluetooth setup prompt. Unavailable or inconclusive
reporting is not treated as disconnection. Busy-client refusal takes priority;
the platform-neutral coordinator knows nothing about Bluetooth.
The installed official module can cache a closed LIPC handle after reader
transitions. Before checking output or opening setup, an unavailable cached API
is refreshed once along with its settings module; available shared handles are
left intact. This changes no installed KinAMP files, daemon or radio state.

Stop and document close still release only owned audio and temporary resources.
Neither the starter nor the port quits/kills a daemon or pairs Bluetooth devices.
The official plugin remains responsible for idle shutdown. If it shuts down on
a reader/file-manager transition, the next explicit Start arranges readiness
again rather than patching its handlers or running a competing lifecycle manager.

`main.lua` selects the audio adapter with `Device:isKindle()` and lazily
requires only the selected adapter; device selection remains outside the
platform-neutral playback coordinator. On Kindle, it maps busy preflight errors
to a focused native prompt and exposes persistent KinAMP setup/help with a button
opening the official `kinamp_btdevices.open()` settings; desktop/mpv errors remain
unchanged. Installation, troubleshooting, workarounds, and physical
validation are documented in the [Kindle tester guide](kindle.md) and
[reference guide](guide.md#experimental-kindlekinamp-support).

## Tooling

- Runtime language: LuaJIT, matching KOReader.
- Linter/static syntax analysis: Luacheck with KOReader-compatible settings.
- Tests: Busted for platform-neutral modules; later KOReader frontend tests for reader integration.
- Editor types: LuaLS is configured for LuaJIT, but there is no upstream KOReader type-check command.
- Formatting: four-space KOReader style; upstream defines no mandatory formatter.
- Desktop runtime: checksum-pinned KOReader Linux x86_64 release installed under `.cache/`.

## Delivery status

The current MVP includes package and SMIL parsing, fragment resolution,
platform-neutral playback, KOReader integration, desktop audio, playback
controls, and representative rerender/page tests.

The Kindle adapter is implemented and physically validated only on the tested
configuration documented in the [Kindle tester guide](kindle.md). It remains experimental with degraded
timing; this validation does not claim support for other Kindle models or
firmware.
