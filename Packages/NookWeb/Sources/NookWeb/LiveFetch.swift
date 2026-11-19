// Licensed under GPL-3.0. See LICENSE.
//
//  LiveFetch.swift
//  Nook
//
//  Authenticated response parsing and anonymous feed retrieval for live folders.
//

import Foundation
import NookTabsCore

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

    /// Feeds follow redirects and use no browser cookies or stored credentials.
    private static let feedSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
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
        guard let (data, response) = try? await feedSession.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let parsed = LiveParse.feed(data, base: response.url ?? url) else { throw Failure.failed }
        return (parsed.title, parsed.items.map { LivePage(url: $0.url, title: $0.title) })
    }
}

extension TabsController {
    /// Retire an invalid request on the model mutation that revokes ownership.
    /// A later reassignment to the original profile cannot revive it.
    func invalidateNativeLiveRequests() {
        for (id, validate) in nativeLiveRequestOwners where !validate() {
            nativeLiveRequestOwners.removeValue(forKey: id)
        }
    }

    func nativeLiveResponse(_ source: ProfileLiveSource, profileID: UUID, spaceID: UUID,
                            while ownsSource: @escaping @MainActor () -> Bool) async throws -> ProfileLiveResponse {
        guard let fetch = nativeLiveFetch else { throw ProfileLiveFailure.unavailable }
        func current() -> Bool {
            !isTerminating && tree.dataStoreID(for: spaceID) == profileID &&
                isProfileAvailable(profileID) && profileSpaceIsReady(spaceID) && ownsSource()
        }
        guard current(), !Task.isCancelled else { throw ProfileLiveFailure.cancelled }

        let id = UUID()
        let response = AsyncStream<Result<ProfileLiveResponse, Error>>.makeStream()
        nativeLiveRequestOwners[id] = {
            guard current() else {
                response.continuation.finish()
                return false
            }
            return true
        }
        let work = Task { @MainActor in
            guard nativeLiveRequestOwners[id] != nil, current(), !Task.isCancelled else {
                response.continuation.finish()
                return
            }
            do {
                let result = try await fetch(profileID, source)
                response.continuation.yield(.success(result))
            } catch {
                response.continuation.yield(.failure(error))
            }
        }
        defer {
            nativeLiveRequestOwners.removeValue(forKey: id)
            response.continuation.finish()
            work.cancel()
        }
        for await result in response.stream {
            guard nativeLiveRequestOwners[id] != nil, current(), !Task.isCancelled else { break }
            return try result.get()
        }
        throw ProfileLiveFailure.cancelled
    }
}
