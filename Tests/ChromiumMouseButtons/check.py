from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[2]
out = root / 'build/mouse-buttons-check'
out.mkdir(parents=True, exist_ok=True)
source = (root / 'App/Chromium/ChromiumMouseButtons.swift').read_text()
a = source.index('/// What an extra mouse button does')
(out / 'Shipped.swift').write_text('import AppKit\n\n' + source[a:source.index('// MARK: - Monitor')])
binary = out / 'chromium-mouse-buttons-check'
c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library',
     str(out / 'Shipped.swift'), str(root / 'Tests/ChromiumMouseButtons/Main.swift'), '-o', str(binary)]
p = subprocess.run(c, capture_output=True, text=True)
print(p.stdout + p.stderr)
if p.returncode:
    raise SystemExit(p.returncode)
p = subprocess.run([str(binary)], capture_output=True, text=True)
print(p.stdout + p.stderr)
raise SystemExit(p.returncode)
