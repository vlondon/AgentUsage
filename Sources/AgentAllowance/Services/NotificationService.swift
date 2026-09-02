import AppKit
import Foundation
import UserNotifications

struct NotificationPayload: Equatable, Sendable {
    let title: String
    let body: String
    let identifier: String
    let priority: Int
    let tags: [String]

    init(
        title: String,
        body: String,
        identifier: String = UUID().uuidString,
        priority: Int = 3,
        tags: [String] = ["bell"]
    ) {
        self.title = title
        self.body = body
        self.identifier = identifier
        self.priority = priority
        self.tags = tags
    }
}

struct NotificationDispatchResult: Equatable, Sendable {
    var macSuccess: Bool?
    var macError: String?
    var iphoneSuccess: Bool?
    var iphoneError: String?

    var isSuccess: Bool {
        let macOk = macSuccess ?? true
        let iphoneOk = iphoneSuccess ?? true
        return macOk && iphoneOk && (macSuccess != nil || iphoneSuccess != nil)
    }

    var summaryDescription: String {
        var parts: [String] = []
        if let macSuccess {
            if macSuccess {
                parts.append("Mac: Sent/Scheduled")
            } else {
                parts.append("Mac: \(macError ?? "Failed")")
            }
        }
        if let iphoneSuccess {
            if iphoneSuccess {
                parts.append("iPhone: Sent/Scheduled")
            } else {
                parts.append("iPhone: \(iphoneError ?? "Failed")")
            }
        }
        if parts.isEmpty {
            return "No notification channels enabled."
        }
        return parts.joined(separator: " • ")
    }
}

final class NotificationCenterDelegate: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationCenterDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound, .list])
    }
}

protocol NotificationSenderProtocol: Sendable {
    func requestMacAuthorization() async -> Bool
    func checkMacAuthorizationStatus() async -> UNAuthorizationStatus
    func sendMacNotification(payload: NotificationPayload, delaySeconds: TimeInterval?) async throws
    func sendNtfyNotification(payload: NotificationPayload, topic: String, server: String, delaySeconds: TimeInterval?) async throws
}

struct LiveNotificationSender: NotificationSenderProtocol {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        UNUserNotificationCenter.current().delegate = NotificationCenterDelegate.shared
    }

    func requestMacAuthorization() async -> Bool {
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func checkMacAuthorizationStatus() async -> UNAuthorizationStatus {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    func sendMacNotification(payload: NotificationPayload, delaySeconds: TimeInterval? = nil) async throws {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()

        if settings.authorizationStatus == .notDetermined {
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }

        if settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional {
            let content = UNMutableNotificationContent()
            content.title = payload.title
            content.body = payload.body
            content.sound = .default

            let trigger: UNNotificationTrigger?
            if let delaySeconds, delaySeconds > 0 {
                trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, delaySeconds), repeats: false)
            } else {
                trigger = nil
            }

            let request = UNNotificationRequest(
                identifier: payload.identifier,
                content: content,
                trigger: trigger
            )
            try? await center.add(request)
        }

        // Post via NSAppleScript system notification fallback to guarantee banner and sound delivery on macOS
        Self.postAppleScriptNotification(
            title: payload.title,
            body: payload.body,
            delaySeconds: delaySeconds
        )
    }

    private static func postAppleScriptNotification(title: String, body: String, delaySeconds: TimeInterval?) {
        let work = {
            let safeTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let safeBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let source = "display notification \"\(safeBody)\" with title \"\(safeTitle)\" sound name \"default\""
            if let appleScript = NSAppleScript(source: source) {
                var error: NSDictionary?
                appleScript.executeAndReturnError(&error)
            }
        }

        if let delaySeconds, delaySeconds > 0 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
                await MainActor.run { work() }
            }
        } else {
            work()
        }
    }

    func sendNtfyNotification(payload: NotificationPayload, topic: String, server: String, delaySeconds: TimeInterval? = nil) async throws {
        let request = try NotificationService.makeNtfyRequest(
            payload: payload,
            topic: topic,
            server: server,
            delaySeconds: delaySeconds
        )
        let (_, response) = try await urlSession.data(for: request)
        if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
            throw NSError(
                domain: "NtfyError",
                code: httpResponse.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "ntfy server returned HTTP \(httpResponse.statusCode)"]
            )
        }
    }
}

struct NotificationService: Sendable {
    private let sender: any NotificationSenderProtocol

    init(sender: any NotificationSenderProtocol = LiveNotificationSender()) {
        self.sender = sender
    }

    static func makeNtfyRequest(
        payload: NotificationPayload,
        topic: String,
        server: String,
        delaySeconds: TimeInterval? = nil
    ) throws -> URLRequest {
        let trimmedTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTopic.isEmpty else {
            throw NSError(
                domain: "NtfyError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ntfy topic cannot be empty"]
            )
        }

        guard trimmedTopic.unicodeScalars.allSatisfy({ NotificationSettings.allowedTopicCharacters.contains($0) }) else {
            throw NSError(
                domain: "NtfyError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "ntfy topic contains invalid characters. Use letters, numbers, hyphens, and underscores."]
            )
        }

        var cleanServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleanServer.isEmpty {
            cleanServer = "https://ntfy.sh"
        }
        if !cleanServer.hasPrefix("http://") && !cleanServer.hasPrefix("https://") {
            cleanServer = "https://" + cleanServer
        }
        while cleanServer.hasSuffix("/") {
            cleanServer.removeLast()
        }

        guard let url = URL(string: cleanServer) else {
            throw NSError(
                domain: "NtfyError",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid ntfy URL: \(cleanServer)"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        var bodyDict: [String: Any] = [
            "topic": trimmedTopic,
            "title": payload.title,
            "message": payload.body,
            "priority": payload.priority,
            "tags": payload.tags
        ]

        if let delaySeconds, delaySeconds > 0 {
            bodyDict["delay"] = "\(Int(delaySeconds))s"
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        return request
    }

    func requestMacAuthorization() async -> Bool {
        await sender.requestMacAuthorization()
    }

    func checkMacAuthorizationStatus() async -> UNAuthorizationStatus {
        await sender.checkMacAuthorizationStatus()
    }

    func dispatch(
        payload: NotificationPayload,
        delaySeconds: TimeInterval? = nil,
        settings: NotificationSettings
    ) async -> NotificationDispatchResult {
        var result = NotificationDispatchResult()

        if settings.macNotificationsEnabled {
            do {
                try await sender.sendMacNotification(payload: payload, delaySeconds: delaySeconds)
                result.macSuccess = true
            } catch {
                result.macSuccess = false
                result.macError = error.localizedDescription
            }
        }

        if settings.iphoneNotificationsEnabled {
            let topic = settings.trimmedNtfyTopic
            if topic.isEmpty {
                result.iphoneSuccess = false
                result.iphoneError = "ntfy topic is not set"
            } else if !settings.isTopicValid {
                result.iphoneSuccess = false
                result.iphoneError = "ntfy topic has invalid characters"
            } else {
                do {
                    try await sender.sendNtfyNotification(
                        payload: payload,
                        topic: topic,
                        server: settings.cleanedNtfyServer,
                        delaySeconds: delaySeconds
                    )
                    result.iphoneSuccess = true
                } catch {
                    result.iphoneSuccess = false
                    result.iphoneError = error.localizedDescription
                }
            }
        }

        return result
    }

    func sendTestNotification(settings: NotificationSettings) async -> NotificationDispatchResult {
        let payload = NotificationPayload(
            title: "Agent Allowance Test",
            body: "Notifications are working! You will receive alerts when your agent allowances reset.",
            priority: 3,
            tags: ["sparkles", "bell"]
        )
        return await dispatch(payload: payload, settings: settings)
    }

    func sendTestMacNotification(delaySeconds: TimeInterval? = nil) async -> NotificationDispatchResult {
        var testSettings = NotificationSettings()
        testSettings.macNotificationsEnabled = true
        testSettings.iphoneNotificationsEnabled = false
        let title = delaySeconds != nil ? "Agent Allowance 10s Test" : "Agent Allowance Mac Alert"
        let body = delaySeconds != nil
            ? "Background 10-second notification received successfully!"
            : "Mac notifications are working! You will receive local alerts when allowances reset."
        let payload = NotificationPayload(
            title: title,
            body: body,
            priority: 3,
            tags: ["hourglass", "bell"]
        )
        return await dispatch(payload: payload, delaySeconds: delaySeconds, settings: testSettings)
    }

    func sendTestIphoneNotification(delaySeconds: TimeInterval? = nil, settings: NotificationSettings) async -> NotificationDispatchResult {
        var testSettings = settings
        testSettings.macNotificationsEnabled = false
        testSettings.iphoneNotificationsEnabled = true
        let title = delaySeconds != nil ? "Agent Allowance 10s iPhone Test" : "Agent Allowance iPhone Alert"
        let body = delaySeconds != nil
            ? "Background 10-second iPhone push received via ntfy!"
            : "iPhone notifications via ntfy are working! You will receive push alerts when allowances reset."
        let payload = NotificationPayload(
            title: title,
            body: body,
            priority: 3,
            tags: ["hourglass", "bell"]
        )
        return await dispatch(payload: payload, delaySeconds: delaySeconds, settings: testSettings)
    }

    func sendTestNotificationWithDelay(seconds: TimeInterval = 10, settings: NotificationSettings) async -> NotificationDispatchResult {
        let payload = NotificationPayload(
            title: "Agent Allowance (10s Delay)",
            body: "10-second background notification received successfully!",
            priority: 3,
            tags: ["hourglass", "sparkles"]
        )
        return await dispatch(payload: payload, delaySeconds: seconds, settings: settings)
    }
}
