# KoReadalong architecture

## MVP outcome

Open a Storyteller-compatible EPUB in KOReader, start or pause its embedded narration, seek with the book/audio controls, and underline the active text target as playback advances. Desktop Linux is the first implementation environment; Kindle playback follows behind the same backend contract.

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
- **Audio adapter:** exposes load, play, pause, seek, stop, position, and duration. Desktop and Kindle implementations must share this contract.

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
`#_doc_fragment_<spine_index>_<text_fragment>` and uses only the injected CRe
operations `isXPointerInDocument`, `getTextFromXPointer`,
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

## Audio direction

KinAMP demonstrates the right Kindle boundary: a small native daemon owns decoding/audio output, while Lua sends FIFO commands and reads atomic status snapshots. Its Kindle Bluetooth adapter uses Lab126 LIPC and must remain capability-gated. On desktop, KinAMP can use GStreamer 1.0 `autoaudiosink`, but its current launcher/build are not turnkey and link unnecessary GTK/XML dependencies.

The MVP should prove the parser, timeline, and visual synchronization on Linux before selecting whether to adapt KinAMP's GPLv3 daemon or implement a smaller protocol-compatible companion. LARK's GTK UI and direct Kindle service manipulation are not appropriate plugin dependencies.

## Tooling

- Runtime language: LuaJIT, matching KOReader.
- Linter/static syntax analysis: Luacheck with KOReader-compatible settings.
- Tests: Busted for platform-neutral modules; later KOReader frontend tests for reader integration.
- Editor types: LuaLS is configured for LuaJIT, but there is no upstream KOReader type-check command.
- Formatting: four-space KOReader style; upstream defines no mandatory formatter.
- Desktop runtime: checksum-pinned KOReader Linux x86_64 release installed under `.cache/`.

## Delivery sequence

1. Parse package metadata, SMIL clocks, nested sequences, and Storyteller fixtures.
2. Resolve fragment IDs to KOReader text anchors and paint a static ephemeral underline.
3. Implement desktop playback and synchronize the active clip.
4. Add navigation, playback controls, state cleanup, and representative rerender/page tests.
5. Implement and test the Kindle audio/Bluetooth adapter on supported hardware.
