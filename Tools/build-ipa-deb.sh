#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${THEOS:?THEOS must point to the Theos checkout}"
GUM_DEVKIT="$(bash Tools/fetch-frida-gum-devkit.sh)"

# Separate outputs keep the jailbroken Substrate deb untouched.
IPA_MAKE=(THEOS_PACKAGE_SCHEME=rootless ORION_DEFAULT_BACKEND=Internal \
          FRIDA_GUM_DEVKIT_DIR="$GUM_DEVKIT" \
          THEOS_OBJ_DIR_NAME=obj-ipa THEOS_STAGING_DIR_NAME=_.ipa \
          THEOS_PACKAGE_DIR_NAME=packages/ipa)
make clean "${IPA_MAKE[@]}"
make package FINALPACKAGE=1 "${IPA_MAKE[@]}"
VERSION=$(awk '$1 == "Version:" { print $2; exit }' control)
DEB_FILE="packages/ipa/com.eevee.spotify_${VERSION}_iphoneos-arm64.deb"
[ -s "$DEB_FILE" ] || { echo "IPA tweak deb missing" >&2; exit 1; }
printf '%s\n' "$DEB_FILE"
