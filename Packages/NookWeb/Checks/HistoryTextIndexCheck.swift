// Licensed under GPL-3.0. See LICENSE.
//
//  HistoryTextIndexCheck.swift
//  Nook
//
//  Page text index check. Compile the shipped SQLite index directly:
//
//    swiftc -parse-as-library Packages/NookWeb/Sources/NookWeb/HistoryTextIndex.swift \
//           Packages/NookWeb/Checks/HistoryTextIndexCheck.swift -o /tmp/text-index-check && /tmp/text-index-check
//

import Foundation
import SQLite3

@main
struct HistoryTextIndexCheck {
    static func main() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let index = HistoryTextIndex(fileURL: dir.appendingPathComponent("History/page-text.sqlite"))

        let profile = UUID()

        // Nothing is created by a read or a delete.
        do { let r = await index.search("anything", profile: profile, limit: 3); precondition(r.isEmpty) }
        await index.delete(url: "https://a.example/", profile: profile)
        precondition(!FileManager.default.fileExists(atPath: index.fileURL.path))

        let old = Date(timeIntervalSince1970: 1_700_000_000)
        await index.record(url: "https://a.example/", profile: profile, title: "Kettle review", body: "The thermostat holds water at eighty degrees. Café crème.", visitedAt: old)
        await index.record(url: "https://b.example/", profile: profile, title: "Bikes", body: "Gear ratios and the thermostat of nothing.", visitedAt: old.addingTimeInterval(60))

        // Every word is a prefix term, in any order, diacritics folded.
        do { let r = await index.search("thermo", profile: profile, limit: 5); precondition(r.count == 2) }
        do { let r = await index.search("eigh therm", profile: profile, limit: 5); precondition(r.map(\.url) == ["https://a.example/"]) }
        do { let r = await index.search("cafe creme", profile: profile, limit: 5); precondition(r.map(\.url) == ["https://a.example/"]) }
        do { let r = await index.search("kett", profile: profile, limit: 5); precondition(r.first?.snippet.contains("Kettle") == true) }
        do { let r = await index.search("thermostat", profile: profile, limit: 1); precondition(r.count == 1) }

        // FTS syntax in the query is literal text, never an error.
        for hostile in ["foo\" OR", "\"", "* NEAR(", "AND OR NOT", "a:b", "(-^)", "thermo\""] {
            _ = await index.search(hostile, profile: profile, limit: 5)
        }
        do { let r = await index.search("thermo\"", profile: profile, limit: 5); precondition(r.count == 2) }
        precondition(HistoryTextIndex.matchExpression(for: "  \" * ") == nil)

        // A revisit replaces the row.
        await index.record(url: "https://a.example/", profile: profile, title: "Kettle review", body: "Now about teapots.", visitedAt: old.addingTimeInterval(120))
        do { let r = await index.search("eighty", profile: profile, limit: 5); precondition(r.isEmpty) }
        do { let r = await index.search("teapot", profile: profile, limit: 5); precondition(r.map(\.url) == ["https://a.example/"]) }
        do { let r = await index.search("thermo", profile: profile, limit: 5); precondition(r.map(\.url) == ["https://b.example/"]) }

        // Deletion, by URL and by what history still holds.
        await index.delete(url: "https://b.example/", profile: profile)
        do { let r = await index.search("gear", profile: profile, limit: 5); precondition(r.isEmpty) }
        await index.record(url: "https://c.example/", profile: profile, title: "C", body: "Gear again", visitedAt: old)
        await index.retain(only: [PageTextKey(profile: profile, url: "https://c.example/")], profile: profile)
        do { let r = await index.search("teapot", profile: profile, limit: 5); precondition(r.isEmpty) }
        do { let r = await index.search("gear", profile: profile, limit: 5); precondition(r.map(\.url) == ["https://c.example/"]) }

        await index.erase()
        precondition(!FileManager.default.fileExists(atPath: index.fileURL.path))
        do { let r = await index.search("gear", profile: profile, limit: 5); precondition(r.isEmpty) }
        // A write after erase starts a fresh file.
        await index.record(url: "https://d.example/", profile: profile, title: "D", body: "fresh", visitedAt: old)
        do { let r = await index.search("fresh", profile: profile, limit: 5); precondition(r.count == 1) }

        // Version 0 had no owner. Upgrading drops only this derived store.
        let legacy = dir.appendingPathComponent("History/legacy.sqlite")
        var handle: OpaquePointer?
        precondition(sqlite3_open(legacy.path, &handle) == SQLITE_OK)
        precondition(sqlite3_exec(handle, """
            CREATE TABLE pages(url TEXT PRIMARY KEY, title TEXT, body TEXT, visitedAt REAL);
            CREATE VIRTUAL TABLE page_fts USING fts5(title, body, content='pages', content_rowid='rowid');
            INSERT INTO pages VALUES('https://shared.invalid/', 'Historical', 'legacytoken', 1);
            INSERT INTO page_fts VALUES('Historical', 'legacytoken');
            """, nil, nil, nil) == SQLITE_OK)
        precondition(sqlite3_close(handle) == SQLITE_OK)
        let rebuilt = HistoryTextIndex(fileURL: legacy)
        let other = UUID(), shared = "https://shared.invalid/"
        do { let rows = await rebuilt.search("legacytoken", profile: profile, limit: 5); precondition(rows.isEmpty) }
        await rebuilt.record(url: shared, profile: profile, title: "Work", body: "worktoken", visitedAt: old)
        await rebuilt.record(url: shared, profile: other, title: "Personal", body: "personaltoken", visitedAt: old)
        do { let rows = await rebuilt.search("worktoken", profile: profile, limit: 5); precondition(rows.map(\.title) == ["Work"]) }
        do { let rows = await rebuilt.search("worktoken", profile: other, limit: 5); precondition(rows.isEmpty) }
        await rebuilt.delete(url: shared, profile: profile)
        do { let rows = await rebuilt.search("personaltoken", profile: other, limit: 5); precondition(rows.map(\.title) == ["Personal"]) }
        let reopened = HistoryTextIndex(fileURL: legacy)
        do { let rows = await reopened.search("personaltoken", profile: other, limit: 5); precondition(rows.count == 1) }

        print("HistoryTextIndexCheck passed")
    }
}
