from pathlib import Path
import platform
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / 'build/fitted-rows-scroll-check'
out.mkdir(parents=True, exist_ok=True)
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
command = ['xcrun', 'swiftc', '-sdk', sdk,
    '-target', platform.machine() + '-apple-macosx15.5', '-swift-version', '5', '-parse-as-library',
    str(root / 'UI/FittedRowsScroll.swift'), str(root / 'Tests/FittedRowsScroll/Main.swift'), '-o', str(out / 'check')]
for label, args in [('compile', command), ('run', [str(out / 'check')])]:
    result = subprocess.run(args, cwd=root, capture_output=True, text=True)
    (out / (label + '.log')).write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end='')
    if result.returncode:
        raise SystemExit(result.returncode)
