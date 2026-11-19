"""Check update trust, per-architecture routing, and release version independence."""

import base64
import hashlib
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
from bark_release import (SPARKLE, TEAM, check_distribution_settings, configure_release,
                          expected_additions, make_distribution, make_personal_image, production_settings,
                          verify_installed_image, write_appcast)


class NookReleaseSourceTests(unittest.TestCase):
    def test_requires_legacy_project_and_shared_scheme_before_release(self):
        with tempfile.TemporaryDirectory() as workspace:
            root = Path(workspace)
            script = root / "scripts/release.sh"
            script.parent.mkdir()
            shutil.copy(Path(__file__).resolve().parents[1] / "release.sh", script)
            project = root / "Nook.xcodeproj/project.pbxproj"
            scheme = root / "Nook.xcodeproj/xcshareddata/xcschemes/Nook.xcscheme"
            scheme.parent.mkdir(parents=True)
            for has_project, has_scheme in ((False, False), (True, False), (False, True), (True, True)):
                with self.subTest(project=has_project, scheme=has_scheme):
                    for path, present in ((project, has_project), (scheme, has_scheme)):
                        if present:
                            path.touch()
                        else:
                            path.unlink(missing_ok=True)
                    result = subprocess.run([script, "--check-source"], capture_output=True, text=True)
                    if has_project and has_scheme:
                        self.assertEqual(result.returncode, 0, result.stderr)
                    else:
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn("Prepare Bark Candidate", result.stderr)
                    self.assertFalse((root / "build").exists())


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

                def exercise(installed):
                    self.assertEqual(installed, installation[0])
                    self.assertTrue(installed.is_dir())
                    events.append("exercise")

                with mock.patch("bark_release.subprocess.run", side_effect=run), mock.patch(
                    "bark_release.subprocess.check_output",
                    side_effect=["CDHash=abc123", "CDHash=bad456" if failure == "identity" else "CDHash=abc123"],
                ):
                    if failure in ("sdk", "identity"):
                        with self.assertRaises(ValueError):
                            verify_installed_image(image, self.app, self.root, requirement, verify_sdk, exercise=exercise)
                    elif failure:
                        with self.assertRaises(subprocess.CalledProcessError):
                            verify_installed_image(image, self.app, self.root, requirement, verify_sdk, exercise=exercise)
                    else:
                        verify_installed_image(image, self.app, self.root, requirement, verify_sdk, exercise=exercise)
                expected = {
                    None: ["image", "attach", "copy", "detach", "seal", "sdk", "execution", "exercise"],
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
        # SHA-256 of the decoded public key from the Nook v1.5.4 release tag.
        for settings in (arm, self.release):
            key = base64.b64decode(settings["SUPublicEDKey"], validate=True)
            self.assertEqual(hashlib.sha256(key).hexdigest(),
                             "f46c966e34a796e0a015f6758d9dae06da33a12511108c690567ca8985291ecb")
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
        self.info_path.write_bytes(plistlib.dumps({**self.base, "CKSharingSupported": True}))
        configure_release(self.app, settings)
        info = plistlib.loads(self.info_path.read_bytes())
        self.assertNotIn("CFBundleDocumentTypes", info)
        expected = plistlib.loads(expected_additions(settings, self.root).read_bytes())["Info"]
        self.assertNotIn("CFBundleDocumentTypes", expected)
        self.assertEqual(expected["BarkUpdateRehearsal"], settings["BarkUpdateRehearsal"])
        self.assertNotIn("CKSharingSupported", info)
        with self.assertRaises(ValueError):
            check_distribution_settings({**info, "CKSharingSupported": True}, "x86_64",
                                        "http://127.0.0.1:8791/releases/")
        check_distribution_settings(info, "x86_64", "http://127.0.0.1:8791/releases/")
        with self.assertRaises(ValueError):
            check_distribution_settings(info, "x86_64", "http://127.0.0.1:9911/releases/")

    def test_distribution_uses_verified_staged_team_for_rehearsal_only(self):
        other = "ABC123DE45"
        for rehearsal, app_team, image_team, succeeds in (
            (True, other, other, True),
            (True, other, TEAM, False),
            (True, "not set", TEAM, False),
            (False, other, other, False),
            (False, TEAM, TEAM, True),
        ):
            with self.subTest(rehearsal=rehearsal, app_team=app_team, image_team=image_team):
                self.info_path.write_bytes(plistlib.dumps(self.base))
                settings = dict(self.release)
                origin = "https://downloads.example"
                if rehearsal:
                    origin = "http://127.0.0.1:8791"
                    settings.update({
                        "CFBundleIdentifier": "ee.qdo.bark.test.00000000-0000-0000-0000-000000000001",
                        "BarkUpdateRehearsal": {
                            "DataRoot": "/private/tmp/fixture",
                            "Profile": "00000000-0000-0000-0000-000000000002",
                        },
                        "SUFeedURL": origin + "/bark-macos-x86_64.xml",
                        "SUEnableAutomaticChecks": False,
                    })
                configure_release(self.app, settings)
                staged = []
                verified = mock.Mock()
                output = self.root / "release"
                bundle_id = settings.get("CFBundleIdentifier", self.base["CFBundleIdentifier"])

                def read(command, **kwargs):
                    tool = Path(command[0]).name
                    if tool == "codesign":
                        self.assertIn(command[-1], staged)
                        return f"TeamIdentifier={app_team}\nCDHash=abc123\n"
                    if tool == "du":
                        return b"1"
                    self.assertEqual(tool, "sign_update")
                    return "signature"

                def run(command, **kwargs):
                    tool = Path(command[0]).name
                    if tool == "ditto":
                        staged.append(command[-1])
                        shutil.copytree(command[-2], command[-1])
                    elif tool == "codesign" and "--verify" in command:
                        requirement = command[command.index("-R") + 1]
                        self.assertIn("anchor apple generic", requirement)
                        self.assertIn("certificate leaf[field.1.2.840.113635.100.6.1.13] exists", requirement)
                        target = command[-1]
                        if target.suffix == ".app":
                            self.assertEqual(target, staged[-1])
                            self.assertIn(f'identifier "{bundle_id}"', requirement)
                            self.assertIn("--deep", command)
                            team = app_team
                        else:
                            self.assertEqual(target.suffix, ".dmg")
                            self.assertNotIn("identifier", requirement)
                            team = image_team
                        expected_team = app_team if rehearsal else TEAM
                        self.assertIn(f'certificate leaf[subject.OU] = "{expected_team}"', requirement)
                        if team != expected_team:
                            raise subprocess.CalledProcessError(1, command)
                    elif tool == "hdiutil":
                        if command[1] == "create":
                            command[-1].write_bytes(b"DMG fixture")
                        elif command[1] == "attach":
                            shutil.copytree(staged[0], command[-2] / "Bark.app")

                with mock.patch("bark_release.subprocess.run", side_effect=run), mock.patch(
                    "bark_release.subprocess.check_output", side_effect=read,
                ):
                    args = self.app, output, "x86_64", "fixture signer", origin, self.root, "fixture key", self.root
                    if succeeds:
                        make_distribution(*args, verify_staged=verified)
                        self.assertEqual(verified.call_args_list, [mock.call(path) for path in staged])
                        self.assertEqual(len(staged), 2)
                        self.assertTrue((output / "bark-macos-x86_64.xml").is_file())
                        shutil.rmtree(output)
                    else:
                        failure = ValueError if app_team == "not set" else subprocess.CalledProcessError
                        with self.assertRaises(failure):
                            make_distribution(*args, verify_staged=verified)
                        if rehearsal and app_team != "not set":
                            verified.assert_called_once_with(staged[0])
                        else:
                            verified.assert_not_called()
                        self.assertFalse(output.exists())

    def test_personal_image_requires_the_ordinary_application(self):
        destination = self.root / "Bark.dmg"
        for metadata in [
            {"CFBundleIdentifier": "ee.qdo.bark.test.00000000-0000-4000-8000-000000000001"},
            {"BarkUpdateRehearsal": {"DataRoot": "/private/tmp/test"}},
        ]:
            with self.subTest(metadata=metadata):
                self.info_path.write_bytes(plistlib.dumps({**self.base, **metadata}))
                with self.assertRaisesRegex(ValueError, "ordinary signed"):
                    make_personal_image(self.app, destination, "signer", mock.Mock())
                self.assertFalse(destination.exists())

    def test_personal_image_requires_the_reopened_app_to_match(self):
        for mismatch in (True, False):
            with self.subTest(mismatch=mismatch):
                destination = self.root / f"Bark-mismatch-{mismatch}.dmg"
                copies = []
                verified = mock.Mock()

                def run(command, **kwargs):
                    tool = Path(command[0]).name
                    if tool == "ditto":
                        copies.append(command[-1])
                        shutil.copytree(command[-2], command[-1])
                    elif tool == "hdiutil" and command[1] == "create":
                        command[-1].write_bytes(b"DMG fixture")
                    elif tool == "hdiutil" and command[1] == "attach":
                        self.assertTrue({"-readonly", "-nobrowse", "-noautoopen"} <= set(command))
                        shutil.copytree(copies[0], command[-2] / "Bark.app")
                    else:
                        self.assertNotEqual(tool, "spctl")

                def read(command, **kwargs):
                    if command[0] == "du":
                        return b"1"
                    installed_copy = len(copies) > 1 and command[-1] == copies[-1]
                    return "CDHash=bad456\n" if mismatch and installed_copy else "CDHash=abc123\n"

                with mock.patch("bark_release.subprocess.run", side_effect=run), mock.patch(
                    "bark_release.subprocess.check_output", side_effect=read,
                ):
                    if mismatch:
                        with self.assertRaisesRegex(ValueError, "copied from the disk image differs"):
                            make_personal_image(self.app, destination, "signer", verified)
                        self.assertFalse(destination.exists())
                        verified.assert_called_once_with(copies[0])
                    else:
                        make_personal_image(self.app, destination, "signer", verified)
                        self.assertEqual(verified.call_args_list, [mock.call(path) for path in copies])
                        self.assertEqual(destination.read_bytes(), b"DMG fixture")
                self.assertEqual(len(copies), 2)

    def test_personal_image_preserves_app_and_previous_exports(self):
        with self.assertRaisesRegex(ValueError, "outside the signed application"):
            make_personal_image(self.app, self.app / "Bark.dmg", "signer", mock.Mock())
        previous = self.root / "Bark.dmg"
        previous.write_bytes(b"previous image")
        with self.assertRaisesRegex(ValueError, "new .dmg"):
            make_personal_image(self.app, previous, "signer", mock.Mock())
        self.assertEqual(previous.read_bytes(), b"previous image")

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
