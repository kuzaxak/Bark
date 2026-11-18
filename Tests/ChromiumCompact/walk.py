#!/usr/bin/env python3
"""Check page popups and external mini windows in the same signed Bark app."""

from contextlib import ExitStack, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import signal
import sys
from threading import Thread

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import run_walk, wait_for


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == "/redirect":
            self.send_response(302)
            self.send_header("Location", self.server.secondary + "/returned")
            self.end_headers()
            return
        if self.path not in ("/source", "/popup", "/returned", "/external"):
            self.send_error(404)
            return
        data = self.server.html
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
        self.server.events.append(json.loads(self.rfile.read(int(self.headers["Content-Length"]))))
        self.send_response(204)
        self.end_headers()

    def log_message(self, *_):
        pass


@contextmanager
def serve():
    with ExitStack() as stack:
        servers = [stack.enter_context(ThreadingHTTPServer(("127.0.0.1", 0), Fixture)) for _ in range(2)]
        primary, secondary = [f"http://127.0.0.1:{s.server_port}" for s in servers]
        html = (HERE / "fixture.html").read_text().replace("SOURCE_ORIGIN", primary).replace("SECOND_ORIGIN", secondary)
        events = []
        for server in servers:
            server.events, server.html, server.secondary = events, html.encode(), secondary
            thread = Thread(target=server.serve_forever, daemon=True)
            thread.start()
            stack.callback(thread.join)
            stack.callback(server.shutdown)
        yield servers[0]


def send_url(pid, url):
    from Foundation import NSAppleEventDescriptor as Descriptor, NSAppleEventSendNeverInteract, NSAppleEventSendNoReply

    kind = int.from_bytes(b"GURL", "big")
    target = Descriptor.descriptorWithProcessIdentifier_(pid)
    event = Descriptor.appleEventWithEventClass_eventID_targetDescriptor_returnID_transactionID_(kind, kind, target, -1, 0)
    event.setParamDescriptor_forKeyword_(Descriptor.descriptorWithString_(url), int.from_bytes(b"----", "big"))
    _, error = event.sendEventWithOptions_timeout_error_(NSAppleEventSendNeverInteract | NSAppleEventSendNoReply, 5, None)
    if error:
        raise RuntimeError(f"The disposable candidate could not receive the external URL: {error}")


def header_button_point(screen, button):
    screen.guard()
    ax = screen.ax
    def attribute(name, kind):
        status, ref = ax.AXUIElementCopyAttributeValue(button, name, None)
        if status != 0:
            raise RuntimeError(f"Missing {name} on the compact header action")
        ok, value = ax.AXValueGetValue(ref, kind, None)
        if not ok:
            raise RuntimeError(f"Could not read {name} on the compact header action")
        return value
    position = attribute("AXPosition", ax.kAXValueCGPointType)
    size = attribute("AXSize", ax.kAXValueCGSizeType)
    bounds = screen.windows()[0]["kCGWindowBounds"]
    x, y = position.x - bounds["X"], position.y - bounds["Y"]
    if not (size.width > 0 and size.height > 0 and 0 <= x < x + size.width <= bounds["Width"]
            and 0 <= y < y + size.height <= 44):
        raise RuntimeError(f"Compact action frame {(x, y, size.width, size.height)} falls outside the 44-point header")
    return x + size.width / 2, y + size.height / 2


def exercise(screen, proc, events, output):
    steps = []

    def event(page, kind, since=0, **values):
        return wait_for(f"Missing {kind} from {page} matching {values}",
                        lambda: next((r for r in events[since:] if r["page"] == page and r["event"] == kind
                                      and all(r.get(k) == v for k, v in values.items())), None), proc)

    def note(step, row):
        steps.append({"step": step, **row})
        (output / "result.json").write_text(json.dumps(steps, indent=2) + "\n")
        print(step, flush=True)

    def type_value(ready, suffix, expected):
        since = len(events)
        for char in suffix:
            screen.key(char, unicode=True)
        return event(ready["page"], "input", since, documentID=ready["documentID"], value=expected, trusted=True)

    source = event("/source", "ready")
    wait_for("Source window did not reach its saved width",
             lambda: any(w["kCGWindowBounds"]["Width"] == 900 for w in screen.windows()), proc)
    x, y = source["point"]
    screen.click((247 + x, 10 + y))
    draft = "source"
    type_value(source, draft, draft)
    documents = set()
    for count, path in enumerate(("/popup", "/returned", "/popup"), start=1):
        since = len(events)
        screen.key("Return")
        event("/source", "opened", since, count=count, trusted=True, hasHandle=True)
        popup = event(path, "ready", since, hasOpener=True)
        assert popup["documentID"] not in documents
        documents.add(popup["documentID"])
        event("/source", "message", since, documentID=source["documentID"],
              sender=popup["documentID"], senderOrigin=popup["origin"])
        assert (popup["origin"] != source["origin"]) == (path == "/returned")
        wait_for("Popup did not show its compact header and its requested 480 by 306 page area",
                 lambda: len(screen.windows()) == 2 and screen.button("Open in Space") and
                 any(r["documentID"] == popup["documentID"] and abs(r["width"] - 480) <= 1
                     and abs(r["height"] - 306) <= 1 for r in events[since:]), proc)
        header_button_point(screen, screen.button("Open in Space"))
        note("Popup opened at the requested viewport and messaged its opener", popup)
        type_value(popup, "child", "child")
        screen.screenshot(output / f"popup-{count}.png")
        screen.key("Return")
        event(path, "closing", since, documentID=popup["documentID"], trusted=True, value="child")
        wait_for("Closing the popup left its window onscreen", lambda: len(screen.windows()) == 1, proc)
        draft += "x"
        note("Closing the popup returned input to the opener's existing draft", type_value(source, "x", draft))

    since = len(events)
    screen.guard()
    send_url(proc.pid, source["origin"] + "/external")
    external = event("/external", "ready", since, hasOpener=False)
    action = wait_for("The external URL did not open in its own mini window",
                      lambda: len(screen.windows()) == 2 and screen.button("Open in Space"), proc)
    type_value(external, "external", "external")
    screen.screenshot(output / "external.png")
    screen.click(header_button_point(screen, action))
    wait_for("Open in Space kept the external window open", lambda: len(screen.windows()) == 1, proc)
    note("Open in Space kept the external document, draft and focus", type_value(external, "x", "externalx"))
    screen.screenshot(output / "promoted.png")
    screen.key("q", flags=screen.command)
    screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), proc))


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    sys.exit(run_walk(__doc__, "compact", serve, exercise))
