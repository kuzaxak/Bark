#!/usr/bin/env python3
"""Replays the recipe into a throwaway index and compares the checkout with it.

replay_gate.py SRC [EVIDENCE_DIR]

The recipe is pristine Chromium at CHROMIUM_VERSION, plus bark/ and chromium_src/ mounted at src/bark and
src/chromium_src, plus every patch in patches/. The checkout passes when it holds exactly that, apart from the Rust matcher the recipe builds.
The budget check runs first.
"""
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
PINS = json.loads((HERE / 'PINS.json').read_text())
MOUNTS = {'bark': HERE / 'bark', 'chromium_src': HERE / 'chromium_src'}
PATCHES = HERE / 'patches'
LEFTOVERS = {'bark/browser/content_blocking/nook_adblock/libnook_adblock.dylib',
             'bark/browser/content_blocking/nook_adblock/libnook_adblock.a'}


def check_pin(src):
    head = subprocess.check_output(['git', '-C', str(src), 'rev-parse', 'HEAD'], text=True).strip()
    if head != PINS['chromium']:
        raise ValueError(f'Chromium HEAD is {head}, recipe pins {PINS["chromium"]}')
    version = dict(line.split('=') for line in (src / 'chrome/VERSION').read_text().split())
    built = '{MAJOR}.{MINOR}.{BUILD}.{PATCH}'.format(**version)
    pinned = (HERE / 'CHROMIUM_VERSION').read_text().strip()
    if built != pinned:
        raise ValueError(f'checkout is Chromium {built}, the recipe pins {pinned}')


def main():
    src = Path(sys.argv[1]).resolve()
    evidence = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else None
    if subprocess.run([sys.executable, str(HERE / 'budget.py'), '--check']).returncode:
        sys.exit('replay gate: budget check failed')
    try:
        check_pin(src)
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'replay gate: {error}')
    objects = subprocess.check_output(
        ['git', '-C', str(src), 'rev-parse', '--path-format=absolute', '--git-path', 'objects'],
        text=True,
    ).strip()
    with tempfile.TemporaryDirectory(prefix='bark-replay-') as scratch:
        env = {**os.environ, 'GIT_INDEX_FILE': f'{scratch}/index', 'GIT_OBJECT_DIRECTORY': f'{scratch}/objects',
               'GIT_ALTERNATE_OBJECT_DIRECTORIES': objects, 'GIT_OPTIONAL_LOCKS': '0'}
        os.mkdir(f'{scratch}/objects')

        def git(*args, **kwargs):
            command = ['git', '-C', str(src), *args]
            result = subprocess.run(command, env=env, capture_output=True, text=True, **kwargs)
            if result.returncode:
                sys.exit(f'replay gate: git {args[0]} failed in {src}: {result.stderr.strip()}')
            return result.stdout

        git('read-tree', 'HEAD')
        files = sorted((mount, p) for mount, root in MOUNTS.items() for p in root.rglob('*') if p.is_file())
        blobs = git('hash-object', '-w', '--stdin-paths', input='\n'.join(str(p) for _, p in files) + '\n').split()
        entries = ''.join(f'{"100755" if os.access(p, os.X_OK) else "100644"} {blob}\t'
                          f'{mount}/{p.relative_to(MOUNTS[mount]).as_posix()}\n' for (mount, p), blob in zip(files, blobs))
        git('update-index', '--add', '--index-info', input=entries)
        patches = sorted(PATCHES.rglob('*.patch'))
        git('apply', '--cached', *patches)
        differences = git('diff', '--name-status', '--no-color').splitlines()
        untracked = [p for p in git('ls-files', '--others', '--exclude-standard').splitlines() if p not in LEFTOVERS]
    report = [f'patches: {len(patches)}', f'mounted files: {len(files)}'] + differences + [f'?\t{p}' for p in untracked]
    if evidence:
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / 'replay-gate.txt').write_text('\n'.join(report) + '\n')
    print('\n'.join(report))
    if differences or untracked:
        sys.exit('replay gate: the checkout differs from the recipe')
    print('replay gate: the checkout is the recipe')


if __name__ == '__main__':
    main()
