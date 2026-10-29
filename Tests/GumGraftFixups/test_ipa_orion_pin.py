import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[2] / "Tools/pin-ipa-orion.py"
REPO = SCRIPT.parents[1]
ORION = "Payload/Spotify.app/Frameworks/Orion.framework/"


class OrionPinTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.framework = self.root / "Orion.framework"
        self.framework.mkdir()
        (self.framework / "Orion").write_bytes(b"\xcf\xfa\xed\xfe" + b"new runtime")
        (self.framework / "Info.plist").write_bytes(
            plistlib.dumps({"CFBundleExecutable": "Orion", "CFBundleVersion": "1"}))
        self.source = self.root / "input.ipa"
        self.output = self.root / "output.ipa"

    def archive(self, extra=None):
        with zipfile.ZipFile(self.source, "w") as archive:
            archive.writestr("Payload/Spotify.app/Spotify", b"main unchanged")
            archive.writestr(ORION + "Orion", b"old runtime")
            archive.writestr(ORION + "Info.plist", b"old info")
            if extra:
                archive.writestr(extra, b"untrusted")

    def run_pin(self):
        return subprocess.run([sys.executable, str(SCRIPT), str(self.source),
                               str(self.framework), str(self.output)],
                              capture_output=True, text=True)

    def test_replaces_only_built_orion(self):
        self.archive()
        self.assertEqual(self.run_pin().returncode, 0)
        with zipfile.ZipFile(self.output) as result:
            self.assertIsNone(result.testzip())
            self.assertEqual(result.read("Payload/Spotify.app/Spotify"), b"main unchanged")
            self.assertEqual(result.read(ORION + "Orion"),
                             (self.framework / "Orion").read_bytes())
            self.assertEqual(result.read(ORION + "Info.plist"),
                             (self.framework / "Info.plist").read_bytes())
        self.assertEqual(os.stat(self.output).st_mode & 0o777, 0o600)

    def test_existing_output_is_not_replaced(self):
        self.archive()
        self.output.write_bytes(b"sentinel")
        self.assertNotEqual(self.run_pin().returncode, 0)
        self.assertEqual(self.output.read_bytes(), b"sentinel")

    def test_rejects_unsafe_member_without_output(self):
        self.archive("../escape")
        self.assertNotEqual(self.run_pin().returncode, 0)
        self.assertFalse(self.output.exists())

    def test_local_and_ci_builds_pin_runtime_and_strip_native_extensions(self):
        callers = [REPO / "build-ipa-local.sh", *(
            REPO / ".github/workflows" / name for name in
            ("buildpatched.yml", "buildnopatch.yml", "build-and-release-yourself.yml"))]
        for caller in callers:
            with self.subTest(caller=caller.name):
                source = caller.read_text()
                self.assertIn("-c 9 -e -w", source)
                self.assertIn("python3 Tools/pin-ipa-orion.py", source)
                self.assertNotIn("-m 15.0 -du", source)


if __name__ == "__main__":
    unittest.main()
