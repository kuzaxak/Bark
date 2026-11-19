// Licensed under GPL-3.0. See LICENSE.

import Foundation
import Testing
@testable import NookSettings

struct ProductDisplayNameTests {
    @Test func readsTheHostingAppsDisplayNameAndPreservesLegacyFallbacks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [([String: String], String?, String)] = [
            (["CFBundleDisplayName": "Bark", "CFBundleName": "Internal"], nil, "Bark"),
            (["CFBundleDisplayName": "Bark"], "Localized Bark", "Localized Bark"),
            (["CFBundleDisplayName": " ", "CFBundleName": "Nook"], nil, "Nook"),
            ([:], nil, "Bark"),
            (["CFBundleDisplayName": " ", "CFBundleName": ""], nil, "Bark"),
        ]
        for (index, entry) in cases.enumerated() {
            let (names, localizedDisplayName, expected) = entry
            let app = directory.appendingPathComponent("Fixture-\(index).app")
            let contents = app.appendingPathComponent("Contents")
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            var info = names
            info["CFBundleIdentifier"] = "ee.qdo.product-fixture.\(index)"
            info["CFBundlePackageType"] = "APPL"
            info["CFBundleDevelopmentRegion"] = "en"
            if let localizedDisplayName {
                let resources = contents.appendingPathComponent("Resources/en.lproj")
                try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
                try "CFBundleDisplayName = \"\(localizedDisplayName)\";".write(
                    to: resources.appendingPathComponent("InfoPlist.strings"), atomically: true, encoding: .utf8
                )
            }
            let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            try data.write(to: contents.appendingPathComponent("Info.plist"))
            let bundle = try #require(Bundle(url: app))
            #expect(ProductDisplayName.resolve(in: bundle) == expected)
        }
    }
}
