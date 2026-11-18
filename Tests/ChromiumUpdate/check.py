#!/usr/bin/env python3
# Licensed under GPL-3.0. See LICENSE.
"""Check installed-update build input selection without building or launching."""

import contextlib
from io import StringIO
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import walk


class UpdateBuildInputTest(unittest.TestCase):
    def test_official_rehearsal_refuses_external_products(self):
        with self.assertRaises(SystemExit) as failure, contextlib.redirect_stderr(StringIO()) as error:
            walk.parse_args(["--require-official", "--derived-data", "/tmp/another-build",
                             "--output", "/tmp/evidence", "--identity", "Fixture"])
        self.assertEqual(failure.exception.code, 2)
        self.assertIn("Omit --derived-data", error.getvalue())

    def test_developer_rehearsal_passes_supplied_products_without_building(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            derived = root / "existing-derived-data"
            derived.mkdir()
            engine = root / "Engine"
            engine.mkdir()
            argv = ["walk.py", "--derived-data", str(derived), "--identity", "Fixture",
                    "--output", str(root / "evidence")]
            tools = {"native_architecture": lambda: "x86_64", "cached_engine": lambda arch: engine}
            with patch.object(walk.sys, "argv", argv), patch.object(walk.runpy, "run_path", return_value=tools), \
                    patch.object(walk, "build_checkout_shell") as build, patch.object(walk, "UpdateServer"), \
                    patch.object(walk, "versions", return_value=(None, None, None, None)) as versions, \
                    patch.object(walk, "exercise"), contextlib.redirect_stdout(StringIO()):
                walk.main()
            build.assert_not_called()
            self.assertEqual(versions.call_args.args[1:5], (derived.resolve(), engine, "Fixture", "x86_64"))

    def test_checkout_shell_uses_locked_release_configuration(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            derived = root / "DerivedData"
            with patch.object(walk, "run") as run:
                walk.build_checkout_shell(derived, "arm64", root)
            self.assertEqual(run.call_args.args[:7],
                             ("xcodebuild", "-project", walk.REPO / "Bark.xcodeproj",
                              "-scheme", "Bark", "-configuration", "Release"))
            self.assertEqual(run.call_args.args[run.call_args.args.index("-derivedDataPath") + 1], derived)
            self.assertIn("-onlyUsePackageVersionsFromResolvedFile", run.call_args.args)
            self.assertIn("ARCHS=arm64", run.call_args.args)


if __name__ == "__main__":
    unittest.main()
