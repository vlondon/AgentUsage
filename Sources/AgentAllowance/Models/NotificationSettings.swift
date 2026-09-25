import Foundation
import Observation

enum IPhonePushService: String, Codable, CaseIterable, Identifiable, Sendable {
    case pushover = "Pushover"
    case simplepush = "Simplepush"
    case ntfy = "ntfy"

    var id: String { rawValue }
}

struct NotificationSettings: Codable, Equatable, Sendable {
    var macNotificationsEnabled: Bool
    var iphoneNotificationsEnabled: Bool
    var iphoneService: IPhonePushService
    var pushoverUserKey: String
    var pushoverApiToken: String
    var simplepushKey: String
    var ntfyTopic: String
    var ntfyServer: String
    var notifyOnReset: Bool
    var notifyOnLowAllowance: Bool
    var lowAllowanceThreshold: Int
    var backgroundRefreshIntervalMinutes: Int

    static let allowedTopicCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_~")

    init(
        macNotificationsEnabled: Bool = false,
        iphoneNotificationsEnabled: Bool = false,
        iphoneService: IPhonePushService = .pushover,
        pushoverUserKey: String = "",
        pushoverApiToken: String = "",
        simplepushKey: String = "",
        ntfyTopic: String = "",
        ntfyServer: String = "https://ntfy.sh",
        notifyOnReset: Bool = true,
        notifyOnLowAllowance: Bool = false,
        lowAllowanceThreshold: Int = 10,
        backgroundRefreshIntervalMinutes: Int = 5
    ) {
        self.macNotificationsEnabled = macNotificationsEnabled
        self.iphoneNotificationsEnabled = iphoneNotificationsEnabled
        self.iphoneService = iphoneService
        self.pushoverUserKey = pushoverUserKey
        self.pushoverApiToken = pushoverApiToken
        self.simplepushKey = simplepushKey
        self.ntfyTopic = ntfyTopic
        self.ntfyServer = ntfyServer
        self.notifyOnReset = notifyOnReset
        self.notifyOnLowAllowance = notifyOnLowAllowance
        self.lowAllowanceThreshold = lowAllowanceThreshold
        self.backgroundRefreshIntervalMinutes = backgroundRefreshIntervalMinutes
    }

    enum CodingKeys: String, CodingKey {
        case macNotificationsEnabled
        case iphoneNotificationsEnabled
        case iphoneService
        case pushoverUserKey
        case pushoverApiToken
        case simplepushKey
        case ntfyTopic
        case ntfyServer
        case notifyOnReset
        case notifyOnLowAllowance
        case lowAllowanceThreshold
        case backgroundRefreshIntervalMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.macNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .macNotificationsEnabled) ?? false
        self.iphoneNotificationsEnabled = try container.decodeIfPresent(Bool.self, forKey: .iphoneNotificationsEnabled) ?? false
        self.iphoneService = try container.decodeIfPresent(IPhonePushService.self, forKey: .iphoneService) ?? .pushover
        self.pushoverUserKey = try container.decodeIfPresent(String.self, forKey: .pushoverUserKey) ?? ""
        self.pushoverApiToken = try container.decodeIfPresent(String.self, forKey: .pushoverApiToken) ?? ""
        self.simplepushKey = try container.decodeIfPresent(String.self, forKey: .simplepushKey) ?? ""
        self.ntfyTopic = try container.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? ""
        self.ntfyServer = try container.decodeIfPresent(String.self, forKey: .ntfyServer) ?? "https://ntfy.sh"
        self.notifyOnReset = try container.decodeIfPresent(Bool.self, forKey: .notifyOnReset) ?? true
        self.notifyOnLowAllowance = try container.decodeIfPresent(Bool.self, forKey: .notifyOnLowAllowance) ?? false
        self.lowAllowanceThreshold = try container.decodeIfPresent(Int.self, forKey: .lowAllowanceThreshold) ?? 10
        self.backgroundRefreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .backgroundRefreshIntervalMinutes) ?? 5
    }

    /// Push credentials are kept in the Keychain and left out of the encoded settings.
    /// They are still decoded so values saved by older builds can be migrated.
    static var secretFields: [(account: String, keyPath: WritableKeyPath<NotificationSettings, String>)] {
        [
            ("pushoverUserKey", \.pushoverUserKey),
            ("pushoverApiToken", \.pushoverApiToken),
            ("simplepushKey", \.simplepushKey)
        ]
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(macNotificationsEnabled, forKey: .macNotificationsEnabled)
        try container.encode(iphoneNotificationsEnabled, forKey: .iphoneNotificationsEnabled)
        try container.encode(iphoneService, forKey: .iphoneService)
        try container.encode(ntfyTopic, forKey: .ntfyTopic)
        try container.encode(ntfyServer, forKey: .ntfyServer)
        try container.encode(notifyOnReset, forKey: .notifyOnReset)
        try container.encode(notifyOnLowAllowance, forKey: .notifyOnLowAllowance)
        try container.encode(lowAllowanceThreshold, forKey: .lowAllowanceThreshold)
        try container.encode(backgroundRefreshIntervalMinutes, forKey: .backgroundRefreshIntervalMinutes)
    }

    var isAnyNotificationEnabled: Bool {
        macNotificationsEnabled || iphoneNotificationsEnabled
    }

    var trimmedPushoverUserKey: String {
        pushoverUserKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedPushoverApiToken: String {
        pushoverApiToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isPushoverConfigured: Bool {
        !trimmedPushoverUserKey.isEmpty && !trimmedPushoverApiToken.isEmpty
    }

    var trimmedSimplepushKey: String {
        simplepushKey.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isSimplepushConfigured: Bool {
        !trimmedSimplepushKey.isEmpty
    }

    var trimmedNtfyTopic: String {
        let trimmed = ntfyTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        return String(trimmed.unicodeScalars.filter { Self.allowedTopicCharacters.contains($0) })
    }

    var isTopicValid: Bool {
        let topic = ntfyTopic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !topic.isEmpty else { return false }
        return topic.unicodeScalars.allSatisfy { Self.allowedTopicCharacters.contains($0) }
    }

    var cleanedNtfyServer: String {
        var server = ntfyServer.trimmingCharacters(in: .whitespacesAndNewlines)
        if server.isEmpty {
            server = "https://ntfy.sh"
        }
        if !server.hasPrefix("http://") && !server.hasPrefix("https://") {
            server = "https://" + server
        }
        while server.hasSuffix("/") {
            server.removeLast()
        }
        return server
    }

    static func generateRandomTopic() -> String {
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        let randomSuffix = String((0..<8).compactMap { _ in chars.randomElement() })
        return "allowance-\(randomSuffix)"
    }
}

@MainActor
@Observable
final class SettingsStore {
    private static let userDefaultsKey = "com.vlondon.AgentAllowance.NotificationSettings"
    /// Keychain writes that have not succeeded yet. Only values that were already on disk in
    /// plain text before the Keychain move, and empty "delete" markers, are ever stored here;
    /// a newly entered credential the Keychain refuses stays in memory only.
    private static let unsyncedSecretsKey = "com.vlondon.AgentAllowance.UnsyncedSecrets"
    private static let secretLabels = [
        "pushoverUserKey": "Pushover User Key",
        "pushoverApiToken": "Pushover API Token",
        "simplepushKey": "Simplepush Key"
    ]

    private let userDefaults: UserDefaults
    private let secretStore: any SecretStore
    /// Outstanding Keychain writes by account, retried on every save (empty value = delete).
    private var unsyncedSecrets: [String: String] = [:]
    /// Plain-text values found on disk at launch; only these may be written back while unsynced.
    private var legacyPlaintext: [String: String] = [:]
    private var readErrors: [String: String] = [:]
    private var writeErrors: [String: String] = [:]
    private var isApplyingKeychainValues = false

    var onSettingsChanged: (@Sendable () -> Void)?

    var settings: NotificationSettings {
        didSet {
            if !isApplyingKeychainValues {
                saveSecrets(changedFrom: oldValue)
            }
            save()
            if oldValue.isAnyNotificationEnabled != settings.isAnyNotificationEnabled ||
               oldValue.backgroundRefreshIntervalMinutes != settings.backgroundRefreshIntervalMinutes {
                onSettingsChanged?()
            }
        }
    }

    /// Keychain problems to show in Settings, or nil when every credential is stored.
    var credentialStorageError: String? {
        let messages = NotificationSettings.secretFields.compactMap { readErrors[$0.account] ?? writeErrors[$0.account] }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    init(userDefaults: UserDefaults = .standard, secretStore: any SecretStore = KeychainSecretStore()) {
        self.userDefaults = userDefaults
        self.secretStore = secretStore
        // Property observers do not run during init, so these assignments save nothing.
        self.settings = NotificationSettings()

        let storedUnsynced = userDefaults.dictionary(forKey: Self.unsyncedSecretsKey) as? [String: String] ?? [:]
        var loaded = NotificationSettings()
        if let data = userDefaults.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(NotificationSettings.self, from: data) {
            loaded = decoded
        }

        var unsynced: [String: String] = [:]
        var legacy: [String: String] = [:]
        var hadLegacySecrets = false
        for field in NotificationSettings.secretFields {
            let jsonValue = loaded[keyPath: field.keyPath]
            if let pendingValue = storedUnsynced[field.account] {
                loaded[keyPath: field.keyPath] = pendingValue
                unsynced[field.account] = pendingValue
                if !pendingValue.isEmpty { legacy[field.account] = pendingValue }
            } else if !jsonValue.isEmpty {
                // Older builds stored this credential in the settings JSON; move it to the Keychain.
                hadLegacySecrets = true
                unsynced[field.account] = jsonValue
                legacy[field.account] = jsonValue
            } else {
                loaded[keyPath: field.keyPath] = readSecret(field.account) ?? ""
            }
        }
        self.unsyncedSecrets = unsynced
        self.legacyPlaintext = legacy
        self.settings = loaded

        syncUnsyncedSecrets()
        if hadLegacySecrets {
            // Rewrite the settings JSON without credentials; any legacy value the Keychain
            // refused is still kept in the unsynced store.
            save()
        }
    }

    /// Retries Keychain reads that failed earlier (for example a denied access prompt).
    func retryFailedCredentialReads() {
        guard !readErrors.isEmpty else { return }
        var updated = settings
        for field in NotificationSettings.secretFields where readErrors[field.account] != nil {
            if let value = readSecret(field.account) {
                updated[keyPath: field.keyPath] = value
            }
        }
        isApplyingKeychainValues = true
        settings = updated
        isApplyingKeychainValues = false
    }

    private func readSecret(_ account: String) -> String? {
        do {
            let value = try secretStore.read(account)
            readErrors[account] = nil
            return value
        } catch {
            readErrors[account] = "Could not read the \(Self.label(account)) from the Keychain: \(error.localizedDescription)"
            return nil
        }
    }

    private func saveSecrets(changedFrom oldValue: NotificationSettings) {
        for field in NotificationSettings.secretFields where oldValue[keyPath: field.keyPath] != settings[keyPath: field.keyPath] {
            // A new value replaces whatever could not be read.
            readErrors[field.account] = nil
            unsyncedSecrets[field.account] = settings[keyPath: field.keyPath]
        }
        syncUnsyncedSecrets()
    }

    /// Writes every outstanding credential to the Keychain, keeping any that fail for a later retry.
    private func syncUnsyncedSecrets() {
        for (account, value) in unsyncedSecrets.sorted(by: { $0.key < $1.key }) {
            do {
                try secretStore.write(value, for: account)
                unsyncedSecrets[account] = nil
                legacyPlaintext[account] = nil
                writeErrors[account] = nil
            } catch {
                let label = Self.label(account)
                writeErrors[account] = isPersistable(account: account, value: value)
                    ? "Could not update the \(label) in the Keychain: \(error.localizedDescription)"
                    : "The \(label) could not be saved to the Keychain and will be lost when the app quits: \(error.localizedDescription)"
            }
        }

        let persisted = unsyncedSecrets.filter { isPersistable(account: $0.key, value: $0.value) }
        if persisted.isEmpty {
            userDefaults.removeObject(forKey: Self.unsyncedSecretsKey)
        } else {
            userDefaults.set(persisted, forKey: Self.unsyncedSecretsKey)
        }
    }

    /// Empty delete markers and values that were already on disk in plain text may be kept on
    /// disk until the Keychain accepts them; a new credential never is.
    private func isPersistable(account: String, value: String) -> Bool {
        value.isEmpty || legacyPlaintext[account] == value
    }

    private static func label(_ account: String) -> String {
        secretLabels[account] ?? account
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(settings) {
            userDefaults.set(encoded, forKey: Self.userDefaultsKey)
        }
    }
}
