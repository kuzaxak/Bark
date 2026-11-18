"""Exercise the first official SDK publication boundary without rebuilding Chromium."""

from pathlib import Path
import hashlib
import json
import runpy
import shlex
import subprocess
import struct
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class FirstOfficialPublicationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = runpy.run_path(str(ROOT / "Tests/ChromiumAppShim/check.py"))
        temporary = tempfile.TemporaryDirectory(prefix="bark-first-official-")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name).resolve()
        self.package = self.work / "package"
        self.addCleanup(self.make_writable)
        self.siso = self.work / "fake-tools"
        self.siso.mkdir()
        self.tool("siso", 'exec /bin/cat "$FAKE_SISO_STATE"')
        self.build = self.make_build("arm64")

    def make_writable(self):
        if self.package.is_dir():
            self.fixture["make_writable"](self.package)

    def tool(self, name, commands):
        path = self.siso / name
        path.write_text('#!/bin/bash\n' + commands + '\n')
        path.chmod(0o755)

    def make_build(self, arch):
        framework = self.work / f"{arch}.dylib"
        self.fixture["fake_framework"](framework, arch=("-arch", arch))
        return self.fixture["fake_engine_build"](self.work / arch, framework)

    def publish(self, *options, build=None, arch="arm64"):
        build = self.build if build is None else build
        return subprocess.run([
            "/bin/bash", self.fixture["PUBLISH"], "--arch", arch,
            *options, build, self.package,
        ], env=self.fixture["publisher_environment"](build, self.siso),
            capture_output=True, text=True)

    def in_transaction(self, script, build=None, arch="arm64", official=False):
        build = self.build if build is None else build
        wrapped = f"""
from pathlib import Path
import sys
sys.path.insert(0, sys.argv[1])
import publish_chromium_sdk as publication
{script}
publication.publish(Path(sys.argv[2]), sys.argv[3], True, sys.argv[4], sys.argv[5],
                    require_official=sys.argv[6] == 'true')
"""
        return subprocess.run([
            sys.executable, "-B", "-c", wrapped, ROOT / "scripts",
            self.package, arch, build, self.fixture["PUBLISH"], str(official).lower(),
        ], env=self.fixture["publisher_environment"](build, self.siso),
            capture_output=True, text=True)

    def pin(self, arch):
        return self.package / "BarkEngine.xcframework" / self.fixture["SLICE_NAME"] / (
            f"Headers/BarcChromium/engine-artifact-{arch}.sha256"
        )

    def make_official(self):
        chromium = ROOT / "Runtime/Chromium"
        pins = json.loads((chromium / "PINS.json").read_text())
        source = self.build.parent.parent
        profile_name = pins["official_pgo_profiles"]["mac-arm"]
        selector = source / "chrome/build/mac-arm.pgo.txt"
        selector.parent.mkdir(parents=True)
        selector.write_text(profile_name + "\n")
        profile = selector.parent / "pgo_profiles" / profile_name
        profile.parent.mkdir()
        profile.write_bytes(b"synthetic PGO fixture")
        self.tool("gn", "printf '%s\\n' " + shlex.quote(f"-fprofile-use={profile}"))
        state_file = self.build / "fake-siso-state.json"
        state = json.loads(state_file.read_text())
        state["entries"].append({
            "name": str(profile),
            "digest": {"hash": hashlib.sha256(profile.read_bytes()).hexdigest()},
            "id": {"mod_time": 0},
        })
        state_file.write_text(json.dumps(state))
        framework = self.build / "Bark.app/Contents/Frameworks/Bark Framework.framework"
        versioned = framework / "Versions/Current"
        sdk = pins["official_macos_sdk"]
        self.fixture["write_plist"](
            versioned / "Resources/Info.plist", DTSDKName="macosx" + sdk["version"],
            DTSDKBuild=sdk["build"], SCMRevision=pins["chromium"],
            CFBundleShortVersionString=(chromium / "CHROMIUM_VERSION").read_text().strip(),
        )
        # Rewrite only LC_BUILD_VERSION's SDK field in a genuine thin ARM
        # fixture. This exercises the production otool/lipo/receipt checks on
        # Intel without requiring Chromium's pinned compile or executing ARM.
        image = versioned / "Bark Framework"
        binary = bytearray(image.read_bytes())
        self.assertEqual(binary[:4], b"\xcf\xfa\xed\xfe")
        commands, = struct.unpack_from("<I", binary, 16)
        position = 32
        for _ in range(commands):
            command, size = struct.unpack_from("<II", binary, position)
            if command == 0x32:
                major, minor, *patch = map(int, sdk["version"].split("."))
                struct.pack_into("<I", binary, position + 16, major << 16 | minor << 8 | (patch[0] if patch else 0))
                break
            position += size
        else:
            self.fail("Fixture has no LC_BUILD_VERSION")
        image.write_bytes(binary)
        env = self.fixture["publisher_environment"](self.build, self.siso)
        subprocess.run([
            sys.executable, "-B", "-c", """
from pathlib import Path
import json, os, sys
sys.path.insert(0, sys.argv[1])
from build_engine import engine_args
from official_provenance import RECEIPT, record
out = Path(sys.argv[2])
(out / 'args.gn').write_bytes(engine_args('arm64', True))
(out / RECEIPT).write_text(json.dumps(record(out, out.parent.parent, 'arm64', os.environ)))
""", chromium, self.build,
        ], env=env, check=True)

    def test_missing_receipt_cannot_create_or_replace_the_first_arm_pin(self):
        pin = self.pin("arm64")
        absent = self.publish("--require-official")
        self.assertNotEqual(absent.returncode, 0)
        self.assertIn("No official Bark SDK build receipt", absent.stderr)
        self.assertFalse(self.package.exists())

        developer = self.publish()
        self.assertEqual(developer.returncode, 0, developer.stderr)
        original = pin.read_bytes()
        missing = self.publish("--require-official", "--replace")
        self.assertNotEqual(missing.returncode, 0)
        self.assertEqual(pin.read_bytes(), original)

        (self.build / "official-build.json").write_text("{}")
        selector = self.build.parent.parent / "chrome/build/mac-arm.pgo.txt"
        selector.parent.mkdir(parents=True)
        selector.write_text("an-unpinned-fixture-profile.profdata\n")
        invalid = self.publish("--require-official", "--replace")
        self.assertNotEqual(invalid.returncode, 0)
        self.assertIn("The Chromium PGO selector does not match the Bark pin", invalid.stderr)
        self.assertEqual(pin.read_bytes(), original)

    def test_invalid_official_input_leaves_unrelated_pending_publication_intact(self):
        intel = self.make_build("x86_64")
        stopped = self.in_transaction("""
import os
def stop_before_promotion(*args, **kwargs):
    os._exit(75)
publication.finish = stop_before_promotion
""", build=intel, arch="x86_64")
        self.assertEqual(stopped.returncode, 75, stopped.stderr)
        journal = self.package / "RuntimeArtifacts/.publication/pending/transaction.json"
        pending = journal.read_bytes()
        self.assertFalse(self.pin("x86_64").exists())

        self.make_official()
        (self.build / "official-build.json").write_text("{}")
        for invoke in (lambda: self.in_transaction("", official=True), lambda: self.publish("--require-official")):
            refused = invoke()
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("official SDK receipt differs", refused.stderr)
            self.assertTrue(journal.is_file())
            self.assertEqual(journal.read_bytes(), pending)
            self.assertFalse(self.pin("x86_64").exists())
            self.assertFalse(self.pin("arm64").exists())

        recovered = self.publish(build=intel, arch="x86_64")
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertIn("Recovered SDK publication", recovered.stdout)
        self.assertTrue(self.pin("x86_64").is_file())
        self.assertFalse(journal.exists())

    def test_sealed_copy_must_keep_the_verified_receipt_and_can_recover(self):
        self.make_official()
        corrupted = self.in_transaction("""
run = publication.subprocess.run
def copy_without_receipt(args, **kwargs):
    result = run(args, **kwargs)
    if '--prepare' in args:
        engine = Path(args[args.index('--prepare') + 2])
        engine.chmod(0o755)
        (engine / 'official-build.json').unlink()
        manifest = engine / 'SHA256SUMS'
        manifest.chmod(0o644)
        manifest.write_text(''.join(line for line in manifest.read_text().splitlines(keepends=True)
                                    if not line.endswith('  ./official-build.json\\n')))
        manifest.chmod(0o444)
        engine.chmod(0o555)
    return result
publication.subprocess.run = copy_without_receipt
""", official=True)
        self.assertNotEqual(corrupted.returncode, 0)
        self.assertIn("No official Bark SDK build receipt", corrupted.stderr)
        self.assertFalse(self.pin("arm64").exists())
        journal = self.package / "RuntimeArtifacts/.publication/pending/transaction.json"
        self.assertFalse(journal.exists())

        stopped = self.in_transaction("""
import os
write = publication.write_atomic
def stop_before_pin(work, target, content):
    if target.name == 'engine-artifact-arm64.sha256':
        os._exit(75)
    write(work, target, content)
publication.write_atomic = stop_before_pin
""", official=True)
        self.assertEqual(stopped.returncode, 75, stopped.stderr)
        self.assertTrue(json.loads(journal.read_text())["official"])
        self.assertFalse(self.pin("arm64").exists())

        recovered = self.publish("--require-official")
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertIn("Recovered SDK publication", recovered.stdout)
        self.assertTrue(self.pin("arm64").is_file())
        self.assertFalse(journal.exists())
