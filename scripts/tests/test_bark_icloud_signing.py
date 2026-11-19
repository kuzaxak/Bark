"""Bark Developer ID profile and outer entitlement checks."""

from datetime import datetime, timedelta, timezone
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bark_icloud_signing as signing


class SigningTests(unittest.TestCase):
    def setUp(self):
        storage = tempfile.TemporaryDirectory()
        self.addCleanup(storage.cleanup)
        self.stage = Path(storage.name)
        self.app = self.stage / "Bark.app"
        self.contents = self.app / "Contents"
        self.contents.mkdir(parents=True)
        self.info = self.contents / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleIdentifier": signing.BUNDLE_ID}))
        self.packaging = self.stage / "Bark Packaging"
        self.packaging.mkdir()
        self.entitlements = self.packaging / "app-entitlements.plist"
        self.entitlements.write_bytes(plistlib.dumps({"com.apple.security.device.camera": True}))
        self.source = self.stage / "source.provisionprofile"
        self.source.write_bytes(b"fixture envelope")
        now = datetime.now(timezone.utc).replace(tzinfo=None)
        self.profile = {
            "ProvisionsAllDevices": True, "Platform": ["OSX"],
            "TeamIdentifier": ["A123456BCD"], "DeveloperCertificates": [b"leaf DER"],
            "CreationDate": now - timedelta(days=1), "ExpirationDate": now + timedelta(days=1),
            "Entitlements": {
                signing.APP_ID: "A123456BCD.ee.qdo.bark", signing.TEAM_ID: "A123456BCD",
                signing.CONTAINERS: [signing.CONTAINER], signing.SERVICES: "*",
                signing.ENVIRONMENT: ["Development", "Production"], signing.PUSH: "production",
            },
        }

    def test_profile_free_signing_leaves_engine_entitlements_unchanged(self):
        original = self.entitlements.read_bytes()
        self.assertIsNone(signing.prepare_profile(self.stage, None))
        self.assertEqual(signing.signed_cloud_entitlements(self.app, signing.BUNDLE_ID), {})
        self.assertEqual(self.entitlements.read_bytes(), original)
        self.assertNotIn(signing.SHARE_ACTIVATION, plistlib.loads(self.info.read_bytes()))
        (self.contents / signing.PROFILE_NAME).write_bytes(b"unexpected profile")
        with self.assertRaisesRegex(ValueError, "explicitly"):
            signing.prepare_profile(self.stage, None)

    def test_stages_profile_and_exact_production_entitlements_only_on_outer_app(self):
        with patch.object(signing, "load_profile", return_value=self.profile) as load:
            staged = signing.prepare_profile(self.stage, self.source)
        load.assert_called_once()
        self.assertEqual(staged, self.contents / signing.PROFILE_NAME)
        self.assertEqual(staged.read_bytes(), self.source.read_bytes())
        self.assertNotIn(signing.SHARE_ACTIVATION, plistlib.loads(self.info.read_bytes()))
        self.assertEqual(plistlib.loads(self.entitlements.read_bytes()), {
            "com.apple.security.device.camera": True,
            signing.APP_ID: "A123456BCD.ee.qdo.bark", signing.TEAM_ID: "A123456BCD",
            signing.CONTAINERS: [signing.CONTAINER], signing.SERVICES: ["CloudKit"],
            signing.ENVIRONMENT: "Production", signing.PUSH: "production",
        })

    def test_share_activation_requires_profile_and_sdk_capability(self):
        header = self.stage / "barc_bridge_api.h"
        header.write_text("#define BARC_BRIDGE_VERSION 13\n")
        self.assertFalse(signing.supports_cloud_share_activation(self.stage))
        header.write_text("#define BARC_HAS_CLOUD_SHARE_ACTIVATION 1\n")
        self.assertTrue(signing.supports_cloud_share_activation(self.stage))
        self.assertIsNone(signing.prepare_profile(self.stage, None, share_activation=True))
        self.assertNotIn(signing.SHARE_ACTIVATION, plistlib.loads(self.info.read_bytes()))
        with patch.object(signing, "load_profile", return_value=self.profile):
            signing.prepare_profile(self.stage, self.source, share_activation=True)
        info = plistlib.loads(self.info.read_bytes())
        signing.verify_share_activation(info, expected=True)
        with self.assertRaisesRegex(ValueError, "requires both"):
            signing.verify_share_activation(info, expected=False)
        with self.assertRaisesRegex(ValueError, "requires CKSharingSupported"):
            signing.verify_share_activation({}, expected=True)

    def test_refuses_profiles_for_the_wrong_bundle_environment_or_scope(self):
        grants = self.profile["Entitlements"]
        for key, value in (
            (signing.APP_ID, "A123456BCD.*"), (signing.APP_ID, "A123456BCD.ee.qdo.nook"),
            (signing.TEAM_ID, "Z987654ABC"), (signing.CONTAINERS, ["iCloud.ee.qdo.nook"]),
            (signing.SERVICES, ["CloudDocuments"]), (signing.ENVIRONMENT, ["Development"]),
            (signing.PUSH, "development"), ("get-task-allow", True),
        ):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                signing.authorized_entitlements(
                    {**self.profile, "Entitlements": {**grants, key: value}}, signing.BUNDLE_ID)
        for key, value in (
            ("ProvisionsAllDevices", False), ("Platform", ["iOS"]),
            ("DeveloperCertificates", []), ("ExpirationDate", self.profile["CreationDate"]),
        ):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                signing.authorized_entitlements({**self.profile, key: value}, signing.BUNDLE_ID)

    def test_verification_binds_the_embedded_profile_to_the_developer_id_leaf(self):
        embedded = self.contents / signing.PROFILE_NAME
        embedded.write_bytes(b"fixture")

        def codesign(command, **kwargs):
            if "--extract-certificates" in command:
                (Path(kwargs["cwd"]) / "codesign0").write_bytes(b"leaf DER")
            else:
                self.assertIn('certificate leaf[subject.OU] = "A123456BCD"', command[-2])
                self.assertIn("1.2.840.113635.100.6.1.13", command[-2])
            return subprocess.CompletedProcess(command, 0)

        with patch.object(signing, "load_profile", return_value=self.profile) as load, \
                patch.object(signing.subprocess, "run", side_effect=codesign):
            self.assertEqual(signing.signed_cloud_entitlements(self.app, signing.BUNDLE_ID),
                             signing.authorized_entitlements(self.profile, signing.BUNDLE_ID))
            load.assert_called_once_with(embedded)
            self.profile["DeveloperCertificates"] = [b"other leaf"]
            with self.assertRaisesRegex(ValueError, "certificate is absent"):
                signing.signed_cloud_entitlements(self.app, signing.BUNDLE_ID)


if __name__ == "__main__":
    unittest.main()
