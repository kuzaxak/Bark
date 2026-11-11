from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[2]
out = root / 'build/onboarding-check'
out.mkdir(parents=True, exist_ok=True)
source = (root / 'App/Chromium/ChromiumOnboarding.swift').read_text()
a = source.index('/// Develop')
(out / 'Shipped.swift').write_text('import Foundation\n\n' + source[a:source.index('    // MARK: - Window')] + '}\n')
binary = out / 'chromium-onboarding-check'
c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library',
     str(out / 'Shipped.swift'), str(root / 'Tests/ChromiumOnboarding/Main.swift'), '-o', str(binary)]
p = subprocess.run(c, capture_output=True, text=True)
print(p.stdout + p.stderr)
if p.returncode:
    raise SystemExit(p.returncode)
p = subprocess.run([str(binary), str(out / 'data')], capture_output=True, text=True)
print(p.stdout + p.stderr)
raise SystemExit(p.returncode)
