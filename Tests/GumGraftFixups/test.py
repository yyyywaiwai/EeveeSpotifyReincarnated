import importlib.util
from pathlib import Path
import struct


module_path = Path(__file__).resolve().parents[2] / "Tools/repair-gum-graft-fixups.py"
spec = importlib.util.spec_from_file_location("repair_gum_graft_fixups", module_path)
repair = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(repair)


def fixture() -> bytes:
    file_size = 0x78100
    image = bytearray(file_size)
    segments = [
        (b"__PAGEZERO", 0, 0x100000000, 0, 0),
        (b"__TEXT", 0x100000000, 0x1000, 0, 0x1000),
        (b"__DATA_CONST", 0x100001000, 0x1000, 0x1000, 0x1000),
        (b"__DATA", 0x100002000, 0x1000, 0x2000, 0x1000),
        (b"__FRIDA_TEXT0", 0x100003000, 0x1000, 0x3000, 0x1000),
        (b"__FRIDA_DATA0", 0x100004000, 0x1000, 0x4000, 0x1000),
        (b"__LINKEDIT", 0x100005000, 0x74000, 0x5000, file_size - 0x5000),
    ]
    commands = bytearray()
    for name, vmaddr, vmsize, fileoff, filesize in segments:
        commands.extend(struct.pack("<II16sQQQQiiII", 0x19, 72,
                                    name.ljust(16, b"\0"), vmaddr, vmsize,
                                    fileoff, filesize, 7, 5, 0, 0))
    commands.extend(struct.pack("<II16s", 0x1B, 24, repair.UUID))
    commands.extend(struct.pack("<IIIIII", 0x2C, 24, 0x500, 0x100, 0, 0))
    commands.extend(struct.pack("<IIII", 0x80000034, 16, 0x5000, 0x726F8))
    commands.extend(struct.pack("<IIII", 0x1D, 16, 0x78000, 0x100))
    struct.pack_into("<IiiIIIII", image, 0, 0xFEEDFACF, 0x100000C, 0,
                     2, len(segments) + 4, len(commands), 0, 0)
    image[32:32 + len(commands)] = commands
    for callsite, branch, before, after in zip(
            (0x400, 0x420), repair.GRAFTED_BRANCHES,
            repair.SITE_CONTEXT_BEFORE, repair.SITE_CONTEXT_AFTER):
        image[callsite - len(before):callsite] = before
        image[callsite:callsite + 4] = branch
        image[callsite + 4:callsite + 4 + len(after)] = after
    struct.pack_into("<7I", image, 0x5000, 0, 0x20, 0xCEC, 0x9BA4, 0x23AE, 1, 0)
    struct.pack_into("<I5I", image, 0x5020, 5, 0, 0, 0x18, 0x4F8, 0)
    image[0x78000:] = b"S" * 0x100
    return bytes(image)


original = fixture()
repaired = repair.repair_macho(original, callsites=(0x400, 0x420))
assert len(repaired) == len(original) + 0x72700
for callsite, branch in zip((0x400, 0x420), repair.GRAFTED_BRANCHES):
    assert original[callsite:callsite + 4] == repaired[callsite:callsite + 4] == branch
segments, commands, _ = repair.read_commands(repaired)
fix_offset, fix_size = struct.unpack_from("<II", repaired, commands[0x80000034] + 8)
sig_offset, sig_size = struct.unpack_from("<II", repaired, commands[0x1D] + 8)
assert (fix_offset, fix_size, sig_offset, sig_size) == (0x78000, 0x72700, 0xEA700, 0x100)
assert struct.unpack_from("<7I", repaired, fix_offset) == (0, 0x20, 0xCF4, 0x9BAC, 0x23AE, 1, 0)
assert struct.unpack_from("<I7I", repaired, fix_offset + 0x20) == (7, 0, 0, 0x20, 0x500, 0, 0, 0)
assert struct.unpack_from("<Q", repaired, segments[-1][1] + 48)[0] == len(repaired) - 0x5000

for offset, value in (
    (commands[0x1B] + 8, b"\0" * 16),
    (commands[0x2C] + 16, b"\1\0\0\0"),
    (0x400, b"\0\0\0\0"),
    (0x420, b"\0\0\0\0"),
    (0x41C, b"\0\0\0\0"),
    (0x5020, b"\7\0\0\0"),
):
    bad = bytearray(original)
    bad[offset:offset + len(value)] = value
    try:
        repair.repair_macho(bad, callsites=(0x400, 0x420))
    except repair.RepairError:
        pass
    else:
        raise AssertionError(f"unsafe image accepted at offset {offset:#x}")

print("Gum-graft fixups repair tests passed")
