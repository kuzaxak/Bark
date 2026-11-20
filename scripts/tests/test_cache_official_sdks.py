# Licensed under GPL-3.0. See LICENSE.

from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "runner"))
import cache_official_sdks as cache


class OfficialSDKCacheTests(unittest.TestCase):
    def setUp(self):
        work = TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self.package = self.root / "products" / "Package"
        self.cache_root = self.root / "cache"
        self.receiver = self.root / "BarkEngine"
        self.metadata = {name: name.encode() for name in cache.METADATA}
        for engine in cache.engines(self.package).values():
            engine.mkdir(parents=True)
            (engine / "fixture").write_bytes(b"native")
        self.write_metadata(self.receiver)

    def write_metadata(self, package):
        header_path = cache.headers_directory(package)
        header_path.mkdir(parents=True, exist_ok=True)
        for name, contents in self.metadata.items():
            (header_path / name).write_bytes(contents)

    def test_verify_checks_both_engines_and_rejects_mismatched_metadata(self):
        with patch.object(cache, "verified_digest") as digest, \
                patch.object(cache, "engine_version_header") as header, \
                patch.object(cache, "verify_official_sdk") as official, \
                patch.object(cache, "stage_pair", side_effect=lambda _, receiver: self.write_metadata(receiver)):
            self.assertEqual(cache.verify_pair(self.package, self.receiver), 12)
            self.assertEqual(digest.call_count, 2)
            self.assertEqual(header.call_count, 2)
            self.assertEqual({call.args[1] for call in official.call_args_list}, set(cache.ARCHITECTURES))
            (cache.headers_directory(self.receiver) / cache.METADATA[0]).write_text("wrong")
            with self.assertRaisesRegex(ValueError, "metadata differs"):
                cache.verify_pair(self.package, self.receiver)

    def test_restore_does_not_install_metadata_if_cache_fails_verification(self):
        self.cache_root.mkdir()
        with patch.object(cache, "verify_pair", side_effect=ValueError("invalid receipt")), \
                patch.object(cache, "stage_pair") as stage, patch.object(cache, "outputs") as output:
            with self.assertRaisesRegex(ValueError, "invalid receipt"):
                cache.install_from_cache(self.cache_root)
            stage.assert_not_called()
            output.assert_not_called()

    def test_symlink_escaping_engine_is_rejected(self):
        engine = next(iter(cache.engines(self.package).values()))
        outside = engine.parent / "unpublished"
        outside.write_text("outside engine")
        (engine / "escaped").symlink_to("../unpublished")
        with self.assertRaisesRegex(ValueError, "Unsafe SDK symlink"):
            cache.verify_tree(engine)

    def test_cache_contains_only_sdk_products_and_paired_metadata(self):
        (self.package / "compiler-output").write_bytes(b"not a release asset")
        with patch.object(cache, "RECEIVER", self.receiver), \
                patch.object(cache, "verify_pair", return_value=12), patch.object(cache, "outputs") as output:
            cache.accept_build(self.package, self.cache_root)
        cached = self.cache_root / "Package"
        self.assertEqual({entry.name for entry in cached.iterdir()},
                         {"RuntimeArtifacts", "BarkEngine.xcframework"})
        self.assertEqual(cache.read_metadata(cached), self.metadata)
        for engine in cache.engines(cached).values():
            self.assertEqual((engine / "fixture").read_bytes(), b"native")
        self.assertTrue((self.package / "compiler-output").is_file())
        output.assert_called_once_with(cached, cacheable=True)

    def test_oversized_or_rejected_cache_uses_runner_products(self):
        with patch.object(cache, "verify_pair", return_value=cache.CACHE_LIMIT + 1), \
                patch.object(cache, "outputs") as output:
            cache.accept_build(self.package, self.cache_root)
            output.assert_called_once_with(self.package)
            self.assertFalse(self.cache_root.exists())

        self.cache_root.mkdir()
        marker = self.cache_root / "invalid-download"
        marker.touch()
        with patch.object(cache, "verify_pair", return_value=12), patch.object(cache, "outputs") as output:
            cache.accept_build(self.package, self.cache_root)
            output.assert_called_once_with(self.package)
        self.assertTrue(marker.is_file())


if __name__ == "__main__":
    unittest.main()
