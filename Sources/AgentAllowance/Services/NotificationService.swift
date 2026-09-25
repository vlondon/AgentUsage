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
        priority: Int = 4,
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
    func sendPushoverNotification(payload: NotificationPayload, userKey: String, apiToken: String, delaySeconds: TimeInterval?) async throws
    func sendSimplepushNotification(payload: NotificationPayload, key: String, delaySeconds: TimeInterval?) async throws
}

struct LiveNotificationSender: NotificationSenderProtocol {
    private let urlSession: URLSession

    /// UNUserNotificationCenter raises an exception when the process is not an app bundle
    /// (for example `swift run`), so Mac notifications are only used from a packaged .app.
    static var isRunningFromAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
        if Self.isRunningFromAppBundle {
            UNUserNotificationCenter.current().delegate = NotificationCenterDelegate.shared
        }
    }

    func requestMacAuthorization() async -> Bool {
        guard Self.isRunningFromAppBundle else { return false }
        let center = UNUserNotificationCenter.current()
        do {
            return try await center.requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func checkMacAuthorizationStatus() async -> UNAuthorizationStatus {
        guard Self.isRunningFromAppBundle else { return .notDetermined }
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    func sendMacNotification(payload: NotificationPayload, delaySeconds: TimeInterval? = nil) async throws {
        guard Self.isRunningFromAppBundle else {
            throw NSError(
                domain: "NotificationError",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Mac notifications need the packaged app (scripts/package_app.sh)."]
            )
        }
        let center = UNUserNotificationCenter.current()
        var status = await center.notificationSettings().authorizationStatus
        if status == .notDetermined,
           (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) != nil {
            status = await center.notificationSettings().authorizationStatus
        }

        switch status {
        case .authorized, .provisional, .ephemeral:
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
            try await center.add(request)
        case .denied:
            throw NSError(
                domain: "NotificationError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Notification permission denied in macOS System Settings."]
            )
        default:
            // The permission prompt could not be shown (for example an unregistered app bundle),
            // so the user has never answered it. Fall back to an AppleScript notification.
            if let delaySeconds, delaySeconds > 0 {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            }
            try await Self.postAppleScriptNotification(title: payload.title, body: payload.body)
        }
    }

    @MainActor
    private static func postAppleScriptNotification(title: String, body: String) throws {
        let safeTitle = title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let safeBody = body.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let source = "display notification \"\(safeBody)\" with title \"\(safeTitle)\" sound name \"default\""
        guard let appleScript = NSAppleScript(source: source) else {
            throw NSError(
                domain: "NotificationError",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Could not create the fallback notification script."]
            )
        }
        var error: NSDictionary?
        appleScript.executeAndReturnError(&error)
        if let error {
            let message = error[NSAppleScript.errorMessage] as? String ?? "Fallback notification failed."
            throw NSError(domain: "NotificationError", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
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

    func sendPushoverNotification(payload: NotificationPayload, userKey: String, apiToken: String, delaySeconds: TimeInterval? = nil) async throws {
        let sendWork = {
            let request = try NotificationService.makePushoverRequest(
                payload: payload,
                userKey: userKey,
                apiToken: apiToken
            )
            let (data, response) = try await self.urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                var errorMessage = "Pushover server returned HTTP \(httpResponse.statusCode)"
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let errors = json["errors"] as? [String], !errors.isEmpty {
                    errorMessage = errors.joined(separator: ", ")
                }
                throw NSError(
                    domain: "PushoverError",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: errorMessage]
                )
            }
        }

        if let delaySeconds, delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        try await sendWork()
    }

    func sendSimplepushNotification(payload: NotificationPayload, key: String, delaySeconds: TimeInterval? = nil) async throws {
        let sendWork = {
            let request = try NotificationService.makeSimplepushRequest(
                payload: payload,
                key: key
            )
            let (data, response) = try await self.urlSession.data(for: request)
            if let httpResponse = response as? HTTPURLResponse, !(200...299).contains(httpResponse.statusCode) {
                throw NSError(
                    domain: "SimplepushError",
                    code: httpResponse.statusCode,
                    userInfo: [NSLocalizedDescriptionKey: "Simplepush server returned HTTP \(httpResponse.statusCode)"]
                )
            }
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let status = json["status"] as? String, status != "OK" {
                throw NSError(
                    domain: "SimplepushError",
                    code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Simplepush returned status: \(status)"]
                )
            }
        }

        if let delaySeconds, delaySeconds > 0 {
            try await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
        }
        try await sendWork()
    }
}

struct NotificationService: Sendable {
    private let sender: any NotificationSenderProtocol

    static let requestTimeout: TimeInterval = 15

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

        guard let url = URL(string: "\(cleanServer)/\(trimmedTopic)") else {
            throw NSError(
                domain: "NtfyError",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid ntfy URL: \(cleanServer)/\(trimmedTopic)"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("AgentAllowance/1.0", forHTTPHeaderField: "User-Agent")
        request.setValue(payload.title, forHTTPHeaderField: "Title")
        request.setValue("\(payload.priority)", forHTTPHeaderField: "Priority")
        if !payload.tags.isEmpty {
            request.setValue(payload.tags.joined(separator: ","), forHTTPHeaderField: "Tags")
        }
        if let delaySeconds, delaySeconds > 0 {
            request.setValue("\(Int(delaySeconds))s", forHTTPHeaderField: "Delay")
        }

        request.httpBody = payload.body.data(using: .utf8)
        return request
    }

    static func makePushoverRequest(
        payload: NotificationPayload,
        userKey: String,
        apiToken: String
    ) throws -> URLRequest {
        let cleanUser = userKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanUser.isEmpty else {
            throw NSError(
                domain: "PushoverError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Pushover User Key cannot be empty"]
            )
        }

        guard !cleanToken.isEmpty else {
            throw NSError(
                domain: "PushoverError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Pushover API Token cannot be empty. Create one in 10s at pushover.net/apps/build"]
            )
        }

        guard let url = URL(string: "https://api.pushover.net/1/messages.json") else {
            throw NSError(
                domain: "PushoverError",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Pushover URL"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: Any] = [
            "token": cleanToken,
            "user": cleanUser,
            "title": payload.title,
            "message": payload.body,
            "priority": 1
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: bodyDict, options: [])
        return request
    }

    static func makeSimplepushRequest(
        payload: NotificationPayload,
        key: String
    ) throws -> URLRequest {
        let cleanKey = key.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleanKey.isEmpty else {
            throw NSError(
                domain: "SimplepushError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Simplepush key cannot be empty"]
            )
        }

        guard let url = URL(string: "https://api.simplepush.io/send") else {
            throw NSError(
                domain: "SimplepushError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid Simplepush URL"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: Any] = [
            "key": cleanKey,
            "title": payload.title,
            "msg": payload.body
        ]

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
            switch settings.iphoneService {
            case .pushover:
                if !settings.isPushoverConfigured {
                    result.iphoneSuccess = false
                    if settings.trimmedPushoverUserKey.isEmpty {
                        result.iphoneError = "Pushover User Key is missing"
                    } else {
                        result.iphoneError = "Pushover API Token is missing (create on pushover.net/apps/build)"
                    }
                } else {
                    do {
                        try await sender.sendPushoverNotification(
                            payload: payload,
                            userKey: settings.trimmedPushoverUserKey,
                            apiToken: settings.trimmedPushoverApiToken,
                            delaySeconds: delaySeconds
                        )
                        result.iphoneSuccess = true
                    } catch {
                        result.iphoneSuccess = false
                        result.iphoneError = error.localizedDescription
                    }
                }
            case .simplepush:
                if !settings.isSimplepushConfigured {
                    result.iphoneSuccess = false
                    result.iphoneError = "Simplepush Key is missing"
                } else {
                    do {
                        try await sender.sendSimplepushNotification(
                            payload: payload,
                            key: settings.trimmedSimplepushKey,
                            delaySeconds: delaySeconds
                        )
                        result.iphoneSuccess = true
                    } catch {
                        result.iphoneSuccess = false
                        result.iphoneError = error.localizedDescription
                    }
                }
            case .ntfy:
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
        }

        return result
    }

    func sendTestNotification(settings: NotificationSettings) async -> NotificationDispatchResult {
        let payload = NotificationPayload(
            title: "Agent Allowance Test",
            body: "Notifications are working! You will receive alerts when your agent allowances reset.",
            priority: 4,
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
            priority: 4,
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
            ? "Background 10-second iPhone push received via \(settings.iphoneService.rawValue)!"
            : "iPhone notifications via \(settings.iphoneService.rawValue) are working! You will receive push alerts when allowances reset."
        let payload = NotificationPayload(
            title: title,
            body: body,
            priority: 4,
            tags: ["hourglass", "bell"]
        )
        return await dispatch(payload: payload, delaySeconds: delaySeconds, settings: testSettings)
    }

    func sendTestNotificationWithDelay(seconds: TimeInterval = 10, settings: NotificationSettings) async -> NotificationDispatchResult {
        let payload = NotificationPayload(
            title: "Agent Allowance (10s Delay)",
            body: "10-second background notification received successfully!",
            priority: 4,
            tags: ["hourglass", "sparkles"]
        )
        return await dispatch(payload: payload, delaySeconds: seconds, settings: settings)
    }
}
