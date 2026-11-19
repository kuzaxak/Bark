"""Exercise the maintained browser-test archive layout with a tiny runtime."""

import json
import runpy
from pathlib import Path
import tarfile
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "package-chromium-tests.py"
package = runpy.run_path(str(SCRIPT))
from chromium_test_runtime import APP_FRAMEWORK, MANIFEST_NAME, TEST_FRAMEWORK, verify_manifest


class BrowserTestArchiveTests(unittest.TestCase):
    def test_archive_records_exact_binary_and_observed_fixture(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "src"
            build = src / "out/Barc-arm64"
            binary = build / "bark_browser_tests"
            fixture = src / package["FIXTURE"]

            def write(relative, contents):
                path = src / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents)

            write("chrome/VERSION", "MAJOR=156")
            write(fixture.relative_to(src), "exact overlay source")
            expected = root / "fixture.mm"
            expected.write_text("older fixture")
            write(binary.relative_to(src), "linked binary")
            write(build.relative_to(src) / "bark_browser_tests.runtime_deps",
                  "bark_browser_tests\nBark Framework.framework\nBark.app\n")
            for path in (*package["IMAGES"][1:], package["RAW_PLIST"], package["RAW_LAUNCHER"],
                         package["INTEGRATED_PLIST"]):
                write(build.relative_to(src) / path, "signed fixture")
            archive = root / "runtime.tar.gz"
            function = package["package"]
            with patch.dict(function.__globals__, {
                "require_host_only_image": lambda path, **_: (path, package["file_identity"](path)),
                "inspect_launcher": lambda *_: None,
            }):
                with self.assertRaisesRegex(ValueError, "Installed browser-test fixture differs"):
                    function(build, "arm64", archive, fixture_source=expected)
                self.assertFalse(archive.exists())
                expected.write_text(fixture.read_text())
                (build / APP_FRAMEWORK).write_text("other host-only framework")
                with self.assertRaisesRegex(ValueError, "framework binaries differ"):
                    function(build, "arm64", archive, fixture_source=expected)
                self.assertFalse(archive.exists())
                (build / APP_FRAMEWORK).write_text((build / TEST_FRAMEWORK).read_text())
                function(build, "arm64", archive, fixture_source=expected)
            restored = root / "restored"
            with tarfile.open(archive) as tar:
                tar.extractall(restored, filter="data")
            restored_binary = restored / binary.relative_to(root)
            verify_manifest(restored_binary, expected)
            installed = restored_binary.parent
            record = json.loads((installed / MANIFEST_NAME).read_text())
            self.assertEqual(record["format"], 2)
            expected.write_text("other source")
            with self.assertRaisesRegex(ValueError, "differs from the expected source"):
                verify_manifest(restored_binary, expected)
            expected.write_text(fixture.read_text())
            (installed / APP_FRAMEWORK).write_text("different linked framework")
            with self.assertRaisesRegex(ValueError, "framework binaries differ"):
                verify_manifest(restored_binary, expected)
            (installed / TEST_FRAMEWORK).write_text("different linked framework")
            with self.assertRaisesRegex(ValueError, "framework differs from its archived SHA-256"):
                verify_manifest(restored_binary, expected)
            restored_binary.write_text("different linked executable")
            with self.assertRaisesRegex(ValueError, "executable differs"):
                verify_manifest(restored_binary, expected)


if __name__ == "__main__":
    unittest.main()
