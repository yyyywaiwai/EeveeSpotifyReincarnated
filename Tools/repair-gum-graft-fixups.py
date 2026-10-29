#!/usr/bin/env python3
"""Repair Spotify 9.1.88 chained-fixup segment starts after gum-graft.

Usage: repair-gum-graft-fixups.py GRAFTED_SPOTIFY OUTPUT_SPOTIFY
The input remains untouched; the output must not already exist. Sign the
result as part of the containing IPA after all Mach-O edits are complete.
"""

import argparse
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys
import tempfile


class RepairError(ValueError):
    pass


UUID = bytes.fromhex("f51dbd933b8f3a12943196c606e3afc2")
CALLSITE_FILE_OFFSETS = (0x865F148, 0x698C34C)
# gum-graft 17.24.3 emits these branches when both -i offsets are supplied.
GRAFTED_BRANCHES = (bytes.fromhex("b9638615"), bytes.fromhex("2daff915"))
SITE_CONTEXT_BEFORE = (
    bytes.fromhex("80e20191e10313aa"),
    bytes.fromhex("e20315aae30314aa44008052"),
)
SITE_CONTEXT_AFTER = (bytes.fromhex("914f6294"), bytes.fromhex("bf831838"))
SEGMENTS = (
    b"__PAGEZERO", b"__TEXT", b"__DATA_CONST", b"__DATA",
    b"__FRIDA_TEXT0", b"__FRIDA_DATA0", b"__LINKEDIT",
)


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RepairError(message)


def read_commands(data: bytes) -> tuple[list[tuple[bytes, int]], dict[int, int], int]:
    require(len(data) >= 32, "short Mach-O header")
    magic, cpu, _, kind, count, size, _, _ = struct.unpack_from("<IiiIIIII", data)
    require((magic, cpu, kind) == (0xFEEDFACF, 0x100000C, 2),
            "expected iOS arm64 MH_EXECUTE")
    require(32 + size <= len(data), "load commands extend past file")
    offset = 32
    segments: list[tuple[bytes, int]] = []
    commands: dict[int, int] = {}
    for _ in range(count):
        require(offset + 8 <= 32 + size, "truncated load command")
        command, command_size = struct.unpack_from("<II", data, offset)
        require(command_size >= 8 and offset + command_size <= 32 + size,
                "invalid load command size")
        if command == 0x19:
            require(command_size >= 72, "short segment command")
            segments.append((data[offset + 8:offset + 24].split(b"\0", 1)[0], offset))
        if command in (0x1B, 0x2C, 0x80000034, 0x1D):
            require(command_size >= {0x1B: 24, 0x2C: 24,
                                     0x80000034: 16, 0x1D: 16}[command],
                    "short required load command")
            require(command not in commands, "duplicate required load command")
            commands[command] = offset
        offset += command_size
    require(offset == 32 + size, "load command size mismatch")
    require(tuple(name for name, _ in segments) == SEGMENTS,
            "expected Spotify 9.1.88 gum-graft segment layout")
    require(all(command in commands for command in (0x1B, 0x2C, 0x80000034, 0x1D)),
            "required UUID, encryption, fixups, or signature command missing")
    return segments, commands, size


def repair_macho(data: bytes, *, callsites: tuple[int, int] = CALLSITE_FILE_OFFSETS) -> bytes:
    segments, commands, _ = read_commands(data)
    uuid_command = commands[0x1B]
    require(data[uuid_command + 8:uuid_command + 24] == UUID,
            "Spotify executable UUID differs from 9.1.88 target")
    encryption = commands[0x2C]
    require(struct.unpack_from("<I", data, encryption + 16)[0] == 0,
            "executable still has cryptid != 0")

    text_segment = segments[1][1]
    text_vmaddr, _, text_fileoff, text_filesize = struct.unpack_from("<QQQQ", data, text_segment + 24)
    require(text_vmaddr == 0x100000000 and text_fileoff == 0,
            "unexpected __TEXT mapping")
    require(len(callsites) == 2, "expected two graft call sites")
    for callsite, branch, before, after in zip(
            callsites, GRAFTED_BRANCHES, SITE_CONTEXT_BEFORE, SITE_CONTEXT_AFTER):
        require(callsite >= len(before) and
                callsite + 4 + len(after) <= text_filesize and
                callsite + 4 + len(after) <= len(data),
                "call-site offset is not in the expected __TEXT mapping")
        require(data[callsite:callsite + 4] == branch,
                "expected gum-graft call-site branch is absent")
        require(data[callsite - len(before):callsite] == before and
                data[callsite + 4:callsite + 4 + len(after)] == after,
                "Spotify call-site context differs")

    fixups_command = commands[0x80000034]
    old_offset, old_size = struct.unpack_from("<II", data, fixups_command + 8)
    require(old_size == 0x726F8 and old_offset + old_size <= len(data),
            "unexpected chained-fixups blob")
    fixups = data[old_offset:old_offset + old_size]
    version, starts, imports, symbols, import_count, import_format, symbol_format = struct.unpack_from(
        "<7I", fixups
    )
    require((version, starts, imports, symbols, import_count, import_format, symbol_format) ==
            (0, 0x20, 0xCEC, 0x9BA4, 0x23AE, 1, 0),
            "unexpected chained-fixups header")
    require(struct.unpack_from("<I", fixups, starts)[0] == 5,
            "chained-fixups segment table is not the original five-entry form")
    old_entries = struct.unpack_from("<5I", fixups, starts + 4)
    require(old_entries == (0, 0, 0x18, 0x4F8, 0),
            "unexpected chained-fixups segment starts")

    # shortcut: this exact 9.1.88 layout has no fixups in the new Frida segments;
    # revisit when changing the Spotify binary or gum-graft version.
    new_entries = (0, 0, 0x20, 0x500, 0, 0, 0)
    replacement = bytearray(
        fixups[:starts + 4] + struct.pack("<7I", *new_entries) + fixups[starts + 24:]
    )
    struct.pack_into("<I", replacement, starts, 7)
    struct.pack_into("<I", replacement, 8, imports + 8)
    struct.pack_into("<I", replacement, 12, symbols + 8)
    require(len(replacement) == old_size + 8 and len(replacement) % 16 == 0,
            "replacement fixups alignment mismatch")

    signature_command = commands[0x1D]
    signature_offset, signature_size = struct.unpack_from("<II", data, signature_command + 8)
    require(signature_size > 0 and signature_offset + signature_size == len(data),
            "code signature is not terminal")
    linkedit_segment = segments[-1][1]
    link_vmaddr, _, link_fileoff, link_filesize = struct.unpack_from(
        "<QQQQ", data, linkedit_segment + 24
    )
    require(link_fileoff + link_filesize == len(data) and
            link_fileoff <= old_offset < old_offset + old_size <= signature_offset,
            "unexpected __LINKEDIT bounds")

    output = bytearray(data[:signature_offset] + replacement + data[signature_offset:])
    struct.pack_into("<II", output, fixups_command + 8, signature_offset, len(replacement))
    struct.pack_into("<II", output, signature_command + 8,
                     signature_offset + len(replacement), signature_size)
    new_filesize = link_filesize + len(replacement)
    new_vmsize = (new_filesize + 0x3FFF) & ~0x3FFF
    struct.pack_into("<QQQQ", output, linkedit_segment + 24,
                     link_vmaddr, new_vmsize, link_fileoff, new_filesize)
    require(all(output[callsite:callsite + 4] == branch for callsite, branch in
                zip(callsites, GRAFTED_BRANCHES)) and
            link_fileoff + new_filesize == len(output), "repaired image bounds mismatch")
    require(struct.unpack_from("<I", output, signature_offset + starts)[0] == 7,
            "repaired segment count mismatch")
    return bytes(output)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("grafted_spotify", type=Path)
    parser.add_argument("output_spotify", type=Path)
    args = parser.parse_args()
    source, output = args.grafted_spotify, args.output_spotify
    temporary: Path | None = None
    try:
        require(source.is_file(), "input file missing")
        require(source.resolve() != output.resolve(), "input and output must differ")
        require(not output.exists(), "output already exists")
        repaired = repair_macho(source.read_bytes())
        with tempfile.NamedTemporaryFile(prefix=f".{output.name}.", suffix=".tmp",
                                         dir=output.parent, delete=False) as handle:
            temporary = Path(handle.name)
            handle.write(repaired)
        os.chmod(temporary, stat.S_IMODE(source.stat().st_mode))
        check = subprocess.run(["xcrun", "dyld_info", "-validate_only", str(temporary)],
                               text=True, capture_output=True, check=False)
        require(check.returncode == 0,
                "dyld_info rejected repaired binary: " + (check.stderr or check.stdout).strip())
        os.link(temporary, output)  # Exclusive; another process's output is never replaced.
        print(output)
        return 0
    except (OSError, RepairError) as error:
        print(f"fixups repair: {error}", file=sys.stderr)
        return 1
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    raise SystemExit(main())
