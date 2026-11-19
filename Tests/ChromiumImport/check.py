from pathlib import Path
from tempfile import TemporaryDirectory
from contextlib import closing
import glob, os, re, sqlite3, subprocess, sys, time
root = Path(__file__).resolve().parents[2]
sys.dont_write_bytecode = True
sys.path.insert(0, str(root / 'Tests/ChromiumImport'))
import fixtures

with TemporaryDirectory(prefix='bark-import-check-') as directory:
    out = Path(directory)

    # The person's own browsers are reachable only through ImportManager(configuration:), which gives a
    # verification launch its fixtures. Nothing may build an ImportManager from defaults.
    reached = []
    for folder in ['App', 'Nook', 'Onboarding']:
        for path in sorted((root / folder).rglob('*.swift')):
            text = path.read_text()
            if 'ImportManager' not in text:
                continue
            for number, line in enumerate(text.splitlines(), 1):
                if re.search(r'\.installed\b|\bImportManager\(\)', line):
                    reached.append((str(path.relative_to(root)), number, line.strip()))
    allowed = [r for r in reached if r[0] == 'Nook/Managers/ImportManager/ImportManager.swift'
               and r[2].startswith('self.init(sources: configuration.isVerification ? .fixtures')]
    if reached != allowed or not allowed:
        print('the installed browsers are reachable outside ImportManager(configuration:):')
        for r in reached:
            if r not in allowed:
                print('  %s:%d: %s' % r)
        raise SystemExit(1)
    scratch = out / 'nookweb'
    p = subprocess.run(['swift', 'build', '--package-path', str(root / 'Packages/NookWeb'), '--scratch-path', str(scratch), '--jobs', '4'],
                       capture_output=True, text=True)
    if p.returncode:
        print(p.stdout + p.stderr)
        raise SystemExit(p.returncode)
    debug = scratch / 'x86_64-apple-macosx/debug'
    objects = sorted(o for target in ['FaviconFinder', 'MuteableWKWebView', 'NookBlocker', 'NookSettings', 'NookTabsCore', 'NookTweaks', 'NookWeb', 'SwiftSoup']
                     for o in glob.glob(str(debug / f'{target}.build/*.o')))
    sources = sorted(str(p) for p in (root / 'Nook/Managers/ImportManager').glob('*.swift'))
    binary = out / 'chromium-import-check'
    c = ['xcrun', 'swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library', '-I', str(debug / 'Modules'),
         '-Xcc', '-fmodule-map-file=' + str(debug / 'MuteableWKWebView.build/module.modulemap'),
         '-I', str(root / 'Packages/NookWeb/Sources/MuteableWKWebView/include'),
         '-I', str(root / 'Nook/ThirdParty/AdblockRustFFI/NookAdblock.xcframework/macos-arm64_x86_64/Headers'),
         *sources, str(root / 'App/Chromium/ChromiumStartup.swift'), *sorted(str(p) for p in (root / 'Tests/ChromiumImport').glob('*.swift')),
         *objects, str(debug / 'libnook_adblock.a'), '-framework', 'AppKit', '-framework', 'WebKit', '-framework', 'Security',
         '-lc++', '-lsqlite3', '-o', str(binary)]
    p = subprocess.run(c, capture_output=True, text=True)
    if p.returncode:
        print(p.stdout + p.stderr)
        raise SystemExit(p.returncode)

    now = int(time.time())
    home = out / 'home'
    home.mkdir()
    env = {**os.environ, 'HOME': str(home), 'CFFIXED_USER_HOME': str(home)}
    if '--measure' in sys.argv:
        visits = int(sys.argv[sys.argv.index('--measure') + 1])
        big, bookmarks, history = out / 'big', out / 'big-bookmarks', out / 'big-history'
        for d, v, b in [(big, visits, 5_000), (bookmarks, 0, 5_000), (history, visits, 0)]:
            fixtures.chrome_big(d, now, v, b)
        p = subprocess.run([str(binary), 'measure', str(big), str(visits), str(bookmarks), str(history)], capture_output=True, text=True, env=env, timeout=3600)
        print(p.stdout + p.stderr)
        raise SystemExit(p.returncode)

    data, errors, empty, bookmarks = out / 'data', out / 'errors', out / 'empty', out / 'bookmarks'
    fixtures.write(data, now)
    fixtures.chrome_errors(errors)
    fixtures.chrome_empty(empty)
    fixtures.chrome_big(bookmarks, now, 0, 5_000)

    # Chrome keeps History locked while it runs; the importer must read it all the same. The holder is
    # also mid-transaction with changed pages already in the file and their originals in the journal,
    # which only the journal's rollback undoes.
    locked = data / 'Import/Chrome/Profile 1/History'
    committed = locked.stat().st_size
    with closing(sqlite3.connect(locked, isolation_level=None)) as holder:
        holder.execute('PRAGMA locking_mode=EXCLUSIVE')
        holder.execute('PRAGMA cache_size=5')
        holder.execute('PRAGMA cache_spill=1')
        holder.execute('BEGIN EXCLUSIVE')
        holder.execute("UPDATE urls SET title = 'Uncommitted ' || title")
        cur = holder.execute("INSERT INTO urls(url,title,visit_count,typed_count,last_visit_time,hidden) VALUES ('https://fixture.test/uncommitted','Uncommitted',0,0,0,0)")
        holder.executemany('INSERT INTO visits(url,visit_time,from_visit,transition,segment_id,visit_duration) VALUES (?,?,0,?,0,0)',
                           [(cur.lastrowid, fixtures.chrome_time(now - 60), fixtures.VISIBLE)] * 3_000)
        journal = Path(str(locked) + '-journal')
        assert locked.stat().st_size > committed and journal.stat().st_size > 0, 'the open transaction spilled into the file'

        p = subprocess.run([str(binary), str(data), str(errors), str(empty), str(now), str(locked), str(bookmarks)], capture_output=True, text=True, env=env, timeout=300)
        holder.execute('ROLLBACK')
    print(p.stdout + p.stderr)
    raise SystemExit(p.returncode)
