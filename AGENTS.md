# KoReadalong development guidance

KoReadalong is a KOReader plugin for EPUB 3 Media Overlays. Keep the core platform-neutral and put desktop/Kindle audio behavior behind explicit adapters.

## Commands

- `make check` runs all repository checks.
- `make run` starts the pinned desktop KOReader with this plugin linked into it.
- `make run-headless` starts KOReader under Xvfb for smoke testing in an orb.

## Constraints

- Follow KOReader's LuaJIT-compatible style: four spaces, no tabs, and Luacheck clean.
- Use KOReader APIs and modules already shipped in the pinned runtime; do not add LuaRocks dependencies without a demonstrated need.
- Represent EPUB text positions with XPointers. Screen boxes are ephemeral and must be recomputed after position or rendering changes.
- Active read-along marks must not create persistent KOReader annotations.
- Resolve OPF, SMIL, XHTML, and audio references relative to their containing files.
- Test parsing and timeline logic independently from KOReader UI and audio backends.
- Do not copy GPL code from Storyteller, KinAMP, or LARK without recording the licensing consequence.
