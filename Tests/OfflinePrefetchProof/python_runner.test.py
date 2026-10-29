import contextlib
import importlib.util
import io
from pathlib import Path
import sys
from types import SimpleNamespace
from unittest.mock import patch

import frida_tools


ROOT = Path(__file__).resolve().parents[2]
RUNNER = ROOT / "Scripts/run-offline-prefetch-proof.py"
PROBE = ROOT / "Scripts/offline-prefetch-proof.js"
spec = importlib.util.spec_from_file_location("proof_runner", RUNNER)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class FakeScript:
    def __init__(self):
        self.callback = None
        self.unloaded = False

    def on(self, name, callback):
        assert name == "message"
        self.callback = callback

    def load(self):
        self.callback({"type": "log", "payload": "ignored bridge log"}, None)
        self.callback({"type": "send", "payload": 1}, None)
        self.callback({"type": "send", "payload": 2}, None)

    def unload(self):
        self.unloaded = True


class FakeSession:
    def __init__(self):
        self.script = FakeScript()
        self.source = None
        self.detached = False
        self.detached_callback = None

    def on(self, name, callback):
        assert name == "detached"
        self.detached_callback = callback

    def create_script(self, source):
        self.source = source
        return self.script

    def detach(self):
        self.detached = True
        self.detached_callback("application-requested")


session = FakeSession()


class FakeDevice:
    def enumerate_processes(self):
        return [SimpleNamespace(name="Spotify", pid=123)]

    def attach(self, pid):
        assert pid == 123
        return session


class FakeManager:
    def add_remote_device(self, remote):
        assert remote == "127.0.0.1:27042"
        return FakeDevice()


fake_frida = SimpleNamespace(get_device_manager=lambda: FakeManager())
output = io.StringIO()
with patch.dict(sys.modules, {"frida": fake_frida}), contextlib.redirect_stdout(output):
    assert runner.main(["--run"]) == 0
assert output.getvalue() == "1\n2\n"
assert session.script.unloaded and session.detached
bridge = (Path(frida_tools.__file__).resolve().parent / "bridges/objc.js").read_text()
assert session.source == bridge + "\nglobalThis.ObjC=bridge;\n" + PROBE.read_text() + "\nstartProof();\n"

output = io.StringIO()
with contextlib.redirect_stdout(output):
    assert runner.main([]) == 2
assert output.getvalue() == "-120\n"

print("OfflinePrefetchProof Python runner tests passed")
