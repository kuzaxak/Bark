#!/usr/bin/env python3
"""Check lazy restoration and bounded warming of a signed Bark session."""

from collections import deque
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import runpy
import subprocess
from pathlib import Path
import re
import sys
from threading import Event, Lock, Thread
import time
from uuid import uuid4

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

source_point = runpy.run_path(str(HERE.parent / "ChromiumPeek/walk.py"))["source_point"]

SELECTED = 23
COLD = 25
PARKED_SPACE = "Parked space"
STANDARD_LIMIT = 16
PAGE = """<!doctype html><meta charset=utf-8><title>Saved tab TAB</title>
<style>body { margin: 24px; font: 18px system-ui } input { font: inherit }</style>
<input id="draft" aria-label="Draft for tab TAB" autofocus>
<script>
const draft = document.querySelector('#draft'), id = crypto.randomUUID();
function report(event, extra = {}) {
    navigator.sendBeacon('/events', JSON.stringify({
        event, id, page: location.pathname, value: draft.value,
        focused: document.activeElement === draft, ...extra
    }));
}
draft.addEventListener('pointerdown', e => report('pointer', {trusted: e.isTrusted}));
draft.addEventListener('input', e => report('input', {trusted: e.isTrusted}));
addEventListener('load', () => report('settled'));
const rect = draft.getBoundingClientRect();
report('ready', {point: [rect.left + rect.width / 2, rect.top + rect.height / 2]});
</script>"""


class EngineTabCounts:
    def __init__(self):
        self.pid = None
        self.pending = deque(maxlen=256)
        self.counts = []
        self.lock = Lock()
        self.ready = Event()

    def read(self, lines):
        for line in lines:
            if line.startswith("Filtering the log data using "):
                self.ready.set()
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if not isinstance(row, dict):
                continue
            pid = row.get("processID")
            message = row.get("eventMessage")
            if (row.get("subsystem"), row.get("category")) != ("ee.qdo.bark", "TabResources"):
                continue
            if type(pid) is not int or not isinstance(message, str):
                continue
            match = re.fullmatch(r"regularTabCount=([0-9]+)", message)
            if not match:
                continue
            count = int(match[1])
            with self.lock:
                if self.pid is None:
                    self.pending.append((pid, count))
                elif pid == self.pid:
                    self.counts.append(count)

    def bind(self, pid):
        # Startup can emit the first count before the signed runner calls its
        # exercise. Recover that count, then discard other processes' samples.
        with self.lock:
            self.pid = pid
            self.counts.extend(count for owner, count in self.pending if owner == pid)
            self.pending.clear()

    def snapshot(self):
        with self.lock:
            return list(self.counts)

    def checkpoint(self, expected, process, description):
        def sample():
            counts = self.snapshot()
            if any(count > expected for count in counts):
                raise RuntimeError(f"{description} exceeded {expected} engine tabs: {counts}")
            return counts if counts and counts[-1] == expected else None

        return wait_for(f"{description} did not report {expected} engine tabs",
                        sample, process)


@contextmanager
def observe_engine_counts():
    observer = EngineTabCounts()
    command = ["/usr/bin/log", "stream", "--level", "debug", "--style", "ndjson", "--predicate",
               'subsystem == "ee.qdo.bark" AND category == "TabResources"']
    with subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True) as stream:
        reader = Thread(target=observer.read, args=(stream.stdout,), daemon=True)
        reader.start()
        try:
            if not observer.ready.wait(5) or stream.poll() is not None:
                raise RuntimeError("The engine tab-count log stream did not start")
            yield observer
        finally:
            if stream.poll() is None:
                stream.terminate()
                try:
                    stream.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    stream.kill()
                    stream.wait(timeout=3)
            reader.join(timeout=3)


def tab_path(number):
    return f"/tab/{number:02}"


class Fixture(BaseHTTPRequestHandler):
    def reply(self, data=b"", kind="text/plain", status=200):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path == "/foreground-gate":
            self.server.events.append({"event": "gate-requested"})
            if not self.server.foreground_typed.wait(25):
                self.server.events.append({"event": "gate-timed-out"})
                self.reply(status=504)
                return
            self.server.events.append({"event": "gate-released"})
            self.reply(status=204)
            return
        page = self.server.pages.get(self.path)
        if page is None:
            self.send_error(404)
            return
        self.server.events.append({"event": "request", "page": self.path})
        self.reply(page, "text/html; charset=utf-8")

    def do_POST(self):
        if self.path != "/events":
            self.send_error(404)
            return
        row = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        row["received_ns"] = time.monotonic_ns()
        self.server.events.append(row)
        if (row.get("page"), row.get("event"), row.get("trusted"), row.get("value")) == (
            tab_path(self.server.selected), "input", True, "foreground draft"
        ):
            self.server.foreground_typed.set()
        self.reply(status=204)

    def log_message(self, *_):
        pass


@contextmanager
def serve(selected):
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.events = []
        server.selected = selected
        server.foreground_typed = Event()
        server.pages = {}
        for number in range(1, 51):
            page = PAGE.replace("TAB", f"{number:02}")
            if number == selected:
                page += '<img hidden alt="" src="/foreground-gate">'
            server.pages[tab_path(number)] = page.encode()
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.foreground_typed.set()
            server.shutdown()
            thread.join()


def prepare_fixture(root, origin, _app, space, *, selected, first_space_size, check_space_switch):
    directory = root / "App/Tabs"
    structure = json.loads((directory / "structure.json").read_text())
    device = json.loads((directory / "device.json").read_text())
    template = device["items"][0]
    other_space = str(uuid4()).upper()
    if check_space_switch:
        # Share one engine profile, so switched-out tabs remain live and the
        # catalog detects any optional warming restarted by the switch.
        structure["spaces"][0]["dataStoreID"] = space
    structure["spaces"].append(dict(structure["spaces"][0], id=other_space, order="W", name=PARKED_SPACE))
    items = []
    for number in range(1, 51):
        owner = space if number <= first_space_size else other_space
        items.append(dict(template, id=str(uuid4()).upper(),
                          kind={"tab": {"url": origin + tab_path(number), "pageTitle": f"Saved tab {number:02}"}},
                          parent={"tabs": {"spaceID": owner}}, order=f"V{number:02}"))
    device["items"] = items
    device["state"]["windows"][0]["selectedItemBySpace"] = [
        space, items[selected - 1]["id"], other_space, items[first_space_size]["id"],
    ]
    for name, value in (("structure", structure), ("device", device)):
        (directory / f"{name}.json").write_text(json.dumps(value) + "\n")


def exercise(screen, process, events, output, *, selected, first_space_size, mode, engine):
    engine.bind(process.pid)
    access = Accessibility(screen, process)
    screen.keys["9"] = 25

    def find_event(name, *, page=None, since=0, **fields):
        return wait_for(f"Missing {name} from {page or 'fixture'} {fields}", lambda: next(
            (row for row in events[since:] if row["event"] == name
             and (page is None or row.get("page") == page)
             and all(row.get(key) == value for key, value in fields.items())), None), process, timeout=45)

    def request_list():
        return [row["page"] for row in events if row["event"] == "request"]

    def mounted_tab(number):
        screen.guard()
        screen.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        want = f"Saved tab {number:02}"

        def check():
            titles = {label for window in access.windows() for node in access.tree(window)
                      if access.attribute(node, "AXRole") == "AXWebArea"
                      for label in access.names(node) if label.startswith("Saved tab ")}
            return sorted(titles) if titles == {want} else None

        try:
            return wait_for(f"The restored WebArea for {want} did not mount alone", check, process)
        except RuntimeError:
            access.dump(output / "accessibility.json")
            raise

    def input_on(number, ready, text):
        start = len(events)
        wait_for("The seeded window did not reach its saved width",
                 lambda: any(row["kCGWindowBounds"]["Width"] == 900 for row in screen.windows()), process)
        screen.click(source_point(ready, "point"))
        find_event("pointer", page=tab_path(number), since=start, id=ready["id"], trusted=True)
        screen.key(text, unicode=True)
        return find_event("input", page=tab_path(number), since=start, id=ready["id"],
                          value=text, trusted=True, focused=True)

    selected_page = tab_path(selected)
    foreground = find_event("ready", page=selected_page)
    find_event("gate-requested")
    initial_requests = request_list()
    if initial_requests != [selected_page]:
        raise RuntimeError(f"Startup reached saved background tabs before the restored page: {initial_requests}")
    held_counts = engine.checkpoint(1, process, "Held foreground")
    first_input = input_on(selected, foreground, "foreground draft")
    find_event("gate-released")
    gate_index = next(index for index, row in enumerate(events) if row["event"] == "gate-released")
    if any(row["event"] == "request" and row["page"] != selected_page for row in events[:gate_index]):
        raise RuntimeError("A background document was requested before foreground input released its load")

    expected = {selected_page}
    if mode == "space-switch":
        expected.update(tab_path(number) for number in range(1, first_space_size + 1))
    elif mode == "default":
        expected.update(tab_path(number) for number in range(1, STANDARD_LIMIT))
    for page in sorted(expected):
        find_event("settled", page=page)
    quiet_until = time.monotonic() + 2
    wait_for("Startup observation interval did not finish", lambda: time.monotonic() >= quiet_until, process)
    startup_requests = request_list()
    startup_ready = {row["page"]: row["id"] for row in events if row["event"] == "ready"}
    if len(startup_requests) != len(expected) or set(startup_requests) != expected or set(startup_ready) != expected:
        raise RuntimeError(f"Wrong startup document set, requests={startup_requests}, ready={list(startup_ready)}")
    settled_ax = mounted_tab(selected)
    startup_counts = engine.checkpoint(len(expected), process, "Settled startup")

    since = len(events)
    selection_started = time.monotonic_ns()
    if mode == "space-switch":
        x, y = access.center(access.control(PARKED_SPACE, ("AXButton",)))
        bounds = screen.windows()[0]["kCGWindowBounds"]
        screen.click((x - bounds["X"], y - bounds["Y"]))
        wait_for("Parked space did not become selected",
                 lambda: access.find(PARKED_SPACE, ("AXMenuButton",)), process)
        cold_tab = first_space_size + 1
    else:
        screen.key("9", screen.command)
        cold_tab = COLD
    cold_page = tab_path(cold_tab)
    cold = find_event("ready", page=cold_page, since=since)
    cold_ax = mounted_tab(cold_tab)
    cold_input = input_on(cold_tab, cold, "selected parked draft")
    if mode == "space-switch":
        find_event("settled", page=cold_page, since=since, id=cold["id"])
        quiet_until = time.monotonic() + 3
        wait_for("Post-switch observation interval did not finish", lambda: time.monotonic() >= quiet_until, process)
    final_requests = request_list()
    if final_requests != startup_requests + [cold_page]:
        raise RuntimeError(f"Selecting the cold row also started another document: {final_requests}")

    final_counts = engine.checkpoint(len(expected) + 1, process, "Cold selection")
    (output / "result.json").write_text(json.dumps({
        "mode": mode,
        "saved_rows": 50,
        "observed_latency_ms": {
            "launch_to_selected_document": round((foreground["received_ns"] - screen.launch_started_ns) / 1e6, 2),
            "launch_to_trusted_input": round((first_input["received_ns"] - screen.launch_started_ns) / 1e6, 2),
            "cold_selection_to_document": round((cold["received_ns"] - selection_started) / 1e6, 2),
            "cold_selection_to_trusted_input": round((cold_input["received_ns"] - selection_started) / 1e6, 2),
        },
        "initial_requests": initial_requests,
        "startup_requests": startup_requests,
        "startup_renderer_documents": startup_ready,
        "settled_web_areas": settled_ax,
        "cold_selection": {"path": cold_page, "document": cold["id"], "web_areas": cold_ax},
        "final_requests": final_requests,
        "engine_catalog": {
            "pid": process.pid,
            "held_foreground": held_counts[-1],
            "settled_startup": startup_counts[-1],
            "after_cold_selection": final_counts[-1],
            "peak": max(final_counts),
            "count_changes": final_counts,
        },
    }, indent=2) + "\n")
    print(f"50 saved rows; {len(startup_ready)} startup renderer documents; exact cold selection and trusted input.",
          flush=True)
    screen.key("q", screen.command)
    screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))


def main():
    preferences = []
    mode, selected, first_space_size, ceiling = "default", SELECTED, 25, STANDARD_LIMIT + 1

    def options(parser):
        nonlocal mode, selected, first_space_size, ceiling
        scenario = parser.add_mutually_exclusive_group()
        scenario.add_argument("--last-tab-only", action="store_true",
                              help="verify the same session with the startup warmer disabled")
        scenario.add_argument("--check-space-switch", action="store_true",
                              help="verify ordinary space switching does not restart the completed startup warmer")
        args = parser.parse_args()
        if args.last_tab_only:
            mode, ceiling = "last-tab-only", 2
            preferences.append(("settings.startupLoadMode", "-string", "nothing"))
        elif args.check_space_switch:
            mode, selected, first_space_size, ceiling = "space-switch", 2, 3, 4
        return args

    def prepare(root, origin, app, space):
        prepare_fixture(root, origin, app, space, selected=selected, first_space_size=first_space_size,
                        check_space_switch=mode == "space-switch")

    def walk(screen, process, events, output):
        exercise(screen, process, events, output, selected=selected, first_space_size=first_space_size,
                 mode=mode, engine=engine)

    with observe_engine_counts() as engine:
        status = run_walk(__doc__, "startup-lazy-restore", lambda: serve(selected), walk, preferences,
                          prepare_fixture=prepare, official_qualification=True, parse_options=options)
    if status == 0:
        counts = engine.snapshot()
        if max(counts) > ceiling:
            raise RuntimeError(f"The engine exceeded the tab ceiling before quit: {counts}")
    return status


if __name__ == "__main__":
    sys.exit(main())
