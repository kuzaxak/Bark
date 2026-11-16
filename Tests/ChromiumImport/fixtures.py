"""Writes Arc, Chrome and Dia fixture profiles from literals. Nothing here reads a real browser's data.

The History tables are Chromium 156's, from components/history/core/browser/url_database.cc and
visit_database.cc; the Bookmarks layout is bookmark_codec.cc's; Local State is
profile_attributes_storage.cc's; extension settings are extension_prefs.cc's."""
from pathlib import Path
import json, sqlite3

WINDOWS_EPOCH_OFFSET = 11644473600
DAY = 86400
VISIBLE = 0x30000000
TYPED = 0x30000001
REDIRECT_HOP = 0x10000000

URLS = ('CREATE TABLE urls(id INTEGER PRIMARY KEY AUTOINCREMENT,url LONGVARCHAR,title LONGVARCHAR,'
        'visit_count INTEGER DEFAULT 0 NOT NULL,typed_count INTEGER DEFAULT 0 NOT NULL,'
        'last_visit_time INTEGER NOT NULL,hidden INTEGER DEFAULT 0 NOT NULL)')
VISITS = ('CREATE TABLE visits(id INTEGER PRIMARY KEY AUTOINCREMENT,url INTEGER NOT NULL,visit_time INTEGER NOT NULL,'
          'from_visit INTEGER,external_referrer_url TEXT,transition INTEGER DEFAULT 0 NOT NULL,segment_id INTEGER,'
          'visit_duration INTEGER DEFAULT 0 NOT NULL,incremented_omnibox_typed_score BOOLEAN DEFAULT FALSE NOT NULL,'
          'opener_visit INTEGER,originator_cache_guid TEXT,originator_visit_id INTEGER,originator_from_visit INTEGER,'
          'originator_opener_visit INTEGER,is_known_to_sync BOOLEAN DEFAULT FALSE NOT NULL,'
          'consider_for_ntp_most_visited BOOLEAN DEFAULT FALSE NOT NULL,visited_link_id INTEGER DEFAULT 0 NOT NULL,app_id TEXT)')


def chrome_time(unix):
    return (int(unix) + WINDOWS_EPOCH_OFFSET) * 1_000_000


def history(path, rows):
    """rows: (url, title, [(unix time, transition)])."""
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.execute(URLS)
    con.execute(VISITS)
    con.execute('CREATE INDEX visits_url_index ON visits (url)')
    for url, title, visits in rows:
        cur = con.execute('INSERT INTO urls(url,title,visit_count,typed_count,last_visit_time,hidden) VALUES (?,?,?,?,?,0)',
                          (url, title, len(visits), 0, chrome_time(max(t for t, _ in visits))))
        con.executemany('INSERT INTO visits(url,visit_time,from_visit,transition,segment_id,visit_duration) VALUES (?,?,0,?,0,0)',
                        [(cur.lastrowid, chrome_time(t), transition) for t, transition in visits])
    con.commit()
    con.close()


def url(name, address, id=[0]):
    id[0] += 1
    return {'id': str(id[0]), 'guid': f'00000000-0000-4000-8000-{id[0]:012d}', 'name': name, 'type': 'url', 'url': address,
            'date_added': '13400000000000000', 'date_last_used': '0'}


def folder(name, children, id=[1000]):
    id[0] += 1
    return {'id': str(id[0]), 'guid': f'00000000-0000-4000-9000-{id[0]:012d}', 'name': name, 'type': 'folder',
            'children': children, 'date_added': '13400000000000000', 'date_last_used': '0', 'date_modified': '0'}


def bookmarks(path, bar, other=(), synced=()):
    path.parent.mkdir(parents=True, exist_ok=True)
    roots = {'bookmark_bar': folder('Bookmarks bar', list(bar)), 'other': folder('Other bookmarks', list(other)),
             'synced': folder('Mobile bookmarks', list(synced))}
    path.write_text(json.dumps({'checksum': '0', 'roots': roots, 'version': 1}))


def extension(from_webstore, location, disabled=()):
    return {'from_webstore': from_webstore, 'location': location, 'disable_reasons': list(disabled)}


def preferences(path, settings):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps({'extensions': {'settings': settings}}))


def local_state(path, profiles, order):
    path.parent.mkdir(parents=True, exist_ok=True)
    cache = {directory: {'name': name, 'is_using_default_name': False} for directory, name in profiles}
    path.write_text(json.dumps({'profile': {'info_cache': cache, 'profiles_order': order}}))


def arc(root, now):
    arc = root / 'Import/Arc'
    (arc / 'User Data').mkdir(parents=True)
    items = ['folder-1', {'id': 'folder-1', 'title': 'Reading', 'data': {'list': {}}, 'childrenIds': ['tab-2']},
             'tab-2', {'id': 'tab-2', 'title': None, 'data': {'tab': {'savedURL': 'https://fixture.test/read', 'savedTitle': 'Read'}}, 'childrenIds': []},
             'tab-1', {'id': 'tab-1', 'title': 'Mine', 'data': {'tab': {'savedURL': 'https://fixture.test/pinned', 'savedTitle': 'Pinned'}}, 'childrenIds': []},
             'pinned-1', {'id': 'pinned-1', 'data': {'itemContainer': {}}, 'childrenIds': ['tab-1', 'folder-1']},
             'tab-3', {'id': 'tab-3', 'title': None, 'data': {'tab': {'savedURL': 'https://fixture.test/today', 'savedTitle': 'Today'}}, 'childrenIds': []},
             'unpinned-1', {'id': 'unpinned-1', 'data': {'itemContainer': {}}, 'childrenIds': ['tab-3']},
             'tab-4', {'id': 'tab-4', 'title': None, 'data': {'tab': {'savedURL': 'https://fixture.test/favorite', 'savedTitle': 'Favorite'}}, 'childrenIds': []},
             'top-1', {'id': 'top-1', 'data': {'itemContainer': {}}, 'childrenIds': ['tab-4']},
             'tab-5', {'id': 'tab-5', 'title': None, 'data': {'tab': {'savedURL': 'https://fixture.test/arc-work', 'savedTitle': 'Arc Work'}}, 'childrenIds': []},
             'pinned-2', {'id': 'pinned-2', 'data': {'itemContainer': {}}, 'childrenIds': ['tab-5']},
             'unpinned-2', {'id': 'unpinned-2', 'data': {'itemContainer': {}}, 'childrenIds': []},
             'tab-6', {'id': 'tab-6', 'title': None, 'data': {'tab': {'savedURL': 'https://fixture.test/errand', 'savedTitle': 'Errand'}}, 'childrenIds': []},
             'pinned-3', {'id': 'pinned-3', 'data': {'itemContainer': {}}, 'childrenIds': ['tab-6']},
             'unpinned-3', {'id': 'unpinned-3', 'data': {'itemContainer': {}}, 'childrenIds': []}]
    space = {'id': 'space-1', 'title': 'Fixture Space', 'profile': {'default': True}, 'containerIDs': ['pinned', 'pinned-1', 'unpinned', 'unpinned-1'],
             'customInfo': {'iconType': {'emoji_v2': '🧪'}, 'windowTheme': {'primaryColorPalette': {'midTone': {'red': 1.0, 'green': 0.5, 'blue': 0.0}}}}}
    work = {'id': 'space-2', 'title': 'Arc Work Space', 'profile': {'custom': {'_0': {'directoryBasename': 'Profile 1'}}},
            'containerIDs': ['pinned', 'pinned-2', 'unpinned', 'unpinned-2']}
    errands = {'id': 'space-3', 'title': 'Fixture Errands', 'profile': {'default': True},
               'containerIDs': ['pinned', 'pinned-3', 'unpinned', 'unpinned-3']}
    sidebar = {'sidebar': {'containers': [{'global': {}}, {'spaces': ['space-1', space, 'space-2', work, 'space-3', errands], 'items': items,
                                                         'topAppsContainerIDs': [{'default': True}, 'top-1']}]}}
    (arc / 'StorableSidebar.json').write_text(json.dumps(sidebar))
    local_state(arc / 'User Data/Local State', [('Default', 'Fixture Person'), ('Profile 1', 'Arc Work')], ['Default', 'Profile 1'])
    (arc / 'StorableMembershipCard.json').write_text(json.dumps({'memberNumber': 42}))
    (arc / 'StorableAuthState.json').write_text(json.dumps({'session': {'user': {'name': 'Fixture Member'}}}))
    history(arc / 'User Data/Default/History', [('https://fixture.test/arc-history', 'Arc History', [(now - 5 * DAY, VISIBLE)])])
    history(arc / 'User Data/Profile 1/History', [('https://fixture.test/arc-work-history', 'Arc Work History', [(now - 6 * DAY, VISIBLE)])])
    preferences(arc / 'User Data/Default/Secure Preferences', {'f' * 32: extension(True, 1)})


def dia(root):
    dia = root / 'Import/Dia'
    dia.mkdir(parents=True)
    tab = lambda i, url: {'id': i, 'contents': [{'variant': {'webContent': {'_0': {'url': url, 'title': i}}}}]}
    (dia / 'StorableProfileContainers.json').write_text(json.dumps({'version': 1, 'containers': [
        {'tabs': [tab('dia-favorite', 'https://fixture.test/dia-favorite')], 'id': {'container': {'favorites': {}}, 'profileID': 'p'}},
        {'tabs': [tab('dia-window', 'https://fixture.test/dia-window')], 'id': {'container': {'window': {'_0': 'w'}}, 'profileID': 'p'}}]}))


def chrome(root, now):
    chrome = root / 'Import/Chrome'
    local_state(chrome / 'Local State', [('Default', 'Fixture Person'), ('Profile 1', 'Work'), ('Profile 7', 'Gone')],
                ['Profile 1', 'Default', 'Profile 7'])
    bookmarks(chrome / 'Default/Bookmarks',
              [url('Fixture Bar', 'https://fixture.test/bar'),
               folder('Reading', [url('Read', 'https://fixture.test/read'), folder('Deep', [url('Deep', 'https://fixture.test/deep')])]),
               url('Bookmarklet', 'javascript:alert(1)')],
              [url('Other', 'https://fixture.test/other'), url('Settings', 'chrome://settings')])
    history(chrome / 'Default/History', [
        ('https://fixture.test/news', 'Fixture News', [(now - 3 * DAY, TYPED), (now - 1 * DAY, VISIBLE)]),
        ('https://fixture.test/docs', 'Fixture Docs', [(now - 2 * DAY, VISIBLE)]),
        ('file:///private/tmp/fixture.html', 'Fixture File', [(now - 2 * DAY, VISIBLE)]),
        ('https://fixture.test/hop', 'Fixture Hop', [(now - 2 * DAY, REDIRECT_HOP)])])
    preferences(chrome / 'Default/Secure Preferences', {
        'a' * 32: extension(True, 1), 'b' * 32: extension(True, 1, [1]),
        'c' * 32: extension(False, 4), 'd' * 32: extension(False, 5), 'g' * 32: extension(True, 1),
        'not an extension id': extension(True, 1)})
    bookmarks(chrome / 'Profile 1/Bookmarks', [url('Work Board', 'https://fixture.test/board')])
    bookmarks(chrome / 'Profile 1/AccountBookmarks', [url('Work Account', 'https://fixture.test/account')])
    history(chrome / 'Profile 1/History', [('https://fixture.test/work-wiki', 'Work Wiki', [(now - 4 * DAY, VISIBLE)])])
    preferences(chrome / 'Profile 1/Preferences', {'a' * 32: extension(True, 1), 'e' * 32: extension(True, 1)})


def chrome_errors(root):
    """A profile whose files are not what Chromium writes, and one with no files at all."""
    chrome = root / 'Import/Chrome'
    local_state(chrome / 'Local State', [('Default', 'Broken'), ('Profile 1', 'Empty'), ('../Chrome/Default', 'Escape')],
                ['Default', 'Profile 1', '../Chrome/Default'])
    (chrome / 'Default').mkdir(parents=True)
    (chrome / 'Default/Bookmarks').write_text('{"roots": ')
    (chrome / 'Default/History').write_text('not a database')
    (chrome / 'Default/Secure Preferences').write_text('{"extensions": ')
    (chrome / 'Profile 1').mkdir(parents=True)
    arc = root / 'Import/Arc'
    (arc / 'User Data').mkdir(parents=True)
    items = ['tab-1', {'id': 'tab-1', 'title': None, 'data': {'tab': {'savedURL': 'https://fixture.test/outside', 'savedTitle': 'Outside'}}, 'childrenIds': []},
             'pinned-1', {'id': 'pinned-1', 'data': {'itemContainer': {}}, 'childrenIds': ['tab-1']}]
    space = {'id': 'space-1', 'title': 'Outside', 'profile': {'custom': {'_0': {'directoryBasename': '../../Chrome/Default'}}},
             'containerIDs': ['pinned', 'pinned-1']}
    (arc / 'StorableSidebar.json').write_text(json.dumps({'sidebar': {'containers': [{'spaces': ['space-1', space], 'items': items}]}}))


def chrome_empty(root):
    chrome = root / 'Import/Chrome'
    local_state(chrome / 'Local State', [], [])


def write(root, now):
    arc(root, now)
    dia(root)
    chrome(root, now)


def chrome_big(root, now, visits, bookmark_count):
    """One profile with `bookmark_count` bookmarks in folders of 50 and `visits` visits over 10,000 pages."""
    chrome = root / 'Import/Chrome'
    local_state(chrome / 'Local State', [('Default', 'Big')], ['Default'])
    (chrome / 'Default').mkdir(parents=True, exist_ok=True)
    if bookmark_count:
        folders = [folder(f'Folder {f}', [url(f'Page {f}-{i}', f'https://bigfixture.test/{f}/{i}') for i in range(50)])
                   for f in range(bookmark_count // 50)]
        bookmarks(chrome / 'Default/Bookmarks', folders)
    if not visits:
        return
    path = chrome / 'Default/History'
    path.parent.mkdir(parents=True, exist_ok=True)
    con = sqlite3.connect(path)
    con.execute(URLS)
    con.execute(VISITS)
    pages = 10_000
    con.executemany('INSERT INTO urls(id,url,title,visit_count,typed_count,last_visit_time,hidden) VALUES (?,?,?,?,0,?,0)',
                    [(i + 1, f'https://bigfixture.test/page/{i}', f'Page {i}', 0, chrome_time(now)) for i in range(pages)])
    con.executemany('INSERT INTO visits(url,visit_time,from_visit,transition,segment_id,visit_duration) VALUES (?,?,0,?,0,0)',
                    [(v % pages + 1, chrome_time(now - (visits - v) * 60), VISIBLE) for v in range(visits)])
    con.commit()
    con.close()


if __name__ == '__main__':
    # fixtures.py DATA_DIR: lays out the walk's Arc, Chrome and Dia fixtures under DATA_DIR/Import, visits dated from now.
    import sys, time
    write(Path(sys.argv[1]), int(time.time()))
