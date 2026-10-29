"""Host-only regression for the cryptid-only Spotify 9.1.88 parser copy.

The historical parser-copy fixture is intentionally not a decrypted IPA. The
test uses a temporary archive and never invokes the actual IPA build.
"""

from pathlib import Path
import hashlib
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import zipfile


ROOT = Path(__file__).resolve().parents[2]
GRAFT = ROOT / "Tools/graft-ipa-playplay.sh"
BUILD = ROOT / "build-ipa-local.sh"
FIXTURE = ROOT / "Outputs/work/playplay-offline-20261026/nonjb-graft-research/structural-fixture.ipa"
SPOTIFY = "Payload/Spotify.app/Spotify"
PLIST = "Payload/Spotify.app/Info.plist"
SHARED = "Payload/Spotify.app/Frameworks/SpotifyShared.framework/SpotifyShared"
ENCRYPTED_PAGE_SHA256 = "fb7a5182219994afd76cf83baf72181a7d9e2ee0eee58af48cf2aacae2e7a16b"


@unittest.skipUnless(FIXTURE.is_file(), "local parser-copy fixture not present")
class IPAInputGuardTests(unittest.TestCase):
    def make_complete_looking_fixture(self, output: Path, replace_page: bool) -> None:
        with zipfile.ZipFile(FIXTURE) as source, zipfile.ZipFile(
            output, "w", compression=zipfile.ZIP_STORED
        ) as destination:
            info = plistlib.loads(source.read(PLIST))
            info["CFBundleIdentifier"] = "com.spotify.client"
            destination.writestr(PLIST, plistlib.dumps(info))
            destination.writestr(SHARED, b"fixture-only runtime placeholder")
            with source.open(SPOTIFY) as original, destination.open(
                SPOTIFY, "w", force_zip64=True
            ) as copied:
                if replace_page:
                    copied.write(original.read(0x50000))
                    original.read(0x1000)
                    copied.write(bytes.fromhex("1f2003d5") * 1024)  # ARM64 NOP; not a real decryption.
                shutil.copyfileobj(original, copied, length=1024 * 1024)

    def test_structural_fixture_rejected_without_output(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "grafted.ipa"
            result = subprocess.run(
                ["bash", str(GRAFT), str(FIXTURE), str(output)],
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("SpotifyShared runtime missing", result.stderr)
            self.assertFalse(output.exists())

    def test_known_ciphertext_rejected_even_with_complete_looking_bundle(self):
        with tempfile.TemporaryDirectory() as tmp:
            candidate = Path(tmp) / "cryptid-only.ipa"
            self.make_complete_looking_fixture(candidate, replace_page=False)

            with zipfile.ZipFile(candidate) as archive, archive.open(SPOTIFY) as image:
                image.read(0x50000)
                self.assertEqual(
                    hashlib.sha256(image.read(0x1000)).hexdigest(),
                    ENCRYPTED_PAGE_SHA256,
                )

            result = subprocess.run(
                ["bash", str(GRAFT), "--check-input", str(candidate)],
                capture_output=True, text=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("known encrypted FairPlay page", result.stderr)

            # The expensive build must call this preflight before creating an
            # output directory or compiling its first dependency.
            script = BUILD.read_text()
            preflight = script.index("bash Tools/graft-ipa-playplay.sh --check-input")
            self.assertLess(preflight, script.index('mkdir -p "$OUT_DIR"'))
            self.assertLess(preflight, script.index("Tools/SwiftProtobufBuild/build-eeveeswiftprotobuf.sh\n"))

    def test_changed_page_passes_structural_preflight_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            candidate = Path(tmp) / "synthetic-page.ipa"
            self.make_complete_looking_fixture(candidate, replace_page=True)
            result = subprocess.run(
                ["bash", str(GRAFT), "--check-input", str(candidate)],
                capture_output=True, text=True, check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertIn("input preflight passed", result.stdout)


if __name__ == "__main__":
    unittest.main()
