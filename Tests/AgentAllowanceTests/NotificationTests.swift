import Foundation
import UserNotifications
import XCTest
@testable import AgentAllowance

final class MockNotificationSender: NotificationSenderProtocol, @unchecked Sendable {
    var authResult = true
    var authStatus: UNAuthorizationStatus = .authorized
    var sentMacPayloads: [NotificationPayload] = []
    var sentNtfyRequests: [(payload: NotificationPayload, topic: String, server: String)] = []
    var macError: (any Error)?
    var ntfyError: (any Error)?

    func requestMacAuthorization() async -> Bool {
        authResult
    }

    func checkMacAuthorizationStatus() async -> UNAuthorizationStatus {
        authStatus
    }

    func sendMacNotification(payload: NotificationPayload) async throws {
        if let macError { throw macError }
        sentMacPayloads.append(payload)
    }

    func sendNtfyNotification(payload: NotificationPayload, topic: String, server: String) async throws {
        if let ntfyError { throw ntfyError }
        sentNtfyRequests.append((payload, topic, server))
    }
}

final class NotificationTests: XCTestCase {

    // MARK: - NotificationSettings Tests

    func testNotificationSettingsDefaults() {
        let settings = NotificationSettings()
        XCTAssertFalse(settings.macNotificationsEnabled)
        XCTAssertFalse(settings.iphoneNotificationsEnabled)
        XCTAssertEqual(settings.ntfyTopic, "")
        XCTAssertEqual(settings.ntfyServer, "https://ntfy.sh")
        XCTAssertTrue(settings.notifyOnReset)
        XCTAssertFalse(settings.notifyOnLowAllowance)
        XCTAssertEqual(settings.lowAllowanceThreshold, 10)
        XCTAssertFalse(settings.isAnyNotificationEnabled)
    }

    func testTopicAndServerTrimming() {
        var settings = NotificationSettings(
            ntfyTopic: "  /my-cool-topic/  ",
            ntfyServer: "  ntfy.sh/  "
        )
        XCTAssertEqual(settings.trimmedNtfyTopic, "my-cool-topic")
        XCTAssertEqual(settings.cleanedNtfyServer, "https://ntfy.sh")

        settings.ntfyServer = "http://custom-ntfy.internal:8080///"
        XCTAssertEqual(settings.cleanedNtfyServer, "http://custom-ntfy.internal:8080")
    }

    @MainActor
    func testSettingsStorePersistence() {
        let suiteName = "test_settings_\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(userDefaults: userDefaults)
        store.settings.macNotificationsEnabled = true
        store.settings.iphoneNotificationsEnabled = true
        store.settings.ntfyTopic = "agent-alerts-123"
        store.settings.lowAllowanceThreshold = 15

        // Read back in a fresh store instance
        let reloaded = SettingsStore(userDefaults: userDefaults)
        XCTAssertTrue(reloaded.settings.macNotificationsEnabled)
        XCTAssertTrue(reloaded.settings.iphoneNotificationsEnabled)
        XCTAssertEqual(reloaded.settings.ntfyTopic, "agent-alerts-123")
        XCTAssertEqual(reloaded.settings.lowAllowanceThreshold, 15)
    }

    // MARK: - NotificationService & Ntfy Request Tests

    func testMakeNtfyRequestValid() throws {
        let payload = NotificationPayload(
            title: "Claude Allowance Reset",
            body: "Your 5-hour session pool has fully refreshed.",
            priority: 3,
            tags: ["sparkles"]
        )

        let request = try NotificationService.makeNtfyRequest(
            payload: payload,
            topic: "my-topic",
            server: "https://ntfy.sh"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://ntfy.sh/my-topic")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        let bodyData = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(json["topic"] as? String, "my-topic")
        XCTAssertEqual(json["title"] as? String, "Claude Allowance Reset")
        XCTAssertEqual(json["message"] as? String, "Your 5-hour session pool has fully refreshed.")
        XCTAssertEqual(json["priority"] as? Int, 3)
        XCTAssertEqual(json["tags"] as? [String], ["sparkles"])
    }

    func testMakeNtfyRequestEmptyTopicThrows() {
        let payload = NotificationPayload(title: "Test", body: "Body")
        XCTAssertThrowsError(
            try NotificationService.makeNtfyRequest(payload: payload, topic: "   ", server: "https://ntfy.sh")
        )
    }

    func testNotificationDispatchMacOnly() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            iphoneNotificationsEnabled: false
        )

        let payload = NotificationPayload(title: "Test", body: "Msg")
        let result = await service.dispatch(payload: payload, settings: settings)

        XCTAssertEqual(result.macSuccess, true)
        XCTAssertNil(result.iphoneSuccess)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(mock.sentMacPayloads.count, 1)
        XCTAssertEqual(mock.sentNtfyRequests.count, 0)
    }

    func testNotificationDispatchBothChannels() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            iphoneNotificationsEnabled: true,
            ntfyTopic: "agent-test-topic"
        )

        let payload = NotificationPayload(title: "Test", body: "Msg")
        let result = await service.dispatch(payload: payload, settings: settings)

        XCTAssertEqual(result.macSuccess, true)
        XCTAssertEqual(result.iphoneSuccess, true)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(mock.sentMacPayloads.count, 1)
        XCTAssertEqual(mock.sentNtfyRequests.count, 1)
        XCTAssertEqual(mock.sentNtfyRequests.first?.topic, "agent-test-topic")
    }

    func testNotificationDispatchIphoneFailsWithoutTopic() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            macNotificationsEnabled: false,
            iphoneNotificationsEnabled: true,
            ntfyTopic: ""
        )

        let payload = NotificationPayload(title: "Test", body: "Msg")
        let result = await service.dispatch(payload: payload, settings: settings)

        XCTAssertEqual(result.iphoneSuccess, false)
        XCTAssertFalse(result.isSuccess)
        XCTAssertEqual(result.iphoneError, "ntfy topic is not set")
    }

    func testSendTestNotification() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            iphoneNotificationsEnabled: true,
            ntfyTopic: "test-topic"
        )

        let result = await service.sendTestNotification(settings: settings)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(mock.sentMacPayloads.first?.title, "Agent Allowance Test")
        XCTAssertEqual(mock.sentNtfyRequests.first?.payload.title, "Agent Allowance Test")
    }

    // MARK: - AllowanceNotificationMonitor Tests

    func testMonitorColdStartupDoesNotSpamNotifications() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: true
        )

        let usages = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 100, resetAt: Date())
                ],
                isLoading: false
            )
        ]

        let payloads = monitor.evaluate(usages: usages, settings: settings)
        XCTAssertTrue(payloads.isEmpty)
        XCTAssertEqual(monitor.snapshotCount(), 1)
    }

    func testMonitorDetectsResetFromLowToFull() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: true
        )

        let now = Date()
        let initialResetAt = now.addingTimeInterval(3600)
        let nextResetAt = now.addingTimeInterval(5 * 3600)

        // Baseline: 20% remaining
        let initialUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 20, resetAt: initialResetAt)
                ],
                isLoading: false
            )
        ]
        _ = monitor.evaluate(usages: initialUsage, settings: settings, now: now)

        // Reset occurs: 100% remaining, new reset cycle
        let resetUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 100, resetAt: nextResetAt)
                ],
                isLoading: false
            )
        ]
        let payloads = monitor.evaluate(usages: resetUsage, settings: settings, now: now.addingTimeInterval(3601))

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].title, "Claude Allowance Reset")
        XCTAssertTrue(payloads[0].body.contains("5h session"))
        XCTAssertTrue(payloads[0].body.contains("100% remaining"))

        // Repeated evaluation with same state should NOT trigger duplicate notification
        let duplicatePayloads = monitor.evaluate(usages: resetUsage, settings: settings, now: now.addingTimeInterval(3610))
        XCTAssertTrue(duplicatePayloads.isEmpty)
    }

    func testMonitorDetectsResetWithScopedWindow() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: true
        )

        let now = Date()
        let initialResetAt = now.addingTimeInterval(100)
        let nextResetAt = now.addingTimeInterval(86400)

        let initialUsage = [
            ProviderUsage(
                provider: .antigravity,
                windows: [
                    AllowanceWindow(id: "gemini-5h", label: "5h session", scope: "Gemini", remainingPercent: 15, resetAt: initialResetAt)
                ],
                isLoading: false
            )
        ]
        _ = monitor.evaluate(usages: initialUsage, settings: settings, now: now)

        let refreshedUsage = [
            ProviderUsage(
                provider: .antigravity,
                windows: [
                    AllowanceWindow(id: "gemini-5h", label: "5h session", scope: "Gemini", remainingPercent: 100, resetAt: nextResetAt)
                ],
                isLoading: false
            )
        ]
        let payloads = monitor.evaluate(usages: refreshedUsage, settings: settings, now: now.addingTimeInterval(150))

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].title, "Antigravity Allowance Reset")
        XCTAssertTrue(payloads[0].body.contains("5h session (Gemini)"))
    }

    func testMonitorDetectsLowAllowance() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: false,
            notifyOnLowAllowance: true,
            lowAllowanceThreshold: 10
        )

        let now = Date()
        let initialUsage = [
            ProviderUsage(
                provider: .codex,
                windows: [
                    AllowanceWindow(id: "weekly", label: "Weekly", remainingPercent: 40, resetAt: now.addingTimeInterval(86400))
                ],
                isLoading: false
            )
        ]
        _ = monitor.evaluate(usages: initialUsage, settings: settings, now: now)

        // Allowance drops to 8% (below 10% threshold)
        let lowUsage = [
            ProviderUsage(
                provider: .codex,
                windows: [
                    AllowanceWindow(id: "weekly", label: "Weekly", remainingPercent: 8, resetAt: now.addingTimeInterval(86400))
                ],
                isLoading: false
            )
        ]
        let payloads = monitor.evaluate(usages: lowUsage, settings: settings, now: now.addingTimeInterval(60))

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].title, "Codex Low Allowance")
        XCTAssertTrue(payloads[0].body.contains("Weekly"))
        XCTAssertTrue(payloads[0].body.contains("8% remaining"))

        // Repeating low usage without recovering does not trigger duplicate
        let repeatPayloads = monitor.evaluate(usages: lowUsage, settings: settings, now: now.addingTimeInterval(120))
        XCTAssertTrue(repeatPayloads.isEmpty)
    }
}
