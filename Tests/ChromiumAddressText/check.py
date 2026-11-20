from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess
root = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='bark-address-text-check-') as directory:
    out = Path(directory)
    source = (root / 'Nook/Components/Sidebar/URLBarView.swift').read_text()
    a = source.index('    static func shownPath(')
    b = source.index('\n    }\n', a) + 7
    (out / 'Shipped.swift').write_text('import Foundation\n\nenum URLBarView {\n' + source[a:b] + '}\n')
    binary = out / 'chromium-address-text-check'
    c = ['swiftc', '-swift-version', '5', '-parse-as-library', str(out / 'Shipped.swift'), str(root / 'App/Chromium/ChromiumAddressTextField.swift'), str(root / 'Tests/ChromiumAddressText/Main.swift'), '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
