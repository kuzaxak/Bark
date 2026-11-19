#!/usr/bin/env python3
"""Check signed Bark profile storage across shared spaces, profile rename and relaunch."""

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
        server.html = (HERE / "storage.html").read_text()
        yield server


def main():
    fixture = {}

    def prepare(root, origin, _app, source):
        fixtures = {name: str(uuid4()).upper() for name in ("work", "personal", "desk", "home")}
        fixtures.update(root=root, origin=origin, office=source)
        fixture.update(fixtures)
        directory = root / "App/Tabs"
        structure_path = directory / "structure.json"
        device_path = directory / "device.json"
        structure = json.loads(structure_path.read_text())
        device = json.loads(device_path.read_text())
        office = structure["spaces"][0]
        office.update(name="Office", dataStoreID=fixture["work"], profileName="Work")
        tab = device["items"][0]
        tab["kind"]["tab"]["pageTitle"] = "Profile Storage Fixture"
        for name, profile, space, order in (("Desk", "work", "desk", "W"), ("Home", "personal", "home", "X")):
            structure["spaces"].append(dict(office, id=fixture[space], name=name, order=order,
                dataStoreID=fixture[profile], profileName=profile.title()))
            item = dict(tab, id=str(uuid4()).upper(), parent={"tabs": {"spaceID": fixture[space]}})
            location = "/target#home" if space == "home" else "/target"
            item["kind"] = {"tab": {"url": origin + location, "pageTitle": "Profile Storage Fixture"}}
            device["items"].append(item)
            device["state"]["windows"][0]["selectedItemBySpace"] += [fixture[space], item["id"]]
        structure_path.write_text(json.dumps(structure) + "\n")
        device_path.write_text(json.dumps(device) + "\n")

    def exercise(screen, process, events, output, *, after_rename=False):
        access = Accessibility(screen, process)
        screen.keys.update({",": 43, "a": 0})

        def selected(name):
            return access.find(name, ("AXMenuButton",)) is not None

        def click(element):
            x, y = access.center(element)
            bounds = screen.windows()[0]["kCGWindowBounds"]
            screen.click((x - bounds["X"], y - bounds["Y"]))

        def select(name):
            if not selected(name):
                click(access.control(name, ("AXButton",)))
            wait_for(f"{name} did not become the visible space", lambda: selected(name), process)

        def site_action(event, path, expected):
            layout_since = len(events)

            def layout():
                viewport = screen.windows()[0]["kCGWindowBounds"]["Width"] - peek["SIDEBAR_WIDTH"] - peek["PAGE_MARGIN"]
                return next((row for row in reversed(events[layout_since:]) if row["event"] == "layout"
                             and row["page"] == path and row["visibility"] == "visible"
                             and row["viewport"] == viewport), None)
            page = wait_for(f"Missing settled viewport for {path}", layout, process)
            since = len(events)
            screen.click(peek["source_point"]({"point": page["points"][event]}, "point"))
            observed = wait_for(f"No trusted site storage report for {event}", lambda: next(
                (row for row in events[since:] if row["event"] == event
                 and row["documentID"] == page["documentID"] and row["page"] == path and row["origin"] == fixture["origin"]
                 and row["visibility"] == "visible"), None), process)
            if (observed["local"], observed["cookie"]) != (expected, expected):
                raise RuntimeError(f"Unexpected synthetic storage for {path}: {observed}")
            return observed

        def read(path, marker):
            return site_action("read", path, marker)

        def directories():
            engine = fixture["root"] / "Engine"
            found = {item.name: item.stat().st_ino for item in engine.glob("Barc-*") if item.is_dir()}
            expected = {"Barc-" + fixture[profile].lower() for profile in ("work", "personal")}
            if set(found) != expected:
                raise RuntimeError(f"Unexpected disposable profile directories: {found}")
            return found

        try:
            select("Office")
            result = {}
            if after_rename:
                result["office"] = read("/source", "work")
                select("Desk")
                result["desk"] = read("/target", "work")
                select("Home")
                result["home"] = read("/target#home", "personal")
                for name in ("office", "desk", "home"):
                    if result[name]["documentID"] == fixture["documents"][name]:
                        raise RuntimeError(f"{name} did not load a new document after relaunch")
                result["directories"] = directories()
                if result["directories"] != fixture["directories"]:
                    raise RuntimeError("Profile directories moved across rename or relaunch")
                structure = json.loads((fixture["root"] / "App/Tabs/structure.json").read_text())
                spaces = {space["name"]: space for space in structure["spaces"]}
                for name in ("Office", "Desk"):
                    space = spaces[name]
                    if space["dataStoreID"].upper() != fixture["work"] or space["profileName"] != "Renamed Work":
                        raise RuntimeError(f"{name} lost its shared UUID or the renamed profile label")
            else:
                result["office"] = site_action("work", "/source", "work")
                select("Desk")
                result["desk"] = read("/target", "work")
                if result["office"]["documentID"] == result["desk"]["documentID"]:
                    raise RuntimeError("The two shared spaces did not mount distinct documents")
                select("Home")
                result["homeBefore"] = read("/target#home", None)
                result["home"] = site_action("personal", "/target#home", "personal")
                if result["desk"]["documentID"] == result["home"]["documentID"]:
                    raise RuntimeError("The isolated profile reused the other profile's document")
                fixture["directories"] = result["directories"] = directories()
                fixture["documents"] = {name: result[name]["documentID"] for name in ("office", "desk", "home")}
                select("Office")
                read("/source", "work")

                screen.key(",", screen.command)
                settings = wait_for("Settings did not open", lambda: access.owner("Privacy", ("AXButton",)), process)
                access.press(access.control("Privacy", ("AXButton",), root=settings))
                access.press(access.control("Open Profiles", ("AXButton",), root=settings))
                field = access.control("Work", ("AXTextField",), root=settings)
                click(field)
                screen.key("a", screen.command)
                screen.key("Renamed Work", unicode=True)
                screen.key("Return")
                access.control("Renamed Work", ("AXTextField",), root=settings)
                access.press(access.attribute(settings, "AXCloseButton"))
                read("/source", "work")
                if directories() != fixture["directories"]:
                    raise RuntimeError("Profile directories moved when changing the name")
            (output / ("storage-relaunched.json" if after_rename else "storage-initial.json")).write_text(
                json.dumps(result, indent=2) + "\n"
            )
            screen.key("q", screen.command)
            screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
        except Exception:
            access.dump(output / ("storage-relaunch-ax.json" if after_rename else "storage-ax.json"))
            raise

    def relaunch(*args):
        exercise(*args, after_rename=True)

    return run_walk(__doc__, "profile-storage", serve, exercise, prepare_fixture=prepare,
                    relaunch=relaunch, official_qualification=True)


if __name__ == "__main__":
    sys.exit(main())
