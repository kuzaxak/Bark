from pathlib import Path
import subprocess
root=Path(__file__).resolve().parents[2];out=root/'build/general-settings';out.mkdir(parents=True,exist_ok=True)
cmd=['swiftc','-swift-version','5','-parse-as-library',str(root/'Packages/NookUI/Sources/NookUI/Settings/GeneralSettingsSection.swift'),str(root/'Tests/ChromiumGeneralSettings/Main.swift'),'-o',str(out/'check')]
for i,c in enumerate([cmd,[str(out/'check')]]):
 p=subprocess.run(c,capture_output=True,text=True);(out/f'{i}.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
 if p.returncode:raise SystemExit(p.returncode)
