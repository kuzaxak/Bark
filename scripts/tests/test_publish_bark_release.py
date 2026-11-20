# Licensed under GPL-3.0. See LICENSE.

from pathlib import Path
from tempfile import TemporaryDirectory
import unittest
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import publish_bark_release as release


COMMIT = "1" * 40
NOTES = "Reviewed release notes."


class FakeGitHub:
    def __init__(self):
        self.releases = {}
        self.latest_tag = release.LEGACY_TAG
        self.contents = {}
        self.uploads = []
        self.promotions = 0
        self.break_upload = False
        self.race_latest = False

    def find(self, tag):
        return self.releases.get(tag)

    def latest(self):
        return self.find(self.latest_tag) or {"tag_name": self.latest_tag}

    def require_release_commit(self, commit, *, tagged):
        if commit != COMMIT:
            raise ValueError("wrong remote tip")

    def tag_commit(self, tag):
        entry = self.find(tag)
        return entry["target_commitish"] if entry and not entry["draft"] else None

    def create_draft(self, tag, commit, version, notes):
        entry = {"tag_name": tag, "target_commitish": commit, "draft": True, "prerelease": False,
                 "body": notes, "assets": {}}
        self.releases[tag] = entry
        return entry

    def assets(self, entry):
        return entry["assets"]

    def upload(self, tag, assets):
        self.uploads.append([asset.path.name for asset in assets])
        for asset in assets:
            name = asset.path.name
            found = self.releases[tag]["assets"]
            if name in found:
                raise AssertionError("upload tried to replace an existing asset")
            found[name] = {
                "state": "uploaded", "size": asset.size, "digest": asset.digest,
                "browser_download_url": release.download_url(tag, name),
            }
            self.contents[tag, name] = asset.path.read_bytes()
            if self.break_upload:
                raise ValueError("interrupted upload")
        if self.race_latest:
            self.latest_tag = "unexpected"

    def download(self, tag, name):
        return self.contents[tag, name]

    def promote_latest(self, entry):
        self.promotions += 1
        entry["draft"] = False
        self.latest_tag = entry["tag_name"]
        return entry


class PublicationTests(unittest.TestCase):
    def setUp(self):
        work = TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self.github = FakeGitHub()
        self.tag = release.TRANSITION_TAG
        self.build = "202611200002"
        self.assets = {
            name: self.asset(name, content) for name, content in (
                ("appcast.xml", "legacy feed"),
                (release.TRANSITION_NAME, "transition"),
                *[(release.feed_name(arch),
                   f'<rss xmlns:sparkle="{release.SPARKLE}"><channel><item>'
                   f'<sparkle:version>{self.build}</sparkle:version><enclosure/>'
                   '</item></channel></rss>') for arch in release.ARCHITECTURES],
            )
        }
        self.transition = self.assets[release.TRANSITION_NAME]

    def asset(self, name, content):
        path = self.root / name
        path.write_text(content)
        return release.Asset.read(path)

    def publish(self, tag=None, version="2.0.0", build=None, previous=release.LEGACY_TAG, assets=None):
        release.publish(self.github, tag or self.tag, COMMIT, version, build or self.build,
                        previous, NOTES, self.assets if assets is None else assets, self.transition)

    def test_interrupted_upload_leaves_latest_untouched_and_retries_missing_assets(self):
        self.github.break_upload = True
        with self.assertRaisesRegex(ValueError, "interrupted"):
            self.publish()
        self.assertEqual(self.github.latest_tag, release.LEGACY_TAG)
        partial = set(self.github.find(self.tag)["assets"])
        self.assertEqual(len(partial), 1)

        self.github.break_upload = False
        self.publish()
        self.assertEqual(set(self.github.uploads[-1]), self.assets.keys() - partial)
        self.assertEqual(self.github.latest_tag, self.tag)
        self.assertEqual(self.github.promotions, 1)
        self.publish()
        self.assertEqual(self.github.promotions, 1)

    def test_refuses_wrong_digest_or_unexpected_asset_without_promoting(self):
        entry = self.github.create_draft(self.tag, COMMIT, "2.0.0", NOTES)
        self.github.upload(self.tag, [self.transition])
        uploaded = entry["assets"][release.TRANSITION_NAME]
        uploaded["digest"] = "sha256:" + "0" * 64
        with self.assertRaisesRegex(ValueError, "differs"):
            self.publish()
        entry["assets"]["extra"] = uploaded
        with self.assertRaisesRegex(ValueError, "asset set"):
            self.publish()
        self.assertTrue(entry["draft"])
        self.assertEqual(self.github.promotions, 0)

    def test_latest_moving_during_upload_leaves_a_draft(self):
        self.github.race_latest = True
        with self.assertRaisesRegex(ValueError, "Expected .* to be Latest"):
            self.publish()
        self.assertTrue(self.github.find(self.tag)["draft"])
        self.assertEqual(self.github.promotions, 0)

    def test_tagged_commit_can_be_behind_default_but_must_remain_reachable(self):
        github = release.GitHub()
        tip = "2" * 40
        base = {"default_branch": "pawl-dev"}
        remote_ref = {"object": {"sha": tip}}
        with patch.object(github, "api", side_effect=[base, remote_ref, {"status": "ahead"}]) as api:
            github.require_release_commit(COMMIT, tagged=True)
            self.assertEqual(api.call_args.args[0], f"/compare/{COMMIT}...{tip}?per_page=1")
        with patch.object(github, "api", side_effect=[base, remote_ref, {"status": "diverged"}]):
            with self.assertRaisesRegex(ValueError, "not reachable"):
                github.require_release_commit(COMMIT, tagged=True)
        with patch.object(github, "api", side_effect=[base, remote_ref]):
            with self.assertRaisesRegex(ValueError, "does not point"):
                github.require_release_commit(COMMIT, tagged=False)

    def test_follow_up_reuses_immutable_transition_and_checks_build_numbers(self):
        self.publish()
        updated = {name: asset for name, asset in self.assets.items() if name != release.TRANSITION_NAME}
        with self.assertRaisesRegex(ValueError, "advance the"):
            self.publish("bark-v2.1.0", "2.1.0", self.build, self.tag, updated)
        altered = {**updated, "appcast.xml": self.asset("appcast.xml", "different legacy feed")}
        with self.assertRaisesRegex(ValueError, "differs"):
            self.publish("bark-v2.1.0", "2.1.0", "202611200003", self.tag, altered)
        # Restore the byte-for-byte original local feed for the successful upload.
        updated["appcast.xml"] = self.asset("appcast.xml", "legacy feed")
        self.publish("bark-v2.1.0", "2.1.0", "202611200003", self.tag, updated)
        self.assertEqual(set(self.github.uploads[-1]), set(updated))
        self.assertEqual(self.github.contents[self.tag, release.TRANSITION_NAME], b"transition")
        self.assertEqual(self.github.contents["bark-v2.1.0", "appcast.xml"], b"legacy feed")

    def test_appcast_uses_immutable_enclosure_and_verifies_signature(self):
        image = self.asset("image.dmg", "fixture")
        feed_name = release.feed_name("arm64")
        url = release.download_url(self.tag, image.path.name)
        xml = (f'<rss xmlns:sparkle="{release.SPARKLE}"><channel>'
               f'<link>{release.FEED_BASE}/{feed_name}</link><item>'
               f'<sparkle:version>{self.build}</sparkle:version>'
               '<sparkle:shortVersionString>2.0.0</sparkle:shortVersionString>'
               f'<enclosure url="{url}" length="{image.size}" sparkle:edSignature="signed"/>'
               '</item></channel></rss>')
        feed = self.asset(feed_name, xml)
        with patch.object(release.subprocess, "run") as verify:
            release.check_appcast(feed, image, self.tag, "2.0.0", self.build, ordinary=True)
            self.assertEqual(verify.call_args.args[0][-3:], [image.path, release.SPARKLE_PUBLIC_KEY, "signed"])
            changed = self.asset(feed_name, xml.replace(url, f"{release.FEED_BASE}/{image.path.name}"))
            with self.assertRaisesRegex(ValueError, "wrong disk image"):
                release.check_appcast(changed, image, self.tag, "2.0.0", self.build, ordinary=True)
            verify.assert_called_once()


if __name__ == "__main__":
    unittest.main()
