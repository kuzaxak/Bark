#!/usr/bin/env python3
"""Builds and runs the data conversion tests against synthetic fixtures under /private/tmp.

check.py                    build and run all scenarios
check.py --only-build       build the test binary, for --make-fixture
check.py --scenario NAME    run one scenario
check.py --red              run every scenario in its own process; each must fail (before implementing)
check.py --mutation [NAME]  neutralize one behaviour, or each in turn; its scenario must fail
check.py --list-mutations
"""
from pathlib import Path
import hashlib, json, os, re, shutil, subprocess, sys

root = Path(__file__).resolve().parents[2]
out = root / 'build/data-conversion'
tests = root / 'Tests/ChromiumDataConversion'
core = root / 'App/Chromium/ChromiumDataConversion.swift'
startup = root / 'App/Chromium/ChromiumStartup.swift'
work_dir = '/private/tmp/nook-data-conversion-tests'
test_domains = ['ee.qdo.nook.chromium-conversion-test', 'ee.qdo.nook.chromium-conversion-test.conversion-probe']

# Every key the app reads must be classified: copied (allowedPreferences in the source) or here, with why not.
EXCLUDED_PREFERENCES = {
    'settings.geminiApiKey': 'secret; the service deletes it on launch',
    'settings.openRouterApiKey': 'secret; the service deletes it on launch',
    'settings.aiProvider': 'superseded by ai_config.json',
    'settings.geminiModel': 'superseded by ai_config.json',
    'settings.openRouterModel': 'superseded by ai_config.json',
    'settings.ollamaEndpoint': 'superseded by ai_config.json',
    'settings.ollamaModel': 'superseded by ai_config.json',
    'settings.webSearchContextSize': 'superseded by ai_config.json',
    'settings.webSearchEnabled': 'superseded by ai_config.json',
    'settings.webSearchEngine': 'superseded by ai_config.json',
    'settings.webSearchMaxResults': 'superseded by ai_config.json',
    'settings.adBlockerLastUpdate': 'describes filter lists that are not copied',
    'settings.agentWindow': 'retired; removed on read',
    'settings.blockCrossSiteTracking': 'retired; removed on read',
    'settings.tabUnloadTimeout': 'retired; replaced by tabManagementMode',
    'settings.debugToggleUpdateNotification': 'developer-only',
    'settings.defaultBrowserPromptDismissedAt': 'an answer about the old bundle id',
    'settings.lastSeenVersion': 'release notes of the old app',
    'settings.pinnedExtensionIDs': 'extensions must be reinstalled per profile',
    'settings.pinnedExtensionIDsMigrated': 'extensions must be reinstalled per profile',
    'settings.sitePermissions': 'engine-bound; Chromium keeps permissions per profile',
    'settings.html': 'a file name, not a preference',
}

# name: (source text, replacement, the scenario that must catch it). Each removes one behaviour.
MUTATIONS = {
    'no-writer-check': ('if environment.isLegacyAppRunning() { throw Failure.legacyAppRunning }\n        try checkSourceReadable', 'try checkSourceReadable', 'refusals'),
    'no-readable-check': ('try checkSourceReadable(stores)\n', '\n', 'refusals'),
    'symlinks-followed': ('open(file.path, O_RDONLY | O_NOFOLLOW)', 'open(file.path, O_RDONLY)', 'symlinked source'),
    'no-parent-readable-check': ('if fm.fileExists(atPath: parent.path), access(parent.path, R_OK | X_OK) != 0 {', 'if parent.path.isEmpty {', 'refusals'),
    'unreadable-root-not-offered': ('            || (fm.fileExists(atPath: data.path) && access(data.path, R_OK | X_OK) != 0)\n', '', 'unreadable source root'),
    'no-space-check': ('if available < required { throw Failure.insufficientSpace(required: required, available: available) }', '', 'refusals'),
    'no-occupied-check': ('try checkDestinationUnoccupied(journal)\n', '\n', 'occupied destination'),
    'wal-ignored': ('databaseFileSuffixes = ["", "-wal", "-journal"]', 'databaseFileSuffixes = [""]', 'converted'),
    'wal-ignored-for-app-store': ('for suffix in Self.databaseFileSuffixes where fm.fileExists(atPath: source.path + suffix) {', 'for suffix in Self.databaseFileSuffixes where fm.fileExists(atPath: source.path + suffix) && (store.id != "appData" || suffix.isEmpty) {', 'converted'),
    'sqlite-opens-source': ('sqlite3_open_v2(database.path, &from, SQLITE_OPEN_READWRITE, nil)', 'sqlite3_open_v2(source.path, &from, SQLITE_OPEN_READONLY, nil)', 'converted'),
    'no-validation': ('try validate(store, at: target)\n', '\n', 'corrupt stores'),
    'app-store-unvalidated': ('try validateAppStore(at: target, invalid: invalid)', '_ = invalid', 'store with another schema'),
    'restart-instead-of-resume': ('if let existing, existing.commitStarted || existing.fingerprint == fingerprint {', 'if let existing, existing.fingerprint.isEmpty {', 'kill at each stage'),
    'validated-recopied': ('for store in available where journal.states[store.id] != .validated {', 'for store in available {', 'kill at each stage'),
    'no-marker': ('try writeMarker("converted")', '', 'converted'),
    'fresh-no-marker': ('try writeMarker("startedFresh")', '', 'start fresh'),
    'all-preferences': ('(environment.legacyPreferences() ?? [:]).filter { Self.allowedPreferences.contains($0.key) }', '(environment.legacyPreferences() ?? [:])', 'converted'),
    'raw-ai-config': ('try JSONEncoder().encode(configuration).write(to: target, options: .atomic)', '_ = configuration\n            try data.write(to: target, options: .atomic)', 'converted'),
    'no-source-recheck': ('guard try self.fingerprint(of: available) == journal.fingerprint else { throw Failure.sourceChanged }', '', 'source changes'),
    'stale-after-source-change': ('existing.commitStarted || existing.fingerprint == fingerprint', 'existing.commitStarted || !existing.fingerprint.isEmpty', 'source changes'),
    'mixed-snapshot-after-commit': ('existing.commitStarted || existing.fingerprint == fingerprint', 'existing.fingerprint == fingerprint', 'source changes after commit started'),
    'no-writer-recheck': ('if environment.isLegacyAppRunning() { throw Failure.legacyAppRunning }\n            guard try self.fingerprint', 'guard try self.fingerprint', 'writer starts mid-run'),
    'rename-recovery-removed': ('} else if !fm.fileExists(atPath: destination.path) {\n                throw Failure.interrupted\n            }', '} else {\n                throw Failure.interrupted\n            }', 'disk exhaustion'),
    'fresh-removes-unowned': ('if journal.states[store.id] == .committed || !fm.fileExists(atPath: staged(store).path) {', 'if true {', 'same-named foreign data during resume'),
    'fresh-keeps-partial': ('guard let journal = readJournal(), journal.commitStarted else { return }', 'guard let journal = readJournal(), journal.fingerprint.isEmpty else { return }', 'start fresh after partial conversion'),
    'fresh-kill-keeps-partial': ('if markerOutcome() != "startedFresh" || (try? removeConverted()) != nil {', 'if true {', 'kill during start fresh'),
    'ai-config-mode': ('try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)\n', '\n', 'converted'),
    'overwrites-occupied': ('if fm.fileExists(atPath: destination.path) { throw Failure.destinationOccupied }\n                ', 'try? fm.removeItem(at: destination)\n                ', 'same-named foreign data during resume'),
    'stock-menu-kept': ('menuBar.set(Self.noticeMenu())', '_ = Self.noticeMenu()', 'stock menu held during the notice'),
    'stock-menu-not-restored': ('self.menuBar.set(self.stockMenu)\n', '\n', 'stock menu held during the notice'),
    'stock-menu-restored-late': ('self.menuBar.set(self.stockMenu)\n                        self.finished()', 'self.finished()\n                        self.menuBar.set(self.stockMenu)', 'stock menu held during the notice'),
    'notice-menu-has-no-quit': ('action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"', 'action: nil, keyEquivalent: "q"', 'stock menu held during the notice'),
    'flow-hides-failure': ('self.phase = .failed(failure.message)', '_ = failure\n                        self.finished()', 'flow'),
    'notice-no-sign-in': ('you will need to sign in to websites again', 'your websites stay as they are', 'notice'),
    'verification-offers': ('legacySupport = synthetic?.appendingPathComponent("Application Support", isDirectory: true)', 'legacySupport = synthetic?.appendingPathComponent("Application Support", isDirectory: true) ?? canonical', 'configuration'),
    'gate-removed': ('self.prepareData { [weak self] in\n                guard let self, !self.returned, !self.failed else { return }\n                self.openDestination()\n            }', 'self.openDestination()', 'startup gate'),
    'gate-ignores-exit': ('guard let self, !self.returned, !self.failed else { return }\n                self.openDestination()', 'guard let self else { return }\n                self.openDestination()', 'startup gate'),
}


def run(command, log, **kwargs):
    result = subprocess.run(command, capture_output=True, text=True, **kwargs)
    log.write_text(result.stdout + result.stderr)
    return result


def classify_preferences():
    source = core.read_text()
    block = re.search(r'allowedPreferences: Set<String> = \[(.*?)\]', source, re.S)
    if not block:
        raise SystemExit('allowedPreferences not found')
    allowed = set(re.findall(r'"([^"]+)"', block.group(1)))
    keys = set()
    for folder in ['Nook', 'App', 'Packages', 'Navigation', 'UI', 'CommandPalette', 'Onboarding']:
        for path in (root / folder).rglob('*.swift'):
            if '/.build/' in str(path) or '/Tests/' in str(path) or '/Checks/' in str(path) or path == core:
                continue
            keys.update(re.findall(r'"(settings\.[A-Za-z]+)"', path.read_text(errors='ignore')))
    unclassified = keys - allowed - set(EXCLUDED_PREFERENCES)
    if unclassified:
        raise SystemExit(f'unclassified preference keys: {sorted(unclassified)}')
    overlap = allowed & set(EXCLUDED_PREFERENCES)
    if overlap:
        raise SystemExit(f'preference keys both copied and excluded: {sorted(overlap)}')


def extract_persistence():
    source = (root / 'Nook/Managers/BrowserManager/BrowserManager.swift').read_text()
    start = source.index('@MainActor\nfinal class Persistence {')
    end = source.index('@MainActor\nclass BrowserManager', start)
    # The real SpaceGradient needs NookUI; LegacyTabEntities only reads it as a default, and no fixture row uses it.
    gradient = 'struct SpaceGradient { static var `default`: SpaceGradient { SpaceGradient() }; var encoded: Data? { Data() } }\n\n'
    return 'import Foundation\nimport OSLog\nimport SwiftData\n\n' + gradient + source[start:end]


def build(mutation=None):
    generated = out / 'generated'
    shutil.rmtree(generated, ignore_errors=True)
    generated.mkdir(parents=True)
    modules, objects = ['-I', str(root / 'Packages/BarkEngine/BarkEngine.xcframework/macos-x86_64/Headers')], []
    for package in ['NookSettings', 'NookTabsCore']:
        scratch = out / 'packages' / package
        p = run(['swift', 'build', '--package-path', str(root / 'Packages' / package), '--scratch-path', str(scratch), '--jobs', '2'],
                out / f'build-{package}.log')
        if p.returncode:
            print(p.stdout + p.stderr)
            raise SystemExit(p.returncode)
        debug = scratch / 'x86_64-apple-macosx/debug'
        modules += ['-I', str(debug / 'Modules')]
        objects += sorted(str(o) for o in (debug / f'{package}.build').glob('*.o'))

    core_text = core.read_text().replace('import NookWeb\n', '')
    startup_text = startup.read_text()
    if mutation:
        old, new, _ = MUTATIONS[mutation]
        if old in core_text:
            core_text = core_text.replace(old, new)
        elif old in startup_text:
            startup_text = startup_text.replace(old, new)
        else:
            raise SystemExit(f'mutation {mutation}: source text not found')
    (generated / 'ChromiumDataConversion.swift').write_text(core_text)
    (generated / 'ChromiumStartup.swift').write_text(startup_text)
    (generated / 'Persistence.swift').write_text(extract_persistence())

    binary = out / 'chromium-data-conversion-check'
    sources = [
        generated / 'ChromiumDataConversion.swift', generated / 'ChromiumStartup.swift', generated / 'Persistence.swift',
        tests / 'Main.swift',
        root / 'Nook/Models/Profile/ProfileEntity.swift',
        root / 'Nook/Models/Legacy/LegacyTabEntities.swift',
        root / 'Nook/Models/Extension/ExtensionModels.swift',
        root / 'Nook/Managers/DownloadManager/DownloadHistoryStore.swift',
        root / 'Packages/NookWeb/Sources/NookWeb/HistoryEntity.swift',
        root / 'Packages/NookWeb/Sources/NookWeb/HistoryIndex.swift',
        root / 'Packages/NookWeb/Sources/NookWeb/HistoryTextIndex.swift',
        root / 'Packages/NookWeb/Sources/NookWeb/PaletteText.swift',
    ]
    command = ['swiftc', '-swift-version', '5', '-target', 'x86_64-apple-macosx15.5', '-parse-as-library', '-j2',
               *modules, *(str(s) for s in sources), *objects, '-o', str(binary)]
    (out / 'command.json').write_text(json.dumps(command, indent=2))
    p = run(command, out / 'compile.log')
    if p.returncode:
        print(p.stdout + p.stderr)
        raise SystemExit(p.returncode)
    undefined = subprocess.run(['nm', '-u', str(binary)], capture_output=True, text=True).stdout
    if 'SecItem' in undefined:
        raise SystemExit('the test binary links the real keychain')
    return binary


def clean_work():
    # A failed run can leave the unreadable-source fixtures behind.
    subprocess.run(['chmod', '-R', 'u+rwx', work_dir], capture_output=True)
    shutil.rmtree(work_dir, ignore_errors=True)


def run_tests(binary, scenario=None):
    clean_work()
    home = out / 'home'
    shutil.rmtree(home, ignore_errors=True)
    home.mkdir(parents=True)
    env = {**os.environ, 'HOME': str(home), 'CFFIXED_USER_HOME': str(home)}
    if scenario:
        env['CONVERSION_SCENARIO'] = scenario
    try:
        p = run([str(binary), work_dir], out / 'run.log', env=env, timeout=540)
        print(p.stdout + p.stderr)
        code = p.returncode
    except subprocess.TimeoutExpired:
        print('test run timed out')
        code = 124
    explicit = 'ee.qdo.nook.chromium-verification.' + hashlib.sha256(f'{work_dir}/explicit-root'.encode()).hexdigest()
    for domain in [*test_domains, explicit, explicit + '.conversion-probe']:
        subprocess.run(['defaults', 'delete', domain], capture_output=True)
        (Path.home() / 'Library/Preferences' / (domain + '.plist')).unlink(missing_ok=True)
    clean_work()
    return code


def main():
    out.mkdir(parents=True, exist_ok=True)
    arguments = sys.argv[1:]
    if arguments == ['--list-mutations']:
        print('\n'.join(MUTATIONS))
        return
    if arguments == ['--red']:
        binary = build()
        passing = []
        for scenario in re.findall(r'selected\("([^"]+)"\)', (tests / 'Main.swift').read_text()):
            code = run_tests(binary, scenario)
            print(f'red {scenario}: exit {code}')
            if not code:
                passing.append(scenario)
        print('passing before implementation:', passing)
        raise SystemExit(1 if passing else 0)
    classify_preferences()
    if len(arguments) == 2 and arguments[0] == '--scenario':
        raise SystemExit(run_tests(build(), arguments[1]))
    if arguments == ['--only-build']:
        print(build())
        return
    if arguments and arguments[0] == '--mutation':
        survivors = []
        for name in arguments[1:] or MUTATIONS:
            code = run_tests(build(name), MUTATIONS[name][2])
            reason = next((line for line in (out / 'run.log').read_text().splitlines() if line.startswith('FAIL') or 'Fatal error' in line), 'no failure line')
            print(f'mutation {name}: {"caught" if code else "NOT CAUGHT"} by {MUTATIONS[name][2]!r} (exit {code}): {reason}', flush=True)
            if not code:
                survivors.append(name)
        raise SystemExit(1 if survivors else 0)
    raise SystemExit(run_tests(build()))


main()
