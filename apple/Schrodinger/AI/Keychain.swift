import Foundation
import Security

/// API keys live in the Keychain and sync between the user's own devices through iCloud Keychain (end-to-end
/// encrypted; needs iCloud Keychain turned on). A key entered on one device is there on the others. Where a synced
/// item can't be stored (iCloud Keychain off, or a build without the entitlement), the key is kept on this device only.
enum Keychain {
    private static let service = "org.schrodinger.app"

    /// The item as it was stored before keys synced: this device only.
    private static func local(_ key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: key]
    }
    /// The synced item.
    private static func synced(_ key: String) -> [String: Any] {
        var q = local(key)
        q[kSecAttrSynchronizable as String] = true
        q[kSecUseDataProtectionKeychain as String] = true
        return q
    }
    private static func read(_ query: [String: Any]) -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }
    @discardableResult
    private static func addSynced(_ value: String, for key: String) -> Bool {
        var add = synced(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func set(_ value: String, for key: String) {
        SecItemDelete(synced(key) as CFDictionary)
        SecItemDelete(local(key) as CFDictionary)
        if value.isEmpty { return }
        if addSynced(value, for: key) { return }
        var add = local(key)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        if let v = read(synced(key)) { return v }
        guard let v = read(local(key)) else { return nil }
        // A key saved before keys synced: move it into the synced keychain so the other devices get it.
        if addSynced(v, for: key) { SecItemDelete(local(key) as CFDictionary) }
        return v
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
    /// The calendar that calendared items are added to as events; empty = none chosen (no calendar is touched).
    var syncCalendarID: String { didSet { d.set(syncCalendarID, forKey: "syncCalendarID") } }
    /// Notifications for dated items (see Reminders). Off until turned on in Settings, which asks for permission.
    var remindersOn: Bool { didSet { d.set(remindersOn, forKey: "remindersOn") } }
    /// Minutes before a timed item's time that its notification goes off (0 = at the time).
    var reminderLeadMinutes: Int { didSet { d.set(reminderLeadMinutes, forKey: "reminderLead") } }
    /// Hour of the day an all-day item's notification goes off.
    var allDayReminderHour: Int { didSet { d.set(allDayReminderHour, forKey: "allDayReminderHour") } }
    var anthropicKey: String {
        get { Keychain.get("anthropic_api_key") ?? "" }
        set { Keychain.set(newValue, for: "anthropic_api_key") }
    }

    private init() {
        // No provider chosen on this device yet: a Claude key that arrived from another device (iCloud Keychain) selects Claude.
        provider = ProviderKind(rawValue: d.string(forKey: "provider") ?? "")
            ?? (!(Keychain.get("anthropic_api_key") ?? "").isEmpty ? .claude : AppleIntelligenceProvider.availability.available ? .apple : .mock)
        claudeModel = d.string(forKey: "claudeModel") ?? "claude-sonnet-4-5"
        harnessIntervalMinutes = d.object(forKey: "harnessInterval") as? Int ?? 30
        staleDays = d.object(forKey: "staleDays") as? Int ?? 5
        maxTasksPerRun = d.object(forKey: "maxTasksPerRun") as? Int ?? 3
        agentMaxTurns = d.object(forKey: "agentMaxTurns") as? Int ?? 12
        iCloudSync = d.bool(forKey: "iCloudSync")
        syncCalendarID = d.string(forKey: "syncCalendarID") ?? ""
        remindersOn = d.bool(forKey: "remindersOn")
        reminderLeadMinutes = d.object(forKey: "reminderLead") as? Int ?? 0
        allDayReminderHour = d.object(forKey: "allDayReminderHour") as? Int ?? 9
    }

    func makeProvider() -> any LanguageModelProvider {
        switch provider {
        case .apple: AppleIntelligenceProvider()
        case .claude: anthropicKey.isEmpty ? MockProvider() : ClaudeProvider(apiKey: anthropicKey, model: claudeModel)
        case .mock: MockProvider()
        }
    }
}
