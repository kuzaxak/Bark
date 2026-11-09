from pathlib import Path
import subprocess
import platform

root = Path(__file__).resolve().parents[2]
out = root / 'build/chromium-panel-check'
out.mkdir(parents=True, exist_ok=True)
source = (root / 'App/Chromium/ChromiumSidebarShell.swift').read_text()
start = source.index('private struct ChromiumPagePanel<')
# Compile the shipped host against real AppKit/SwiftUI; no browser or real profiles.
(out / 'Panel.swift').write_text('import AppKit\nimport SwiftUI\n' +
    source[start:].replace('private struct ChromiumPagePanel<', 'struct ChromiumPagePanel<', 1))
sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
command = ['xcrun', 'swiftc', '-sdk', sdk,
    '-target', platform.machine() + '-apple-macosx15.5', '-swift-version', '5', '-parse-as-library',
    str(out / 'Panel.swift'), str(root / 'Tests/ChromiumPanels/Main.swift'), '-o', str(out / 'check')]
for label, args in [('compile', command), ('run', [str(out / 'check')])]:
    result = subprocess.run(args, cwd=root, capture_output=True, text=True)
    (out / (label + '.log')).write_text(result.stdout + result.stderr)
    print(result.stdout + result.stderr, end='')
    if result.returncode:
        raise SystemExit(result.returncode)
