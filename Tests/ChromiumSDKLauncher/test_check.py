"""Check static and native execution boundaries for the raw SDK launcher."""

from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
from unittest.mock import patch

import check


class LauncherCheckTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.build = Path(directory.name)
        raw = self.build / "Bark.app/Contents/Info.plist"
        integrated = self.build / "gen/chrome/chrome_integrated_app_info_plist.plist"
        raw.parent.mkdir(parents=True)
        integrated.parent.mkdir(parents=True)
        raw.write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "ee.qdo.bark.sdk", "CFBundleExecutable": "Bark",
            "LSBackgroundOnly": True,
        }))
        integrated.write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "ee.qdo.bark", "NSPrincipalClass": "BrowserCrApplication",
            "CFBundleURLTypes": [{}], "CFBundleDocumentTypes": [{}],
        }))
        self.executable = raw.parent / "MacOS/Bark"

    def inspect(self, architecture, hardware, tooling, *, actual=None, imports="___stderrp\n_fputs\n"):
        metadata = [f"{actual or architecture}\n", "launcher:\n /usr/lib/libSystem.B.dylib (version)\n", imports]
        refusal = subprocess.CompletedProcess(
            [], 69, "", "Bark Engine is an SDK build artifact. Launch the signed Bark app.\n")
        output = StringIO()
        with patch.object(check.subprocess, "check_output", side_effect=metadata) as inspect, patch.object(
            check.subprocess, "run", return_value=refusal
        ) as launch, patch.object(check, "native_architecture", return_value=hardware), patch.object(
            check.platform, "machine", return_value=tooling
        ), redirect_stdout(output):
            if actual is not None or "_NSApplicationMain" in imports:
                with self.assertRaises(SystemExit):
                    check.check(self.build, architecture)
                launch.assert_not_called()
            else:
                check.check(self.build, architecture)
                self.assertEqual([Path(call.args[0][0]).name for call in inspect.call_args_list],
                                 ["lipo", "otool", "nm"])
        return output.getvalue(), launch.call_args_list

    def test_foreign_target_never_executes_launcher(self):
        for architecture, hardware, tooling in (("arm64", "x86_64", "x86_64"),
                                                  ("x86_64", "arm64", "x86_64")):
            with self.subTest(architecture=architecture, hardware=hardware, tooling=tooling):
                output, launches = self.inspect(architecture, hardware, tooling)
                self.assertIn(f"tooling {tooling}, hardware {hardware}", output)
                self.assertIn("require a native run", output)
                self.assertEqual(launches, [])

    def test_native_executes_all_refusal_cases(self):
        for arch, tooling in (("x86_64", "x86_64"), ("arm64", "arm64"), ("arm64", "x86_64")):
            with self.subTest(arch=arch, tooling=tooling):
                output, launches = self.inspect(arch, arch, tooling)
                self.assertIn("all 5 native direct launch cases refused", output)
                self.assertEqual([call.args[0] for call in launches], [
                    [self.executable], [self.executable, "-psn_0_12345"],
                    [self.executable, "--type=renderer"], [self.executable, "--type=gpu-process"],
                    [self.executable, "--headless", "https://example.invalid"],
                ])

    def test_static_inspection_never_executes_a_valid_native_launcher(self):
        metadata = ["x86_64\n", "launcher:\n /usr/lib/libSystem.B.dylib (version)\n", "_fputs\n"]
        with patch.object(check.subprocess, "check_output", side_effect=metadata), patch.object(
            check.subprocess, "run"
        ) as launch:
            self.assertEqual(check.inspect_launcher(self.build, "x86_64"), self.executable)
            launch.assert_not_called()

    def test_static_inspection_refuses_legacy_foreground_bundle(self):
        path = self.build / check.RAW_PLIST
        result = plistlib.loads(path.read_bytes())
        result.pop("LSBackgroundOnly")
        path.write_bytes(plistlib.dumps(result))
        with patch.object(check.subprocess, "check_output") as inspect, patch.object(
            check.subprocess, "run"
        ) as launch:
            with self.assertRaisesRegex(SystemExit, "eligible for foreground"):
                check.inspect_launcher(self.build, "arm64")
            inspect.assert_not_called()
            launch.assert_not_called()

    def test_wrong_width_arch_or_unsafe_symbols_fail_before_launch(self):
        self.inspect("arm64", "arm64", "arm64", actual="x86_64 arm64")
        self.inspect("arm64", "arm64", "arm64", actual="x86_64")
        self.inspect("arm64", "arm64", "arm64", imports="_NSApplicationMain\n")


if __name__ == "__main__":
    unittest.main()
