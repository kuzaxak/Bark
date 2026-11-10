from pathlib import Path
import json,subprocess
root=Path(__file__).resolve().parents[2];out=root/'build/space-chrome/check';out.mkdir(parents=True,exist_ok=True)
packages=root/'build/space-chrome/packages'
objects=[];includes=[]
for name in ['NookTabsCore','NookSettings']:
 scratch=packages/name
 p=subprocess.run(['swift','build','--package-path',str(root/'Packages'/name),'--scratch-path',str(scratch),'--jobs','2'],capture_output=True,text=True)
 (out/f'{name}.log').write_text(p.stdout+p.stderr)
 if p.returncode:print(p.stdout+p.stderr);raise SystemExit(p.returncode)
 debug=scratch/'x86_64-apple-macosx/debug'
 includes+=['-I',str(debug/'Modules')]
 objects+=map(str,sorted((debug/f'{name}.build').glob('*.o')))
s=(root/'App/NookApp.swift').read_text()
a=s.index('func applyAppearanceMode(');b=s.index('// MARK: - Window Configuration',a)
apply=s[a:b].replace('private func ','func ',1)
(out/'Apply.swift').write_text('import AppKit\nimport NookSettings\n'+apply)
cmd=['swiftc','-swift-version','5','-target','x86_64-apple-macosx15.5','-parse-as-library',*includes,str(out/'Apply.swift'),str(root/'App/Chromium/ChromiumAppearance.swift'),str(root/'App/Chromium/ChromiumSpaceChrome.swift'),str(root/'Tests/ChromiumSpaceChrome/Main.swift'),*objects,'-o',str(out/'check')]
(out/'command.json').write_text(json.dumps(cmd,indent=2))
for i,c in enumerate([cmd,[str(out/'check')]]):
 p=subprocess.run(c,capture_output=True,text=True);(out/f'{i}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
 if p.returncode:raise SystemExit(p.returncode)
