#!/usr/bin/env python3
"""Open each Chromium quick link in the requested profile's space in signed Bark."""

import json
from pathlib import Path
import runpy
import subprocess
import sys
from uuid import uuid4

HERE = Path(__file__).resolve().parent
peek = runpy.run_path(str(HERE.parent / "ChromiumPeek/walk.py"))
from signed_walk import Accessibility, run_walk, wait_for


def main():
    fixture = {}
    profile_name = "Archive Fixture"
    space_name = "Archive First"

    def prepare(root, _origin, _app, _profile):
        fixture["id"] = str(uuid4()).upper()
        fixture["engine"] = root / "Engine"
        tabs = root / "App/Tabs"
        structure = json.loads((tabs / "structure.json").read_text())
        device = json.loads((tabs / "device.json").read_text())
        for name, order in ((space_name, "W"), ("Archive Second", "X")):
            space = str(uuid4()).upper()
            tab = str(uuid4()).upper()
            structure["spaces"].append(dict(
                structure["spaces"][0], id=space, name=name, order=order,
                profileName=profile_name, dataStoreID=fixture["id"]))
            device["items"].append(dict(device["items"][0], id=tab, parent={"tabs": {"spaceID": space}}))
            device["state"]["windows"][0]["selectedItemBySpace"] += [space, tab]
        for name, value in (("structure", structure), ("device", device)):
            (tabs / f"{name}.json").write_text(json.dumps(value) + "\n")

    def exercise(screen, process, _events, output):
        access = Accessibility(screen, process)
        screen.keys[","] = 43
        links = {
            "Open Profile Settings": ("Settings", "chrome://settings/"),
            "Extensions": ("Extensions", "chrome://extensions/"),
            "Privacy and Security": ("Settings - Privacy and security", "chrome://settings/privacy"),
            "Secure Connections": ("Settings - Security", "chrome://settings/security"),
            "Site Settings": ("Settings - Site settings", "chrome://settings/content"),
            "Clear Browsing Data": ("Settings - Privacy and security", "chrome://settings/clearBrowserData"),
            "Downloads": ("Settings - Downloads", "chrome://settings/downloads"),
            "Password Manager": ("Password Manager", "chrome://password-manager/passwords"),
        }
        results = {}
        try:
            def frontmost():
                asn = subprocess.check_output(["lsappinfo", "front"], text=True).strip()
                pid = subprocess.check_output(["lsappinfo", "info", "-only", "pid", asn], text=True).strip()
                return pid.split("=")[-1] == str(process.pid) and screen.windows()

            wait_for("The disposable Bark window did not become frontmost", frontmost, process)
            product = wait_for("The product window did not become key",
                               lambda: access.attribute(access.application, "AXFocusedWindow"), process)
            screen.guard()
            access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
            screen.key(",", screen.command)
            access.press(access.control("Privacy", ("AXButton",)))
            access.press(access.control("Open Profiles", ("AXButton",)))
            settings = wait_for("Profiles did not open",
                                lambda: access.owner("Your Profiles"), process)
            profile = next(element for element in access.tree(settings)
                           if access.attribute(element, "AXRole") == "AXButton"
                           and any(profile_name in name for name in access.names(element)))
            access.press(profile)
            directory = fixture["engine"] / ("Barc-" + fixture["id"].lower())
            def web_url(element):
                url = access.attribute(element, "AXURL")
                return str(url.absoluteString()) if url else None

            for label, (title, expected_url) in links.items():
                access.press(access.control(label, ("AXButton",), root=settings))
                wait_for("The product window did not return to the front",
                         lambda: access.attribute(access.application, "AXFocusedWindow") == product, process)
                access.control(space_name, ("AXMenuButton",), root=product)
                wait_for("The requested profile's Chromium directory was not created",
                         lambda: directory.is_dir(), process)
                area = wait_for(f"{label} did not open {expected_url}", lambda: next(
                    (element for element in access.tree(product)
                     if access.attribute(element, "AXRole") == "AXWebArea"
                     and web_url(element) == expected_url), None), process)
                detail = {}
                if label == "Site Settings":
                    row = access.control("Location Sites can ask for your location", ("AXLink",), root=area)
                    detail["permission_row"] = access.names(row)
                if label == "Clear Browsing Data":
                    dialog = wait_for("Missing the Chromium delete data dialog", lambda: next(
                        (element for element in access.tree(area)
                         if (access.attribute(element, "AXRole") == "AXDialog"
                             or access.attribute(element, "AXSubrole")
                             in ("AXApplicationDialog", "AXApplicationAlertDialog", "AXDialog"))
                         and any(name.lower() == "delete browsing data" for name in access.names(element))
                         and access.find("Cancel", ("AXButton",), root=element)), None), process)
                    detail["dialog"] = access.names(dialog)
                    detail["cancel_button"] = "Cancel"
                screen.screenshot(output / ("-".join(label.lower().split()) + ".png"))
                if label == "Clear Browsing Data":
                    access.press(access.control("Cancel", ("AXButton",), root=dialog))
                results[label] = {"title": title, "profile": profile_name, "directory": directory.name,
                                  "space": space_name, "url": web_url(area), **detail}
                (output / "quick-links.json").write_text(json.dumps(results, indent=2) + "\n")
                screen.keys["w"] = 13
                screen.key("w", screen.command)
                wait_for(f"{label} tab did not close", lambda: all(
                    access.attribute(element, "AXRole") != "AXWebArea" or web_url(element) != expected_url
                    for element in access.tree(product)), process)
                if len(results) != len(links):
                    screen.key(",", screen.command)
                    wait_for("Settings did not return to the front",
                             lambda: access.attribute(access.application, "AXFocusedWindow") == settings, process)
            screen.key("q", screen.command)
            screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
        except Exception:
            access.dump(output / "quick-links-ax.json")
            raise

    return run_walk(__doc__, "profile-quick-links", peek["serve"], exercise,
                    prepare_fixture=prepare, official_qualification=True)


if __name__ == "__main__":
    sys.exit(main())
