#!/usr/bin/env bash
# Add the 9.1.88 playback and prefetch key probes before signing.
set -euo pipefail

check_only=0
if [ "${1:-}" = --check-input ] && [ "$#" -eq 2 ]; then
    check_only=1
    shift
elif [ "${1:-}" = --help ] || [ "$#" -ne 2 ]; then
    echo "usage: $0 INPUT_IPA OUTPUT_IPA | --check-input INPUT_IPA" >&2
    [ "${1:-}" = --help ] && exit 0 || exit 2
fi
repo="$(cd "$(dirname "$0")/.." && pwd)"
input="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
if [ "$check_only" -eq 1 ]; then
    output_dir="${TMPDIR:-/tmp}"
    [ -f "$input" ] || { echo "graft IPA: input missing" >&2; exit 1; }
else
    output_dir="$(cd "$(dirname "$2")" && pwd)"
    output="$output_dir/$(basename "$2")"
    [ -f "$input" ] && [ ! -e "$output" ] && [ "$input" != "$output" ] || {
        echo "graft IPA: input missing or output already exists" >&2; exit 1;
    }
fi
work="$(mktemp -d "$output_dir/.playplay-graft.XXXXXXXX")"
trap 'rm -rf "$work"' EXIT

# Reject archive path traversal before unzip. The app executable itself must
# also be a regular, non-symlink file before mutation.
python3 - "$input" <<'PY'
import pathlib, stat, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    items = archive.infolist()
    if not items or any(pathlib.PurePosixPath(item.filename).is_absolute() or
                        '..' in pathlib.PurePosixPath(item.filename).parts or
                        '\\' in item.filename or
                        stat.S_ISLNK(item.external_attr >> 16) for item in items):
        raise SystemExit('graft IPA: unsafe archive path')
PY
mkdir "$work/extracted"
unzip -q "$input" -d "$work/extracted"
spotify="$work/extracted/Payload/Spotify.app/Spotify"
plist="$work/extracted/Payload/Spotify.app/Info.plist"
shared="$work/extracted/Payload/Spotify.app/Frameworks/SpotifyShared.framework/SpotifyShared"
[ -f "$spotify" ] && [ ! -L "$spotify" ] && [ -f "$plist" ] && [ -s "$shared" ] || {
    echo "graft IPA: Spotify executable, Info.plist, or SpotifyShared runtime missing" >&2; exit 1;
}

python3 - "$spotify" "$plist" <<'PY'
import hashlib, pathlib, plistlib, struct, sys
executable, plist = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads(plist.read_bytes())
if info.get('CFBundleIdentifier') != 'com.spotify.client':
    raise SystemExit('graft IPA: expected com.spotify.client bundle')
if (info.get('CFBundleShortVersionString'), str(info.get('CFBundleVersion'))) != ('9.1.88', '918802209'):
    raise SystemExit('graft IPA: expected Spotify 9.1.88 (918802209)')
with executable.open('rb') as file:
    header = file.read(32)
    if len(header) != 32:
        raise SystemExit('graft IPA: expected arm64 Mach-O executable')
    magic, cpu, _, kind, count, size, _, _ = struct.unpack('<IiiIIIII', header)
    if (magic, cpu, kind) != (0xFEEDFACF, 0x100000C, 2) or size > 1_048_576:
        raise SystemExit('graft IPA: unsupported Mach-O header')
    commands = file.read(size)
    if len(commands) != size:
        raise SystemExit('graft IPA: truncated load commands')
    offset = 0
    segments = []
    uuid = None
    cryptid = None
    for _ in range(count):
        if offset + 8 > size:
            raise SystemExit('graft IPA: invalid load commands')
        command, length = struct.unpack_from('<II', commands, offset)
        if length < 8 or offset + length > size:
            raise SystemExit('graft IPA: invalid load command size')
        if command == 0x19:
            segments.append(commands[offset + 8:offset + 24].split(b'\0', 1)[0])
            if segments[-1] == b'__TEXT':
                vmaddr, _, fileoff, _ = struct.unpack_from('<QQQQ', commands, offset + 24)
                if (vmaddr, fileoff) != (0x100000000, 0):
                    raise SystemExit('graft IPA: unexpected __TEXT mapping')
        elif command == 0x1B:
            uuid = commands[offset + 8:offset + 24]
        elif command == 0x2C:
            cryptid = struct.unpack_from('<I', commands, offset + 16)[0]
        offset += length
    if offset != size or segments != [b'__PAGEZERO', b'__TEXT', b'__DATA_CONST', b'__DATA', b'__LINKEDIT']:
        raise SystemExit('graft IPA: unexpected segment layout')
    if uuid != bytes.fromhex('f51dbd933b8f3a12943196c606e3afc2') or cryptid != 0:
        raise SystemExit('graft IPA: wrong UUID or executable still encrypted')
    # A parser copy of the on-disk FairPlay image has only cryptid flipped to 0.
    # Its encrypted 4 KiB page must not be mistaken for a decrypted executable.
    file.seek(0x50000)
    page = file.read(0x1000)
    if len(page) != 0x1000 or hashlib.sha256(page).hexdigest() == 'fb7a5182219994afd76cf83baf72181a7d9e2ee0eee58af48cf2aacae2e7a16b':
        raise SystemExit('graft IPA: known encrypted FairPlay page or truncated executable')
    file.seek(0x865F148 - 8)
    if file.read(16) != bytes.fromhex('80e20191e10313aa147f5697914f6294'):
        raise SystemExit('graft IPA: unexpected key-setter call site')
    file.seek(0x698C34C - 12)
    if file.read(20) != bytes.fromhex('e20315aae30314aa4400805275976e94bf831838'):
        raise SystemExit('graft IPA: unexpected prefetch cache call site')
PY
if [ "$check_only" -eq 1 ]; then
    echo "graft IPA: input preflight passed"
    exit 0
fi

case "$(uname -m)" in
    arm64)
        arch=arm64
        archive_sha=a5936b11adf2247c770e22fe0809d9b053e2169ca4011071ed73a4c40f4e0807
        tool_sha=74f0a95cb283e10ab46e396605d04eb03f04152beca2391c18f6c38974b58b01
        ;;
    x86_64)
        arch=x86_64
        archive_sha=e7ff2824ab6b6351a1d10ac6c2d8a011fa564621d4656a8c9a0b021e3dee6aad
        tool_sha=6feb60fcbd4ad447540afc0136378d0f6271f857f8f698911d548ef49d9b5ab4
        ;;
    *) echo "graft IPA: unsupported host architecture" >&2; exit 1 ;;
esac
tool_dir="$repo/Outputs/dependencies/gum-graft-17.24.3-macos-$arch"
tool="$tool_dir/gum-graft"
mkdir -p "$tool_dir"
if [ ! -f "$tool" ]; then
    archive="$tool_dir/gum-graft-17.24.3-macos-$arch.xz"
    if [ ! -f "$archive" ]; then
        curl -fLsS --retry 3 \
            "https://github.com/frida/frida/releases/download/17.24.3/gum-graft-17.24.3-macos-$arch.xz" \
            -o "$archive.tmp"
        mv "$archive.tmp" "$archive"
    fi
    printf '%s  %s\n' "$archive_sha" "$archive" | shasum -a 256 -c - >/dev/null
    xz -dc "$archive" > "$tool.tmp"
    printf '%s  %s\n' "$tool_sha" "$tool.tmp" | shasum -a 256 -c - >/dev/null
    chmod +x "$tool.tmp"
    mv "$tool.tmp" "$tool"
fi
printf '%s  %s\n' "$tool_sha" "$tool" | shasum -a 256 -c - >/dev/null

"$tool" -i 0x865F148 -i 0x698C34C "$spotify"
python3 "$repo/Tools/repair-gum-graft-fixups.py" "$spotify" "$spotify.repaired"
mv "$spotify.repaired" "$spotify"
xcrun dyld_info -validate_only "$spotify" >/dev/null
cp "$repo/docs/third-party/Frida-Gum-COPYING" \
    "$work/extracted/Payload/Spotify.app/Frida-Gum-COPYING.txt"

archive="$work/result.ipa"
(
    cd "$work/extracted"
    shopt -s nullglob dotglob
    entries=(*)
    [ "${#entries[@]}" -gt 0 ] || exit 1
    zip -qry "$archive" "${entries[@]}"
)
unzip -tq "$archive" >/dev/null
cmp "$spotify" <(unzip -p "$archive" Payload/Spotify.app/Spotify) >/dev/null
cmp "$repo/docs/third-party/Frida-Gum-COPYING" \
    <(unzip -p "$archive" Payload/Spotify.app/Frida-Gum-COPYING.txt) >/dev/null
ln "$archive" "$output"  # Exclusive publication; an existing output is never replaced.
printf '%s\n' "$output"
