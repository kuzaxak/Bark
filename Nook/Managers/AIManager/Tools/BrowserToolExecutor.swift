// Licensed under GPL-3.0. See LICENSE.
//
//  BrowserToolExecutor.swift
//  Nook
//
//  Executes browser tool calls using BrowserManager and Chromium page APIs
//

import Foundation
import OSLog
import NookTabsCore
import NookWeb

@MainActor
class BrowserToolExecutor {
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Nook", category: "BrowserToolExecutor")

    weak var browserManager: BrowserManager?
    weak var windowState: BrowserWindowState?
    /// DevMCP's Agent space: tools act on its tabs instead of what the window shows.
    let agentSpace: UUID?

    init(browserManager: BrowserManager? = nil, windowState: BrowserWindowState? = nil, agentSpace: UUID? = nil) {
        self.browserManager = browserManager
        self.windowState = windowState
        self.agentSpace = agentSpace
    }

    // MARK: - Tool Definitions

    func availableToolDefinitions(enabledTools: Set<String>) -> [AIToolDefinition] {
        BrowserTools.allTools.filter { enabledTools.contains($0.name) }
    }

    /// Callback for requesting user confirmation before executing dangerous tools.
    /// Set by AIService to route through the standard approval UI.
    var confirmationHandler: ((_ toolName: String, _ args: [String: Any]) async -> Bool)?

    // MARK: - Execute Tool Call

    func execute(_ toolCall: AIToolCall) async throws -> AIToolResult {
        guard let browserManager = browserManager,
              let windowState = windowState else {
            return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: "Browser not available", isError: true)
        }

        // Capture before the existing approval await; approval must never retarget
        // the tool to a newer selected page or document.
        let nativeScriptTarget: NativeScriptTarget?
        if toolCall.name == "executeJavaScript" {
            nativeScriptTarget = captureNativeScriptTarget(browserManager, windowState)
        } else { nativeScriptTarget = nil }

        // SECURITY: executeJavaScript ALWAYS requires user confirmation regardless of execution mode,
        // because it can run arbitrary code on the current page.
        if toolCall.name == "executeJavaScript" {
            if let handler = confirmationHandler {
                let approved = await handler(toolCall.name, toolCall.arguments)
                if !approved {
                    Self.log.warning("User denied executeJavaScript execution")
                    return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: "User denied execution of executeJavaScript.", isError: true)
                }
            } else {
                Self.log.error("executeJavaScript called without a confirmation handler — denying by default")
                return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: "executeJavaScript requires user confirmation but no confirmation handler is available.", isError: true)
            }
        }

        if toolCall.name == "executeJavaScript",
           nativeScriptTarget == nil || !nativeScriptTargetIsCurrent(nativeScriptTarget!, browserManager, windowState) {
            return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name,
                content: "The approved page changed or is unavailable; JavaScript was not executed", isError: true)
        }
        let result: String

        switch toolCall.name {
        case "navigateToURL":
            result = try await executeNavigateToURL(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "readPageContent":
            result = try await executeReadPageContent(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "clickElement":
            result = try await executeClickElement(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "getInteractiveElements":
            result = try await executeGetInteractiveElements(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "extractStructuredData":
            result = try await executeExtractStructuredData(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "summarizePage":
            result = try await executeSummarizePage(browserManager: browserManager, windowState: windowState)
        case "searchInPage":
            result = try await executeSearchInPage(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "getTabList":
            result = executeGetTabList(browserManager: browserManager, windowState: windowState)
        case "switchTab":
            result = try executeSwitchTab(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "createTab":
            result = try executeCreateTab(toolCall.arguments, browserManager: browserManager, windowState: windowState)
        case "getSelectedText":
            result = try await executeGetSelectedText(browserManager: browserManager, windowState: windowState)
        case "executeJavaScript":
            result = try await executeJavaScript(toolCall.arguments, browserManager: browserManager,
                windowState: windowState, nativeTarget: nativeScriptTarget)
        default:
            return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: "Unknown tool: \(toolCall.name)", isError: true)
        }

        return AIToolResult(toolCallId: toolCall.id, toolName: toolCall.name, content: result)
    }

    // MARK: - Tool Implementations

    private func tabTitle(_ itemID: UUID, in tabs: TabsController) -> String {
        if let custom = tabs.item(itemID)?.customTitle, !custom.isEmpty { return custom }
        return tabs.session(for: itemID)?.title ?? tabs.item(itemID)?.displayTitle ?? ""
    }

    /// Fixed tools share the existing exact-page transport; only arbitrary
    /// executeJavaScript uses the separate pre-approval target capture above.
    private func evaluateToolScript(_ script: String, browserManager manager: BrowserManager,
        windowState window: BrowserWindowState,
        mode: ChromiumPageNavigation.ScriptMode = .expression, refusingChangedPage: Bool = false) async throws -> Any? {
        if agentSpace != nil {
            guard let page = await manager.tabs.prepareNativeAgentPage(in: window),
                  let navigation = page.navigation as? ChromiumPageNavigation else {
                throw ChromiumPageNavigation.ScriptError.unavailable
            }
            let owner = navigation.nativeWindowID, tab = navigation.nativeTabID, profile = navigation.profileID
            let current: @MainActor () -> Bool = { [weak manager, weak window, weak page, weak navigation] in
                guard let manager, let window, let page, let navigation else { return false }
                return manager.windowRegistry?.windows[window.id] === window &&
                    manager.tabs.existingNativeAgentPage(in: window) === page &&
                    page.navigation === navigation && navigation.nativeWindowID == owner &&
                    navigation.nativeTabID == tab && navigation.profileID == profile && !navigation.isClosed
            }
            if page.nativeAgentNavigationIsPending,
               !(await page.waitForNativeAgentNavigation(in: window, reload: false, while: current)) {
                throw ChromiumPageNavigation.ScriptError.cancelled
            }
            guard current() else { throw ChromiumPageNavigation.ScriptError.cancelled }
        }
        guard let target = captureNativeScriptTarget(manager, window, requiringSettledNavigation: false), !Task.isCancelled else {
            throw ChromiumPageNavigation.ScriptError.unavailable
        }
        let result = try await target.navigation.evaluateScript(script, mode: mode, world: .page)
        try Task.checkCancellation()
        if refusingChangedPage, !nativeScriptTargetIsCurrent(target, manager, window, requiringSettledNavigation: false) {
            throw ChromiumPageNavigation.ScriptError.cancelled
        }
        if result.isUndefined { return nil }
        if result.isString { return result.text }
        guard let bytes = result.json.data(using: .utf8) else {
            throw ChromiumPageNavigation.ScriptError.unserializable
        }
        return try JSONSerialization.jsonObject(with: bytes, options: .fragmentsAllowed)
    }

    /// The chat's read of the window's selected page, refused when that page or its document
    /// changed before the reply arrived.
    func evaluatePageContextScript(_ script: String, browserManager: BrowserManager,
        windowState: BrowserWindowState) async throws -> Any? {
        try await evaluateToolScript(script, browserManager: browserManager, windowState: windowState,
            refusingChangedPage: true)
    }

    private func tabOrder(_ tabs: TabsController, _ windowState: BrowserWindowState) -> [UUID] {
        agentSpace.map(tabs.displayOrder(inSpace:)) ?? tabs.displayOrder(in: windowState)
    }

    /// A new selected tab: in the Agent space when there is one, without showing it.
    @discardableResult
    private func openTab(_ url: URL, _ tabs: TabsController, _ windowState: BrowserWindowState) -> UUID? {
        tabs.open(url: url, in: windowState, placement: .newTab, parent: agentSpace.map { .tabs(spaceID: $0) })
    }

    /// JSON-encodes a string for interpolation into a script. `JSONSerialization` raises an
    /// ObjC `NSInvalidArgumentException` for a bare string at the top level unless
    /// `.fragmentsAllowed` is set, and neither `try` nor `try?` catches an ObjC exception:
    /// it unwinds through the Swift async frames, leaves the main thread's executor tracking
    /// pointing at a dead stack frame, and the next `MainActor.assumeIsolated` anywhere in the
    /// app segfaults in `swift_getObjectType`.
    private func jsLiteral(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }

    /// Only web URLs. A file: URL would load with read access to its directory, and the
    /// read tools never prompt, so a page could have a local file read and sent elsewhere.
    private func webURL(_ string: String) -> URL? {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }

    private func executeNavigateToURL(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let urlString = args["url"] as? String,
              let url = webURL(urlString) else {
            return "Invalid URL: only http and https URLs are allowed"
        }

        let newTab = args["newTab"] as? Bool ?? false
        let tabs = browserManager.tabs
        if agentSpace != nil {
            if !newTab, let id = tabs.agentItem, let session = tabs.ensureSession(for: id) {
                tabs.select(id, in: windowState)
                session.load(url)
            } else {
                openTab(url, tabs, windowState)
            }
            return "Navigated to \(urlString)\(newTab ? " in new tab" : "")"
        }

        guard browserManager.tabs.open(url: url, in: windowState, placement: newTab ? .newTab : .replaceCurrent) != nil else {
            return "No active tab"
        }

        return "Navigated to \(urlString)\(newTab ? " in new tab" : "")"
    }

    private func executeReadPageContent(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        let maxLength = args["maxLength"] as? Int ?? 8000
        let selector = args["selector"] as? String

        let script: String
        if let selector = selector {
            let selectorJSON = jsLiteral(selector)
            script = """
            (function() {
                const el = document.querySelector(\(selectorJSON));
                if (!el) return { error: 'Element not found' };
                return {
                    title: document.title,
                    url: window.location.href,
                    content: el.innerText.substring(0, \(maxLength))
                };
            })();
            """
        } else {
            script = """
            (function() {
                const clone = document.body.cloneNode(true);
                clone.querySelectorAll('script, style, noscript').forEach(el => el.remove());
                let text = clone.innerText || clone.textContent || '';
                text = text.replace(/\\s+/g, ' ').trim();
                if (text.length > \(maxLength)) text = text.substring(0, \(maxLength)) + '...';
                return { title: document.title, url: window.location.href, content: text };
            })();
            """
        }

        let result = try await evaluateToolScript(script, browserManager: browserManager, windowState: windowState)
        if let dict = result as? [String: Any] {
            if let error = dict["error"] as? String {
                return "Error: \(error)"
            }
            let title = dict["title"] as? String ?? ""
            let url = dict["url"] as? String ?? ""
            let content = dict["content"] as? String ?? ""
            return "Title: \(title)\nURL: \(url)\n\n\(content)"
        }

        return "Failed to read page content"
    }

    private func executeClickElement(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        // Support clicking by CSS selector OR by visible text
        if let selector = args["selector"] as? String, !selector.isEmpty {
            let selectorJSON = jsLiteral(selector)
            let script = """
            (function() {
                const sel = \(selectorJSON);
                const el = document.querySelector(sel);
                if (!el) return 'Element not found: ' + sel;
                el.scrollIntoView({block: 'center'});
                el.click();
                return 'Clicked element: ' + (el.textContent || '').substring(0, 100).trim();
            })();
            """
            let result = try await evaluateToolScript(script, browserManager: browserManager, windowState: windowState)
            return result as? String ?? "Click executed"
        } else if let text = args["text"] as? String, !text.isEmpty {
            let textJSON = jsLiteral(text)
            let script = """
            (function() {
                const query = \(textJSON).toLowerCase();
                const candidates = document.querySelectorAll('a, button, input[type="submit"], input[type="button"], [role="button"], [onclick], [tabindex]');
                let best = null;
                let bestScore = Infinity;
                for (const el of candidates) {
                    if (el.offsetParent === null && el.style.display !== 'contents') continue;
                    const label = (el.textContent || el.value || el.getAttribute('aria-label') || el.getAttribute('title') || '').trim();
                    const lower = label.toLowerCase();
                    if (lower === query) {
                        best = el;
                        bestScore = 0;
                        break;
                    }
                    if (lower.includes(query) && label.length < bestScore) {
                        best = el;
                        bestScore = label.length;
                    }
                }
                if (!best) return 'No clickable element found matching: ' + query;
                best.scrollIntoView({block: 'center'});
                best.click();
                return 'Clicked: ' + (best.textContent || best.value || '').substring(0, 100).trim();
            })();
            """
            let result = try await evaluateToolScript(script, browserManager: browserManager, windowState: windowState)
            return result as? String ?? "Click executed"
        } else {
            return "Provide either 'selector' (CSS) or 'text' (visible text) to identify the element"
        }
    }

    private func executeGetInteractiveElements(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        let filter = args["filter"] as? String ?? ""
        let limit = args["limit"] as? Int ?? 50
        let filterJSON = jsLiteral(filter)

        let script = """
        (function() {
            const filter = \(filterJSON).toLowerCase();
            const limit = \(limit);
            const selectors = 'a[href], button, input, select, textarea, [role="button"], [role="link"], [role="menuitem"], [onclick], [tabindex]';
            const elements = document.querySelectorAll(selectors);
            const results = [];

            for (const el of elements) {
                if (results.length >= limit) break;
                if (el.offsetParent === null && el.style.display !== 'contents' && !el.closest('label')) continue;

                const tag = el.tagName.toLowerCase();
                const type = el.getAttribute('type') || '';
                const text = (el.textContent || '').trim().substring(0, 80);
                const value = el.value || '';
                const ariaLabel = el.getAttribute('aria-label') || '';
                const placeholder = el.getAttribute('placeholder') || '';
                const href = el.getAttribute('href') || '';
                const role = el.getAttribute('role') || '';
                const name = el.getAttribute('name') || '';
                const id = el.id || '';
                const classes = el.className && typeof el.className === 'string' ? el.className.split(' ').slice(0, 3).join('.') : '';

                const label = text || ariaLabel || placeholder || value;
                if (filter && !label.toLowerCase().includes(filter) && !ariaLabel.toLowerCase().includes(filter) && !placeholder.toLowerCase().includes(filter)) continue;
                if (!label && tag === 'input' && type === 'hidden') continue;

                let selector = '';
                if (id) selector = '#' + CSS.escape(id);
                else if (name) selector = tag + '[name="' + name + '"]';
                else if (ariaLabel) selector = tag + '[aria-label="' + ariaLabel.replace(/"/g, '\\\\"') + '"]';
                else if (classes) selector = tag + '.' + classes.split('.').map(c => CSS.escape(c.trim())).filter(c => c).join('.');

                const entry = { tag, text: text.substring(0, 60) };
                if (type) entry.type = type;
                if (href) entry.href = href.substring(0, 100);
                if (ariaLabel) entry.ariaLabel = ariaLabel;
                if (placeholder) entry.placeholder = placeholder;
                if (selector) entry.selector = selector;
                if (role) entry.role = role;

                results.push(entry);
            }
            return JSON.stringify(results);
        })();
        """

        let result = try await evaluateToolScript(script, browserManager: browserManager, windowState: windowState)
        if let jsonString = result as? String {
            return jsonString
        }
        return "[]"
    }

    private func executeExtractStructuredData(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let type = args["type"] as? String else {
            return "Missing type parameter"
        }

        let script: String
        switch type {
        case "schema_org":
            script = """
            (function() {
                const scripts = document.querySelectorAll('script[type="application/ld+json"]');
                const data = [];
                scripts.forEach(s => { try { data.push(JSON.parse(s.textContent)); } catch(e) {} });
                return JSON.stringify(data, null, 2);
            })();
            """
        case "open_graph":
            script = """
            (function() {
                const og = {};
                document.querySelectorAll('meta[property^="og:"]').forEach(m => {
                    og[m.getAttribute('property')] = m.getAttribute('content');
                });
                return JSON.stringify(og, null, 2);
            })();
            """
        case "meta":
            script = """
            (function() {
                const meta = {};
                document.querySelectorAll('meta[name], meta[property]').forEach(m => {
                    const key = m.getAttribute('name') || m.getAttribute('property');
                    meta[key] = m.getAttribute('content');
                });
                return JSON.stringify(meta, null, 2);
            })();
            """
        case "custom":
            guard let selectors = args["selectors"] as? [String] else {
                return "Missing selectors for custom extraction"
            }
            let selectorsJSON = (try? String(data: JSONSerialization.data(withJSONObject: selectors), encoding: .utf8)) ?? "[]"
            script = """
            (function() {
                const selectors = \(selectorsJSON);
                const results = {};
                selectors.forEach(s => {
                    const els = document.querySelectorAll(s);
                    results[s] = Array.from(els).map(e => e.innerText.trim()).filter(t => t);
                });
                return JSON.stringify(results, null, 2);
            })();
            """
        default:
            return "Unknown extraction type: \(type)"
        }

        let result = try await evaluateToolScript(script, browserManager: browserManager, windowState: windowState)
        return result as? String ?? "No data found"
    }

    private func executeSummarizePage(browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        let script = """
        (function() {
            const clone = document.body.cloneNode(true);
            clone.querySelectorAll('script, style, noscript, nav, footer, header').forEach(el => el.remove());
            let text = clone.innerText || clone.textContent || '';
            text = text.replace(/\\s+/g, ' ').trim();
            if (text.length > 16000) text = text.substring(0, 16000) + '...';
            return { title: document.title, url: window.location.href, content: text, length: text.length };
        })();
        """

        let result = try await evaluateToolScript(script, browserManager: browserManager, windowState: windowState)
        if let dict = result as? [String: Any] {
            let title = dict["title"] as? String ?? ""
            let url = dict["url"] as? String ?? ""
            let content = dict["content"] as? String ?? ""
            return "Title: \(title)\nURL: \(url)\n\n\(content)"
        }

        return "Failed to read page"
    }

    private func executeSearchInPage(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        guard let query = args["query"] as? String else {
            return "Missing query parameter"
        }

        // The query goes in as an argument. Interpolating it meant JSON-encoding a
        // bare String, which JSONSerialization rejects as an invalid top-level type
        // by raising an ObjC exception rather than returning an error.
        let script = """
        const text = document.body.innerText;
        const needle = query.toLowerCase();
        const hay = text.toLowerCase();
        const matches = [];
        let idx = needle ? hay.indexOf(needle) : -1;
        while (idx !== -1 && matches.length < 10) {
            const start = Math.max(0, idx - 50);
            const end = Math.min(text.length, idx + needle.length + 50);
            matches.push({ index: idx, context: text.substring(start, end) });
            idx = hay.indexOf(needle, idx + needle.length);
        }
        return JSON.stringify({ count: matches.length, matches: matches });
        """

        // JSON encoding keeps the query data rather than executable source.
        let result = try await evaluateToolScript("const query = \(jsLiteral(query));\n" + script,
            browserManager: browserManager, windowState: windowState, mode: .asyncBody)
        return result as? String ?? "No matches found"
    }

    private func executeGetTabList(browserManager: BrowserManager, windowState: BrowserWindowState) -> String {
        let controller = browserManager.tabs
        let order = tabOrder(controller, windowState)
        guard !order.isEmpty else {
            return "No tabs available"
        }

        var tabList: [[String: Any]] = []
        for (index, itemID) in order.enumerated() {
            tabList.append([
                "index": index,
                "title": tabTitle(itemID, in: controller),
                "url": (controller.session(for: itemID)?.url ?? controller.item(itemID)?.url)?.absoluteString ?? "",
                "isActive": itemID == (agentSpace != nil ? controller.agentItem : windowState.selectedItemID)
            ])
        }

        let data = try? JSONSerialization.data(withJSONObject: tabList, options: .prettyPrinted)
        return String(data: data ?? Data(), encoding: .utf8) ?? "[]"
    }

    private func executeSwitchTab(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) throws -> String {
        guard let index = args["index"] as? Int else {
            return "Missing index parameter"
        }

        let controller = browserManager.tabs
        let order = tabOrder(controller, windowState)
        guard !order.isEmpty else {
            return "No tabs available"
        }
        guard order.indices.contains(index) else {
            return "Tab index \(index) out of range (0-\(order.count - 1))"
        }

        controller.select(order[index], in: windowState)
        return "Switched to tab: \(tabTitle(order[index], in: controller))"
    }

    private func executeCreateTab(_ args: [String: Any], browserManager: BrowserManager, windowState: BrowserWindowState) throws -> String {
        if let urlString = args["url"] as? String, !urlString.isEmpty {
            guard let url = webURL(urlString) else {
                return "Invalid URL: only http and https URLs are allowed"
            }
            openTab(url, browserManager.tabs, windowState)
            return "Created new tab with URL: \(urlString)"
        }

        openTab(TabsController.homeURL, browserManager.tabs, windowState)

        return "Created new empty tab"
    }

    private func executeGetSelectedText(browserManager: BrowserManager, windowState: BrowserWindowState) async throws -> String {
        let script = "window.getSelection().toString();"
        let result = try await evaluateToolScript(script, browserManager: browserManager, windowState: windowState)
        let text = result as? String ?? ""
        return text.isEmpty ? "No text selected" : text
    }

    private struct NativeScriptTarget {
        let page: PageSession
        let navigation: ChromiumPageNavigation
        let serial: UInt64
        let window: Int32
        let tab: Int32
        let profile: UUID?
    }

    private func captureNativeScriptTarget(_ manager: BrowserManager,
        _ window: BrowserWindowState, requiringSettledNavigation: Bool = true) -> NativeScriptTarget? {
        let page = agentSpace != nil ? manager.tabs.existingNativeAgentPage(in: window)
            : manager.tabs.controllableSession(in: window)
        guard manager.windowRegistry?.windows[window.id] === window,
              let page, let navigation = page.navigation as? ChromiumPageNavigation,
              !requiringSettledNavigation || (!page.isLoading && !page.nativeAgentNavigationIsPending && !navigation.state.isLoading),
              !navigation.isClosed, navigation.nativeWindowID > 0 else { return nil }
        return NativeScriptTarget(page: page, navigation: navigation,
            serial: page.nativeNavigationSerial, window: navigation.nativeWindowID,
            tab: navigation.nativeTabID, profile: navigation.profileID)
    }

    private func nativeScriptTargetIsCurrent(_ target: NativeScriptTarget,
        _ manager: BrowserManager, _ window: BrowserWindowState, requiringSettledNavigation: Bool = true) -> Bool {
        guard let now = captureNativeScriptTarget(manager, window, requiringSettledNavigation: requiringSettledNavigation) else { return false }
        return now.page === target.page && now.navigation === target.navigation &&
            now.serial == target.serial && now.window == target.window &&
            now.tab == target.tab && now.profile == target.profile
    }

    private func executeJavaScript(_ args: [String: Any], browserManager: BrowserManager,
        windowState: BrowserWindowState, nativeTarget: NativeScriptTarget?) async throws -> String {
        guard let code = args["code"] as? String else {
            return "Missing code parameter"
        }

        guard let target = nativeTarget,
              nativeScriptTargetIsCurrent(target, browserManager, windowState) else {
            return "The approved page changed or is unavailable; JavaScript was not executed"
        }
        return try await target.navigation.evaluateScript(code, mode: .expression, world: .page).browserToolText
    }
}
