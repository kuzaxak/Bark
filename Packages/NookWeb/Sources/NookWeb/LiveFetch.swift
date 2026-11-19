// Licensed under GPL-3.0. See LICENSE.
//
//  LiveFetch.swift
//  Nook
//
//  Authenticated response parsing and anonymous feed retrieval for live folders.
//

import Foundation
import NookTabsCore
import Observation

public enum ProfileLiveSource: Equatable, Sendable {
    case githubPulls, githubIssues, githubNotifications, asanaWorkspaces
    case asanaTasks(workspace: String), gmail(account: Int)
}
public struct ProfileLiveResponse: Sendable {
    public let data: Data
    public let status: Int
    public init(data: Data, status: Int) { self.data = data; self.status = status }
}
public enum ProfileLiveFailure: Error { case unavailable, cancelled, failed }
public typealias ProfileLiveFetch = @MainActor (UUID, ProfileLiveSource) async throws -> ProfileLiveResponse

enum LiveFetch {
    enum Failure: Error { case signedOut, failed }

    /// Feeds follow redirects and carry no browser cookies.
    private static let feedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    static func githubIssues(data: Data, status: Int) throws -> [LivePage] {
        if (300..<400).contains(status) || status == 401 || status == 404 { throw Failure.signedOut }
        guard status == 200, let entries = LiveParse.githubIssues(data) else { throw Failure.failed }
        return entries.prefix(25).map { LivePage(url: $0.url, title: $0.title) }
    }

    static func githubNotifications(data: Data, status: Int) throws -> [LivePage] {
        if (300..<400).contains(status) || status == 401 || status == 404 { throw Failure.signedOut }
        guard status == 200 else { throw Failure.failed }
        return LiveParse.githubNotifications(html: String(decoding: data, as: UTF8.self))
            .prefix(25).map { LivePage(url: $0.url, title: $0.title) }
    }

    static func asanaTasks(workspaces: Data, tasksFor: (String) async throws -> Data) async throws -> [LivePage] {
        guard let workspaces = LiveParse.asanaWorkspaces(workspaces) else { throw Failure.failed }
        var tasks: [LiveParse.AsanaTask] = []
        for workspace in workspaces {
            let data = try await tasksFor(workspace)
            guard let more = LiveParse.asanaTasks(data) else { throw Failure.failed }
            tasks += more
        }
        return LiveParse.rankAsanaTasks(tasks).map { LivePage(url: $0.url, title: $0.title) }
    }

    /// A feed's own title and newest items. No cookies are sent.
    static func feed(_ url: URL) async throws -> (title: String?, pages: [LivePage]) {
        var request = URLRequest(url: url)
        request.setValue("application/rss+xml, application/atom+xml, application/xml;q=0.9, */*;q=0.8", forHTTPHeaderField: "Accept")
        if let agent = PlatformUserAgent.custom { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        guard let (data, response) = try? await feedSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = LiveParse.feed(data, base: response.url ?? url) else { throw Failure.failed }
        return (parsed.title, parsed.items.map { LivePage(url: $0.url, title: $0.title) })
    }
}

extension TabsController {
    /// Request-local observation of existing model ownership. Zero polling and
    /// no transport/session registry; cancellation ends this request's task.
    func nativeLiveResponse(_ source: ProfileLiveSource, profileID: UUID, spaceID: UUID,
                            while ownsSource: @escaping @MainActor () -> Bool) async throws -> ProfileLiveResponse {
        guard let fetch = nativeLiveFetch else { throw ProfileLiveFailure.unavailable }
        func current() -> Bool {
            profileEngine == .chromium && !isTerminating && isProfileAvailable(profileID) &&
                tree.space(spaceID) != nil && profile(forSpace: spaceID)?.id == profileID && ownsSource()
        }
        let changes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        func watch() -> Bool {
            withObservationTracking { current() } onChange: {
                DispatchQueue.main.async { changes.continuation.yield(()) }
            }
        }
        guard watch(), !Task.isCancelled else { throw ProfileLiveFailure.cancelled }
        var result: Result<ProfileLiveResponse, Error>?
        let work = Task { @MainActor in
            do {
                guard current(), !Task.isCancelled else { throw ProfileLiveFailure.cancelled }
                result = .success(try await fetch(profileID, source))
            }
            catch { result = .failure(error) }
            changes.continuation.yield(())
        }
        defer { changes.continuation.finish(); work.cancel() }
        for await _ in changes.stream {
            guard watch(), !Task.isCancelled else { throw ProfileLiveFailure.cancelled }
            if let result { return try result.get() }
        }
        throw ProfileLiveFailure.cancelled
    }
}
