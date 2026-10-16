# Kindle beta tester guide

KOReadalong's Kindle support is experimental. The tested configuration is
**Kindle Paperwhite 6, firmware 5.19.3.0.1, KOReader v2026.07.1**, with KinAMP's
native Bluetooth output. Other models and firmware are unverified; a player
binary built for this configuration is not a universal Kindle download.

## What you need

- A jailbroken Kindle with KOReader installed.
- [KinAMP 3.0.0](https://github.com/kbarni/KinAMP/releases/tag/3.0.0): its player, required libraries,
  launchers, and enabled KOReader plugin. KOReadalong does not replace these.
- Connected Bluetooth headphones or a speaker.
- An EPUB containing embedded audio and EPUB 3 Media Overlays. Separate EPUB
  and audiobook files are not supported.
- The versioned KOReadalong ZIP from the
  [prerelease](https://github.com/pricci1/KOReadalong/releases/tag/v0.1.0-beta.2). The same
  plugin ZIP is used for Linux and Kindle; audio players are separate.

## Choose your downloads

| Asset | When to use it |
| --- | --- |
| `koreadalong-v0.1.0-beta.2.zip` | The plugin. Required on both Linux and Kindle. |
| `kinamp-player-pw6-v0.1.0-beta.1.zip` | **Optional:** experimental Opus-in-MP4 and 0.5–3× speed support, for the tested PW6 configuration only. Requires an existing KinAMP installation. |
| `kinamp-bt-guard-pw6-v0.1.0-beta.1.zip` | **Optional, advanced:** Bluetooth idle workaround for the exact firmware and optional player below. Not needed to start playback. |
| `kinamp-player-pw6-v0.1.0-beta.1-source.tar.gz` and `kinamp-bt-guard-pw6-v0.1.0-beta.1-source.tar.gz` | Matching companion source, build recipes and notices; not installation packages. |
| `SHA256SUMS` | Checksums for all five archives. Verify the files you download before installation. |

All assets are on the same prerelease. Install only the plugin to keep stock
KinAMP AAC playback. Neither optional ZIP is installed or enabled automatically.
The guard requires the optional player; it is not compatible with stock KinAMP.
The repository is private during this beta, so testers need repository access.

Beta.2 updates only the plugin. The optional beta.1 player, guard, and source
archives are unchanged; existing companion installations do not need updating.

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

### Install the optional Opus/speed player

This package preserves the exact native-tested executable, not a new rebuild:

```text
KinAMP-minimal SHA256
e2b1466a5514963e56818a58e6ecb898140eb778b14bb4796ae76ae521fbcde6
```

1. Install upstream KinAMP 3.0.0 first, using its **Kindle `kinamp.zip`**, not
   `kinamp-kobo.zip`. Keep its required libraries, launchers and official KOReader
   plugin. Verify ordinary AAC playback before replacing anything.
2. Stop narration and any other KinAMP playback, exit KOReader, and ensure its
   player daemon has stopped. Do not replace an executable still in use. If a
   guard is already installed, disable it using its documented procedure first.
3. Extract the optional player ZIP on your computer. Read its included notices
   and installation guide. Copy the extracted `kinamp-player-pw6` folder to
   `/mnt/us/KOReadalong-beta/kinamp-player-pw6` on the Kindle.
4. Over SSH, back up the original player outside its installation directory,
   then replace **only** `KinAMP-minimal`. For the standard `/mnt/us/KinAMP`
   installation, run these commands only after completing step 2:

   ```sh
   cd /mnt/us/KOReadalong-beta/kinamp-player-pw6
   sha256sum -c SHA256SUMS
   test ! -e /mnt/us/KinAMP-minimal.before-koreadalong-beta1 || exit 1
   cp -p /mnt/us/KinAMP/KinAMP-minimal /mnt/us/KinAMP-minimal.before-koreadalong-beta1
   cp KinAMP-minimal /mnt/us/KinAMP/KinAMP-minimal
   chmod 755 /mnt/us/KinAMP/KinAMP-minimal
   sha256sum /mnt/us/KinAMP/KinAMP-minimal
   ```

5. Confirm the installed hash matches the value above. Restart KOReader and
   start a readaloud explicitly. **More** should offer speed controls on
   supported AAC/Opus tracks. Opening a book must remain silent.

This is not a complete KinAMP replacement or an upstream release. No proprietary
firmware libraries are included. The source companion contains pinned public
dependency sources, expanded miniaudio, Sonic and build recipes. Original
generated build configurations/link maps were not preserved; this release does
not claim a reproducible byte-identical rebuild.

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

The optional guard ZIP contains the preserved
[experimental Bluetooth guard](https://github.com/pricci1/KinAMP-fork/blob/7a3dbf7f71d62cd50ea8a52cff9d3e484cecfb06/BT_GUARD.md).
It is tied to exact firmware and player identities and is **not included or
enabled by the KOReadalong plugin ZIP**. It changes the running Bluetooth-service
policy. Use it only if you accept the additional risk and can perform root SSH
recovery; do not bypass its checks or preload `guard.so` into the player.

### Install and enable the optional guard

Read the package's complete `BT_GUARD.md` before proceeding. The supported
identities are:

```text
acsbtfd        70e32455351761c90356b8640bc196201af00dbc86471f0f6e8315ca12c35528
libacsbtfdlib  569865512abd5ad74bface0a8d01123d695639955ac5dc3bf288d65094f10774
acsbtfd job    6e4336d6c9ac3cc9bf062374eed397a934115055690b03eef70c2d2810c05170
KinAMP player  e2b1466a5514963e56818a58e6ecb898140eb778b14bb4796ae76ae521fbcde6
```

1. Install the optional player above. Stop playback (**not Pause**), exit
   KOReader and keep a root SSH connection available. Enabling or disabling the
   guard can disconnect headphones and restart the audio manager.
2. Extract the guard ZIP and copy its `kinamp-bt-guard-pw6` directory to
   `/mnt/us/KOReadalong-beta/kinamp-bt-guard-pw6`. Back up any existing
   `/tmp/btfd-acs.err` privately before enabling; it may contain device details.
3. As root, verify the package and create a **new** installation. If the fixed
   install path already exists, stop and use that installation's update or
   uninstall procedure; never overwrite an active guard.

   ```sh
   cd /mnt/us/KOReadalong-beta/kinamp-bt-guard-pw6
   sha256sum -c SHA256SUMS
   test ! -e /var/local/kinamp-bt-guard || exit 1
   mkdir -m 755 /var/local/kinamp-bt-guard
   cp guard.so session bt-guard 'Enable Bluetooth Guard.sh' BT_GUARD.md SHA256SUMS /var/local/kinamp-bt-guard/
   chown root:root /var/local/kinamp-bt-guard /var/local/kinamp-bt-guard/*
   chmod 755 /var/local/kinamp-bt-guard/session /var/local/kinamp-bt-guard/bt-guard '/var/local/kinamp-bt-guard/Enable Bluetooth Guard.sh'
   chmod 644 /var/local/kinamp-bt-guard/guard.so /var/local/kinamp-bt-guard/BT_GUARD.md /var/local/kinamp-bt-guard/SHA256SUMS
   cd /var/local/kinamp-bt-guard
   sha256sum -c SHA256SUMS
   ./bt-guard enable
   ./bt-guard status
   ```

4. Confirm status is **supervised**, with a fresh nonzero player binding when
   the accepted player is running. **Waiting for KinAMP** before it starts is
   expected; an expired binding is not protection. Reconnect headphones normally,
   then open KOReader and explicitly start playback.
5. Optionally copy `Enable Bluetooth Guard.sh` from the installation into
   `/mnt/us/documents/`, without overwriting an unrelated document. The existing
   SH_Integration Scriptlet handler is required. Return to the normal Kindle
   Library and clear book-only filters to find **Enable Bluetooth Guard**.
   Actual tile indexing/tapping was not validated; use SSH if it does not appear.

The package's existing manifest covers its five original payloads; the release's
outer `SHA256SUMS` covers the entire ZIP, including notices and this guide.

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

For the optional guard, Stop narration, then use
`/var/local/kinamp-bt-guard/bt-guard disable` or `bt-guard uninstall` as described
in `BT_GUARD.md`. Uninstall restores stock first and refuses deletion if recovery
is incomplete. If supervisors died while the stock service remained stopped,
use its documented `recover` command; do not blindly start services or kill PIDs.
A normal reboot is the user-operated fallback to stock because there is no boot
hook. Do not delete the installation as a substitute for recovery.

To roll back the optional player, first disable/uninstall any guard, Stop
playback, exit KOReader and confirm the daemon has stopped. Restore
`/mnt/us/KinAMP-minimal.before-koreadalong-beta1` to
`/mnt/us/KinAMP/KinAMP-minimal`, preserve executable permissions, and restart
KOReader. Do not restore the player while an accepted guard session is active.
