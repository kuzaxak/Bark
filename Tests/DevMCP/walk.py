#!/usr/bin/env python3
"""Exercise signed Bark page diagnostics and BFCache requests with a disposable profile."""

from contextlib import contextmanager
from http.client import HTTPConnection
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import socket
import stat
import sys
from threading import Thread

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

TITLES = {"/source": "Bark diagnostic regular", "/private": "Bark diagnostic private"}
DRAFT = "retained draft"


class FixturePage(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        title = TITLES.get(self.path)
        if title is None:
            self.send_error(404)
            return
        body = f"""<!doctype html><meta charset="utf-8"><title>{title}</title>
<style>input {{ margin: 40px; width: 280px; height: 30px; }}</style>
<label for="draft">Diagnostic draft</label><input id="draft" autocomplete="off">
<script>
const id = crypto.randomUUID(), draft = document.querySelector('input');
const key = 'bark-disposable-devmcp';
if (location.pathname === '/source') localStorage.setItem(key, id);
function report(event, trusted) {{
    fetch('/event', {{method: 'POST', body: JSON.stringify({{
        page: location.pathname, event, trusted, id, value: draft.value, storage: localStorage.getItem(key)
    }})}}).catch(() => {{}});
}}
report('ready', false);
draft.addEventListener('input', e => report('input', e.isTrusted));
</script>""".encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if self.path != "/event":
            self.send_error(404)
            return
        event = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.server.events.append(event)
        self.send_response(204)
        self.end_headers()


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), FixturePage) as server:
        server.events = []
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


class Diagnostics:
    def __init__(self, port, token_path):
        fd = os.open(token_path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK)
        with os.fdopen(fd, "r") as stream:
            info = os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) != 0o600 or info.st_uid != os.getuid():
                raise RuntimeError("Unsafe disposable DevMCP token file")
            self.token = stream.read(1025).strip()
        if not 32 <= len(self.token) <= 1024 or not self.token.isascii() or not self.token.isprintable():
            raise RuntimeError("Malformed disposable DevMCP token")
        self.port = port
        self.sequence = 0
        self.session = None

    def request(self, method, params=None):
        self.sequence += 1
        connection = HTTPConnection("127.0.0.1", self.port, timeout=3)
        headers = {"Authorization": f"Bearer {self.token}", "Content-Type": "application/json"}
        if self.session:
            headers["Mcp-Session-Id"] = self.session
        try:
            body = json.dumps({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params or {}})
            connection.request("POST", "/mcp", body, headers)
            response = connection.getresponse()
            if response.status != 200:
                raise RuntimeError(f"DevMCP returned HTTP {response.status} for {method}")
            self.session = response.getheader("Mcp-Session-Id")
            message = json.loads(response.read())
        finally:
            connection.close()
        if message.get("id") != self.sequence or "result" not in message:
            raise RuntimeError(f"Unexpected DevMCP response for {method}")
        return message["result"]

    def tool(self, name, **arguments):
        result = self.request("tools/call", {"name": name, "arguments": arguments})
        if result.get("isError") or len(result.get("content", [])) != 1:
            raise RuntimeError(f"DevMCP could not run {name}")
        return result["content"][0]["text"]


def tab_inventory(root):
    folder = root / "App/Tabs"
    structure = json.loads((folder / "structure.json").read_text())
    device = json.loads((folder / "device.json").read_text())
    return (sorted(row["id"] for row in structure["spaces"]),
            sorted(row["id"] for tree in (structure, device) for row in tree["items"]))


def main():
    require_renderer = False
    fixture = {}
    with socket.socket() as probe:
        probe.bind(("127.0.0.1", 0))
        port = probe.getsockname()[1]

    def parse_options(parser):
        nonlocal require_renderer
        parser.add_argument("--require-renderer", action="store_true",
                            help="require PID and visibility from an SDK with renderer diagnostics")
        args = parser.parse_args()
        require_renderer = args.require_renderer
        return args

    def prepare(root, origin, _app, _profile):
        fixture.update(root=root, origin=origin, inventory=tab_inventory(root))

    def exercise(screen, process, events, output):
        access = Accessibility(screen, process)
        screen.keys.update({"a": 0, "l": 37, "n": 45})

        def front_page(path):
            window = access.attribute(access.application, "AXFocusedWindow")
            return window is not None and access.attribute(window, "AXTitle") == TITLES[path]

        def event(path, name, **expected):
            return wait_for(f"Missing {name} on {path}", lambda: next(
                (row for row in events if row["page"] == path and row["event"] == name
                 and all(row[key] == value for key, value in expected.items())), None), process)

        def fill_draft(text):
            window = access.attribute(access.application, "AXFocusedWindow")
            field = access.control("Diagnostic draft", ("AXTextField",), root=window)
            x, y = access.center(field)
            bounds = screen.windows()[0]["kCGWindowBounds"]
            screen.click((x - bounds["X"], y - bounds["Y"]))
            screen.key("a", screen.command)
            screen.key(text, unicode=True)

        def pages(*, regular_front):
            screen.guard()
            rows = json.loads(mcp.tool("pages"))
            if len(rows) != 1 or rows[0]["url"] != fixture["origin"] + "/source":
                raise RuntimeError("Diagnostics did not return exactly the existing regular fixture page")
            row = rows[0]
            if row.get("loaded") is not True or row.get("onScreen") is not True or row.get("inWindow") is not True:
                raise RuntimeError(f"Regular page lost its live window attachment: {row}")
            if require_renderer or "pid" in row or "visibility" in row:
                visibility = ("visible",) if regular_front else ("visible", "hidden")
                if type(row.get("pid")) is not int or row["pid"] <= 0 or row.get("visibility") not in visibility:
                    raise RuntimeError(f"Invalid regular renderer diagnostics: {row}")
            return row

        def flush(all_pages, count):
            reply = mcp.tool("clear_page_cache", **{"all": all_pages})
            expected = f"Accepted BFCache flush for {count} of {count} live pages; no reload or site-data deletion."
            if reply != expected:
                raise RuntimeError(f"Unexpected cache result: {reply}")
            return reply

        try:
            original = event("/source", "ready")
            wait_for("Regular page is not frontmost", lambda: front_page("/source"), process)
            screen.guard()
            screen.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
            fill_draft(DRAFT)
            event("/source", "input", id=original["id"], value=DRAFT, trusted=True)
            token = fixture["root"] / "App/DevMCP/token"
            wait_for("Disposable DevMCP token was not created", lambda: token.is_file(), process)
            mcp = Diagnostics(port, token)

            def ping():
                try:
                    mcp.request("ping")
                    return True
                except ConnectionRefusedError:
                    return False

            wait_for("Disposable DevMCP listener did not start", ping, process)
            mcp.request("initialize", {"protocolVersion": "2025-06-18"})
            regular = pages(regular_front=True)
            unchanged = flush(False, 0)
            print("DevMCP reported one mounted regular page", flush=True)

            screen.key("n", screen.command | screen.shift)
            wait_for("New Private Window did not open a second native window",
                     lambda: len(screen.windows()) == 2 or None, process)
            screen.key("l", screen.command)
            wait_for("Private address field did not take focus", lambda:
                     access.attribute(access.attribute(access.application, "AXFocusedUIElement"), "AXRole") == "AXTextField",
                     process)
            screen.key(fixture["origin"] + "/private", unicode=True)
            screen.key("Return")
            event("/private", "ready", storage=None)
            wait_for("Private fixture is not frontmost", lambda: front_page("/private"), process)
            private_front = pages(regular_front=False)
            private_default = flush(False, 0)
            private_all = flush(True, 1)
            print("Frontmost private window was excluded from diagnostics and cache requests", flush=True)
            if not front_page("/private") or len(screen.windows()) != 2:
                raise RuntimeError("A diagnostics call displaced the private window")
            private_window = access.attribute(access.application, "AXFocusedWindow")
            close = access.attribute(private_window, "AXCloseButton")
            if close is None:
                raise RuntimeError("Private window did not offer a native close button")
            access.press(close)
            wait_for("Regular window did not return after closing the private page",
                     lambda: len(screen.windows()) == 1 and front_page("/source"), process)

            field = access.control("Diagnostic draft", ("AXTextField",))
            if access.attribute(field, "AXValue") != DRAFT:
                raise RuntimeError("The cache request lost the regular draft")
            fill_draft(DRAFT + " confirmed")
            event("/source", "input", id=original["id"], value=DRAFT + " confirmed",
                  storage=original["id"], trusted=True)
            if sum(row["event"] == "ready" for row in events) != 2:
                raise RuntimeError("Diagnostics reloaded or created a fixture page")

            screen.key("q", screen.command)
            screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
            if process.wait(timeout=30) != 0:
                raise RuntimeError("Bark did not quit cleanly")
            if tab_inventory(fixture["root"]) != fixture["inventory"]:
                raise RuntimeError("Page diagnostics changed the saved regular tabs or spaces")
            (output / "diagnostics.json").write_text(json.dumps({
                "regular": regular, "private_front": private_front,
                "visible_default": unchanged, "private_default": private_default, "private_all": private_all,
                "retained_document": original["id"], "private_storage_isolated": True, "saved_inventory_unchanged": True,
            }, indent=2) + "\n")
            print("The regular draft, document, site data and saved tab inventory were retained", flush=True)
        except BaseException:
            if process.poll() is None:
                access.dump(output / "accessibility.json")
            raise

    return run_walk(__doc__, "dev-mcp-diagnostics", serve, exercise,
                    [("settings.developerMode", "-bool", "true"), ("settings.browserControlServer", "-bool", "true"),
                     ("NookDevMCPPort", "-string", str(port))],
                    prepare_fixture=prepare, official_qualification=True, parse_options=parse_options)


if __name__ == "__main__":
    sys.exit(main())
