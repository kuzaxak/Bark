from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[2]
out = root / 'build/address-fill-check'
out.mkdir(parents=True, exist_ok=True)
source = (root / 'Nook/Components/Sidebar/URLBarView.swift').read_text()
a = source.index('    static func fieldFillOpacity(')
b = source.index('    static func fieldFill(', a)
(out / 'Shipped.swift').write_text('import Foundation\n\nenum URLBarView {\n' + source[a:b] + '}\n')
binary = out / 'chromium-address-fill-check'
c = ['swiftc', '-swift-version', '5', '-parse-as-library', str(out / 'Shipped.swift'), str(root / 'Tests/ChromiumAddressFill/Main.swift'), '-o', str(binary)]
p = subprocess.run(c, capture_output=True, text=True)
print(p.stdout + p.stderr)
if p.returncode:
    raise SystemExit(p.returncode)
p = subprocess.run([str(binary)], capture_output=True, text=True)
print(p.stdout + p.stderr)
raise SystemExit(p.returncode)
