from pathlib import Path
import platform
from tempfile import TemporaryDirectory
import subprocess
import sys

root = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "Tests/Shared"))
from bridge_fixture import write_bridge_fixture

headers = root / "Packages/BarkEngine/BarkEngine.xcframework/macos-arm64_x86_64/Headers"

with TemporaryDirectory(prefix='bark-window-host-check-') as directory:
    out = Path(directory)
    binary = out / 'chromium-window-host-check'
    table = write_bridge_fixture(headers / 'BarcChromium/barc_bridge_api.h', out / 'BridgeTable.swift')
    c = ['swiftc', '-swift-version', '5', '-target', f'{platform.machine()}-apple-macosx15.5', '-parse-as-library',
         '-I', str(headers),
         str(root / 'App/Chromium/ChromiumWindowRoot.swift'), str(root / 'App/Chromium/ChromiumWindowHostLink.swift'), str(root / 'App/Chromium/ChromiumCompactRoot.swift'), str(root / 'App/Window/WindowFrameInteraction.swift'),
         str(root / 'App/Chromium/ChromiumPagePanel.swift'), str(root / 'Nook/Components/Sidebar/Menu/LibrarySwipeDecision.swift'),
         str(root / 'Nook/Components/Browser/Window/SplitDrop.swift'), str(root / 'Nook/Components/WebsiteView/SplitDividerView.swift'),
         str(table),
         str(root / 'Tests/ChromiumWindowHost/Main.swift'), '-framework', 'AppKit', '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    print(p.stdout + p.stderr)
    if p.returncode:
        raise SystemExit(p.returncode)
    p = subprocess.run([str(binary)], capture_output=True, text=True)
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
