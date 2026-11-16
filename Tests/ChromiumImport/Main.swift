// Licensed under GPL-3.0. See LICENSE.
// check.py compiles the shipped importers and writes Arc, Chrome and Dia fixtures; nothing here reads a real browser's data.
import Foundation
import SQLite3

@main @MainActor enum Check {
    static let arguments = CommandLine.arguments
    static let root = URL(fileURLWithPath: arguments[arguments[1] == "measure" ? 2 : 1], isDirectory: true)

    static func main() async throws {
        if arguments[1] == "measure" { return try await measure(URL(fileURLWithPath: arguments[2], isDirectory: true), visits: Int(arguments[3])!) }
        try verificationSources()
        await arcAndDia()
        chromeProfilesAndBookmarks()
        try await chromeHistory()
        try await modelImport()
        print("Import: every check passed")
    }

    static func urls(_ value: Any) -> [URL] {
        Mirror(reflecting: value).children.flatMap { child -> [URL] in
            if let url = child.value as? URL { return [url] }
            return urls(child.value)
        }
    }

    /// I1: a verification launch's importer can only read under its own data directory.
    static func verificationSources() throws {
        let run = URL(fileURLWithPath: "/private/tmp/bark-import-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: run) }
        let configuration = try ChromiumStartupConfiguration(arguments: [
            "Bark", "--barc-app-data-dir=\(run.path)", "--barc-app-profile=\(UUID().uuidString)"])
        let importer = ImportManager(configuration: configuration)
        let read = urls(importer.sources)
        precondition(read.count == 3 && read.contains(importer.sources.chrome), "Arc, Chrome and Dia each have a source: \(read)")
        for url in read + [importer.workDirectory] {
            precondition(url.standardizedFileURL.path.hasPrefix(configuration.root.path + "/"),
                         "a verification run reads and copies only under its own data directory: \(url.path)")
        }
        precondition(importer.sources.chrome.path == configuration.root.appendingPathComponent("Import/Chrome").path,
                     "Chrome's fixture is laid out under Import/Chrome")
        let stale = importer.workDirectory.appendingPathComponent("earlier-run/History")
        try FileManager.default.createDirectory(at: stale.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("left by a run that quit".utf8).write(to: stale)
        _ = ImportManager(configuration: configuration)
        precondition(!FileManager.default.fileExists(atPath: importer.workDirectory.path),
                     "a copy left by a run that quit mid-import is gone at the next launch")
    }

    /// I2: Chrome's profiles in the person's order, and each one's bookmark tree, web pages only.
    static func chromeProfilesAndBookmarks() {
        let importer = ImportManager(sources: .fixtures(in: root), workDirectory: root.appendingPathComponent("App/ImportCopies"))
        let profiles = importer.chromiumProfiles(.chrome)
        precondition(profiles.found == [ChromiumProfile(directory: "Profile 1", name: "Work"), ChromiumProfile(directory: "Default", name: "Fixture Person")],
                     "Chrome's profiles in the person's order: \(profiles.found)")
        precondition(profiles.missing == [ChromiumProfile(directory: "Profile 7", name: "Gone")], "a profile Local State names without its folder is left out: \(profiles.missing)")
        let person = importer.chromeBookmarks(profiles.found[1])
        let expected: [ArcNode] = [
            .tab(url: "https://fixture.test/bar", title: "Fixture Bar", customTitle: nil),
            .folder(title: "Reading", children: [
                .tab(url: "https://fixture.test/read", title: "Read", customTitle: nil),
                .folder(title: "Deep", children: [.tab(url: "https://fixture.test/deep", title: "Deep", customTitle: nil)])]),
            .folder(title: "Other Bookmarks", children: [.tab(url: "https://fixture.test/other", title: "Other", customTitle: nil)]),
        ]
        precondition(person == expected, "the bookmark bar, then Other Bookmarks, in order and nesting, web pages only: \(person)")
        precondition(importer.chromeBookmarks(profiles.found[0]) == [.tab(url: "https://fixture.test/board", title: "Work Board", customTitle: nil),
                                                                     .tab(url: "https://fixture.test/account", title: "Work Account", customTitle: nil)],
                     "a signed-in profile's account bookmarks follow its local ones")
        precondition((try? parseChromiumBookmarks(Data("{\"roots\": ".utf8))) == nil, "malformed JSON is refused")
        let errors = ImportManager(sources: .fixtures(in: URL(fileURLWithPath: arguments[2], isDirectory: true)), workDirectory: root.appendingPathComponent("App/ImportCopies"))
        let broken = errors.chromiumProfiles(.chrome).found
        precondition(broken.map(\.name) == ["Broken", "Empty"], "profiles whose files are malformed or missing are still profiles: \(broken)")
        precondition(errors.chromiumProfiles(.chrome).missing.isEmpty, "a profile folder outside the browser's own folder is no profile")
        precondition(broken.allSatisfy { errors.chromeBookmarks($0).isEmpty }, "and bring no bookmarks")
        precondition(ImportManager(sources: .fixtures(in: root.appendingPathComponent("nothing")), workDirectory: root.appendingPathComponent("App/ImportCopies"))
            .chromiumProfiles(.chrome) == ChromiumProfiles(found: [], missing: []), "a Mac without Chrome has no Chrome profiles")
    }

    static let now = TimeInterval(arguments[4])!
    static func daysAgo(_ days: Double) -> Date { Date(timeIntervalSince1970: now - days * 86_400) }

    final class Batches: @unchecked Sendable {
        var visits: [[ChromiumVisit]] = []
        var progress: [(Int, Int)] = []
    }

    /// I3: History is read from a copy, so a locked file reads all the same and is never touched.
    static func chromeHistory() async throws {
        let work = root.appendingPathComponent("App/ImportCopies", isDirectory: true)
        let person = root.appendingPathComponent("Import/Chrome/Default/History")
        let locked = URL(fileURLWithPath: arguments[5])
        func fingerprint(_ url: URL) throws -> (Data, Date) {
            (try Data(contentsOf: url), try url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate!)
        }
        let before = try [person, locked].map(fingerprint)

        var db: OpaquePointer?
        var statement: OpaquePointer?
        precondition(sqlite3_open_v2(locked.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        let prepared = sqlite3_prepare_v2(db, "SELECT count(*) FROM urls", -1, &statement, nil)
        precondition((prepared == SQLITE_OK ? sqlite3_step(statement) : prepared) == SQLITE_BUSY, "the fixture is held locked, as Chrome holds its History")
        sqlite3_finalize(statement)
        sqlite3_close(db)

        let batches = Batches()
        let count = try await readChromiumHistory(person, workDirectory: work, batchSize: 2) { batch, read, total in
            batches.visits.append(batch)
            batches.progress.append((read, total))
        }
        let expected = [ChromiumVisit(url: "https://fixture.test/news", title: "Fixture News", date: daysAgo(3)),
                        ChromiumVisit(url: "https://fixture.test/docs", title: "Fixture Docs", date: daysAgo(2)),
                        ChromiumVisit(url: "https://fixture.test/news", title: "Fixture News", date: daysAgo(1))]
        precondition(batches.visits.flatMap { $0 } == expected && count == 3,
                     "every web visit Chrome's own history shows, oldest first, with its title and time: \(batches.visits)")
        precondition(batches.visits.map(\.count) == [2, 1] && batches.progress.map(\.0) == [2, 3] && batches.progress.allSatisfy { $0.1 == 3 },
                     "in batches, with progress against the total: \(batches.progress)")

        let work2 = Batches()
        _ = try await readChromiumHistory(locked, workDirectory: work) { batch, _, _ in work2.visits.append(batch) }
        precondition(work2.visits.flatMap { $0 } == [ChromiumVisit(url: "https://fixture.test/work-wiki", title: "Work Wiki", date: daysAgo(4))],
                     "a History file the browser holds locked reads through its copy: \(work2.visits)")
        let after = try [person, locked].map(fingerprint)
        precondition(zip(before, after).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }, "the browser's files keep their bytes and modification time")
        precondition(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).isEmpty, "and no copy is left behind")

        let errors = URL(fileURLWithPath: arguments[2], isDirectory: true).appendingPathComponent("Import/Chrome")
        do {
            _ = try await readChromiumHistory(errors.appendingPathComponent("Default/History"), workDirectory: work) { _, _, _ in }
            preconditionFailure("a file that is not a History database is refused")
        } catch let error as ChromiumHistoryError {
            precondition(error == .unreadable, "as unreadable: \(error)")
        }
        let none = try await readChromiumHistory(errors.appendingPathComponent("Profile 1/History"), workDirectory: work) { _, _, _ in
            preconditionFailure("a profile with no History has no visits")
        }
        precondition(none == 0, "a profile with no History has no visits")
        precondition(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).isEmpty, "no copy is left after an error")

        let cancelled = Batches()
        let task = Task {
            try await readChromiumHistory(person, workDirectory: work, batchSize: 1) { batch, _, _ in
                cancelled.visits.append(batch)
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do {
            _ = try await task.value
            preconditionFailure("a cancelled read stops")
        } catch is CancellationError {}
        precondition(cancelled.visits.count == 1, "between batches: \(cancelled.visits.count)")
        precondition(((try? FileManager.default.contentsOfDirectory(atPath: work.path)) ?? []).isEmpty, "and leaves no copy")
    }

    static func arcAndDia() async {
        let sources = ImportManager.Sources.fixtures(in: root)
        let importer = ImportManager(sources: sources, workDirectory: root.appendingPathComponent("App/ImportCopies"))

        let arc = await importer.importArcSidebarData()
        precondition(arc.spaces.map(\.title) == ["Fixture Space", "Arc Work Space", "Fixture Errands"], "Arc's spaces come in: \(arc.spaces.map(\.title))")
        let space = arc.spaces[0]
        precondition(space.emoji == "🧪" && space.accentHex != nil, "with their icon and colour")
        precondition(space.pinned == [.tab(url: "https://fixture.test/pinned", title: "Pinned", customTitle: "Mine"),
                                      .folder(title: "Reading", children: [.tab(url: "https://fixture.test/read", title: "Read", customTitle: nil)])],
                     "pinned tabs and folders in order: \(space.pinned)")
        precondition(space.unpinned == [.tab(url: "https://fixture.test/today", title: "Today", customTitle: nil)], "and Today's tabs")
        precondition(arc.favorites["default"] == [.tab(url: "https://fixture.test/favorite", title: "Favorite", customTitle: nil)], "and the profile's favorites")
        precondition(arc.profileNames["default"] == "Fixture Person" && arc.profileNames["Profile 1"] == "Arc Work", "each profile keeps Arc's name")

        let dia = await importer.importDiaData()
        precondition(dia.favoriteTabs.map(\.url) == ["https://fixture.test/dia-favorite"] && dia.windowTabs.map(\.url) == ["https://fixture.test/dia-window"],
                     "Dia's favorites and window tabs come in")

        let empty = ImportManager(sources: .fixtures(in: root.appendingPathComponent("nothing")), workDirectory: root.appendingPathComponent("App/ImportCopies"))
        let nothing = await empty.importArcSidebarData(), noDia = await empty.importDiaData()
        precondition(nothing.spaces.isEmpty && noDia.windowTabs.isEmpty, "a source with nothing in it imports nothing")
        let tabs = root.appendingPathComponent("App/Tabs", isDirectory: true)
        try? FileManager.default.createDirectory(at: tabs, withIntermediateDirectories: true)
        func files() -> Set<String> {
            Set((FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String]) ?? [])
        }
        let before = files()
        importer.saveArcMembershipCard(nextTo: tabs)
        let card = root.appendingPathComponent("App/ArcMembershipCard.json")
        let saved = (try? Data(contentsOf: card)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        precondition(saved?["memberNumber"] as? Int == 42 && saved?["name"] as? String == "Fixture Member",
                     "Arc's member card, with the person's Arc name, lands beside the run's tabs")
        precondition(files().subtracting(before) == ["App/ArcMembershipCard.json"], "and nothing else is written in the run")
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        for name in ["ee.qdo.bark", "Nook"] {
            precondition(!FileManager.default.fileExists(atPath: support.appendingPathComponent(name).appendingPathComponent("ArcMembershipCard.json").path),
                         "nor in Application Support's \(name) folder")
        }
    }
}
