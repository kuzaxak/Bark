#!/usr/bin/env python3
"""Walk a signed Intel Bark candidate with a new disposable profile."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import signal
import sys
from threading import Thread
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import run_walk, wait_for

SIDEBAR_WIDTH = 247
PAGE_MARGIN = 10


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path not in ("/source", "/target"):
            self.send_error(404)
            return
        data = self.server.html.replace("PAGE", self.path[1:]).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        if self.path != "/events":
            self.send_error(404)
            return
        row = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        row["time"] = time.time()
        row["received_ns"] = time.monotonic_ns()
        self.server.events.append(row)
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.html = (HERE / "fixture.html").read_text()
        server.events = []
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.shutdown()
            thread.join()


def source_point(event, name):
    x, y = event[name]
    return SIDEBAR_WIDTH + x, PAGE_MARGIN + y


def exercise(screen, proc, events, output):
    steps = []

    def note(step, row):
        steps.append({"step": step, **row})
        (output / "result.json").write_text(json.dumps(steps, indent=2) + "\n")
        print(step, flush=True)

    def event(page, kind, since=0, **where):
        return wait_for(f"{kind} did not reach {page}",
                        lambda: next((row for row in events[since:] if row["page"] == page and row["event"] == kind
                                      and all(row.get(key) == value for key, value in where.items())), None), proc)

    def draft(page, ready, text):
        if page == "/source":
            screen.click(source_point(ready, "draftPoint"))
        since = len(events)
        for char in text:
            screen.key(char, unicode=True)
        return event(page, "input", since, trusted=True, value=text, documentID=ready["documentID"])

    source = event("/source", "ready")
    wait_for("the seeded window never reached its saved size",
             lambda: any(row["kCGWindowBounds"]["Width"] == 900 for row in screen.windows()), proc)
    draft("/source", source, "sourcedraft")
    screen.screenshot(output / "source.png")

    def peek():
        since = len(events)
        screen.click(source_point(source, "linkPoint"), flags=screen.shift)
        linked = event("/source", "link", since, trusted=True, shift=True, documentID=source["documentID"])
        target = event("/target", "ready", since)
        wait_for("Missing Peek card actions", lambda: screen.button("Open in Split View"), proc)
        if len(screen.windows()) != 1:
            raise RuntimeError("Shift-click opened a new window")
        note("Trusted Shift-click opened Peek", {"link": linked, "target": target})
        return target

    first = peek()
    screen.screenshot(output / "peek.png")
    draft("/target", first, "firstpeek")
    since = len(events)
    screen.key("Escape")
    event("/target", "key", since, key="Escape", trusted=True)
    wait_for("Escape left the Peek actions visible", lambda: screen.button("Open in Split View") is None, proc)
    screen.key("s")
    note("Escape restored the same source draft and keyboard focus",
         event("/source", "key", since, key="s", trusted=True, documentID=source["documentID"], value="sourcedraft"))

    second = peek()
    if second["documentID"] == first["documentID"]:
        raise RuntimeError("The dismissed Peek document was reused")
    card = draft("/target", second, "keptinpeek")
    since = len(events)
    screen.press_button(wait_for("Missing Peek split action", lambda: screen.button("Open in Split View"), proc))
    wait_for("Opening a split did not resize the Peek into a pane",
             lambda: any(row["documentID"] == second["documentID"] and row["event"] == "resize"
                         and row["viewport"] < card["viewport"] * 0.80 for row in events[since:]), proc)
    wait_for("The split action remained in the window after promotion",
             lambda: screen.button("Open in Split View") is None, proc)
    screen.key("p")
    note("Split promotion retained the same Peek document, draft and keyboard focus",
         event("/target", "key", since, key="p", trusted=True, documentID=second["documentID"], value="keptinpeek"))
    screen.screenshot(output / "split.png")
    screen.key("q", flags=screen.command)
    screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), proc))


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    sys.exit(run_walk(__doc__, "peek", serve, exercise, [("settings.peekOnShiftClick", "-bool", "true")]))
