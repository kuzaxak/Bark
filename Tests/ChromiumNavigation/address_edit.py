#!/usr/bin/env python3
"""Check which document receives a submitted address after a same-URL reload."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
import sys
from threading import Event, Thread

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for


def main():
    reload_page = Event()
    origin = ""

    @contextmanager
    def serve():
        nonlocal origin

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.server.events.append(self.path)
                body = b""
                if self.path == "/source":
                    body = b"""<!doctype html><title>Address edit owner</title><h1>Address edit owner</h1>
                        <script>
                        const visit = Number(sessionStorage.visits || 0) + 1;
                        sessionStorage.visits = visit;
                        window.name = 'address-edit-source';
                        onload = () => {
                            fetch('/ready' + visit);
                            if (visit === 1) fetch('/reload').then(() => location.reload());
                        };
                        </script>"""
                elif self.path == "/reload":
                    reload_page.wait(60)
                elif self.path == "/accepted":
                    body = b"""<!doctype html><title>Address edit result</title>
                        <script>fetch(window.name === 'address-edit-source' ? '/same-tab' : '/new-tab');</script>"""
                self.send_response(200)
                self.send_header("Content-Type", "text/html; charset=utf-8")
                self.send_header("Cache-Control", "no-store")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_):
                pass

        with ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
            server.events = []
            origin = f"http://127.0.0.1:{server.server_port}"
            worker = Thread(target=server.serve_forever, daemon=True)
            worker.start()
            try:
                yield server
            finally:
                reload_page.set()
                server.shutdown()
                worker.join()

    def exercise(screen, process, events, output):
        access = Accessibility(screen, process)
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        screen.keys.update({"l": 37, "a": 0})

        def address_value():
            field = access.attribute(access.application, "AXFocusedUIElement")
            if field is not None and access.attribute(field, "AXRole") in ("AXTextField", "AXComboBox"):
                return access.attribute(field, "AXValue")
            return None

        def enter_address(path):
            screen.key("l", screen.command)
            wait_for("Cmd+L did not expose the source address", lambda: address_value() == origin + "/source", process)
            screen.key("a", screen.command)
            for char in origin + path:
                screen.key(char, unicode=True)
            wait_for("The address editor did not receive the entire URL", lambda: address_value() == origin + path, process)

        try:
            wait_for("The source document did not load", lambda: "/ready1" in events, process, timeout=30)
            enter_address("/stale")
            reload_page.set()
            wait_for("The source did not load its replacement document", lambda: "/ready2" in events, process)
            if address_value() == origin + "/stale":
                screen.key("Return")
            wait_for("The previous address editor did not dismiss", lambda: address_value() != origin + "/stale", process)
            if "/stale" in events:
                raise RuntimeError("Submitting the stale address navigated the replacement document")
            enter_address("/accepted")
            screen.key("Return")
            wait_for("The new edit did not navigate the original tab", lambda: "/same-tab" in events, process)
            if "/stale" in events:
                raise RuntimeError("The stale address was requested during the next edit")
            screen.key("q", screen.command)
            access.press(access.control("Quit", ("AXButton",)))
        except Exception:
            access.dump(output / "address-accessibility.json")
            raise

    return run_walk(__doc__, "address-edit", serve, exercise, official_qualification=True)


if __name__ == "__main__":
    sys.exit(main())
