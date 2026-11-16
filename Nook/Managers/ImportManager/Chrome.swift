// Licensed under GPL-3.0. See LICENSE.
//
//  Chrome.swift
//  Nook
//

import Foundation

/// A profile a Chromium browser lists in its `Local State`.
struct ChromiumProfile: Equatable {
    /// The profile's folder in the browser's user data folder: "Default", "Profile 1".
    let directory: String
    let name: String
}

/// The profiles a browser lists, split by whether their folder is on disk.
struct ChromiumProfiles: Equatable {
    var found: [ChromiumProfile]
    var missing: [ChromiumProfile]
}

/// Profiles from a Chromium `Local State`: `profile.info_cache` keyed by folder, in the order
/// of `profile.profiles_order`, then any it leaves out by folder name.
func parseChromiumProfiles(_ data: Data) -> [ChromiumProfile] {
    let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    let profile = root?["profile"] as? [String: Any]
    let cache = profile?["info_cache"] as? [String: Any] ?? [:]
    var directories: [String] = []
    for directory in (profile?["profiles_order"] as? [String] ?? []) + cache.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending })
    where cache[directory] != nil && !directories.contains(directory) && isFolderName(directory) {
        directories.append(directory)
    }
    return directories.map { directory in
        let name = ((cache[directory] as? [String: Any])?["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return ChromiumProfile(directory: directory, name: name ?? directory)
    }
}

/// One folder inside the user data folder, never a path out of it.
func isFolderName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/")
}

/// The three bookmark roots of a Chromium bookmarks file, web pages only, folders kept.
struct ChromiumBookmarks: Equatable {
    var bar: [ArcNode] = []
    var other: [ArcNode] = []
    var mobile: [ArcNode] = []

    /// The bookmark bar's items, then Other and Mobile Bookmarks each as a folder of its own.
    var folderContents: [ArcNode] {
        bar + [("Other Bookmarks", other), ("Mobile Bookmarks", mobile)].compactMap { title, children in
            children.isEmpty ? nil : .folder(title: title, children: children)
        }
    }

    static func + (lhs: ChromiumBookmarks, rhs: ChromiumBookmarks) -> ChromiumBookmarks {
        ChromiumBookmarks(bar: lhs.bar + rhs.bar, other: lhs.other + rhs.other, mobile: lhs.mobile + rhs.mobile)
    }
}

enum ChromiumBookmarksError: Error { case malformed }

/// Reads a `Bookmarks` or `AccountBookmarks` file: `roots` holds `bookmark_bar`, `other` and
/// `synced`, each a folder node whose `children` are nodes of `type` "url" or "folder".
func parseChromiumBookmarks(_ data: Data) throws -> ChromiumBookmarks {
    guard let file = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let roots = file["roots"] as? [String: Any] else { throw ChromiumBookmarksError.malformed }
    func children(_ node: Any?) -> [ArcNode] {
        ((node as? [String: Any])?["children"] as? [Any] ?? []).compactMap { child -> ArcNode? in
            guard let child = child as? [String: Any] else { return nil }
            let name = child["name"] as? String ?? ""
            switch child["type"] as? String {
            case "url":
                guard let address = child["url"] as? String,
                      let scheme = URL(string: address)?.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return nil }
                return .tab(url: address, title: name.isEmpty ? nil : name, customTitle: nil)
            case "folder":
                return .folder(title: name, children: children(child))
            default:
                return nil
            }
        }
    }
    return ChromiumBookmarks(bar: children(roots["bookmark_bar"]), other: children(roots["other"]), mobile: children(roots["synced"]))
}
