// Licensed under GPL-3.0. See LICENSE.
// swiftc Nook/Managers/DownloadManager/DownloadHistoryStore.swift scripts/tests/DownloadHistoryCheck.swift -o /tmp/dlhist && /tmp/dlhist

import Foundation

@main
struct DownloadHistoryCheck {
    static func main() {
        let url = URL(string: "https://user:pw@cdn.example.com/f.zip?token=1#frag")!
        precondition(DownloadHistoryStore.strippingQuery(url)?.absoluteString == "https://cdn.example.com/f.zip")

        // Records written before profiles existed still decode.
        let old = #"[{"originalURL":"https:\/\/a.com\/x","path":"\/x","date":0}]"#.data(using: .utf8)!
        let decoded = try? JSONDecoder().decode([DownloadRecord].self, from: old)
        precondition(decoded?.first?.profileID == nil && decoded?.count == 1, "old record failed to decode")

        print("DownloadHistoryCheck passed")
    }
}
