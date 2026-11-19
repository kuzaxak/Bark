"""Exercise the maintained browser-test archive layout with a tiny runtime."""

import json
import runpy
import shutil
import subprocess
import sys
from pathlib import Path
import tarfile
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "package-chromium-tests.py"
package = runpy.run_path(str(SCRIPT))
from chromium_test_runtime import (
    APP_FRAMEWORK, INVENTORY_NAME, MANIFEST_NAME, TEST_FRAMEWORK, fixture_digests, verify_manifest,
)

FIXTURE_TREE = SCRIPT.parents[1] / "Runtime/Chromium/bark/test"


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


    @unittest.skipUnless(sys.platform == "darwin", "requires macOS Mach-O linker")
    def test_exact_archive_rejects_stale_non_bridge_compiler_inputs(self):
        with TemporaryDirectory() as directory:
            root = Path(directory)
            src = root / "src"
            fixtures = src / "bark/test"
            shutil.copytree(FIXTURE_TREE, fixtures)
            generated = root / "receipt.cc"
            generator = fixtures / "write_source_receipt.py"
            expected_names = fixture_digests(fixtures)
            subprocess.run([sys.executable, "-B", generator, generated,
                            *(fixtures / name for name in expected_names)], check=True)
            (fixtures / "unrelated_check.py").write_text("# not linked into the test target\n")
            self.assertEqual(fixture_digests(fixtures), expected_names)
            main = root / "main.cc"
            main.write_text("int main() { return 0; }\n")
            (src / "chrome").mkdir()
            (src / "chrome/VERSION").write_text("MAJOR=156")
            for arch, gn in (("arm64", "arm64"), ("x86_64", "x64")):
                with self.subTest(arch=arch):
                    build = src / "out" / f"Barc-{gn}"
                    build.mkdir(parents=True)
                    binary = build / "bark_browser_tests"
                    subprocess.run(["xcrun", "clang++", "-arch", arch, "-Oz", "-Wl,-dead_strip",
                                    main, generated, "-o", binary], check=True)
                    (build / "bark_browser_tests.runtime_deps").write_text(
                        "bark_browser_tests\nBark Framework.framework\nBark.app\n")
                    for path in (*package["IMAGES"][1:], package["RAW_PLIST"], package["RAW_LAUNCHER"],
                                 package["INTEGRATED_PLIST"]):
                        target = build / path
                        target.parent.mkdir(parents=True, exist_ok=True)
                        target.write_text("framework or app fixture")
                    archive = root / f"{arch}.tar.gz"
                    function = package["package"]
                    with patch.dict(function.__globals__, {
                        "require_host_only_image": lambda path, **_: (path, package["file_identity"](path)),
                        "inspect_launcher": lambda *_: None,
                    }):
                        for name in ("bark_window_host_browsertest.mm", "barc_extension_storage_browsertest.mm"):
                            fixture = fixtures / name
                            old = fixture.read_bytes()
                            fixture.write_bytes(old + b"\n// updated source\n")
                            with self.assertRaisesRegex(ValueError, name):
                                function(build, arch, archive, fixture_tree=fixtures)
                            self.assertFalse(archive.exists())
                            fixture.write_bytes(old)
                        function(build, arch, archive, fixture_tree=fixtures)

                    restored = root / f"restored-{arch}"
                    with tarfile.open(archive) as tar:
                        tar.extractall(restored, filter="data")
                    linked = restored / binary.relative_to(root)
                    verify_manifest(linked, expected_tree=fixtures)
                    for name in ("bark_window_host_browsertest.mm", "barc_extension_storage_browsertest.mm"):
                        fixture = fixtures / name
                        old = fixture.read_bytes()
                        fixture.write_bytes(old + b"\n// updated source\n")
                        with self.assertRaisesRegex(ValueError, name):
                            verify_manifest(linked, expected_tree=fixtures)
                        fixture.write_bytes(old)
                    inventory = fixtures / INVENTORY_NAME
                    original = inventory.read_text()
                    current = json.loads(original)
                    removed = current["sources"].pop()
                    inventory.write_text(json.dumps(current))
                    with self.assertRaisesRegex(ValueError, removed):
                        verify_manifest(linked, expected_tree=fixtures)
                    current = json.loads(original)
                    current["support"].append("test_helper.h")
                    (fixtures / "test_helper.h").write_text("// included by a fixture\n")
                    inventory.write_text(json.dumps(current))
                    with self.assertRaisesRegex(ValueError, "test_helper.h"):
                        verify_manifest(linked, expected_tree=fixtures)
                    inventory.write_text(original)
                    manifest = linked.parent / MANIFEST_NAME
                    record = json.loads(manifest.read_text())
                    self.assertEqual(record["format"], 3)
                    self.assertEqual(record["linked_test_sources"], fixture_digests(fixtures))
                    name = "barc_extension_storage_browsertest.mm"
                    record["linked_test_sources"][name] = "0" * 64
                    manifest.write_text(json.dumps(record))
                    with self.assertRaisesRegex(ValueError, "receipt differs from the linked executable"):
                        verify_manifest(linked, expected_tree=fixtures)


if __name__ == "__main__":
    unittest.main()
