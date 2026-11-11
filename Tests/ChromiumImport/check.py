from pathlib import Path
import json, shutil, subprocess
root = Path(__file__).resolve().parents[2]
out = root / 'build/import-check'
fixtures = out / 'data'
shutil.rmtree(fixtures, ignore_errors=True)
arc = fixtures / 'Import/Arc'
(arc / 'User Data').mkdir(parents=True)
items = ['folder-1', {'id': 'folder-1', 'title': 'Reading', 'data': {'list': {}}, 'childrenIds': ['tab-2']},
         'tab-2', {'id': 'tab-2', 'title': None, 'data': {'tab': {'savedURL': 'https://fixture.test/read', 'savedTitle': 'Read'}}, 'childrenIds': []},
         'tab-1', {'id': 'tab-1', 'title': 'Mine', 'data': {'tab': {'savedURL': 'https://fixture.test/pinned', 'savedTitle': 'Pinned'}}, 'childrenIds': []},
         'pinned-1', {'id': 'pinned-1', 'data': {'itemContainer': {}}, 'childrenIds': ['tab-1', 'folder-1']},
         'tab-3', {'id': 'tab-3', 'title': None, 'data': {'tab': {'savedURL': 'https://fixture.test/today', 'savedTitle': 'Today'}}, 'childrenIds': []},
         'unpinned-1', {'id': 'unpinned-1', 'data': {'itemContainer': {}}, 'childrenIds': ['tab-3']},
         'tab-4', {'id': 'tab-4', 'title': None, 'data': {'tab': {'savedURL': 'https://fixture.test/favorite', 'savedTitle': 'Favorite'}}, 'childrenIds': []},
         'top-1', {'id': 'top-1', 'data': {'itemContainer': {}}, 'childrenIds': ['tab-4']}]
space = {'id': 'space-1', 'title': 'Fixture Space', 'profile': {'default': True}, 'containerIDs': ['pinned', 'pinned-1', 'unpinned', 'unpinned-1'],
         'customInfo': {'iconType': {'emoji_v2': '🧪'}, 'windowTheme': {'primaryColorPalette': {'midTone': {'red': 1.0, 'green': 0.5, 'blue': 0.0}}}}}
sidebar = {'sidebar': {'containers': [{'global': {}}, {'spaces': ['space-1', space], 'items': items, 'topAppsContainerIDs': [{'default': True}, 'top-1']}]}}
(arc / 'StorableSidebar.json').write_text(json.dumps(sidebar))
(arc / 'User Data/Local State').write_text(json.dumps({'profile': {'info_cache': {'Default': {'name': 'Fixture Person'}}}}))
(arc / 'StorableMembershipCard.json').write_text(json.dumps({'memberNumber': 42}))
(arc / 'StorableAuthState.json').write_text(json.dumps({'session': {'user': {'name': 'Fixture Member'}}}))
dia = fixtures / 'Import/Dia'
dia.mkdir(parents=True)
tab = lambda i, url: {'id': i, 'contents': [{'variant': {'webContent': {'_0': {'url': url, 'title': i}}}}]}
(dia / 'StorableProfileContainers.json').write_text(json.dumps({'version': 1, 'containers': [
    {'tabs': [tab('dia-favorite', 'https://fixture.test/dia-favorite')], 'id': {'container': {'favorites': {}}, 'profileID': 'p'}},
    {'tabs': [tab('dia-window', 'https://fixture.test/dia-window')], 'id': {'container': {'window': {'_0': 'w'}}, 'profileID': 'p'}}]}))
sources = sorted(str(p) for p in (root / 'Nook/Managers/ImportManager').glob('*.swift'))
binary = out / 'chromium-import-check'
c = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library', *sources,
     str(root / 'Tests/ChromiumImport/Main.swift'), '-o', str(binary)]
p = subprocess.run(c, capture_output=True, text=True)
print(p.stdout + p.stderr)
if p.returncode:
    raise SystemExit(p.returncode)
p = subprocess.run([str(binary), str(fixtures)], capture_output=True, text=True)
print(p.stdout + p.stderr)
raise SystemExit(p.returncode)
