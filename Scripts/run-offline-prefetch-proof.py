#!/usr/bin/env python3
"""Run the fixed one-shot proof with Frida's packaged ObjC bridge."""

import argparse
from pathlib import Path
from threading import Event, Lock


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run", action="store_true", help="attach to foreground Spotify")
    parser.add_argument("--remote", default="127.0.0.1:27042")
    args = parser.parse_args(argv)
    if not args.run:
        print(-120)
        return 2

    try:
        import frida
        import frida_tools
        bridge = (Path(frida_tools.__file__).resolve().parent / "bridges/objc.js").read_text()
        probe = Path(__file__).with_name("offline-prefetch-proof.js").read_text()
        source = bridge + "\nglobalThis.ObjC=bridge;\n" + probe + "\nstartProof();\n"
    except Exception:
        print(-110)
        return 1
    done = Event()
    lock = Lock()
    result = {"code": None}
    session = None
    script = None

    def report(code):
        with lock:
            if done.is_set():
                return
            print(code, flush=True)
            result["code"] = code
            if code != 1:
                done.set()

    def on_message(message, _data):
        if message.get("type") == "send":
            payload = message.get("payload")
            report(payload if type(payload) is int else -113)
        elif message.get("type") == "error":
            report(-114)

    def on_detached(*_):
        if result["code"] != 2:
            report(-116)

    try:
        device = frida.get_device_manager().add_remote_device(args.remote)
        process = next(p for p in device.enumerate_processes() if p.name == "Spotify")
        session = device.attach(process.pid)
        session.on("detached", on_detached)
        script = session.create_script(source)
        script.on("message", on_message)
        script.load()
        if not done.wait(365):
            report(-115)
        return 0 if result["code"] == 2 else 1
    except Exception:
        report(-110)
        return 1
    finally:
        if script is not None:
            try:
                script.unload()
            except Exception:
                pass
        if session is not None:
            try:
                session.detach()
            except Exception:
                pass


if __name__ == "__main__":
    raise SystemExit(main())
