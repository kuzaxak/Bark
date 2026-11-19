from pathlib import Path
from tempfile import TemporaryDirectory
import json,subprocess
import sys

root=Path(__file__).resolve().parents[2]
sys.path.insert(0, str(root / "Tests/Shared"))
from swift_check import build_package, swift_target

target = swift_target()

with TemporaryDirectory(prefix='bark-space-chrome-') as directory:
    out = Path(directory)
    packages=out/'packages'
    objects=[];includes=[]
    for name in ['NookTabsCore','NookSettings']:
     scratch=packages/name
     debug=build_package(root/'Packages'/name,scratch,target,log=out/f'{name}.log')
     includes+=['-I',str(debug/'Modules')]
     objects+=map(str,sorted((debug/f'{name}.build').glob('*.o')))
    cmd=['swiftc','-swift-version','5','-target',target,'-parse-as-library',*includes,str(root/'App/Chromium/ChromiumAppearance.swift'),str(root/'App/Chromium/ChromiumSpaceChrome.swift'),str(root/'Tests/ChromiumSpaceChrome/Main.swift'),*objects,'-o',str(out/'check')]
    (out/'command.json').write_text(json.dumps(cmd,indent=2))
    for i,c in enumerate([cmd,[str(out/'check')]]):
     p=subprocess.run(c,capture_output=True,text=True);(out/f'{i}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
     if p.returncode:raise SystemExit(p.returncode)
