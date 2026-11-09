#!/usr/bin/env python3
"""Runs the outer app's main and the staging script against fake engine products."""
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SHIM = ROOT / 'ChromiumApp'
STAGE = ROOT / 'scripts/stage-chromium-app.sh'
VERSION = '156.0.8078.80'
FRAMEWORK = 'Bark Framework.framework'
BUNDLE_ID = 'ee.qdo.bark'
DELEGATING_ZONE = 'DelegatingDefaultZoneForPartitionAlloc'
ABORT_STATUS = 134

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
'''
FAKE_SHELL = COMMON + r'''
#include <dlfcn.h>
__attribute__((constructor)) static void loaded(void) { record("shell"); }
int barc_native_main(void* library, int argc, const char** argv) {
  char line[256];
  snprintf(line, sizeof line, "native-main argc=%d last=%s", argc, argv[argc - 1]);
  record(line);
  int (*chrome_main)(int, const char**) = dlsym(library, "ChromeMain");
  return chrome_main ? chrome_main(argc, argv) : 99;
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

failures = []


def check(name, ok, detail=''):
    print(('PASS ' if ok else 'FAIL ') + name + ('' if ok else f': {detail}'), flush=True)
    if not ok:
        failures.append(name)


def compile_c(source, output, *extra):
    source_file = output.with_suffix('.c')
    source_file.write_text(source)
    subprocess.run(['xcrun', 'clang', '-arch', 'x86_64', str(source_file), '-o', str(output), *extra], check=True)


def compile_shim(output, version=VERSION):
    sources = sorted(str(p) for p in SHIM.glob('*.cc'))
    if not sources:
        return False
    run = subprocess.run(['xcrun', 'clang++', '-arch', 'x86_64', '-std=c++20', '-fno-exceptions', '-fno-rtti',
                          '-nostdlib++', '-O2', f'-DENGINE_VERSION_STRING="{version}"', *sources, '-o', str(output)],
                         capture_output=True, text=True)
    if run.returncode:
        print(run.stderr)
    return run.returncode == 0


def versioned_framework(root, binary=None):
    framework = root / FRAMEWORK
    (framework / f'Versions/{VERSION}').mkdir(parents=True)
    (framework / 'Versions/Current').symlink_to(VERSION)
    (framework / 'Bark Framework').symlink_to('Versions/Current/Bark Framework')
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


def launch_cases(work, shim, framework_lib, shell_lib, no_entry_lib, quiet_lib):
    def launch(name, framework=True, shell=shell_lib):
        contents = work / name / 'Bark.app/Contents'
        (contents / 'MacOS').mkdir(parents=True)
        (contents / 'Frameworks').mkdir()
        shutil.copy2(shim, contents / 'MacOS/Bark')
        if framework:
            versioned_framework(contents / 'Frameworks', framework_lib)
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
    check('framework loads, then the shell, then the shell runs ChromeMain through the handle',
          lines[1:] == ['shell', 'native-main argc=3 last=last-argument', 'chrome-main'], lines)
    check('exit status is what the shell returned', run.returncode == 23, run.returncode)

    run, lines = launch('no-shell', shell=None)
    check('missing shell aborts before ChromeMain', run.returncode == ABORT_STATUS and 'chrome-main' not in lines, (run.returncode, lines))
    check('missing shell names the shell in its error', 'NookNativeShell' in run.stderr, run.stderr)

    run, lines = launch('no-framework', framework=False)
    check('missing framework aborts before the shell loads', run.returncode == ABORT_STATUS and lines == [], (run.returncode, lines))
    check('missing framework names it in its error', 'Bark Framework' in run.stderr, run.stderr)

    run, lines = launch('no-entry', shell=no_entry_lib)
    check('shell without its entry aborts before ChromeMain', run.returncode == ABORT_STATUS and 'chrome-main' not in lines, (run.returncode, lines))

    libraries = subprocess.check_output(['otool', '-L', str(shim)], text=True).splitlines()[1:]
    linked = [line.split()[0] for line in libraries]
    check('main links only libSystem', linked == ['/usr/lib/libSystem.B.dylib'], linked)


def write_plist(path, **values):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(plistlib.dumps(values))


def make_inputs(root, shim, framework_lib, shell_lib):
    root.mkdir()
    app = root / 'app/Bark.app/Contents'
    (app / 'MacOS').mkdir(parents=True)
    shutil.copy2(shim, app / 'MacOS/Bark')
    write_plist(app / 'Info.plist', CFBundleExecutable='Bark', CFBundleIdentifier=BUNDLE_ID,
                CFBundleName='Bark', NSPrincipalClass='BrowserCrApplication', OwnedBy='app')

    engine = root / 'engine/Bark.app/Contents'
    (engine / 'MacOS').mkdir(parents=True)
    (engine / 'MacOS/Bark').write_text('stock launcher that must not ship')
    write_plist(engine / 'Info.plist', CFBundleExecutable='Bark', CFBundleIdentifier=BUNDLE_ID,
                CFBundleShortVersionString=VERSION, OwnedBy='engine')
    (engine / 'Frameworks').mkdir()
    versioned_framework(engine / 'Frameworks', framework_lib)
    (engine / 'Resources/en.lproj').mkdir(parents=True)
    (engine / 'Resources/en.lproj/InfoPlist.strings').write_text('strings')
    (engine / 'Resources/app.icns').write_text('icon')

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
    return root / 'app/Bark.app', root / 'engine/Bark.app', products


def stage(app, engine, products, output):
    return subprocess.run(['bash', str(STAGE), str(app), str(engine), str(products), str(output)],
                          capture_output=True, text=True)


def stage_cases(work, shim, framework_lib, shell_lib):
    def inputs(name):
        return make_inputs(work / name, shim, framework_lib, shell_lib)

    app, engine, products = inputs('flip')
    output = work / 'flip/out/Bark.app'
    output.parent.mkdir()
    run = stage(app, engine, products, output)
    check('valid inputs stage', run.returncode == 0, run.stderr)
    contents = output / 'Contents'
    executable = contents / 'MacOS/Bark'
    check('outer executable is the app target\'s main',
          executable.is_file() and executable.read_bytes() == shim.read_bytes())
    check('Contents/MacOS holds nothing else', [p.name for p in (contents / 'MacOS').iterdir()] == ['Bark'] if executable.exists() else False)
    info = contents / 'Info.plist'
    check('outer Info.plist is the app target\'s', info.is_file() and plistlib.loads(info.read_bytes()).get('OwnedBy') == 'app')
    engine_framework = contents / 'Frameworks' / FRAMEWORK
    check('engine framework is inside, with its version symlinks',
          (engine_framework / 'Versions/Current').is_symlink() and (engine_framework / f'Versions/{VERSION}/Bark Framework').is_file())
    check('shell and package frameworks are inside',
          all((contents / 'Frameworks' / n).is_dir() for n in ['NookNativeShell.framework', 'Sparkle.framework', 'Packaged.framework']))
    check('engine outer resources and native bundles are inside',
          all((contents / 'Resources' / n).exists() for n in ['app.icns', 'en.lproj/InfoPlist.strings', 'NookWeb_NookWeb.bundle']))

    def refused(name, why, reason, mutate):
        app, engine, products = inputs(name)
        mutate(app, engine, products)
        out = work / name / 'out/Bark.app'
        out.parent.mkdir()
        run = stage(app, engine, products, out)
        check(f'refuses {why}', run.returncode != 0 and reason in run.stderr, (run.returncode, run.stderr))

    refused('no-engine-framework', 'an engine without its framework', 'Missing Bark framework',
            lambda a, e, p: shutil.rmtree(e / 'Contents/Frameworks' / FRAMEWORK))
    refused('stock-app', 'an app executable that does not load the shell', 'lacks the required native bootstrap',
            lambda a, e, p: shutil.copy2(framework_lib, a / 'Contents/MacOS/Bark'))

    def other_version(a, e, p):
        other = work / 'other-version-shim'
        assert compile_shim(other, version='1.2.3.4')
        shutil.copy2(other, a / 'Contents/MacOS/Bark')
    refused('other-version', 'a main built for another engine version', 'another engine version', other_version)

    def extra_library(a, e, p):
        library = work / 'linked-shim'
        sources = sorted(str(s) for s in SHIM.glob('*.cc'))
        subprocess.run(['xcrun', 'clang++', '-arch', 'x86_64', '-std=c++20', '-fno-exceptions', '-fno-rtti', '-framework', 'AppKit',
                        '-Wl,-needed_framework,AppKit', f'-DENGINE_VERSION_STRING="{VERSION}"', *sources, '-o', str(library)], check=True)
        shutil.copy2(library, a / 'Contents/MacOS/Bark')
    refused('extra-library', 'a main that links more than libSystem', 'must link only libSystem', extra_library)

    def other_identity(a, e, p):
        write_plist(a / 'Contents/Info.plist', CFBundleExecutable='Bark', CFBundleIdentifier='ee.qdo.other',
                    CFBundleName='Bark', NSPrincipalClass='BrowserCrApplication')
    refused('other-identity', 'an app whose bundle identifier is not the engine\'s', 'bundle identifiers differ', other_identity)

    def shipping_identity(a, e, p):
        for bundle in (a, e):
            info = bundle / 'Contents/Info.plist'
            write_plist(info, **{**plistlib.loads(info.read_bytes()), 'CFBundleIdentifier': 'ee.qdo.nook'})
    refused('shipping-identity', 'the shipping app\'s bundle identifier even when app and engine agree', 'must not carry', shipping_identity)

    refused('no-principal-class', 'an app that does not let Chromium own NSApplication', 'BrowserCrApplication',
            lambda a, e, p: write_plist(a / 'Contents/Info.plist', CFBundleExecutable='Bark', CFBundleIdentifier=BUNDLE_ID, CFBundleName='Bark'))
    refused('framework-collision', 'a product named like the engine framework', 'Framework collision',
            lambda a, e, p: (p / FRAMEWORK).mkdir())
    refused('resource-collision', 'an app resource named like an engine resource', 'Resource collision',
            lambda a, e, p: ((a / 'Contents/Resources').mkdir(), (a / 'Contents/Resources/app.icns').write_text('other')))


def main():
    with tempfile.TemporaryDirectory(prefix='nook-app-shim-') as directory:
        work = Path(directory).resolve()
        shim = work / 'shim'
        framework_lib = work / 'framework.dylib'
        shell_lib = work / 'shell.dylib'
        no_entry_lib = work / 'shell-no-entry.dylib'
        quiet_lib = work / 'quiet-abort.dylib'
        compile_c(FAKE_FRAMEWORK, framework_lib, '-dynamiclib')
        compile_c(FAKE_SHELL, shell_lib, '-dynamiclib')
        compile_c(FAKE_SHELL_NO_ENTRY, no_entry_lib, '-dynamiclib')
        compile_c(QUIET_ABORT, quiet_lib, '-dynamiclib', f'-DABORT_STATUS={ABORT_STATUS}')
        if not compile_shim(shim):
            check('main compiles from ChromiumApp', False, 'no usable sources')
        else:
            launch_cases(work, shim, framework_lib, shell_lib, no_entry_lib, quiet_lib)
            stage_cases(work, shim, framework_lib, shell_lib)
    print(f'{len(failures)} failed')
    sys.exit(1 if failures else 0)


main()
