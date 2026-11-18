from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess

root = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='bark-chromium-clipboard-check-') as directory:
    out = Path(directory)
    source = (root / 'Nook/Managers/BrowserManager/BrowserManager+ActivePage.swift').read_text()
    start = source.index('    func captureNativeScreenshot(')
    end = source.index('    private func clearCookies(', start)
    # Compile the shipped asynchronous operation; only AppKit and page owners are fakes.
    (out / 'Operation.swift').write_text('import Foundation\nextension BrowserManager {\n' + source[start:end] + '}\n')
    portrait = (root / 'Nook/Components/DevTools/PortraitCaptureView.swift').read_text()
    start = portrait.index('    @MainActor\n    static func copyImage(')
    end = portrait.index('    static func canvasSize(', start)
    with (out / 'Operation.swift').open('a') as file:
        file.write('\nenum PortraitComposition {\n' + portrait[start:end] + '\n}\n')
    command = ['swiftc', '-swift-version', '5', '-parse-as-library', str(out / 'Operation.swift'),
               str(root / 'Tests/ChromiumClipboard/Main.swift'), '-o', str(out / 'check')]
    for label, args in [('compile', command), ('run', [str(out / 'check')])]:
        result = subprocess.run(args, cwd=root, capture_output=True, text=True)
        (out / (label + '.log')).write_text(result.stdout + result.stderr)
        print(result.stdout + result.stderr, end='')
        if result.returncode:
            raise SystemExit(result.returncode)
