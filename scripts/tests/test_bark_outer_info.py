# Licensed under GPL-3.0. See LICENSE.
"""Test the separation between Xcode's shell product and signed Bark metadata."""

from copy import deepcopy
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


SCRIPTS = Path(__file__).resolve().parents[1]
REPO = SCRIPTS.parent
sys.path.insert(0, str(SCRIPTS))
from bark_outer_info import (ENGLISH_REASON, PERMISSION_KEYS, UNMODIFIED_LOCALES,
                             localize_permission_reasons, materialize_info, verify_build_info)


class BarkOuterInfoTests(unittest.TestCase):
    def setUp(self):
        self.template = plistlib.loads((REPO / "ChromiumApp/Info.plist").read_bytes())
        self.engine = {
            "CFBundleShortVersionString": "156.0.8078.105",
            "SCMRevision": "b" * 40 + "-refs/branch-heads/8078@{#1742}",
        }
        self.build = {
            "CFBundleExecutable": "Bark",
            "CFBundleIdentifier": "ee.qdo.bark.build",
            "CFBundleName": "Bark",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "1.5.4",
            "CFBundleVersion": "120",
            "LSBackgroundOnly": True,
            "BuildMachineOSBuild": "24G419",
            "CFBundleSupportedPlatforms": ["MacOSX"],
            "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
            "DTPlatformBuild": "25C58",
            "DTPlatformName": "macosx",
            "DTPlatformVersion": "26.2",
            "DTSDKBuild": "25C58",
            "DTSDKName": "macosx26.2",
            "DTXcode": "2630",
            "DTXcodeBuild": "17C529",
        }

    def test_shipped_localizations_change_only_the_seven_permission_keys(self):
        sources = REPO / "ChromiumApp/Resources"
        reasons = json.loads((sources.parent / "PermissionReasons.json").read_text())

        def parse(path):
            return plistlib.loads(subprocess.check_output(
                ["/usr/bin/plutil", "-convert", "xml1", "-o", "-", path]))

        with TemporaryDirectory() as tmp:
            resources = Path(tmp)
            for source in sources.glob("*.lproj"):
                shutil.copytree(source, resources / source.name)
            localize_permission_reasons(resources, reasons)
            localize_permission_reasons(resources, reasons)
            for path in resources.glob("*.lproj/InfoPlist.strings"):
                source = sources / path.relative_to(resources)
                locale = path.parent.stem
                with self.subTest(locale=locale):
                    if locale in UNMODIFIED_LOCALES:
                        self.assertEqual(path.read_bytes(), source.read_bytes())
                    else:
                        expected = parse(source)
                        expected.update(dict.fromkeys(PERMISSION_KEYS, reasons[locale]))
                        self.assertEqual(plistlib.loads(path.read_bytes()), expected)
        self.assertEqual(reasons["de"], "Sobald Bark Zugriff hat, können Websites dich um Zugriff bitten.")
        self.assertIn("Barkile", reasons["et"])
        self.assertIn("Bark को", reasons["hi"])
        self.assertTrue(reasons["ar"].startswith("\u200f"))
        self.assertTrue(reasons["he"].startswith("\u200f"))
        self.assertTrue(reasons["nb"].startswith("Når Bark"))

    def test_missing_locale_and_changed_reasons_are_reported_without_overwriting(self):
        with TemporaryDirectory() as tmp:
            resources = Path(tmp)
            path = resources / "de.lproj/InfoPlist.strings"
            path.parent.mkdir()
            # Localized nibs may exist without bundle-info translations.
            (resources / "Base.lproj").mkdir()
            reasons = {"de": "Sobald Bark Zugriff hat"}
            original = dict.fromkeys(PERMISSION_KEYS, ENGLISH_REASON)
            original["NSCameraUsageDescription"] = "A different upstream translation"
            path.write_bytes(plistlib.dumps(original))
            with self.assertRaisesRegex(ValueError, "Missing Bark permission localizations: et"):
                localize_permission_reasons(resources, {**reasons, "et": "Barkile"})
            with self.assertRaisesRegex(ValueError, "Missing Bark permission translations: de"):
                localize_permission_reasons(resources, {})
            with self.assertRaisesRegex(ValueError, "Unexpected Bark permission reason in de NSCamera"):
                localize_permission_reasons(resources, reasons)
            self.assertEqual(plistlib.loads(path.read_bytes()), original)

    def test_inert_build_identity_and_shape_are_required(self):
        verify_build_info(self.build)
        replacements = {
            "CFBundleIdentifier": ("ee.qdo.bark", "ee.qdo.nook", "ee.qdo.bark.sdk", "other.build"),
            "LSBackgroundOnly": (False, "YES"),
            "CFBundleExecutable": ("Other", "../Bark"),
            "CFBundlePackageType": ("BNDL",),
            "CFBundleShortVersionString": ("release",),
            "CFBundleVersion": ("invalid",),
            "BarkChromiumVersion": ("invalid",),
            "NSPrincipalClass": ("BrowserCrApplication",),
        }
        for key, values in replacements.items():
            for value in values:
                with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                    verify_build_info({**self.build, key: value})
        for key in ("CFBundleIdentifier", "LSBackgroundOnly", "CFBundleExecutable",
                    "CFBundleShortVersionString", "CFBundleVersion"):
            with self.subTest(missing=key), self.assertRaises(ValueError):
                modified = dict(self.build)
                del modified[key]
                verify_build_info(modified)

    def test_build_cannot_advertise_handlers_even_with_empty_declarations(self):
        for key, value in (
            ("CFBundleDocumentTypes", []),
            ("CFBundleURLTypes", []),
            ("UTExportedTypeDeclarations", []),
            ("UTImportedTypeDeclarations", []),
            ("NSUserActivityTypes", []),
            ("ASWebAuthenticationSessionWebBrowserSupportCapabilities", {}),
            ("CKSharingSupported", False),
            ("OSAScriptingDefinition", "scripting.sdef"),
            ("NSAppleScriptEnabled", False),
        ):
            with self.subTest(key=key), self.assertRaises(ValueError):
                verify_build_info({**self.build, key: value})

    def test_shipping_metadata_restores_handlers_and_keeps_xcode_provenance(self):
        build_before, template_before = deepcopy(self.build), deepcopy(self.template)
        info = materialize_info(self.build, self.template, self.engine)
        self.assertEqual(self.build, build_before)
        self.assertEqual(self.template, template_before)
        self.assertEqual(info["CFBundleIdentifier"], "ee.qdo.bark")
        self.assertEqual(info["CFBundleExecutable"], "Bark")
        self.assertEqual(info["CFBundleName"], "Bark")
        self.assertEqual(info["CFBundleDisplayName"], "Bark")
        self.assertEqual(info["CFBundlePackageType"], "APPL")
        self.assertEqual(info["NSPrincipalClass"], "BrowserCrApplication")
        self.assertEqual(info["OSAScriptingDefinition"], "scripting.sdef")
        self.assertNotIn("LSBackgroundOnly", info)
        self.assertEqual(info["BarkChromiumVersion"], self.engine["CFBundleShortVersionString"])
        self.assertEqual(info["SCMRevision"], self.engine["SCMRevision"])
        for key in ("CFBundleShortVersionString", "CFBundleVersion"):
            self.assertEqual(info[key], self.build[key])
        for key in ("CFBundleURLTypes", "CFBundleDocumentTypes", "UTExportedTypeDeclarations",
                    "ASWebAuthenticationSessionWebBrowserSupportCapabilities"):
            with self.subTest(key=key):
                self.assertEqual(info[key], self.template[key])
                self.assertTrue(info[key])
        schemes = {scheme for declaration in info["CFBundleURLTypes"]
                   for scheme in declaration["CFBundleURLSchemes"]}
        self.assertTrue({"http", "https"} <= schemes)
        for key, value in self.build.items():
            if key.startswith("DT") or key in ("BuildMachineOSBuild", "CFBundleSupportedPlatforms"):
                self.assertEqual(info[key], value)

    def test_unknown_template_setting_fails_closed(self):
        template = {**self.template, "Unresolved": {"Nested": ["$(UNDEFINED_BARK_SETTING)"]}}
        with self.assertRaises(ValueError):
            materialize_info(self.build, template, self.engine)

    def test_legacy_build_version_must_match_the_selected_sdk(self):
        build = {**self.build, "BarkChromiumVersion": self.engine["CFBundleShortVersionString"]}
        result = materialize_info(build, self.template, self.engine)
        self.assertEqual(result["BarkChromiumVersion"], build["BarkChromiumVersion"])
        build["BarkChromiumVersion"] = "156.0.8078.80"
        with self.assertRaisesRegex(ValueError, "differs from the pinned engine"):
            materialize_info(build, self.template, self.engine)

    def test_shipping_requires_a_version_and_revision_from_the_sdk(self):
        for key, value in (("CFBundleShortVersionString", "156.0"), ("CFBundleShortVersionString", 156),
                           ("SCMRevision", ""), ("SCMRevision", None)):
            with self.subTest(key=key, value=value), self.assertRaises(ValueError):
                materialize_info(self.build, self.template, {**self.engine, key: value})


if __name__ == "__main__":
    unittest.main()
