// Licensed under GPL-3.0. See LICENSE.
// Read-only support for a caller that explicitly selects a legacy Downloads.json file.

import Foundation

struct DownloadRecord: Decodable, Equatable {
    /// Without its query, fragment or credentials: signed links carry tokens there.
    var originalURL: URL
    var path: String
    var date: Date
    var size: Int64?
    var renamedFrom: String?
    /// The profile (data store id) the download came from; nil for records from before profiles.
    var profileID: UUID?
}

enum DownloadHistoryStore {
    static func strippingQuery(_ url: URL) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.query = nil
        parts.fragment = nil
        parts.user = nil
        parts.password = nil
        return parts.url
    }

    static func load(from url: URL, completion: @escaping ([DownloadRecord]) -> Void) {
        queue.async {
            var kept: [DownloadRecord] = []
            if let data = try? Data(contentsOf: url),
               let records = try? JSONDecoder().decode([DownloadRecord].self, from: data) {
                kept = records.compactMap { record in
                    guard FileManager.default.fileExists(atPath: record.path),
                          let origin = strippingQuery(record.originalURL) else { return nil }
                    var cleaned = record
                    cleaned.originalURL = origin
                    return cleaned
                }
            }
            DispatchQueue.main.async { completion(kept) }
        }
    }

    private static let queue = DispatchQueue(label: "ee.qdo.bark.legacy-download-history", qos: .utility)
}
