#!/usr/bin/env bash
# Local IPA build — mirror of .github/workflows/main.yml. Produces an IPA
# you can sign with Sideloadly/AltStore/TrollStore.
#
# Pipeline:
#   1. Build EeveeSwiftProtobuf.framework from apple/swift-protobuf source
#      (renamed module — see Tools/SwiftProtobufBuild/).
#   2. theos `make package FINALPACKAGE=1` with Orion's Internal backend —
#      produces a self-contained IPA tweak .deb, separate from the rootless deb.
#   3. Build zxPluginsInject.dylib — sideload compat shim (keychain redirect,
#      group containers, CloudKit stub). LC-injected via ipapatch in step 5.
#   4. Build and cyan-inject Orion.framework plus deb contents into vanilla IPA;
#      remove native extensions/Watch and keep the freshly built Orion runtime.
#   5. ipapatch LC-inject zxPluginsInject into the main executable.
#   6. Stage alternate app icons.
#   7. For Spotify 9.1.88, graft the PlayPlay key-call probe before signing.
#
# Requires: theos, cyan (pyzule-rw), ipapatch, dpkg, ldid, plutil.

set -euo pipefail

VANILLA_IPA="${1:-}"
[ -n "$VANILLA_IPA" ] && [ -f "$VANILLA_IPA" ] || {
    echo "usage: $0 <path/to/Spotify-vanilla.ipa>" >&2
    exit 1
}

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_DIR"

[ -n "${THEOS:-}" ] || { [ -d "$HOME/theos" ] && export THEOS="$HOME/theos" || { echo "THEOS not set"; exit 1; }; }

VERSION=$(grep -E '^Version:' control | awk '{print $2}')
SPOT_VERSION=$(unzip -p "$VANILLA_IPA" 'Payload/Spotify.app/Info.plist' \
    | plutil -extract CFBundleShortVersionString raw - 2>/dev/null || echo "unknown")
if [ "$SPOT_VERSION" = "9.1.88" ]; then
    # Reject the known cryptid-only parser copy before any build/output changes.
    bash Tools/graft-ipa-playplay.sh --check-input "$VANILLA_IPA"
fi
OUT_DIR="Outputs/IPAS"
OUT_IPA="$OUT_DIR/EeveeSpotify-${VERSION}-${SPOT_VERSION}.ipa"
mkdir -p "$OUT_DIR"
[ ! -e "$OUT_IPA" ] && [ ! -e "${OUT_IPA%.ipa}.orion-pinned.ipa" ] &&
[ ! -e "${OUT_IPA%.ipa}.grafted.ipa" ] || {
    echo "IPA output or staging path already exists" >&2
    exit 1
}

color() { printf '\033[1;32m==> %s\033[0m\n' "$*"; }

color "1/7  EeveeSwiftProtobuf.framework"
chmod +x Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh
Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh

color "2/7  theos make package (IPA/Internal backend)"
Tools/build-ipa-deb.sh
DEB_FILE="packages/ipa/com.eevee.spotify_${VERSION}_iphoneos-arm64.deb"
[ -s "$DEB_FILE" ] || { echo "IPA deb not produced" >&2; exit 1; }

color "3/7  zxPluginsInject.dylib"
chmod +x Tools/build-zxpi.sh
Tools/build-zxpi.sh >/dev/null

color "4/7  extract deb"
DEB_EXTRACT="$(mktemp -d "$REPO_DIR/Outputs/deb-extract.XXXXXXXX")"
trap 'rm -rf "$DEB_EXTRACT"' EXIT
dpkg-deb -R "$DEB_FILE" "$DEB_EXTRACT"
DYLIB_SRC=$(find "$DEB_EXTRACT" -name 'EeveeSpotify.dylib' | head -1)
BUNDLE_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSpotify.bundle' | head -1)
FRAMEWORK_SRC=$(find "$DEB_EXTRACT" -type d -name 'EeveeSwiftProtobuf.framework' | head -1)
[ -n "$DYLIB_SRC" ] || { echo "dylib not in deb"; exit 1; }
ORION_SRC="$(Tools/build-orion-ipa.sh)"
[ -s "$ORION_SRC/Orion" ] || { echo "Orion runtime not built" >&2; exit 1; }

color "5/7  cyan inject"
INJECT=("$DYLIB_SRC")
[ -n "$ORION_SRC" ]    && INJECT+=("$ORION_SRC")
[ -n "$FRAMEWORK_SRC" ] && INJECT+=("$FRAMEWORK_SRC")
[ -n "$BUNDLE_SRC" ]    && INJECT+=("$BUNDLE_SRC")
cyan -i "$VANILLA_IPA" -o "$OUT_IPA" -f "${INJECT[@]}" -c 9 -e -w
PINNED_IPA="${OUT_IPA%.ipa}.orion-pinned.ipa"
python3 Tools/pin-ipa-orion.py "$OUT_IPA" "$ORION_SRC" "$PINNED_IPA"
mv "$PINNED_IPA" "$OUT_IPA"

color "6/7  ipapatch LC-inject zxPluginsInject"
ipapatch --input "$OUT_IPA" --inplace --noconfirm --dylib packages/zxPluginsInject.dylib

color "7/7  stage alternate app icons"
# Copies Assets/AppIcon/*.png into Spotify.app and registers each stem under
# CFBundleIcons/CFBundleAlternateIcons in its Info.plist, which is what
# EeveeAppIconPickerView enumerates at runtime. This is the same step the
# GitHub IPA workflows run (buildpatched/buildnopatch/build-and-release-yourself),
# so a locally built IPA ends up with the identical icon set.
chmod +x Tools/alt-icons.sh
Tools/alt-icons.sh "$OUT_IPA"

if [ "$SPOT_VERSION" = "9.1.88" ]; then
    color "PlayPlay call-site graft (Spotify 9.1.88)"
    GRAFTED_IPA="${OUT_IPA%.ipa}.grafted.ipa"
    if ! bash Tools/graft-ipa-playplay.sh "$OUT_IPA" "$GRAFTED_IPA"; then
        rm -f "$OUT_IPA" "$GRAFTED_IPA"
        exit 1
    fi
    mv -f "$GRAFTED_IPA" "$OUT_IPA"
else
    color "PlayPlay graft skipped for Spotify $SPOT_VERSION"
fi

color "Done"
ls -lh "$OUT_IPA"
echo "Sign with Sideloadly / AltStore / TrollStore."
