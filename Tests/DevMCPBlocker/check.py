from pathlib import Path
import json, subprocess
root = Path(__file__).resolve().parents[2]
out = root / 'build/devmcp-blocker/dispatch'
out.mkdir(parents=True, exist_ok=True)
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
(out / 'Dispatch.swift').write_text(fixture)
cmd = ['swiftc', '-swift-version', '5', '-parse-as-library', str(out / 'Dispatch.swift'), 'Tests/DevMCPBlocker/Main.swift', '-o', str(out / 'check')]
(out / 'command.json').write_text(json.dumps(cmd, indent=2))
for i, command in enumerate([cmd, [str(out / 'check')]]):
    r = subprocess.run(command, cwd=root, capture_output=True, text=True, timeout=60)
    (out / f'{i}.log').write_text(r.stdout + r.stderr)
    print(r.stdout + r.stderr)
    if r.returncode:
        raise SystemExit(r.returncode)
