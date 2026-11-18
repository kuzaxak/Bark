#!/usr/bin/env python3
"""Verify the signed Bark site-controls certificate inspector on a trusted HTTPS site."""

import argparse
from copy import deepcopy
import hashlib
import json
from pathlib import Path
import runpy
import socket
import ssl
import sys
from urllib.parse import urlsplit
from uuid import uuid4

HERE = Path(__file__).resolve().parent
controls = runpy.run_path(str(HERE.parent / "ChromiumExtensionActions/walk.py"))
from signed_walk import run_walk, wait_for


def peer_certificate(url):
    target = urlsplit(url)
    if target.scheme != "https" or not target.hostname or target.username is not None:
        raise ValueError("Use an HTTPS address without embedded credentials")
    host = target.hostname
    with socket.create_connection((host, target.port or 443), timeout=8) as connection:
        with ssl.create_default_context().wrap_socket(connection, server_hostname=host) as tls:
            issuer_fields = {key: value for group in tls.getpeercert()["issuer"] for key, value in group}
            issuer = issuer_fields.get("commonName") or issuer_fields.get("organizationName")
            if not issuer:
                raise ValueError("The served certificate did not supply an issuer name")
            fingerprint = hashlib.sha256(tls.getpeercert(binary_form=True)).hexdigest()
    return host, issuer, fingerprint


def walk(url, host, issuer, fingerprint):
    def prepare(root, origin, _app, _profile):
        path = root / "App/Tabs/device.json"
        data = json.loads(path.read_text())
        original = data["items"][0]
        original["kind"]["tab"].update(url=url, pageTitle="Certificate test")
        alternate = deepcopy(original)
        alternate["id"] = str(uuid4()).upper()
        alternate["order"] = "W"
        alternate["kind"]["tab"].update(url=f"{origin}/source", pageTitle="Certificate alternate")
        data["items"].append(alternate)
        path.write_text(json.dumps(data) + "\n")

    def exercise(screen, process, events, output):
        access = controls["Accessibility"](screen, process)
        address_hosts = {host.removeprefix("www."), host}
        app_address = urlsplit(url)
        if app_address.port not in (None, 443):
            address_hosts.update(f"{name}:{app_address.port}" for name in tuple(address_hosts))

        def address(window):
            return next((element for element in access.tree(window)
                         if access.attribute(element, "AXRole") == "AXButton"
                         and address_hosts.intersection(access.names(element))), None)

        def click(element):
            x, y = access.center(element)
            bounds = screen.windows()[0]["kCGWindowBounds"]
            screen.click((x - bounds["X"], y - bounds["Y"]))

        def viewer():
            return next((window for window in access.windows()
                         if any(label.startswith("Certificate Viewer: ") for label in access.names(window))), None)

        def open_inspector(source):
            access.hover(address(source))
            access.press(access.control("Site Controls", ("AXButton",), root=source))
            click(access.control("Secure, Show Certificate", ("AXButton",)))
            inspector = wait_for("Physical Secure click did not open the Certificate Viewer", viewer, process)
            wait_for("The certificate inspector did not show the directly verified fingerprint and issuer",
                     lambda: access.find(fingerprint, root=inspector) and access.find(issuer, root=inspector),
                     process)
            return inspector

        def require_preserved_page(source, title, action):
            wait_for(f"{action} did not dismiss the Certificate Viewer", lambda: not viewer(), process)
            wait_for(f"{action} did not preserve the original selected page",
                     lambda: access.attribute(source, "AXTitle") == title and address(source)
                     and access.find(title, ("AXWebArea",), root=source), process)

        try:
            source = wait_for(f"Missing selected address for {host}", lambda: next(
                (window for window in access.windows() if address(window)), None), process, timeout=30)
            screen.guard()
            access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)

            inspector = open_inspector(source)
            title = access.attribute(source, "AXTitle")
            screen.screenshot(output / "certificate.png", include_owned_windows=True)
            click(access.control("Close", ("AXButton",), root=inspector))
            require_preserved_page(source, title, "Physical Close")

            inspector = open_inspector(source)
            inspector_title = access.attribute(inspector, "AXTitle")

            def inspector_focused():
                element = access.attribute(access.application, "AXFocusedUIElement")
                return (access.attribute(element, "AXRole") == "AXWebArea"
                        and inspector_title in access.names(element))

            wait_for("The certificate inspector did not receive keyboard focus", inspector_focused, process)
            focus_window = access.attribute(access.application, "AXFocusedWindow")
            focus = {"title": access.attribute(focus_window, "AXTitle"),
                     "subrole": access.attribute(focus_window, "AXSubrole")}
            (output / "keyboard-focus.json").write_text(json.dumps(focus, indent=2) + "\n")
            screen.keys.update({"w": 13, "1": 18, "2": 19})
            screen.key("w", screen.command)
            require_preserved_page(source, title, "Cmd+W")

            screen.key("2", screen.command)
            alternate = controls["SOURCE"]
            wait_for("Cmd+W lost the alternate tab", lambda: "/ready" in events
                     and access.attribute(source, "AXTitle") == alternate, process)
            screen.key("1", screen.command)
            require_preserved_page(source, title, "Returning from the alternate tab")
            result = {"site": host, "issuer": issuer, "fingerprint_sha256": fingerprint,
                      "dismissal": ["physical Close", "Cmd+W"], "page_after_close": title,
                      "alternate_tab": alternate}
            (output / "certificate.json").write_text(json.dumps(result, indent=2) + "\n")
            print(json.dumps(result), flush=True)
            screen.key("q", screen.command)
            screen.press_button(wait_for("Missing quit confirmation", lambda: screen.button("Quit"), process))
        finally:
            access.dump(output / "final-ax.json")

    return run_walk(__doc__, "certificate", controls["serve"], exercise, prepare_fixture=prepare)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://example.com/",
                        help="Trusted HTTPS URL that stays on the same host (default: %(default)s)")
    if "-h" in sys.argv or "--help" in sys.argv:
        parser.add_argument("--app", required=True, type=Path, help="Signed native Bark.app")
        parser.add_argument("--output", required=True, type=Path, help="New evidence directory")
        parser.parse_args()
    args, remaining = parser.parse_known_args()
    try:
        peer = peer_certificate(args.url)
    except (OSError, ValueError) as failure:
        parser.error(f"Could not verify the HTTPS peer: {failure}")
    sys.argv[1:] = remaining
    return walk(args.url, *peer)


if __name__ == "__main__":
    sys.exit(main())
