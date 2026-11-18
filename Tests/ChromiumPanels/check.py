from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
import platform

root = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='bark-chromium-panel-check-') as directory:
    out = Path(directory)
    # Compile the shipped host against real AppKit/SwiftUI; no browser or real profiles.
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    command = ['xcrun', 'swiftc', '-sdk', sdk,
        '-target', platform.machine() + '-apple-macosx15.5', '-swift-version', '5', '-parse-as-library',
        str(root / 'App/Chromium/ChromiumPagePanel.swift'), str(root / 'Tests/ChromiumPanels/Main.swift'), '-o', str(out / 'check')]
    for label, args in [('compile', command), ('run', [str(out / 'check')])]:
        result = subprocess.run(args, cwd=root, capture_output=True, text=True)
        (out / (label + '.log')).write_text(result.stdout + result.stderr)
        print(result.stdout + result.stderr, end='')
        if result.returncode:
            raise SystemExit(result.returncode)
