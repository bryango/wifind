# wifind - design

Status: implemented (v1). See `README.md` for usage; this file records the
design and the reasoning behind it.

## 1. Goal

A terminal UI for macOS that scans nearby Wi-Fi access points, lists one row
per access point (SSID, BSSID, channel, band, width, RSSI, security), lets the
user pick one with the arrow keys, and connects to it.

Scope: scan + select + connect. No packet capture, no channel hopping, no
password storage of our own.

## 2. Reference implementations and what we take from them

`braineo/airport-bssid` (Swift, CoreWLAN)

- Shows the shape of a CoreWLAN scanner: `CWWiFiClient` -> `interface()` ->
  `scanForNetworks` -> read `ssid` / `bssid` / `wlanChannel.channelNumber` /
  `rssiValue`, then `interface.associate(to:password:)` to connect.
- Records that `airport -A=ssid -BSSID=...` no longer exists, that BSSID comes
  back empty on macOS 10.15+ unless the binary is signed, and that the fallback
  for connecting is SSID + channel. We keep that fallback as a matching rule.

`jaisonerick/macwifi` (Go library + Swift helper) and `jaisonerick/macwifi-cli`

- Documents the environment we must live in: macOS 14.4 removed the `airport`
  scan path, `wdutil info` redacts BSSID even under sudo, `networksetup` never
  listed nearby networks, and CoreWLAN only returns real SSIDs/BSSIDs to a
  process that has Location Services permission (Apple DTS: scripts and
  launchd daemons cannot satisfy this).
- Gates scanning on CoreLocation authorization (`CLLocationManager`,
  `requestAlwaysAuthorization`, poll until the status leaves `notDetermined`),
  because without it `CWNetwork.ssid` is nil for every result.
- Uses `/usr/sbin/networksetup -listpreferredwirelessnetworks en0` to tell
  saved networks from new ones, and reads stored credentials from the login
  keychain (`kSecClassGenericPassword`, description `AirPort network password`,
  account = SSID).
- Handles the case where a saved network is not visible in the scan by
  synthesizing a row for it.
- Ships its scanner as an `.app` bundle and launches it with `open -W`. Section
  10 explains why that turned out to be the whole trick: the launch context,
  not the signature, decides whether macOS hands over network names. We do not
  copy the Go/loopback-socket IPC design, because a one-shot request/response
  over temp files covers scan and join without a listening socket.

## 3. Measured constraints on this machine

macOS 15.7.5 (build 24G624), arm64, Swift 6.2.4, Xcode toolchain present.

| Probe | Result |
| --- | --- |
| `airport -s` / `airport -I` | present but neutered: prints the deprecation warning only, no data |
| `wdutil info` | usage error without root; redacts BSSID per macwifi docs |
| `networksetup -setairportnetwork` | still available on 15.7.5 (verified from `networksetup -help`) |
| `python3` + pyobjc | no `objc`/`CoreWLAN` module; a Python TUI would need a Swift helper anyway |
| `system_profiler SPAirPortDataType` | reachable, reports the interface but not the nearby list |

So the scanner is Swift + CoreWLAN, and `networksetup` is kept as the connect
fallback. The list of nearby APs comes from CoreWLAN only.

## 4. Layout

```
wifind/
  Package.swift
  Makefile
  README.md
  DESIGN.md
  Sources/WifindKit/          testable core, no UI
    Model.swift               NetworkEntry, Band, SortMode, BandFilter, formatting
    Security.swift            CWSecurity probe order -> label + rank
    Scanner.swift             CoreWLAN scan, dedupe, flags, sort
    Preferred.swift           local scan, else delegate to the app bundle
    Helper.swift              request/response protocol, bundle discovery
    Location.swift            CoreLocation authorization gate
    SavedNetworks.swift       networksetup -listpreferredwirelessnetworks
    Keychain.swift            "AirPort network password" lookup
    Associator.swift          associate + fallback + verification
    Doctor.swift              capability report
  Sources/wifind/             executable
    main.swift                argv dispatch
    CLI.swift                 scan / connect / doctor / tui, --json
    Term.swift                raw mode, ANSI, key decoding, display width
    TUI.swift                 render loop, list, modals, key handling
  Tests/WifindKitTests/       pure logic tests (band, dedupe, sort, width, wire)
  scripts/make-app.sh         wrap the binary in Wifind.app and sign it
  scripts/Info.plist          location usage strings for the bundle
  scripts/wifind.entitlements Wi-Fi info entitlement, off unless a profile exists
```

## 5. Data model

```swift
struct NetworkEntry {
    var ssid: String?        // nil = redacted by macOS, or hidden network
    var bssid: String?       // nil = redacted by macOS
    var channel: Int?
    var band: Band           // .ghz2, .ghz5, .ghz6, .unknown
    var widthMHz: Int?
    var rssi: Int?
    var noise: Int?
    var security: String
    var phyMode: String?
    var isCurrent: Bool
    var isSaved: Bool
    var ref: CWNetwork?      // CoreWLAN handle used by the connect path
}
```

Identity for dedupe is the BSSID when present, otherwise `ssid#channel`. One
row per BSSID is deliberate: a mesh or roaming setup exposes several BSSIDs per
SSID and the user asked for BSSIDs in the list.

## 6. Scan pipeline

1. Resolve the interface (`--iface`, else the system default). If it is
   missing or powered off, report it instead of an empty list.
2. Check CoreLocation status; if `notDetermined`, request authorization and
   wait (bounded) so the first scan is not wasted.
3. `scanForNetworks(withName: nil)` on a background queue.
4. Map each `CWNetwork` to a `NetworkEntry`.
5. Read the saved-network list and the current SSID/BSSID, then set flags.
6. Dedupe, sort (default: RSSI desc, nil last), hand to the UI.

7. If macOS redacted every SSID, re-run the same scan inside the app bundle
   (section 10.1) and use that result instead. A redacted list is a symptom,
   not a final answer, and the retry is invisible except for one status line.

`isCurrent` prefers BSSID equality and falls back to SSID equality.

## 7. Band classification

Primary source is `CWChannel.channelBand`. Numeric fallback when the band is
unknown: 1-14 -> 2.4 GHz, 32-177 -> 5 GHz, otherwise unknown. Channels 1-14 can
also be 6 GHz channel numbers, so numbers alone cannot decide; the UI shows
`?` rather than guessing.

## 8. TUI

Stack: raw mode via `termios` (no `ICANON`, no `ECHO`, `VMIN=0/VTIME=1`), alt
screen buffer, cursor hidden, single `write()` per frame, restore on every exit
path (defer plus SIGINT/SIGTERM/SIGWINCH handlers).

```
 wifind  en0  Wi-Fi on   42 APs   sorted by RSSI        12:31:07
 BAND  SSID                     BSSID              CH   W   RSSI   SEC
  5G   home-5g                  aa:bb:cc:dd:ee:01   44  80  ▂▄▆█  WPA2      *
  2.4G neighbour                aa:bb:cc:dd:ee:02    6  20  ▂▄__  WPA2/WPA3 S
 ...
 5G home-5g  ch 44 (80 MHz)  5 GHz  WPA2  802.11ax  -52 dBm  noise -92 dBm
 [status: Scanned 42 APs in 1.8 s]
 up/down move  enter connect  r rescan  / filter  tab band  s sort  ? help  q quit
```

Keys: `up`/`down` and `k`/`j` move, `g`/`G` jump, `enter` connect, `r` rescan,
`/` incremental filter over SSID and BSSID, `tab` cycle band filter, `s` cycle
sort (RSSI/SSID/channel/band/security), `?` help overlay, `q`/`ctrl-c` quit.
Band tags are colour-coded (2.4 GHz yellow, 5 GHz cyan, 6 GHz magenta), the
current network is marked `*`, saved networks `S`. SSID truncation is
display-width aware so CJK SSIDs stay aligned.

States: scanning (spinner in the header), list, filter input, password modal
(echo off, `*` masking, esc cancels), connecting (per-row spinner), notice
banner (for example when every SSID is redacted), help overlay.

### 8.1 Painting, and the two bugs that made the screen jump

The first implementation wrote a full screen every frame: `ESC[H`, every
line joined with `\r\n`, then `ESC[J`. It flickered, and on a normal
80-column terminal it visibly jumped. Two independent causes:

1. **Lines were never clamped to the terminal width.** The redaction banner is
   135 columns wide and the table row was 82; anything past the edge wraps, so
   each frame occupied more physical rows than the layout assumed and
   everything below shifted. Measured in an 80x24 PTY before the fix: 18 lines
   over the limit, widest 135.
2. **Every frame rewrote all 24 rows at 10 Hz** to animate a spinner, with no
   diffing and no synchronised-update markers, so the terminal was asked to
   redraw continuously.

The row width was wrong by construction, not by accident: the reserved-space
arithmetic counted one separator too few, so `totalWidth` came out as
`columns + 1`. That arithmetic now lives in `TableLayout` with
`totalWidth` as a stated invariant, and a test walks every width from 60 to
200 to hold it.

Painting now works differently:

- every line is passed through `Display.truncateVisible`, which measures
  visible columns the way the terminal does - escape sequences are copied
  through and never counted - so a line cannot exceed the width even if a
  builder is wrong;
- the frame is diffed against the previous one and only changed rows are
  written, each addressed absolutely (`ESC[<row>;1H`) and cleared to the
  end of its line, with rows that no longer exist blanked the same way;
- the whole write is wrapped in `ESC[?2026h`/`l` (synchronised update),
  which terminals that support it use to swap the frame atomically, and which
  everything else ignores;
- the header and footer are built by adding segments only while they still
  fit, so a narrow terminal loses the clock and the sort mode instead of
  wrapping;
- the note wraps to at most two lines (`Display.wrap`, word-aware, CJK-aware)
  because it is the only explanation for a redacted list.

Measured in the same 80x24 PTY after the fix: 0 lines over the limit, widest
line exactly 80, 7 rows written in 9 seconds instead of a full screen 10 times
a second, 646 bytes captured instead of tens of kilobytes. At 50 and 120
columns: 0 lines over the limit at each.

### 8.2 The permission prompt must not block

The first version called the blocking Location Services request before entering
the event loop. When the dialog cannot be answered - a bare binary starts
without one, and any headless run - the loop then sat still for the full
thirty-second timeout, showing a single frozen status line and ignoring every
key. Measured: two paints in nine seconds, both from before the wait.

The request now runs on its own queue, the loop keeps rendering and handling
keys while it is pending, the status line says the keys still work, and when
the grant arrives the list is scanned again automatically because the previous
scan was necessarily redacted.

## 9. Connect flow

1. If the row is the current network, say so and stop.
2. Password source: inline prompt for anything not saved; for saved networks a
   keychain lookup first (`AirPort network password`), with empty input as
   "use the system credential".
3. If the row came from the helper it has no `CWNetwork` handle, so the join
   runs in the helper instead and matches SSID/BSSID/channel against a fresh
   scan there. Rows scanned locally take the direct route:
   `interface.associate(to:password:)`, rescanning first if the handle went
   stale, and matching by BSSID, else SSID + channel.
4. On failure with a known SSID, fall back to
   `networksetup -setairportnetwork <iface> <ssid> [password]`.
5. Poll `interface.ssid()` / `bssid()` for up to 20 s, reporting progress in
   the status line, then refresh the scan on success.

Passwords are never passed on the command line (`connect` reads stdin) and
never echoed. A passphrase that has to reach the helper travels in a 0600
request file inside a 0700 directory that the helper deletes on read.

## 10. Permissions: what actually unlocks the names

An earlier version of this section claimed that a stable signature plus the
Wi-Fi entitlement is what macOS requires. Measurement says otherwise, and the
corrected model is what the code now implements.

Same machine, same signed binary, same Location Services grant
("authorized (always)"), differing only in how the process was started:

| Launch context | Reports | SSID | BSSID |
| --- | --- | --- | --- |
| binary executed from a shell | 15 | 0 | 0 |
| binary inside `Wifind.app`, executed from a shell | 15 | 0 | 0 |
| `Wifind.app` launched with `open -W` (parent: launchd) | 15 | 15 | 15 |

Things that did **not** change the outcome: the signing identity (ad-hoc and a
generic Apple Development identity, `dev@example.com (ABCDE12345)`, both
tested), an existing Location Services authorization, and
`--request-location`. The one thing that did: being launched by launchd.

The entitlement is a trap worth recording. Applying
`com.apple.developer.networking.wifi-info` to a build with no embedded
provisioning profile does not merely fail to help, it makes macOS SIGKILL the
process at launch (exit 137, no output). This machine has no provisioning
profiles at all, so `scripts/wifind.entitlements` exists as documentation and
is applied only when a profile is present.

Degradation, best case first:

| Condition | Behaviour |
| --- | --- |
| bundle present, helper answers | full rows: SSIDs, BSSIDs, bands |
| no bundle, or the helper fails | rows keep channel, band, width, RSSI and security; names show as `(hidden)` and the status line says why |
| Location Services denied for the bundle | same as above; the first launch prompts, and the help overlay names the exact System Settings pane |

`wifind doctor` reports the launch context, the Location Services status,
whether the entitlement is present, and the visible/total counts, so every
claim above can be re-checked on another machine.

### 10.1 The helper protocol

Scanning is not the only action that needs the privileged context: CoreWLAN's
only association API is `associateToNetwork:(CWNetwork *)`, and those objects
cannot be constructed on the redacting side. So both actions go through one
mechanism.

```
client                                    Wifind.app (started by open -n -W)
  |  mkdtemp 0700, write request.json 0600   |
  |------------------------------------------>|  wifind helper --request R --response S
  |  open -n -W <bundle> --args helper ...    |  scan, or associate + verify
  |<------------------------------------------|  write response.json 0600, exit
  |  read the answer, delete the directory    |
```

- Request: `{action, iface, ssid, bssid, channel, password, timeout,
  includeSaved}`. Carrying the passphrase in a 0600 file keeps it out of
  `argv`, where `ps` would show it.
- Response: `{ok, error, via, interface, rawCount, ssidVisible, bssidVisible,
  duration, notes, accessPoints[]}`, with rows shaped like the scan JSON.
- `open -W` waits for the helper to exit, so the client needs no polling and
  no socket, and the helper cannot outlive its request.
- The helper never delegates again (`Helper.runningAsHelper`), which is what
  stops the fallback from recursing.
- Rows cross the boundary without a `CWNetwork`, so the join side re-scans
  inside the helper and matches by BSSID, else SSID + channel - the same rule
  `airport-bssid` settled on for the same reason.

The bundle deliberately has no interface of its own. It links no UI framework,
is marked `LSUIElement` so it cannot take a Dock icon or steal focus, and
double-clicking it in Finder achieves nothing: with no terminal it prints one
line and exits 2. That is the point rather than an omission - the bundle exists
to be *launched by the tool* in the context macOS trusts, and the interface
belongs to the TUI in the terminal. Anyone who expects an app window here is
looking at the wrong half, so `README.md` says so explicitly.

## 11. Build

```
make build     # swift build -c release
make test      # swift test
make app       # bundle + sign -> Wifind.app (SIGN_IDENTITY, ENTITLEMENTS)
make run       # build then run the TUI
```

## 12. Testing

- `swift test`: band classification (including the 6 GHz ambiguity), security
  label mapping, dedupe key selection, sort orders, filter matching, and
  display-width truncation for ASCII and CJK strings.
- Manual: `wifind doctor`, `wifind scan --json`, then the TUI in a real PTY.

### What was observed on this machine

Scanning and the UI are verified against live hardware; the association path is
implemented but was not exercised, because joining a network would change this
machine's connectivity.

- `swift test`: 24 tests, 0 failures.
- `wifind scan`: 9 access points from 15 reports in 1.5 s, bands classified as
  3 × 2.4 GHz and 5 × 5 GHz, widths 20-160 MHz, `802.11ax`/`802.11n` PHY
  labels, so the dedupe and band mapping work on real data.
- TUI in a PTY: header, columns, RSSI bars, colour-coded bands, detail line,
  status line, help overlay, `s` sort cycle and `tab` band filter all
  behaved; `q` restored the terminal and exited 0.
- Every SSID and BSSID came back redacted, first for the bare binary (Location
  Services `not determined`) and then inside `Wifind.app` after the prompt was
  answered (`authorized (always)`). That is the macOS 15 rule documented in
  section 10, not a wifind bug: this machine has no Developer ID identity
  installed, so the entitlement that unredacts Wi-Fi details cannot be issued
  here. `wifind doctor` reports the exact state in both cases.
- The airport probe reports `present but non-functional (deprecation stub)`,
  which matches the direct measurement in section 3.

### Second pass, after signing and the helper

- `scripts/make-app.sh` signs with the first usable identity by SHA-1
  (Developer ID Application, else Apple Development), so the repository holds
  no personal name and no key material; the private key stays in the keychain
  and `codesign` is the only thing that talks to it.
- `make test`: 29 tests, 0 failures, including the helper wire round trip.
- Assigning the process to the helper automatically is verified end to end:
  `wifind scan` prints `macOS hid the names here; scanning through
  Wifind.app...` and then reports `route: helper` with 8 of 8 SSIDs and
  8 of 8 BSSIDs, where the same call with `--no-helper` reports 0 of 8.
- The TUI in a PTY shows real names (`Iceland`, `Antarctica`,
  `CU_观夏summer_5G`), colour-coded band tags, the current network marked
  `*S`, and the detail line for the selected row.
- Still not exercised: a live join. The machine's Wi-Fi is already associated,
  and re-associating would change connectivity, so the association path is
  verified by construction and by its error paths only.

### Third pass, the flicker fix

- 48 tests, 0 failures. The new ones cover the row-width invariant across 60 to
  200 columns, styled-row width, ANSI-aware truncation, and the note wrapping.
  One of them immediately caught an off-by-one in the first version of the
  fixed arithmetic, which is the reason it exists.
- Frame measurements were taken by driving the TUI in a Python `pty` of a
  chosen size, then parsing the captured bytes: split on the synchronised-update
  marker, take each `ESC[<row>;1H ... ESC[K` segment, and measure visible
  width with East Asian wide characters counted as two.
- Verified in a real terminal by the user's report that the static CLI was fine
  while the TUI flickered; the fix is confirmed by the measurements above.

## 13. Non-goals

- Monitoring mode, frame capture, packet statistics.
- Storing credentials of our own; the keychain remains the only store.
- Changing system settings, joining networks silently in the background.
- Linux support.
