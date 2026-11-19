# Licensed under GPL-3.0. See LICENSE.
"""Exercise shell provenance with synthetic source and app fixtures."""

from contextlib import nullcontext, redirect_stdout
from io import StringIO
import os
from pathlib import Path
import plistlib
import runpy
import shutil
import sys
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import Mock, patch

SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))
import bark_shell_source as shell


class SourceTests(unittest.TestCase):
    def test_shell_identity_includes_the_shipping_plist_generator_when_used(self):
        self.make_shell_inputs()
        legacy = shell.shell_source_digest(self.root)
        generator = self.write("scripts/bark_outer_info.py")
        self.assertEqual(shell.shell_source_digest(self.root), legacy)
        self.write("ChromiumApp/Build-Info.plist")
        staged = shell.shell_source_digest(self.root)
        generator.write_bytes(b"changed shipping identity")
        self.assertNotEqual(shell.shell_source_digest(self.root), staged)

    def setUp(self):
        scratch = TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name)

    def write(self, name, content=b"value"):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)
        return path

    def make_shell_inputs(self):
        for name in shell._INPUTS:
            path = Path(name)
            if not path.suffix or path.name == "xcshareddata":
                path = path / "fixture"
            self.write(path)
        self.write(shell._PROJECT, b"""
        // !$*UTF8*$!
        { rootObject = project; objects = {
            project = { isa = PBXProject; mainGroup = root; targets = (shell,); };
            root = { isa = PBXGroup; sourceTree = "<group>"; children = (app, palette, navigation, explicit,); };
            shell = { isa = PBXNativeTarget; name = BarkNativeShell; fileSystemSynchronizedGroups = (app,);
                      buildPhases = (sources,); };
            app = { isa = PBXFileSystemSynchronizedRootGroup; path = App; sourceTree = "<group>";
                    exceptions = (excluded,); };
            palette = { isa = PBXFileSystemSynchronizedRootGroup; path = CommandPalette; sourceTree = "<group>";
                        exceptions = (includedPalette,); };
            navigation = { isa = PBXFileSystemSynchronizedRootGroup; path = Navigation; sourceTree = "<group>";
                           exceptions = (includedNavigation,); };
            excluded = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; target = shell;
                         membershipExceptions = (excluded.swift,); };
            includedPalette = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; target = shell;
                                membershipExceptions = ("Accessories/Command Item.swift",); };
            includedNavigation = { isa = PBXFileSystemSynchronizedBuildFileExceptionSet; target = shell;
                                   membershipExceptions = (Sidebar/SidebarHeader.swift,); };
            explicit = { isa = PBXGroup; path = Other; sourceTree = "<group>"; children = (file,); };
            file = { isa = PBXFileReference; path = Explicit.swift; sourceTree = "<group>"; };
            sources = { isa = PBXSourcesBuildPhase; files = (buildFile,); };
            buildFile = { isa = PBXBuildFile; fileRef = file; };
        }; }
        """)
        for member in ("App/member.swift", "CommandPalette/Accessories/Command Item.swift",
                       "Navigation/Sidebar/SidebarHeader.swift", "Other/Explicit.swift"):
            self.write(member)
        for package in shell._PACKAGES:
            self.write(f"Packages/{package}/Package.swift")
            self.write(f"Packages/{package}/Sources/fixture.swift")
        self.write(shell._ADBLOCK_BINARY / "libnook_adblock.a")
        self.write(shell._SDK_INTERFACE / "macos-arm64_x86_64/Headers/BarcChromium/public.h")

    def test_checkout_and_archive_match_but_dirty_inputs_do_not(self):
        self.make_shell_inputs()
        sdk = shell._SDK_INTERFACE
        original = shell.shell_source_digest(self.root)
        archive = self.root / "archive"
        shutil.copytree(self.root, archive)
        for ignored in (".git/HEAD", "README.md", "Tests/fixture.swift", "build/Bark.app/Contents/MacOS/Bark",
                        "Packages/NookWeb/.build/derived", "Packages/NookWeb/Tests/fixture.swift",
                        "CommandPalette/legacy.swift", "Navigation/legacy.swift", "App/excluded.swift",
                        "Other/unlisted.swift",
                        shell._RUST / "Cargo.lock", shell._RUST / "target/compiled",
                        "Packages/BarkEngine/RuntimeArtifacts/x86_64/Engine/framework",
                        sdk / "macos-x86_64/Engine/framework",
                        sdk / "macos-arm64_x86_64/Headers/BarcChromium/engine-artifact-x86_64.sha256"):
            self.write(ignored, b"changed")
        self.assertEqual(shell.shell_source_digest(self.root), original)
        self.assertEqual(shell.shell_source_digest(archive), original)

        for changed in ("App/new.swift", "Packages/NookWeb/Sources/fixture.swift",
                        shell._PROJECT, "CommandPalette/Accessories/Command Item.swift",
                        "Navigation/Sidebar/SidebarHeader.swift", "Other/Explicit.swift",
                        shell._ADBLOCK_BINARY / "libnook_adblock.a",
                        sdk / "macos-arm64_x86_64/Headers/BarcChromium/public.h"):
            with self.subTest(changed=changed):
                path = self.root / changed
                prior = path.read_bytes() if path.exists() else None
                self.write(changed, prior + b"\n// dirty project\n" if changed == shell._PROJECT else b"dirty")
                self.assertNotEqual(shell.shell_source_digest(self.root), original)
                if prior is None:
                    path.unlink()
                else:
                    path.write_bytes(prior)

    def test_relocated_links_bind_destinations_and_file_contents(self):
        self.make_shell_inputs()
        source = self.write("Shared/first.swift", b"shared code")
        self.write("Shared/second.swift", b"shared code")
        link = self.root / "App/relative.swift"
        link.symlink_to("../Shared/first.swift")
        linked = shell.shell_source_digest(self.root)
        source.write_bytes(b"edited shared code")
        self.assertNotEqual(shell.shell_source_digest(self.root), linked)
        link.unlink()
        link.symlink_to("../Shared/second.swift")
        self.assertNotEqual(shell.shell_source_digest(self.root), linked)
        link.unlink()
        alias = self.root / "App/Shared"
        alias.symlink_to("../Shared", target_is_directory=True)
        moved = self.root / "relocated"
        shutil.copytree(self.root, moved, symlinks=True, ignore=shutil.ignore_patterns("relocated", "archive"))
        self.assertEqual(shell.shell_source_digest(moved), shell.shell_source_digest(self.root))
        alias.unlink()
        alias.symlink_to("Shared")
        with self.assertRaises((ValueError, OSError)):
            shell.shell_source_digest(self.root)
        alias.unlink()
        alias.symlink_to(".", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "Directory cycle"):
            shell.shell_source_digest(self.root)
        alias.unlink()
        alias.symlink_to("../..", target_is_directory=True)
        with self.assertRaisesRegex(ValueError, "within the checkout"):
            shell.shell_source_digest(self.root)

    def test_native_shell_omits_source_only_rust_and_webkit_reports(self):
        checkout = SCRIPTS.parent
        reports = {
            Path("Nook/Managers/ExtensionManager/README-URLSchemeHandler.md"),
            Path("Nook/Utils/Debug/NavigationRootCauseAnalysis.md"),
        }
        def rust_source_paths(root):
            sources = set()
            for directory, children, files in os.walk(root / shell._RUST):
                children[:] = [name for name in children
                               if name not in {"target", ".git", shell._ADBLOCK_BINARY.name}]
                sources.update((Path(directory) / name).relative_to(root)
                               for name in files if name != ".DS_Store")
            return sources

        source = shell._RUST / "src/fixture.rs"
        self.write(source)
        self.write(shell._RUST / "target/debug/build/ignored/generated.rs")
        self.assertEqual(rust_source_paths(self.root), {source})

        rust_sources = rust_source_paths(checkout)
        self.assertTrue(rust_sources)
        groups = shell._project_inputs(checkout)
        self.assertLessEqual(reports | rust_sources | {shell._ADBLOCK_BINARY}, groups[Path("Nook")])
        inputs = set(shell._inputs(checkout, {}))
        self.assertFalse(inputs & (reports | rust_sources))
        self.assertIn(shell._ADBLOCK_BINARY / "macos-arm64_x86_64/libnook_adblock.a", inputs)
        self.assertTrue(any(path.suffix == ".metal" for path in inputs))
        self.assertTrue(any("Assets.xcassets" in path.parts for path in inputs))

    def test_legacy_missing_invalid_and_verified_bundle_value(self):
        app = self.root / "Bark.app"
        info = self.write("Bark.app/Contents/Info.plist", plistlib.dumps({}))
        self.assertIsNone(shell.verify_shell_source(app))
        with self.assertRaisesRegex(ValueError, "no Bark shell source"):
            shell.verify_shell_source(app, required=True)
        shell.write_shell_source(app, "a" * 64)
        self.assertEqual(shell.verify_shell_source(app, expected="a" * 64), "a" * 64)
        with self.assertRaisesRegex(ValueError, "different Bark shell source"):
            shell.verify_shell_source(app, expected="b" * 64)
        with self.assertRaisesRegex(ValueError, "preexisting"):
            shell.write_shell_source(app, "b" * 64)
        info.write_bytes(plistlib.dumps({shell.SHELL_SOURCE_KEY: "A" * 64}))
        with self.assertRaisesRegex(ValueError, "Invalid Bark shell source"):
            shell.verify_shell_source(app)


class BuildContractTests(unittest.TestCase):
    def build(self, *, release, changed):
        cli = runpy.run_path(str(SCRIPTS / "bark-check.py"))["main"].__globals__
        with TemporaryDirectory() as directory:
            output = Path(directory).resolve() / "Bark.app"
            source = "a" * 64
            unsigned = None
            staged = None
            signed = None
            def configure_release(app, settings):
                path = app / "Contents/Info.plist"
                info = plistlib.loads(path.read_bytes())
                info.update(settings)
                path.write_bytes(plistlib.dumps(info))

            configure = Mock(side_effect=configure_release)

            def fake_run(command, *args):
                nonlocal unsigned, staged, signed
                if command == "xcodebuild":
                    derived = Path(args[args.index("-derivedDataPath") + 1])
                    unsigned = derived / "Build/Products/Release/Bark.app"
                elif command == "/bin/bash":
                    staged = Path(args[-2])
                    (staged / "Contents").mkdir(parents=True)
                    (staged / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "ee.qdo.bark"}))
                elif command == sys.executable:
                    self.assertEqual(shell.verify_shell_source(staged, required=True), source)
                    signed = args[-1] / "stable/Bark.app"
                    shutil.copytree(staged, signed)
                else:
                    self.fail(f"Unexpected build step {command}")

            def verify(app, *_args, shell_source):
                self.assertEqual(app, signed)
                self.assertEqual(shell.verify_shell_source(app, expected=shell_source), source)

            install = Mock()
            with patch.dict(cli, {"run": fake_run, "configure_release": configure, "verify_candidate": verify,
                                  "install_local_build": install, "unregister_unsigned_shell": Mock(), "verify_xcode_component": Mock(),
                                  "shell_source_digest": Mock(side_effect=[source, "b" * 64 if changed else source])}), \
                 redirect_stdout(StringIO()):
                if changed:
                    with self.assertRaisesRegex(ValueError, "changed during the build"):
                        cli["build_candidate"](Path("Engine"), output, "Fixture ID", "x86_64")
                    self.assertIsNone(signed)
                    install.assert_not_called()
                else:
                    cli["build_candidate"](Path("Engine"), output, "Fixture ID", "x86_64", {} if not release else {
                        "CFBundleVersion": "42"
                    })
                    install.assert_called_once_with(signed, output, "ee.qdo.bark")
                    self.assertEqual(configure.call_count, int(release))

    def test_developer_and_release_paths_seal_identity_before_signing(self):
        for release in (False, True):
            with self.subTest(release=release):
                self.build(release=release, changed=False)

    def test_changed_build_inputs_do_not_get_signed(self):
        self.build(release=False, changed=True)

    def test_release_package_requires_an_identity_on_the_staged_signed_app(self):
        cli = runpy.run_path(str(SCRIPTS / "bark-check.py"))["main"].__globals__
        with TemporaryDirectory() as directory:
            root = Path(directory).resolve()
            app, staged = root / "Bark.app", root / "staged/Bark.app"
            for path in [app, staged]:
                (path / "Contents").mkdir(parents=True)
                (path / "Contents/Info.plist").write_bytes(plistlib.dumps({}))
            shell.write_shell_source(app, "a" * 64)
            engine = root / "Engine"

            def distribution(*_args, verify_staged):
                verify_staged(staged)

            def verify(path, *_args, require_shell_source):
                shell.verify_shell_source(path, required=require_shell_source)

            args = ["bark-check.py", "package", str(app), "--arch", "x86_64", "--require-official",
                    "--output", str(root / "release"), "--download-base-url", "https://fixture.invalid/",
                    "--ed-key-file", "-"]
            with patch.object(sys, "argv", args), patch.dict(cli, {
                "pinned_engine": Mock(return_value=nullcontext(engine)),
                "make_distribution": distribution, "verify_candidate": verify,
            }):
                with self.assertRaisesRegex(ValueError, "no Bark shell source"):
                    cli["main"]()
                shell.write_shell_source(staged, "a" * 64)
                cli["main"]()


if __name__ == "__main__":
    unittest.main()
