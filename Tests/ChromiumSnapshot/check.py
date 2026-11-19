from pathlib import Path
from tempfile import TemporaryDirectory
import json,subprocess,sys
root=Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='bark-snapshot-') as directory:
    out = Path(directory)
    s=(root/'Nook/Managers/DevMCPServer/DevMCPServer.swift').read_text();a=s.index('    private struct StoredSnapshot');b=s.index('    private var token',a);cache=s[a:b]
    a=s.index('    private func nativeScreenshot(');b=s.index('    private func nativeSelectionTool(',a);helper=s[a:b].replace('    private func nativeSnapshot','    func nativeSnapshot',1).replace('    private func nativeScreenshot','    func nativeScreenshot',1)
    a=s.index('    private func nativeSelectionTool(')
    b=s.index('        if let result = nativeBlockerTool',a)
    selection=s[a:b].replace('    private func callTool(', '    func callTool(',1)
    selection+='        preconditionFailure("Human picker did not reach native selection dispatch")\n    }\n'
    pickerSource=(root/'Nook/Components/DevTools/BrowserManager+DevPick.swift').read_text()
    a=pickerSource.index('    func nativeDeveloperPage');b=pickerSource.index('    /// Clipboard',a)
    developer=pickerSource[a:b]
    a=s.index('    private static func wholeNumber(');b=s.index('    /// These operations',a);whole=s[a:b]
    tools=root/'Packages/NookWeb/Sources/NookWeb/DevTools'
    fixture='''import Foundation
@MainActor final class SnapshotFixture {
 var isPermitted=true;var listener:Int?=1;var generation:UInt64=1
 var humanWindow:BrowserWindowState?;var browserManager:BrowserManager?
 static let humanTools:Set<String> = ["pick", "selection"]
 func text(_ text:String,error:Bool=false)->[String:Any] {["text":text,"isError":error]}
'''+whole+cache+helper+selection+''' func reset() {generation+=1;snapshots=[:]}
 var cacheCount:Int {snapshots.count}
}
@MainActor extension BrowserManager {
'''+developer+'}\n'
    (out/'Snapshot.swift').write_text(fixture)
    picker=root/'Packages/NookWeb/Sources/NookWeb/DevTools/DevPickerScript.swift'
    args=['swiftc','-swift-version','5','-parse-as-library',str(out/'Snapshot.swift'),str(tools/'PageSession+DevTools.swift'),str(tools/'DevPick.swift'),str(tools/'DevEntries.swift'),str(tools/'DevLog.swift'),str(picker),str(root/'Tests/ChromiumSnapshot/Main.swift'),'-o',str(out/'check')]
    (out/'command.json').write_text(json.dumps(args,indent=2))
    for i,c in enumerate([args,[str(out/'check')]]):
     p=subprocess.run(c,capture_output=True,text=True);(out/f'{i}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
     if p.returncode:raise SystemExit(p.returncode)
    linked = subprocess.check_output(['/usr/bin/otool', '-L', str(out/'check')], text=True)
    if '/WebKit.framework/' in linked:
        raise SystemExit('Chromium snapshot harness links WebKit')
    # Export the actual maintained Swift script source, not a separate JS copy.
    export = out / 'Export.swift'
    export.write_text("""import Foundation
@main struct Export {
    static func main() throws {
        let scripts = [
            "source": DevPickerScript.source,
            "describe": DevPickerScript.describeScript(selector: "#save")!,
            "describeMissing": DevPickerScript.describeScript(selector: "#missing")!,
            "hints": DevPickerScript.hintsScript(selector: "#save")!,
            "hintsMissing": DevPickerScript.hintsScript(selector: "#missing")!
        ]
        FileHandle.standardOutput.write(try JSONEncoder().encode(scripts))
    }
}
""")
    cmd=['swiftc','-swift-version','5','-parse-as-library',str(picker),str(export),'-o',str(out/'export')]
    p=subprocess.run(cmd,capture_output=True,text=True);(out/'export-compile.log').write_text(p.stdout+p.stderr)
    if p.returncode:print(p.stderr);raise SystemExit(p.returncode)
    p=subprocess.run([str(out/'export')],capture_output=True)
    if p.returncode:
        print(p.stderr.decode(errors='replace'))
        raise SystemExit(p.returncode)
    (out/'picker-scripts.json').write_bytes(p.stdout)
    node=sys.argv[1] if len(sys.argv)>1 else 'node'
    node_command=[node,str(root/'Tests/ChromiumSnapshot/Script.cjs'),str(out/'picker-scripts.json')]
    (out/'node-command.json').write_text(json.dumps(node_command,indent=2))
    p=subprocess.run(node_command,capture_output=True,text=True);(out/'script.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr);raise SystemExit(p.returncode)
