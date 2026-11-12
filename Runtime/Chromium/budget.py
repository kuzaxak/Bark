#!/usr/bin/env python3
"""Counts what the recipe changes in upstream Chromium, from patches/ and chromium_src/.

budget.py            prints the counts as JSON.
budget.py --check    also fails when a count exceeds BUDGET.json or a patch breaks the layout rules:
                     one patch per upstream file, named after its path, creating or deleting nothing.
"""
import json
import re
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
PATCHES = HERE / 'patches'
OVERRIDES = HERE / 'chromium_src'
BUDGET = HERE / 'BUDGET.json'
AREAS = {'ui_views_files': 'ui/views/', 'content_files': 'content/', 'android_webview_files': 'android_webview/',
         'tools_metrics_files': 'tools/metrics/'}
TEST_NAME = re.compile(r'(^|_)(unit|browser|interactive_ui|ui|api)?tests?(_|$)')


def is_upstream_test(path):
    parts = path.split('/')
    return any(part in ('test', 'tests') for part in parts[:-1]) or bool(TEST_NAME.search(parts[-1].split('.')[0]))


def read_patches():
    problems, rows = [], []
    for patch in sorted(PATCHES.rglob('*')):
        if patch.is_dir():
            continue
        name = patch.relative_to(PATCHES).as_posix()
        if not name.endswith('.patch'):
            problems.append(f'{name}: not a .patch file')
            continue
        text = patch.read_text()
        targets = re.findall(r'^\+\+\+ (\S+)', text, re.M)
        sources = re.findall(r'^--- (\S+)', text, re.M)
        expected = 'b/' + name[:-len('.patch')]
        if targets != [expected] or sources != ['a/' + expected[2:]]:
            problems.append(f'{name}: must change exactly {expected[2:]}, changes {targets}')
        if name.startswith('bark/'):
            problems.append(f'{name}: Bark files live in bark/, never in a patch')
        if re.search(r'^(new|deleted) file mode|^rename (from|to) |^Binary files', text, re.M):
            problems.append(f'{name}: creates, deletes, renames or binary-patches a file')
        lines = text.split('\n')
        hunks = sum(1 for line in lines if line.startswith('@@ '))
        added = sum(1 for line in lines if line.startswith('+') and not line.startswith('+++ '))
        rows.append((expected[2:], hunks, added))
    return rows, problems


def counts():
    rows, problems = read_patches()
    paths = [path for path, _, _ in rows]
    result = {
        'patch_files': len(rows),
        'upstream_files': len(set(paths)),
        'hunks': sum(hunks for _, hunks, _ in rows),
        'lines_added': sum(added for _, _, added in rows),
        'override_files': sum(1 for p in OVERRIDES.rglob('*') if p.is_file() and p != OVERRIDES / 'README.md'),
    }
    for key, prefix in AREAS.items():
        result[key] = sum(1 for path in paths if path.startswith(prefix))
    result['upstream_test_files'] = sum(1 for path in paths if is_upstream_test(path))
    return result, problems


def main():
    result, problems = counts()
    print(json.dumps(result, indent=2))
    if '--check' not in sys.argv:
        return 0
    limits = json.loads(BUDGET.read_text())['limits']
    if set(limits) != set(result):
        problems.append(f'BUDGET.json limits {sorted(limits)} must name exactly {sorted(result)}')
    for key, value in result.items():
        if key in limits and value > limits[key]:
            problems.append(f'{key} is {value}, over the budget of {limits[key]}')
    for problem in problems:
        print('BUDGET FAIL ' + problem, file=sys.stderr)
    if not problems:
        print('budget ok')
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main())
