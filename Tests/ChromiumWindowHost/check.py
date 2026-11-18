from pathlib import Path
from tempfile import TemporaryDirectory
import subprocess

root = Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='bark-window-host-check-') as directory:
    out = Path(directory)
    binary = out / 'chromium-window-host-check'
    c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library',
         '-I', str(root / 'Packages/BarkEngine/BarkEngine.xcframework/macos-x86_64/Headers'),
         str(root / 'App/Chromium/ChromiumWindowRoot.swift'), str(root / 'App/Chromium/ChromiumWindowHostLink.swift'), str(root / 'App/Chromium/ChromiumCompactRoot.swift'), str(root / 'App/Window/WindowFrameInteraction.swift'),
         str(root / 'App/Chromium/ChromiumPagePanel.swift'), str(root / 'Nook/Components/Sidebar/Menu/LibrarySwipeDecision.swift'),
         str(root / 'Nook/Components/Browser/Window/SplitDrop.swift'), str(root / 'Nook/Components/WebsiteView/SplitDividerView.swift'),
         str(root / 'Tests/Shared/BridgeTable.swift'),
         str(root / 'Tests/ChromiumWindowHost/Main.swift'), '-framework', 'AppKit', '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
