#!/usr/bin/env python3
"""Replays the recipe into a throwaway index and compares the checkout with it.

replay_gate.py SRC [EVIDENCE_DIR]
replay_gate.py SRC --check-patches-at REVISION

The recipe is pristine Chromium at CHROMIUM_VERSION, plus bark/ and chromium_src/ mounted at src/bark and
src/chromium_src, plus every patch in patches/. The checkout passes when it holds exactly that, apart from the Rust matcher the recipe builds.
The budget check runs first.
"""
import argparse
from contextlib import contextmanager
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


@contextmanager
def temporary_index(src, revision='HEAD'):
    objects = subprocess.check_output(
        ['git', '-C', str(src), 'rev-parse', '--path-format=absolute', '--git-path', 'objects'],
        text=True,
    ).strip()
    with tempfile.TemporaryDirectory(prefix='bark-replay-') as scratch:
        env = {**os.environ, 'GIT_INDEX_FILE': f'{scratch}/index', 'GIT_OBJECT_DIRECTORY': f'{scratch}/objects',
               'GIT_ALTERNATE_OBJECT_DIRECTORIES': objects, 'GIT_OPTIONAL_LOCKS': '0'}
        os.mkdir(f'{scratch}/objects')

        def git(*args, binary=False, **kwargs):
            command = ['git', '-C', str(src), *args]
            result = subprocess.run(command, env=env, capture_output=True, text=not binary, **kwargs)
            if result.returncode:
                sys.exit(f'replay gate: git {args[0]} failed in {src}: {result.stderr.strip()}')
            return result.stdout

        git('read-tree', revision)
        yield git


def load_recipe(git, recipe):
    files = []
    for mount in MOUNTS:
        root = recipe / mount
        if not root.is_dir():
            raise ValueError(f'{root}: missing recipe mount')
        for path in sorted(root.rglob('*')):
            if path.is_symlink() and not path.is_file():
                raise ValueError(f'{path}: missing mounted file')
            if path.is_file():
                files.append((path.relative_to(recipe).as_posix(), path))
    if files:
        blobs = git('hash-object', '-w', '--', *(path for _, path in files)).split()
        entries = ''.join(f'{"100755" if os.access(path, os.X_OK) else "100644"} {blob}\t{name}\0'
                          for (name, path), blob in zip(files, blobs))
        git('update-index', '--add', '-z', '--index-info', input=entries)
    patches = sorted((recipe / 'patches').rglob('*.patch'))
    if patches:
        git('apply', '--cached', *patches)
    return len(patches), len(files)


def differences(git):
    fields = git('diff', '--no-ext-diff', '--no-renames', '--name-status', '-z').split('\0')[:-1]
    result = {name: status for status, name in zip(fields[::2], fields[1::2])}
    for name in git('ls-files', '--others', '--exclude-standard', '-z').split('\0'):
        if name and name not in LEFTOVERS:
            result[name] = '?'
    return result


def check_patches_at(src, revision, recipe):
    commit = subprocess.check_output(
        ['git', '-C', str(src), 'rev-parse', '--verify', '--end-of-options', revision + '^{commit}'],
        text=True,
    ).strip()
    with temporary_index(src, commit) as git:
        patches, mounts = load_recipe(git, recipe)
    print(f'{commit}: {patches} patches applied with {mounts} mounted files in a temporary index')


def main():
    parser = argparse.ArgumentParser(description='Replay the Bark Chromium recipe')
    parser.add_argument('src', type=Path, help='Chromium Git checkout')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('evidence_dir', type=Path, nargs='?', help='save the working-tree comparison')
    mode.add_argument('--check-patches-at', metavar='REVISION', help='try the recipe on a locally available commit')
    args = parser.parse_args()
    src = args.src.resolve()
    evidence = args.evidence_dir
    if subprocess.run([sys.executable, str(HERE / 'budget.py'), '--check']).returncode:
        sys.exit('replay gate: budget check failed')
    if args.check_patches_at:
        check_patches_at(src, args.check_patches_at, HERE)
        return
    check_pin(src)
    with temporary_index(src) as git:
        patch_count, file_count = load_recipe(git, HERE)
        changes = differences(git)
    report = [f'patches: {patch_count}', f'mounted files: {file_count}']
    report.extend(f'{status}\t{name}' for name, status in sorted(changes.items()))
    if evidence:
        evidence.mkdir(parents=True, exist_ok=True)
        (evidence / 'replay-gate.txt').write_text('\n'.join(report) + '\n')
    print('\n'.join(report))
    if changes:
        sys.exit('replay gate: the checkout differs from the recipe')
    print('replay gate: the checkout is the recipe')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(f'replay gate: {error}')
