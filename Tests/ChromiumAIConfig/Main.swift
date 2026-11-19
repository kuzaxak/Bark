// Licensed under GPL-3.0. See LICENSE.
// Compiles the shipped AIConfigService and AIKeychainStorage. check.py runs this with a synthetic
// home and refuses a binary that links SecItem: the functions below shadow Security's, so no
// keychain and no real configuration file can be reached.
import Foundation
import NookSettings
import Security

struct KeychainCall: Equatable { let service: String; let account: String }
nonisolated(unsafe) var keychainCalls: [KeychainCall] = []
nonisolated(unsafe) var keychainItems: [String: Data] = [:]

private func call(_ query: CFDictionary) -> KeychainCall {
    let query = query as NSDictionary
    let call = KeychainCall(service: query[kSecAttrService as String] as! String, account: query[kSecAttrAccount as String] as! String)
    keychainCalls.append(call)
    return call
}
private func itemKey(_ call: KeychainCall) -> String { call.service + "|" + call.account }

func SecItemCopyMatching(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    guard let data = keychainItems[itemKey(call(query))] else { return errSecItemNotFound }
    result?.pointee = data as CFData
    return errSecSuccess
}
func SecItemAdd(_ query: CFDictionary, _ result: UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus {
    keychainItems[itemKey(call(query))] = (query as NSDictionary)[kSecValueData as String] as? Data
    return errSecSuccess
}
func SecItemUpdate(_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus {
    keychainItems[itemKey(call(query))] = (attributes as NSDictionary)[kSecValueData as String] as? Data
    return errSecSuccess
}
func SecItemDelete(_ query: CFDictionary) -> OSStatus {
    keychainItems[itemKey(call(query))] = nil
    return errSecSuccess
}

struct AITranslationModel { init(providerId: String, modelId: String, send: @escaping @Sendable (String, String) async throws -> String) {} }
enum PageTranslationSetting { case onDevice, ai(AITranslationModel?) }
struct AITranslationModelUnavailable: Error { let reason: String }
enum AIService { static func hostedProvider(for provider: AIProviderConfig) -> AIProviderProtocol? { nil } }
enum AppleIntelligenceProvider {
    static let providerId = "apple-intelligence", modelId = "apple-on-device", isAvailable = false
}
struct URLCitation: Equatable, Codable { let url: String; let title: String?; let content: String?; let startIndex: Int; let endIndex: Int }

@main struct Main {
    @MainActor static func main() throws {
        let files = FileManager.default
        let home = ProcessInfo.processInfo.environment["CFFIXED_USER_HOME"] ?? ""
        let synthetic = URL(fileURLWithPath: home).resolvingSymlinksInPath()
        let scratch = synthetic.deletingLastPathComponent()
        let executable = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        guard !home.isEmpty else { fatalError("missing synthetic home") }
        let legacyURL = synthetic.appendingPathComponent("Library/Application Support/Nook/ai_config.json")
        guard !home.isEmpty, synthetic.lastPathComponent == "home",
              scratch.lastPathComponent.hasPrefix("bark-ai-config-"),
              executable.lastPathComponent == scratch.lastPathComponent,
              executable.deletingLastPathComponent().path == scratch.path else {
            fatalError("refusing to run outside the synthetic home")
        }
        let legacyKey = "com.nook.aiProvider|gemini", fakeKey = "fake-key-not-a-secret"
        keychainItems[legacyKey] = Data("previous-value".utf8)
        precondition(AIKeychainStorage.shared.apiKey(for: "gemini") == nil)
        precondition(!AIKeychainStorage.shared.saveAPIKey(fakeKey, for: "gemini"))
        precondition(!AIKeychainStorage.shared.deleteAPIKey(for: "gemini"))
        precondition(keychainCalls.isEmpty, "unconfigured storage must not query Security")
        let migrated = "ai_config_migrated_v1"
        precondition(UserDefaults.standard.object(forKey: migrated) == nil)
        let legacyDefaults = [
            "settings.geminiApiKey": "fake-legacy-key", "settings.aiProvider": "gemini", "settings.geminiModel": "legacy-model",
        ]
        UserDefaults.standard.register(defaults: legacyDefaults)

        let roots = URL(fileURLWithPath: home).appendingPathComponent("roots", isDirectory: true)
        let injected = roots.appendingPathComponent("a/App/ai_config.json")
        let first = AIConfigService(configURL: injected, keychainService: "synthetic.a")
        precondition(files.fileExists(atPath: injected.path), "the injected file is written")
        let mode = try files.attributesOfItem(atPath: injected.path)[.posixPermissions] as? NSNumber
        precondition(mode?.intValue == 0o600, "owner-only like the default file")
        precondition(first.config.activeProviderId != "gemini" && first.config.activeModelId != "legacy-model", "nothing migrated")
        precondition(UserDefaults.standard.object(forKey: migrated) == nil, "no migration mark")
        precondition(keychainItems == [legacyKey: Data("previous-value".utf8)], "no legacy key moved")

        let defaultPrompt = AIGenerationConfig.defaultSystemPrompt
        precondition(defaultPrompt.hasPrefix("You are the assistant in Bark,"))
        precondition(first.generationConfig.systemPrompt == defaultPrompt, "fresh Bark config uses the renamed prompt")
        let oldStockPrompt = defaultPrompt.replacingOccurrences(of: "assistant in Bark,", with: "assistant in Nook,")
        func reopen(with prompt: String) -> AIConfigService {
            var config = first.generationConfig
            config.systemPrompt = prompt
            first.generationConfig = config
            return AIConfigService(configURL: injected, keychainService: "synthetic.a")
        }
        let upgraded = reopen(with: oldStockPrompt)
        precondition(upgraded.generationConfig.systemPrompt == defaultPrompt, "the exact previous default is renamed")
        let upgradedData = try Data(contentsOf: injected)
        let upgradedConfig = try JSONDecoder().decode(AIConfiguration.self, from: upgradedData)
        precondition(upgradedConfig.generationConfig.systemPrompt == defaultPrompt, "the renamed default survives reload")
        for custom in [oldStockPrompt + "\n", "  Use Nook in historical comparisons.\n"] {
            let reopened = reopen(with: custom)
            precondition(reopened.generationConfig.systemPrompt.utf8.elementsEqual(custom.utf8),
                         "a custom prompt's original UTF-8 bytes are preserved")
        }

        first.updateProviderAPIKey("gemini", apiKey: fakeKey)
        first.setActiveProvider("gemini")
        first.addModelById("synthetic-model", displayName: nil, providerId: "gemini")
        first.setActiveModel("synthetic-model")
        let gemini = first.providers.first { $0.id == "gemini" }!
        precondition(gemini.apiKey == fakeKey)
        let saved = try String(contentsOf: injected, encoding: .utf8)
        precondition(!saved.contains(fakeKey), "keys stay out of the file")

        let reloaded = AIConfigService(configURL: injected, keychainService: "synthetic.a")
        precondition(reloaded.config.activeModelId == "synthetic-model" && reloaded.activeProvider?.id == "gemini")
        precondition(reloaded.activeProvider?.apiKey == fakeKey)

        let second = AIConfigService(configURL: roots.appendingPathComponent("b/App/ai_config.json"), keychainService: "synthetic.b")
        precondition(second.providers.first { $0.id == "gemini" }?.apiKey == "", "another service sees no key")
        precondition(second.config.activeModelId == nil, "another file sees no model")

        precondition(!keychainCalls.isEmpty && keychainCalls.allSatisfy { $0.service.hasPrefix("synthetic.") }, "only the injected services")
        precondition(!files.fileExists(atPath: legacyURL.deletingLastPathComponent().path))
        precondition(keychainItems[legacyKey] == Data("previous-value".utf8))
        precondition(UserDefaults.standard.object(forKey: migrated) == nil)
        for (key, value) in legacyDefaults {
            precondition(UserDefaults.standard.string(forKey: key) == value)
        }
        print("AI config: existing file, custom settings and injected service preserved; legacy keys untouched")
    }
}
