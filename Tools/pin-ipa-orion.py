#!/usr/bin/env python3
"""Keep the freshly built Orion runtime when cyan substitutes its bundled copy."""

import os
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import stat
import sys
import tempfile
import zipfile


def main() -> None:
    if len(sys.argv) != 4:
        raise SystemExit("usage: pin-ipa-orion.py INPUT_IPA ORION_FRAMEWORK OUTPUT_IPA")
    source, framework, output = (Path(arg).resolve() for arg in sys.argv[1:])
    binary = framework / "Orion"
    info = framework / "Info.plist"
    if (not source.is_file() or not binary.is_file() or not info.is_file() or
            not output.parent.is_dir() or output.exists() or source == output or
            plistlib.loads(info.read_bytes()).get("CFBundleExecutable") != "Orion"):
        raise SystemExit("pin IPA Orion: invalid input or existing output")
    replacements = {
        "Payload/Spotify.app/Frameworks/Orion.framework/Orion": binary.read_bytes(),
        "Payload/Spotify.app/Frameworks/Orion.framework/Info.plist": info.read_bytes(),
    }
    if not replacements[next(iter(replacements))].startswith(b"\xcf\xfa\xed\xfe"):
        raise SystemExit("pin IPA Orion: expected arm64 Mach-O")
    os.umask(0o077)
    with tempfile.NamedTemporaryFile(prefix=".orion-pinned-", suffix=".ipa",
                                     dir=output.parent, delete=False) as temporary:
        staged = Path(temporary.name)
    try:
        with zipfile.ZipFile(source) as original:
            entries = original.infolist()
            names = [entry.filename for entry in entries]
            if (len(names) != len(set(names)) or not set(replacements).issubset(names) or
                    any(PurePosixPath(name).is_absolute() or
                        ".." in PurePosixPath(name).parts or "\\" in name or
                        stat.S_ISLNK(entry.external_attr >> 16)
                        for name, entry in zip(names, entries))):
                raise SystemExit("pin IPA Orion: unsafe or incomplete archive")
            with zipfile.ZipFile(staged, "w") as result:
                for entry in entries:
                    if entry.filename in replacements:
                        result.writestr(entry, replacements[entry.filename])
                    elif entry.is_dir():
                        result.writestr(entry, b"")
                    else:
                        with original.open(entry) as src, result.open(entry, "w") as dst:
                            shutil.copyfileobj(src, dst, 1 << 20)
                result.comment = original.comment
        with zipfile.ZipFile(staged) as result:
            if result.testzip() is not None or any(
                    result.read(name) != data for name, data in replacements.items()):
                raise SystemExit("pin IPA Orion: output verification failed")
        os.link(staged, output)  # Exclusive publication; leave an existing output untouched.
    finally:
        staged.unlink(missing_ok=True)
    print(output)


if __name__ == "__main__":
    main()
