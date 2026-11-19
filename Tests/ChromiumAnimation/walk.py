#!/usr/bin/env python3
"""Verify a parked Bark document stops animating and resumes without losing its draft."""

from contextlib import contextmanager
from http.server import ThreadingHTTPServer
import json
from pathlib import Path
import runpy
import sys
from threading import Event, Thread
import time

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "Shared"))
from signed_walk import Accessibility, run_walk, wait_for

startup = runpy.run_path(str(HERE.parent / "ChromiumStartup/walk.py"))
source_point = startup["source_point"]
HIDDEN_SECONDS = 1.5


peek = startup["peek_fixture"]


class Fixture(peek["Fixture"]):
    def do_GET(self):
        if self.path == "/navigate-while-hidden":
            self.server.navigation_requested.set()
            if not self.server.release_navigation.wait(timeout=15):
                self.send_error(408)
                return
            self.send_response(204)
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            return
        if self.path in ("/target?parked-navigation=1", "/target?background-created=1"):
            self.path = "/target"
        super().do_GET()


@contextmanager
def serve():
    with ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.html = (Path(peek["HERE"]) / "fixture.html").read_text() + (HERE / "animation.html").read_text()
        server.events = []
        server.navigation_requested = Event()
        server.release_navigation = Event()
        thread = Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            yield server
        finally:
            server.release_navigation.set()
            server.shutdown()
            thread.join()


def main():
    check_split = False
    server = None

    @contextmanager
    def fixture():
        nonlocal server
        with serve() as current:
            server = current
            yield current

    def options(parser):
        nonlocal check_split
        parser.add_argument("--split", action="store_true",
                            help="also require both visible split panes to animate while the earlier tab is parked")
        args = parser.parse_args()
        check_split = args.split
        return args

    def exercise(screen, process, events, output):
        access = Accessibility(screen, process)

        def event(name, since=0, *, minimum_frames=0, **facts):
            return wait_for(f"Missing {name} {facts}", lambda: next(
                (row for row in events[since:] if row["event"] == name and row.get("frames", 0) >= minimum_frames
                 and all(row.get(key) == value for key, value in facts.items())), None), process)

        def advancing(document, since, before):
            return event("animation-visible", since, minimum_frames=before["frames"] + 12,
                         documentID=document, visibility="visible")

        screen.keys.update({"1": 18, "2": 19})
        try:
            source = event("ready", page="/source", wasDiscarded=False)
            document = source["documentID"]
            visible = event("animation-visible", documentID=document, visibility="visible")
            wait_for("The seeded window did not reach its saved size",
                     lambda: any(row["kCGWindowBounds"]["Width"] == 900 for row in screen.windows()), process)
            screen.click(source_point(source, "draftPoint"))
            event("pointer", documentID=document, trusted=True)
            draft = "animation draft"
            screen.key(draft, unicode=True)
            event("input", documentID=document, value=draft, trusted=True)

            before_switch = len(events)
            screen.key("2", screen.command)
            hidden = event("animation-hidden", before_switch, documentID=document,
                           visibility="hidden", value=draft, wasDiscarded=False)
            target = event("ready", page="/target")
            target_id = target["documentID"]
            alternate = event("animation-visible", before_switch, documentID=target_id, visibility="visible")
            siblings = {}
            if check_split:
                before_peek = len(events)
                screen.click(source_point(target, "linkPoint"), screen.shift)
                event("link", before_peek, documentID=target_id, trusted=True, shift=True)
                sibling = event("ready", before_peek, page="/target")
                sibling_id = sibling["documentID"]
                if sibling_id == target_id:
                    raise RuntimeError("Peek did not create an independent sibling document")
                add = wait_for("Missing Peek split action", lambda: screen.button("Open in Split View"), process)
                before_split = len(events)
                screen.press_button(add)
                wait_for("The sibling did not enter the split",
                         lambda: screen.button("Open in Split View") is None, process)
                pane = event("resize", before_split, documentID=target_id)
                if pane["viewport"] >= target["viewport"] or len(screen.windows()) != 1:
                    raise RuntimeError("The two documents did not share the original split window")
                sibling_before = event("animation-visible", before_split, documentID=sibling_id, visibility="visible")
                siblings[sibling_id] = sibling_before
                alternate = advancing(target_id, before_split, alternate)

            # The host measures the hold and the visible sibling(s) provide a
            # positive control throughout. No hidden-page timer or polling.
            held = time.monotonic() + HIDDEN_SECONDS
            wait_for("The parked interval did not elapse", lambda: time.monotonic() >= held, process,
                     timeout=HIDDEN_SECONDS + 2)
            after_hold = len(events)
            advance = advancing(target_id, after_hold, alternate)
            split_frames = {sibling_id: [initial["frames"], advancing(sibling_id, after_hold, initial)["frames"]]
                            for sibling_id, initial in siblings.items()}

            before_return = len(events)
            screen.key("1", screen.command)
            returned = event("animation-returned", before_return, documentID=document,
                             period=hidden["period"], visibility="visible", value=draft, wasDiscarded=False)
            if (returned["durationMs"] < HIDDEN_SECONDS * 1000 or returned["lateFrames"] != 0
                    or returned["frames"] - hidden["frames"] != returned["hiddenFrames"]):
                raise RuntimeError(f"Parked animation did not stop: {returned}")
            resumed = advancing(document, before_return, returned)
            screen.key("s")
            event("input", before_return, documentID=document, value=draft + "s", trusted=True, wasDiscarded=False)
            if sum(row["page"] == "/source" and row["event"] == "ready" for row in events) != 1:
                raise RuntimeError("Returning to the animated page created a new document")
            # Only after proving the original draft survives a normal return,
            # park it again and release a loopback response to its hidden page.
            before_navigation = len(events)
            screen.key("2", screen.command)
            event("animation-hidden", before_navigation, documentID=document, period=hidden["period"] + 1,
                  visibility="hidden", value=draft + "s", wasDiscarded=False)
            wait_for("The parked source did not request navigation", server.navigation_requested.is_set, process)
            server.release_navigation.set()
            navigated = event("parked-navigation-started", before_navigation, page="/target",
                              visibility="hidden", wasDiscarded=False)
            new_document = navigated["documentID"]
            if new_document in {document, target_id, *siblings}:
                raise RuntimeError("The parked navigation did not create a distinct document")
            def verify_initial_hidden(initial, positive_id, reveal):
                since = len(events)
                positive = event("animation-visible", since, documentID=positive_id, visibility="visible")
                held_until = time.monotonic() + HIDDEN_SECONDS
                wait_for("The initially hidden interval did not elapse",
                         lambda: time.monotonic() >= held_until, process, timeout=HIDDEN_SECONDS + 2)
                advancing(positive_id, len(events), positive)
                before_reveal = len(events)
                reveal()
                revealed = event("animation-returned", before_reveal, documentID=initial["documentID"],
                                 period=initial["period"], visibility="visible", wasDiscarded=False)
                if (revealed["durationMs"] < HIDDEN_SECONDS * 1000 or revealed["lateFrames"] != 0
                        or revealed["frames"] - initial["frames"] != revealed["hiddenFrames"]):
                    raise RuntimeError(f"Initially hidden animation did not stop: {revealed}")
                sample = advancing(initial["documentID"], before_reveal, revealed)
                return revealed, sample

            navigation_revealed, navigation_visible = verify_initial_hidden(navigated, target_id,
                                                        lambda: screen.key("1", screen.command))

            def select_new_background():
                row = access.control("Background animation fixture")
                x, y = access.center(row)
                bounds = screen.windows()[0]["kCGWindowBounds"]
                screen.click((x - bounds["X"], y - bounds["Y"]))

            before_creation = len(events)
            screen.click(source_point(navigation_visible, "linkPoint"), screen.command)
            event("background-link", before_creation, documentID=new_document, trusted=True, command=True)
            background = event("background-creation-started", before_creation, page="/target",
                               visibility="hidden", wasDiscarded=False)
            if background["documentID"] in {document, target_id, new_document, *siblings}:
                raise RuntimeError("The background link did not create a distinct document")
            background_revealed, _ = verify_initial_hidden(background, new_document, select_new_background)
            (output / "animation.json").write_text(json.dumps({
                "document_id": document,
                "draft_still_editable": True,
                "visible_frames_before_parking": visible["frames"],
                "hidden_duration_ms": returned["durationMs"],
                "hidden_grace_ms": returned["graceMs"],
                "frames_during_hidden_grace": returned["hiddenFrames"],
                "frames_after_hidden_grace": returned["lateFrames"],
                "alternate_visible_frames": [alternate["frames"], advance["frames"]],
                "split_sibling_visible_frames": split_frames,
                "frames_after_return": resumed["frames"] - returned["frames"],
                "parked_navigation_document_id": new_document,
                "parked_navigation_initial_visibility": navigated["visibility"],
                "parked_navigation_late_frames": navigation_revealed["lateFrames"],
                "background_creation_document_id": background["documentID"],
                "background_creation_initial_visibility": background["visibility"],
                "background_creation_late_frames": background_revealed["lateFrames"],
            }, indent=2) + "\n")
            screen.key("q", screen.command)
            screen.press_button(wait_for("Missing Quit confirmation", lambda: screen.button("Quit"), process))
        except Exception:
            access.dump(output / "accessibility.json")
            raise

    return run_walk(__doc__, "parked-animation", fixture, exercise,
                    [("settings.peekOnShiftClick", "-bool", "true")],
                    prepare_fixture=startup["prepare_fixture"], parse_options=options, official_qualification=True)


if __name__ == "__main__":
    sys.exit(main())
