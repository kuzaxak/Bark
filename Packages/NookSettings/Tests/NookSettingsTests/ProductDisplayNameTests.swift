// Licensed under GPL-3.0. See LICENSE.

import Foundation
import Testing
@testable import NookSettings

struct ProductDisplayNameTests {
    @Test func readsTheHostingAppsDisplayNameAndPreservesLegacyFallbacks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [([String: String], String)] = [
            (["CFBundleDisplayName": "Bark", "CFBundleName": "Internal"], "Bark"),
            (["CFBundleDisplayName": " ", "CFBundleName": "Nook"], "Nook"),
            ([:], "Nook"),
        ]
        for (index, entry) in cases.enumerated() {
            let (names, expected) = entry
            let app = directory.appendingPathComponent("Fixture-\(index).app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info = names
            info["CFBundleIdentifier"] = "ee.qdo.product-fixture.\(index)"
            info["CFBundlePackageType"] = "APPL"
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            let bundle = try #require(Bundle(url: app))
            #expect(ProductDisplayName.resolve(in: bundle) == expected)
        }
    }
}
