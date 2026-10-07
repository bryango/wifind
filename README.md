# wifind

A terminal UI that scans nearby Wi-Fi access points, lists one row per access
point with its SSID, BSSID, channel and band, and joins the one you pick with
the arrow keys.

```
 wifind │ en0 │ 18 APs │ band all 2.4G 5G 6G │ sort RSSI │ 22:10:13
  BAND SSID                     BSSID              CH     RSSI▼ SEC
▸ 2.4G Iceland                  18:f2:2c:04:a7:11    6     ▂▂▂▂ -42 WPA2/WPA3  S
  5G   Antarctica               a4:2b:8c:11:22:33   36     ▂▂▂▂ -45 WPA2/WPA3  S
  5G   Iceland                  18:f2:2c:04:a7:12   36     ▂▂▂▂ -48 WPA2/WPA3 *S
  2.4G (hidden)                60:38:e0:aa:bb:cc    6     ▂▂__ -66 OWE
 2.4 GHz · ch 6 (40 MHz) · 2.4 GHz · WPA2/WPA3 · 802.11n · -42 dBm · saved
 Scanned 18 access points in 0.4 s via Wifind.app
 ↑↓ move  ⏎ connect  r rescan  / filter  tab band  s sort  ? help  q quit
```

## Build

```sh
make build          # release binary at .build/release/wifind
make test           # unit tests
make app            # wrap it in Wifind.app and sign it
make run            # build and launch the TUI
make doctor         # print the capability report
```

macOS 13 or newer and the Xcode command line tools; no third-party
dependencies.

## The one thing that matters

**macOS only reveals network names to a process launched by LaunchServices.**
Not to a signed binary run from a shell, not to one with the right entitlement
- to a bundle that launchd started. Everything else in this project follows
from that.

Details, all measured on macOS 15.7.5:

| Probe | Result |
| --- | --- |
| `airport -s` | prints the deprecation notice only, no scan data |
| `wdutil info` | needs root, and redacts BSSID |
| CoreWLAN scan, binary started from a shell | 15 access points, **0** with SSID, **0** with BSSID |
| CoreWLAN scan, `.app` bundle started from a shell | same: 0 with SSID, 0 with BSSID |
| CoreWLAN scan, bundle launched with `open -W` | 15 access points, **15** with SSID, **15** with BSSID |

The middle two rows held with - and without - a signed identity, and with
Location Services already granted. Adding
`com.apple.developer.networking.wifi-info` without an embedded provisioning
profile does not help either: macOS SIGKILLs the app at launch (exit 137).

So wifind does not ask you to remember any of this. It scans locally first; if
macOS redacts every name, it re-runs the same scan through `Wifind.app` using
`open -n -W`, which is the launch context that gets the real data. That
happens automatically for the TUI, `scan` and `connect`. It needs one thing:
a built bundle, so run `make app` once.

```sh
make app
./.build/release/wifind        # the TUI, which delegates scanning to Wifind.app
```

Pass `--no-helper` to keep everything in one process and accept the redacted
list. When no bundle exists, or the helper cannot run, the tool says so in the
status line rather than showing a list of anonymous access points.

### Wifind.app has no window, and double-clicking it does nothing

The bundle is a launch context, not an application you run. `Wifind.app` contains
a binary, an Info.plist and a signature - no AppKit, no SwiftUI, no window of
any kind - and it is marked `LSUIElement`, so it never takes a Dock icon or
steals focus. Open it from Finder and nothing appears; run the binary inside it
from a shell and it exits with:

```
wifind: the interactive UI needs a terminal (stdin and stdout must be a TTY).
```

That is the intended behaviour in both cases. The interface is the TUI, and the
TUI lives in the binary you launch from your terminal:

```
./.build/release/wifind          # what you run
```

`Wifind.app` is started by that binary, on demand, through `open -n -W`, and
only to perform one scan or one join in the launch context that macOS grants
Wi-Fi details to. It has no UI because it has nothing to show: it writes a JSON
answer to a temp file and exits.

## Usage

```
wifind                        interactive list (default)
wifind scan [options]         print the scan as a table
wifind connect <ssid> [opts]  join a network
wifind doctor [options]       report what macOS lets this process see
```

Options:

```
--iface <name>       Wi-Fi interface (default: system default, usually en0)
--json               machine readable output (scan, doctor)
--band <all|2.4|5|6> restrict to one band
--sort <mode>        rssi (default), ssid, ch, band, sec
--no-saved           do not add saved-but-out-of-range networks
--no-helper          never delegate to Wifind.app
--bssid <mac>        connect: pick one access point of a multi-BSSID network
--channel <n>        connect: pick one channel
--password-stdin     connect: read the password from stdin
--request-location   scan/doctor: ask for Location Services before scanning
--out <path>         scan/doctor: write the output to a file
--no-scan            doctor: skip the scan probe
```

### Keys

| Key | Action |
| --- | --- |
| `↑` `↓` or `j` `k` | move the selection |
| `enter` | connect to the selected network |
| `r` | rescan |
| `/` | filter by SSID or BSSID (enter applies, esc clears) |
| `tab` | cycle the band filter: all, 2.4G, 5G, 6G |
| `s` | cycle the sort: RSSI, SSID, CH, BAND, SEC |
| `?` | help overlay, including which process scanned and what it could see |
| `q` | quit |

### Connecting

`enter` on a row joins that access point. Open and OWE networks connect
straight away. Otherwise wifind uses the credential macOS already stored for
that network when there is one; if not, it prompts with the input hidden.

The join itself runs in the same privileged context as the scan, because
CoreWLAN only takes a `CWNetwork` object and those do not cross a process
boundary; the request carries SSID, BSSID and channel instead, and the helper
matches them against a fresh scan. If the helper cannot join,
`networksetup -setairportnetwork` is tried last.

Passwords are never written to disk beyond the 0600 request file the helper
deletes on read, never passed as command line arguments, and never echoed.

## Signing

`make app` signs with the first usable identity it finds (Developer ID
Application, else Apple Development, else ad-hoc) and never touches private key
material itself - `codesign` asks the keychain, and the identity is referenced
by SHA-1 hash so no personal name is baked into the repository. Override with:

```sh
SIGN_IDENTITY=- make app                 # force ad-hoc
SIGN_IDENTITY=<sha1|name> make app       # pick a specific identity
```

Signing is worth doing because it gives TCC a stable identity for the Location
Services prompt, so a re-signed build asks once and then stays quiet. It is
**not** what unlocks the network names: the launch context is. See
`scripts/wifind.entitlements` for the entitlement that *would* be needed on a
machine with a provisioning profile, and why it is off by default.

## Row anatomy

`BAND` comes from CoreWLAN's channel band, falling back to the channel number
(1-14 → 2.4 GHz, 32-177 → 5 GHz) when the band is unknown. A bare channel number
cannot tell 6 GHz from 2.4 GHz, so those rows show `?` instead of a guess.

`S` marks a saved network, `*` the current one, and `S-` a saved network
that is out of range right now (kept in the list so you can still join it).

## Files

```
Sources/WifindKit/   scanning, security mapping, keychain, association, helper
Sources/wifind/      TUI and CLI
Tests/               unit tests for the logic above
DESIGN.md            design notes, reference implementations, measured limits
```

## Prior art

wifind was written after studying three existing macOS Wi-Fi scanners. Each is
worth a look if you are doing something similar:

- [braineo/airport-bssid](https://github.com/braineo/airport-bssid) - Swift and
  CoreWLAN. Shows the scan-then-associate shape, records that
  `airport -A=ssid -BSSID=...` no longer exists, and settles on SSID + channel
  as the fallback for connecting.
- [jaisonerick/macwifi](https://github.com/jaisonerick/macwifi) - a Go library
  with a signed Swift helper, and the source of most of the constraints above:
  the retired `airport` path, redacted BSSIDs, the CoreLocation gate, the
  keychain item, and the `open -W` launch.
- [jaisonerick/macwifi-cli](https://github.com/jaisonerick/macwifi-cli) - the
  command line front end for that library; its table layout and `C`/`S` flags
  informed wifind's columns.

`DESIGN.md` section 2 records what was taken from each, and what was left out.
(`airport-bssid` is GPL-3.0; both `macwifi` projects are MIT.)

## License

GNU General Public License v3.0 - see [LICENSE](LICENSE).
