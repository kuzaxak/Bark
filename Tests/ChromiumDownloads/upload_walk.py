#!/usr/bin/env python3
"""Verify signed Bark's native file chooser and a disposable loopback upload."""

from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
from threading import Thread

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

TITLE = "Bark upload fixture"
NAME = "bark-synthetic-upload.txt"
PAYLOAD = b"A disposable Bark upload fixture.\n"
DIGEST = hashlib.sha256(PAYLOAD).hexdigest()
PAGE = f"""<!doctype html><meta charset="utf-8"><title>{TITLE}</title>
<button id="choose">Choose fixture file</button>
<input id="file" type="file" hidden>
<button id="upload">Upload selected file</button>
<label for="draft">Page input after file chooser</label><input id="draft">
<script>
const file = document.querySelector('#file');
const report = data => fetch('/event', {{method: 'POST', body: JSON.stringify(data)}});
document.querySelector('#choose').onclick = () => file.click();
file.addEventListener('cancel', () => report({{kind: 'cancel', count: file.files.length}}));
file.addEventListener('change', () => report({{kind: 'selected', name: file.files[0].name}}));
document.querySelector('#upload').onclick = () => {{
    if (file.files.length === 1) fetch('/upload', {{method: 'POST', body: file.files[0]}});
}};
document.querySelector('#draft').addEventListener('input',
    event => report({{kind: 'input', trusted: event.isTrusted, value: event.target.value}}));
report({{kind: 'ready'}});
</script>""".encode()


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path != "/source":
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(PAGE)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        if self.path not in ("/event", "/upload") or not 0 < length < 4096:
            self.send_error(400)
            return
        body = self.rfile.read(length)
        event = (json.loads(body) if self.path == "/event" else
                 {"kind": "upload", "bytes": len(body), "sha256": hashlib.sha256(body).hexdigest()})
        self.server.events.append(event)
        self.send_response(204)
        self.end_headers()


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.events = []
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def main():
    fixture = {}

    def prepare(root, _origin, _app, profile):
        directory = root / "upload-fixture"
        directory.mkdir(mode=0o700)
        path = directory / NAME
        path.write_bytes(PAYLOAD)
        preferences = root / "Engine" / f"Barc-{profile.lower()}" / "Preferences"
        preferences.parent.mkdir(parents=True)
        preferences.write_text(json.dumps({"selectfile": {"last_directory": str(directory)}}))
        fixture["file"] = path

    def exercise(screen, process, events, output):
        access = Accessibility(screen, process)
        screen.keys["g"] = 5

        def event(kind, **expected):
            return wait_for(f"Missing page event {kind}",
                            lambda: next((record for record in events if record.get("kind") == kind
                                          and all(record.get(k) == v for k, v in expected.items())), None), process)

        def click(label, role):
            node = access.control(label, (role,))
            x, y = access.center(node)
            bounds = screen.windows()[0]["kCGWindowBounds"]
            screen.click((x - bounds["X"], y - bounds["Y"]))

        def panel():
            # Chromium's native open panel belongs to the guarded Bark process.
            return access.find("Cancel", ("AXButton",))

        event("ready")
        wait_for("The loopback source window was not active", lambda: access.owner(TITLE), process)
        screen.guard()
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)

        click("Choose fixture file", "AXButton")
        access.press(wait_for("The file chooser did not open", panel, process))
        wait_for("The file chooser did not dismiss after Cancel", lambda: not panel(), process)
        event("cancel", count=0)
        if any(record.get("kind") in ("upload", "selected") for record in events):
            raise RuntimeError("The cancelled chooser selected or uploaded a file")

        click("Choose fixture file", "AXButton")
        wait_for("The file chooser did not reopen", panel, process)
        screen.key("g", screen.command | screen.shift)

        def folder_field():
            field = access.attribute(access.application, "AXFocusedUIElement")
            return field if access.attribute(field, "AXRole") in ("AXTextField", "AXComboBox") else None

        field = wait_for("The chooser did not open Go to Folder", folder_field, process)
        screen.guard()
        if access.ax.AXUIElementSetAttributeValue(field, "AXValue", str(fixture["file"])) != 0:
            screen.key(str(fixture["file"]), unicode=True)
        screen.key("Return")

        def selected_button():
            for name in ("Open", "Choose"):
                button = access.find(name, ("AXButton",))
                if button is not None and access.attribute(button, "AXEnabled"):
                    return button
            return None

        access.press(wait_for("File chooser did not enable its selection action", selected_button, process))
        event("selected", name=NAME)
        wait_for("File chooser did not close after selection", lambda: not panel(), process)
        click("Upload selected file", "AXButton")
        received = event("upload", bytes=len(PAYLOAD), sha256=DIGEST)
        click("Page input after file chooser", "AXTextField")
        screen.key("input retained", unicode=True)
        event("input", trusted=True, value="input retained")
        (output / "result.json").write_text(json.dumps({
            "cancelled_without_selection": True, "selected": NAME,
            "upload": received, "trusted_page_input_after_chooser": True,
        }, indent=2) + "\n")
        screen.key("q", screen.command)
        access.press(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))

    return run_walk(__doc__, "file-upload", serve, exercise, prepare_fixture=prepare,
                    official_qualification=True)


if __name__ == "__main__":
    sys.exit(main())
