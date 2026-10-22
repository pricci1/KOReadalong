# Storyteller phone audio (experimental, unreleased)

Play the audio in the official Storyteller v3 app while KOReader follows the
same aligned EPUB. The phone controls playback; KOReadalong receives sentence
positions over the local network and draws its usual temporary narration mark.
There is no audio streaming, server login, or cloud-progress polling here.

This feature is in the source checkout, not v0.1.0-beta.4. It targets the native
v3 **Live Reading Sync** protocol, not Storyteller v2 or the web player.
Desktop KOReader has been exercised with a simulated phone, real UDP/mDNS,
native controls, and CRe rendering. Physical iOS/Android, Kindle Wi-Fi,
background playback, Bluetooth latency, and battery use remain unverified.

## Connect

1. Put the **same aligned EPUB** on the phone and in KOReader. A separately
   downloaded/re-aligned edition may use different paths, IDs, or timings.
2. Connect both devices to the same trusted Wi-Fi/LAN. Enable **Live Reading
   Sync** in the v3 phone app and allow local-network access if prompted. The
   app build must include this setting; ordinary server progress sync is not
   sufficient. Keep KOReader's Wi-Fi on yourself; the plugin does not change
   radio or power policy.
3. In KOReader choose **Read along → Audio source → Storyteller phone
   (experimental)**, then **Listen** and accept the trusted-network notice.
4. Play or seek on the phone *after* starting the listener. Discovery alone
   does not make the phone send its current position; an entry must advance.
5. Choose **Choose phone / book**, select the matching phone/book, and confirm
   **Follow**. Confirm the phone address, book identity, and matching text.
   A text match alone cannot prove that two EPUBs are the same book.

The receiver is IPv4-only. Discovery uses `_storyteller-lrs._udp.local.` on
UDP 5353 and positions arrive on the receiver's dynamically assigned UDP port.
Both must be permitted between the devices; guest-network client isolation,
multicast filtering, VPNs, or another exclusive mDNS listener can interfere.
The receiver address and port appear in the panel for troubleshooting.

**This is not authenticated pairing.** Another LAN device can spoof positions
or the selected sender/book identity. Do not expose the receiver to the internet
or use it on an untrusted network. KOReadalong sends service-discovery records,
but never sends reading positions, transport commands, or book content back to
the phone.

## Correct the marks, not the phone's speed

- **Later 0.25 s** holds new marks for an additional quarter second, up to
  5 seconds. Use this when marks arrive before the sound, for example with
  delayed Bluetooth output.
- **Earlier 0.25 s** reduces that delay, then allows up to 2 seconds of
  *predictive* advance. The panel labels positive correction **estimated**
  and asks for acknowledgement before enabling it.
- **Reset timing** removes the correction and shows the latest received
  position. It does not seek or change speed on the phone.

Correction is saved per book. It uses time since local receipt, not the
difference between device clocks. It cannot automatically measure Bluetooth,
network, rendering, or e-ink latency.

Earlier is intentionally conservative: two adjacent, naturally spaced updates
at a stable rate must agree before predicting one next target in the same
chapter/audio resource. Seeks, repeated/ambiguous text targets, gaps, and rate
changes disable prediction until steady observations return. If confirmation
does not arrive by 750 ms after the estimated boundary, the last received
target replaces the prediction. It never runs through chapters on a guessed
clock. A pause can still briefly expose an estimated next sentence.

The upstream protocol has no continuous audio clock, pause/resume event, EOF,
heartbeat, or acknowledgement. **Waiting** means no recent positions, which
may be a pause, a long passage, or network loss—not a confirmed playback state.
The last confirmed mark stays visible. Accurate continuous/word-level sync
would require additional timing and transport-state messages from the phone.

## Read and browse

**Follow: on/off**, **Return to narration**, the existing gestures, and
**Narration mark → Margin bar / Underline / Off** work with phone positions.
Browsing does not seek the phone; Return jumps to the current marked passage.
**Read from here** is unavailable in remote mode because the phone owns seeks.
There are no local pause, seek, speed, or progress-bar controls in this mode.

**Hide** dismisses the panel without stopping reception. **Stop following**
closes the listener and clears its marks, but does not stop phone audio. The
source choice and correction are remembered; the phone/book selection is not.
Opening a book never listens automatically or starts audio. Suspend,
network-disconnect notifications, book close, and exit stop reception; press
Listen and select the phone again afterward. Restart listening after changing
interfaces, a phone restart, or a backwards phone-clock adjustment.

Switching to **This device** closes reception and restores the local controls
without autoplay. Switching away from local playback closes the local player
and preserves its saved resume point, rather than issuing the reset-style
Stop. Remote positions never overwrite that local audio resume point.
Remote mode needs neither mpv nor KinAMP and does not extract embedded audio.

## If it does not follow

- **No candidates:** check the phone's Live Reading Sync switch, local-network
  permission, Wi-Fi/client isolation, and receiver address. Advance or seek on
  the phone after listening. On Apple builds, the app's Live Reading Sync
  status shows peers and positions sent.
- **No match / Book-text mismatch:** open the identical aligned EPUB. Phone
  indices are not trusted; the XHTML archive path plus fragment ID must match.
  A selected phone changing book or reporting an unknown target clears the
  old mark. Choose the new source explicitly if that is intentional.
- **Network error:** the listener closes on startup or terminal socket failure.
  Resolve the network/UDP-port conflict, then press Listen again. UDP loss may
  be silent, so Waiting is not a guarantee of a functioning connection.
- **Text highlighting unavailable:** a matching target could not be resolved
  to a CRe range, or a delayed first mark is still pending. Unsupported text
  targets do not turn into persistent annotations or start audio.

## Reproduce without a phone

The standard-library Python simulator parses EPUB overlays and sends the
published packet shape. It **does not play audio**. From a source checkout,
open the same book in KOReader, enable listening, then run:

```sh
./scripts/storyteller-simulator spec/fixtures/chapter-transition.epub --repeat 5
./scripts/storyteller-simulator book.epub --interactive --delay 0.15
```

Discovery requires exactly one `KOReadalong-` receiver. Alternatively use
`--target HOST:PORT` from the panel. `--interface` takes a local IPv4 address;
`--mdns-port` is available for isolated tests. `--repeat` is a finite pass count.
Interactive commands are `pause`, `resume`, `next`, `previous`, `seek INDEX`,
`rate VALUE`, and `quit`; indices are zero-based overlay entries. Pause is
silence, not a fabricated wire message. Already delayed packets may still arrive.

```sh
make check
make remote-integration
./scripts/run-remote-smoke --artifacts .amp/in/artifacts/remote-follow --record
./scripts/run-remote-smoke --width 800 --height 600
```

Use `--plugin-dir /path/to/extracted/koreadalong.koplugin` to run the same
native scenario against an unpacked release. The runner creates an isolated
runtime view rather than changing the shared runtime's plugin installation.

The native test requires the pinned Linux KOReader runtime, Xvfb, X11/XTest,
and optional ffmpeg for recording. It uses a separate HOME, copied synthetic
fixture, and private loopback mDNS port. Only the phone is simulated: production
plugin lifecycle, UDP, DNS-SD, CRe text resolution, ephemeral marks and native
pointer interactions remain real. It covers explicit selection, timing,
cross-chapter positions, browsing/return, wrong phone/book, silence, Hide,
Stop, bind failure/retry, suspend, source switching and cleanup. Unit tests
exercise predictive boundaries and malformed/reordered traffic independently.

## Protocol reference and implementation limits

The wire contract was checked against Storyteller tag
[`web-v3.0.0-beta.55`](https://gitlab.com/storyteller-platform/storyteller/-/tree/web-v3.0.0-beta.55),
commit [`2f12802e`](https://gitlab.com/storyteller-platform/storyteller/-/commit/2f12802e250fba5de8ad3a869feb3c010d39ff3f), specifically
`LiveReadingSyncActor.swift`, `LiveReadingSyncPacket.swift`,
`MediaOverlayManager.swift`, and `BonjourPeerDiscovery.swift`. The protocol
is implemented independently; no upstream implementation code is vendored.

`storytellersync.lua` owns nonblocking sockets and a bounded DNS-SD responder;
`remotefollower.lua` validates packets, selects the source, orders updates, and
applies correction using an injected clock. `narrationranges.lua` shares the
local player's XPointer resolution, not its audio or saved-progress state.

The receiver handles PTR/SRV/TXT/A, service enumeration, multicast, QU and
legacy-unicast queries, periodic TTL refresh, and best-effort TTL-zero goodbye.
It is not a full mDNS daemon: no conflict probing/renaming or known-answer
suppression. Instance names use 96 bits of OS randomness. One IPv4 interface
is selected at startup. Work is bounded to 16 datagrams per socket per poll,
8192 bytes per datagram, JSON depth 16, 32 DNS questions, 16 candidate sources,
and 64 delayed positions. Physical Bonjour/Android NSD interoperability is
still a release-validation requirement.
