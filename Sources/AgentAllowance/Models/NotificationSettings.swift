import Foundation
import Observation

enum IPhonePushService: String, Codable, CaseIterable, Identifiable, Sendable {
    case pushover = "Pushover"
    case ntfy = "ntfy"

    var id: String { rawValue }
}

struct NotificationSettings: Codable, Equatable, Sendable {
    var macNotificationsEnabled: Bool
    var iphoneNotificationsEnabled: Bool
    var iphoneService: IPhonePushService
    var pushoverUserKey: String
    var pushoverApiToken: String
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
        self.ntfyTopic = try container.decodeIfPresent(String.self, forKey: .ntfyTopic) ?? ""
        self.ntfyServer = try container.decodeIfPresent(String.self, forKey: .ntfyServer) ?? "https://ntfy.sh"
        self.notifyOnReset = try container.decodeIfPresent(Bool.self, forKey: .notifyOnReset) ?? true
        self.notifyOnLowAllowance = try container.decodeIfPresent(Bool.self, forKey: .notifyOnLowAllowance) ?? false
        self.lowAllowanceThreshold = try container.decodeIfPresent(Int.self, forKey: .lowAllowanceThreshold) ?? 10
        self.backgroundRefreshIntervalMinutes = try container.decodeIfPresent(Int.self, forKey: .backgroundRefreshIntervalMinutes) ?? 5
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
    private let userDefaults: UserDefaults

    var onSettingsChanged: (@Sendable () -> Void)?

    var settings: NotificationSettings {
        didSet {
            save()
            if oldValue.isAnyNotificationEnabled != settings.isAnyNotificationEnabled ||
               oldValue.backgroundRefreshIntervalMinutes != settings.backgroundRefreshIntervalMinutes {
                onSettingsChanged?()
            }
        }
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        if let data = userDefaults.data(forKey: Self.userDefaultsKey),
           let decoded = try? JSONDecoder().decode(NotificationSettings.self, from: data) {
            self.settings = decoded
        } else {
            self.settings = NotificationSettings()
        }
    }

    private func save() {
        if let encoded = try? JSONEncoder().encode(settings) {
            userDefaults.set(encoded, forKey: Self.userDefaultsKey)
        }
    }
}
