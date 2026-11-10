import Foundation
import Security

/// API keys live in the Keychain on this device only (no iCloud Keychain sync: kSecAttrSynchronizable is not set).
enum Keychain {
    private static let service = "org.schrodinger.app"

    static func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
        if value.isEmpty { SecItemDelete(query as CFDictionary); return }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func get(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key,
                                    kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
}

/// App settings (UserDefaults for non-secret values, Keychain for the API key).
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var provider: ProviderKind { didSet { d.set(provider.rawValue, forKey: "provider") } }
    var claudeModel: String { didSet { d.set(claudeModel, forKey: "claudeModel") } }
    var harnessIntervalMinutes: Int { didSet { d.set(harnessIntervalMinutes, forKey: "harnessInterval") } }
    var staleDays: Int { didSet { d.set(staleDays, forKey: "staleDays") } }
    var maxTasksPerRun: Int { didSet { d.set(maxTasksPerRun, forKey: "maxTasksPerRun") } }
    var agentMaxTurns: Int { didSet { d.set(agentMaxTurns, forKey: "agentMaxTurns") } }
    var iCloudSync: Bool { didSet { d.set(iCloudSync, forKey: "iCloudSync") } }   // takes effect on next launch
    var anthropicKey: String {
        get { Keychain.get("anthropic_api_key") ?? "" }
        set { Keychain.set(newValue, for: "anthropic_api_key") }
    }

    private init() {
        provider = ProviderKind(rawValue: d.string(forKey: "provider") ?? "") ?? (AppleIntelligenceProvider.availability.available ? .apple : .mock)
        claudeModel = d.string(forKey: "claudeModel") ?? "claude-sonnet-4-5"
        harnessIntervalMinutes = d.object(forKey: "harnessInterval") as? Int ?? 30
        staleDays = d.object(forKey: "staleDays") as? Int ?? 5
        maxTasksPerRun = d.object(forKey: "maxTasksPerRun") as? Int ?? 3
        agentMaxTurns = d.object(forKey: "agentMaxTurns") as? Int ?? 12
        iCloudSync = d.bool(forKey: "iCloudSync")
    }

    func makeProvider() -> any LanguageModelProvider {
        switch provider {
        case .apple: AppleIntelligenceProvider()
        case .claude: anthropicKey.isEmpty ? MockProvider() : ClaudeProvider(apiKey: anthropicKey, model: claudeModel)
        case .mock: MockProvider()
        }
    }
}
