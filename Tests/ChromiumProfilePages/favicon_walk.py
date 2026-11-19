#!/usr/bin/env python3
"""Verify per-profile favicons in the real signed Bark sidebar."""

from contextlib import contextmanager
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import signal
import struct
import sys
from threading import Thread
import time
from uuid import uuid4
import zlib

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

TITLE = "Favicon Fixture"
COLORS = {"Work": (238, 0, 184), "Personal": (0, 225, 43)}


def solid_png(rgb, size=32):
    def chunk(kind, data):
        payload = kind + data
        return struct.pack(">I", len(data)) + payload + struct.pack(">I", zlib.crc32(payload))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress((b"\0" + bytes(rgb) * size) * size))
            + chunk(b"IEND", b""))


class Fixture(BaseHTTPRequestHandler):
    def respond(self, status, kind, body=b"", **headers):
        self.send_response(status)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        for name, value in headers.items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        cookies = SimpleCookie(self.headers.get("Cookie", ""))
        marker = cookies.get("fixture_profile")
        profile = marker.value if marker and marker.value in COLORS else None
        self.server.events.append({"path": self.path, "profile": profile})
        if self.path in ("/start/Work", "/start/Personal"):
            return self.respond(302, "text/plain", Location="/source",
                                **{"Set-Cookie": f"fixture_profile={self.path.split('/')[-1]}; Path=/; SameSite=Lax"})
        if self.path == f"/icon/{profile}.png" and profile in COLORS:
            return self.respond(200, "image/png", solid_png(COLORS[profile]))
        if self.path in ("/source", "/no-icon") and profile:
            icon = f'<link rel="icon" href="/icon/{profile}.png">' if self.path == "/source" else ""
            label = f"{profile} {'icon document' if icon else 'no-icon document'}"
            return self.respond(200, "text/html; charset=utf-8", (
                f'<!doctype html><meta charset="utf-8"><title>{TITLE}</title>{icon}'
                f'<h1>{label}</h1><a href="/no-icon">Open page without an icon</a>'
            ).encode())
        self.respond(404, "text/plain")

    def log_message(self, *_):
        pass


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


def prepare(root, origin, _app, _space):
    paths = root / "App/Tabs"
    structure = json.loads((paths / "structure.json").read_text())
    device = json.loads((paths / "device.json").read_text())
    work = structure["spaces"][0]
    work.update(name="Office", profileName="Work", accentHex="#606060")
    home, home_tab = (str(uuid4()).upper() for _ in range(2))
    structure["spaces"].append(dict(work, id=home, order="W", name="Home", profileName="Personal", icon="house"))
    first = device["items"][0]
    first["kind"] = {"tab": {"url": f"{origin}/start/Work", "pageTitle": TITLE}}
    device["items"].append(dict(first, id=home_tab, parent={"tabs": {"spaceID": home}},
                                kind={"tab": {"url": f"{origin}/start/Personal", "pageTitle": TITLE}}))
    device["state"]["windows"][0]["selectedItemBySpace"] += [home, home_tab]
    for name, data in (("structure", structure), ("device", device)):
        (paths / f"{name}.json").write_text(json.dumps(data) + "\n")


def row_pixels(path, bounds, center):
    from AppKit import NSBitmapImageRep, NSColorSpace
    from Foundation import NSData

    bitmap = NSBitmapImageRep.imageRepWithData_(NSData.dataWithContentsOfFile_(str(path)))
    if bitmap is None:
        raise RuntimeError("Cannot read the candidate screenshot")
    width, height = bitmap.pixelsWide(), bitmap.pixelsHigh()
    sx, sy = width / bounds["Width"], height / bounds["Height"]
    x, y, row_width = center
    left = x - row_width / 2 - bounds["X"]
    middle = y - bounds["Y"]
    x0, x1 = round(left * sx), round((left + 32) * sx)
    y0, y1 = round((middle - 8) * sy), round((middle + 8) * sy)
    if not (0 <= x0 < x1 <= width and 0 <= y0 < y1 <= height):
        raise RuntimeError("Sidebar icon region is outside the candidate screenshot")

    counts = dict.fromkeys(COLORS, 0)
    color_space = NSColorSpace.sRGBColorSpace()
    for yy in range(y0, y1):
        for xx in range(x0, x1):
            color = bitmap.colorAtX_y_(xx, yy).colorUsingColorSpace_(color_space)
            r, g, b = (color.redComponent(), color.greenComponent(), color.blueComponent())
            # Compare channel separation so a display color profile does not
            # move a visibly colored icon across a fixed low-channel boundary.
            if r > 0.65 and b > 0.5 and min(r, b) - g > 0.28:
                counts["Work"] += 1
            if g > 0.6 and g - max(r, b) > 0.28:
                counts["Personal"] += 1
    scale = sx * sy
    return {profile: round(pixels / scale, 1) for profile, pixels in counts.items()}


def exercise(screen, process, events, output):
    access = Accessibility(screen, process)
    results = []
    window = wait_for("The candidate window is missing", lambda: screen.windows() or None, process)[0]
    screen.guard()
    access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
    probe = output / "probe.png"

    def snapshot(step, space, profile, path, expected):
        label = f"{profile} {'icon document' if expected else 'no-icon document'}"
        stable_since = None

        def observe():
            nonlocal stable_since
            screen.guard()
            windows = screen.windows()
            if len(windows) != 1 or windows[0]["kCGWindowNumber"] != window["kCGWindowNumber"]:
                return None
            owner = access.owner(space, ("AXMenuButton",))
            if owner is None:
                return None
            area = next((node for node in access.tree(owner)
                         if access.attribute(node, "AXRole") == "AXWebArea"
                         and access.find(label, ("AXHeading",), root=node)), None)
            url = access.attribute(area, "AXURL")
            if not url or str(url.host()) != "127.0.0.1" or str(url.path()) != path:
                return None
            bounds = windows[0]["kCGWindowBounds"]
            rows = []
            # During a space transition SwiftUI may still expose an identically
            # named outgoing row. Only the row in the visible sidebar can count.
            for node in access.tree(owner):
                if access.attribute(node, "AXRole") != "AXButton" or TITLE not in access.names(node):
                    continue
                size = access.attribute(node, "AXSize")
                if not size:
                    continue
                ok, extent = access.ax.AXValueGetValue(size, access.ax.kAXValueCGSizeType, None)
                if not ok or extent.width < 60:
                    continue
                x, y = access.center(node)
                if (0 < x - bounds["X"] < bounds["Width"] / 3
                        and 0 < y - bounds["Y"] < bounds["Height"]):
                    rows.append((x, y, extent.width))
            if len(rows) != 1:
                stable_since = None
                return None
            x, y, row_width = rows[0]
            screen.screenshot(probe)
            colors = row_pixels(probe, bounds, rows[0])
            if not all(value >= 55 if name == expected else value < 8 for name, value in colors.items()):
                stable_since = None
                return None
            now = time.monotonic()
            if stable_since is None:
                stable_since = now
            if now - stable_since >= 0.8:
                return {"phase": step, "profile": profile, "space": space, "url": str(url.absoluteString()),
                        "sidebar_color_area": colors, "row_center": [x, y], "row_width": row_width}
            return None

        row = wait_for(f"Sidebar icon did not settle for {step}", observe, process, timeout=20)
        probe.rename(output / f"{step}.png")
        results.append(row)
        (output / "result.json").write_text(json.dumps(results, indent=2) + "\n")
        print(step, row["sidebar_color_area"], flush=True)
        return row

    def select_space(space):
        access.press(access.control(space, ("AXButton",)))

    try:
        first = snapshot("work", "Office", "Work", "/source", "Work")
        select_space("Home")
        second = snapshot("personal", "Home", "Personal", "/source", "Personal")
        select_space("Office")
        returned = snapshot("work-return", "Office", "Work", "/source", "Work")
        if first["url"] != second["url"] or first["url"] != returned["url"]:
            raise RuntimeError("The profiles did not display the same committed URL")
        access.press(access.control("Open page without an icon", ("AXLink",)))
        cleared = snapshot("work-no-icon", "Office", "Work", "/no-icon", None)
        if cleared["url"] != first["url"].removesuffix("/source") + "/no-icon":
            raise RuntimeError("The no-icon page left the fixture origin")
        select_space("Home")
        restored = snapshot("personal-return", "Home", "Personal", "/source", "Personal")
        if restored["url"] != second["url"]:
            raise RuntimeError("Returning to Personal changed its committed page")
        for profile in COLORS:
            if {"path": f"/icon/{profile}.png", "profile": profile} not in events:
                raise RuntimeError(f"The fixture did not serve the expected {profile} icon")
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
    except Exception:
        access.dump(output / "last-ax.json")
        raise


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, lambda *_: signal.raise_signal(signal.SIGINT))
    sys.exit(run_walk(__doc__, "profile-favicons", serve, exercise, prepare_fixture=prepare,
                      official_qualification=True))
