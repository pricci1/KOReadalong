# Kindle beta tester guide

KOReadalong's Kindle support is experimental. The tested configuration is
**Kindle Paperwhite 6, firmware 5.19.3.0.1, KOReader v2026.07.1**, with KinAMP's
native Bluetooth output. Other models and firmware are unverified; a player
binary built for this configuration is not a universal Kindle download.

## What you need

- A jailbroken Kindle with KOReader installed.
- [KinAMP](https://github.com/kbarni/KinAMP): its player, required libraries,
  launchers, and enabled KOReader plugin. KOReadalong does not replace these.
- Connected Bluetooth headphones or a speaker.
- An EPUB containing embedded audio and EPUB 3 Media Overlays. Separate EPUB
  and audiobook files are not supported.
- The versioned KOReadalong ZIP supplied by the prerelease organizer. The same
  plugin ZIP is used for Linux and Kindle; audio players are separate.

> **Before inviting testers:** the organizer must provide the exact player
> download, source, checksums, supported hardware, and any Bluetooth-guard
> instructions in the prerelease notes. The fork links below are source
> references, not ready-to-install binary downloads.

## Choose the player

| Player | AAC in M4A/MP4 | Opus in MP4 | Playback speed |
| --- | --- | --- | --- |
| Tested upstream KinAMP 3.0.0 | Yes | No | No |
| Experimental speed-enabled fork | Yes | Yes | 0.5–3× |

The [speed prototype](https://github.com/pricci1/KinAMP-fork/tree/080aed2e014433063c3363720d4a59c787d91231)
was tested on the PW6 configuration above, including listening at 1× and 1.5×.
The tested installation replaced only `KinAMP-minimal`, keeping the official
plugin and libraries. Do not substitute a desktop binary or an arbitrary build.
The player advertises speed support; KOReadalong hides those controls on stock
KinAMP and unsupported tracks.

Changing an Opus file's extension or installing a GStreamer codec does not add
Opus-in-MP4 support to stock KinAMP. KOReadalong does not transcode books.

## Install or update KOReadalong

1. Stop narration and exit KOReader before changing files. If already installed,
   back up `koreader/plugins/koreadalong.koplugin` outside the plugins directory.
   Preserve your KOReader settings and book sidecars.
2. Extract the KOReadalong ZIP on your computer. Copy only its
   `koreadalong.koplugin` directory into the Kindle's `koreader/plugins`
   directory. Replace the old plugin directory rather than merging versions.
3. Confirm that the resulting path is
   `koreader/plugins/koreadalong.koplugin/main.lua`, without an extra nested
   archive directory. Safely eject the Kindle and start KOReader.
4. Connect audio using **KinAMP setup and help → Bluetooth setup**. Pairing and
   connection remain user actions; KOReadalong does not change the radio.
5. Open a narrated EPUB and choose **Read along → Start here**. KOReadalong
   starts an absent KinAMP service automatically. You do not need to start a
   player manually for each book.

Existing playing or paused audio from another client is left alone and reported
as busy. Do not use competing KinAMP clients during narration.

## Bluetooth idle timeout and optional guard

On the tested firmware, Amazon's Bluetooth service can disconnect after about
20 minutes because it does not recognize external KinAMP narration as active
playback. This happened while the reader was awake; preventing sleep is not
the demonstrated fix.

There is a separate [experimental Bluetooth guard](https://github.com/pricci1/KinAMP-fork/blob/7a3dbf7f71d62cd50ea8a52cff9d3e484cecfb06/BT_GUARD.md).
It is tied to exact firmware and player identities and is **not included or
enabled by the KOReadalong ZIP**. It changes the running Bluetooth-service
policy, so only use the organizer's exact compatible package and its documented
enable, disable, recovery, and uninstall procedures. Do not bypass its checks.

- Stop narration before enabling, disabling, or uninstalling the guard. Service
  changes can disconnect Bluetooth; reconnect normally before starting playback.
- There is no boot hook: after reboot, the device returns to stock behavior
  until the guard is explicitly enabled again.
- The earlier bounded guard passed roughly 29 minutes of audible playback and
  a paused-timeout control. The revised lifecycle package still needs its own
  long-playback acceptance; multi-hour reliability and battery use are unknown.
- Supervisor failure can require explicit recovery. Do not assume that every
  failure automatically restores the stock service.

## First listening check

1. Start narration and confirm both audible audio and temporary text underlining.
2. Pause, resume, and try both 15-second seek buttons. If speed controls appear
   under **More**, try 1.5× and reset to 1×; a paused speed change should stay paused.
3. Turn a page while listening, then choose **Return to narration**.
4. Cross a narrated chapter boundary. Pause, close, and reopen the book: reopening
   must be silent, and saved **Resume** should be available after confirmed progress.
5. Record the time and guard state during longer listening. Report any disconnect,
   missing audio, stuck highlight, or crash rather than changing firmware settings.

**Hide is not Stop:** hiding the panel leaves audio running. Stop resets the
session to the first clip; pause or close the book to retain your listening place.

## Known limitations

- Position estimates are not an exact audible Bluetooth playhead. Seeks round
  to whole seconds. Queued audio can delay a speed change becoming audible.
- Repeated AAC playback tests left extra file handles open in the player, also
  in the older baseline. This is a resource leak, not file growth or book damage;
  long-session effects are not established.
- An external stop and natural end-of-track can look identical to the adapter.
- A reader crash can leave KinAMP playing. Reopen the book and explicitly Start
  to recover a positively identified orphan; unknown playback is refused as busy.
- Endurance, battery drain, other Kindle models, and power-off/reboot during
  narration have not been qualified.

## Report a problem

Include the KOReadalong version from the archive's `RELEASE.json`, Kindle model
and firmware, KOReader version, exact player package, guard state, elapsed
listening time, and reproduction steps. Say whether audio continued after a
crash and whether a second attempt behaved differently.

The archive includes `scripts/kinamp-diagnostic`. Copy it to the device and,
over SSH, run it with your actual KinAMP installation directory:

```sh
sh /path/to/kinamp-diagnostic --kinamp-dir /mnt/us/KinAMP
```

It does not start/stop a player, send FIFO commands, or modify files. Media paths
are sanitized. Exit 0 means selected checks passed, 2 indicates a known problem,
and 3 means incomplete/inconclusive checks. Review reports before sharing; do
not attach books, raw dumps, or private settings. The [reference troubleshooting
table](guide.md#troubleshooting) covers missing libraries, busy players, and timeouts.

Do not expose KOReader's unauthenticated HTTP inspector publicly. It can invoke
arbitrary methods and is not needed for normal testing.

## Roll back or uninstall

Stop narration and exit KOReader. Restore the backed-up plugin directory, or
remove `koreadalong.koplugin` to uninstall, then restart KOReader. This does not
uninstall KinAMP, revert its player binary, or disable a separately installed
guard. Use those packages' rollback procedures independently. Keep book sidecars
unless you deliberately want to remove saved per-book settings.
