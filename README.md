# KoReadalong

KoReadalong is a [KOReader](https://github.com/koreader/koreader) plugin for reading EPUB 3 books alongside their embedded audio. The MVP will play EPUB Media Overlays and underline the sentence or paragraph currently being narrated.

The primary target is a jailbroken Kindle with Bluetooth audio. Development and automated checks use KOReader's Linux desktop build.

## Development

Fresh Amp orbs are prepared by `.agents/setup`. On another Debian-based machine, run it directly:

```sh
./.agents/setup
make check
make run
```

`make run` launches the checksum-pinned KOReader desktop runtime with `koreadalong.koplugin` linked into its plugin directory. `make run-headless` provides a short Xvfb smoke run for environments without a display.

The project follows KOReader's upstream Luacheck configuration. LuaLS settings are included for editor assistance, but KOReader does not define an authoritative Lua type-checking gate or autoformatter.

See [docs/architecture.md](docs/architecture.md) for the MVP boundaries and compatibility findings.
