from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[2];out=root/'build/loading-bar';out.mkdir(parents=True,exist_ok=True)
s=(root/'Nook/Components/WebsiteView/PageLoadingProgressBar.swift').read_text()
a=s.index('    static func sweep(');b=s.index('    var body: some View {',a)
(out/'Sweep.swift').write_text('import Foundation\nenum NativePageLoadingBar {\n'+s[a:b]+'}\n')
cmd=['swiftc','-swift-version','5','-parse-as-library',str(out/'Sweep.swift'),str(root/'Tests/ChromiumLoadingBar/Main.swift'),'-o',str(out/'check')]
for i,c in enumerate([cmd,[str(out/'check')]]):
 p=subprocess.run(c,capture_output=True,text=True);(out/f'{i}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
 if p.returncode:raise SystemExit(p.returncode)
