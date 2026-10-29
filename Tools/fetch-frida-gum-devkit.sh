#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# IPA-only native probe dependency; exact artifact and contents are pinned.
version=17.24.3
name="frida-gum-devkit-${version}-ios-arm64.tar.xz"
directory="$PWD/Outputs/dependencies/frida-gum-${version}-ios-arm64"
archive="$directory/$name"
mkdir -p "$directory"
if [ ! -f "$archive" ]; then
    curl -fL --retry 3 "https://github.com/frida/frida/releases/download/${version}/${name}" \
        -o "$archive.tmp"
    mv "$archive.tmp" "$archive"
fi
printf '%s  %s\n' \
    '5d1b4c9aad03a059e6154bbc773a612e5baff3f868e9263be6dd2af1b6761115' \
    "$archive" | shasum -a 256 -c - >/dev/null
tar -xJf "$archive" -C "$directory"
printf '%s  %s\n' \
    '880a66dff1fcb0da32cf08dd3bfd2514078f8826be9c1323b5a1735fd829d39f' \
    "$directory/libfrida-gum.a" | shasum -a 256 -c - >/dev/null
printf '%s  %s\n' \
    '022b32992ebd318e82429cbafcfc7167c3efe1b4a35255df264e04f73716da46' \
    "$directory/frida-gum.h" | shasum -a 256 -c - >/dev/null
printf '%s\n' "$directory"
