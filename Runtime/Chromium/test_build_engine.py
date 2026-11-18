"""Exercise interrupted engine recipe preparation with tiny Git fixtures."""
import argparse
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
                    args = argparse.Namespace(arch=arch, dry_run=True, jobs=2)
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


if __name__ == "__main__":
    unittest.main()
