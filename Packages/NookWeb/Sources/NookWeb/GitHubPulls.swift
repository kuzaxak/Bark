// Licensed under GPL-3.0. See LICENSE.
import Foundation
import NookTabsCore

/// Parses the open pull request list returned by GitHub for a Chromium profile.
enum GitHubPulls {
    typealias Failure = LiveFetch.Failure

    private struct Response: Decodable {
        struct Payload: Decodable { let pullsDashboardSurfaceContentRoute: Route }
        struct Route: Decodable { let results: [PullRequest] }
        struct PullRequest: Decodable {
            let permalink: URL
            let title: String
        }
        let payload: Payload
    }

    /// A pull request page: github.com/<owner>/<repo>/pull/<number>.
    static func owns(_ url: URL) -> Bool {
        let parts = url.path.split(separator: "/")
        return url.host == "github.com" && parts.count == 4 && parts[2] == "pull" && Int(parts[3]) != nil
    }

    static func response(data: Data, status: Int) throws -> [LivePage] {
        // Signed out, the JSON list answers 404 and the HTML one redirects to the login page.
        if (300..<400).contains(status) || status == 401 || status == 404 { throw Failure.signedOut }
        guard status == 200, let decoded = try? JSONDecoder().decode(Response.self, from: data) else { throw Failure.failed }
        return decoded.payload.pullsDashboardSurfaceContentRoute.results
            .filter { owns($0.permalink) }
            .map { LivePage(url: $0.permalink, title: $0.title) }
    }
}
