# Licensed under GPL-3.0. See LICENSE.
"""Check Bark’s source and linked framework boundaries without building the app."""

from pathlib import Path
import platform
import subprocess
import sys
import tempfile
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bark_shell_boundary import verify_shell_boundary


class ShellBoundaryTests(unittest.TestCase):
    def test_rejects_both_direct_import_and_package_view_lookup(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "Nook/Managers/Legacy.swift"
            source.parent.mkdir(parents=True)
            source.write_text("internal import class WebKit.WKWebView\n"
                              "let source = WebKitPageAccess.existingView(for: page)\n")
            with self.assertRaises(ValueError) as caught:
                verify_shell_boundary(root)
            self.assertIn("Nook/Managers/Legacy.swift:1: internal import class WebKit", str(caught.exception))
            self.assertIn("Nook/Managers/Legacy.swift:2: WebKitPageAccess", str(caught.exception))

    def test_policy_packages_and_developer_tools_cannot_install_webkit_handlers(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for folder in ("NookBlocker/Sources/NookBlocker", "NookTweaks/Sources/NookTweaks",
                           "NookWeb/Sources/NookWeb/DevTools"):
                file = root / "Packages" / folder / "Handler.swift"
                file.parent.mkdir(parents=True)
                file.write_text("class Handler: NSObject, WKScriptMessageHandlerWithReply {}\n")
            with self.assertRaises(ValueError) as caught:
                verify_shell_boundary(root)
            self.assertEqual(str(caught.exception).count("Handler.swift:1:"), 3)

    @unittest.skipUnless(sys.platform == "darwin", "requires macOS Mach-O tools")
    def test_linked_webkit_is_rejected_even_when_sources_have_no_swift_import(self):
        checker = Path(__file__).resolve().parents[1] / "check-chromium-architectures.py"
        architecture = platform.machine()
        with tempfile.TemporaryDirectory() as directory:
            # Link only. The test never starts a browser or calls a WebKit function.
            for framework in ("Foundation", "WebKit"):
                with self.subTest(framework=framework):
                    image = Path(directory) / f"Test{framework}.dylib"
                    subprocess.run(["xcrun", "clang", "-arch", architecture, "-dynamiclib",
                                    "-x", "c", "-", f"-Wl,-needed_framework,{framework}", "-o", image],
                                   input="int fixture(void) { return 0; }", text=True, check=True)
                    result = subprocess.run([sys.executable, "-B", checker, "--arch", architecture,
                                             "--shell-image", image], capture_output=True, text=True)
                    if framework == "Foundation":
                        self.assertEqual(result.returncode, 0, result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("WebKit.framework", result.stderr)

    def test_allows_read_only_import_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            migration = root / "App/LegacyDataMigration.swift"
            migration.parent.mkdir()
            migration.write_text('import Foundation\n// WKWebsiteDataStore is unnecessary here.\n'
                                 'let file = library.appendingPathComponent("WebKit/WebsiteDataStore")\n')
            verify_shell_boundary(root)


if __name__ == "__main__":
    unittest.main()
