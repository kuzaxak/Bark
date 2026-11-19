#!/usr/bin/env python3
"""Check duplicate folder paths and a single sidebar toggle in signed Bark."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
from pathlib import Path
import sys
from threading import Thread
from urllib.parse import urlsplit
from uuid import uuid4

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

SOURCE = "Folder walk source"
FOLDER = "Insly"
BRANCHES = ("Github", "Projects")
PATHS = {name: f"Work › QDO › Pinned › {name} › Nested 📁 › {FOLDER}" for name in BRANCHES}


class Fixture(BaseHTTPRequestHandler):
    def do_GET(self):
        path = urlsplit(self.path).path
        if path == "/source":
            body = f"<title>{SOURCE}</title><h1>{SOURCE}</h1><script>fetch('/ready')</script>".encode()
        elif path == "/ready":
            body = b""
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
        self.server.events.append(path)

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


def prepare(root, origin, _app, space):
    # Keep palette autocomplete local to the fixture profile.
    engine_profile = root / "Engine" / f"Barc-{space.lower()}"
    engine_profile.mkdir(parents=True)
    (engine_profile / "Preferences").write_text(json.dumps({"search": {"suggest_enabled": False}}) + "\n")
    path = root / "App/Tabs/structure.json"
    structure = json.loads(path.read_text())
    structure["spaces"][0].update(name="QDO", profileName="Work")
    modified = structure["spaces"][0]["modifiedAt"]

    def add(parent, kind, order, title):
        identifier = str(uuid4()).upper()
        structure["items"].append({"id": identifier, "parent": parent, "kind": kind, "order": order,
                                   "customTitle": title, "modifiedAt": modified})
        return {"folder": {"itemID": identifier}}

    for name, position in zip(BRANCHES, ("V", "W")):
        branch = add({"pinned": {"spaceID": space}}, {"folder": {}}, position, name)
        nested = add(branch, {"folder": {}}, "V", "Nested 📁")
        folder = add(nested, {"folder": {}}, "V", FOLDER)
        add(folder, {"tab": {"url": f"{origin}/source?branch={name}", "pageTitle": f"Only in {name}"}},
            "V", f"Only in {name}")
    path.write_text(json.dumps(structure) + "\n")


def click(screen, access, element):
    x, y = access.center(element)
    bounds = screen.windows()[0]["kCGWindowBounds"]
    screen.click((x - bounds["X"], y - bounds["Y"]))


def palette_rows(access):
    focused = access.attribute(access.application, "AXFocusedUIElement")
    palette = access.attribute(focused, "AXParent")
    if palette is None:
        return None
    rows = {}
    for node in access.tree(palette):
        for label in access.names(node):
            for name, path in PATHS.items():
                if label.startswith(f"{FOLDER}, {path},"):
                    rows[name] = (node, label)
    return rows if rows.keys() == PATHS.keys() else None


def folder_control(access, source, state):
    nodes = [node for node in access.tree(source)
             if access.attribute(node, "AXValue") in ("Expanded", "Collapsed")
             and any(label.partition(",")[0] == FOLDER for label in access.names(node))]
    if len(nodes) != 1:
        return None
    node = nodes[0]
    if (access.attribute(node, "AXRole") not in ("AXButton", "AXMenuButton")
            or access.attribute(node, "AXValue") != state):
        return None
    return node


def require_single_toggle_hit(access, row):
    x, y = access.center(row)
    ref = access.attribute(row, "AXSize")
    if ref is None:
        raise RuntimeError("Missing the folder control’s accessibility size")
    ok, size = access.ax.AXValueGetValue(ref, access.ax.kAXValueCGSizeType, None)
    if not ok or size.width <= 0:
        raise RuntimeError("The folder control has no visible width")
    # The leading icon area and text area must resolve to the same actionable
    # row. A second chevron control would introduce a second AX action here.
    for relative_x in (0.1, 0.5):
        hit_x = x + (relative_x - 0.5) * size.width
        status, hit = access.ax.AXUIElementCopyElementAtPosition(access.application, hit_x, y, None)
        if status:
            raise RuntimeError("The folder control could not be hit-tested")
        while hit is not None and hit != row:
            status, actions = access.ax.AXUIElementCopyActionNames(hit, None)
            if not status and "AXPress" in (actions or ()):
                raise RuntimeError("The folder row has a second actionable toggle surface")
            hit = access.attribute(hit, "AXParent")
        if hit != row:
            raise RuntimeError("The folder icon and label do not share a hit target")


def exercise(screen, process, events, output):
    access = Accessibility(screen, process)
    try:
        wait_for("The loopback page did not load", lambda: "/ready" in events, process, timeout=30)
        screen.guard()
        access.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        source = wait_for("The source window did not appear", lambda: access.owner(SOURCE), process)
        screen.keys.update({"t": 17, "i": 34, "n": 45, "s": 1, "l": 37, "y": 16})
        screen.key("t", screen.command)
        wait_for("The command palette did not take text focus", lambda: access.attribute(
            access.attribute(access.application, "AXFocusedUIElement"), "AXRole") == "AXTextField", process)
        for letter in FOLDER.lower():
            screen.key(letter)
        rows = wait_for("The palette did not expose both full folder paths",
                        lambda: palette_rows(access), process)
        screen.screenshot(output / "search.png", include_owned_windows=True)
        selected = BRANCHES[1]
        click(screen, access, rows[selected][0])

        def chosen_child():
            return access.find(f"Only in {selected}", root=source)

        expanded = wait_for("The selected branch did not reveal its child and one expanded folder control",
                            lambda: chosen_child() and not access.find(f"Only in {BRANCHES[0]}", root=source)
                            and folder_control(access, source, "Expanded"), process)
        states = [access.attribute(expanded, "AXValue")]
        require_single_toggle_hit(access, expanded)
        screen.screenshot(output / "expanded.png", include_owned_windows=True)
        click(screen, access, expanded)
        collapsed = wait_for("The same folder did not hide its child and expose one collapsed control",
                             lambda: not chosen_child() and folder_control(access, source, "Collapsed"), process)
        states.append(access.attribute(collapsed, "AXValue"))
        require_single_toggle_hit(access, collapsed)
        screen.screenshot(output / "collapsed.png", include_owned_windows=True)
        click(screen, access, collapsed)
        reopened = wait_for("Reopening the folder did not restore the exact selected child",
                            lambda: chosen_child() and not access.find(f"Only in {BRANCHES[0]}", root=source)
                            and folder_control(access, source, "Expanded"), process)
        states.append(access.attribute(reopened, "AXValue"))
        (output / "folders.json").write_text(json.dumps({
            "presented_labels": [rows[name][1] for name in BRANCHES],
            "selected_label": rows[selected][1],
            "selected_child": access.names(chosen_child()),
            "unique_folder_control_states": states,
        }, ensure_ascii=False, indent=2) + "\n")
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
    except BaseException:
        access.dump(output / "accessibility.json")
        raise


if __name__ == "__main__":
    sys.exit(run_walk(__doc__, "folder-paths", serve, exercise, prepare_fixture=prepare,
                      official_qualification=True))
