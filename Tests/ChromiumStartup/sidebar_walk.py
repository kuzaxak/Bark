#!/usr/bin/env python3
"""Check the first sidebar shortcut on fresh launch and the first sidebar click on relaunch."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
import threading
import time
from urllib.parse import parse_qs, urlsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for


PAGE = b"""<!doctype html><meta charset=utf-8><title>Bark sidebar startup test</title>
<script>
const doc = crypto.randomUUID();
function report(event) {
  fetch('/event?' + new URLSearchParams({event, doc, width: innerWidth}));
}
addEventListener('load', () => report('loaded'));
addEventListener('resize', () => report('resized'));
</script>"""


def main():
    allow_page = threading.Event()

    @contextmanager
    def serve():
        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                parsed = urlsplit(self.path)
                if parsed.path == "/source":
                    if not allow_page.wait(30):
                        self.send_error(503)
                        return
                    self.send_response(200)
                    self.send_header("Content-Type", "text/html; charset=utf-8")
                    self.send_header("Cache-Control", "no-store")
                    self.send_header("Content-Length", str(len(PAGE)))
                    self.end_headers()
                    self.wfile.write(PAGE)
                    return
                if parsed.path == "/event":
                    values = parse_qs(parsed.query)
                    self.server.events.append({key: values[key][0] for key in ("event", "doc", "width")})
                self.send_response(204)
                self.end_headers()

            def log_message(self, *_args):
                pass

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            server.events = []
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                yield server
            finally:
                allow_page.set()
                server.shutdown()
                worker.join()

    def check_first_input(screen, process, events, output, *, mouse):
        access = Accessibility(screen, process)
        key = "mouse" if mouse else "keyboard"
        start = len(events)

        def visible_toggle():
            windows = screen.windows()
            if len(windows) != 1 or not access.attribute(access.application, "AXFrontmost"):
                return None
            button = access.find("Toggle Sidebar", ("AXButton",))
            if button is not None:
                x, y = access.center(button)
                bounds = windows[0]["kCGWindowBounds"]
                if (bounds["X"] <= x < bounds["X"] + bounds["Width"] and
                        bounds["Y"] <= y < bounds["Y"] + bounds["Height"]):
                    return button
            return None

        wait_for("The startup window did not appear", lambda: bool(screen.windows()), process)
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        try:
            button = wait_for("Bark did not show its sidebar on launch", visible_toggle, process)
        except RuntimeError:
            access.dump(output / f"{key}-startup.json")
            raise
        if allow_page.is_set() or len(events) != start:
            raise RuntimeError("The first input must precede the fixture page response")
        if mouse:
            x, y = access.center(button)
            bounds = screen.windows()[0]["kCGWindowBounds"]
            screen.click((x - bounds["X"], y - bounds["Y"]))
        else:
            screen.key("s", screen.command)
        submitted = time.monotonic_ns()

        def sidebar_hidden():
            screen.guard()
            return visible_toggle() is None

        wait_for("The first input did not hide the sidebar while the page was pending", sidebar_hidden, process)
        wait_for("The invisible sidebar still exposes its button to accessibility",
                 lambda: access.find("Toggle Sidebar", ("AXButton",)) is None, process)
        allow_page.set()
        loaded = wait_for("The held page did not load after the first input",
                          lambda: next((e for e in events[start:] if e["event"] == "loaded"), None), process)

        def hidden_viewport():
            windows = screen.windows()
            if len(windows) != 1 or windows[0]["kCGWindowBounds"]["Width"] != 900:
                return None
            # Chromium can briefly report its default surface size while the
            # window restores its saved 900-point frame.
            latest = next((e for e in reversed(events[start:]) if e["doc"] == loaded["doc"]), None)
            return latest if latest and 850 <= int(latest["width"]) <= 900 else None

        hidden = wait_for("The page did not fill the restored window with its sidebar hidden",
                          hidden_viewport, process)
        hide_width = int(hidden["width"])
        if not mouse:
            bounds = screen.windows()[0]["kCGWindowBounds"]
            y = bounds["Y"] + bounds["Height"] / 2
            screen.hover((bounds["X"] + 2, y))
            wait_for("Edge hover did not restore accessible sidebar controls", visible_toggle, process)
            screen.hover((bounds["X"] + bounds["Width"] - 25, y))
            wait_for("The dismissed hover sidebar still exposes its button to accessibility",
                     lambda: access.find("Toggle Sidebar", ("AXButton",)) is None, process)

            def palette_has_focus():
                focus = access.attribute(access.application, "AXFocusedUIElement")
                return access.attribute(focus, "AXRole") == "AXTextField"

            screen.keys["t"] = 17
            screen.key("t", screen.command)
            wait_for("The command palette did not open with the sidebar hidden", palette_has_focus, process)
            screen.key("Escape")
            wait_for("Escape did not dismiss the command palette", lambda: not palette_has_focus(), process)
        before_restore = len(events)
        screen.key("s", screen.command)
        wait_for("Command-S did not restore the sidebar", visible_toggle, process)
        resized = wait_for("Restoring the sidebar did not reclaim its column from the live page",
                           lambda: next((e for e in events[before_restore:] if e["doc"] == loaded["doc"]
                                         and e["event"] == "resized" and int(e["width"]) < hide_width - 100), None),
                           process)
        result = {"first_input": key, "launch_to_input_sent_ms": round((submitted - screen.launch_started_ns) / 1e6),
                  "page_width_hidden": hide_width, "page_width_shown": int(resized["width"]),
                  "document": loaded["doc"]}
        (output / f"{key}.json").write_text(json.dumps(result, indent=2) + "\n")
        print(json.dumps(result), flush=True)
        allow_page.clear()
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))

    return run_walk(__doc__, "startup-sidebar", serve,
                    lambda *args: check_first_input(*args, mouse=False),
                    relaunch=lambda *args: check_first_input(*args, mouse=True),
                    official_qualification=True)


if __name__ == "__main__":
    sys.exit(main())
