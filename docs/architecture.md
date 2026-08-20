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
accepts the extracted OPF XML, the OPF containing path, and either a map or list
of extracted SMIL documents:

```lua
local clips, error_message = MediaOverlays.parse(
    opf_xml,
    "book/package.opf",
    {
        { path = "book/media/chapter.smil", xml = smil_xml },
    }
)
```

Each returned clip has `text_path`, `text_fragment`, `audio_path`,
`clip_begin`, and `clip_end`. Paths are normalized relative to the containing
document and remain ZIP-entry paths; the parser does not assume an `OEBPS/`
root. A parse failure returns `nil, error_message`.

`timeline.lua` provides `Timeline.new(clips):lookup(playback_time)`. Lookup uses
binary search and half-open clip intervals, `[clip_begin, clip_end)`: a shared
boundary selects the following clip and a gap returns `nil`. The timeline keeps
the source audio clock values in each clip; audio-resource switching remains
outside this parser/timeline slice.

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
