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
                parts.append("Mac: Sent")
            } else {
                parts.append("Mac: \(macError ?? "Failed")")
            }
        }
        if let iphoneSuccess {
            if iphoneSuccess {
                parts.append("iPhone: Sent")
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

protocol NotificationSenderProtocol: Sendable {
    func requestMacAuthorization() async -> Bool
    func checkMacAuthorizationStatus() async -> UNAuthorizationStatus
    func sendMacNotification(payload: NotificationPayload) async throws
    func sendNtfyNotification(payload: NotificationPayload, topic: String, server: String) async throws
}

struct LiveNotificationSender: NotificationSenderProtocol {
    private let urlSession: URLSession

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
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

    func sendMacNotification(payload: NotificationPayload) async throws {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: payload.identifier,
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    func sendNtfyNotification(payload: NotificationPayload, topic: String, server: String) async throws {
        let request = try NotificationService.makeNtfyRequest(payload: payload, topic: topic, server: server)
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
        server: String
    ) throws -> URLRequest {
        let cleanTopic = topic.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanTopic.isEmpty else {
            throw NSError(
                domain: "NtfyError",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "ntfy topic cannot be empty"]
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

        guard let url = URL(string: "\(cleanServer)/\(cleanTopic)") else {
            throw NSError(
                domain: "NtfyError",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Invalid ntfy URL: \(cleanServer)/\(cleanTopic)"]
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let bodyDict: [String: Any] = [
            "topic": cleanTopic,
            "title": payload.title,
            "message": payload.body,
            "priority": payload.priority,
            "tags": payload.tags
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
        settings: NotificationSettings
    ) async -> NotificationDispatchResult {
        var result = NotificationDispatchResult()

        if settings.macNotificationsEnabled {
            do {
                try await sender.sendMacNotification(payload: payload)
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
            } else {
                do {
                    try await sender.sendNtfyNotification(
                        payload: payload,
                        topic: topic,
                        server: settings.cleanedNtfyServer
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
}
