// Licensed under GPL-3.0. See LICENSE.
//
//  DevMCPServer.swift
//  Nook
//
//  Opt-in MCP server for a coding agent to drive the running Bark app.
//  Streamable HTTP on loopback, with a bearer token in App/DevMCP/token
//  under Bark's configured data root.
//

import AppKit
import NookSettings
import BarcChromium
import Foundation
import Network
import OSLog
import NookBlocker
import NookWeb

@MainActor
final class DevMCPServer {
    static let shared = DevMCPServer()
    private var configuration: DevMCPConfiguration?
    private var generation: UInt64 = 0
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var downloads: [UUID: DevMCPDownload] = [:]
    private var requests: [UUID: Request] = [:]
    @MainActor private final class Request {
        var task: Task<Void, Never>?
        var cancelTool: (() -> Void)?
        func cancel() { cancelTool?(); task?.cancel() }
    }
    private var isPermitted: Bool {
        guard let settings = browserManager?.nookSettings else { return false }
        return DevMCPConfiguration.isEnabled(developerMode: settings.developerModeEnabled,
                                             browserControl: settings.browserControlServerEnabled)
    }

    /// Native startup installs isolated destinations before settings can enable the singleton.
    @discardableResult
    func setConfiguration(_ value: DevMCPConfiguration) -> Bool {
        // Once installed, roots are immutable for this server lifetime, including abandoned
        // asynchronous operations that may outlive their cancelled HTTP request.
        guard configuration == nil || configuration == value else { return false }
        guard listener == nil, requests.isEmpty, connections.isEmpty else { return configuration == value }
        configuration = value
        return true
    }

    nonisolated private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "DevMCP")
    nonisolated private static let maxBody = 8 * 1024 * 1024
    nonisolated private static let toolTimeout: Double = 30
    /// How long a closed stream may take to reconnect before its agent counts as gone.
    private static let reconnectGrace: Duration = .seconds(10)
    /// Under the 300 s an idle response body may last in the client's fetch.
    private static let keepAliveInterval: Duration = .seconds(120)

    private weak var browserManager: BrowserManager?
    private var listener: NWListener?
    /// Last snapshot per page and selector, so the next call can answer with a diff.
    private struct StoredSnapshot {
        let outline: String
        weak var navigation: ChromiumPageNavigation? = nil
        var documentSerial: UInt64? = nil
    }
    private var snapshots: [String: StoredSnapshot] = [:]
    private var token = ""
    /// Each session's open GET stream, which carries nothing but keep-alives.
    private var streams: [String: NWConnection] = [:]
    private var reconnectTask: Task<Void, Never>?
    private var keepAlive: Task<Void, Never>?
    private let queue = DispatchQueue(label: "com.gstudios.nook.devmcp")

    /// Remember the browser and start only if the user has turned the server on.
    /// Off is the default: see NookSettingsService.browserControlServerEnabled.
    func configure(browserManager: BrowserManager, enabled: Bool) {
        self.browserManager = browserManager
        applyEnabledSetting(enabled)
    }

    /// Called when the setting changes, so the server starts and stops without a relaunch.
    func applyEnabledSetting(_ enabled: Bool) {
        guard enabled else { stop(); return }
        guard let browserManager else { return }   // configure() has not run yet
        start(browserManager: browserManager)
    }

    func stop() {
        // Revoke every callback before cancellation can reenter this instance.
        generation &+= 1
        listener?.cancel()
        listener = nil
        token = ""
        let ownedRequests = Array(requests.values)
        let ownedConnections = Array(connections.values)
        connections = [:]
        streams = [:]
        reconnectTask?.cancel()
        reconnectTask = nil
        keepAlive?.cancel()
        keepAlive = nil
        snapshots = [:]
        let ownedDownloads = Array(downloads.values)
        downloads = [:]
        ownedDownloads.forEach { $0.cancel() }
        ownedRequests.forEach { $0.cancel() }
        ownedConnections.forEach { $0.cancel() }
    }

    func shutdown() {
        stop()
        browserManager = nil
    }

    private func start(browserManager: BrowserManager) {
        guard let settings = browserManager.nookSettings,
              DevMCPConfiguration.isEnabled(developerMode: settings.developerModeEnabled,
                                            browserControl: settings.browserControlServerEnabled) else { stop(); return }
        guard listener == nil, let configuration else { return }
        self.browserManager = browserManager
        do {
            token = try configuration.loadOrCreateToken()
            guard let port = NWEndpoint.Port(rawValue: configuration.port) else { throw DevMCPConfiguration.ConfigurationError.unsafePath }
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
            params.allowLocalEndpointReuse = true
            let listener = try NWListener(using: params)
            generation &+= 1
            let expected = generation
            listener.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in
                    guard let self, self.generation == expected, self.listener != nil else { conn.cancel(); return }
                    self.accept(conn)
                }
            }
            listener.stateUpdateHandler = { state in
                Self.log.notice("listener \(String(describing: state), privacy: .public)")
            }
            self.listener = listener
            listener.start(queue: queue)
        } catch {
            token = ""
            Self.log.error("start failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - HTTP

    private func accept(_ conn: NWConnection) {
        connections[ObjectIdentifier(conn)] = conn
        let expected = generation
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard case .cancelled = state else { return }
            Task { @MainActor in
                guard let self, let conn, self.generation == expected else { return }
                self.connections.removeValue(forKey: ObjectIdentifier(conn))
            }
        }
        conn.start(queue: queue)
        receive(conn, buffer: Data(), generation: expected)
    }

    private nonisolated func receive(_ conn: NWConnection, buffer: Data, generation expected: UInt64) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            let received = buffer
            let parsed = HTTPRequest(received)
            Task { @MainActor in
                guard let self, self.generation == expected, self.listener != nil,
                      self.connections[ObjectIdentifier(conn)] === conn else { conn.cancel(); return }
                if let request = parsed {
                    if request.method == "GET", self.rejection(request) == nil, let session = request.headers["mcp-session-id"] {
                        self.openStream(conn, session: session)
                        return
                    }
                    let id = UUID()
                    let owned = Request()
                    self.requests[id] = owned
                    owned.task = Task { @MainActor in
                        defer { owned.task = nil; self.requests.removeValue(forKey: id) }
                        guard !Task.isCancelled, self.generation == expected else { return }
                        let (status, body) = await self.handle(request, owned: owned)
                        guard !Task.isCancelled, self.generation == expected else { conn.cancel(); return }
                        self.send(conn, status: status, body: body, session: request.headers["mcp-session-id"] ?? UUID().uuidString)
                    }
                } else if error != nil || isComplete || received.count > Self.maxBody {
                    conn.cancel()
                } else {
                    self.receive(conn, buffer: received, generation: expected)
                }
            }
        }
    }

    private nonisolated func send(_ conn: NWConnection, status: Int, body: Data?, session: String) {
        let reason = [200: "OK", 202: "Accepted", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed"][status] ?? "Error"
        var head = "HTTP/1.1 \(status) \(reason)\r\nConnection: close\r\nContent-Length: \(body?.count ?? 0)\r\nMcp-Session-Id: \(session)\r\n"
        if body != nil { head += "Content-Type: application/json\r\n" }
        var out = Data((head + "\r\n").utf8)
        if let body { out.append(body) }
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    // MARK: - Sessions

    private func openStream(_ conn: NWConnection, session: String) {
        reconnectTask?.cancel()
        reconnectTask = nil
        streams.updateValue(conn, forKey: session)?.cancel()
        let head = "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8), completion: .contentProcessed { _ in })
        watchClose(conn, session: session)
        guard keepAlive == nil else { return }
        let expected = generation
        keepAlive = Task {
            while !streams.isEmpty, generation == expected, !Task.isCancelled {
                do { try await Task.sleep(for: Self.keepAliveInterval) } catch { return }
                guard generation == expected, !Task.isCancelled else { return }
                for stream in streams.values { stream.send(content: Data(":\n\n".utf8), completion: .contentProcessed { _ in }) }
            }
            if generation == expected { keepAlive = nil }
        }
    }

    /// The client sends nothing on a stream, so a finished receive is the stream closing.
    private nonisolated func watchClose(_ conn: NWConnection, session: String) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] _, _, isComplete, error in
            guard isComplete || error != nil else { self?.watchClose(conn, session: session); return }
            conn.cancel()
            Task { @MainActor in
                guard let self, self.streams[session] === conn else { return }
                self.endSession(session)
            }
        }
    }

    /// Forgets `session`, and once no client has reconnected within the grace, closes the
    /// Agent space's tabs.
    private func endSession(_ session: String?) {
        guard let session else { return }
        streams.removeValue(forKey: session)?.cancel()
        guard streams.isEmpty else { return }
        reconnectTask?.cancel()
        let expected = generation
        reconnectTask = Task {
            do { try await Task.sleep(for: Self.reconnectGrace) } catch { return }
            guard generation == expected else { return }
            reconnectTask = nil
            guard streams.isEmpty, listener != nil else { return }
            Self.log.notice("last agent disconnected")
            browserManager?.closeIdleAgentTabs()
        }
    }

    /// The status refusing `req`, or nil when it may go ahead.
    private func rejection(_ req: HTTPRequest) -> Int? {
        guard isPermitted else { return 403 }
        // Web pages cannot reach us: they would send an Origin, and could not know the token.
        // Compare the parsed host, not a string prefix: http://localhost.attacker.example passed.
        if let origin = req.headers["origin"] {
            let host = URL(string: origin)?.host
            guard host == "127.0.0.1" || host == "localhost" || host == "::1" else { return 403 }
        }
        guard req.headers["authorization"] == "Bearer \(token)" else { return 401 }
        guard req.path.hasPrefix("/mcp") else { return 404 }
        return nil
    }

    private func handle(_ req: HTTPRequest, owned: Request) async -> (Int, Data?) {
        guard listener != nil, !Task.isCancelled else { return (503, nil) }
        if let status = rejection(req) { return (status, nil) }
        switch req.method {
        case "POST": break
        case "DELETE":
            endSession(req.headers["mcp-session-id"])
            return (200, nil)
        default: return (405, nil)
        }
        guard let msg = try? JSONSerialization.jsonObject(with: req.body) as? [String: Any] else {
            return (400, rpcError(id: NSNull(), code: -32700, message: "Parse error"))
        }
        guard let id = msg["id"] else { return (202, nil) } // notification
        let method = msg["method"] as? String ?? ""
        let params = msg["params"] as? [String: Any] ?? [:]

        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:] as [String: Any]],
                "serverInfo": ["name": "bark-dev", "version": "1"],
                "instructions": "Controls the running \(ProductDisplayName.current) app while Browser Control is enabled. "
                    + "Agent browsing opens in the Agent space. Bark creates it on first use with the logins of the space the person was using. "
                    + "The person can open the Agent space to watch. Popups from agent pages open as tabs in that space. "
                    + "The pick and selection tools use the person’s active tab."
            ]
        case "ping":
            result = [:]
        case "tools/list":
            result = ["tools": Self.toolList]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            // Counted here, not in callTool, so a call the deadline abandons stops the pulse.
            let callManager = browserManager
            callManager?.tabs.agentCallsInFlight += 1
            let requestedTimeout = (args["timeout"] as? NSNumber)?.doubleValue ?? 20
            let nativeWait = browserManager != nil && (name == "reload" || name == "wait_for_load")
            let timeout = nativeWait ? (requestedTimeout.isFinite ? max(0, min(requestedTimeout, Self.toolTimeout - 5)) : 20) : Self.toolTimeout
            let called = await withTimeout(timeout, owned: owned, operation: { await self.callTool(name, args) })
            callManager?.tabs.agentCallsInFlight -= 1
            guard let called else {
                return (200, rpcError(id: id, code: -32001, message: "Tool \(name) did not answer within \(Int(timeout))s"))
            }
            result = called
        default:
            return (200, rpcError(id: id, code: -32601, message: "Method not found: \(method)"))
        }
        return (200, try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "result": result]))
    }

    /// A tool that never returns must not hold its connection open for ever, so
    /// every call races a deadline and nil means the deadline won. The losing work
    /// is cancelled; a native operation may still deliver its completion.
    private func withTimeout<T: Sendable>(_ seconds: Double, owned: Request, operation: @escaping @MainActor () async -> T) async -> T? {
        // Not a task group: a group waits for its children even after cancelAll(),
        // so an abandoned operation would still hold the connection open
        // for as long as it took. These two tasks race and the loser is dropped.
        let latch = Latch()
        owned.cancelTool = { latch.finishCancellation() }
        defer { owned.cancelTool = nil }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
                latch.cancel = { cont.resume(returning: nil) }
                if latch.done {
                    latch.cancel = nil
                    cont.resume(returning: nil)
                    return
                }
                guard !Task.isCancelled else { latch.finishCancellation(); return }
                let deadline = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
                    latch.finishCancellation()
                }
                latch.deadline = deadline
                latch.work = Task { @MainActor in
                    guard !Task.isCancelled, !latch.done else { return }
                    let value = await operation()
                    guard !latch.done else { return }
                    latch.done = true
                    latch.cancel = nil
                    latch.deadline?.cancel()
                    latch.deadline = nil
                    latch.work = nil
                    cont.resume(returning: value)
                }
            }
        } onCancel: {
            Task { @MainActor in latch.finishCancellation() }
        }
    }

    @MainActor private final class Latch {
        var done = false
        var work: Task<Void, Never>?
        var deadline: Task<Void, Never>?
        var cancel: (() -> Void)?
        func finishCancellation() {
            guard !done else { return }
            done = true
            work?.cancel()
            deadline?.cancel()
            work = nil
            deadline = nil
            let completion = cancel
            cancel = nil
            completion?()
        }
    }

    private func rpcError(id: Any, code: Int, message: String) -> Data? {
        try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
    }

    // MARK: - Tools

    private static let devTools: [AIToolDefinition] = [
        AIToolDefinition(
            name: "evaluate",
            description: "Run JavaScript as an async function body in the selected tab and return the JSON of its return value. Use `return` and `await` freely. world: 'page' (default) or 'isolated'. saveTo: a path relative to the configured DevMCP file root; the result is written there instead of returned (a string as is, anything else as JSON), and append: true adds it to the end of the file.",
            parameters: ["type": "object", "properties": [
                "code": ["type": "string"],
                "world": ["type": "string", "enum": ["page", "isolated"]],
                "saveTo": ["type": "string"],
                "append": ["type": "boolean"]
            ], "required": ["code"]]
        ),
        AIToolDefinition(
            name: "download",
            description: "Save https URLs (plain http fails App Transport Security) as files in dir, a path relative to the configured DevMCP file root, fetched with the selected tab's cookies and user agent and its URL as Referer. urls: a list, and/or urlsFile: a file under the same root with one URL per line (write one with evaluate saveTo). Files are named <hash>-<last path component>; ones already there are skipped. Each URL adds a line to dir/manifest.jsonl (url, file, status ok|exists|http|error|tooLarge, httpStatus, contentType, bytes). Answers when all are done or after 20 s; the rest keep downloading, so read the manifest for the outcome.",
            parameters: ["type": "object", "properties": [
                "urls": ["type": "array", "items": ["type": "string"]],
                "urlsFile": ["type": "string"],
                "dir": ["type": "string"]
            ], "required": ["dir"]]
        ),
        AIToolDefinition(
            name: "screenshot",
            description: "JPEG of the selected tab's visible page, at most maxWidth pixels wide (default 1200).",
            parameters: ["type": "object", "properties": ["maxWidth": ["type": "integer"]]]
        ),
        AIToolDefinition(
            name: "console",
            description: "Console messages, uncaught errors and failed resource loads from every frame of the selected tab since its last load. Pass the returned cursor as since to get only newer entries. clear: true empties the log after reading.",
            parameters: ["type": "object", "properties": ["since": ["type": "integer"], "clear": ["type": "boolean"]]]
        ),
        AIToolDefinition(
            name: "blocker_log",
            description: "What the content blocker did to the selected tab since its last load: loads and cookies blocked, loads made HTTPS, navigations rewritten by $removeparam or urlskip, plus the page's procedural cosmetic rules and scriptlet names. Pass the returned cursor as since for only newer actions. The rule list that blocked a load is not known.",
            parameters: ["type": "object", "properties": ["since": ["type": "integer"]]]
        ),
        AIToolDefinition(
            name: "snapshot",
            description: "Accessibility outline of the selected tab under a CSS selector (the body when omitted): one line per role with its name and state, generic wrappers flattened, hidden content left out. A repeat call for the same page and selector returns only the lines that changed; pass full: true for the whole outline. maxNodes defaults to 300, maxDepth to 12.",
            parameters: ["type": "object", "properties": [
                "selector": ["type": "string"], "full": ["type": "boolean"],
                "maxNodes": ["type": "integer"], "maxDepth": ["type": "integer"],
            ]]
        ),
        AIToolDefinition(
            name: "perf",
            description: "Legacy page performance capture. Not available for Chromium pages.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        ),
        AIToolDefinition(
            name: "pick",
            description: "Start the element picker in the selected tab and wait up to 25 seconds for the person to click an element, then return it as selection does. Use it to ask the person which element they mean.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        ),
        AIToolDefinition(
            name: "selection",
            description: "What the person last handed to the agent from the selected tab: an element picked with Pick Element (selector, role, HTML, styles that differ from defaults, React or Vue component names and source when the page exposes them, recent errors and failed requests) or a console line or request sent with Send to Agent. Markdown, plus the element's screenshot when there is one.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        ),
        AIToolDefinition(
            name: "network",
            description: "Requests from the selected tab since its last load: fetch and XHR with status, plus every other load from Resource Timing. Pass the returned cursor as since for only new or updated entries. detail: true adds headers and bodies for fetch and XHR.",
            parameters: ["type": "object", "properties": ["since": ["type": "integer"], "detail": ["type": "boolean"]]]
        ),
        AIToolDefinition(
            name: "reload",
            description: "Reload the selected tab and wait for the load to finish (timeout seconds, default 20, capped at 25 by the server's own deadline).",
            parameters: ["type": "object", "properties": ["timeout": ["type": "number"]]]
        ),
        AIToolDefinition(
            name: "wait_for_load",
            description: "Wait until the selected tab stops loading (timeout seconds, default 20, capped at 25 by the server's own deadline). Call after navigateToURL.",
            parameters: ["type": "object", "properties": ["timeout": ["type": "number"]]]
        ),
        AIToolDefinition(
            name: "blocker_status",
            description: "Content blocker state for the selected tab: enabled, whether this page is exempt, allowlisted host, compiled rule lists.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        ),
        AIToolDefinition(
            name: "set_blocking",
            description: "Turn ad blocking on or off for the selected tab's host (edits the persisted allowlist) and reload.",
            parameters: ["type": "object", "properties": ["enabled": ["type": "boolean"]], "required": ["enabled"]]
        ),
        AIToolDefinition(
            name: "check_urls",
            description: "Ask adblock-rust whether each URL would be blocked when requested from sourceURL (default: the selected tab's URL). type is an adblock request type: script, image, stylesheet, xmlhttprequest, sub_frame, media, font, ping, other.",
            parameters: ["type": "object", "properties": [
                "urls": ["type": "array", "items": ["type": "string"]],
                "type": ["type": "string"],
                "sourceURL": ["type": "string"]
            ], "required": ["urls"]]
        ),
        AIToolDefinition(
            name: "closeTabs",
            description: "Close Agent space tabs. indices: positions from getTabList. Or regular: true to delete every tab and folder in its regular tabs section, leaving favorites and pinned tabs.",
            parameters: ["type": "object", "properties": [
                "indices": ["type": "array", "items": ["type": "integer"]],
                "regular": ["type": "boolean"]
            ]]
        ),
        AIToolDefinition(
            name: "pinTab",
            description: "Pin the tab at a getTabList index to the Agent space's pinned section.",
            parameters: ["type": "object", "properties": ["index": ["type": "integer"]], "required": ["index"]]
        ),
        AIToolDefinition(
            name: "user_scripts",
            description: "User scripts installed in the selected tab: first line, injection time, main frame only, length.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        ),
        AIToolDefinition(
            name: "pages",
            description: "List existing regular pages with their URL, loaded state and on-screen selection. Includes native window attachment when available, and renderer PID and document visibility on supporting engines. Leaves parked pages alone.",
            parameters: ["type": "object", "properties": [:] as [String: Any]]
        ),
        AIToolDefinition(
            name: "clear_page_cache",
            description: "Request a Back/Forward cache flush for loaded regular pages off screen. Set all to true to include displayed regular pages. Preserves history, live documents and site data. Returns the count of accepted page requests.",
            parameters: ["type": "object", "properties": ["all": ["type": "boolean"]]]
        )
    ]

    /// `executeJavaScript` is not advertised: over this server it is only an old name for
    /// `evaluate` (see callTool), and the chat's description of it is wrong for that behaviour.
    /// The alias stays so an agent registered against the old name keeps working.
    private static let toolList: [[String: Any]] = (BrowserTools.allTools.filter { $0.name != "executeJavaScript" } + devTools).map {
        ["name": $0.name, "description": $0.description, "inputSchema": $0.parameters]
    }

    /// About the person's own page, so they act on the active window's tab, not the Agent space.
    private static let humanTools: Set<String> = ["pick", "selection"]
    /// Need no Agent page, so they neither create the Agent space nor load its tab.
    private static let toolsWithoutAgentPage: Set<String> = ["check_urls", "getTabList", "closeTabs", "pinTab"]

    private var humanWindow: BrowserWindowState? {
        guard let registry = browserManager?.windowRegistry else { return nil }
        return registry.activeWindow ?? registry.windows.values.first
    }

    private func text(_ s: String, error: Bool = false) -> [String: Any] {
        ["content": [["type": "text", "text": s]], "isError": error]
    }

    private func json(_ value: Any) -> String {
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]) else {
            return String(describing: value)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// The server does not enforce the advertised schemas, and `intValue` would turn 1.9 into tab 1.
    private static func wholeNumber(_ number: NSNumber) -> Int? {
        let value = number.doubleValue
        return value == value.rounded() && abs(value) < 1e9 ? Int(value) : nil
    }

    /// These operations inspect the existing model policy, not native request installation.
    private func nativeBlockerTool(_ name: String, _ args: [String: Any],
                                   browserManager bm: BrowserManager, window: BrowserWindowState) -> [String: Any]? {
        guard ["blocker_status", "set_blocking", "check_urls"].contains(name) else { return nil }
        guard let page = bm.tabs.existingNativeAgentPage(in: window) else {
            return text("No current live Agent page in this window/profile", error: true)
        }
        let blocker = bm.contentBlockerManager
        let host = page.url.host
        switch name {
        case "blocker_status":
            return text(json([
                "scope": "modelPolicyAndBuildReadiness", "nativeInstallation": "notVerifiedByThisTool",
                "enabled": blocker.isEnabled, "compiling": blocker.isCompiling,
                "lastBuildSucceeded": blocker.lastBuildSucceeded, "hasExportedRules": blocker.networkRules != nil,
                "networkBlockingRequested": blocker.networkBlockingRequested,
                "host": host ?? "", "hostAllowlisted": blocker.isDomainAllowed(host),
                "policyShouldApply": blocker.shouldApplyBlocking(to: page),
                "oauthFlow": page.isOAuthFlow, "temporarilyDisabled": blocker.isTemporarilyDisabled(tabId: page.itemID)
            ]))
        case "set_blocking":
            guard let host else { return text("Agent page has no host", error: true) }
            let enabled = args["enabled"] as? Bool ?? true
            blocker.allowDomain(host, allowed: !enabled, from: page)
            guard bm.tabs.existingNativeAgentPage(in: window) === page else {
                return text("Policy updated, but Agent page ownership changed", error: true)
            }
            return text("Blocking policy \(enabled ? "on" : "off") for \(host). Native installation is not verified by this tool.")
        default:
            let source = args["sourceURL"] as? String ?? page.url.absoluteString
            let type = args["type"] as? String ?? "script"
            var matches: [String: Bool] = [:]
            for url in args["urls"] as? [String] ?? [] {
                matches[url] = blocker.engine.matches(url: url, sourceURL: source, type: type)
            }
            return text(json(["scope": "inProcessRuleMatcher", "nativeInstallation": "notVerifiedByThisTool",
                              "compiling": blocker.isCompiling, "lastBuildSucceeded": blocker.lastBuildSucceeded,
                              "hasExportedRules": blocker.networkRules != nil, "sourceURL": source, "matches": matches]))
        }
    }

    private func pageResourceTool(_ name: String, _ args: [String: Any], tabs: TabsController) -> [String: Any]? {
        guard name == "pages" || name == "clear_page_cache" else { return nil }
        let regular = tabs.regularDiagnosticSessions.filter {
            ($0.navigation as? ChromiumPageNavigation)?.isPrivateSession != true
        }
        if name == "pages" {
            let rows = regular.map { page -> [String: Any] in
                var row: [String: Any] = ["url": page.url.absoluteString, "loaded": !page.isUnloaded,
                                           "onScreen": tabs.isOnScreen(page.itemID)]
                if let navigation = page.navigation as? ChromiumPageNavigation {
                    let sample = navigation.resourceDiagnostics
                    if let value = sample.inWindow { row["inWindow"] = value }
                    if let value = sample.pid { row["pid"] = value }
                    if let value = sample.visibility { row["visibility"] = value }
                }
                return row
            }
            return text(json(rows))
        }
        let all = args["all"] as? Bool ?? false
        let pages = regular.filter { !$0.isUnloaded && (all || !tabs.isOnScreen($0.itemID)) }
        let accepted = pages.filter { $0.clearPageCache() }.count
        return text("Accepted BFCache flush for \(accepted) of \(pages.count) live pages; no reload or site-data deletion.")
    }

    private func nativeEvaluate(_ args: [String: Any], browserManager bm: BrowserManager,
        window: BrowserWindowState) async throws -> [String: Any] {
        var saveURL: URL?
        if let saveTo = args["saveTo"] as? String {
            guard let configuration, let url = configuration.resolve(saveTo) else {
                return text("saveTo must be a relative path inside the configured files directory", error: true)
            }
            saveURL = url
        }
        guard let page = await bm.tabs.prepareNativeAgentPage(in: window),
              let navigation = page.navigation as? ChromiumPageNavigation else {
            return text("Agent page preparation was cancelled or unavailable", error: true)
        }
        let owner = navigation.nativeWindowID, tab = navigation.nativeTabID
        let profile = navigation.profileID
        let current: @MainActor () -> Bool = { [weak bm, weak window, weak page, weak navigation] in
            guard let bm, let window, let page, let navigation else { return false }
            return bm.windowRegistry?.windows[window.id] === window &&
                bm.tabs.existingNativeAgentPage(in: window) === page &&
                page.navigation === navigation && navigation.nativeWindowID == owner &&
                navigation.nativeTabID == tab && navigation.profileID == profile && !navigation.isClosed
        }
        if page.nativeAgentNavigationIsPending,
           !(await page.waitForNativeAgentNavigation(in: window, reload: false, while: current)) {
            return text("Agent navigation failed or ownership changed", error: true)
        }
        guard current(), isPermitted, listener != nil, !Task.isCancelled else {
            return text("Agent request cancelled or ownership changed", error: true)
        }
        let result = try await navigation.evaluateScript(args["code"] as? String ?? "",
            mode: .asyncBody, world: args["world"] as? String == "isolated" ? .isolated : .page)
        guard current(), isPermitted, listener != nil, !Task.isCancelled else {
            return text("Agent request cancelled or ownership changed", error: true)
        }
        let output = saveURL != nil && result.isString ? result.text : result.devMCPText
        guard let saveURL else { return text(output) }
        try FileManager.default.createDirectory(at: saveURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = Data(output.utf8)
        if args["append"] as? Bool == true, let handle = try? FileHandle(forWritingTo: saveURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile(); handle.write(data)
        } else { try data.write(to: saveURL) }
        return text("Saved \(data.count) bytes to \(saveURL.path)")
    }

    private func nativeDownload(_ args: [String: Any], browserManager bm: BrowserManager,
                                window: BrowserWindowState) async throws -> [String: Any] {
        let requestGeneration = generation
        guard isPermitted, listener != nil, !Task.isCancelled, let configuration,
              let relative = args["dir"] as? String, let dir = configuration.resolve(relative) else {
            return text("Download requires authorization and a relative directory inside the configured file root.",error:true)
        }
        var list = args["urls"] as? [String] ?? []
        if let file = args["urlsFile"] as? String {
            guard let source = configuration.resolve(file), let body = try? String(contentsOf:source,encoding:.utf8) else {
                return text("urlsFile must be readable inside the configured file root.",error:true)
            }
            list += body.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in:.whitespaces) }
        }
        var seen = Set<URL>()
        let urls = list.compactMap(URL.init(string:)).filter { ["http","https"].contains($0.scheme) && seen.insert($0).inserted }
        guard !urls.isEmpty else { return text("No http(s) URLs given",error:true) }
        guard let page = await bm.tabs.prepareNativeAgentPage(in:window),
              let navigation = page.navigation as? ChromiumPageNavigation else {
            return text("Agent page preparation was cancelled or unavailable",error:true)
        }
        let owner = navigation.nativeWindowID, tab = navigation.nativeTabID, profile = navigation.profileID
        let current: @MainActor @Sendable () -> Bool = { [weak self,weak bm,weak window,weak page,weak navigation] in
            guard let self,let bm,let window,let page,let navigation else { return false }
            return self.generation == requestGeneration && self.isPermitted && self.listener != nil &&
                self.configuration == configuration && configuration.resolve(relative)?.path == dir.path &&
                bm.windowRegistry?.windows[window.id] === window &&
                bm.tabs.existingNativeAgentPage(in:window) === page && page.navigation === navigation &&
                navigation.nativeWindowID == owner && navigation.nativeTabID == tab &&
                navigation.profileID == profile && !navigation.isClosed
        }
        if page.nativeAgentNavigationIsPending,
           !(await page.waitForNativeAgentNavigation(in:window,reload:false,while:current)) {
            return text("Agent navigation failed or ownership changed",error:true)
        }
        guard current(), !Task.isCancelled else { return text("Download ownership changed",error:true) }
        let serial = page.nativeNavigationSerial
        let canPublish: @MainActor @Sendable () -> Bool = { [weak page] in
            current() && page?.nativeNavigationSerial == serial
        }
        try await Task.detached(priority:.utility) { try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true) }.value
        guard canPublish(), !Task.isCancelled else { return text("Download ownership changed",error:true) }
        let job = try DevMCPDownload(urls:urls,dir:dir,filesRoot:configuration.filesRoot,owner:navigation,canPublish:canPublish) { [weak navigation] url,directory in
            guard let navigation, await MainActor.run(body:canPublish) else { throw CancellationError() }
            let file = try await navigation.downloadFile(url,directory:directory)
            let status: String
            switch BarcFileResult(rawValue:UInt32(bitPattern:file.result)) {
            case BARC_FILE_OK:status="ok";case BARC_FILE_TOO_LARGE:status="tooLarge";case BARC_FILE_HTTP:status="http";default:status="error" }
            return .init(temporary:file.temporary,status:status,httpStatus:Int(file.status),contentType:file.contentType,bytes:file.bytes)
        }
        // Existing jobs provide ordering for this exact adapter; there is no
        // second queue. A second six-item job cannot consume rejected slots.
        let prior=downloads.values.filter{$0.nativeOwner === navigation}.compactMap(\.batchTask)
        let id = UUID();downloads[id] = job
        let running=job.start(after:prior)
        Task { [weak self] in await running.value;self?.downloads.removeValue(forKey:id) }
        await job.waitForCompletion(seconds:20)
        guard !Task.isCancelled, !job.isCancelled, canPublish() else { job.cancel();return text("Download cancelled, directory replaced, or ownership changed",error:true) }
        let progress = job.progress
        return text(json(["dir":dir.path,"manifest":dir.appendingPathComponent("manifest.jsonl").path,
            "total":urls.count,"done":progress.counts.values.reduce(0,+),"finished":progress.finished,"counts":progress.counts]))
    }

    private func nativeScreenshot(_ args: [String: Any], browserManager bm: BrowserManager,
                                  window: BrowserWindowState) async throws -> [String: Any] {
        let width: Double
        if let supplied = args["maxWidth"] {
            guard let number = supplied as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  let value = Self.wholeNumber(number), (1...4096).contains(value) else {
                return text("maxWidth must be an integer from 1 to 4096 pixels.", error: true)
            }
            width = number.doubleValue
        } else { width = 1200 }
        let requestGeneration = generation
        guard isPermitted, listener != nil, !Task.isCancelled,
              let page = await bm.tabs.prepareNativeAgentPage(in: window),
              let navigation = page.navigation as? ChromiumPageNavigation else {
            return text("Agent page preparation was cancelled or unavailable", error: true)
        }
        let owner = navigation.nativeWindowID, tab = navigation.nativeTabID
        let profile = navigation.profileID
        let current: @MainActor () -> Bool = { [weak bm, weak window, weak page, weak navigation] in
            guard let bm, let window, let page, let navigation else { return false }
            return bm.windowRegistry?.windows[window.id] === window &&
                bm.tabs.existingNativeAgentPage(in: window) === page && page.navigation === navigation &&
                navigation.nativeWindowID == owner && navigation.nativeTabID == tab &&
                navigation.profileID == profile && !navigation.isClosed
        }
        if page.nativeAgentNavigationIsPending,
           !(await page.waitForNativeAgentNavigation(in: window, reload: false, while: current)) {
            return text("Agent navigation failed or ownership changed", error: true)
        }
        guard current(), requestGeneration == generation, isPermitted, listener != nil, !Task.isCancelled else {
            return text("Agent request cancelled or ownership changed", error: true)
        }
        let serial = page.nativeNavigationSerial
        let jpeg: Data
        do { jpeg = try await navigation.captureScreenshot(maxWidth: width) }
        catch {
            return text("Screenshot unavailable or cancelled: no retained viewport, capture restricted, unsupported output dimensions, or page ownership changed.", error: true)
        }
        guard current(), page.nativeNavigationSerial == serial, requestGeneration == generation,
              isPermitted, listener != nil, !Task.isCancelled else {
            return text("Screenshot cancelled or its document changed", error: true)
        }
        return ["content": [
            ["type": "text", "text": "Last rendered viewport; hidden-page DOM changes may not be rendered."],
            ["type": "image", "data": jpeg.base64EncodedString(), "mimeType": "image/jpeg"]
        ]]
    }

    private func nativeSnapshot(_ args: [String: Any], browserManager bm: BrowserManager,
        window: BrowserWindowState) async throws -> [String: Any] {
        let requestGeneration = generation
        guard isPermitted, listener != nil, !Task.isCancelled else {
            return text("Tool request was cancelled", error: true)
        }
        guard let page = await bm.tabs.prepareNativeAgentPage(in: window),
              let navigation = page.navigation as? ChromiumPageNavigation else {
            return text("Agent page preparation was cancelled or unavailable", error: true)
        }
        let owner = navigation.nativeWindowID, tab = navigation.nativeTabID, profile = navigation.profileID
        let current: @MainActor () -> Bool = { [weak bm, weak window, weak page, weak navigation] in
            guard let bm, let window, let page, let navigation else { return false }
            return bm.windowRegistry?.windows[window.id] === window &&
                bm.tabs.existingNativeAgentPage(in: window) === page && page.navigation === navigation &&
                navigation.nativeWindowID == owner && navigation.nativeTabID == tab &&
                navigation.profileID == profile && !navigation.isClosed
        }
        if page.nativeAgentNavigationIsPending,
           !(await page.waitForNativeAgentNavigation(in: window, reload: false, while: current)) {
            return text("Agent navigation failed or ownership changed", error: true)
        }
        guard current(), requestGeneration == generation, isPermitted, listener != nil, !Task.isCancelled else {
            return text("Agent request cancelled or ownership changed", error: true)
        }
        let selector = args["selector"] as? String ?? ""
        let nodes = (args["maxNodes"] as? NSNumber).flatMap(Self.wholeNumber).map { min(max($0, 1), 2_000) } ?? 300
        let depth = (args["maxDepth"] as? NSNumber).flatMap(Self.wholeNumber).map { min(max($0, 1), 40) } ?? 12
        guard let script = page.nativeDevSnapshotScript(selector, maxDepth: depth, maxNodes: nodes) else {
            return text("Developer Mode is off or this page is unavailable.", error: true)
        }
        let documentSerial = page.nativeNavigationSerial
        let result = try await navigation.evaluateScript(script, mode: .asyncBody, world: .isolated)
        guard current(), requestGeneration == generation, isPermitted, listener != nil, !Task.isCancelled,
              page.nativeNavigationSerial == documentSerial else {
            return text("Snapshot cancelled or its document changed", error: true)
        }
        guard result.isString else {
            return text(result.json == "null" ? "Nothing matches \(selector)." : "Snapshot did not return an outline.", error: true)
        }
        let outline = result.text
        // One slot per existing page/selector, replaced across navigations;
        // weak adapter identity and the document revision prevent cross-document diffs.
        let key = "native|\(page.itemID)|\(selector)"
        let previous = snapshots[key]
        snapshots[key] = StoredSnapshot(outline: outline, navigation: navigation, documentSerial: documentSerial)
        if args["full"] as? Bool != true, let previous,
           previous.navigation === navigation, previous.documentSerial == documentSerial {
            return text(DevHandoff.snapshotDiff(old: previous.outline, new: outline))
        }
        return text(outline)
    }

    private func nativeSelectionTool(_ name: String, browserManager bm: BrowserManager,
                                     window: BrowserWindowState) async -> [String: Any] {
        let generation = generation
        guard isPermitted, listener != nil, !Task.isCancelled else {
            return text("Tool request was cancelled", error: true)
        }
        if name == "selection" {
            guard let pick = bm.currentNativeDeveloperPick(in: window) else {
                return text("Nothing picked in the current page. Ask the person to pick an element.", error: true)
            }
            return text(pick.markdown)
        }
        guard let (page, navigation) = bm.nativeDeveloperPage(in: window),
              let pick = await bm.pickNativeElement(on: page, navigation: navigation, in: window, while: {
                  self.generation == generation && self.isPermitted && self.listener != nil
              }) else {
            return text("No element picked in the current page, or the request was cancelled.", error: true)
        }
        return text(pick.markdown)
    }

    private func callTool(_ rawName: String, _ args: [String: Any]) async -> [String: Any] {
        guard isPermitted, listener != nil, !Task.isCancelled else { return text("Tool request was cancelled", error: true) }
        // The chat's executeJavaScript evaluates an expression, so `return` (which
        // every agent writes) is a syntax error. Here it is another name for
        // `evaluate`, which runs the code as an async function body.
        let name = rawName == "executeJavaScript" ? "evaluate" : rawName
        // Everything but pick and selection works in the Agent space, whatever the window shows,
        // through a regular window: a private one holds no Agent space. No window is ever opened.
        let forPerson = Self.humanTools.contains(name)
        let active = humanWindow
        guard let bm = browserManager,
              let window = forPerson ? active : (active?.privateTree == nil ? active : bm.tabs.regularWindows.first)
        else { return text("No browser window", error: true) }
        if forPerson {
            return await nativeSelectionTool(name, browserManager: bm, window: window)
        }
        if let result = nativeBlockerTool(name, args, browserManager: bm, window: window) { return result }
        if let result = pageResourceTool(name, args, tabs: bm.tabs) { return result }
        // Model-only tools never create an Agent space or materialize a page.
        let agentSpace = forPerson ? nil
            : Self.toolsWithoutAgentPage.contains(name) ? bm.tabs.agentSpaceID : bm.tabs.ensureAgentSpace(loginsFrom: window)
        if agentSpace == nil, !forPerson {
            if name == "getTabList" { return text("No tabs available") }
            if !Self.toolsWithoutAgentPage.contains(name) { return text("No space to borrow logins from", error: true) }
        }
        let space = forPerson ? window.spaceID : agentSpace
        let order = space.map(bm.tabs.displayOrder(inSpace:)) ?? []

        do {
            if name == "download" {
                return try await nativeDownload(args,browserManager:bm,window:window)
            }
            if name == "screenshot" {
                return try await nativeScreenshot(args, browserManager: bm, window: window)
            }
            if name == "snapshot" {
                return try await nativeSnapshot(args, browserManager: bm, window: window)
            }
            if name == "evaluate" {
                return try await nativeEvaluate(args, browserManager: bm, window: window)
            }
            if name == "reload" || name == "wait_for_load" {
                guard let page = await bm.tabs.prepareNativeAgentPage(in: window),
                      let navigation = page.navigation as? ChromiumPageNavigation else {
                    return text("Agent page preparation was cancelled or unavailable", error: true)
                }
                let owner = navigation.nativeWindowID, tab = navigation.nativeTabID
                let profile = navigation.profileID
                let current: @MainActor () -> Bool = { [weak bm, weak window, weak page, weak navigation] in
                    guard let bm, let window, let page, let navigation else { return false }
                    return bm.windowRegistry?.windows[window.id] === window &&
                        bm.tabs.agentItem == page.itemID && page.navigation === navigation &&
                        navigation.nativeWindowID == owner && navigation.nativeTabID == tab &&
                        navigation.profileID == profile && !navigation.isClosed
                }
                // The existing outer tool deadline cancels these event-driven
                // waits. No native timer/polling or replacement callback exists.
                if name == "reload", page.nativeAgentNavigationIsPending,
                   !(await page.waitForNativeAgentNavigation(in: window, reload: false, while: current)) {
                    return text("Agent navigation failed or ownership changed", error: true)
                }
                let loaded = await page.waitForNativeAgentNavigation(in: window, reload: name == "reload", while: current)
                guard loaded, current() else { return text("Agent navigation failed or ownership changed", error: true) }
                return text("Loaded: \(page.url.absoluteString) | \(page.title)")
            }
            if BrowserTools.toolsByName[name] != nil {
                let executor = BrowserToolExecutor(browserManager: bm, windowState: window, agentSpace: agentSpace)
                let r = try await executor.execute(AIToolCall(name: name, arguments: args))
                return text(r.content, error: r.isError)
            }
            // Tab-tree commands do not need a renderer.
            switch name {
            case "closeTabs":
                if args["regular"] as? Bool == true {
                    guard let spaceID = space else { return text("Window has no space", error: true) }
                    let roots = bm.tabs.children(of: .tabs(spaceID: spaceID))
                    for item in roots { bm.tabs.remove(item.id) }
                    return text("Removed \(roots.count) items from the regular tabs section")
                }
                let indices = (args["indices"] as? [NSNumber] ?? []).compactMap(Self.wholeNumber)
                guard !indices.isEmpty, indices.count == (args["indices"] as? [Any])?.count,
                      indices.allSatisfy(order.indices.contains) else {
                    return text("indices must be positions from getTabList (0-\(order.count - 1))", error: true)
                }
                bm.tabs.close(indices.map { order[$0] })
                return text("Requested closure of \(indices.count) tabs")

            case "pinTab":
                guard let index = (args["index"] as? NSNumber).flatMap(Self.wholeNumber), order.indices.contains(index),
                      let spaceID = space else { return text("index must be a position from getTabList", error: true) }
                bm.tabs.pin(order[index], to: .pinned(spaceID: spaceID))
                return text("Pinned: \(bm.tabs.item(order[index])?.displayTitle ?? "")")

            case "perf", "blocker_log", "console", "network", "user_scripts":
                return text("\(name) failed: This tool is not available for Chromium pages yet", error: true)

            default:
                return text("Unknown tool: \(name)", error: true)
            }
        } catch {
            return text("\(name) failed: \(error.localizedDescription)", error: true)
        }
    }
}

// MARK: - Minimal HTTP/1.1 request parsing

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Nil until the buffer holds the full head and a Content-Length body.
    init?(_ buffer: Data) {
        guard let split = buffer.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: buffer[..<split.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let start = lines[0].split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        // A negative length would build an inverted range below and trap before the token check.
        let length = max(0, Int(headers["content-length"] ?? "0") ?? 0)
        let bodyStart = split.upperBound
        guard buffer.count - bodyStart >= length else { return nil }
        method = String(start[0])
        path = String(start[1])
        self.headers = headers
        body = buffer.subdata(in: bodyStart..<(bodyStart + length))
    }
}
