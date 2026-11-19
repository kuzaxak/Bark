from pathlib import Path
import subprocess
from tempfile import TemporaryDirectory
root = Path(__file__).resolve().parents[2]
s = (root / 'Nook/Managers/DevMCPServer/DevMCPServer.swift').read_text()
a = s.index('    private func nativeBlockerTool(')
b = s.index('    private func nativeEvaluate(', a)
helper = s[a:b]
a = s.index('        if bm.engine == .chromium,\n           let result = nativeBlockerTool(')
b = s.index('        // Model-only tools', a)
route = s[a:b]
assert a < s.index('try bm.agentWebView()'), 'native route must precede WK preparation'
fixture = '''import Foundation
@MainActor final class DispatchFixture {
    func text(_ value: String, error: Bool = false) -> [String: Any] { ["content": [["type": "text", "text": value]], "isError": error] }
    func json(_ value: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: value), as: UTF8.self) }
''' + helper + '''    func dispatch(_ name: String, _ args: [String: Any], browserManager bm: BrowserManager, window: BrowserWindowState) throws -> [String: Any] {
''' + route + '''        try bm.agentWebView()
    }
}
'''
with TemporaryDirectory(prefix='bark-devmcp-dispatch-') as directory:
    out = Path(directory)
    source = out / 'Dispatch.swift'
    source.write_text(fixture)
    subprocess.run(['swiftc', '-swift-version', '5', '-parse-as-library', source,
                    'Tests/DevMCPBlocker/Main.swift', '-o', out / 'check'], cwd=root, check=True, timeout=60)
    subprocess.run([out / 'check'], cwd=root, check=True, timeout=60)
