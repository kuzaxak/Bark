from pathlib import Path
import json,subprocess
root=Path(__file__).resolve().parents[2];out=root/'build/site-controls';out.mkdir(parents=True,exist_ok=True)
s=(root/'Nook/Components/Extensions/ExtensionLibraryView.swift').read_text()
def method(name,end):
 a=s.index('    private func '+name+'(');return s[a:s.index(end,a)].replace('    private func ','    func ',1)
clear=method('clear','    // MARK: - Zoom Helpers')
zoom=s[s.index('    private func zoomIn('):s.index('// MARK: - Tiles')].rstrip().rstrip('}')
zoom=zoom.replace('    private func ','    func ')
c=(root/'App/Chromium/ChromiumSiteControls.swift').read_text()
a=c.index('enum ChromiumPageZoom');b=c.index('enum ChromiumSiteControlsPlacement');percent=c[a:c.index('\n}\n',a)+3]+c[b:c.index('\n}\n',b)+3]
fixture='import CoreGraphics\nimport Foundation\n'+percent+'''
@MainActor final class ViewFixture {
 var browserManager:BrowserManager
 var windowState=BrowserWindowState()
 var currentTab:PageSession?
 var currentHost:String?
 var nativeZoomPercent:Int?
 var dismissals=0
 var isChromium:Bool{browserManager.engine == .chromium}
 func onDismiss(){dismissals+=1}
 init(_ manager:BrowserManager){browserManager=manager}
'''+clear+zoom+'\n}\n'
(out/'View.swift').write_text(fixture)
cmd=['swiftc','-swift-version','5','-parse-as-library',str(out/'View.swift'),str(root/'Tests/ChromiumSiteControls/Main.swift'),'-o',str(out/'check')]
(out/'command.json').write_text(json.dumps(cmd,indent=2))
for i,x in enumerate([cmd,[str(out/'check')]]):
 p=subprocess.run(x,capture_output=True,text=True);(out/f'{i}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
 if p.returncode:raise SystemExit(p.returncode)
