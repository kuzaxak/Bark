#!/usr/bin/env python3
"""Save and decline fully specified shipping addresses in a signed Bark window."""

from contextlib import closing, contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
from threading import Thread
from urllib.parse import parse_qs

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

FIELDS = (
    ("name", "Full name"), ("address-line1", "Street address"), ("address-level2", "City"),
    ("address-level1", "State"), ("postal-code", "ZIP code"), ("country-name", "Country"),
    ("tel", "Phone"), ("email", "Email"),
)
ACCEPT = ("Tessa Fixture", "123 Test Avenue", "Cupertino", "California", "95014", "United States",
          "+14085550101", "tessa@fixture.invalid")
DECLINE = ("Jamie Sample", "77 Sample Road", "Seattle", "Washington", "98101", "United States",
           "+12065550102", "jamie@fixture.invalid")


class Fixture(BaseHTTPRequestHandler):
    def send_page(self, title, content):
        body = (f"<!doctype html><meta charset=utf-8><title>{title}</title>"
                "<style>body{font:16px system-ui} label{display:block;margin:7px} "
                "label span{display:inline-block;width:130px} input{width:230px}</style>"
                f"<h1>{title}</h1>{content}").encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path not in ("/source", "/decline"):
            self.send_error(404)
            return
        fields = "".join(f'<label><span>{label}</span><input name="{name}" autocomplete="shipping {name}"></label>'
                         for name, label in FIELDS)
        self.send_page("Shipping address fixture",
                       f'<form action="/submitted{self.path}" method="post">{fields}'
                       '<button type="submit">Submit shipping address</button></form>')
        self.server.events.append({"page": self.path})

    def do_POST(self):
        if self.path not in ("/submitted/source", "/submitted/decline"):
            self.send_error(404)
            return
        fields = parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode())
        self.send_page("Shipping address submitted", '<a href="/decline">Open second shipping form</a>')
        self.server.events.append({"page": self.path, "fields": fields})

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


def verify_addresses(root, output):
    databases = list((root / "Engine").glob("Barc-*/Web Data"))
    if len(databases) != 1:
        raise RuntimeError("Expected one named disposable profile address database")
    with closing(sqlite3.connect(databases[0].as_uri() + "?mode=ro", uri=True)) as db:
        addresses = db.execute("SELECT guid FROM addresses").fetchall()
        tokens = set(db.execute("SELECT value FROM address_type_tokens").fetchall())
    values = {item[0] for item in tokens}
    # Chromium normalizes country and phone. Check independent identity and street
    # values rather than depending on its country-specific formatting.
    if len(addresses) != 1 or not {ACCEPT[0], ACCEPT[1], ACCEPT[2], ACCEPT[4], ACCEPT[7]} <= values:
        raise RuntimeError(f"Accept did not persist exactly the submitted shipping address: {values}")
    if {DECLINE[0], DECLINE[1], DECLINE[7]} & values:
        raise RuntimeError("The declined address was persisted")
    (output / "saved-address.json").write_text(json.dumps({"saved_count": len(addresses),
                                                           "saved_values": sorted(values)}, indent=2) + "\n")


def exercise(screen, process, events, output, root):
    access = Accessibility(screen, process)
    def click(element):
        x, y = access.center(element)
        bounds = screen.windows()[0]["kCGWindowBounds"]
        screen.click((x - bounds["X"], y - bounds["Y"]))

    def bubble():
        titles = {"Save address?", "Save address in account?"}
        return next((node for window in access.windows() for node in access.tree(window)
                     if access.attribute(node, "AXRole") in ("AXWindow", "AXDialog", "AXPopover")
                     and titles.intersection(access.names(node))), None)

    def click_action(labels):
        previous = None

        def stable_hit():
            nonlocal previous
            dialog = bubble()
            if dialog is None:
                previous = None
                return None
            button = next((node for label in labels if
                           (node := access.find(label, ("AXButton",), root=dialog))), None)
            if button is None:
                previous = None
                return None
            point = access.center(button)
            status, hit = access.ax.AXUIElementCopyElementAtPosition(access.application, *point, None)
            hit_window = access.attribute(hit, "AXWindow")
            if (status or access.attribute(hit, "AXRole") != "AXButton"
                    or not set(labels).intersection(access.names(hit))
                    or not access.attribute(hit, "AXEnabled")
                    or not set(access.names(dialog)).intersection(access.names(hit_window))):
                previous = None
                return None
            stable = point == previous
            previous = point
            return point if stable else None

        x, y = wait_for("Missing stable owned address action", stable_hit, process)
        bounds = screen.windows()[0]["kCGWindowBounds"]
        screen.click((x - bounds["X"], y - bounds["Y"]))

    def bubble_preview():
        for element in access.tree(bubble()):
            yield from access.names(element)
            value = access.attribute(element, "AXValue")
            if hasattr(value, "string"):
                yield str(value.string())

    def submit(page, values, buttons):
        wait_for(f"Did not serve {page}", lambda: any(row["page"] == page for row in events), process)
        for (_, label), value in zip(FIELDS, values):
            field = wait_for(f"Missing shipping field {label}",
                             lambda: access.find(label, ("AXTextField",)), process)
            click(field)
            wait_for(f"The shipping field {label} did not take focus", lambda: access.attribute(field, "AXFocused"), process)
            screen.key(value, unicode=True)
            # The newly saved address can present suggestions over the next
            # field. Clear that popup while the submitted page is still the form.
            screen.key("Escape")
        click(access.control("Submit shipping address", ("AXButton",)))
        expected = {name: [value] for (name, _), value in zip(FIELDS, values)}
        wait_for(f"Real shipping form POST did not contain expected fields for {page}", lambda: any(
            row["page"] == "/submitted" + page and row.get("fields") == expected for row in events), process)
        wait_for("The submitted address did not show a save bubble", bubble, process)
        access.dump(output / ("bubble" + page.replace("/", "-") + ".json"))
        screen.screenshot(output / ("bubble" + page.replace("/", "-") + ".png"), include_owned_windows=True)
        wait_for("The address bubble did not show the submitted person and street",
                 lambda: all(value in "\n".join(bubble_preview()) for value in values[:2]), process)
        click_action(buttons)
        wait_for("Address bubble did not dismiss", lambda: not bubble(), process)

    try:
        def frontmost():
            asn = subprocess.check_output(["lsappinfo", "front"], text=True).strip()
            pid = subprocess.check_output(["lsappinfo", "info", "-only", "pid", asn], text=True).strip()
            return pid.split("=")[-1] == str(process.pid)

        wait_for("Missing frontmost shipping fixture window",
                 lambda: frontmost() and access.owner("Shipping address fixture", ("AXWindow",)), process)
        screen.guard()
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        submit("/source", ACCEPT, ("Save",))
        click(access.control("Open second shipping form", ("AXLink",)))
        submit("/decline", DECLINE, ("No thanks", "Cancel"))
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
        if process.wait(timeout=30) != 0:
            raise RuntimeError("The candidate did not flush and quit cleanly")
        verify_addresses(root, output)
    finally:
        if process.poll() is None:
            access.dump(output / "last-ax.json")


if __name__ == "__main__":
    fixture = {}
    def prepare(root, _origin, _app, _profile):
        fixture["root"] = root
    def run(screen, process, events, output):
        exercise(screen, process, events, output, fixture["root"])
    sys.exit(run_walk(__doc__, "shipping-address", serve, run, prepare_fixture=prepare,
                      official_qualification=True))
