#!/usr/bin/env bash
# Build a self-contained Orion runtime for IPA injection; Theos ships only its link stub.
set -euo pipefail

: "${THEOS:?THEOS must point to the Theos checkout}"
SOURCE="$THEOS/vendor/orion"
[ -f "$SOURCE/Orion.xcodeproj/project.pbxproj" ] || { echo "Orion source missing: $SOURCE" >&2; exit 1; }

TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
mkdir -p "$TEMP/orion"
rsync -a --exclude .git --exclude .theos --exclude .theos_build --exclude packages \
  --exclude .build "$SOURCE/" "$TEMP/orion/"

# Xcode 26 ExtractAPI reads the source header before Orion's copy phase runs.
cp "$TEMP/orion/Orion/Orion-Target-iphoneos.h" "$TEMP/orion/Orion/Orion-Target.h"
make -C "$TEMP/orion" package THEOS_PACKAGE_SCHEME=rootless ARCHS=arm64 \
  Orion_XCODEFLAGS='IPHONEOS_DEPLOYMENT_TARGET=15.0' >/dev/null

PACKAGE="$(find "$TEMP/orion/packages" -maxdepth 1 -name 'dev.theos.orion*.deb' -print -quit)"
[ -n "$PACKAGE" ] || { echo "Orion package missing" >&2; exit 1; }
dpkg-deb -x "$PACKAGE" "$TEMP/extracted"
FRAMEWORK="$TEMP/extracted/var/jb/Library/Frameworks/Orion.framework"
[ -s "$FRAMEWORK/Orion" ] || { echo "Orion runtime missing" >&2; exit 1; }

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEST="$REPO/Outputs/ipa-runtime/Orion.framework"
mkdir -p "$(dirname "$DEST")"
rm -rf "$DEST"
cp -R "$FRAMEWORK" "$DEST"
printf '%s\n' "$DEST"
