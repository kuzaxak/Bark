# Licensed under GPL-3.0. See LICENSE.

import json
import os
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "scripts/runner/promote-bark-2.sh"
HEADERS = Path("Packages/BarkEngine/BarkEngine.xcframework/macos-arm64_x86_64/Headers/BarcChromium")
CHROMIUM = "158.0.8127.37"
TRANSITION = ("appcast.xml", "Nook-1.5.5-universal.dmg")
NOTES = "Bark 2.0.1 fixes zoom in Peek.\n\n### Fixed\n\n- Zoom shortcuts zoom the page shown in Peek"
CHANGELOG = f"# Changelog\n\n## 2.0.1\n\n{NOTES}\n\n## 2.0.0\n\nBark 2.0.0 moves web pages to Chromium 158.\n"

FAKE_GH = """
import json, os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
with open(Path(os.environ["FAKE_LOG"]) / "gh", "a") as log:
    log.write(json.dumps(args) + "\\n")
if args[:2] == ["release", "download"]:
    target = Path(args[args.index("--dir") + 1])
    for name in (args[i + 1] for i, value in enumerate(args) if value == "--pattern"):
        if (target / name).exists():
            sys.exit(f"{name} already exists")
        shutil.copyfile(Path(os.environ["FAKE_RELEASES"]) / args[2] / name, target / name)
else:
    print("success")
"""
FAKE_CURL = """
import os, shutil, sys
from pathlib import Path
args = sys.argv[1:]
url = next(arg for arg in args if arg.startswith("https://"))
shutil.copyfile(Path(os.environ["FAKE_LATEST"]) / url.rsplit("/", 1)[1], args[args.index("-o") + 1])
"""
FAKE_PYTHON = """
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
options = dict(zip(args[2::2], args[3::2]))
with open(Path(os.environ["FAKE_LOG"]) / "publish", "a") as log:
    log.write(json.dumps({"args": args, "notes": Path(options["--notes"]).read_text(),
                          "directory": sorted(os.listdir(options["--directory"])),
                          "transition": Path(options["--transition-image"]).read_text()}) + "\\n")
if "--publish" in args and os.environ.get("FAKE_PUBLISH_FAILS"):
    sys.exit("publication failed")
"""


class PromotionTests(unittest.TestCase):
    def setUp(self):
        work = TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        (self.root / "gitconfig").touch()
        self.env = {**os.environ, "GIT_CONFIG_GLOBAL": str(self.root / "gitconfig"), "GIT_CONFIG_NOSYSTEM": "1"}
        for variable in ("GIT_DIR", "GIT_WORK_TREE", "GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL",
                         "GIT_COMMITTER_NAME", "GIT_COMMITTER_EMAIL"):
            self.env.pop(variable, None)
        tools = self.root / "bin"
        tools.mkdir()
        for name, source in (("gh", FAKE_GH), ("curl", FAKE_CURL), ("publish-python", FAKE_PYTHON)):
            (tools / name).write_text(f"#!{sys.executable}\n{source}")
            (tools / name).chmod(0o755)
        self.log = self.root / "log"
        self.log.mkdir()
        self.assets = self.root / "assets"
        self.assets.mkdir()
        for arch in ("x86_64", "arm64"):
            (self.assets / f"bark-macos-{arch}.xml").write_text(f"{arch} feed")
            (self.assets / f"Bark-2.0.1-202611240001-macos-{arch}.dmg").write_text(f"{arch} image")
        published = self.root / "releases/bark-v2.0.0"
        published.mkdir(parents=True)
        for name in TRANSITION:
            (published / name).write_text(f"published {name}")
        (self.root / "runner").mkdir()
        self.env.update({
            "PATH": f"{tools}{os.pathsep}{os.environ['PATH']}",
            "FAKE_LOG": str(self.log), "FAKE_RELEASES": str(self.root / "releases"), "FAKE_LATEST": str(self.assets),
            "BARK_WALK_PYTHON": str(tools / "publish-python"), "RUNNER_TEMP": str(self.root / "runner"),
            "DEFAULT_BRANCH": "main", "GITHUB_REPOSITORY": "kuzaxak/Bark",
            "BARK_RELEASE_VERSION": "2.0.1", "BARK_BUILD_NUMBER": "202611240001",
        })

        self.origin = self.root / "origin.git"
        self.git(self.root, "init", "--quiet", "--bare", "-b", "main", str(self.origin))
        seed = self.root / "seed"
        self.git(self.root, "init", "--quiet", "-b", "main", str(seed))
        self.write(seed, {"Runtime/Chromium/CHROMIUM_VERSION": CHROMIUM + "\n", "CHANGELOG.md": CHANGELOG})
        self.commit(seed, "Prepare Bark 2.0.0")
        self.write(seed / HEADERS, self.pins("2.0.0"))
        self.commit(seed, "Pin the Chromium 158 SDKs for Bark 2.0.0")
        self.git(seed, "tag", "-a", "bark-v2.0.0", "-m", "Bark 2.0.0")
        self.write(seed, {"Peek.swift": "zoom the shown Peek\n"})
        self.commit(seed, "Send zoom to a shown Peek")
        self.git(seed, "tag", "bark-v2.0.1-rc.1")
        self.git(seed, "push", "--quiet", str(self.origin), "main", "--tags")
        self.source = self.git(seed, "rev-parse", "HEAD")
        self.env["SOURCE_COMMIT"] = self.source

    def git(self, cwd, *args):
        identity = ("-c", "user.name=Test", "-c", "user.email=test@example.com")
        return subprocess.run(["git", *identity, *args], cwd=cwd, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    @staticmethod
    def write(directory, files):
        for name, content in files.items():
            (directory / name).parent.mkdir(parents=True, exist_ok=True)
            (directory / name).write_text(content)

    def commit(self, repository, subject):
        self.git(repository, "add", "-A")
        self.git(repository, "commit", "--quiet", "-m", subject)

    @staticmethod
    def pins(build):
        return {
            **{f"barc_engine_version_{arch}.h": f'#define BARC_ENGINE_VERSION "{CHROMIUM}"\n'
               for arch in ("x86_64", "arm64")},
            **{f"engine-artifact-{arch}.official.json": f'{{"build": "{build}"}}\n' for arch in ("x86_64", "arm64")},
            **{f"engine-artifact-{arch}.sha256": f"{arch} {build}\n" for arch in ("x86_64", "arm64")},
        }

    def promote(self, built="2.0.0", **env):
        checkout = self.root / f"checkout-{len(list(self.root.glob('checkout-*')))}"
        self.git(self.root, "clone", "--quiet", str(self.origin), str(checkout))
        self.git(checkout, "checkout", "--quiet", "--detach", self.source)
        generated = self.root / f"generated-{built}"
        if not generated.exists():
            generated.mkdir()
            self.write(generated, self.pins(built))
        for name in TRANSITION:
            (self.assets / name).unlink(missing_ok=True)
        (self.log / "publish").unlink(missing_ok=True)
        return subprocess.run(["bash", SCRIPT, generated, self.assets], cwd=checkout,
                              env={**self.env, **env}, capture_output=True, text=True)

    def published(self, ref):
        return self.git(self.origin, "rev-parse", ref)

    def publications(self):
        return [json.loads(line) for line in (self.log / "publish").read_text().splitlines()]

    def assert_published(self, commit):
        verify, publish = self.publications()
        self.assertEqual(publish["args"], verify["args"] + ["--publish"])
        options = dict(zip(verify["args"][2::2], verify["args"][3::2]))
        self.assertEqual({key: options[key] for key in
                          ("--version", "--build", "--commit", "--previous-latest", "--directory")},
                         {"--version": "2.0.1", "--build": "202611240001", "--commit": commit,
                          "--previous-latest": "bark-v2.0.0", "--directory": str(self.assets)})
        self.assertEqual(verify["notes"].strip(), NOTES)
        self.assertTrue(set(TRANSITION[:1]) <= set(verify["directory"]))
        self.assertEqual(verify["transition"], f"published {TRANSITION[1]}")
        self.assertEqual(self.git(self.origin, "cat-file", "-t", "refs/tags/bark-v2.0.1"), "tag")
        self.assertEqual(self.published("bark-v2.0.1^{commit}"), commit)
        self.assertEqual(self.published("main"), commit)

    def test_unchanged_pins_publish_the_tagged_source(self):
        result = self.promote()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_published(self.source)

    def test_changed_pins_are_committed_before_the_release_tag(self):
        result = self.promote("2.0.1")
        self.assertEqual(result.returncode, 0, result.stderr)
        pinned = self.published("main")
        self.assertEqual(self.published("main^"), self.source)
        self.assertEqual(self.git(self.origin, "log", "-1", "--format=%s", "main"),
                         "Pin the Chromium 158 SDKs for Bark 2.0.1")
        self.assertEqual(self.git(self.origin, "show", f"main:{HEADERS}/engine-artifact-arm64.sha256"),
                         "arm64 2.0.1")
        self.assert_published(pinned)

    def test_retry_after_a_failed_publication_reuses_the_pushed_tag(self):
        result = self.promote(FAKE_PUBLISH_FAILS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.published("bark-v2.0.1^{commit}"), self.source)
        result = self.promote()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_published(self.source)


if __name__ == "__main__":
    unittest.main()
