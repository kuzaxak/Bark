#!/usr/bin/env python3
"""Open a legacy .nookspace file in signed Bark and check the imported model."""

from contextlib import contextmanager
import json
from pathlib import Path
import runpy
import sys
from uuid import uuid4

HERE = Path(__file__).resolve().parent
peek = runpy.run_path(str(HERE.parent / "ChromiumPeek/walk.py"))
from signed_walk import Accessibility, run_walk, wait_for


@contextmanager
def serve():
    with peek["serve"]() as server:
        server.html = "<title>Original Bark space</title><h1>Original Bark space</h1>"
        yield server


def read_model(root):
    tabs = root / "App/Tabs"
    structure, device = (json.loads((tabs / f"{name}.json").read_text())
                         for name in ("structure", "device"))
    return structure["spaces"], structure["items"] + device["items"], device["state"]


def main():
    root = file = None
    original = source = None
    name = "Imported legacy space"
    legacy_identity = "synthetic-old-cloud-identity"
    legacy_share = "synthetic-old-share"
    legacy_cursor = "synthetic-old-cursor"

    def prepare(data_root, origin, _candidate, _profile):
        nonlocal root, file, original, source
        root = data_root
        original = read_model(root)
        identifiers = [str(uuid4()).upper() for _ in range(4)]
        source = {
            "format": "nook.space", "version": 1, "exportedAt": "2026-05-01T08:00:00Z",
            "appVersion": "1.4", "enabled": True, "account": legacy_identity,
            "share": legacy_share, "engine": legacy_cursor,
            "space": {
                "id": identifiers[0], "name": name, "icon": "folder", "accentHex": "#225588",
                "dataStoreID": str(uuid4()).upper(), "share": legacy_share, "syncLevel": "everything",
                "favorites": [],
                "pinned": [{"id": identifiers[1], "kind": "folder", "title": "Imported folder", "children": [
                    {"id": identifiers[2], "kind": "tab", "title": "Imported tab", "url": origin + "/pinned",
                     "children": [], "cloudAccount": legacy_identity},
                ]}],
                "tabs": [{"id": identifiers[3], "kind": "tab", "title": "Unsafe local tab",
                          "url": "file:///private/tmp/not-imported.html", "children": []}],
            },
        }
        file = root / "Original export.nookspace"
        file.write_text(json.dumps(source) + "\n")
        legacy_store = root / "App/Sync/iCloud.ee.qdo.nook/spaces.json"
        legacy_store.parent.mkdir(parents=True)
        legacy_store.write_text(json.dumps({"enabled": True, "account": legacy_identity}) + "\n")

    def exercise(screen, proc, _events, output):
        access = Accessibility(screen, proc)
        try:
            perform_import(screen, proc, access, output)
        except Exception:
            access.dump(output / "accessibility.json")
            raise

    def perform_import(screen, proc, access, output):
        before = file.read_bytes()
        legacy_store = root / "App/Sync/iCloud.ee.qdo.nook/spaces.json"
        legacy_store_before = legacy_store.read_bytes()
        access.control("Original Bark space", ("AXWindow",))
        screen.keys.update({",": 43, "g": 5})
        screen.key(",", screen.command)
        access.press(access.control("Spaces", ("AXButton",)))
        access.press(access.control("Import Space…", ("AXButton",)))
        access.control("Import", ("AXButton",))
        screen.key("g", screen.command | screen.shift)

        def path_field():
            field = access.attribute(access.application, "AXFocusedUIElement")
            return field if access.attribute(field, "AXRole") in ("AXTextField", "AXComboBox") else None

        field = wait_for("The open panel did not offer Go to Folder", path_field, proc)
        screen.guard()
        if access.ax.AXUIElementSetAttributeValue(field, "AXValue", str(file)) != 0:
            screen.key(str(file), unicode=True)
        screen.key("Return")

        def enabled_import():
            button = access.find("Import", ("AXButton",))
            return button if access.attribute(button, "AXEnabled") else None

        access.press(wait_for("The file was not selected in the open panel", enabled_import, proc))
        request = access.control(f"Import “{name}”", ("AXStaticText",))
        # Scope actions to the actual import alert, not the settings window.
        sheet = access.attribute(request, "AXParent")
        while sheet is not None and access.attribute(sheet, "AXRole") not in {"AXSheet", "AXWindow"}:
            sheet = access.attribute(sheet, "AXParent")
        if sheet is None:
            raise RuntimeError("The import request had no candidate-owned sheet")
        access.press(access.control("Import", ("AXButton",), root=sheet))
        window = wait_for("The signed app did not confirm the import",
                          lambda: access.owner(f"Imported “{name}”", ("AXStaticText",)), proc)
        screen.screenshot(output / "imported.png", include_owned_windows=True)

        def imported():
            spaces, items, state = read_model(root)
            space = next((item for item in spaces if item["name"] == name), None)
            folder = next((item for item in items if item.get("customTitle") == "Imported folder"), None)
            tab = next((item for item in items
                        if item.get("kind", {}).get("tab", {}).get("pageTitle") == "Imported tab"), None)
            return (spaces, items, state, space, folder, tab) if space and folder and tab else None

        spaces, items, state, space, folder, tab = wait_for("Imported space and its items were not saved", imported, proc)
        old_spaces, old_items, old_state = original
        ids = {space["id"], folder["id"], tab["id"]}
        old_ids = {source["space"]["id"], source["space"]["pinned"][0]["id"],
                   source["space"]["pinned"][0]["children"][0]["id"]}
        if len(ids) != 3 or ids & old_ids:
            raise RuntimeError("Import did not allocate independent identifiers")
        if space["dataStoreID"] != old_spaces[0]["id"] or space["order"] <= old_spaces[0]["order"]:
            raise RuntimeError("Import did not append the space in the selected profile")
        if folder["parent"] != {"pinned": {"spaceID": space["id"]}} or tab["parent"] != {"folder": {"itemID": folder["id"]}}:
            raise RuntimeError("Import did not preserve the folder and pinned tab structure")
        if any(item.get("kind", {}).get("tab", {}).get("url", "").startswith("file:") for item in items):
            raise RuntimeError("Import kept a non-web URL")
        if not all(record in spaces for record in old_spaces):
            raise RuntimeError("Import changed an existing space")
        existing_owners = {item["id"]: item["parent"] for item in old_items}
        if {item["id"]: item["parent"] for item in items if item["id"] in existing_owners} != existing_owners:
            raise RuntimeError("Import changed existing item ownership")
        if state["windows"][0]["spaceID"] != old_state["windows"][0]["spaceID"]:
            raise RuntimeError("Import changed the open window's selected space")
        if (file.read_bytes() != before or legacy_store.read_bytes() != legacy_store_before
                or (root / "App/Sync/iCloud.ee.qdo.bark").exists()
                or any(marker in json.dumps([spaces, items, state]) for marker in (legacy_identity, legacy_share, legacy_cursor))):
            raise RuntimeError("Import changed the source file or restored old sync state")
        (output / "import.json").write_text(json.dumps({
            "source_unchanged": True, "legacy_store_unchanged": True, "profile": space["dataStoreID"], "imported_ids": sorted(ids),
            "selected_space_unchanged": True, "sync_store_created": False, "legacy_fields_restored": False,
        }, indent=2) + "\n")
        access.press(access.control("OK", ("AXButton",), root=window))
        wait_for("Import confirmation did not close", lambda: access.find(f"Imported “{name}”") is None, proc)
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), proc))
        print("Opened a legacy .nookspace, kept the original, and created a fresh local space", flush=True)

    return run_walk(__doc__, "space-file", serve, exercise, prepare_fixture=prepare, official_qualification=True)


if __name__ == "__main__":
    sys.exit(main())
