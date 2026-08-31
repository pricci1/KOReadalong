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
- **Playback coordinator:** maps audio position to a clip with binary search, updates the active text target, and coordinates chapter/audio transitions.
- **Reader adapter:** converts EPUB fragment IDs to CRe XPointers, derives current screen boxes, and paints ephemeral underlines. It recomputes boxes on page/position updates and document rerenders.
- **Audio adapter:** exposes `open(path, { position = 0, paused = false })`,
  `setPaused`, `seek`, `stop`, `getStatus`, and `close`. Desktop and Kindle
  implementations must share this contract.

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
non-empty, visibly rendered inline text. It accepts a range only when the
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

Dynamic read-along marks should be a registered reader view module with a `paintTo` method. Persisted highlights are intentionally avoided because narration state must not enter KOReader's annotations/bookmarks/export systems. Text anchors are stored as XPointers; rendered boxes are display-dependent cache entries only.

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
reported as a playback error; the adapter does not launch, kill, or quit it.

KinAMP's whole-second seek protocol is intentionally exposed as degraded
timing: fractional requests are rounded to the nearest non-negative second,
and reported positions are observed whole seconds rather than predicted
fractions. KinAMP 3.0.0's `play` command can subtract stale pipeline running
time when resuming, rewinding the published and audible position. The adapter
therefore resumes by seeking to the last published paused second; KinAMP's
seek starts a replacement playing pipeline without the faulty resume clock
adjustment. No timing capability interface is exposed in this phase. KinAMP's
current protocol can make external stop and natural EOF indistinguishable, so
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

`main.lua` selects the audio adapter with `Device:isKindle()` and lazily
requires only the selected adapter; device selection remains outside the
platform-neutral playback coordinator. On Kindle, it maps recoverable missing
or busy preflight errors to focused native prompts and exposes persistent
KinAMP setup/help alongside the Read along menu item; desktop/mpv errors remain
unchanged. Operator setup, troubleshooting, workarounds, and physical
validation are documented in the [Kindle/KinAMP section of the README](../README.md).

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
configuration documented in the README. It remains experimental with degraded
timing; this validation does not claim support for other Kindle models or
firmware.
