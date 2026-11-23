"""Offline checks for the signed walk's native-architecture preflight."""

from contextlib import ExitStack, contextmanager, nullcontext, redirect_stdout
import io
import json
import math
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch

import signed_walk
from signed_walk import REPO, Screen, ScreenUnavailable, verify_native_candidate


@contextmanager
def refused_name_lookups():
    with ExitStack() as stack:
        for name in ("getfqdn", "gethostbyaddr", "gethostbyname", "gethostbyname_ex", "gethostname", "getnameinfo"):
            stack.enter_context(patch(f"socket.{name}", side_effect=AssertionError(f"socket.{name} was called")))
        yield


class InputOwnershipTests(unittest.TestCase):
    def test_rebuilt_app_is_rejected_before_launch(self):
        lock = runpy.run_path(str(REPO / "scripts/bark-check.py"))["app_output_lock"]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(signed_walk, "bundle_cdhash", return_value="new-build"), \
                    patch.object(subprocess, "Popen") as start, self.assertRaisesRegex(RuntimeError, "changed"):
                signed_walk.launch_verified(root / "Bark.app", "verified-build", root, "fixture", None, lock)
            start.assert_not_called()

    def test_pointer_interruption_and_missed_post_stop_before_further_input(self):
        screen = Screen.__new__(Screen)
        screen.owns_screen = lambda: True
        screen.console = Mock()
        screen.console.pointer.return_value = (1400, 450)
        screen.point = (428, 453)
        with self.assertRaisesRegex(ScreenUnavailable, "between test inputs"):
            screen.key("q")
        with self.assertRaisesRegex(RuntimeError, "Posted pointer event missed"):
            screen.guard(target=(420, 450))


class ClickDiagnosticsTests(unittest.TestCase):
    def failed_click(self, *, lock_lost=False, covered=False, cursor=False, shown_after=0.0, private=False):
        pid = 4321
        banner = {"kCGWindowOwnerName": "NotificationCenter", "kCGWindowOwnerPID": 99, "kCGWindowLayer": 23,
                  "kCGWindowNumber": 12, "kCGWindowBounds": {"X": 380, "Y": 150, "Width": 360, "Height": 80}}
        target = {"kCGWindowOwnerName": "Bark", "kCGWindowOwnerPID": pid, "kCGWindowLayer": 0, "kCGWindowNumber": 40,
                  "kCGWindowName": "Peek fixture source", "kCGWindowBounds": {"X": 50, "Y": 40, "Width": 900, "Height": 660}}
        rows = [
            {"kCGWindowOwnerName": "Dock", "kCGWindowOwnerPID": 77, "kCGWindowLayer": 20, "kCGWindowNumber": 3,
             "kCGWindowBounds": {"X": 0, "Y": 0, "Width": 1440, "Height": 900}},
            {"kCGWindowOwnerName": "Bark", "kCGWindowOwnerPID": pid, "kCGWindowLayer": 0, "kCGWindowNumber": 41,
             "kCGWindowAlpha": 1.0, "kCGWindowBounds": {"X": 600, "Y": 60, "Width": 320, "Height": 120}},
            target,
        ]
        if cursor:
            rows.insert(0, {"kCGWindowOwnerName": "Window Server", "kCGWindowOwnerPID": 159,
                            "kCGWindowLayer": 2147483630, "kCGWindowNumber": 3, "kCGWindowName": "Cursor",
                            "kCGWindowAlpha": 1, "kCGWindowBounds": {"X": 416, "Y": 153, "Width": 23, "Height": 22}})
        if private:
            banner["kCGWindowName"] = "Private banner title"
            rows.append({"kCGWindowOwnerName": "Mail", "kCGWindowOwnerPID": 55, "kCGWindowLayer": 0,
                         "kCGWindowNumber": 9, "kCGWindowName": "Private mail subject", "kCGWindowAlpha": 1.0,
                         "kCGWindowBounds": {"X": 0, "Y": 25, "Width": 1200, "Height": 800}})
        desktop = {"pointer": (5.0, 5.0), "owned": True, "banner": covered, "front": pid, "now": 0.0, "shown_at": 0.0}
        self.posted_alphas = []

        def alpha():
            return 1.0 if desktop["now"] >= desktop["shown_at"] else 0.0

        def window_list(*_):
            target["kCGWindowAlpha"] = alpha()
            return [banner, *rows] if desktop["banner"] else rows

        def post(tap, point):
            self.posted_alphas.append(alpha())
            desktop.update(pointer=point)

        quartz = Mock(kCGDockWindowLevel=20, kCGCursorWindowLevel=2147483630)
        quartz.CGWindowListCopyWindowInfo.side_effect = window_list
        quartz.CGEventCreateMouseEvent.side_effect = lambda source, kind, point, button: point
        quartz.CGEventPost.side_effect = post
        quartz.CGEventGetLocation.side_effect = lambda event: SimpleNamespace(
            x=desktop["pointer"][0], y=desktop["pointer"][1])
        quartz.CGGetDisplaysWithPoint.return_value = (0, (7,), 1)
        quartz.CGDisplayBounds.return_value = SimpleNamespace(
            origin=SimpleNamespace(x=0, y=0), size=SimpleNamespace(width=1440, height=900))
        quartz.CGDisplayModeGetPixelWidth.return_value = 2880
        quartz.CGImageDestinationFinalize.return_value = True
        elements = {
            "bark": {"AXRole": "AXApplication", "AXTitle": "Bark", "AXFocusedWindow": "window"},
            "window": {"AXRole": "AXWindow", "AXSubrole": "AXStandardWindow", "AXTitle": "Peek fixture source"},
            "banner": {"AXRole": "AXGroup", "AXDescription": "Notification"},
            "mail": {"AXRole": "AXApplication", "AXTitle": "Mail", "AXFocusedWindow": "draft"},
            "draft": {"AXRole": "AXWindow", "AXSubrole": "AXStandardWindow", "AXTitle": "Private draft to a friend",
                      "AXDescription": "Private draft description"},
        }
        if private:
            elements["banner"]["AXTitle"] = "Private alert title"
        owners = {"bark": pid, "window": pid, "banner": 99, "mail": 55, "draft": 55}
        ax = Mock(AXIsProcessTrusted=lambda: True)
        ax.AXUIElementCreateSystemWide.return_value = "system"
        ax.AXUIElementCreateApplication.side_effect = lambda owner: {pid: "bark", 55: "mail"}[owner]
        ax.AXUIElementCopyAttributeValue.side_effect = lambda element, name, _: (
            (0, elements[element][name]) if name in elements.get(element, {}) else (-25212, None))
        ax.AXUIElementGetPid.side_effect = lambda element, _: (0, owners[element])
        ax.AXUIElementCopyElementAtPosition.return_value = (0, "banner")
        foundation = Mock()
        console = Mock(pointer=lambda: desktop["pointer"], available=lambda: True, idle=lambda: 60)
        contributor = {"native_architecture": lambda: "arm64", "verify_signed_shell": Mock(),
                       "app_output_lock": lambda app: nullcontext(), "seed_profile": Mock(), "stop": Mock()}
        process = Mock(pid=pid)

        @contextmanager
        def serve():
            yield SimpleNamespace(server_port=8000, events=[])

        def exercise(screen, _process, _events, _output):
            desktop["shown_at"] = desktop["now"] + shown_after
            screen.click((378, 133))
            desktop.update(owned=not lock_lost, banner=True, front=55 if private else pid)
            raise RuntimeError("Missing pointer event on /source")

        def lsappinfo(command, text):
            if command[1] == "front":
                return "ASN:0x0-0x1:\n"
            name = {pid: "Bark", 55: "Mail"}[desktop["front"]]
            return f'"pid"={desktop["front"]}\n' + (f'"LSDisplayName"="{name}"\n' if "name" in command else "")

        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Bark.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/Bark").touch()
            output = Path(folder) / "evidence"
            log = io.StringIO()
            with patch.object(sys, "argv", ["walk", "--app", str(app), "--output", str(output)]), \
                    patch.object(sys, "platform", "darwin"), patch.dict(sys.modules, {
                        "ApplicationServices": ax, "Quartz": quartz, "Foundation": foundation}), \
                    patch.object(signed_walk, "processes", return_value=[]), \
                    patch.object(signed_walk, "crash_reports", return_value=set()), \
                    patch.object(signed_walk.runpy, "run_path", return_value=contributor), \
                    patch.object(signed_walk, "bundle_cdhash", return_value="cdhash"), \
                    patch.object(signed_walk, "launch_verified", return_value=(process, 0)), \
                    patch("bark_macos_console.QuartzConsole", return_value=console), \
                    patch("bark_macos_console.screen_lock", lambda path, wait: nullcontext(lambda: desktop["owned"])), \
                    patch("bark_macos_console.require_idle_console"), \
                    patch("subprocess.check_output", side_effect=lsappinfo), patch("subprocess.run"), \
                    patch("time.monotonic", lambda: desktop["now"]), \
                    patch("time.sleep", side_effect=lambda seconds: desktop.update(now=desktop["now"] + seconds)), \
                    redirect_stdout(log), \
                    self.assertRaises(RuntimeError) as failure:
                signed_walk.run_walk("fixture", "fixture", serve, exercise)
            evidence = json.loads((output / "click-diagnostics.json").read_text())
        return str(failure.exception), evidence, log.getvalue(), quartz, ax, foundation, output

    def test_missed_click_records_what_was_under_the_point(self):
        failure, evidence, log, quartz, ax, foundation, output = self.failed_click()
        self.assertEqual(failure, "Missing pointer event on /source")
        self.assertEqual([row["owner"] for row in evidence["click"]["before"]["windows_at_point"]], ["Dock", "Bark"])
        self.assertEqual(evidence["click"]["relative"], [378, 133])
        self.assertEqual(evidence["click"]["point"], [428, 173])
        self.assertEqual(evidence["click"]["before"]["frontmost"], {"pid": 4321, "name": "Bark"})
        self.assertEqual(evidence["click"]["before"]["key_window"],
                         {"pid": 4321, "AXRole": "AXWindow", "AXSubrole": "AXStandardWindow",
                          "AXTitle": "Peek fixture source"})
        self.assertEqual([row["number"] for row in evidence["click"]["before"]["candidate_windows"]], [41, 40])
        stack = evidence["at_failure"]["windows_at_point"]
        self.assertEqual([(row["owner"], row["pid"], row["layer"]) for row in stack],
                         [("NotificationCenter", 99, 23), ("Dock", 77, 20), ("Bark", 4321, 0)])
        self.assertEqual(stack[0]["bounds"], {"X": 380, "Y": 150, "Width": 360, "Height": 80})
        self.assertEqual(evidence["at_failure"]["pointer"], [428, 173])
        self.assertEqual(evidence["element_at_point"], {"pid": 99, "AXRole": "AXGroup"})
        ax.AXUIElementCopyElementAtPosition.assert_called_once_with("system", 428, 173, None)
        self.assertEqual(evidence["display"]["scale"], 2.0)
        self.assertEqual(evidence["screenshot"], "display.png")
        quartz.CGWindowListCreateImage.assert_called_once_with(
            quartz.CGRectInfinite, quartz.kCGWindowListOptionOnScreenOnly, quartz.kCGNullWindowID,
            quartz.kCGWindowImageDefault)
        foundation.NSURL.fileURLWithPath_.assert_called_once_with(str(output.resolve() / "display.png"))
        self.assertIn("click-diagnostics.json", log)
        self.assertIn("NotificationCenter", log)
        self.assertIn("AXGroup", log)

    def test_display_is_not_captured_without_the_screen_lock(self):
        _, evidence, _, quartz, _, _, _ = self.failed_click(lock_lost=True)
        self.assertIsNone(evidence["screenshot"])
        quartz.CGWindowListCreateImage.assert_not_called()
        self.assertEqual(evidence["element_at_point"]["AXRole"], "AXGroup")

    def test_another_apps_window_over_the_point_fails_before_any_pointer_event(self):
        failure, evidence, log, quartz, _, _, _ = self.failed_click(covered=True)
        self.assertEqual(failure, "NotificationCenter window covers the click point")
        quartz.CGEventCreateMouseEvent.assert_not_called()
        quartz.CGEventPost.assert_not_called()
        self.assertEqual(evidence["failure"], failure)
        self.assertEqual([row["owner"] for row in evidence["click"]["before"]["windows_at_point"]],
                         ["NotificationCenter", "Dock", "Bark"])
        self.assertEqual(evidence["screenshot"], "display.png")
        self.assertIn("click-diagnostics.json", log)

    def test_pointer_window_over_the_point_does_not_block_the_click(self):
        failure, evidence, _, quartz, _, _, _ = self.failed_click(cursor=True)
        self.assertEqual(failure, "Missing pointer event on /source")
        self.assertEqual([row["owner"] for row in evidence["click"]["before"]["windows_at_point"]],
                         ["Window Server", "Dock", "Bark"])
        self.assertEqual([call.args[1:3] for call in quartz.CGEventCreateMouseEvent.call_args_list],
                         [(quartz.kCGEventMouseMoved, (428, 173)), (quartz.kCGEventLeftMouseDown, (428, 173)),
                          (quartz.kCGEventLeftMouseUp, (428, 173))])
        self.assertEqual(quartz.CGEventPost.call_count, 3)

    def test_click_waits_until_the_candidate_window_is_drawn(self):
        failure, evidence, _, _, _, _, _ = self.failed_click(shown_after=1.0)
        self.assertEqual(failure, "Missing pointer event on /source")
        self.assertEqual(self.posted_alphas, [1.0, 1.0, 1.0])
        self.assertEqual([row["alpha"] for row in evidence["click"]["before"]["windows_at_point"]
                          if row["number"] == 40], [1.0])

    def test_window_that_stays_transparent_fails_before_any_pointer_event(self):
        failure, evidence, _, quartz, _, _, _ = self.failed_click(shown_after=math.inf)
        self.assertEqual(failure, "The candidate window stayed transparent")
        quartz.CGEventPost.assert_not_called()
        self.assertEqual(evidence["failure"], failure)
        self.assertEqual([row["alpha"] for row in evidence["at_failure"]["candidate_windows"]
                          if row["number"] == 40], [0.0])

    def test_other_applications_titles_stay_out_of_the_diagnostics(self):
        _, evidence, log, _, _, _, _ = self.failed_click(private=True)
        recorded = json.dumps(evidence)
        for title in ("Private mail subject", "Private banner title", "Private alert title",
                      "Private draft to a friend", "Private draft description"):
            self.assertNotIn(title, recorded)
            self.assertNotIn(title, log)
        self.assertIn("Peek fixture source", log)
        self.assertEqual(evidence["click"]["before"]["key_window"]["AXTitle"], "Peek fixture source")
        self.assertEqual([row.get("name") for row in evidence["click"]["before"]["windows_at_point"]],
                         [None, "Peek fixture source", None])
        self.assertEqual(evidence["click"]["before"]["windows_at_point"][-1],
                         {"owner": "Mail", "pid": 55, "layer": 0, "number": 9, "alpha": 1.0,
                          "bounds": {"X": 0, "Y": 25, "Width": 1200, "Height": 800}})
        self.assertEqual(evidence["at_failure"]["frontmost"], {"pid": 55, "name": "Mail"})
        self.assertEqual(evidence["at_failure"]["key_window"],
                         {"pid": 55, "AXRole": "AXWindow", "AXSubrole": "AXStandardWindow"})
        self.assertEqual(evidence["element_at_point"], {"pid": 99, "AXRole": "AXGroup"})


class ClickCoverTests(unittest.TestCase):
    def covering(self, notification_bounds):
        screen = Screen.__new__(Screen)
        screen.pid = 4321
        screen.quartz = Mock(kCGDockWindowLevel=20, kCGCursorWindowLevel=2147483630)
        screen.quartz.CGGetDisplaysWithPoint.return_value = (0, (7,), 1)
        screen.quartz.CGDisplayBounds.return_value = SimpleNamespace(
            origin=SimpleNamespace(x=0, y=0), size=SimpleNamespace(width=1920, height=1080))
        screen.quartz.CGDisplayModeGetPixelWidth.return_value = 1920
        notification = {"owner": "Notification Center", "pid": 99, "layer": 23, "number": 12, "alpha": 1,
                        "bounds": notification_bounds}
        stack = [notification,
                 {"owner": "Dock", "pid": 77, "layer": 20, "number": 3, "alpha": 1,
                  "bounds": {"X": 0, "Y": 0, "Width": 1920, "Height": 1080}},
                 {"owner": "Bark", "pid": 4321, "layer": 0, "number": 40, "alpha": 1,
                  "bounds": {"X": 50, "Y": 320, "Width": 900, "Height": 660}}]
        return screen.covering(stack, 40), notification

    def test_notification_centers_full_display_overlay_does_not_cover_the_candidate(self):
        cover, _ = self.covering({"X": 0, "Y": 0, "Width": 1920, "Height": 1080})
        self.assertIsNone(cover)

    def test_notification_center_panel_smaller_than_the_display_covers_the_candidate(self):
        cover, panel = self.covering({"X": 600, "Y": 300, "Width": 360, "Height": 400})
        self.assertIs(cover, panel)


class TransparentHoverTests(unittest.TestCase):
    def hover(self, shown_after):
        clock = {"now": 0.0}
        self.posted = []

        def alpha():
            return 1.0 if clock["now"] >= shown_after else 0.0

        screen = Screen.__new__(Screen)
        screen.pid, screen.source, screen.guard = 4321, None, Mock()
        screen.quartz = Mock()
        screen.quartz.CGWindowListCopyWindowInfo.side_effect = lambda *_: [{
            "kCGWindowOwnerPID": 4321, "kCGWindowLayer": 0, "kCGWindowNumber": 40, "kCGWindowAlpha": alpha(),
            "kCGWindowBounds": {"X": 50, "Y": 40, "Width": 900, "Height": 660}}]
        screen.quartz.CGEventPost.side_effect = lambda tap, event: self.posted.append(alpha())
        with patch("time.monotonic", lambda: clock["now"]), \
                patch("time.sleep", side_effect=lambda seconds: clock.update(now=clock["now"] + seconds)):
            screen.hover((428, 173))
        return self.posted

    def test_hover_waits_until_the_candidate_window_is_drawn(self):
        self.assertEqual(self.hover(shown_after=1.0), [1.0])

    def test_hover_over_a_window_that_stays_transparent_posts_nothing(self):
        with self.assertRaisesRegex(RuntimeError, "The candidate window stayed transparent"):
            self.hover(shown_after=math.inf)
        self.assertEqual(self.posted, [])


class FirstWindowTests(unittest.TestCase):
    pid, finder = 4321, 341

    def launch(self, *, shown_at=1.0, drawn_at=1.0, front_at=1.0, exits_at=math.inf):
        desktop = {"now": 0.0}
        self.seen = []

        def front():
            return self.pid if desktop["now"] >= front_at else self.finder

        def window_list(*_):
            if desktop["now"] < shown_at:
                return []
            return [{"kCGWindowOwnerName": "Bark", "kCGWindowOwnerPID": self.pid, "kCGWindowLayer": 0,
                     "kCGWindowNumber": 40, "kCGWindowAlpha": 1.0 if desktop["now"] >= drawn_at else 0.0,
                     "kCGWindowBounds": {"X": 50, "Y": 40, "Width": 900, "Height": 660}}]

        def lsappinfo(command, text):
            if command[1] == "front":
                return "ASN:0x0-0x1:\n"
            name = "Bark" if front() == self.pid else "Finder"
            return f'"pid"={front()}\n' + (f'"LSDisplayName"="{name}"\n' if "name" in command else "")

        quartz = Mock(kCGDockWindowLevel=20, kCGCursorWindowLevel=2147483630)
        quartz.CGWindowListCopyWindowInfo.side_effect = window_list
        quartz.CGEventGetLocation.return_value = SimpleNamespace(x=5.0, y=5.0)
        quartz.CGGetDisplaysWithPoint.return_value = (0, (7,), 1)
        quartz.CGDisplayBounds.return_value = SimpleNamespace(
            origin=SimpleNamespace(x=0, y=0), size=SimpleNamespace(width=1024, height=768))
        quartz.CGDisplayModeGetPixelWidth.return_value = 1024
        quartz.CGImageDestinationFinalize.return_value = True
        ax = Mock(AXIsProcessTrusted=lambda: True)
        ax.AXUIElementCopyAttributeValue.return_value = (-25212, None)
        ax.AXUIElementCopyElementAtPosition.return_value = (-25212, None)
        console = Mock(pointer=lambda: (5.0, 5.0), available=lambda: True, idle=lambda: 60)
        contributor = {"native_architecture": lambda: "arm64", "verify_signed_shell": Mock(),
                       "app_output_lock": lambda app: nullcontext(), "seed_profile": Mock(), "stop": Mock()}
        process = Mock(pid=self.pid, returncode=1)
        process.poll.side_effect = lambda: 1 if desktop["now"] >= exits_at else None
        process.wait.return_value = 0

        @contextmanager
        def serve():
            yield SimpleNamespace(server_port=8000, events=[])

        def exercise(screen, _process, _events, _output):
            screen.guard()
            self.seen.append({"now": desktop["now"], "front": front(),
                              "alphas": [row["kCGWindowAlpha"] for row in screen.windows()]})

        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "Bark.app"
            (app / "Contents/MacOS").mkdir(parents=True)
            (app / "Contents/MacOS/Bark").touch()
            output = Path(folder) / "evidence"
            with patch.object(sys, "argv", ["walk", "--app", str(app), "--output", str(output)]), \
                    patch.object(sys, "platform", "darwin"), patch.dict(sys.modules, {
                        "ApplicationServices": ax, "Quartz": quartz, "Foundation": Mock()}), \
                    patch.object(signed_walk, "processes", return_value=[]), \
                    patch.object(signed_walk, "crash_reports", return_value=set()), \
                    patch.object(signed_walk.runpy, "run_path", return_value=contributor), \
                    patch.object(signed_walk, "bundle_cdhash", return_value="cdhash"), \
                    patch.object(signed_walk, "launch_verified", return_value=(process, 0)), \
                    patch("bark_macos_console.QuartzConsole", return_value=console), \
                    patch("bark_macos_console.screen_lock", lambda path, wait: nullcontext(lambda: True)), \
                    patch("bark_macos_console.require_idle_console"), \
                    patch("subprocess.check_output", side_effect=lsappinfo), patch("subprocess.run"), \
                    patch("time.monotonic", lambda: desktop["now"]), \
                    patch("time.sleep", side_effect=lambda seconds: desktop.update(now=desktop["now"] + seconds)), \
                    redirect_stdout(io.StringIO()):
                try:
                    return signed_walk.run_walk("fixture", "fixture", serve, exercise), None
                except RuntimeError as failure:
                    evidence = json.loads((output / "click-diagnostics.json").read_text())
                    return failure, evidence

    def test_walk_begins_once_its_first_window_is_drawn_and_frontmost(self):
        status, _ = self.launch(shown_at=2.0, drawn_at=3.0, front_at=4.0)
        self.assertEqual(status, 0)
        self.assertEqual(len(self.seen), 1)
        self.assertGreaterEqual(self.seen[0]["now"], 4.0)
        self.assertEqual(self.seen[0]["front"], self.pid)
        self.assertEqual(self.seen[0]["alphas"], [1.0])

    def test_candidate_without_a_drawn_window_fails_before_the_walk(self):
        for case, timeline, expected in [
            ("never shown", {"shown_at": math.inf}, "The candidate did not show a window"),
            ("stays transparent", {"drawn_at": math.inf}, "The candidate did not show a window"),
            ("exits first", {"shown_at": math.inf, "exits_at": 2.0},
             "The candidate did not show a window (candidate exit status 1)"),
        ]:
            with self.subTest(case):
                failure, evidence = self.launch(**timeline)
                self.assertEqual(str(failure), expected)
                self.assertEqual(self.seen, [])
                self.assertEqual(evidence["failure"], expected)

    def test_candidate_that_never_becomes_frontmost_fails_before_the_walk(self):
        failure, evidence = self.launch(front_at=math.inf)
        self.assertEqual(str(failure), "The candidate did not become frontmost")
        self.assertEqual(self.seen, [])
        self.assertEqual(evidence["at_failure"]["frontmost"], {"pid": self.finder, "name": "Finder"})
        self.assertEqual([row["number"] for row in evidence["at_failure"]["candidate_windows"]], [40])


class LoopbackFixtureTests(unittest.TestCase):
    def test_startup_fixture_binds_loopback_without_name_lookups(self):
        serve = runpy.run_path(str(REPO / "Tests/ChromiumStartup/walk.py"))["serve"]
        with refused_name_lookups(), serve() as server:
            self.assertEqual(server.socket.getsockname()[0], "127.0.0.1")


class NativeArchitectureTests(unittest.TestCase):
    def test_native_image_is_required_even_under_translated_python(self):
        contributor = runpy.run_path(str(REPO / "scripts/bark-check.py"))
        contributor["verify_signed_shell"] = Mock()
        verify = contributor["verify_signed_shell"]
        app = Path("/fixture/Bark.app")
        for probe_values, expected in [("1\n0\n", "arm64"), ("0\n1\n", "arm64"), ("", "x86_64")]:
            reply = subprocess.CompletedProcess([], 0, stdout=probe_values)
            with self.subTest(architecture=expected), patch("sys.platform", "darwin"), \
                    patch("platform.machine", return_value="x86_64"), patch("subprocess.run", return_value=reply) as sysctl:
                self.assertEqual(verify_native_candidate(contributor, app), expected)
                verify.assert_called_with(app, expected)
                sysctl.assert_called_once_with(
                    ["/usr/sbin/sysctl", "-in", "hw.optional.arm64", "sysctl.proc_translated"],
                    capture_output=True, text=True, check=True,
                )

    def test_verified_sdk_evidence_also_records_signed_bundle_identity(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            app = root / "Bark.app"
            binary = app / "Contents/MacOS/Bark"
            binary.parent.mkdir(parents=True)
            binary.touch()
            output = root / "evidence"
            argv = ["walk", "--app", str(app), "--output", str(output), "--verify-sdk"]
            sdk = root / "Engine"
            qualification = {"architecture": "arm64", "sdk_pin": "fixture-pin", "official": None}
            ax = Mock(AXIsProcessTrusted=lambda: True)
            quartz = Mock(CGPreflightPostEventAccess=lambda: True, CGPreflightScreenCaptureAccess=lambda: True)
            check = runpy.run_path(str(REPO / "scripts/bark-check.py"))
            contributor = {"native_architecture": lambda: "arm64", "app_output_lock": check["app_output_lock"]}

            def verified_cdhash(candidate):
                verify.assert_called_once_with(contributor, "arm64", app.resolve(), require_official=False)
                self.assertEqual(candidate, app.resolve())
                return "verified-cdhash"

            with patch.object(sys, "argv", argv), patch.object(sys, "platform", "darwin"), patch.dict(
                sys.modules, {"ApplicationServices": ax, "Quartz": quartz}
            ), patch.object(signed_walk, "processes", return_value=[]), patch.object(
                signed_walk.runpy, "run_path", return_value=contributor
            ), patch.object(signed_walk, "verify_pinned_sdk", return_value=(sdk, qualification)) as verify, patch.object(
                signed_walk, "bundle_cdhash", side_effect=verified_cdhash
            ), patch("bark_macos_console.QuartzConsole"), self.assertRaisesRegex(RuntimeError, "stop before launch"):
                signed_walk.run_walk("fixture", "fixture", Mock(side_effect=RuntimeError("stop before launch")),
                                     Mock(), official_qualification=True)
            self.assertEqual(json.loads((output / "candidate.json").read_text()), {
                "architecture": "arm64", "sdk_pin": "fixture-pin", "official": None,
                "bundle_cdhash": "verified-cdhash",
            })

    def test_timing_report_survives_missing_cpu_brand(self):
        startup = runpy.run_path(str(REPO / "Tests/ChromiumStartup/walk.py"))
        with patch("subprocess.check_output", return_value="Mac14,2\n17179869184\n"), patch(
            "subprocess.run", return_value=subprocess.CompletedProcess([], 1, stdout="")
        ):
            self.assertEqual(startup["hardware"](), {"model": "Mac14,2", "memory_bytes": 17179869184, "cpu": None})


if __name__ == "__main__":
    unittest.main()
