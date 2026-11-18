"""Update a real Git checkout while keeping incremental compiler state."""
import contextlib
import io
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest
from unittest import mock

from update_checkout import advance


class RecipeUpdateTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.root = Path(scratch.name).resolve()
        self.src = self.root / "src"
        self.src.mkdir()
        self.git("init", "-q")
        (self.src / ".gitignore").write_text("out/\n")
        for path in ("engine.cc", "remove-patch.cc", "add-patch.cc", "unrelated.cc"):
            (self.src / path).write_text("upstream\n")
        self.git("add", ".")
        self.git("-c", "core.hooksPath=/dev/null", "-c", "user.name=Fixture", "-c", "user.email=test@local",
                 "-c", "commit.gpgsign=false", "commit", "-qm", "Base")
        self.before = self.recipe("old", {"engine.cc": "first", "remove-patch.cc": "before"})
        self.after = self.recipe("new", {"engine.cc": "second", "add-patch.cc": "after"})
        self.output = self.src / "out/current.o"
        self.output.parent.mkdir()
        self.output.write_bytes(b"compiled")
        for file in (self.before / "patches").glob("*.patch"):
            self.git("apply", str(file))
        for name in ("bark", "chromium_src"):
            shutil.copytree(self.before / name, self.src / name)

    def git(self, *args):
        return subprocess.check_output(["git", "-C", self.src, *args])

    def recipe(self, name, patches):
        root = self.root / name
        for folder in ("bark", "chromium_src", "patches"):
            (root / folder).mkdir(parents=True)
        for target, content in patches.items():
            path = self.src / target
            path.write_text(content + "\n")
            (root / "patches" / (target + ".patch")).write_bytes(self.git("diff", "--src-prefix=a/", "--dst-prefix=b/", "--", target))
            path.write_text("upstream\n")
        resource = root / "resource.bin"
        resource.write_bytes(b"\x00\xff\r\n" + name.encode())
        (root / "bark/asset.bin").symlink_to("../resource.bin")
        (root / "bark/tool").write_text("run\n")
        (root / "bark/tool").chmod(0o755 if name == "new" else 0o644)
        (root / "chromium_src" / name).write_text(name)
        return root

    def test_dry_run_and_partial_retry_preserve_build_outputs_and_index(self):
        original_index = self.git("ls-files", "--stage")
        inode = self.output.stat().st_ino
        advance(self.src, self.before, self.after, dry_run=True)
        self.assertEqual((self.src / "engine.cc").read_text(), "first\n")
        (self.src / "engine.cc").write_text("second\n")  # Part of an earlier update.
        advance(self.src, self.before, self.after)
        for target, content in {"engine.cc":"second", "remove-patch.cc":"upstream", "add-patch.cc":"after"}.items():
            self.assertEqual((self.src / target).read_text(), content + "\n")
        self.assertEqual((self.src / "bark/asset.bin").read_bytes(), b"\x00\xff\r\nnew")
        self.assertFalse((self.src / "bark/asset.bin").is_symlink())
        self.assertTrue(os.access(self.src / "bark/tool", os.X_OK))
        self.assertFalse((self.src / "chromium_src/old").exists())
        self.assertEqual((self.src / "chromium_src/new").read_text(), "new")
        with contextlib.redirect_stdout(io.StringIO()) as log:
            advance(self.src, self.before, self.after)
        self.assertIn("already matches", log.getvalue())
        self.assertEqual(self.git("ls-files", "--stage"), original_index)
        self.assertEqual(self.output.stat().st_ino, inode)
        self.assertEqual(self.output.read_bytes(), b"compiled")

    def test_local_edits_are_reported_before_other_files_change(self):
        for name in ("engine.cc", "bark/asset.bin", "unrelated.cc", "chromium_src/new"):
            path = self.src / name
            previous = path.read_bytes() if path.exists() else None
            path.write_bytes(b"my edit")
            with self.subTest(path=name), self.assertRaisesRegex(ValueError, "recipe"):
                advance(self.src, self.before, self.after)
            self.assertEqual(path.read_bytes(), b"my edit")
            self.assertEqual((self.src / "remove-patch.cc").read_text(), "before\n")
            if previous is None:
                path.unlink()
            else:
                path.write_bytes(previous)

    def test_resume_after_replacement_is_interrupted(self):
        replace = Path.replace

        def interrupt(staged, target):
            if target == self.src / "engine.cc":
                raise InterruptedError("fixture stop")
            return replace(staged, target)

        with mock.patch.object(Path, "replace", interrupt), self.assertRaises(InterruptedError):
            advance(self.src, self.before, self.after)
        self.assertTrue((self.src / "bark/asset.bin").read_bytes().endswith(b"new"))
        advance(self.src, self.before, self.after)
        self.assertEqual((self.src / "engine.cc").read_text(), "second\n")

    def test_edit_during_staging_is_not_replaced(self):
        write = Path.write_bytes

        def edit(staged, data):
            if staged.name == "engine.cc":
                write(self.src / "engine.cc", b"unsaved elsewhere")
            return write(staged, data)

        with mock.patch.object(Path, "write_bytes", edit), self.assertRaisesRegex(ValueError, "changed during"):
            advance(self.src, self.before, self.after)
        self.assertEqual((self.src / "engine.cc").read_bytes(), b"unsaved elsewhere")
        self.assertEqual((self.src / "remove-patch.cc").read_text(), "before\n")

    def test_directory_to_file_keeps_ignored_local_contents(self):
        self.git("config", "core.excludesFile", str(self.root / "ignores"))
        (self.root / "ignores").write_text("private.tmp\n")
        for tree in (self.before, self.src):
            (tree / "bark/tool").unlink()
            (tree / "bark/tool").mkdir()
            (tree / "bark/tool/source").write_bytes(b"old")
        local = self.src / "bark/tool/private.tmp"
        local.write_bytes(b"mine")
        with self.assertRaisesRegex(ValueError, "local data"):
            advance(self.src, self.before, self.after)
        self.assertEqual(local.read_bytes(), b"mine")
        self.assertEqual((self.src / "remove-patch.cc").read_text(), "before\n")
        local.unlink()
        advance(self.src, self.before, self.after)
        self.assertEqual((self.src / "bark/tool").read_text(), "run\n")

    def test_staged_file_and_missing_link_are_preserved(self):
        self.git("add", "engine.cc")
        with self.assertRaisesRegex(ValueError, "staged changes"):
            advance(self.src, self.before, self.after)
        self.git("restore", "--staged", "engine.cc")
        (self.after / "resource.bin").unlink()
        with self.assertRaisesRegex(ValueError, "missing mounted file"):
            advance(self.src, self.before, self.after)
        self.assertEqual((self.src / "engine.cc").read_text(), "first\n")


    def folded_spellings(self):
        old = self.src / "bark/tool"
        new = old.with_name("Tool")
        if not new.is_file():
            self.skipTest("requires a case-insensitive temporary filesystem")
        return old, new

    def test_case_only_file_rename_uses_the_actual_directory_entry(self):
        old, new = self.folded_spellings()
        recipe_tool = self.after / "bark/tool"
        recipe_tool.chmod(0o644)  # Same blob and mode as the old spelling.
        recipe_tool.rename(recipe_tool.with_name("Tool"))
        advance(self.src, self.before, self.after, dry_run=True)
        self.assertIn("tool", {p.name for p in old.parent.iterdir()})

        def interrupt(source, destination):
            if destination == new:
                raise InterruptedError("staged link failed")
            return link(source, destination)

        link = os.link
        with mock.patch("update_checkout.os.link", side_effect=interrupt):
            with self.assertRaisesRegex(InterruptedError, "staged link failed"):
                advance(self.src, self.before, self.after)
        self.assertFalse(old.exists())
        advance(self.src, self.before, self.after)
        self.assertEqual(new.read_text(), "run\n")
        self.assertEqual({p.name for p in old.parent.iterdir()}, {"asset.bin", "Tool"})
        advance(self.src, self.before, self.after)

    def test_case_alias_not_retired_by_recipe_is_preserved(self):
        self.folded_spellings()
        protected = self.src / "bark/extra.tmp"
        protected.write_text("ignored local file")
        (self.root / "ignores").write_text("extra.tmp\n")
        self.git("config", "core.excludesFile", str(self.root / "ignores"))
        (self.after / "bark/Extra.tmp").write_text("recipe file")
        with self.assertRaisesRegex(ValueError, "different spelling already exists"):
            advance(self.src, self.before, self.after)
        self.assertEqual(protected.read_text(), "ignored local file")
        self.assertEqual((self.src / "engine.cc").read_text(), "first\n")

    def test_case_only_directory_rename_recreates_the_spelling(self):
        self.folded_spellings()
        for recipe in (self.src, self.before):
            (recipe / "bark/widgets").mkdir()
            (recipe / "bark/widgets/item").write_bytes(b"shared")
        (self.after / "bark/Widgets").mkdir()
        (self.after / "bark/Widgets/item").write_bytes(b"shared")
        advance(self.src, self.before, self.after)
        self.assertIn("Widgets", {p.name for p in (self.src / "bark").iterdir()})
        self.assertEqual((self.src / "bark/Widgets/item").read_bytes(), b"shared")
