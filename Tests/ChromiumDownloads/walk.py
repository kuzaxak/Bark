#!/usr/bin/env python3
"""Verify signed Bark downloads, cancellation, and restored sidebar history."""

from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import json
from pathlib import Path
import select
import sys
from threading import Event, Thread

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

HELD = "bark-held-fixture.txt"
COMPLETE = "bark-complete-fixture.txt"
PAYLOAD = b"Signed Bark loopback attachment.\n"
TITLE = "Bark download fixture"


class Fixture(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        if self.path == "/source":
            mime = "text/html"
            body = f"""<!doctype html><title>{TITLE}</title>
                      <p><a href="/held">Start held attachment</a></p>
                      <p><a href="/complete">Download complete attachment</a></p>""".encode()
        elif self.path in ("/held", "/complete"):
            mime = "text/plain"
            body = PAYLOAD if self.path == "/complete" else PAYLOAD * 1024
        else:
            self.send_error(404)
            return
        self.send_response(200)
        self.send_header("Content-Type", mime)
        if self.path in ("/held", "/complete"):
            filename = HELD if self.path == "/held" else COMPLETE
            self.send_header("Content-Disposition", f'attachment; filename="{filename}"')
        self.send_header("Content-Length", str(len(body) if self.path != "/held" else 1 << 20))
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        self.wfile.write(body)
        self.wfile.flush()
        self.server.events.append(self.path)
        if self.path == "/held":
            # Keep the body incomplete until Chromium cancels the transport.
            while not self.server.stopped.is_set():
                if select.select([self.connection], [], [], .15)[0]:
                    if not self.connection.recv(1):
                        self.server.events.append("held connection closed")
                        break
            self.close_connection = True


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.events = []
        server.stopped = Event()
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.stopped.set()
            server.shutdown()
            thread.join()


def fixture_preferences(root, profile, prompt):
    directory = root / "download-target"
    directory.mkdir(mode=0o700)
    prefs = root / "Engine" / f"Barc-{profile.lower()}" / "Preferences"
    prefs.parent.mkdir(parents=True)
    prefs.write_text(json.dumps({
        "download": {"default_directory": str(directory), "directory_upgrade": True,
                     "prompt_for_download": prompt},
        "savefile": {"default_directory": str(directory)},
    }))
    return directory, prefs


def main():
    fixture = {}
    save_as = False

    def parse_options(parser):
        nonlocal save_as
        parser.allow_abbrev = False
        parser.add_argument("--save-as", action="store_true",
                            help="choose a different disposable download destination in the native panel")
        args = parser.parse_args()
        save_as = args.save_as
        return args

    def prepare(root, _origin, _app, profile):
        fixture["directory"], fixture["prefs"] = fixture_preferences(root, profile, prompt=save_as)
        if save_as:
            alternate = root / "alternate-target"
            alternate.mkdir(mode=0o700)
            fixture["alternate"] = alternate

    def verify_target():
        target = fixture["directory"]
        prefs = json.loads(fixture["prefs"].read_text())
        if (prefs["download"]["default_directory"] != str(target)
                or prefs["download"]["prompt_for_download"] is not save_as
                or target.is_symlink() or not target.is_dir()):
            raise RuntimeError("The disposable Chromium download directory changed")
        return target

    def click_control(screen, access, element):
        x, y = access.center(element)
        bounds = screen.windows()[0]["kCGWindowBounds"]
        screen.click((x - bounds["X"], y - bounds["Y"]))

    def row(access, label, status):
        cell = access.find(label, ("AXStaticText",))
        for _ in range(4):
            if cell is None or access.attribute(cell, "AXRole") == "AXWindow":
                return None
            if any(name.startswith(status + " •") for element in access.tree(cell)
                   for name in access.names(element)):
                return cell
            cell = access.attribute(cell, "AXParent")
        return None

    def show_downloads(access):
        access.menu("Downloads")

    def quit_app(screen, process):
        screen.key("q", screen.command)
        screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))

    def exercise(screen, process, events, output):
        target = verify_target()
        access = Accessibility(screen, process)
        try:
            wait_for("Initial loopback page not served", lambda: "/source" in events, process)
            wait_for("Initial download fixture window not ready", lambda: access.owner(TITLE), process)
            screen.guard()
            screen.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
            click_control(screen, access, access.control("Start held attachment", ("AXLink",)))
            wait_for("Browser did not request held attachment", lambda: "/held" in events, process)
            show_downloads(access)
            item = wait_for("Held attachment did not appear as Downloading",
                            lambda: row(access, HELD, "Downloading"), process)
            access.hover(access.control(HELD, ("AXStaticText",), root=item))
            menu = wait_for("Held download row has no action menu", lambda: next(
                (element for element in access.tree(row(access, HELD, "Downloading"))
                 if access.attribute(element, "AXRole") == "AXMenuButton"), None), process)
            click_control(screen, access, menu)
            cancel = wait_for("Missing Cancel Download", lambda:
                access.find("Cancel Download", ("AXMenuItem",), root=menu) or
                access.find("Cancel Download", ("AXMenuItem",), root=access.application), process)
            access.press(cancel)
            wait_for("Sidebar did not report the held attachment as cancelled",
                     lambda: row(access, HELD, "Cancelled"), process)
            wait_for("The held attachment stream did not terminate",
                     lambda: "held connection closed" in events, process)
            if (target / HELD).exists():
                raise RuntimeError("Cancellation left a completed file")

            access.press(access.control("Back", ("AXButton",)))
            wait_for("Downloads sidebar did not dismiss", lambda: not access.find("Back", ("AXButton",)), process)
            click_control(screen, access, access.control("Download complete attachment", ("AXLink",)))
            wait_for("Browser did not request completed attachment", lambda: "/complete" in events, process)
            downloaded = target / COMPLETE
            wait_for("Completed attachment did not appear in the disposable directory", downloaded.is_file, process)
            if downloaded.is_symlink() or downloaded.read_bytes() != PAYLOAD:
                raise RuntimeError("Completed attachment did not match its exact name and bytes")
            if not row(access, COMPLETE, "Completed"):
                show_downloads(access)
            wait_for("Sidebar did not report the completed attachment",
                     lambda: row(access, COMPLETE, "Completed"), process)
            screen.screenshot(output / "downloads.png")
            click_control(screen, access, access.control(COMPLETE, ("AXStaticText",)))
            close_preview = access.control("Close", ("AXButton",))
            access.control("Previous", ("AXButton",))
            access.control("Next", ("AXButton",))
            screen.screenshot(output / "download-preview.png", include_owned_windows=True)
            access.press(close_preview)
            wait_for("Download preview stayed open", lambda: not access.find("Close", ("AXButton",)), process)
            wait_for("The completed row was lost after closing its preview",
                     lambda: row(access, COMPLETE, "Completed"), process)
            quit_app(screen, process)
        except BaseException:
            access.dump(output / "downloads-ax.json")
            raise

    def save_as_exercise(screen, process, events, output):
        target = verify_target()
        alternate = fixture["alternate"]
        access = Accessibility(screen, process)
        screen.keys["g"] = 5
        wait_for("Initial loopback page not served", lambda: "/source" in events, process)
        wait_for("Initial download fixture window not ready", lambda: access.owner(TITLE), process)
        screen.guard()
        screen.ax.AXUIElementSetAttributeValue(access.application, "AXEnhancedUserInterface", True)
        click_control(screen, access, access.control("Download complete attachment", ("AXLink",)))
        wait_for("Browser did not request the Save As attachment", lambda: "/complete" in events, process)
        access.control("Save", ("AXButton",))

        def suggested_name():
            # macOS can hide the extension in the editable Save As field.
            return (access.find(COMPLETE, ("AXTextField",)) or
                    access.find(Path(COMPLETE).stem, ("AXTextField",)))

        name_field = wait_for("Save As did not suggest the fixture filename", suggested_name, process)
        screen.key("g", screen.command | screen.shift)

        def folder_field():
            field = access.attribute(access.application, "AXFocusedUIElement")
            return (field if field is not None and field != name_field
                    and access.attribute(field, "AXRole") in ("AXTextField", "AXComboBox") else None)

        field = wait_for("Save As did not open Go to Folder", folder_field, process)
        screen.guard()
        if access.ax.AXUIElementSetAttributeValue(field, "AXValue", str(alternate)) != 0:
            screen.key(str(alternate), unicode=True)
        screen.key("Return")

        # The folder picker must be gone and the original suggested name
        # present before committing the separate native Save action.
        wait_for("Save As did not retain the fixture filename", suggested_name, process)
        save = access.control("Save", ("AXButton",))
        access.press(save)
        wait_for("Save As panel did not dismiss", lambda: not access.find("Save", ("AXButton",)), process)
        downloaded = alternate / COMPLETE
        wait_for("The selected folder did not receive the attachment", downloaded.is_file, process)
        if downloaded.is_symlink() or downloaded.read_bytes() != PAYLOAD or list(target.iterdir()):
            raise RuntimeError("The selected destination did not exclusively receive the exact attachment")
        (output / "result.json").write_text(json.dumps({
            "suggested_filename": COMPLETE, "used_alternate_disposable_directory": True,
            "configured_default_directory_empty": True, "sha256": hashlib.sha256(PAYLOAD).hexdigest(),
        }, indent=2) + "\n")
        quit_app(screen, process)

    def relaunch(screen, process, _events, output):
        target = verify_target()
        access = Accessibility(screen, process)
        try:
            wait_for("Restored regular window missing", lambda: access.owner(TITLE), process)
            show_downloads(access)
            wait_for("Completed entry did not restore in the sidebar",
                     lambda: row(access, COMPLETE, "Completed"), process)
            wait_for("Cancelled entry did not restore in the sidebar",
                     lambda: row(access, HELD, "Cancelled"), process)
            if sorted(path.name for path in target.iterdir()) != [COMPLETE] or (target / COMPLETE).read_bytes() != PAYLOAD:
                raise RuntimeError("Relaunch did not retain exactly the completed fixture file")
            (output / "result.json").write_text(json.dumps({
                "completed": COMPLETE,
                "sha256": hashlib.sha256(PAYLOAD).hexdigest(),
                "cancelled": HELD,
                "sidebar_history_restored": True,
                "preview_returned_to_completed_row": True,
                "download_directory": "disposable Chromium profile target",
            }, indent=2) + "\n")
            screen.screenshot(output / "downloads-restored.png")
            quit_app(screen, process)
        except BaseException:
            access.dump(output / "restart-downloads-ax.json")
            raise

    def run_case(screen, process, events, output):
        action = save_as_exercise if save_as else exercise
        action(screen, process, events, output)

    # The alternate destination has no additional relaunch requirement.
    has_save_as = "--save-as" in sys.argv[1:]
    return run_walk(__doc__, "downloads", serve, run_case, prepare_fixture=prepare,
                    official_qualification=True, relaunch=None if has_save_as else relaunch,
                    parse_options=parse_options)


if __name__ == "__main__":
    sys.exit(main())
