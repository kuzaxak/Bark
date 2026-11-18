from pathlib import Path
from tempfile import TemporaryDirectory
import json,os,subprocess
root=Path(__file__).resolve().parents[2]

with TemporaryDirectory(prefix='bark-ai-config-') as directory:
    out = Path(directory)
    home=out/'home'
    home.mkdir()
    package=out/'settings-package'
    build=['swift','build','--package-path',str(root/'Packages/NookSettings'),'--scratch-path',str(package),'--jobs','2']
    source=(root/'Nook/Managers/AIManager/AIConfigService.swift').read_text().replace('import NookWeb\n','')
    (out/'AIConfigService.swift').write_text(source)
    debug=package/'x86_64-apple-macosx/debug'
    binary=out/out.name
    manager=root/'Nook/Managers/AIManager'
    compile=lambda: ['swiftc','-swift-version','5','-target','x86_64-apple-macosx15.5','-parse-as-library','-I',str(debug/'Modules'),
     str(out/'AIConfigService.swift'),str(root/'Nook/Models/AI/AIKeychainStorage.swift'),str(manager/'AIProvider.swift'),
     str(manager/'Providers/AnthropicProvider.swift'),str(manager/'Providers/OpenAICompatibleProvider.swift'),str(manager/'Tools/BrowserTools.swift'),
     str(root/'Tests/ChromiumAIConfig/Main.swift'),*(str(debug/'NookSettings.build'/name) for name in ['AIModels.swift.o','MCPServerConfig.swift.o']),'-o',str(binary)]
    env={**os.environ,'HOME':str(home),'CFFIXED_USER_HOME':str(home)}
    p=subprocess.run(build,capture_output=True,text=True)
    (out/'build.log').write_text(p.stdout+p.stderr)
    if p.returncode:print(p.stdout+p.stderr);raise SystemExit(p.returncode)
    c=compile();(out/'command.json').write_text(json.dumps(c,indent=2))
    p=subprocess.run(c,capture_output=True,text=True);(out/'compile.log').write_text(p.stdout+p.stderr);print(p.stdout+p.stderr)
    if p.returncode:raise SystemExit(p.returncode)
    undefined=subprocess.run(['nm','-u',str(binary)],capture_output=True,text=True).stdout
    if 'SecItem' in undefined:raise SystemExit('the test binary links the real keychain')
    # UserDefaults.standard reaches cfprefsd under the real home; this binary's own domain is the only thing it writes there.
    domain=binary.name
    try:
        p=subprocess.run([str(binary)],capture_output=True,text=True,env=env)
        print(p.stdout+p.stderr)
        raise SystemExit(p.returncode)
    finally:
        subprocess.run(['defaults','delete',domain],capture_output=True)
        (Path.home()/'Library/Preferences'/(domain+'.plist')).unlink(missing_ok=True)
