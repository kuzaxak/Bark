"""Check update trust, per-architecture routing, and release version independence."""

import plistlib
import shutil
import subprocess
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock
import xml.etree.ElementTree as ET

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from bark_release import (SPARKLE, check_distribution_settings, configure_release,
                          expected_additions, production_settings, verify_installed_image, write_appcast)


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name)
        self.app = self.root / "Bark.app"
        self.info_path = self.app / "Contents/Info.plist"
        self.info_path.parent.mkdir(parents=True)
        framework = self.app / "Contents/Frameworks/Bark Framework.framework/Resources/Info.plist"
        framework.parent.mkdir(parents=True)
        framework.write_bytes(plistlib.dumps({"CFBundleShortVersionString": "156.0.8078.80"}))
        self.base = {"CFBundleIdentifier": "ee.qdo.bark", "CFBundleVersion": "120",
                     "CFBundleShortVersionString": "1.5.4", "BarkChromiumVersion": "156.0.8078.80",
                     "LSMinimumSystemVersion": "15.5",
                     "CFBundleDocumentTypes": [{"CFBundleTypeName": "Web page"}]}
        self.info_path.write_bytes(plistlib.dumps(self.base))
        self.release = production_settings("1.4.0.2", "102", "https://update.example/bark/", "x86_64")

    def test_assesses_sealed_app_copied_from_read_only_image(self):
        image = self.root / "Bark.dmg"
        requirement = '=identifier "ee.qdo.bark"'
        for failure in (None, "image", "copy", "seal", "identity", "sdk", "execution"):
            with self.subTest(failure=failure):
                events = []
                installation = []

                def run(command, **kwargs):
                    tool, mode = Path(command[0]).name, command[1]
                    if tool == "spctl":
                        event = "image" if "open" in command else "execution"
                    elif tool == "hdiutil":
                        event = mode
                    elif tool == "ditto":
                        event = "copy"
                    else:
                        event = "seal"
                    events.append(event)
                    if failure == event:
                        raise subprocess.CalledProcessError(1, command)
                    if event == "attach":
                        self.assertTrue({"-readonly", "-nobrowse", "-noautoopen"} <= set(command))
                        shutil.copytree(self.app, command[-2] / self.app.name)
                    if event == "copy":
                        installation.append(command[-1])
                        shutil.copytree(command[-2], command[-1])
                    if event == "seal":
                        self.assertIn(requirement, command)
                        self.assertEqual(command[-1], installation[0])
                    if event == "execution":
                        self.assertEqual(command[-1], installation[0])

                def verify_sdk(installed):
                    events.append("sdk")
                    self.assertEqual(installed, installation[0])
                    if failure == "sdk":
                        raise ValueError("SDK mismatch")

                with mock.patch("bark_release.subprocess.run", side_effect=run), mock.patch(
                    "bark_release.subprocess.check_output",
                    side_effect=["CDHash=abc123", "CDHash=bad456" if failure == "identity" else "CDHash=abc123"],
                ):
                    if failure in ("sdk", "identity"):
                        with self.assertRaises(ValueError):
                            verify_installed_image(image, self.app, self.root, requirement, verify_sdk)
                    elif failure:
                        with self.assertRaises(subprocess.CalledProcessError):
                            verify_installed_image(image, self.app, self.root, requirement, verify_sdk)
                    else:
                        verify_installed_image(image, self.app, self.root, requirement, verify_sdk)
                expected = {
                    None: ["image", "attach", "copy", "detach", "seal", "sdk", "execution"],
                    "image": ["image"],
                    "copy": ["image", "attach", "copy", "detach"],
                    "seal": ["image", "attach", "copy", "detach", "seal"],
                    "identity": ["image", "attach", "copy", "detach", "seal"],
                    "sdk": ["image", "attach", "copy", "detach", "seal", "sdk"],
                    "execution": ["image", "attach", "copy", "detach", "seal", "sdk", "execution"],
                }
                self.assertEqual(events, expected[failure])
                self.assertEqual(list(self.root.glob("install-check-*")), [])

    def test_releasing_the_shell_preserves_the_embedded_engine_version(self):
        configure_release(self.app, self.release)
        info = plistlib.loads(self.info_path.read_bytes())
        self.assertEqual(info["BarkChromiumVersion"], "156.0.8078.80")
        self.assertEqual(info["CFBundleShortVersionString"], "1.4.0.2")
        self.assertEqual(info["CFBundleVersion"], "102")
        self.assertEqual(info["CFBundleDocumentTypes"], self.base["CFBundleDocumentTypes"])
        self.assertEqual(check_distribution_settings(info, "x86_64", "https://downloads.example/releases"),
                         ("ee.qdo.bark", "1.4.0.2", "102"))
        with self.assertRaises(ValueError):
            check_distribution_settings(info, "arm64", "https://downloads.example/releases")
        with self.assertRaises(ValueError):
            check_distribution_settings({**info, "SUPublicEDKey": "AA=="}, "x86_64", "https://downloads.example")

    def test_imports_the_version_from_legacy_staged_apps_and_refuses_mismatches(self):
        legacy = self.base.copy()
        legacy["CFBundleShortVersionString"] = legacy.pop("BarkChromiumVersion")
        self.info_path.write_bytes(plistlib.dumps(legacy))
        configure_release(self.app, self.release)
        self.assertEqual(plistlib.loads(self.info_path.read_bytes())["BarkChromiumVersion"], "156.0.8078.80")
        self.info_path.write_bytes(plistlib.dumps({**self.base, "BarkChromiumVersion": "155.0.0.1"}))
        with self.assertRaisesRegex(ValueError, "embedded engine"):
            configure_release(self.app, self.release)

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
