// Licensed under GPL-3.0. See LICENSE.
//
//  ExtensionModels.swift
//  Nook
//
//  Simplified extension models using native WKWebExtension support
//

import Foundation
import SwiftData

@Model
final class ExtensionEntity {
    @Attribute(.unique) var id: String
    // Extensions are global: one install, one enabled state, and one storage namespace
    // shared by every profile. Private (ephemeral) tabs never see extensions.
    var name: String
    var version: String
    var manifestVersion: Int
    var extensionDescription: String?
    var isEnabled: Bool
    var installDate: Date
    var lastUpdateDate: Date
    var packagePath: String // Path to the extension package
    var iconPath: String?
    var grantedOptionalPermissions: [String]?
    var grantedOptionalMatchPatterns: [String]?
    /// Store the extension came from ("chrome" or "edge"). When set, `id` is the store's
    /// extension ID and the extension receives automatic updates from that store.
    var sourceStore: String?

    init(
        id: String,
        name: String,
        version: String,
        manifestVersion: Int,
        extensionDescription: String? = nil,
        isEnabled: Bool = true,
        installDate: Date = Date(),
        lastUpdateDate: Date = Date(),
        packagePath: String,
        iconPath: String? = nil,
        grantedOptionalPermissions: [String] = [],
        grantedOptionalMatchPatterns: [String] = []
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.manifestVersion = manifestVersion
        self.extensionDescription = extensionDescription
        self.isEnabled = isEnabled
        self.installDate = installDate
        self.lastUpdateDate = lastUpdateDate
        self.packagePath = packagePath
        self.iconPath = iconPath
        self.grantedOptionalPermissions = grantedOptionalPermissions
        self.grantedOptionalMatchPatterns = grantedOptionalMatchPatterns
    }
}
