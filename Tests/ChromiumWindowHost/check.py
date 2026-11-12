from pathlib import Path
import subprocess

root = Path(__file__).resolve().parents[2]
out = root / 'build/window-host-check'
out.mkdir(parents=True, exist_ok=True)
binary = out / 'chromium-window-host-check'
c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library',
     '-I', str(root / 'Packages/BarkEngine/BarkEngine.xcframework/macos-x86_64/Headers'),
     str(root / 'App/Chromium/ChromiumWindowRoot.swift'), str(root / 'Tests/Shared/BridgeTable.swift'),
     str(root / 'Tests/ChromiumWindowHost/Main.swift'), '-framework', 'AppKit', '-o', str(binary)]
p = subprocess.run(c, capture_output=True, text=True)
print(p.stdout + p.stderr)
if p.returncode:
    raise SystemExit(p.returncode)
p = subprocess.run([str(binary)], capture_output=True, text=True)
print(p.stdout + p.stderr)
raise SystemExit(p.returncode)
