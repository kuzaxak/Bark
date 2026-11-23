"""Check that the Sparkle rehearsal serves its feed without leaving the loopback address."""

from contextlib import ExitStack
from pathlib import Path
import runpy
import tempfile
import unittest
from unittest.mock import patch

REHEARSAL = runpy.run_path(str(Path(__file__).resolve().parents[1] / "runner/rehearse-nook-migration.py"))


class LoopbackFeedTests(unittest.TestCase):
    def test_feed_binds_loopback_without_name_lookups(self):
        canonical = REHEARSAL["ENCLOSURES"] + "Bark-2.0.0-202611200002-macos-arm64.dmg"
        feed = f'<enclosure url="{canonical}" length="5"/>'.encode()
        with tempfile.TemporaryDirectory() as folder, ExitStack() as stack:
            image = Path(folder) / "update.dmg"
            image.write_bytes(b"image")
            for name in ("getfqdn", "gethostbyaddr", "gethostbyname", "gethostbyname_ex", "gethostname", "getnameinfo"):
                stack.enter_context(patch(f"socket.{name}", side_effect=AssertionError(f"socket.{name} was called")))
            url = stack.enter_context(REHEARSAL["loopback_feed"](feed, image, canonical))
            self.assertRegex(url, r"^http://127\.0\.0\.1:[0-9]+/appcast\.xml$")


if __name__ == "__main__":
    unittest.main()
