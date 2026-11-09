from pathlib import Path
import subprocess,json
root=Path(__file__).resolve().parents[2]; out=root/'build/devmcp/checks';out.mkdir(parents=True,exist_ok=True)
s=(root/'Nook/Managers/DevMCPServer/DevMCPServer.swift').read_text()
start=s.index('@MainActor\nfinal class DevMCPServer')
end=s.index('    // MARK: - Tools')
parser=s[s.index('private struct HTTPRequest'):s.index('private extension WKWebView')]
# All lifecycle, timeout, permission and HTTP parser code is verbatim; only app tool dispatch is substituted.
s='import Foundation\nimport OSLog\n'+s[start:end]+'''    static let toolList: [[String: Any]] = []
    func callTool(_ name: String, _ args: [String: Any]) async -> [String: Any] { await TestTools.call() }
}\n'''+parser
(out/'ServerLifecycle.swift').write_text(s)
cmd=['swiftc','-swift-version','5','-parse-as-library','Nook/Managers/DevMCPServer/DevMCPFiles.swift','Nook/Managers/DevMCPServer/DevMCPConfiguration.swift',str(out/'ServerLifecycle.swift'),'Tests/DevMCP/Main.swift','-o',str(out/'check')]
(out/'command.json').write_text(json.dumps(cmd,indent=2))
r=subprocess.run(cmd,cwd=root,capture_output=True,text=True);(out/'compile.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr)
if r.returncode:raise SystemExit(r.returncode)
r=subprocess.run([str(out/'check')],cwd=root,capture_output=True,text=True);(out/'run.log').write_text(r.stdout+r.stderr);print(r.stdout+r.stderr);raise SystemExit(r.returncode)
