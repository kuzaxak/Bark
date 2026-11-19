# Licensed under GPL-3.0. See LICENSE.
"""Check the app-owned WebKit source boundary without building Bark."""

from pathlib import Path
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

    def test_allows_shared_packages_and_read_only_import_paths(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            shared = root / "Packages/NookWeb/Sources/WebKitAdapter.swift"
            shared.parent.mkdir(parents=True)
            shared.write_text("import WebKit\nlet page: WKWebView? = nil\n")
            migration = root / "App/LegacyDataMigration.swift"
            migration.parent.mkdir()
            migration.write_text('import Foundation\n// WKWebsiteDataStore is unnecessary here.\n'
                                 'let file = library.appendingPathComponent("WebKit/WebsiteDataStore")\n')
            verify_shell_boundary(root)


if __name__ == "__main__":
    unittest.main()
