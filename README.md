# KOReadalong

Read and listen to a book together in [KOReader](https://github.com/koreader/koreader).
KOReadalong plays the audio embedded in a narrated EPUB and underlines the text
being read, using the book's own timing rather than a separate audiobook or
text-to-speech service.

- **Follow along.** Turn pages automatically with narration, or browse elsewhere
  while listening and return to the narrated text when you're ready.
- **Pick up later.** Resume your saved place, start at the current page, or hold
  a word and choose **Read from here**.
- **Listen your way.** Pause, seek by 15 seconds, and adjust speed from 0.5× to
  3× on supported players. Speed is remembered per book.
- **Keep books untouched.** Narration marks are temporary, not saved highlights;
  the original EPUB is not modified.
- **Linux and experimental Kindle.** Linux uses mpv. Kindle uses a separately
  installed KinAMP player; the tested device is a Paperwhite 6.

For example: open a narrated EPUB → **Read along** → **Start here**. The active
sentence or paragraph is underlined. Turn a page to browse without stopping
audio, then choose **Return to narration** to follow again.

> **Beta preparation:** no KOReadalong prerelease has been published yet.
> Kindle testers should read the [Kindle setup and limitations](docs/kindle.md)
> before installing.

**Create your own readalouds with [Storyteller](https://storyteller-platform.dev/).**
It aligns a DRM-free EPUB with its matching audiobook and produces an EPUB with
embedded narration and timing. Follow Storyteller's [readaloud creation
guide](https://storyteller-platform.dev/docs/managing/aligning), download the
resulting EPUB, and open it in KOReader with KOReadalong. KOReadalong plays these
aligned books; it does not align a separate ebook and audiobook itself.

## Contents

- [Install](#install)
- [Start listening](#start-listening)
- [Compatibility and limitations](#compatibility-and-limitations)
- [Report a problem](#report-a-problem)
- [Development](#development)
- [Credits](#credits)
- [License](#license)

## Install

### Linux

1. Install [KOReader](https://github.com/koreader/koreader/releases). Development
   and integration testing use its Linux x86_64 v2026.07.1 build.
2. Install `mpv` on your PATH. On Debian or Ubuntu:

   ```sh
   sudo apt install mpv
   ```

3. From a source checkout, copy `koreadalong.koplugin` into KOReader's `plugins`
   directory. For a packaged beta, extract the versioned ZIP and copy that same
   directory—not the entire extracted archive. Keep the directory name intact:

   ```text
   koreader/plugins/koreadalong.koplugin/main.lua
   ```

4. Restart KOReader. Open a narrated EPUB and select **Read along** in the menu.

### Kindle

Use the [Kindle tester guide](docs/kindle.md). You need a jailbroken Kindle,
KOReader, KinAMP with its libraries and enabled KOReader plugin, and connected
Bluetooth audio. **The KOReadalong ZIP does not install KinAMP or change the
Kindle's Bluetooth policy.**

## Start listening

1. Open a supported EPUB, then **Read along → Start here**.
2. Use **Pause/Resume**, the 15-second seek buttons, and **Follow** in the compact
   panel. **More** reveals saved **Resume**, **Start over**, **Stop**, and speed
   controls when supported.
3. Use **Hide** to dismiss the panel while continuing to listen. **Stop** stops
   narration and resets playback to the first clip. Opening a book never starts
   audio automatically.

To reopen controls quickly, assign **Reader → KOReadalong: show playback
controls** in KOReader's Gesture manager. See the [reference guide](docs/guide.md#use)
for all controls, resume behavior, progress displays, and gestures.

## Compatibility and limitations

- Supports ordinary Storyteller-style overlays targeting XHTML element IDs.
  Web Text Fragments and complex DOM ranges are not supported.
- Books need their own usable narration timings. Some invalid intervals are
  skipped with a warning; broken references and other structural errors can
  make a book unavailable.
- Kindle validation is limited to **Paperwhite 6, firmware 5.19.3.0.1, KOReader
  v2026.07.1**. Other models and firmware are unverified.
- Stock KinAMP lacks Opus-in-MP4 and speed support. The experimental fork adds
  them, but timing is approximate and Bluetooth output latency is not measured.
- Kindle Bluetooth can disconnect after about 20 minutes of unrecognized
  playback. A separate firmware-specific guard exists; it is not a general
  compatibility fix. Long-session reliability and battery use remain unproven.

See the [Kindle guide](docs/kindle.md) before planning a long listening session.

## Report a problem

Use the issue tracker named in your prerelease, or send the report to the person
who invited you to test. Include the release version, device and firmware,
KOReader version, player version, what you did, and what you expected. On Kindle,
also say whether the Bluetooth guard was enabled and how long playback ran.

Do not attach copyrighted books, private settings, or raw dumps. The
[read-only Kindle diagnostic](docs/kindle.md#report-a-problem) sanitizes media paths.

## Development

For building and testing from source, see the
[development guide](docs/guide.md#development) and [architecture](docs/architecture.md).
Maintainers can follow the [prerelease checklist](docs/releasing.md).

## Credits

KOReadalong is made possible by these projects and their contributors:

- [Storyteller](https://storyteller-platform.dev/) creates the aligned readaloud
  EPUBs that bring ebook text and audiobook narration together.
- [KinAMP](https://github.com/kbarni/KinAMP) provides the Kindle audio player,
  Bluetooth setup, and playback interface used by KOReadalong's Kindle backend.
  The [experimental fork](https://github.com/pricci1/KinAMP-fork) builds on that work
  to add Opus-in-MP4 and playback-speed support.
- [KOReader](https://github.com/koreader/koreader) provides the reader, plugin
  framework, text rendering, and device support that KOReadalong integrates with.

## License

KOReadalong is licensed under the [GNU Affero General Public License, version 3](LICENSE),
the same license used by KOReader. Storyteller and KinAMP are separate projects
with their own licenses.
