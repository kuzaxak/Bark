// Licensed under GPL-3.0. See LICENSE.
//
//  RedditTweaks.swift
//  Nook
//
//  Created by Bain Gurley on 22/10/2026.
//

import Foundation
import NookSettings

@MainActor
public enum RedditTweaks {
    /// The Hot version of a sortless Reddit feed URL: home, a subreddit, or a custom feed.
    public static func hotURL(for url: URL, settings: NookSettingsService) -> URL? {
        guard settings.redditSortHot,
              let host = url.host?.lowercased(), host == "reddit.com" || host == "www.reddit.com",
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let parts = components.path.split(separator: "/")
        let isFeed = parts.isEmpty
            || (parts.count == 2 && parts[0] == "r")
            || (parts.count == 4 && parts[0] == "user" && parts[2] == "m")
        guard isFeed else { return nil }
        components.path = "/" + parts.map { "\($0)/" }.joined() + "hot/"
        return components.url
    }
}
