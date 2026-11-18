"""Exercise the first official SDK publication boundary without rebuilding Chromium."""

from pathlib import Path
import runpy
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class FirstOfficialPublicationTests(unittest.TestCase):
    def test_missing_receipt_cannot_create_or_replace_the_first_arm_pin(self):
        fixture = runpy.run_path(str(ROOT / "Tests/ChromiumAppShim/check.py"))
        with tempfile.TemporaryDirectory(prefix="bark-first-official-") as directory:
            work = Path(directory).resolve()
            package = work / "package"
            framework = work / "arm64.dylib"
            fixture["fake_framework"](framework, arch=("-arch", "arm64"))
            build = fixture["fake_engine_build"](work, framework)
            siso = work / "fake-siso"
            siso.mkdir()
            command = siso / "siso"
            command.write_text('#!/bin/bash\nexec /bin/cat "$FAKE_SISO_STATE"\n')
            command.chmod(0o755)

            def publish(*options):
                return subprocess.run([
                    "/bin/bash", str(fixture["PUBLISH"]), "--arch", "arm64",
                    *options, str(build), str(package),
                ], env=fixture["publisher_environment"](build, siso),
                    capture_output=True, text=True)

            pin = package / "BarkEngine.xcframework" / fixture["SLICE_NAME"] / (
                "Headers/BarcChromium/engine-artifact-arm64.sha256"
            )
            absent = publish("--require-official")
            self.assertNotEqual(absent.returncode, 0)
            self.assertIn("No official Bark SDK build receipt", absent.stderr)
            self.assertFalse(package.exists())

            developer = publish()
            self.assertEqual(developer.returncode, 0, developer.stderr)
            original = pin.read_bytes()
            missing = publish("--require-official", "--replace")
            self.assertNotEqual(missing.returncode, 0)
            self.assertEqual(pin.read_bytes(), original)

            # The option requires genuine provenance, even if a named receipt exists.
            (build / "official-build.json").write_text("{}")
            selector = build.parent.parent / "chrome/build/mac-arm.pgo.txt"
            selector.parent.mkdir(parents=True)
            selector.write_text("an-unpinned-fixture-profile.profdata\n")
            invalid = publish("--require-official", "--replace")
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("The Chromium PGO selector does not match the Bark pin", invalid.stderr)
            self.assertEqual(pin.read_bytes(), original)
            fixture["make_writable"](package)
