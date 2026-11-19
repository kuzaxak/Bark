from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='bark-shortcuts-') as directory:
    out = Path(directory)
    commands = (root / 'App/Chromium/ChromiumPageCommands.swift').read_text()
    (out / 'ChromiumPageCommands.swift').write_text(commands[:commands.index('extension ChromiumPageNavigation')])
    manager = (root / 'Nook/Managers/BrowserManager/BrowserManager.swift').read_text()
    start = manager.index('    func manageExtensions(')
    end = manager.index('    /// Set the active window state', start)
    extension_action = manager[start:end].replace('CommandWindow.key', 'keyWindow')
    shortcuts = (root / 'Nook/Managers/KeyboardShortcutManager/KeyboardShortcutManager.swift').read_text()
    start = shortcuts.index('    private func executeAction(')
    end = shortcuts.index('        if action == .addSplitView', start)
    dispatch = shortcuts[start:end].replace('private func executeAction', 'func executeAction')
    (out / 'ExtensionShortcut.swift').write_text(
        'import AppKit\nextension ExtensionBrowserFixture {\n' + extension_action +
        '}\nextension ExtensionShortcutFixture {\n' + dispatch +
        '    preconditionFailure("Managed extension command reached generic dispatch")\n}\n}\n')
    binary = out / 'chromium-shortcuts-check'
    c = ['swiftc', '-swift-version', '5', '-target', platform.machine() + '-apple-macosx15.5', '-parse-as-library',
         '-I', str(root / 'Packages/BarkEngine/BarkEngine.xcframework/macos-arm64_x86_64/Headers'),
         str(root / 'Nook/Models/KeyboardShortcut/KeyboardShortcut.swift'), str(root / 'Nook/Managers/BrowserManager/FrontPage.swift'),
         str(root / 'Nook/Managers/KeyboardShortcutManager/CommandWindow.swift'),
         str(out / 'ChromiumPageCommands.swift'), str(out / 'ExtensionShortcut.swift'),
         str(root / 'Tests/ChromiumShortcuts/Main.swift'), '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
