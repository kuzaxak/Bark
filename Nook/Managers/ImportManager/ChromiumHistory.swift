// Licensed under GPL-3.0. See LICENSE.
//
//  ChromiumHistory.swift
//  Nook
//

import Foundation
import SQLite3

struct ChromiumVisit: Equatable, Sendable {
    let url: String
    let title: String
    let date: Date
}

enum ChromiumHistoryError: Error, Equatable {
    /// The file could not be copied, opened or queried as a Chromium History database.
    case unreadable
}

/// Chromium stores times as microseconds since 1601-01-01 UTC.
private let windowsEpochOffset: TimeInterval = 11_644_473_600

/// The visits Chromium's own history page shows: the last page of a redirect chain
/// (`PAGE_TRANSITION_CHAIN_END`), in the main frame, not keyword-generated
/// (`TransitionIsVisible` in components/history/core/browser/visit_database.cc), web pages only.
private let visibleVisits = """
    FROM visits JOIN urls ON urls.id = visits.url
    WHERE (visits.transition & 536870912) != 0 AND (visits.transition & 255) NOT IN (3, 4, 10)
      AND (urls.url LIKE 'http://%' OR urls.url LIKE 'https://%')
    """

/// Reads a Chromium profile's `History`, oldest visit first, `batchSize` at a time, from a copy
/// in `workDirectory`. The browser keeps the file locked while it runs, and the copy means it is
/// never opened or written; the copy goes when reading ends, however it ends. Returns how many
/// visits were read; a profile with no History has none.
func readChromiumHistory(_ file: URL, workDirectory: URL, batchSize: Int = 100,
                         onBatch: @Sendable ([ChromiumVisit], _ read: Int, _ total: Int) async -> Void) async throws -> Int {
    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: file.path) else { return 0 }
    let directory = workDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? fileManager.removeItem(at: directory) }
    let copy = directory.appendingPathComponent("History")
    do {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        // Chromium uses a TRUNCATE rollback journal, or a write-ahead log where that is enabled.
        for suffix in ["-journal", "-wal"] where fileManager.fileExists(atPath: file.path + suffix) {
            try fileManager.copyItem(atPath: file.path + suffix, toPath: copy.path + suffix)
        }
        try fileManager.copyItem(at: file, to: copy)
    } catch {
        throw ChromiumHistoryError.unreadable
    }

    var db: OpaquePointer?
    defer { sqlite3_close(db) }
    // SQLite rolls back a journal left mid-transaction only on a connection that can write.
    guard sqlite3_open_v2(copy.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else { throw ChromiumHistoryError.unreadable }
    var count: OpaquePointer?
    defer { sqlite3_finalize(count) }
    guard sqlite3_prepare_v2(db, "SELECT count(*) " + visibleVisits, -1, &count, nil) == SQLITE_OK,
          sqlite3_step(count) == SQLITE_ROW else { throw ChromiumHistoryError.unreadable }
    let total = Int(sqlite3_column_int64(count, 0))

    var rows: OpaquePointer?
    defer { sqlite3_finalize(rows) }
    guard sqlite3_prepare_v2(db, "SELECT urls.url, urls.title, visits.visit_time " + visibleVisits + " ORDER BY visits.visit_time, visits.id",
                             -1, &rows, nil) == SQLITE_OK else { throw ChromiumHistoryError.unreadable }
    var read = 0
    var batch: [ChromiumVisit] = []
    while true {
        try Task.checkCancellation()
        let step = sqlite3_step(rows)
        if step == SQLITE_ROW {
            let url = sqlite3_column_text(rows, 0).map { String(cString: $0) } ?? ""
            let title = sqlite3_column_text(rows, 1).map { String(cString: $0) } ?? ""
            let microseconds = sqlite3_column_int64(rows, 2)
            batch.append(ChromiumVisit(url: url, title: title, date: Date(timeIntervalSince1970: TimeInterval(microseconds) / 1_000_000 - windowsEpochOffset)))
            guard batch.count == batchSize else { continue }
        } else if step != SQLITE_DONE {
            throw ChromiumHistoryError.unreadable
        }
        if !batch.isEmpty {
            read += batch.count
            await onBatch(batch, read, total)
            batch.removeAll(keepingCapacity: true)
        }
        if step == SQLITE_DONE { return read }
    }
}
