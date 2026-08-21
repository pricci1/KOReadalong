# KoReadalong development guidance

KoReadalong is a KOReader plugin for EPUB 3 Media Overlays. Keep the core platform-neutral and put desktop/Kindle audio behavior behind explicit adapters.

## Commands

- `make check` runs all repository checks.
- `make mpv-integration` exercises the real mpv process and Unix IPC under the pinned KOReader LuaJIT.
- `make smoke-integration` generates a synthetic EPUB and exercises the complete read-along pipeline under KOReader.
- `make run` starts the pinned desktop KOReader with this plugin linked into it.
- `make run-headless` starts KOReader under Xvfb for smoke testing in an orb.

## Fixtures

- `spec/fixtures/chapter-transition.epub` is a small, sanitized EPUB with synthetic silent audio for chapter-handoff tests. It preserves the regression shape from the original report: narrated content at spine index 3, a non-overlay item at index 4, and the next narrated chapter at index 5.

## Runtime debugging

- Prefer the checksum-pinned runtime under `.cache/koreader` for reproducible development. A user-installed `/usr/bin/koreader` and `/usr/lib/koreader` may also exist; record which runtime produced a result and compare installed plugin files with the checkout before diagnosing version-specific behavior.
- Do not stop an existing KOReader or mpv process, overwrite its profile, or remove its `/tmp/koreadalong-*` paths unless the user explicitly asks. Use a separate temporary `HOME` for diagnostic sessions.
- For an interactive session on the orb desktop, run KOReader as an `amp orb service` with `DISPLAY=:0`, the desktop's `WAYLAND_DISPLAY` and `XDG_RUNTIME_DIR`, and an isolated `HOME`. This preserves logs through `amp orb service logs`; stop the service and remove only its owned profile and temporary paths afterward.
- Use Xvfb for automated checks. If a diagnostic session auto-starts audio, inject mpv's test-only clocked `--ao=null` sink so it does not play duplicate audio through the user's desktop session. Never add a null sink to production defaults.
- KOReader loads plugin Lua modules per process. Restart the diagnostic session after changing or replacing plugin files.

## Constraints

- Follow KOReader's LuaJIT-compatible style: four spaces, no tabs, and Luacheck clean.
- Use KOReader APIs and modules already shipped in the pinned runtime; do not add LuaRocks dependencies without a demonstrated need.
- Represent EPUB text positions with XPointers. Screen boxes are ephemeral and must be recomputed after position or rendering changes.
- Active read-along marks must not create persistent KOReader annotations.
- Resolve OPF, SMIL, XHTML, and audio references relative to their containing files.
- Test parsing and timeline logic independently from KOReader UI and audio backends.
- Do not copy GPL code from Storyteller, KinAMP, or LARK without recording the licensing consequence.
