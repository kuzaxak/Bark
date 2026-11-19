#!/usr/bin/env python3
"""Open Chromium quick links for a profile with no spaces in signed Bark."""

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

    def prepare(root, _origin, _app, _profile):
        fixture["id"] = str(uuid4()).upper()
        fixture["engine"] = root / "Engine"
        path = root / "App/Tabs/device.json"
        device = json.loads(path.read_text())
        device["state"].setdefault("keptProfiles", []).append({"id": fixture["id"], "name": profile_name})
        path.write_text(json.dumps(device) + "\n")

    def exercise(screen, process, _events, output):
        access = Accessibility(screen, process)
        screen.keys[","] = 43
        links = {
            "Open Profile Settings": ("Settings", "chrome://settings/"),
            "Extensions": ("Extensions", "chrome://extensions/"),
            "Privacy and Security": ("Settings - Privacy and security", "chrome://settings/privacy"),
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
            if directory.exists():
                raise RuntimeError("The no-space profile was already open before its first quick link")
            def web_url(element):
                url = access.attribute(element, "AXURL")
                return str(url.absoluteString()) if url else None

            for label, (title, expected_url) in links.items():
                access.press(access.control(label, ("AXButton",), root=settings))
                utility = wait_for(f"{label} did not open an owned utility",
                                   lambda: access.owner("Close Window", ("AXButton",)), process)
                access.control(profile_name, root=utility)
                wait_for("The no-space profile's Chromium directory was not created",
                         lambda: directory.is_dir(), process)
                access.control(title, ("AXStaticText",), root=utility)
                area = wait_for(f"{label} did not open {expected_url}", lambda: next(
                    (element for element in access.tree(utility)
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
                results[label] = {"title": title, "profile": profile_name, "directory": directory.name,
                                  "url": web_url(area), **detail}
                (output / "quick-links.json").write_text(json.dumps(results, indent=2) + "\n")
                access.press(access.control("Close Window", ("AXButton",), root=utility))
                wait_for("Utility window did not close",
                         lambda: access.owner("Close Window", ("AXButton",)) is None, process)
            screen.key("q", screen.command)
            screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
        except Exception:
            access.dump(output / "quick-links-ax.json")
            raise

    return run_walk(__doc__, "profile-quick-links", peek["serve"], exercise,
                    prepare_fixture=prepare, official_qualification=True)


if __name__ == "__main__":
    sys.exit(main())
