from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='bark-front-page-commands-') as directory:
    out = Path(directory)
    source = (root / 'Nook/Managers/BrowserManager/BrowserManager+ActivePage.swift').read_text()
    start = source.index('    /// Product page commands never fall through')
    end = source.index('    /// Copy the requested document only while', start)
    # Compile the shipped command gate; the pages, hosts and window model are fakes.
    (out / 'Commands.swift').write_text('import Foundation\nextension BrowserManager {\n' + source[start:end] + '}\n')
    commands = (root / 'App/Chromium/ChromiumPageCommands.swift').read_text()
    (out / 'ChromiumPageCommands.swift').write_text(commands[:commands.index('extension ChromiumPageNavigation')])
    binary = out / 'check'
    compile = ['swiftc', '-swift-version', '5', '-target', platform.machine() + '-apple-macosx15.5', '-parse-as-library',
               '-I', str(root / 'Packages/BarkEngine/BarkEngine.xcframework/macos-arm64_x86_64/Headers'),
               str(root / 'Nook/Models/KeyboardShortcut/KeyboardShortcut.swift'),
               str(root / 'Nook/Managers/BrowserManager/FrontPage.swift'),
               str(out / 'ChromiumPageCommands.swift'), str(out / 'Commands.swift'),
               str(root / 'Tests/ChromiumFrontPageCommands/Main.swift'), '-o', str(binary)]
    for args in (compile, [str(binary)]):
        result = subprocess.run(args, cwd=root, capture_output=True, text=True)
        print(result.stdout + result.stderr, end='')
        if result.returncode:
            raise SystemExit(result.returncode)
