// Licensed under GPL-3.0. See LICENSE.
import Foundation
import Testing
import WebKit
@testable import NookWeb

/// Chromium's picker returns a selector; the scripts here read the rest of the element as the
/// WebKit picker sends it.
@MainActor
struct DevPickDescribeTests {
    private final class Loaded: NSObject, WKNavigationDelegate {
        var done: CheckedContinuation<Void, Never>?
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { done?.resume(); done = nil }
    }

    @Test func aPickedSelectorReadsAsTheWebKitPickerSendsTheElement() async throws {
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let loaded = Loaded()
        view.navigationDelegate = loaded
        await withCheckedContinuation { continuation in
            loaded.done = continuation
            view.loadHTMLString("<main><button id=go class=primary style='width:120px'>Go now</button></main>",
                                baseURL: URL(string: "https://fixture.test/page")!)
        }
        let isolated = WKContentWorld.world(name: "DevPickDescribeTests")
        let describe = try #require(DevPickerScript.describeScript(selector: "#go"))
        let body = try await view.callAsyncJavaScript(describe, arguments: [:], in: nil, contentWorld: isolated)
        let element = try #require(DevPickedElement(message: body as Any))
        #expect(element.url == "https://fixture.test/page" && element.selector == "#go" && element.tag == "button")
        #expect(element.name == "Go now" && element.html.contains("Go now") && element.rect.width == 120)
        #expect(element.styles.contains { $0.0 == "width" && $0.1 == "120px" })

        let missing = try await view.callAsyncJavaScript(try #require(DevPickerScript.describeScript(selector: "#gone")),
                                                         arguments: [:], in: nil, contentWorld: isolated)
        #expect(missing == nil || missing is NSNull, "nothing at the selector, nothing to hand off")

        let hints = try await view.callAsyncJavaScript(try #require(DevPickerScript.hintsScript(selector: "#go")),
                                                       arguments: [:], in: nil, contentWorld: .page)
        #expect(hints is [String: Any], "the page world adds what only it sees")
        #expect(DevPickerScript.describeScript(selector: "x\u{2028}y")?.contains("\u{2028}") == false, "the selector stays a string literal")
    }
}
