"""Exercise the first official SDK publication boundary without rebuilding Chromium."""

from pathlib import Path
import hashlib
import json
import runpy
import shlex
import shutil
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
PGO_FIXTURE = b"synthetic PGO fixture"
V8_FIXTURE = b"synthetic V8 builtins PGO"


class FirstOfficialPublicationTests(unittest.TestCase):
    def setUp(self):
        self.fixture = runpy.run_path(str(ROOT / "Tests/ChromiumAppShim/check.py"))
        temporary = tempfile.TemporaryDirectory(prefix="bark-first-official-")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name).resolve()
        # The publisher subprocesses use the real verifier and an isolated
        # recipe whose ARM hash pins these fixture bytes.
        self.repo = self.work / "repo"
        self.chromium = self.repo / "Runtime/Chromium"
        shutil.copytree(ROOT / "Runtime/Chromium", self.chromium)
        shutil.copytree(ROOT / "scripts", self.repo / "scripts")
        rust = Path("Nook/ThirdParty/AdblockRustFFI")
        shutil.copytree(ROOT / rust, self.repo / rust,
                        ignore=shutil.ignore_patterns("NookAdblock.xcframework", "tests"))
        # The resource parity tests add files to this copy during publication.
        shutil.copytree(ROOT / "ChromiumApp", self.repo / "ChromiumApp")
        pins_path = self.chromium / "PINS.json"
        pins = json.loads(pins_path.read_text())
        for target in ("mac", "mac-arm"):
            pins["official_pgo_sha256"][target] = hashlib.sha256(PGO_FIXTURE).hexdigest()
        pins_path.write_text(json.dumps(pins))
        self.publisher = self.repo / "scripts/publish-chromium-engine.sh"
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

    def make_build(self, arch, version=None):
        name = f"{arch}-{version}" if version else arch
        framework = self.work / f"{name}.dylib"
        self.fixture["fake_framework"](framework, arch=("-arch", arch))
        info = dict(self.fixture["ENGINE_PLIST"])
        if version is not None:
            info["CFBundleShortVersionString"] = version
        return self.fixture["fake_engine_build"](self.work / name, framework, engine_info=info)

    def publish(self, *options, build=None, arch="arm64"):
        build = self.build if build is None else build
        return subprocess.run([
            "/bin/bash", self.publisher, "--arch", arch,
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
            sys.executable, "-B", "-c", wrapped, self.repo / "scripts",
            self.package, arch, build, self.publisher, str(official).lower(),
        ], env=self.fixture["publisher_environment"](build, self.siso),
            capture_output=True, text=True)

    def pin(self, arch):
        return self.package / "BarkEngine.xcframework" / self.fixture["SLICE_NAME"] / (
            f"Headers/BarcChromium/engine-artifact-{arch}.sha256"
        )

    def official_seal(self, arch):
        return self.pin(arch).with_name(f"engine-artifact-{arch}.official.json")

    def expected_seal(self, package, arch):
        artifact = package / "RuntimeArtifacts" / arch / "Engine"
        return {
            "sdk_sha256": hashlib.sha256((artifact / "SHA256SUMS").read_bytes()).hexdigest(),
            "receipt_sha256": hashlib.sha256((artifact / "official-build.json").read_bytes()).hexdigest(),
        }

    def version(self, arch):
        return self.pin(arch).with_name(f"barc_engine_version_{arch}.h")

    def test_single_architecture_version_upgrade_and_legacy_backfill(self):
        for arch in ("arm64", "x86_64"):
            build = self.build if arch == "arm64" else self.make_build(arch)
            published = self.publish(build=build, arch=arch)
            self.assertEqual(published.returncode, 0, published.stderr)
            self.assertEqual(self.version(arch).read_bytes(), b'#define BARC_CHROMIUM_VERSION "156.0.8078.80"\n')

        artifact = self.package / "RuntimeArtifacts/arm64/Engine"
        prior = self.pin("arm64").read_bytes()
        engine_inode = artifact.stat().st_ino
        self.version("arm64").unlink()
        repeat = self.publish()
        self.assertEqual(repeat.returncode, 0, repeat.stderr)
        self.assertIn("Verified existing SDK", repeat.stdout)
        self.assertEqual(artifact.stat().st_ino, engine_inode)
        self.assertEqual(self.pin("arm64").read_bytes(), prior)
        self.assertEqual(self.version("arm64").read_bytes(), self.version("x86_64").read_bytes())

        upgrade = self.make_build("arm64", "156.0.8078.105")
        intel_pin = self.pin("x86_64").read_bytes()
        stopped = self.in_transaction("""
import os
write = publication.write_atomic
def stop_before_pin(work, target, content):
    if target.name == 'engine-artifact-arm64.sha256':
        os._exit(75)
    write(work, target, content)
publication.write_atomic = stop_before_pin
""", build=upgrade)
        self.assertEqual(stopped.returncode, 75, stopped.stderr)
        self.assertEqual(self.pin("arm64").read_bytes(), prior)
        self.assertEqual(self.version("arm64").read_bytes(), self.version("x86_64").read_bytes())

        recovered = self.publish(build=upgrade)
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertIn("Recovered SDK publication", recovered.stdout)
        self.assertNotEqual(self.pin("arm64").read_bytes(), prior)
        self.assertEqual(self.version("arm64").read_bytes(), b'#define BARC_CHROMIUM_VERSION "156.0.8078.105"\n')
        self.assertEqual(self.pin("x86_64").read_bytes(), intel_pin)
        self.assertEqual(self.version("x86_64").read_bytes(), b'#define BARC_CHROMIUM_VERSION "156.0.8078.80"\n')

    def test_publication_rejects_framework_version_mismatch_and_metadata_symlink(self):
        info = self.build / "Bark.app/Contents/Frameworks/Bark Framework.framework/Versions/Current/Resources/Info.plist"
        self.fixture["write_plist"](info, CFBundleShortVersionString="156.0.8078.105")
        refused = self.publish()
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("framework differs from engine-Info.plist", refused.stderr)
        self.assertFalse(self.pin("arm64").exists())

        self.fixture["write_plist"](info, CFBundleShortVersionString=self.fixture["VERSION"])
        target = self.work / "do-not-overwrite"
        target.write_bytes(b"sentinel")
        self.version("arm64").symlink_to(target)
        refused = self.publish()
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("Expected a regular SDK metadata file", refused.stderr)
        self.assertEqual(target.read_bytes(), b"sentinel")
        self.assertFalse(self.pin("arm64").exists())

    def make_official(self, arch="arm64", v8_template=None):
        chromium = self.chromium
        pins_path = chromium / "PINS.json"
        pins = json.loads(pins_path.read_text())
        source = self.build.parent.parent
        v8 = source / "v8"
        if v8_template is None:
            v8.mkdir()
            subprocess.run(["git", "-C", v8, "init", "-q"], check=True)
            subprocess.run(["git", "-C", v8, "-c", "core.hooksPath=/dev/null",
                            "-c", "user.name=V8 fixture", "-c", "user.email=fixture@example.invalid",
                            "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-qm", "Synthetic V8"], check=True)
        else:
            subprocess.run(["git", "clone", "-q", "--local", v8_template, v8], check=True)
        revision = subprocess.check_output(["git", "-C", v8, "rev-parse", "HEAD"], text=True).strip()
        v8_profile = v8 / "tools/builtins-pgo/profiles/x64.profile"
        v8_profile.parent.mkdir(parents=True)
        v8_profile.write_bytes(V8_FIXTURE)
        pins["official_v8_builtins"].update(revision=revision, sha256=hashlib.sha256(V8_FIXTURE).hexdigest())
        pins_path.write_text(json.dumps(pins))
        target = "mac-arm" if arch == "arm64" else "mac"
        profile_name = pins["official_pgo_profiles"][target]
        selector = source / f"chrome/build/{target}.pgo.txt"
        selector.parent.mkdir(parents=True)
        selector.write_text(profile_name + "\n")
        profile = selector.parent / "pgo_profiles" / profile_name
        profile.parent.mkdir()
        profile.write_bytes(PGO_FIXTURE)
        self.tool("gn", "printf '%s\\n' " + shlex.quote(f"-fprofile-use={profile}"))
        state_file = self.build / "fake-siso-state.json"
        state = json.loads(state_file.read_text())
        browser = self.build / "obj/chrome/browser/core/browser_process_impl.o"
        browser.parent.mkdir(parents=True)
        browser.write_bytes(b"profiled browser object fixture")
        state["entries"].extend([
            {"name": str(profile), "digest": {"hash": hashlib.sha256(profile.read_bytes()).hexdigest()},
             "id": {"mod_time": profile.stat().st_mtime_ns}},
            {"name": str(browser), "digest": {"hash": hashlib.sha256(browser.read_bytes()).hexdigest()},
             "id": {"mod_time": browser.stat().st_mtime_ns}, "cmd_hash": "command", "edge_hash": "edge"},
        ])
        framework = self.build / "Bark.app/Contents/Frameworks/Bark Framework.framework"
        versioned = framework / "Versions/Current"
        sdk = pins["official_macos_sdk"]
        self.fixture["write_plist"](
            versioned / "Resources/Info.plist", DTSDKName="macosx" + sdk["version"],
            DTSDKBuild=sdk["build"], SCMRevision=pins["chromium"],
            CFBundleShortVersionString=(chromium / "CHROMIUM_VERSION").read_text().strip(),
        )
        # The receiver inspects both architectures without executing their code.
        linked = self.work / f"official-{arch}.dylib"
        self.fixture["fake_framework"](linked, arch=(
            "-arch", arch, "-mmacosx-version-min=15.5",
            f"-Wl,-platform_version,macos,15.5,{sdk['version']}",
        ))
        shutil.copyfile(linked, versioned / "Bark Framework")
        raw_image = self.build / "obj/chrome/chrome_framework_shared_library/Bark Framework"
        raw_image.parent.mkdir(parents=True)
        shutil.copyfile(linked, raw_image)
        state["entries"].append({"name": str(raw_image),
                                 "digest": {"hash": hashlib.sha256(raw_image.read_bytes()).hexdigest()},
                                 "id": {"mod_time": raw_image.stat().st_mtime_ns},
                                 "cmd_hash": "link command", "edge_hash": "link edge"})
        state_file.write_text(json.dumps(state))
        env = self.fixture["publisher_environment"](self.build, self.siso)
        subprocess.run([
            sys.executable, "-B", "-c", """
from pathlib import Path
import json, os, sys
sys.path.insert(0, sys.argv[1])
from build_engine import engine_args
from official_provenance import RECEIPT, record
out = Path(sys.argv[2])
(out / 'args.gn').write_bytes(engine_args('arm64' if sys.argv[3] == 'arm64' else 'x64', True))
(out / RECEIPT).write_text(json.dumps(record(out, out.parent.parent, sys.argv[3], os.environ)))
""", chromium, self.build, arch,
        ], env=env, check=True)

    def test_pair_published_sdk_metadata_and_verify_both_receiver_artifacts(self):
        v8_template = None
        for arch in ("arm64", "x86_64"):
            if arch == "x86_64":
                self.build = self.make_build(arch)
            self.make_official(arch, v8_template)
            v8_template = self.build.parent.parent / "v8"
            published = self.publish("--require-official", arch=arch)
            self.assertEqual(published.returncode, 0, published.stderr)
            self.assertEqual(json.loads(self.official_seal(arch).read_text()), self.expected_seal(self.package, arch))

        receiver = self.repo / "Packages/BarkEngine"
        dest = receiver / "BarkEngine.xcframework" / self.fixture["SLICE_NAME"] / "Headers/BarcChromium"
        dest.mkdir(parents=True)
        module_map = dest / "module.modulemap"
        module_map.write_bytes(b"existing receiver module map")
        (dest / "engine-artifact-x86_64.sha256").write_text("old pin")
        sources = {}
        for arch in ("arm64", "x86_64"):
            artifact = self.package / "RuntimeArtifacts" / arch / "Engine"
            sources[arch] = self.work / ("transfer-" + arch)
            shutil.copytree(artifact / "Headers", sources[arch] / "Headers")
            (sources[arch] / "Headers").chmod(0o755)
            for name in ("SHA256SUMS", "official-build.json"):
                shutil.copy2(artifact / name, sources[arch] / name)

        cli = [sys.executable, "-B", self.repo / "scripts/bark-check.py"]
        def pair(intel, arm, destination=receiver):
            return subprocess.run([*cli, "pair-sdk", "--x86-64", intel, "--arm64", arm,
                                   "--package", destination], capture_output=True, text=True)
        def snapshot():
            return {p.name: p.read_bytes() for p in dest.iterdir()}

        before = snapshot()
        wrong = pair(sources["arm64"], sources["arm64"])
        self.assertNotEqual(wrong.returncode, 0)
        self.assertIn("x86_64 receipt", wrong.stderr)
        self.assertEqual(snapshot(), before)
        for _ in range(2):
            accepted = pair(sources["x86_64"], sources["arm64"])
            self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(module_map.read_bytes(), before[module_map.name])
        for arch in sources:
            artifact = self.package / "RuntimeArtifacts" / arch / "Engine"
            self.assertEqual((dest / self.pin(arch).name).read_bytes(), self.pin(arch).read_bytes())
            self.assertEqual((dest / self.version(arch).name).read_bytes(), self.version(arch).read_bytes())
            self.assertEqual(json.loads((dest / self.official_seal(arch).name).read_text()),
                             self.expected_seal(self.package, arch))
            verified = subprocess.run([*cli, "engine", "--arch", arch, "--engine", artifact,
                                       "--require-official"], capture_output=True, text=True)
            self.assertEqual(verified.returncode, 0, verified.stderr)

        self.verify_app_only_receivers(receiver, pair, sources["x86_64"])

        accepted = snapshot()
        arm_version = dest / self.version("arm64").name
        arm_version.unlink()
        arm_version.symlink_to(self.version("arm64"))
        refused = pair(sources["x86_64"], sources["arm64"])
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("Expected a regular SDK metadata file", refused.stderr)
        self.assertTrue(arm_version.is_symlink())
        arm_version.unlink()
        arm_version.write_bytes(accepted[arm_version.name])
        digest_header = sources["arm64"] / "Headers/barc_public_headers_sha256.h"
        digest_header.chmod(0o644)
        digest_header.write_text("incomplete transfer")
        interrupted = pair(sources["x86_64"], sources["arm64"])
        self.assertNotEqual(interrupted.returncode, 0)
        self.assertIn("differs from its SDK manifest", interrupted.stderr)
        self.assertEqual(snapshot(), accepted)

        # Even two intact manifests must bind the same generated digest to the API.
        for arch in ("arm64", "x86_64"):
            inputs = sources[arch]
            header = inputs / "Headers/barc_public_headers_sha256.h"
            header.chmod(0o644)
            header.write_text("another bridge digest")
            manifest = inputs / "SHA256SUMS"
            rows = manifest.read_text().splitlines()
            name = "  ./Headers/barc_public_headers_sha256.h"
            updated = [hashlib.sha256(header.read_bytes()).hexdigest() + name
                       if line.endswith(name) else line for line in rows]
            manifest.chmod(0o644)
            manifest.write_text("\n".join(updated) + "\n")
            refused = pair(sources["x86_64"], sources["arm64"])
            self.assertNotEqual(refused.returncode, 0)
            self.assertIn("different public headers" if arch == "arm64" else "does not describe", refused.stderr)
            self.assertEqual(snapshot(), accepted)


    def verify_app_only_receivers(self, receiver, pair, compact_intel):
        thin = self.work / "app-only"
        shutil.copytree(self.repo / "scripts", thin / "scripts")
        shutil.copytree(self.repo / "ChromiumApp", thin / "ChromiumApp")
        shutil.copytree(receiver, thin / "Packages/BarkEngine")
        self.assertFalse((thin / "Runtime").exists())
        metadata = thin / "Packages/BarkEngine" / self.pin("arm64").relative_to(self.package).parent
        arm = self.package / "RuntimeArtifacts/arm64/Engine"

        def verify(root, arch, engine, *, official=True):
            flags = ["--require-official"] if official else []
            return subprocess.run([sys.executable, "-B", root / "scripts/bark-check.py", "engine",
                                   "--arch", arch, "--engine", engine, *flags],
                                  cwd=root, capture_output=True, text=True)

        for arch in ("arm64", "x86_64"):
            accepted = verify(thin, arch, self.package / "RuntimeArtifacts" / arch / "Engine")
            self.assertEqual(accepted.returncode, 0, accepted.stderr)

        seal = metadata / self.official_seal("arm64").name
        original = seal.read_bytes()
        seal.unlink()
        refused = verify(thin, "arm64", arm)
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("official verification needs", refused.stderr)
        seal.symlink_to(self.official_seal("arm64"))
        linked = verify(thin, "arm64", arm)
        self.assertNotEqual(linked.returncode, 0, linked.stdout)
        self.assertIn("official verification needs", linked.stderr)
        seal.unlink()
        for field in ("receipt_sha256", "sdk_sha256"):
            with self.subTest(tampered_field=field):
                seal.write_text(json.dumps({**json.loads(original), field: "0" * 64}))
                refused = verify(thin, "arm64", arm)
                self.assertNotEqual(refused.returncode, 0, refused.stdout)
                self.assertIn("official SDK seal does not match", refused.stderr)
                self.assertEqual(verify(thin, "arm64", arm, official=False).returncode, 0)
        seal.write_bytes(original)

        # Replacing only the normal pin must not convert a different, valid
        # developer SDK into an officially qualified SDK.
        dev_package = self.work / "developer-package"
        developer_build = self.make_build("arm64", "156.0.8078.105")
        published = subprocess.run(["/bin/bash", self.publisher, "--arch", "arm64",
                                    developer_build, dev_package],
                                   env=self.fixture["publisher_environment"](developer_build, self.siso),
                                   capture_output=True, text=True)
        self.assertEqual(published.returncode, 0, published.stderr)
        self.addCleanup(self.fixture["make_writable"], dev_package)
        dev = dev_package / "RuntimeArtifacts/arm64/Engine"
        local_pin = metadata / self.pin("arm64").name
        normal_pin = local_pin.read_bytes()
        developer_pin = hashlib.sha256((dev / "SHA256SUMS").read_bytes()).hexdigest()
        local_pin.write_text(developer_pin + "\n")
        self.assertEqual(verify(thin, "arm64", dev, official=False).returncode, 0)
        refused = verify(thin, "arm64", dev)
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        seal.write_text(json.dumps({**json.loads(original), "sdk_sha256": developer_pin}))
        refused = verify(thin, "arm64", dev)
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("regular official build receipt", refused.stderr)
        local_pin.write_bytes(normal_pin)
        seal.write_bytes(original)

        partial = thin / "Runtime/Chromium"
        partial.mkdir(parents=True)
        shutil.copyfile(self.chromium / "PINS.json", partial / "PINS.json")
        refused = verify(thin, "arm64", arm)
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("Incomplete Runtime/Chromium", refused.stderr)

        wrapper = self.chromium / "bark/tools/override_cc.c"
        source = wrapper.read_bytes()
        wrapper.write_bytes(source + b"\n/* drift after the official seal was published */\n")
        try:
            refused = verify(self.repo, "arm64", arm)
            self.assertNotEqual(refused.returncode, 0, refused.stdout)
            self.assertRegex(refused.stderr, r"official SDK receipt.*recipe")
        finally:
            wrapper.write_bytes(source)

        shutil.rmtree(partial.parent)
        self.verify_compact_framework_sdk(thin, arm, pair, compact_intel, verify)

    def verify_compact_framework_sdk(self, thin, arm, pair, compact_intel, verify):
        # Compact transfer can authenticate hashes and recipe inputs, but does
        # not carry the framework plist itself for the producer to inspect.
        mismatched = self.work / "wrong-sdk-arm"
        shutil.copytree(arm, mismatched, symlinks=True)
        self.addCleanup(self.fixture["make_writable"], mismatched)
        info = (mismatched / "Bark Framework.framework/Versions/Current/Resources/Info.plist").resolve()
        receipt = mismatched / "official-build.json"
        manifest = mismatched / "SHA256SUMS"
        for path in (info, receipt, manifest):
            path.chmod(0o644)
        self.fixture["write_plist"](info, **{**self.fixture["read_plist"](info), "DTSDKBuild": "25Z999"})
        receipt.write_text(json.dumps({**json.loads(receipt.read_text()),
                                      "framework_info_sha256": hashlib.sha256(info.read_bytes()).hexdigest()}))
        updates = {path.relative_to(mismatched).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                   for path in (info, receipt)}
        rows = []
        for line in manifest.read_text().splitlines():
            digest, name = line.split("  ./", 1)
            rows.append(f"{updates.get(name, digest)}  ./{name}\n")
        manifest.write_text("".join(rows))
        for path in (info, receipt, manifest):
            path.chmod(0o444)
        compact_arm = self.work / "wrong-sdk-arm-compact"
        shutil.copytree(mismatched / "Headers", compact_arm / "Headers")
        shutil.copy2(receipt, compact_arm / receipt.name)
        shutil.copy2(manifest, compact_arm / manifest.name)
        paired = pair(compact_intel, compact_arm, thin / "Packages/BarkEngine")
        self.assertEqual(paired.returncode, 0, paired.stderr)
        ordinary = verify(thin, "arm64", mismatched, official=False)
        self.assertEqual(ordinary.returncode, 0, ordinary.stderr)
        refused = verify(thin, "arm64", mismatched)
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("25Z999", refused.stderr)

    def test_only_verified_official_publication_can_omit_finder_pseudolocales(self):
        source = self.build / "Bark.app/Contents/Resources"
        # An official engine omits developer-only GRIT pseudolocales.
        for name in ("ar_XB.lproj", "en_XA.lproj"):
            shutil.rmtree(source / name)
        refused = self.publish()
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("ar_XB.lproj, en_XA.lproj", refused.stderr)
        self.assertFalse(self.pin("arm64").exists())

        self.make_official()
        accepted = self.publish("--require-official")
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        pin = self.pin("arm64").read_bytes()

        # Genuine localized files and additional pseudo-locale resources still
        # require parity. Preserve the previous immutable publication on refusal.
        (self.repo / "ChromiumApp/Resources/ar_XB.lproj/extra.txt").write_text("extra")
        refused = self.publish("--require-official", "--replace")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("ar_XB.lproj", refused.stderr)
        (self.repo / "ChromiumApp/Resources/ar_XB.lproj/extra.txt").unlink()
        shutil.rmtree(source / "en.lproj")
        refused = self.publish("--require-official", "--replace")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("en.lproj", refused.stderr)
        self.assertEqual(self.pin("arm64").read_bytes(), pin)

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

        self.make_official()
        (self.build / "official-build.json").write_text("{}")
        selector = self.build.parent.parent / "chrome/build/mac-arm.pgo.txt"
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

    def test_receipt_from_another_bark_runtime_cannot_replace_the_pin(self):
        self.make_official()
        original = self.publish("--require-official")
        self.assertEqual(original.returncode, 0, original.stderr)
        pin = self.pin("arm64").read_bytes()
        wrapper = self.chromium / "bark/tools/override_cc.c"
        wrapper.write_bytes(wrapper.read_bytes() + b"\n/* changed source fixture */\n")
        refused = self.publish("--require-official", "--replace")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("official SDK receipt differs", refused.stderr)
        self.assertEqual(self.pin("arm64").read_bytes(), pin)

    def test_same_arch_and_sdk_framework_replacement_cannot_publish(self):
        self.make_official()
        linked = self.build / "obj/chrome/chrome_framework_shared_library/Bark Framework"
        packaged = self.build / "Bark.app/Contents/Frameworks/Bark Framework.framework/Versions/Current/Bark Framework"
        sdk = json.loads((self.chromium / "PINS.json").read_text())["official_macos_sdk"]["version"]
        replacement = self.work / "replacement.dylib"
        self.fixture["fake_framework"](replacement, zone="Replacement image", arch=(
            "-arch", "arm64", "-mmacosx-version-min=15.5",
            f"-Wl,-platform_version,macos,15.5,{sdk}",
        ))
        self.assertNotEqual(linked.read_bytes(), replacement.read_bytes())
        shutil.copyfile(replacement, linked)
        shutil.copyfile(replacement, packaged)
        # Even with metadata amended to match the replaced bytes, the actual
        # Siso record still names the digest of the original linked image.
        receipt_path = self.build / "official-build.json"
        receipt = json.loads(receipt_path.read_text())
        receipt["framework_sha256"] = hashlib.sha256(replacement.read_bytes()).hexdigest()
        receipt_path.write_text(json.dumps(receipt))
        refused = self.publish("--require-official")
        self.assertNotEqual(refused.returncode, 0)
        self.assertIn("no matching Siso link record", refused.stderr)
        self.assertFalse(self.pin("arm64").exists())

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
        self.assertFalse(self.official_seal("arm64").exists())

        recovered = self.publish("--require-official")
        self.assertEqual(recovered.returncode, 0, recovered.stderr)
        self.assertIn("Recovered SDK publication", recovered.stdout)
        self.assertTrue(self.pin("arm64").is_file())
        self.assertFalse(journal.exists())
        seal = self.official_seal("arm64")
        expected = self.expected_seal(self.package, "arm64")
        self.assertEqual(json.loads(seal.read_text()), expected)
        original_pin = self.pin("arm64").read_bytes()
        seal.unlink()
        backfilled = self.publish()
        self.assertEqual(backfilled.returncode, 0, backfilled.stderr)
        self.assertEqual(json.loads(seal.read_text()), expected)
        self.assertEqual(self.pin("arm64").read_bytes(), original_pin)

        developer = self.make_build("arm64", "156.0.8078.105")
        refused = self.publish(build=developer)
        self.assertNotEqual(refused.returncode, 0, refused.stdout)
        self.assertIn("--replace", refused.stderr)
        self.assertEqual(json.loads(seal.read_text()), expected)
        downgraded = self.publish("--replace", build=developer)
        self.assertEqual(downgraded.returncode, 0, downgraded.stderr)
        self.assertNotEqual(self.pin("arm64").read_bytes(), original_pin)
        self.assertFalse(seal.exists())
