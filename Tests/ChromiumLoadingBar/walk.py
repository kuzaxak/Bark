#!/usr/bin/env python3
"""Check the address bar's load progress on a held loopback navigation in signed Bark."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
from threading import Event, Thread

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for


def main():
    release_more = Event()
    finish = Event()
    expect_unknown = False

    def parse(parser):
        nonlocal expect_unknown
        parser.add_argument("--expect-indeterminate", action="store_true",
                            help="check the loading flag on an SDK without numeric progress")
        options = parser.parse_args()
        if options.require_official and options.expect_indeterminate:
            parser.error("official load-progress qualification requires numeric progress")
        expect_unknown = options.expect_indeterminate
        return options

    @contextmanager
    def serve():
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                if self.path == "/source":
                    data = (b"<!doctype html><title>Loading bar fixture</title><h1>Loading bar fixture</h1>"
                            b"<script src='/held.js'></script><script>onload=()=>fetch('/loaded')</script>")
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Content-Length", str(len(data)))
                    self.end_headers()
                    self.wfile.write(data)
                elif self.path == "/held.js":
                    # A blocking script with a declared size gives Chromium measurable
                    # progress between chunks. Keep the same document loading throughout.
                    self.send_response(200)
                    self.send_header("Content-Type", "text/javascript")
                    self.send_header("Content-Length", str(1024 * 1024))
                    self.end_headers()
                    for size, event, gate in ((64, "first chunk", release_more),
                                              (768, "second chunk", finish),
                                              (192, "last chunk", None)):
                        self.wfile.write(b" " * (size * 1024))
                        self.wfile.flush()
                        self.server.events.append(event)
                        if gate and not gate.wait(45):
                            return
                else:
                    if self.path == "/loaded":
                        self.server.events.append("loaded")
                    self.send_response(204)
                    self.end_headers()

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            server.events = []
            worker = Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                yield server
            finally:
                release_more.set()
                finish.set()
                server.shutdown()
                worker.join()

    def exercise(screen, process, events, output):
        access = Accessibility(screen, process)
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)

        def indicator():
            return access.find("Page loading", ("AXProgressIndicator", "AXBusyIndicator"))

        def sample():
            element = indicator()
            if not element:
                return None
            value = access.attribute(element, "AXValue")
            role = access.attribute(element, "AXRole")
            if expect_unknown:
                if role == "AXBusyIndicator" and access.attribute(element, "AXValueDescription") == "In progress":
                    return "In progress"
            elif (role == "AXProgressIndicator" and access.attribute(element, "AXMinValue") == 0
                  and access.attribute(element, "AXMaxValue") == 1
                  and isinstance(value, (int, float)) and 0 < value < 1):
                return float(value)
            return None

        try:
            wait_for("The script did not begin loading", lambda: "first chunk" in events, process, timeout=30)
            first = wait_for("Missing expected loading indicator", sample, process)
            release_more.set()
            wait_for("The second script chunk did not arrive", lambda: "second chunk" in events, process)

            def next_sample():
                value = sample()
                return value if value is not None and (expect_unknown or value > first) else None

            second = wait_for("The indicator did not reflect the second chunk", next_sample, process)
            finish.set()
            wait_for("The page did not finish loading", lambda: "loaded" in events, process)
            wait_for("The address bar still reports loading after completion", lambda: indicator() is None, process)
            (output / "progress.json").write_text(json.dumps({"first": first, "second": second,
                                                               "hidden_after_load": True}, indent=2) + "\n")
            screen.key("q", screen.command)
            access.press(access.control("Quit", ("AXButton",)))
        except Exception:
            access.dump(output / "loading-accessibility.json")
            raise

    return run_walk(__doc__, "page-progress", serve, exercise, official_qualification=True,
                    parse_options=parse)


if __name__ == "__main__":
    sys.exit(main())
