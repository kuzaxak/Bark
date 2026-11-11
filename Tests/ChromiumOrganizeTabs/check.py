from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / 'build/organize-tabs-check'
out.mkdir(parents=True, exist_ok=True)
shell = (root / 'App/Chromium/ChromiumSidebarShell.swift').read_text()
a = shell.index('private struct OrganizeTabsRequests')
requests = shell[a:shell.index('\n}\n', a) + 3].replace('private struct ', 'struct ', 1)
(out / 'OrganizeTabsRequests.swift').write_text('import SwiftUI\n\n' + requests)
binary = out / 'chromium-organize-tabs-check'
c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library',
     str(out / 'OrganizeTabsRequests.swift'), str(root / 'Tests/ChromiumOrganizeTabs/Main.swift'), '-o', str(binary)]
p = subprocess.run(c, capture_output=True, text=True)
print(p.stdout + p.stderr)
if p.returncode:
    raise SystemExit(p.returncode)
p = subprocess.run([str(binary)], capture_output=True, text=True)
print(p.stdout + p.stderr)
raise SystemExit(p.returncode)
