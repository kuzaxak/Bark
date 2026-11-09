#!/usr/bin/env python3
"""Runs the outer app's main, the public headers, publishing and staging against fake engine products."""
from pathlib import Path
import hashlib
import json
import os
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SHIM = ROOT / 'ChromiumApp'
APP_RESOURCES = SHIM / 'Resources'
STAGE = ROOT / 'scripts/stage-chromium-app.sh'
PUBLISH = ROOT / 'scripts/publish-chromium-engine.sh'
RUNTIME = ROOT / 'Runtime/Chromium'
PACKAGE = ROOT / 'Packages/BarkEngine'
XCFRAMEWORK = PACKAGE / 'BarkEngine.xcframework'
SLICE_NAME = 'macos-x86_64'
SLICE = XCFRAMEWORK / SLICE_NAME
PUBLIC_HEADERS = SLICE / 'Headers'
MODULE = PUBLIC_HEADERS / 'BarcChromium'
HEADER_NAMES = ['barc_bridge_api.h', 'barc_runtime_startup_api.h', 'barc_page_tweaks.h']
DIGEST_HEADER = 'barc_public_headers_sha256.h'
ENGINE_HEADER_DIRECTORIES = {'barc_bridge_api.h': 'chrome/browser/ui/views/frame', 'barc_runtime_startup_api.h': 'chrome/browser/ui/views/frame',
                             'barc_page_tweaks.h': 'chrome/browser/content_blocking'}
STARTUP = ROOT / 'App/Chromium/ChromiumStartup.swift'
VERSION = '156.0.8078.80'
FRAMEWORK = 'Bark Framework.framework'
BUNDLE_ID = 'ee.qdo.bark'
DELEGATING_ZONE = 'DelegatingDefaultZoneForPartitionAlloc'
BRIDGE_VERSION = 8
ENTRY = f'barc_engine_main_v{BRIDGE_VERSION}'
ABORT_STATUS = 134

ENGINE_PLIST = dict(CFBundleExecutable='Bark', CFBundleIdentifier=BUNDLE_ID, CFBundleName='Bark',
                    NSPrincipalClass='BrowserCrApplication', CFBundleShortVersionString=VERSION,
                    LSEnvironment={'MallocNanoZone': '0'},
                    CFBundleURLTypes=[{'CFBundleURLSchemes': ['http', 'https']}])
XCODE_ONLY_KEYS = dict(DTXcode='2630', DTSDKName='macosx26.2', BuildMachineOSBuild='24G',
                       CFBundleSupportedPlatforms=['MacOSX'])

COMMON = r'''
#include <mach/mach.h>
#include <malloc/malloc.h>
#include <stdio.h>
#include <stdlib.h>
static void record(const char* line) {
  FILE* f = fopen(getenv("SHIM_LOG"), "a");
  fprintf(f, "%s\n", line);
  fclose(f);
}
'''
FAKE_FRAMEWORK = COMMON + r'''
__attribute__((used)) static const char zone_name[] = ZONE_NAME;
__attribute__((constructor)) static void loaded(void) {
  vm_address_t* zones = NULL;
  unsigned zone_count = 0;
  malloc_get_all_zones(mach_task_self(), NULL, &zones, &zone_count);
  thread_act_array_t threads;
  mach_msg_type_number_t thread_count = 0;
  task_threads(mach_task_self(), &threads, &thread_count);
  char line[256];
  snprintf(line, sizeof line, "framework zone=%s threads=%u",
           ((malloc_zone_t*)zones[0])->zone_name, thread_count);
  record(line);
}
int ChromeMain(int argc, const char** argv) {
  record("chrome-main");
  return 23;
}
#ifdef HEADERS_SHA256
const char* barc_public_headers_sha256(void) { return HEADERS_SHA256; }
#endif
#ifdef ENTRY_FUNCTION
int ENTRY_FUNCTION(int argc, const char** argv) {
  record("engine-main");
  return ChromeMain(argc, argv);
}
#endif
'''
FAKE_SHELL = COMMON + r'''
#include <dlfcn.h>
__attribute__((constructor)) static void loaded(void) { record("shell"); }
int barc_native_main(void* library, int argc, const char** argv) {
  char line[256];
  snprintf(line, sizeof line, "native-main argc=%d last=%s", argc, argv[argc - 1]);
  record(line);
  int (*engine_main)(int, const char**) = dlsym(library, ENTRY_NAME);
  return engine_main ? engine_main(argc, argv) : 99;
}
'''
# An unhandled abort writes a report to ~/Library/Logs/DiagnosticReports on every run.
QUIET_ABORT = r'''
#include <signal.h>
#include <unistd.h>
static void leave(int unused) { _exit(ABORT_STATUS); }
__attribute__((constructor)) static void quiet(void) { signal(SIGABRT, leave); }
'''
FAKE_SHELL_NO_ENTRY = COMMON + r'''
__attribute__((constructor)) static void loaded(void) { record("shell"); }
'''
MAIN_WITHOUT_ENTRY = r'''
__attribute__((used)) static const char a[] = "../Frameworks/Bark Framework.framework/Versions/''' + VERSION + r'''/Bark Framework";
__attribute__((used)) static const char b[] = "NookNativeShell.framework/Versions/A/NookNativeShell";
__attribute__((used)) static const char c[] = "barc_native_main";
__attribute__((used)) static const char d[] = "''' + DELEGATING_ZONE + r'''";
int main(void) { return 0; }
'''

failures = []
FAKE_SISO = None


def check(name, ok, detail=''):
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f': {detail}'), flush=True)
    if not ok:
        failures.append(name)


def compile_c(source, output, *extra):
    source_file = output.with_suffix('.c')
    source_file.write_text(source)
    subprocess.run(['xcrun', 'clang', '-arch', 'x86_64', str(source_file), '-o', str(output), *extra], check=True)


def headers_digest():
    lines = ''.join(f'{hashlib.sha256((RUNTIME / name).read_bytes()).hexdigest()}  {name}\n' for name in HEADER_NAMES)
    return hashlib.sha256(lines.encode()).hexdigest()


def digest_in(header):
    found = re.fullmatch(r'#define BARC_PUBLIC_HEADERS_SHA256 "([0-9a-f]{64})"\n', header.read_text()) if header.is_file() else None
    return found and found[1]


def fake_framework(output, entry=ENTRY, zone=DELEGATING_ZONE, arch=('-arch', 'x86_64'), digest=headers_digest()):
    extra = ['-dynamiclib', f'-DZONE_NAME="{zone}"', *arch]
    if entry:
        extra.append(f'-DENTRY_FUNCTION={entry}')
    if digest:
        extra.append(f'-DHEADERS_SHA256="{digest}"')
    compile_c(FAKE_FRAMEWORK, output, *extra)


def fake_shell(output, arch=('-arch', 'x86_64')):
    compile_c(FAKE_SHELL, output, '-dynamiclib', f'-DENTRY_NAME="{ENTRY}"', *arch)


def compile_shim(output, version=VERSION, headers=PUBLIC_HEADERS, extra=('-arch', 'x86_64'), libs=('-nostdlib++',)):
    sources = sorted(str(p) for p in SHIM.glob('*.cc'))
    if not sources:
        return False
    run = subprocess.run(['xcrun', 'clang++', *extra, '-std=c++20', '-fno-exceptions', '-fno-rtti',
                          *libs, '-O2', f'-DENGINE_VERSION_STRING="{version}"', f'-I{headers}', *sources, '-o', str(output)],
                         capture_output=True, text=True)
    if run.returncode:
        print(run.stderr)
    return run.returncode == 0


def write_plist(path, **values):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(values))


def read_plist(path):
    return plistlib.loads(path.read_bytes())


def versioned_framework(root, binary=None):
    framework = root / FRAMEWORK
    (framework / f'Versions/{VERSION}').mkdir(parents=True)
    (framework / 'Versions/Current').symlink_to(VERSION)
    (framework / 'Bark Framework').symlink_to('Versions/Current/Bark Framework')
    write_plist(framework / f'Versions/{VERSION}/Resources/Info.plist', CFBundleShortVersionString=VERSION)
    (framework / 'Resources').symlink_to('Versions/Current/Resources')
    if binary:
        shutil.copy2(binary, framework / f'Versions/{VERSION}/Bark Framework')
    return framework


def shell_framework(root, binary):
    framework = root / 'NookNativeShell.framework'
    (framework / 'Versions/A/Resources').mkdir(parents=True)
    (framework / 'Versions/Current').symlink_to('A')
    shutil.copy2(binary, framework / 'Versions/A/NookNativeShell')
    (framework / 'NookNativeShell').symlink_to('Versions/Current/NookNativeShell')
    return framework


def header_cases(work):
    missing = [name for name in HEADER_NAMES if not (MODULE / name).is_file()]
    check('package publishes the public headers', not missing, missing)
    if missing:
        return
    def code(text):
        return re.sub(r'//.*', '', text)
    for name in HEADER_NAMES:
        public = (MODULE / name).read_text()
        check(f'{name} matches its recipe source', public == (RUNTIME / name).read_text())
        run = subprocess.run(['xcrun', 'clang', '-arch', 'x86_64', '-x', 'c', '-std=c11', '-Werror', '-fsyntax-only', str(MODULE / name)],
                             capture_output=True, text=True)
        check(f'{name} compiles as plain C', run.returncode == 0, run.stderr)
        found = re.findall(r'\bnamespace\b|\bclass\b|\btemplate\b|#\s*include\s*["<](?!stddef\.h|stdint\.h)', code(public))
        check(f'{name} holds no C++ and includes only C headers', not found, found)
    for name, marker in [('barc_bridge.h', 'bool CanRequestPeek'), ('barc_runtime_startup.h', 'bool IsNativeApplicationMode')]:
        private = (RUNTIME / name).read_text()
        public_name = name.replace('.h', '_api.h')
        check(f'{name} keeps the private C++ and includes its public header',
              marker in private and 'namespace barc' in private and f'{public_name}"' in private)

    header = (MODULE / 'barc_bridge_api.h').read_text()
    version = re.search(r'#define BARC_BRIDGE_VERSION (\d+)', header)
    symbol = re.search(r'#define BARC_ENGINE_MAIN_SYMBOL "(\w+)"', header)
    check('entry symbol names the bridge version', bool(version and symbol) and int(version[1]) == BRIDGE_VERSION and symbol[1] == ENTRY,
          (version, symbol))
    check('entry is declared with the bridge\'s visibility', f'BARC_API int {ENTRY}(int argc, const char** argv);' in header)
    check('the bridge declares the digest of its public headers', 'BARC_API const char* barc_public_headers_sha256(void);' in header)
    check('the package holds the digest of exactly these public headers', digest_in(MODULE / DIGEST_HEADER) == headers_digest(),
          (digest_in(MODULE / DIGEST_HEADER), headers_digest()))

    source = work / 'linkage.cc'
    source.write_text(f'#include "BarcChromium/barc_bridge_api.h"\nint {ENTRY}(int argc, const char** argv) {{ return argc; }}\n')
    subprocess.run(['xcrun', 'clang++', '-arch', 'x86_64', '-std=c++20', f'-I{PUBLIC_HEADERS}', '-c', str(source), '-o', str(work / 'linkage.o')], check=True)
    symbols = subprocess.check_output(['nm', '-gjU', str(work / 'linkage.o')], text=True).split()
    check('from C++ the entry keeps C linkage', symbols == [f'_{ENTRY}'], symbols)

    swift = work / 'import.swift'
    swift.write_text('import BarcChromium\n'
                     'let entry: String = BARC_ENGINE_MAIN_SYMBOL\n'
                     'let split = BarcSplitLayout()\n'
                     'let target = BarcApplicationTarget()\n'
                     'let publish = barc_page_tweaks_publish\n')
    run = subprocess.run(['xcrun', 'swiftc', '-target', 'x86_64-apple-macosx15.5', '-typecheck', '-I', str(PUBLIC_HEADERS), str(swift)],
                         capture_output=True, text=True)
    check('Swift imports the module and its string entry name', run.returncode == 0, run.stderr[-600:])


def startup_version_cases(work):
    def required_version(name, headers):
        probe = work / f'{name}.swift'
        probe.parent.mkdir(exist_ok=True)
        directory = work / name
        directory.mkdir()
        main_swift = directory / 'main.swift'
        main_swift.write_text('import Foundation\n'
                              'let config = try ChromiumStartupConfiguration(arguments: ["x", "--barc-app-data-dir=/private/tmp/nook-check-version", '
                              '"--barc-app-profile=5068D9EB-6482-4F00-B743-6606EA7898F4"])\n'
                              'print(config.requiredBridgeVersion)\n')
        built = subprocess.run(['xcrun', 'swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-I', str(headers),
                                str(STARTUP), str(main_swift), '-o', str(directory / 'probe')], capture_output=True, text=True)
        if built.returncode:
            return built.stderr[-300:]
        return subprocess.run([str(directory / 'probe')], capture_output=True, text=True).stdout.strip()

    check('the app requires the header\'s bridge version', required_version('startup-current', PUBLIC_HEADERS) == str(BRIDGE_VERSION))
    bumped = work / 'bumped-headers/BarcChromium'
    shutil.copytree(MODULE, bumped)
    header = bumped / 'barc_bridge_api.h'
    header.write_text(header.read_text().replace(f'BARC_BRIDGE_VERSION {BRIDGE_VERSION}', f'BARC_BRIDGE_VERSION {BRIDGE_VERSION + 1}'))
    result = required_version('startup-bumped', work / 'bumped-headers')
    check('a bumped header changes the version the app requires', result == str(BRIDGE_VERSION + 1), result)


def package_cases(work):
    run = subprocess.run(['swift', 'package', 'dump-package', '--package-path', str(PACKAGE)], capture_output=True, text=True)
    check('the package manifest parses', run.returncode == 0, run.stderr[-400:])
    if run.returncode:
        return
    targets = json.loads(run.stdout)['targets']
    check('the package is one binary target', [(t['name'], t['type'], t['path']) for t in targets] ==
          [('BarkEngine', 'binary', 'BarkEngine.xcframework')], targets)
    info = read_plist(XCFRAMEWORK / 'Info.plist')
    libraries = info['AvailableLibraries']
    check('the xcframework has one x86_64 macOS library slice',
          [(l['LibraryIdentifier'], l['SupportedPlatform'], l['SupportedArchitectures'], l.get('HeadersPath')) for l in libraries] ==
          [(SLICE_NAME, 'macos', ['x86_64'], 'Headers')], libraries)
    stub = SLICE / libraries[0]['LibraryPath']
    defined = subprocess.run(['nm', '-gjU', str(stub)], capture_output=True, text=True).stdout
    check('the slice library defines no symbols', stub.is_file() and not [l for l in defined.splitlines() if l.startswith('_')], defined)
    probe = work / 'probe.c'
    probe.write_text('int main(void) { return 0; }\n')
    subprocess.run(['xcrun', 'clang', '-arch', 'x86_64', str(probe), str(stub), '-o', str(work / 'probe')], check=True)
    linked = [l.split()[0] for l in subprocess.check_output(['otool', '-L', str(work / 'probe')], text=True).splitlines()[1:]]
    check('linking the package adds no library', linked == ['/usr/lib/libSystem.B.dylib'], linked)


def launch_cases(work, shim, framework_lib, shell_lib, no_entry_lib, quiet_lib):
    def launch(name, framework=framework_lib, shell=shell_lib, main=shim):
        contents = work / name / 'Bark.app/Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Frameworks').mkdir()
        shutil.copy2(main, contents / 'MacOS/Bark')
        if framework:
            versioned_framework(contents / 'Frameworks', framework)
        if shell:
            shell_framework(contents / 'Frameworks', shell)
        log = work / name / 'log.txt'
        log.touch()
        run = subprocess.run([str(contents / 'MacOS/Bark'), '--barc-app-data-dir=/synthetic', 'last-argument'],
                             env={**os.environ, 'SHIM_LOG': str(log), 'DYLD_INSERT_LIBRARIES': str(quiet_lib)}, capture_output=True, text=True, timeout=30)
        return run, log.read_text().splitlines()

    run, lines = launch('normal')
    check('zone is the delegating one when the framework loads, with one thread',
          lines[:1] == [f'framework zone={DELEGATING_ZONE} threads=1'], lines)
    check('framework loads, then the shell, then the shell enters the engine through the versioned symbol',
          lines[1:] == ['shell', 'native-main argc=3 last=last-argument', 'engine-main', 'chrome-main'], lines)
    check('exit status is what the shell returned', run.returncode == 23, run.returncode)

    run, lines = launch('no-shell', shell=None)
    check('missing shell aborts before ChromeMain', run.returncode == ABORT_STATUS and 'chrome-main' not in lines, (run.returncode, lines))
    check('missing shell names the shell in its error', 'NookNativeShell' in run.stderr, run.stderr)

    run, lines = launch('no-framework', framework=None)
    check('missing framework aborts before the shell loads', run.returncode == ABORT_STATUS and lines == [], (run.returncode, lines))
    check('missing framework names it in its error', 'Bark Framework' in run.stderr, run.stderr)

    run, lines = launch('no-entry', shell=no_entry_lib)
    check('shell without its entry aborts before ChromeMain', run.returncode == ABORT_STATUS and 'chrome-main' not in lines, (run.returncode, lines))

    old_engine = work / 'framework-without-entry.dylib'
    fake_framework(old_engine, entry=None)
    run, lines = launch('engine-without-entry', framework=old_engine)
    check('an engine without the versioned entry aborts before the shell loads',
          run.returncode == ABORT_STATUS and 'shell' not in lines, (run.returncode, lines))
    check('that error names the missing entry', ENTRY in run.stderr, run.stderr)

    for name, digest, why in [('engine-without-digest', None, 'an engine that exports no header digest'),
                              ('engine-other-digest', '0' * 64, 'an engine built from other public headers')]:
        engine = work / f'{name}.dylib'
        fake_framework(engine, digest=digest)
        run, lines = launch(name, framework=engine)
        check(f'{why} aborts before the shell loads', run.returncode == ABORT_STATUS and 'shell' not in lines, (run.returncode, lines))
        check(f'that error names both digests', 'other public headers' in run.stderr and headers_digest() in run.stderr and
              (digest or 'none') in run.stderr, run.stderr)

    other_headers = work / 'other-headers/BarcChromium'
    shutil.copytree(MODULE, other_headers)
    header = other_headers / 'barc_bridge_api.h'
    header.write_text(header.read_text().replace(ENTRY, 'barc_engine_main_v5').replace(f'BARC_BRIDGE_VERSION {BRIDGE_VERSION}', 'BARC_BRIDGE_VERSION 5'))
    wrong = work / 'wrong-version-shim'
    assert compile_shim(wrong, headers=work / 'other-headers')
    run, lines = launch('wrong-version', main=wrong)
    check('an app built against another bridge version aborts before the shell loads',
          run.returncode == ABORT_STATUS and 'shell' not in lines and 'chrome-main' not in lines, (run.returncode, lines))
    check('that error names the version the app wants and says the engine differs',
          'barc_engine_main_v5' in run.stderr and 'another bridge version' in run.stderr, run.stderr)

    libraries = subprocess.check_output(['otool', '-L', str(shim)], text=True).splitlines()[1:]
    linked = [line.split()[0] for line in libraries]
    check('main links only libSystem', linked == ['/usr/lib/libSystem.B.dylib'], linked)


def artifact_of(package):
    return package / f'BarkEngine.xcframework/{SLICE_NAME}/Engine'


def seal(artifact, products):
    """Refreshes the artifact's checksums so a mutation reaches the gate under test, not the checksum gate."""
    files = sorted(p for p in artifact.rglob('*') if p.is_file() and not p.is_symlink() and p.name != 'SHA256SUMS')
    run = subprocess.run(['shasum', '-a', '256', *['./' + str(p.relative_to(artifact)) for p in files]], cwd=artifact, capture_output=True, text=True, check=True)
    (artifact / 'SHA256SUMS').write_text(run.stdout)
    pin = subprocess.check_output(['shasum', '-a', '256', 'SHA256SUMS'], cwd=artifact, text=True).split()[0]
    (products / 'include/BarcChromium/engine-artifact.sha256').write_text(pin + '\n')


def sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def engine_binary(build):
    return build / f'Bark.app/Contents/Frameworks/{FRAMEWORK}/Versions/{VERSION}/Bark Framework'


def write_build_record(build, **headers):
    """What `siso fs export` reports: each input's digest and modification time as of the last build."""
    source = build.parents[1]
    linked = engine_binary(build).stat().st_mtime_ns if engine_binary(build).exists() else 0
    entries = [{'name': str(build / 'obj/unrelated.o'), 'id': {'mod_time': linked}}]
    for name, directory in ENGINE_HEADER_DIRECTORIES.items():
        entry = {'name': str(source / directory / name), 'id': {'mod_time': linked - 1_000_000_000},
                 'digest': {'hash': sha256(RUNTIME / name), 'size_bytes': (RUNTIME / name).stat().st_size}}
        changes = headers.get(name.replace('.', '_'))
        if changes is None and name.replace('.', '_') in headers:
            continue
        entry.update(changes or {})
        entries.append(entry)
    (build / 'fake-siso-state.json').write_text(json.dumps({'entries': entries}))


def fake_engine_build(root, framework_lib):
    """What the engine's build directory holds: its Bark.app with outer resources and stock launcher, and Bark Packaging."""
    build = root / 'source/out/Barc-x64'
    engine = build / 'Bark.app/Contents'
    (engine / 'MacOS').mkdir(parents=True)
    (engine / 'MacOS/Bark').write_text('stock launcher that must not ship')
    write_plist(engine / 'Info.plist', **ENGINE_PLIST)
    (engine / 'Frameworks').mkdir()
    versioned_framework(engine / 'Frameworks', framework_lib)
    shutil.copytree(APP_RESOURCES, engine / 'Resources')
    (build / 'Bark Packaging/signing').mkdir(parents=True)
    (build / 'Bark Packaging/sign_chrome.py').write_text('import signing\n')
    (build / 'Bark Packaging/signing/__init__.py').write_text('')
    write_build_record(build)
    return build


def publish(build, package, siso=None):
    fake = FAKE_SISO if siso is None else siso
    env = {**os.environ, 'PATH': f'{fake}:{os.environ["PATH"]}', 'FAKE_SISO_STATE': str(build / 'fake-siso-state.json')}
    return subprocess.run(['bash', str(PUBLISH), str(build), str(package)], capture_output=True, text=True, env=env)


def same_text(a, b):
    return a.is_file() and b.is_file() and a.read_text() == b.read_text()


def make_writable(path):
    subprocess.run(['chmod', '-R', 'u+w', str(path)], check=True)


def make_inputs(root, shim, framework_lib, shell_lib, writable=True):
    root.mkdir()
    build = fake_engine_build(root, framework_lib)
    package = root / 'package'
    run = publish(build, package)
    assert run.returncode == 0, run.stderr
    artifact = artifact_of(package)
    if writable:
        make_writable(artifact)

    app = root / 'app/Bark.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    shutil.copy2(shim, app / 'MacOS/Bark')
    write_plist(app / 'Info.plist', **ENGINE_PLIST, **XCODE_ONLY_KEYS)
    shutil.copytree(APP_RESOURCES, app / 'Resources')

    products = root / 'products'
    framework = shell_framework(products, shell_lib)
    resources = framework / 'Versions/A/Resources'
    (resources / 'Assets.car').write_text('assets')
    (resources / 'default.metallib').write_text('metal')
    write_plist(resources / 'Info.plist', CFBundlePackageType='FMWK', CFBundleExecutable='NookNativeShell',
                CFBundleIdentifier='ee.qdo.nook.NativeShell')
    (products / 'PackageFrameworks/Packaged.framework').mkdir(parents=True)
    (products / 'Sparkle.framework').mkdir()
    (products / 'NookWeb_NookWeb.bundle').mkdir()
    (products / 'include').mkdir()
    shutil.copytree(package / f'BarkEngine.xcframework/{SLICE_NAME}/Headers/BarcChromium', products / 'include/BarcChromium')
    return root / 'app/Bark.app', artifact, products


def stage(app, artifact, products, output):
    return subprocess.run(['bash', str(STAGE), str(app), str(artifact), str(products), str(output)],
                          capture_output=True, text=True)


def publish_cases(work, framework_lib):
    def attempt(name, mutate=None, framework=framework_lib):
        root = work / name
        root.mkdir()
        build = fake_engine_build(root, framework)
        if mutate:
            mutate(build)
        package = root / 'package'
        return publish(build, package), package

    run, package = attempt('publish-ok')
    check('publishing a valid engine succeeds', run.returncode == 0, run.stderr)
    if run.returncode:
        return
    artifact = artifact_of(package)
    check('the artifact holds the framework, packaging, the engine plist, public headers and checksums, nothing else',
          sorted(p.name for p in artifact.iterdir()) == sorted([FRAMEWORK, 'Bark Packaging', 'engine-Info.plist', 'Headers', 'SHA256SUMS']),
          sorted(p.name for p in artifact.iterdir()))
    check('the artifact holds the public headers', all(same_text(artifact / 'Headers' / n, RUNTIME / n) for n in HEADER_NAMES))
    published = package / f'BarkEngine.xcframework/{SLICE_NAME}/Headers/BarcChromium'
    check('publishing copies the public headers', all((published / n).read_text() == (RUNTIME / n).read_text() for n in HEADER_NAMES))
    pin = subprocess.check_output(['shasum', '-a', '256', 'SHA256SUMS'], cwd=artifact, text=True).split()[0]
    check('the pin is the checksum list\'s SHA', (published / 'engine-artifact.sha256').read_text().strip() == pin)
    listed = (artifact / 'SHA256SUMS').read_text()
    check('checksums cover the versioned framework executable', f'{FRAMEWORK}/Versions/{VERSION}/Bark Framework' in listed, listed)
    check('checksums cover the public headers', all(f'./Headers/{n}' in listed for n in HEADER_NAMES), listed)
    check('publishing writes the digest of the headers it publishes beside them',
          digest_in(artifact / 'Headers' / DIGEST_HEADER) == headers_digest() and digest_in(published / DIGEST_HEADER) == headers_digest() and
          f'./Headers/{DIGEST_HEADER}' in listed)
    check('a published artifact cannot be written to', not os.access(artifact, os.W_OK) and not os.access(artifact / 'Bark Packaging/signing', os.W_OK) and
          not os.access(artifact / 'engine-Info.plist', os.W_OK))
    executable = artifact / FRAMEWORK / f'Versions/{VERSION}/Bark Framework'
    check('a published artifact keeps its executable bits', os.access(executable, os.X_OK))

    again = publish(work / 'publish-ok/engine', package)
    check('publishing refuses to replace an artifact', again.returncode != 0 and 'already published' in again.stderr, (again.returncode, again.stderr))

    def refused(name, why, reason, mutate=None, framework=framework_lib):
        run, _ = attempt(name, mutate, framework)
        check(f'publishing refuses {why}', run.returncode != 0 and reason in run.stderr, (run.returncode, run.stderr))

    refused('publish-no-framework', 'an engine without its framework', 'Missing Bark framework',
            lambda b: shutil.rmtree(b / 'Bark.app/Contents/Frameworks' / FRAMEWORK))
    refused('publish-no-packaging', 'an engine without its signing tools', 'Missing Bark Packaging',
            lambda b: shutil.rmtree(b / 'Bark Packaging'))
    refused('publish-resource-drift', 'outer resources that differ from the app\'s', 'differ from ChromiumApp/Resources',
            lambda b: (b / 'Bark.app/Contents/Resources/app.icns').write_text('other'))
    no_entry = work / 'publish-no-entry.dylib'
    fake_framework(no_entry, entry=None)
    refused('publish-no-entry', 'an engine that does not export the header\'s entry', f'does not export {ENTRY}', framework=no_entry)
    no_digest = work / 'publish-no-digest-export.dylib'
    fake_framework(no_digest, digest=None)
    refused('publish-no-digest-export', 'an engine that does not export its header digest', 'does not export barc_public_headers_sha256',
            framework=no_digest)
    fat = work / 'publish-fat.dylib'
    fake_framework(fat, arch=('-arch', 'x86_64', '-arch', 'arm64'))
    refused('publish-fat', 'an engine that is not exactly x86_64', 'must be exactly x86_64', framework=fat)

    for name in HEADER_NAMES:
        key = name.replace('.', '_')
        refused('publish-other-' + name, f'an engine built from another {name}', f'Engine was built from another {name} than Runtime/Chromium',
                lambda b, k=key: write_build_record(b, **{k: {'digest': {'hash': '0' * 64, 'size_bytes': 1}}}))
        refused('publish-late-' + name, f'{name} changed after the engine was linked', f'{name} changed after the engine was linked',
                lambda b, k=key: write_build_record(b, **{k: {'id': {'mod_time': engine_binary(b).stat().st_mtime_ns + 1_000_000_000}}}))
        refused('publish-unrecorded-' + name, f'a build record without {name}', f'No build record of {name}',
                lambda b, k=key: write_build_record(b, **{k: None}))
    refused('publish-no-digest', 'a header the build record has no digest for', 'No build record of barc_bridge_api.h',
            lambda b: write_build_record(b, barc_bridge_api_h={'digest': {}}))
    refused('publish-no-record', 'a build directory with no build record', 'Cannot read the build record',
            lambda b: (b / 'fake-siso-state.json').unlink())

    def later_source_changes(b):
        source = b.parents[1]
        for name, directory in ENGINE_HEADER_DIRECTORIES.items():
            changed = source / directory / name
            changed.parent.mkdir(parents=True, exist_ok=True)
            changed.write_text('// hunks the engine was not built with\n')
    run, package = attempt('publish-tree-moved-on', later_source_changes)
    check('a source tree changed after the build does not refuse an engine built from Runtime/Chromium', run.returncode == 0, run.stderr)
    published = package / f'BarkEngine.xcframework/{SLICE_NAME}'
    check('it publishes the headers the engine was built from, not the changed tree\'s',
          run.returncode == 0 and all(same_text(published / 'Engine/Headers' / n, RUNTIME / n) and
                                      same_text(published / 'Headers/BarcChromium' / n, RUNTIME / n) for n in HEADER_NAMES))


def stage_cases(work, shim, framework_lib, shell_lib):
    def inputs(name):
        return make_inputs(work / name, shim, framework_lib, shell_lib)

    app, artifact, products = make_inputs(work / 'flip', shim, framework_lib, shell_lib, writable=False)
    output = work / 'flip/out/Bark.app'
    output.parent.mkdir()
    run = stage(app, artifact, products, output)
    check('valid inputs stage from a read-only artifact', run.returncode == 0, run.stderr)
    contents = output / 'Contents'
    staged_binary = contents / 'Frameworks' / FRAMEWORK / f'Versions/{VERSION}/Bark Framework'
    check('what signing rewrites is writable after staging',
          os.access(staged_binary, os.W_OK) and os.access(staged_binary, os.X_OK) and os.access(staged_binary.parent, os.W_OK))
    env = {k: v for k, v in os.environ.items() if k != 'PYTHONDONTWRITEBYTECODE'}
    signer = subprocess.run([sys.executable, str(artifact / 'Bark Packaging/sign_chrome.py')], capture_output=True, text=True, env=env)
    check('the signing tools run from the artifact', signer.returncode == 0, signer.stderr)
    check('running them leaves no bytecode in the artifact', not list(artifact.rglob('__pycache__')))
    again = work / 'flip/again/Bark.app'
    again.parent.mkdir()
    run = stage(app, artifact, products, again)
    check('the next staging against the same artifact succeeds', run.returncode == 0, run.stderr)
    executable = contents / 'MacOS/Bark'
    check('outer executable is the app target\'s main',
          executable.is_file() and executable.read_bytes() == shim.read_bytes())
    check('Contents/MacOS holds nothing else', [p.name for p in (contents / 'MacOS').iterdir()] == ['Bark'] if executable.exists() else False)
    info = contents / 'Info.plist'
    check('outer Info.plist is the app target\'s', info.is_file() and read_plist(info).get('DTXcode') == XCODE_ONLY_KEYS['DTXcode'])
    engine_framework = contents / 'Frameworks' / FRAMEWORK
    check('engine framework is inside, with its version symlinks',
          (engine_framework / 'Versions/Current').is_symlink() and (engine_framework / f'Versions/{VERSION}/Bark Framework').is_file())
    check('shell and package frameworks are inside',
          all((contents / 'Frameworks' / n).is_dir() for n in ['NookNativeShell.framework', 'Sparkle.framework', 'Packaged.framework']))
    check('the app\'s own resources and native bundles are inside',
          all((contents / 'Resources' / n).exists() for n in ['app.icns', 'en.lproj/InfoPlist.strings', 'NookWeb_NookWeb.bundle']))

    def refused(name, why, reason, mutate, sealed=True):
        app, artifact, products = inputs(name)
        mutate(app, artifact, products)
        if sealed:
            seal(artifact, products)
        out = work / name / 'out/Bark.app'
        out.parent.mkdir()
        run = stage(app, artifact, products, out)
        check(f'refuses {why}', run.returncode != 0 and reason in run.stderr and not out.exists(), (run.returncode, run.stderr))

    versioned = lambda a: a / FRAMEWORK / f'Versions/{VERSION}'

    def edit_plist(path, **changes):
        values = read_plist(path)
        for key, value in changes.items():
            if value is None:
                values.pop(key, None)
            else:
                values[key] = value
        path.write_bytes(plistlib.dumps(values))

    refused('no-engine-framework', 'an engine without its framework', 'Missing Bark framework',
            lambda a, e, p: shutil.rmtree(e / FRAMEWORK))
    refused('stock-app', 'an app executable that does not load the shell', 'lacks the required native bootstrap',
            lambda a, e, p: shutil.copy2(framework_lib, a / 'Contents/MacOS/Bark'))

    refused('changed-artifact', 'an artifact whose files no longer match its checksums', 'does not match its SHA256SUMS',
            lambda a, e, p: (versioned(e) / 'Bark Framework').write_text('other'), sealed=False)
    refused('unlisted-file', 'an artifact holding a file its checksums do not list', 'does not match its SHA256SUMS',
            lambda a, e, p: (e / 'extra').write_text('extra'), sealed=False)
    refused('no-checksums', 'an artifact without its checksums', 'does not match its SHA256SUMS',
            lambda a, e, p: (e / 'SHA256SUMS').unlink(), sealed=False)
    def other_pin(a, e, p):
        (p / 'include/BarcChromium/engine-artifact.sha256').write_text('0' * 64 + '\n')
    refused('other-pin', 'an app built against another engine artifact', 'built against another engine artifact', other_pin, sealed=False)
    refused('no-pin', 'app products without an engine pin', 'built against another engine artifact',
            lambda a, e, p: (p / 'include/BarcChromium/engine-artifact.sha256').unlink(), sealed=False)
    for name in HEADER_NAMES + [DIGEST_HEADER]:
        reason = f'App was compiled against another {name} than the engine\'s'
        refused('app-header-' + name, f'an app compiled against another {name}', reason,
                lambda a, e, p, n=name: (p / 'include/BarcChromium' / n).write_text('// another layout\n'))
        refused('engine-header-' + name, f'an engine holding another {name}', reason,
                lambda a, e, p, n=name: (e / 'Headers' / n).write_text('// another layout\n'))
        refused('no-app-header-' + name, f'app products without {name}', reason,
                lambda a, e, p, n=name: (p / 'include/BarcChromium' / n).unlink())
        refused('no-engine-header-' + name, f'an engine without {name}', reason,
                lambda a, e, p, n=name: (e / 'Headers' / n).unlink())

    def other_version(a, e, p):
        other = work / 'other-version-shim'
        assert compile_shim(other, version='1.2.3.4')
        shutil.copy2(other, a / 'Contents/MacOS/Bark')
    refused('other-version', 'a main built for another engine version', 'another engine version', other_version)

    def extra_library(a, e, p):
        library = work / 'linked-shim'
        assert compile_shim(library, libs=('-framework', 'AppKit', '-Wl,-needed_framework,AppKit'))
        shutil.copy2(library, a / 'Contents/MacOS/Bark')
    refused('extra-library', 'a main that links more than libSystem', 'must link only libSystem', extra_library)

    def both_identity(identifier):
        def change(a, e, p):
            edit_plist(a / 'Contents/Info.plist', CFBundleIdentifier=identifier)
            edit_plist(e / 'engine-Info.plist', CFBundleIdentifier=identifier)
        return change
    refused('other-identity', 'an identifier other than ee.qdo.bark even when app and engine agree', 'must be exactly ee.qdo.bark',
            both_identity('ee.qdo.other'))
    refused('near-identity', 'an identifier that merely starts with the shipping one', 'must be exactly ee.qdo.bark',
            both_identity('ee.qdo.nook.x'))
    refused('shipping-identity', 'the shipping app\'s bundle identifier', 'must be exactly ee.qdo.bark',
            both_identity('ee.qdo.nook'))
    refused('no-identity', 'an app with no identifier', 'must be exactly ee.qdo.bark',
            lambda a, e, p: (edit_plist(a / 'Contents/Info.plist', CFBundleIdentifier=None), edit_plist(e / 'engine-Info.plist', CFBundleIdentifier=None)))

    refused('no-principal-class', 'an app that does not let Chromium own NSApplication', 'BrowserCrApplication',
            lambda a, e, p: (edit_plist(a / 'Contents/Info.plist', NSPrincipalClass=None), edit_plist(e / 'engine-Info.plist', NSPrincipalClass=None)))
    refused('framework-collision', 'a product named like the engine framework', 'Framework collision',
            lambda a, e, p: (p / FRAMEWORK).mkdir())
    refused('resource-collision', 'a product bundle named like an app resource', 'Resource collision',
            lambda a, e, p: (a / 'Contents/Resources/NookWeb_NookWeb.bundle').mkdir())

    refused('no-resources', 'an app with no Resources directory', 'Missing outer resource',
            lambda a, e, p: shutil.rmtree(a / 'Contents/Resources'))
    for name in ['app.icns', 'Assets.car', 'scripting.sdef', 'en.lproj/InfoPlist.strings']:
        refused('no-' + name.replace('/', '-'), f'an app without {name}', f'Missing outer resource: {name}',
                lambda a, e, p, n=name: (a / 'Contents/Resources' / n).unlink())

    refused('no-versioned-binary', 'a framework without the file main loads', 'Missing versioned engine executable',
            lambda a, e, p: (versioned(e) / 'Bark Framework').unlink())
    def other_current(a, e, p):
        (e / FRAMEWORK / 'Versions/9.9.9.9').mkdir()
        (e / FRAMEWORK / 'Versions/Current').unlink()
        (e / FRAMEWORK / 'Versions/Current').symlink_to('9.9.9.9')
    refused('other-current', 'Versions/Current pointing at another version', f'Versions/Current must point to {VERSION}', other_current)
    refused('other-framework-version', 'a framework whose version differs from the app\'s', 'CFBundleShortVersionString',
            lambda a, e, p: edit_plist(versioned(e) / 'Resources/Info.plist', CFBundleShortVersionString='1.2.3.4'))

    refused('plist-lost-key', 'an app plist missing a key the engine has', 'differs from the engine: LSEnvironment',
            lambda a, e, p: edit_plist(a / 'Contents/Info.plist', LSEnvironment=None))
    refused('plist-new-engine-key', 'a new key only the engine has', 'differs from the engine: NewUpstreamKey',
            lambda a, e, p: edit_plist(e / 'engine-Info.plist', NewUpstreamKey='value'))
    refused('plist-extra-app-key', 'a key only the app has', 'differs from the engine: AppOnlyKey',
            lambda a, e, p: edit_plist(a / 'Contents/Info.plist', AppOnlyKey='value'))
    refused('plist-changed-value', 'a value that differs', 'differs from the engine: CFBundleURLTypes',
            lambda a, e, p: edit_plist(a / 'Contents/Info.plist', CFBundleURLTypes=[]))

    fat_main = work / 'fat-main-binary'
    assert compile_shim(fat_main, extra=('-arch', 'x86_64', '-arch', 'arm64'))
    refused('fat-main', 'a main that is not exactly x86_64', 'must be exactly x86_64',
            lambda a, e, p: shutil.copy2(fat_main, a / 'Contents/MacOS/Bark'))
    fat_shell = work / 'fat-shell.dylib'
    fake_shell(fat_shell, arch=('-arch', 'x86_64', '-arch', 'arm64'))
    refused('fat-shell', 'a shell that is not exactly x86_64', 'must be exactly x86_64',
            lambda a, e, p: shutil.copy2(fat_shell, p / 'NookNativeShell.framework/Versions/A/NookNativeShell'))
    fat_framework = work / 'fat-framework.dylib'
    fake_framework(fat_framework, arch=('-arch', 'x86_64', '-arch', 'arm64'))
    refused('fat-framework', 'an engine that is not exactly x86_64', 'must be exactly x86_64',
            lambda a, e, p: shutil.copy2(fat_framework, versioned(e) / 'Bark Framework'))

    other_zone = work / 'other-zone.dylib'
    fake_framework(other_zone, zone='DelegatingDefaultZoneForSomethingElse')
    refused('other-zone', 'a framework with another malloc zone name', 'same malloc zone name',
            lambda a, e, p: shutil.copy2(other_zone, versioned(e) / 'Bark Framework'))

    refused('signed-app', 'an app that already has a signature', 'already has a code signature',
            lambda a, e, p: (a / 'Contents/_CodeSignature').mkdir())

    no_entry = work / 'stage-no-entry.dylib'
    fake_framework(no_entry, entry=None)
    refused('engine-no-entry', 'an engine that does not export main\'s entry', f'does not export {ENTRY}',
            lambda a, e, p: shutil.copy2(no_entry, versioned(e) / 'Bark Framework'))
    main_no_entry = work / 'main-no-entry-binary'
    compile_c(MAIN_WITHOUT_ENTRY, main_no_entry)
    refused('main-no-entry', 'a main that names no versioned entry', 'must name exactly one versioned engine entry',
            lambda a, e, p: shutil.copy2(main_no_entry, a / 'Contents/MacOS/Bark'))
    other_entry_shell = work / 'other-entry-shell.dylib'
    compile_c(FAKE_SHELL, other_entry_shell, '-dynamiclib', '-arch', 'x86_64', '-DENTRY_NAME="barc_engine_main_v5"')
    refused('shell-other-entry', 'a shell built for another bridge version', 'does not export barc_engine_main_v5',
            lambda a, e, p: shutil.copy2(other_entry_shell, p / 'NookNativeShell.framework/Versions/A/NookNativeShell'))
    no_entry_shell = work / 'no-entry-shell.dylib'
    compile_c(FAKE_SHELL_NO_ENTRY, no_entry_shell, '-dynamiclib', '-arch', 'x86_64')
    refused('shell-no-entry', 'a shell that names no versioned entry', 'must name exactly one versioned engine entry',
            lambda a, e, p: shutil.copy2(no_entry_shell, p / 'NookNativeShell.framework/Versions/A/NookNativeShell'))
    two_entries_shell = work / 'two-entries-shell.dylib'
    compile_c(FAKE_SHELL + '__attribute__((used)) static const char other[] = "barc_engine_main_v5";\n', two_entries_shell, '-dynamiclib', '-arch', 'x86_64', f'-DENTRY_NAME="{ENTRY}"')
    refused('shell-two-entries', 'a shell naming two entries', 'must name exactly one versioned engine entry',
            lambda a, e, p: shutil.copy2(two_entries_shell, p / 'NookNativeShell.framework/Versions/A/NookNativeShell'))


def main():
    with tempfile.TemporaryDirectory(prefix='nook-app-shim-') as directory:
        work = Path(directory).resolve()
        shim = work / 'shim'
        framework_lib = work / 'framework.dylib'
        shell_lib = work / 'shell.dylib'
        no_entry_lib = work / 'shell-no-entry.dylib'
        quiet_lib = work / 'quiet-abort.dylib'
        global FAKE_SISO
        FAKE_SISO = work / 'fake-siso-bin'
        FAKE_SISO.mkdir()
        (FAKE_SISO / 'siso').write_text('#!/bin/bash\nexec /bin/cat "$FAKE_SISO_STATE"\n')
        (FAKE_SISO / 'siso').chmod(0o755)
        fake_framework(framework_lib)
        fake_shell(shell_lib)
        compile_c(FAKE_SHELL_NO_ENTRY, no_entry_lib, '-dynamiclib')
        compile_c(QUIET_ABORT, quiet_lib, '-dynamiclib', f'-DABORT_STATUS={ABORT_STATUS}')
        header_cases(work)
        startup_version_cases(work)
        package_cases(work)
        if not compile_shim(shim):
            check('main compiles from ChromiumApp', False, 'no usable sources')
        else:
            launch_cases(work, shim, framework_lib, shell_lib, no_entry_lib, quiet_lib)
            publish_cases(work, framework_lib)
            stage_cases(work, shim, framework_lib, shell_lib)
        make_writable(work)
    print(f'{len(failures)} failed')
    sys.exit(1 if failures else 0)


main()
