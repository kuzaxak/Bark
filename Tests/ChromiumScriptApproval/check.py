from pathlib import Path
import json, subprocess
root = Path(__file__).resolve().parents[2]
out = root / 'build/script-approval'; out.mkdir(parents=True, exist_ok=True)
s = (root / 'Nook/Managers/AIManager/Tools/BrowserToolExecutor.swift').read_text()
a = s.index('    func execute(_ toolCall:'); b = s.index('    // MARK: - Tool Implementations', a)
execute = s[a:b]
a = s.index('    private struct NativeScriptTarget'); b = s.index('\n}', a)
methods = s[a:b]
stubs = ''
for name in ['executeNavigateToURL','executeReadPageContent','executeClickElement','executeGetInteractiveElements','executeExtractStructuredData','executeSearchInPage']:
    stubs += f'func {name}(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {{ "unused" }}\n'
for name in ['executeSummarizePage','executeGetSelectedText']:
    stubs += f'func {name}(browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {{ "unused" }}\n'
for name in ['executeSwitchTab','executeCreateTab']:
    stubs += f'func {name}(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) throws -> String {{ "unused" }}\n'
stubs += 'func executeGetTabList(browserManager: BrowserManager, windowState: BrowserWindowState) -> String { "unused" }\n'
fixture = '''import Foundation
@MainActor final class BrowserToolExecutor {
 static let log = Log()
 var browserManager: BrowserManager?
 var windowState: BrowserWindowState?
 var agentSpace: UUID?
 var confirmationHandler: ((String,[String:Any]) async -> Bool)?
 func getWebView(browserManager: BrowserManager, windowState: BrowserWindowState) -> FakeWK? { fatalError("native execution reached WK preparation") }
''' + execute + methods + '\n' + stubs + '\n}\n'
(out / 'Executor.swift').write_text(fixture)
cmd = ['swiftc','-swift-version','5','-parse-as-library',str(out/'Executor.swift'),str(root/'Tests/ChromiumScriptApproval/Main.swift'),'-o',str(out/'check')]
(out/'command.json').write_text(json.dumps(cmd,indent=2))
for i,c in enumerate([cmd,[str(out/'check')]]):
 p=subprocess.run(c,capture_output=True,text=True);(out/f'{i}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
 if p.returncode:raise SystemExit(p.returncode)
