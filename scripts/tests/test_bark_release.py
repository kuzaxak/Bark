"""Check update trust, per-architecture routing, and release version independence."""

import plistlib
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bark_release import (SPARKLE, check_distribution_settings, configure_release,
                          expected_additions, production_settings, write_appcast)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.app = self.root / "Bark.app"
        self.info_path = self.app / "Contents/Info.plist"
        self.info_path.parent.mkdir(parents=True)
        self.base = {"CFBundleIdentifier": "ee.qdo.bark", "CFBundleVersion": "8078.80",
                     "CFBundleShortVersionString": "156.0.8078.80", "LSMinimumSystemVersion": "15.5",
                     "CFBundleDocumentTypes": [{"CFBundleTypeName": "Web page"}]}
        self.info_path.write_bytes(plistlib.dumps(self.base))
        self.release = production_settings("1.4.0.2", "102", "https://update.example/bark/", "x86_64")

    def test_releasing_the_shell_preserves_the_embedded_engine_version(self):
        configure_release(self.app, self.release)
        info = plistlib.loads(self.info_path.read_bytes())
        self.assertEqual(info["BarkChromiumVersion"], "156.0.8078.80")
        self.assertEqual(info["CFBundleDocumentTypes"], self.base["CFBundleDocumentTypes"])
        self.assertEqual(check_distribution_settings(info, "x86_64", "https://downloads.example/releases"),
                         ("ee.qdo.bark", "1.4.0.2", "102"))
        with self.assertRaises(ValueError):
            check_distribution_settings(info, "arm64", "https://downloads.example/releases")
        with self.assertRaises(ValueError):
            check_distribution_settings({**info, "SUPublicEDKey": "AA=="}, "x86_64", "https://downloads.example")

    def test_developer_and_release_configuration(self):
        self.assertIsNone(production_settings(None, None, None, "arm64"))
        arm = production_settings("1.4.0.2", "102", "https://update.example/bark", "arm64")
        self.assertTrue(arm["SUFeedURL"].endswith("/bark-macos-arm64.xml"))
        self.assertEqual(arm["SUPublicEDKey"], self.release["SUPublicEDKey"])
        for url in ("https://example.com:unknown", "https://example.com:65536",
                    "https://updates.example/a b", "https://updates.example/a?channel=old"):
            with self.subTest(url=url), self.assertRaises(ValueError):
                production_settings("1", "20", url, "arm64")
        for version, build, base in [("1.4", None, None), ("1.4/x", "10", "https://example.com"),
                                     ("1", "0", "https://example.com"), ("1", "20", "http://example.com")]:
            with self.subTest(version=version, build=build, base=base), self.assertRaises(ValueError):
                production_settings(version, build, base, "x86_64")

    def test_rehearsal_metadata_is_sealed_without_claiming_document_handlers(self):
        settings = {**self.release, "CFBundleIdentifier": "ee.qdo.bark.test.00000000-0000-0000-0000-000000000001",
                    "BarkUpdateRehearsal": {"DataRoot": "/private/tmp/example", "Profile": "00000000-0000-0000-0000-000000000002"},
                    "SUEnableAutomaticChecks": False, "SUFeedURL": "http://127.0.0.1:8791/bark-macos-x86_64.xml"}
        configure_release(self.app, settings)
        info = plistlib.loads(self.info_path.read_bytes())
        self.assertNotIn("CFBundleDocumentTypes", info)
        expected = plistlib.loads(expected_additions(settings, self.root).read_bytes())["Info"]
        self.assertNotIn("CFBundleDocumentTypes", expected)
        self.assertEqual(expected["BarkUpdateRehearsal"], settings["BarkUpdateRehearsal"])
        check_distribution_settings(info, "x86_64", "http://127.0.0.1:8791/releases/")
        with self.assertRaises(ValueError):
            check_distribution_settings(info, "x86_64", "http://127.0.0.1:9911/releases/")

    def test_feed_describes_the_signed_app_and_final_archive(self):
        path = self.root / "bark-macos-x86_64.xml"
        write_appcast(path, {**self.base, **self.release}, "https://example.com/update.dmg", 4567, "signature")
        item = ET.parse(path).find("channel/item")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}version"), "102")
        self.assertEqual(item.findtext(f"{{{SPARKLE}}}minimumSystemVersion"), "15.5")
        self.assertEqual(item.find("enclosure").attrib[f"{{{SPARKLE}}}edSignature"], "signature")
        self.assertEqual(item.find("enclosure").attrib["length"], "4567")


if __name__ == "__main__":
    unittest.main()
