# KOReadalong

Read and listen to a book simultaneously in [KOReader](https://github.com/koreader/koreader).
KOReadalong plays the audio embedded in a narrated EPUB and underlines the text
being read, using the book's own timing rather than a separate audiobook or
text-to-speech service.

- **Follow along.** Turn pages automatically with narration, or don't.
- **Pick up later.** Resume your saved place, start at the current page, or hold
  a word and choose **Read from here**.
- **Listen your way.** Pause, seek by 15 seconds, and adjust speed from 0.5× to
  3× on supported players. Speed is remembered per book.
- **Linux and experimental Kindle.** Linux uses mpv. Kindle uses KinAMP (installed separately) (Only tested on a PW6).

> **Latest beta:** download [v0.1.0-beta.3](https://github.com/pricci1/KOReadalong/releases/tag/v0.1.0-beta.3).
> The plugin, optional experimental Kindle Opus/speed player, and optional
> Bluetooth guard are separate downloads. Read the [Kindle setup and
> limitations](docs/kindle.md) before installing either companion.

**Create your own _readalouds_ with [Storyteller](https://storyteller-platform.dev/).**
It aligns a DRM-free EPUB with its matching DRM-free audiobook and produces an EPUB with
embedded narration and timing. Follow Storyteller's [readaloud creation
guide](https://storyteller-platform.dev/docs/managing/aligning), download the
resulting EPUB, and open it in KOReader with KOReadalong. **KOReadalong plays these
aligned books; it does not align a separate ebook and audiobook itself.**

## Contents

- [Install](#install)
- [Start listening](#start-listening)
- [Compatibility and limitations](#compatibility-and-limitations)
- [Report a problem](#report-a-problem)
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

3. Download `koreadalong-v0.1.0-beta.3.zip` from the
   [prerelease](https://github.com/pricci1/KOReadalong/releases/tag/v0.1.0-beta.3),
   verify it against `SHA256SUMS`, and extract it. Copy `koreadalong.koplugin`
   into KOReader's `plugins` directory—not the entire extracted archive.
   From a source checkout, copy that same directory. Keep its name intact:

   ```text
   koreader/plugins/koreadalong.koplugin/main.lua
   ```

4. Restart KOReader. Open a narrated EPUB and select **Read along** in the menu.

### Kindle

Use the [Kindle tester guide](docs/kindle.md). You need a jailbroken Kindle,
KOReader, KinAMP with its libraries and enabled KOReader plugin, and connected
Bluetooth audio. **The KOReadalong ZIP does not install KinAMP or change the
Kindle's Bluetooth policy.** Optional player and guard ZIPs are available on the
same prerelease; they are not required for stock KinAMP AAC playback. The guard
requires the optional player and exact supported firmware.

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

Use the [issue tracker](https://github.com/pricci1/KOReadalong/issues).
Include the release version, device and firmware, KOReader version,
player version, what you did, and what you expected. On Kindle,
also say whether you are using the forked version of KinAMP and if the
Bluetooth guard was enabled and how long playback ran.

## Credits

KOReadalong is mostly derived form, and made possible by, the following projects and their contributors:

- [Storyteller](https://storyteller-platform.dev/) creates the aligned readaloud
  EPUBs that bring ebook text and audiobook narration together.
- [KinAMP](https://github.com/kbarni/KinAMP) provides the Kindle audio player,
  Bluetooth setup, and playback interface used by KOReadalong's Kindle backend.
  The [experimental fork](https://github.com/pricci1/KinAMP-fork) builds on that work
  to add Opus-in-MP4 and playback-speed support.
- [KOReader](https://github.com/koreader/koreader) provides the reader, plugin
  framework, text rendering, and device support that KOReadalong integrates with.

## License

KOReadalong is licensed under the [GNU Affero General Public License, version 3](LICENSE).
