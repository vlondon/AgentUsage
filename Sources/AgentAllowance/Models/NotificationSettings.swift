import Foundation
import Observation

struct NotificationSettings: Codable, Equatable, Sendable {
    var macNotificationsEnabled: Bool
    var iphoneNotificationsEnabled: Bool
    var ntfyTopic: String
    var ntfyServer: String
    var notifyOnReset: Bool
    var notifyOnLowAllowance: Bool
    var lowAllowanceThreshold: Int
    var backgroundRefreshIntervalMinutes: Int

    init(
        macNotificationsEnabled: Bool = false,
        iphoneNotificationsEnabled: Bool = false,
        ntfyTopic: String = "",
        ntfyServer: String = "https://ntfy.sh",
        notifyOnReset: Bool = true,
        notifyOnLowAllowance: Bool = false,
        lowAllowanceThreshold: Int = 10,
        backgroundRefreshIntervalMinutes: Int = 5
    ) {
        self.macNotificationsEnabled = macNotificationsEnabled
        self.iphoneNotificationsEnabled = iphoneNotificationsEnabled
        self.ntfyTopic = ntfyTopic
        self.ntfyServer = ntfyServer
        self.notifyOnReset = notifyOnReset
        self.notifyOnLowAllowance = notifyOnLowAllowance
        self.lowAllowanceThreshold = lowAllowanceThreshold
        self.backgroundRefreshIntervalMinutes = backgroundRefreshIntervalMinutes
    }

    var isAnyNotificationEnabled: Bool {
        macNotificationsEnabled || iphoneNotificationsEnabled
    }

    var trimmedNtfyTopic: String {
        ntfyTopic.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
}

@MainActor
@Observable
final class SettingsStore {
    private static let userDefaultsKey = "com.vlondon.AgentAllowance.NotificationSettings"
    private let userDefaults: UserDefaults

    var settings: NotificationSettings {
        didSet {
            save()
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
