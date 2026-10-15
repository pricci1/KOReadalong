# Preparing a GitHub prerelease

The release artifact is one platform-neutral plugin ZIP, plus `SHA256SUMS`.
Kindle testers also need a separately installed compatible player and possibly
the firmware-specific Bluetooth guard. The plugin package never bundles either
component, firmware libraries, private settings, or a Kindle sysroot.

## Before publication

1. Configure the GitHub repository that will host KoReadalong source and prereleases.
2. Verify that the package contains KoReadalong's `LICENSE`: GNU Affero General
   Public License, version 3, matching KOReader. The GitHub release workflow
   refuses to create a draft without a nonempty license file. Companion players
   retain their own licenses and distribution obligations.
3. Finalize the exact Kindle companion downloads and source/license delivery.
   Do not send testers to moving source branches as if they were binary assets.

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
and finish the checklist below before making it public. The workflow never
publishes a draft automatically and never marks the beta as the latest stable
release.

## Kindle release checklist

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
- [ ] Add tester contact/issue-report instructions and companion download links
      to the draft. Replace the README's beta-preparation notice with that
      repository's prerelease link when publication is actually ready.

The native-tested speed player has SHA-256
`e2b1466a5514963e56818a58e6ecb898140eb778b14bb4796ae76ae521fbcde6`.
The guard's published source pins that identity. A rebuild with a different hash
is a new candidate: do not bypass the guard's checks or call it the tested binary.
