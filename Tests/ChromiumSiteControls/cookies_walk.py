#!/usr/bin/env python3
"""Clear a cookie from one disposable loopback site using signed Bark's Site Controls."""

from contextlib import contextmanager
from copy import deepcopy
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
from threading import Event, Thread
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

HOSTS = {"127.0.0.1": ("Cookie source", "source"), "localhost": ("Cookie alternate", "alternate")}
COOKIE = "bark_site_controls_fixture"
navigation = Event()


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        host = self.headers.get("Host", "").split(":", 1)[0]
        if host not in HOSTS or self.path not in ("/source", "/read", "/changed", "/advance"):
            self.send_error(404)
            return
        title, marker = HOSTS[host]
        self.send_response(200)
        self.send_header("Cache-Control", "no-store")
        if self.path in ("/source", "/changed"):
            if self.path == "/source":
                self.send_header("Set-Cookie", f"{COOKIE}={marker}; Path=/; HttpOnly; SameSite=Lax")
            else:
                title = "Cookie destination"
                self.server.events.append({"host": host, "page": "changed"})
            self.send_header("Content-Type", "text/html; charset=utf-8")
            body = (f"<!doctype html><title>{title}</title><h1>{title}</h1>"
                    "<button onclick=\"fetch('/read', {cache: 'no-store'})\">Read fixture cookie</button>"
                    "<button onclick=\"advance()\">Arm fixture navigation</button>"
                    "<script>async function advance() { while ((await (await fetch('/advance')).text()) === 'wait') "
                    "await new Promise(resolve => setTimeout(resolve, 100)); location.assign('/changed'); }</script>").encode()
        elif self.path == "/advance":
            body = b"go" if navigation.is_set() else b"wait"
        else:
            cookies = SimpleCookie(self.headers.get("Cookie", ""))
            self.server.events.append({"host": host, "cookie": cookies[COOKIE].value if COOKIE in cookies else None})
            body = b"ok"
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.events = []
        worker = Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            yield server
        finally:
            server.shutdown()
            worker.join()


def prepare(root, origin, _app, _profile):
    path = root / "App/Tabs/device.json"
    data = json.loads(path.read_text())
    source = data["items"][0]
    source["kind"]["tab"]["pageTitle"] = HOSTS["127.0.0.1"][0]
    alternate = deepcopy(source)
    alternate.update(id=str(uuid4()).upper(), order="W")
    alternate["kind"]["tab"].update(url=f"{origin.replace('127.0.0.1', 'localhost')}/source",
                                    pageTitle=HOSTS["localhost"][0])
    data["items"].append(alternate)
    path.write_text(json.dumps(data) + "\n")


def exercise(screen, process, events, output):
    access = Accessibility(screen, process)
    screen.keys.update({"1": 18, "2": 19, "escape": 53})

    def window_for(host, *, title=None):
        title = title or HOSTS[host][0]
        return wait_for(f"Missing selected {title} page",
                        lambda: access.owner(title, ("AXHeading",)), process, timeout=30)

    def read_cookie(host, *, title=None):
        window = window_for(host, title=title)
        start = len(events)
        access.press(access.control("Read fixture cookie", ("AXButton",), root=window))
        return wait_for(f"Missing cookie probe for {host}",
                        lambda: next((row for row in events[start:] if row["host"] == host and "cookie" in row), None),
                        process)["cookie"]

    def require_cookie(host, expected, *, title=None):
        observed = read_cookie(host, title=title)
        if observed != expected:
            raise RuntimeError(f"{host}: expected fixture cookie {expected!r}, got {observed!r}")

    def clear_menu(host, *, title=None):
        owner = window_for(host, title=title)
        address = wait_for("Missing the fixture address", lambda: next(
            (element for element in access.tree(owner)
             if access.attribute(element, "AXRole") == "AXButton"
             and any(name == host or name.startswith(host + ":")
                     for name in access.names(element))), None), process)
        access.hover(address)
        access.press(access.control("Site Controls", ("AXButton",), root=owner))
        more = wait_for("Missing Site Controls More button", lambda: next(
            (element for element in access.tree(owner)
             if access.attribute(element, "AXRole") in ("AXButton", "AXMenuButton", "AXPopUpButton")
             and ("More" in access.names(element) or access.attribute(element, "AXHelp") == "More")), None), process)
        x, y = access.center(more)
        bounds = screen.windows()[0]["kCGWindowBounds"]
        screen.click((x - bounds["X"], y - bounds["Y"]))

        def clear_cookies():
            focused = access.attribute(access.application, "AXFocusedUIElement")
            for root in (more, access.attribute(more, "AXShownMenuUIElement"), focused,
                         access.attribute(focused, "AXParent"), owner, access.application):
                if root is not None:
                    item = access.find("Clear Cookies", ("AXMenuItem", "AXButton"), root=root)
                    if item is not None:
                        return item
            return None

        return wait_for("Missing Clear Cookies in Site Controls More", clear_cookies, process)

    try:
        wait_for("Missing initial cookie fixture window",
                 lambda: access.owner(HOSTS["127.0.0.1"][0], ("AXWindow",)),
                 process, timeout=30)
        screen.guard()
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        require_cookie("127.0.0.1", "source")
        screen.key("2", screen.command)
        require_cookie("localhost", "alternate")
        screen.key("1", screen.command)
        source_host = "127.0.0.1"
        destination = "Cookie destination"
        owner = window_for(source_host)
        access.press(access.control("Arm fixture navigation", ("AXButton",), root=owner))
        retained = clear_menu(source_host)
        navigation.set()
        wait_for("Fixture did not request the replacement document",
                 lambda: any(row.get("page") == "changed" for row in events), process)
        window_for(source_host, title=destination)
        screen.guard()
        status = access.ax.AXUIElementPerformAction(retained, "AXPress")
        if status == access.ax.kAXErrorInvalidUIElement:
            print("AppKit closed the original menu on navigation.", flush=True)
        elif status == 0:
            print("Submitted the retained menu action after navigation.", flush=True)
        else:
            raise RuntimeError(f"AppKit returned unexpected status for the retained menu: {status}")
        screen.key("Escape")
        require_cookie(source_host, "source", title=destination)

        access.press(clear_menu(source_host, title=destination))
        wait_for("The cookie persisted after Clear Cookies",
                 lambda: read_cookie(source_host, title=destination) is None, process)
        screen.key("2", screen.command)
        require_cookie("localhost", "alternate")
        screen.screenshot(output / "alternate-cookie-preserved.png")
        print("Cleared the requesting site's cookie and preserved the second loopback host's cookie.", flush=True)

        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing quit confirmation", lambda: screen.button("Quit"), process))
    finally:
        access.dump(output / "final-ax.json")


if __name__ == "__main__":
    sys.exit(run_walk(__doc__, "site-cookies", serve, exercise,
                      prepare_fixture=prepare, official_qualification=True))
