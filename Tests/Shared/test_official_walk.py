"""Offline checks for signed walk official qualification."""
from contextlib import contextmanager
import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import Mock

from signed_walk import verify_official_sdk, verify_pinned_sdk


class OfficialWalkTests(unittest.TestCase):
    def setUp(self):
        scratch = tempfile.TemporaryDirectory()
        self.addCleanup(scratch.cleanup)
        self.engine = Path(scratch.name)
        self.app = Path("/fixture/Bark.app")
        self.package = Path("/fixture/BarkEngine")
        manifest = b"pinned SDK fixture\n"
        (self.engine / "SHA256SUMS").write_bytes(manifest)
        self.pin = hashlib.sha256(manifest).hexdigest()
        self.calls = Mock()
        self.calls.read_pin.return_value = self.pin
        self.refuse_sdk = False

        @contextmanager
        def pinned_engine(source, working, arch, *, require_official):
            self.calls.pinned_engine(source, arch, require_official)
            if self.refuse_sdk:
                raise ValueError("developer SDK")
            yield self.engine

        self.contributor = {
            "cached_engine": Mock(return_value=self.engine),
            "pinned_engine": pinned_engine,
            "verify_candidate": self.calls.verify_candidate,
            "read_pin": self.calls.read_pin,
            "PACKAGE": self.package,
        }

    def test_startup_verifies_signed_payload_before_recording_pin(self):
        engine, evidence = verify_official_sdk(self.contributor, "arm64", self.app)
        self.assertEqual(engine, self.engine)
        self.assertEqual(evidence, {"architecture": "arm64", "sdk_pin": self.pin, "official": True})
        self.assertEqual([call[0] for call in self.calls.mock_calls], ["pinned_engine", "verify_candidate", "read_pin"])
        self.calls.pinned_engine.assert_called_once_with(str(self.engine), "arm64", True)
        self.assertEqual(self.calls.verify_candidate.call_args.args[:2], (self.app, self.engine))
        self.assertEqual(self.calls.verify_candidate.call_args.args[-1], "arm64")

    def test_pinned_developer_walk_does_not_claim_official_provenance(self):
        _, evidence = verify_pinned_sdk(self.contributor, "x86_64", self.app)
        self.assertEqual(evidence, {"architecture": "x86_64", "sdk_pin": self.pin, "official": None})
        self.calls.pinned_engine.assert_called_once_with(str(self.engine), "x86_64", False)
        self.calls.verify_candidate.assert_called_once()

    def test_developer_sdk_is_refused_before_signed_app_verification(self):
        self.refuse_sdk = True
        with self.assertRaisesRegex(ValueError, "developer SDK"):
            verify_official_sdk(self.contributor, "x86_64", self.app)
        self.calls.verify_candidate.assert_not_called()
        self.calls.read_pin.assert_not_called()

    def test_another_checkout_pin_cannot_label_the_verified_sdk(self):
        self.calls.read_pin.return_value = "b" * 64
        with self.assertRaisesRegex(ValueError, "pin changed"):
            verify_official_sdk(self.contributor, "arm64", self.app)
        self.calls.verify_candidate.assert_called_once()

    def test_mismatched_signed_app_prevents_evidence(self):
        self.calls.verify_candidate.side_effect = ValueError("signed payload mismatch")
        with self.assertRaisesRegex(ValueError, "signed payload mismatch"):
            verify_official_sdk(self.contributor, "arm64", self.app)
        self.calls.read_pin.assert_not_called()


if __name__ == "__main__":
    unittest.main()
