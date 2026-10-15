# Preparing a GitHub prerelease

The release has one platform-neutral plugin ZIP and separate **optional** Kindle
player and Bluetooth-guard ZIPs, each with a corresponding-source archive.
`SHA256SUMS` covers all five archives. The plugin ZIP never bundles or enables
either companion. No asset may contain proprietary firmware libraries, private
settings, books, or a Kindle sysroot.

## Before publication

1. Use [pricci1/KOReadalong](https://github.com/pricci1/KOReadalong), private during
   the initial beta. Testers need repository access; publishing a prerelease does
   not change repository visibility.
2. Verify that the package contains KOReadalong's `LICENSE`: GNU Affero General
   Public License, version 3, matching KOReader. The GitHub release workflow
   refuses to create a draft without a nonempty license file. Companion players
   retain their own licenses and distribution obligations.
3. Finalize the exact Kindle companion downloads and source/license delivery.
   Do not send testers to moving source branches as if they were binary assets.
   Preserve the tested binaries; a rebuild is a new candidate with a new identity.

## Build locally

From the repository root, with Python 3 and Git installed:

```sh
make check
make mpv-integration
make smoke-integration
make dist VERSION=v0.1.0-beta.1
cd dist
sha256sum -c SHA256SUMS
```

`scripts/package-release` accepts only `vMAJOR.MINOR.PATCH-beta.NUMBER` versions.
It includes the plugin's Lua modules, README, documentation, read-only diagnostic,
optional license, and a generated `RELEASE.json` with the version, source commit,
and whether the checkout has local changes. ZIP entry order, timestamps, and
permissions are fixed so identical inputs produce identical archives in the same
Python/zlib environment. Build from a clean, tagged checkout for distribution;
a local dirty-tree preview is not a released candidate.

The ZIP extracts to `koreadalong.koplugin/`, `README.md`, `docs/`, `scripts/`,
`RELEASE.json`, and `LICENSE` when present. Testers copy only the plugin directory
into KOReader. Dependencies are installed separately. The checksum file describes
only the ZIP produced by that invocation, not unrelated files in `dist/`.

## First-beta companion provenance

The optional player is the preserved 980,124-byte ARM hard-float executable with
SHA256 `e2b1466a5514963e56818a58e6ecb898140eb778b14bb4796ae76ae521fbcde6`.
It includes both Opus-in-MP4 and pitch-preserving speed; a separate Opus-only
binary is not needed. Its original build record identifies local source commit
`5ef5f417c2d3e4026f3931176119c075eceab475` on baseline
[`865034f32a4df360e3f624fecf11874c5ae3d184`](https://github.com/pricci1/KinAMP-fork/commit/865034f32a4df360e3f624fecf11874c5ae3d184).
The preserved source patch has SHA256
`d2962a6732c4c6e90bcff5168ad14ffb391a321f9a10e437dd90bd4ea29d8066`.
Applying it to that baseline matches all 199 non-submodule files other than
`SPEED_PROTOTYPE.md` in published source
[`080aed2e014433063c3363720d4a59c787d91231`](https://github.com/pricci1/KinAMP-fork/commit/080aed2e014433063c3363720d4a59c787d91231).
Only that historical report was subsequently updated. This establishes source
content correspondence, not a byte-identical rebuild: original generated
configuration headers, full package inventory and link maps are unavailable.

The player source archive expands miniaudio commit
`f40cf03f80cdb7e741d43e53b7e706e8c1394bcf`, retains vendored Sonic 0.2.0 and its
Apache-2.0 license, and includes the six hash-pinned public source archives used
by `scripts/build-kindle-candidate.sh` and `scripts/build-opus-ffmpeg.sh`:
FFmpeg 7.1.1, Opus 1.5.2, GLib 2.29.18, GStreamer 0.10.25, FAAD2 2.10.1 and
zlib 1.2.11. Preserve their complete notices, including Opus patent documents,
FAAD attribution and miniaudio's embedded decoder notices. FAAD2's public header
version does not identify the user's pre-existing decoder library.

The guard is the preserved package from
[`7a3dbf7f71d62cd50ea8a52cff9d3e484cecfb06`](https://github.com/pricci1/KinAMP-fork/commit/7a3dbf7f71d62cd50ea8a52cff9d3e484cecfb06).
Its original five-payload manifest must remain intact:

| File | SHA256 |
| --- | --- |
| `guard.so` | `a4bcaca76764ea1ea8ec7fa806417ba8875486429967cff8a768a546fdc6c941` |
| `session` | `343ff9171392ddc0b2057d29caf425c0742b0d84d9e5a878dad6552120b4908f` |
| `bt-guard` | `3c3957d152cfcba00752bc259de8f6fa16bb4b2e1753d7cbb3d6d1b1ac02f634` |
| `Enable Bluetooth Guard.sh` | `2a59fb699b048ceeea3213bd88286d8c438556c20b940a260821420a518a8fba` |
| `BT_GUARD.md` | `6109ebea50268d56474627275a51c363f09fdc4e2f48870b7ed20e671866f4f4` |

Both binary ZIPs include installation/rollback instructions, provenance and GPLv3
text. The player also includes its third-party notices. Source archives accompany
the binaries on the same release rather than relying on a source offer or moving
branch. Existing proprietary device libraries are external inputs, not assets.

To build a modified player after extracting its source companion:

```sh
# Install Debian GCC/G++ ARM hard-float 12 and the tools listed by the recipe.
# Supply your own compatible device runtime at /absolute/path/to/private-target.
KINAMP_SPEED=ON KINAMP_BUILD_CACHE="$(pwd)/dependencies" \
  source/scripts/build-kindle-candidate.sh \
  /absolute/path/to/private-target /absolute/path/to/new-player-build
```

The source already contains miniaudio; no submodule download is needed. To build
a modified guard, run `source/scripts/build-bt-guard.sh /absolute/path/to/output`
with Debian bookworm GCC12 ARM hard-float. No signing secret or activation service
is required. A changed player must undergo its own validation; do not bypass the
guard's accepted-player hash. The companion READMEs distinguish historical
upstream prototype reports from the beta installation instructions.

Do not distribute the existing silent WAV regression fixture as an audible
Kindle demo. Kindle AAC/Opus acceptance needs a separate suitable sample whose
text/audio redistribution rights are documented.

## GitHub workflow

`.github/workflows/prerelease.yml` runs when a `v*-beta.*` tag is pushed. It:

1. Checks that the license is present and the version is valid.
2. Sets up the pinned desktop runtime and runs checks plus real mpv and KOReader
   integrations.
3. Builds the ZIP and verifies its checksum.
4. Creates a **draft prerelease**, attaches the ZIP and checksums, and links its
   source tag, setup instructions, and known limitations.

GitHub's automatic source archive for the tag contains the plugin source and
license. The workflow needs `contents: write` only in the draft-release job;
validation runs read-only. A failed build does not create a draft.

After the GitHub destination is configured, a maintainer can commit
the reviewed changes, push the source, then create and push a beta tag. Those
are explicit release actions, not part of local preparation. Review the draft
and attach the optional companions and source before publishing it. Regenerate
`SHA256SUMS` across exactly the five release archives, verify it after downloading
the draft assets, and replace the workflow's maintainer-placeholder notes with
download choices, compatibility, limitations and issue-report instructions.
The workflow never
publishes a draft automatically and never marks the beta as the latest stable
release.

## Kindle release checklist

The first beta is explicitly experimental. Packaging and identity checks are
publication gates; the remaining native endurance/shortcut/recovery checks are
open qualification work and must be disclosed, not silently marked passed.

- [ ] Record the plugin tag and exact player/guard source commits and binary hashes.
- [ ] Provide the compatible player download and source, dependency notices,
      build recipes, and any applicable installation information. KinAMP is
      GPLv3+; the speed fork also includes Sonic and other dependencies.
- [ ] Exclude private firmware/runtime libraries and sysroots from every asset.
- [ ] Supply and verify a separate guard package only for its exact supported
      firmware/player identities, with stop-first, recovery, and rollback guidance.
- [ ] Install the extracted plugin ZIP into a clean KOReader profile, not a
      checkout-linked plugin directory.
- [ ] Run final-package native PW6 listening beyond the Bluetooth idle deadline,
      then pause/resume, seek, hand off chapters, and close/reopen silently.
- [ ] Check repeated AAC handoffs for resource growth; record remaining limits
      honestly rather than treating short-run speed tests as endurance acceptance.
- [ ] Verify guard enable/disable/recovery and its Library shortcut on the device.
- [ ] Put the exact supported Kindle model, firmware and KOReader version in the
      release notes; identify other devices as unverified.
- [ ] Add the repository issue-report link and exact companion downloads to the
      draft, and keep the README's prerelease link current.

The native-tested speed player has SHA-256
`e2b1466a5514963e56818a58e6ecb898140eb778b14bb4796ae76ae521fbcde6`.
The guard's published source pins that identity. A rebuild with a different hash
is a new candidate: do not bypass the guard's checks or call it the tested binary.
