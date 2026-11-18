"""Exercise interrupted engine recipe preparation with tiny Git fixtures."""
import argparse
import plistlib
from contextlib import redirect_stdout
from io import StringIO
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

import build_engine


class InterruptedPreparationTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        root = Path(scratch.name)
        self.src = root / "src"
        self.src.mkdir()
        self.marker = root / ".bark-engine-preparing"

        def git(*args):
            return subprocess.check_output(["git", "-C", self.src, *args], text=True)

        git("init", "--quiet")
        base = "original\nline two\nline three\nline four\n"
        names = ("first.cc", "second.cc")
        for name in names:
            (self.src / name).write_text(base)
        git("add", ".")
        git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture",
            "-c", "user.email=fixture@example.invalid", "-c", "commit.gpgsign=false",
            "commit", "--quiet", "-m", "Pristine upstream")

        self.patches = root / "patches"
        self.patches.mkdir()
        for name in names:
            upstream = self.src / name
            upstream.write_text(base.replace("original", "patched"))
            (self.patches / f"{name}.patch").write_text(git("diff", "HEAD", "--", name))
            upstream.write_text(base)

        mounts = {}
        for name in ("bark", "chromium_src"):
            mounts[name] = root / name
            mounts[name].mkdir()
            (mounts[name] / "owned.cc").write_text(f"recipe {name}\n")
        for name, value in (("PATCHES", self.patches), ("MOUNTS", mounts),
                            ("replay", mock.Mock())):
            change = mock.patch.object(build_engine, name, value)
            change.start()
            self.addCleanup(change.stop)

    def interrupt_after_first_mount(self):
        copy = shutil.copy2

        def stop_on_second_mount(source, dest):
            if source.parent.name == "chromium_src":
                raise InterruptedError("fixture interruption")
            return copy(source, dest)

        with mock.patch.object(build_engine.shutil, "copy2", stop_on_second_mount):
            with self.assertRaisesRegex(InterruptedError, "fixture interruption"):
                build_engine.apply_recipe(self.src, self.marker)
        self.assertTrue(self.marker.is_file())
        self.assertTrue((self.src / "bark/owned.cc").is_file())
        self.assertFalse((self.src / "chromium_src/owned.cc").exists())

    def test_resume_keeps_existing_mount_and_finishes_pending_patch(self):
        self.interrupt_after_first_mount()
        existing_mount = self.src / "bark/owned.cc"
        previous_inode = existing_mount.stat().st_ino
        build_engine.patches(self.src, inputs=[self.patches / "first.cc.patch"])
        build_engine.apply_recipe(self.src, self.marker)
        self.assertEqual(existing_mount.stat().st_ino, previous_inode)
        self.assertTrue((self.src / "chromium_src/owned.cc").is_file())
        for name in ("first.cc", "second.cc"):
            self.assertTrue((self.src / name).read_text().startswith("patched\n"))
        self.assertFalse(self.marker.exists())
        build_engine.replay.assert_called_once_with(self.src)

    def test_resume_refuses_to_change_an_edited_mount(self):
        self.interrupt_after_first_mount()
        edited = self.src / "bark/owned.cc"
        edited.write_text("local edit\n")
        with self.assertRaisesRegex(ValueError, "differs from the interrupted recipe mount"):
            build_engine.apply_recipe(self.src, self.marker)
        self.assertEqual(edited.read_text(), "local edit\n")
        self.assertFalse((self.src / "chromium_src/owned.cc").exists())
        self.assertTrue(self.marker.exists())

    def test_resume_refuses_an_upstream_edit_within_a_patch_file(self):
        self.interrupt_after_first_mount()
        edited = self.src / "first.cc"
        build_engine.patches(self.src, inputs=[self.patches / "first.cc.patch"])
        local = edited.read_text() + "local edit\n"
        edited.write_text(local)
        with self.assertRaisesRegex(ValueError, "local edits within Chromium patch files"):
            build_engine.apply_recipe(self.src, self.marker)
        self.assertEqual(edited.read_text(), local)
        self.assertFalse((self.src / "chromium_src/owned.cc").exists())
        self.assertTrue(self.marker.exists())


class BuildArchitectureTests(unittest.TestCase):
    def test_cli_defaults_to_native_gn_cpu_and_accepts_a_cross_build(self):
        for hardware, extra, expected in (("arm64", [], "arm64"), ("x86_64", [], "x64"),
                                           ("arm64", ["--arch", "x64"], "x64")):
            argv = ["recipe", "build", "--dry-run", "--checkout", "/tmp/bark-fixture/checkout", *extra]
            with self.subTest(hardware=hardware, flags=extra), mock.patch("sys.argv", argv), \
                    mock.patch.object(build_engine, "native_architecture", return_value=hardware), \
                    mock.patch.object(build_engine, "build") as build:
                build_engine.main()
                self.assertEqual(build.call_args.args[-1].arch, expected)

    def test_dry_run_selects_matching_cargo_target_and_gn_output(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            src = checkout / "src"
            src.mkdir()
            for arch, target in (("x64", "x86_64-apple-darwin"), ("arm64", "aarch64-apple-darwin")):
                with self.subTest(arch=arch):
                    out = src / "out" / f"Barc-{arch}"
                    out.mkdir(parents=True)
                    shutil.copy(build_engine.HERE / f"args-{arch}.gn", out / "args.gn")
                    args = argparse.Namespace(arch=arch, official=False, dry_run=True, jobs=2)
                    output = StringIO()
                    with mock.patch.object(build_engine, "verify_gclient"), mock.patch.object(
                        build_engine, "repository"
                    ), mock.patch.object(build_engine, "replay"), redirect_stdout(output):
                        build_engine.build(checkout, checkout / "tools", {}, args)
                    commands = output.getvalue()
                    self.assertIn(f"--target {target} --target-dir {src / 'out/BarkCargo'}", commands)
                    self.assertIn(f"gn gen out/Barc-{arch}", commands)
                    self.assertIn(f"autoninja -C out/Barc-{arch}", commands)
                    self.assertFalse((src / "bark").exists())
                    self.assertFalse((src / "out/BarkCargo").exists())


    def test_official_build_uses_target_profile_and_a_separate_gn_and_cargo_directory(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            for arch, pgo in (("x64", "mac"), ("arm64", "mac-arm")):
                with self.subTest(arch=arch):
                    args = argparse.Namespace(arch=arch, official=True, dry_run=True, jobs=3)
                    output = StringIO()
                    with mock.patch.object(build_engine, "verify_gclient"), mock.patch.object(
                        build_engine, "repository"
                    ), mock.patch.object(build_engine, "replay"), redirect_stdout(output):
                        build_engine.build(checkout, checkout / "tools", {}, args)
                    self.assertIn(f"update_pgo_profiles.py --target={pgo} update", output.getvalue())
                    self.assertIn("BarkCargo-official", output.getvalue())
                    self.assertIn(f"gn gen out/Barc-{arch}-official", output.getvalue())
                    self.assertIn("-load @config//official_pgo.star", output.getvalue())
                    gn = build_engine.engine_args(arch, True).decode().splitlines()
                    self.assertIn("is_official_build = true", gn)
                    self.assertIn("chrome_pgo_phase = 2", gn)
                    wrapper = build_engine.OFFICIAL_CC_WRAPPER
                    self.assertIn(f'cc_wrapper = "./{wrapper}"', gn)
                    self.assertIn(f"/{wrapper} ", output.getvalue())
                    self.assertIn(f'"command_prefix": "./{wrapper} "',
                                  (build_engine.HERE / "official_pgo.star").read_text())
                    self.assertIn(b'cc_wrapper = "./bark_override_cc"\n',
                                  build_engine.engine_args(arch, False))
                    self.assertIn(f'target_cpu = "{arch}"', gn)
                    self.assertIn('mac_sdk_min = "26.5"', gn)
                    self.assertNotIn("is_official_build = false", gn)
                    self.assertFalse((checkout / "src/out").exists())

    def test_official_output_migrates_atomically_and_retries(self):
        with tempfile.TemporaryDirectory() as directory:
            checkout = Path(directory)
            out = checkout / "src/out/Barc-arm64-official"
            out.mkdir(parents=True)
            selector = checkout / "src/chrome/build/mac-arm.pgo.txt"
            selector.parent.mkdir(parents=True)
            selector.write_text(build_engine.PINS["official_pgo_profiles"]["mac-arm"] + "\n")
            output_args = out / "args.gn"
            configured = build_engine.engine_args("arm64", True)
            previous = configured.replace(b'cc_wrapper = "./bark_official_pgo_cc_v1"\n',
                                          b'cc_wrapper = "./bark_override_cc"\n')
            self.assertNotEqual(previous, configured)
            output_args.write_bytes(previous)
            existing_product = out / "keep.o"
            existing_product.touch()
            args = argparse.Namespace(arch="arm64", official=True, dry_run=True, jobs=2)
            with mock.patch.multiple(build_engine, verify_gclient=mock.DEFAULT,
                                     repository=mock.DEFAULT, replay=mock.DEFAULT,
                                     official_sdk=mock.DEFAULT, run=mock.DEFAULT) as commands:
                build_engine.build(checkout, checkout / "tools", {}, args)
                self.assertEqual(output_args.read_bytes(), previous)
                commands["official_sdk"].assert_not_called()

                args.dry_run = False
                with mock.patch.object(Path, "replace", side_effect=InterruptedError("replace")):
                    with self.assertRaisesRegex(InterruptedError, "replace"):
                        build_engine.build(checkout, checkout / "tools", {}, args)
                self.assertEqual(output_args.read_bytes(), previous)
                self.assertEqual(set(out.iterdir()), {output_args, existing_product})

                modified = previous + b"# external edit\n"
                write_bytes = Path.write_bytes

                def edit_during_staging(path, data):
                    write_bytes(path, data)
                    write_bytes(output_args, modified)

                with mock.patch.object(Path, "write_bytes", edit_during_staging):
                    with self.assertRaisesRegex(ValueError, "changed during build setup"):
                        build_engine.build(checkout, checkout / "tools", {}, args)
                self.assertEqual(output_args.read_bytes(), modified)

                for invalid in (modified, build_engine.engine_args("arm64", False)):
                    output_args.write_bytes(invalid)
                    commands["run"].reset_mock()
                    with self.assertRaisesRegex(ValueError, "fresh GN output directory"):
                        build_engine.build(checkout, checkout / "tools", {}, args)
                    commands["run"].assert_not_called()
                    self.assertEqual(output_args.read_bytes(), invalid)

                output_args.write_bytes(previous)
                commands["run"].side_effect = InterruptedError("profile preparation")
                for _ in range(2):
                    with self.assertRaisesRegex(InterruptedError, "profile preparation"):
                        build_engine.build(checkout, checkout / "tools", {}, args)
                    self.assertEqual(output_args.read_bytes(), configured)
                    self.assertEqual(set(out.iterdir()), {output_args, existing_product})

    def test_official_build_checks_sdk_version_and_build_id(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)
            info = path / "System/Library/CoreServices/SystemVersion.plist"
            info.parent.mkdir(parents=True)
            with mock.patch.object(build_engine.subprocess, "check_output", return_value=str(path)):
                for version, build, matches in (("26.2", "25C58", False), ("26.5", "other", False),
                                                ("26.5", "25F70", True)):
                    with self.subTest(version=version, build=build):
                        info.write_bytes(plistlib.dumps({"ProductVersion": version, "ProductBuildVersion": build}))
                        if matches:
                            self.assertEqual(build_engine.official_sdk(), path)
                        else:
                            with self.assertRaisesRegex(ValueError, "Official Bark builds require"):
                                build_engine.official_sdk()


if __name__ == "__main__":
    unittest.main()
