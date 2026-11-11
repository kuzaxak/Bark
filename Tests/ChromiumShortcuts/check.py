from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / 'build/shortcuts-check'
out.mkdir(parents=True, exist_ok=True)
commands = (root / 'App/Chromium/ChromiumPageCommands.swift').read_text()
(out / 'ChromiumPageCommands.swift').write_text(commands[:commands.index('extension ChromiumPageNavigation')])
binary = out / 'chromium-shortcuts-check'
c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library',
     '-I', str(root / 'Packages/BarkEngine/BarkEngine.xcframework/macos-x86_64/Headers'),
     str(root / 'Nook/Models/KeyboardShortcut/KeyboardShortcut.swift'), str(root / 'Nook/Managers/BrowserManager/FrontPage.swift'),
     str(out / 'ChromiumPageCommands.swift'), str(root / 'Tests/ChromiumShortcuts/Main.swift'), '-o', str(binary)]
p = subprocess.run(c, capture_output=True, text=True)
print(p.stdout + p.stderr)
if p.returncode:
    raise SystemExit(p.returncode)
p = subprocess.run([str(binary)], capture_output=True, text=True)
print(p.stdout + p.stderr)
raise SystemExit(p.returncode)
