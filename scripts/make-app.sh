#!/usr/bin/env bash
# Wrap .build/release/wifind in Wifind.app and sign it.
#
# Signing matters twice on macOS:
#   1. Location Services (TCC) attributes permission to a code identity. A
#      bare binary inherits the terminal's entry; a process launched from an
#      app bundle gets its own.
#   2. Unredacted SSIDs and BSSIDs are only handed to a process with a stable
#      signature. Ad-hoc signing satisfies (1) but the grant is tied to the
#      code hash, so a rebuild needs a fresh approval and macOS may still
#      redact Wi-Fi details.
#
# Identity selection:
#   SIGN_IDENTITY=<name|sha1>  use that identity
#   SIGN_IDENTITY=-            ad-hoc (no certificate)
#   unset                      prefer Developer ID Application, then Apple
#                              Development, then ad-hoc
#
# ENTITLEMENTS=<path> opts in to an entitlement file. It is empty by default
# and that default is measured, not cautious: applying
# com.apple.developer.networking.wifi-info without an embedded provisioning
# profile that authorizes it makes macOS SIGKILL the app at launch (exit 137,
# observed on macOS 15.7.5). Reaching unredacted SSIDs requires an App ID with
# the Wi-Fi Information capability, a development profile for it, and then
# ENTITLEMENTS=scripts/wifind.entitlements.
#
# The private key never leaves the keychain. codesign asks the keychain for the
# signature; this script never reads, prints, or copies key material, and the
# signing identity is used by SHA-1 hash so no personal name is baked in.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
binary="$root/.build/release/wifind"
app="$root/Wifind.app"
entitlements="${ENTITLEMENTS-}"

# Prints the SHA-1 of the preferred signing identity, or nothing. Developer ID
# Application wins, then Apple Development, then whatever is listed first.
detect_identity() {
    local table hash
    table="$(security find-identity -v -p codesigning 2>/dev/null | awk '
        /^ *[0-9]+\)/ {
            h = $2
            if (length(h) == 40) {
                n = $0
                sub(/^[^"]*"/, "", n)
                sub(/".*$/, "", n)
                print h "\t" n
            }
        }')" || return 0
    [[ -n "$table" ]] || return 0
    hash="$(printf '%s\n' "$table" | grep -i 'developer id application' | head -1 | cut -f1 || true)"
    [[ -n "$hash" ]] || hash="$(printf '%s\n' "$table" | grep -i 'apple development' | head -1 | cut -f1 || true)"
    [[ -n "$hash" ]] || hash="$(printf '%s\n' "$table" | head -1 | cut -f1 || true)"
    [[ -n "$hash" ]] && printf '%s\n' "$hash"
}

identity="${SIGN_IDENTITY-}"
if [[ -z "$identity" ]]; then
    identity="$(detect_identity)"
fi
if [[ -z "$identity" ]]; then
    identity="-"
fi

if [[ ! -x "$binary" ]]; then
    echo "make-app: $binary is missing; run 'make build' first" >&2
    exit 1
fi

rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$binary" "$app/Contents/MacOS/wifind"
cp "$root/scripts/Info.plist" "$app/Contents/Info.plist"
printf 'APPL????' > "$app/Contents/PkgInfo"

if command -v codesign >/dev/null 2>&1; then
    sign_args=(--force --sign "$identity" --timestamp=none)
    applied="none"
    if [[ "$identity" != "-" && -n "$entitlements" && -f "$entitlements" ]]; then
        if [[ -f "$app/Contents/embedded.provisionprofile" ]]; then
            sign_args+=(--entitlements "$entitlements")
            applied="$entitlements"
        else
            echo "warning: $entitlements requested but the bundle has no" >&2
            echo "         embedded.provisionprofile; skipping it because macOS" >&2
            echo "         kills the app at launch without the matching profile" >&2
        fi
    fi
    if codesign "${sign_args[@]}" "$app" >/dev/null 2>&1; then
        if [[ "$identity" == "-" ]]; then
            echo "signed ad-hoc"
        else
            echo "signed with $identity"
        fi
        echo "entitlements: $applied"
    else
        echo "warning: codesign failed for identity '$identity'; leaving the bundle unsigned" >&2
        echo "         pass SIGN_IDENTITY=- to force ad-hoc signing" >&2
    fi
fi

cat <<EOF
built $app

run it from a terminal:
  $app/Contents/MacOS/wifind

the first scan triggers a Location Services prompt for "wifind"; after
allowing it, the same binary inside the bundle can read SSIDs (and BSSIDs when
macOS permits it). run 'wifind doctor' to see exactly what is visible.
EOF
