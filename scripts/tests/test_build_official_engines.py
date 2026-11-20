"""Test the release runner's cache and sequential engine orchestration."""

import importlib.util
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

SPEC = importlib.util.spec_from_file_location(
    "build_official_engines", Path(__file__).resolve().parents[1] / "runner/build_official_engines.py",
)
builder = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(builder)


class RunnerEngineTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.scratch = Path(scratch.name)
        self.checkout = self.scratch / "checkout"
        self.state = self.checkout / ".bark-runner-recipe.json"

    def test_prepare_adopt_and_advance_recipe(self):
        with patch.object(builder, "run") as run:
            builder.prepare_checkout(self.checkout, "original", "first", 6)
            args = run.call_args.args
            self.assertEqual(args[3:5], ("prepare", "--resume"))
            self.assertEqual(args[6], self.checkout)
            run.reset_mock()

            builder.prepare_checkout(self.checkout, "shell-only", "first", 6)
            run.assert_not_called()

            builder.prepare_checkout(self.checkout, "next", "second", 6)
            args = run.call_args.args
            self.assertEqual(args[3], "update")
            self.assertEqual(args[6:8], ("--from-revision", "original"))
            self.assertEqual(builder.read_state(self.state)["applied"], {"revision": "next", "overlay": "second"})

    def test_interrupted_update_same_recipe_resumes_from_previous_revision(self):
        with patch.object(builder, "run") as run:
            builder.prepare_checkout(self.checkout, "base", "first", 6)
            run.side_effect = subprocess.CalledProcessError(1, "update")
            with self.assertRaises(subprocess.CalledProcessError):
                builder.prepare_checkout(self.checkout, "failed", "second", 6)
            with self.assertRaisesRegex(ValueError, "interrupted preparation for failed"):
                builder.prepare_checkout(self.checkout, "new", "third", 6)

            run.side_effect = None
            builder.prepare_checkout(self.checkout, "retry", "second", 6)
            self.assertEqual(run.call_args.args[6:8], ("--from-revision", "base"))
            self.assertEqual(builder.read_state(self.state), {"applied": {"revision": "retry", "overlay": "second"}})

    def test_two_builds_are_sequential_and_warm_sdk_hits_skip_compile(self):
        args = SimpleNamespace(
            macos_sdk=self.scratch / "MacOSX.sdk", cache_root=self.scratch / "cache",
            checkout=self.checkout, output=self.scratch / "job-one", jobs=6,
        )
        actions = []

        def fake_run(*command, **kwargs):
            if command[2:4] == (builder.BUILD, "build"):
                actions.append(("build", command[command.index("--arch") + 1]))
            elif command[:2] == ("/bin/bash", builder.PUBLISH):
                arch = command[command.index("--arch") + 1]
                actions.append(("publish", arch))
                engine = builder.artifact_directory(command[-1], arch)
                engine.mkdir(parents=True, exist_ok=True)
                (engine / "marker").write_text(arch)
            else:
                self.assertEqual(command[2:4], (builder.CHECK, "pair-sdk"))
                actions.append(("pair",))

        def verify(package, arch):
            marker = builder.artifact_directory(package, arch) / "marker"
            return marker.read_text() if marker.is_file() else None

        with (
            patch.object(builder, "native_architecture", return_value="x86_64"),
            patch.object(builder, "official_sdk", return_value=args.macos_sdk),
            patch.object(builder, "capture", side_effect=["", "head"] * 3),
            patch.object(builder, "preparation_inputs", return_value=({}, {})),
            patch.object(builder, "sdk_key", return_value="example"),
            patch.object(builder, "verified_sdk", side_effect=verify),
            patch.object(builder, "prepare_checkout") as prepare,
            patch.object(builder, "summary"),
            patch.object(builder, "run", side_effect=fake_run),
        ):
            builder.build_pair(args)
            self.assertEqual(actions, [
                ("build", "x64"), ("publish", "x86_64"),
                ("build", "arm64"), ("publish", "arm64"), ("pair",),
            ])
            for arch, _ in builder.ARCHITECTURES:
                self.assertTrue(builder.artifact_directory(args.output / "Package", arch).is_dir())
            prepare.assert_called_once()
            actions.clear()
            prepare.reset_mock()

            args.output = self.scratch / "job-two"
            builder.build_pair(args)
            self.assertEqual(actions, [("pair",)])
            prepare.assert_not_called()

            actions.clear()
            cache_package = args.cache_root / "sdks/example/Package"
            (builder.artifact_directory(cache_package, "arm64") / "marker").unlink()
            args.output = self.scratch / "job-three"
            builder.build_pair(args)
            self.assertEqual(actions, [("build", "arm64"), ("publish", "arm64"), ("pair",)])
            prepare.assert_called_once()


if __name__ == "__main__":
    unittest.main()
