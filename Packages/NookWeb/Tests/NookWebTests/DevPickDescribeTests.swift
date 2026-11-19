// Licensed under GPL-3.0. See LICENSE.
import Testing
@testable import NookWeb

struct DevPickDescribeTests {
    @Test func scriptsPassTheSelectorAsAJavaScriptStringLiteral() throws {
        let selector = "#quoted\"\n\u{2028}"
        let describe = try #require(DevPickerScript.describeScript(selector: selector))
        let hints = try #require(DevPickerScript.hintsScript(selector: selector))
        for script in [describe, hints] {
            #expect(script.contains(#"#quoted\"\n\u2028"#))
            #expect(!script.contains("\u{2028}"))
        }
    }
}
