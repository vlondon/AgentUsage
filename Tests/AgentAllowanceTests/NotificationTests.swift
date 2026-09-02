import Foundation
import UserNotifications
import XCTest
@testable import AgentAllowance

final class MockNotificationSender: NotificationSenderProtocol, @unchecked Sendable {
    var authResult = true
    var authStatus: UNAuthorizationStatus = .authorized
    var sentMacPayloads: [(payload: NotificationPayload, delay: TimeInterval?)] = []
    var sentNtfyRequests: [(payload: NotificationPayload, topic: String, server: String, delay: TimeInterval?)] = []
    var macError: (any Error)?
    var ntfyError: (any Error)?

    var sentPushoverRequests: [(payload: NotificationPayload, userKey: String, apiToken: String, delay: TimeInterval?)] = []
    var pushoverError: (any Error)?

    var sentSimplepushRequests: [(payload: NotificationPayload, key: String, delay: TimeInterval?)] = []
    var simplepushError: (any Error)?

    func requestMacAuthorization() async -> Bool {
        authResult
    }

    func checkMacAuthorizationStatus() async -> UNAuthorizationStatus {
        authStatus
    }

    func sendMacNotification(payload: NotificationPayload, delaySeconds: TimeInterval? = nil) async throws {
        if authStatus == .denied {
            throw NSError(
                domain: "NotificationError",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Notification permission denied in macOS System Settings."]
            )
        }
        if let macError { throw macError }
        sentMacPayloads.append((payload, delaySeconds))
    }

    func sendNtfyNotification(payload: NotificationPayload, topic: String, server: String, delaySeconds: TimeInterval? = nil) async throws {
        if let ntfyError { throw ntfyError }
        sentNtfyRequests.append((payload, topic, server, delaySeconds))
    }

    func sendPushoverNotification(payload: NotificationPayload, userKey: String, apiToken: String, delaySeconds: TimeInterval? = nil) async throws {
        if let pushoverError { throw pushoverError }
        sentPushoverRequests.append((payload, userKey, apiToken, delaySeconds))
    }

    func sendSimplepushNotification(payload: NotificationPayload, key: String, delaySeconds: TimeInterval? = nil) async throws {
        if let simplepushError { throw simplepushError }
        sentSimplepushRequests.append((payload, key, delaySeconds))
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
        XCTAssertEqual(settings.backgroundRefreshIntervalMinutes, 5)
        XCTAssertFalse(settings.isAnyNotificationEnabled)
    }

    func testTopicCharsetValidation() {
        var settings = NotificationSettings(ntfyTopic: "my-valid_topic~123")
        XCTAssertTrue(settings.isTopicValid)
        XCTAssertEqual(settings.trimmedNtfyTopic, "my-valid_topic~123")

        settings.ntfyTopic = "invalid/path/topic"
        XCTAssertFalse(settings.isTopicValid)
        XCTAssertEqual(settings.trimmedNtfyTopic, "invalidpathtopic")

        settings.ntfyTopic = "spaces in topic"
        XCTAssertFalse(settings.isTopicValid)
    }

    func testRandomTopicGeneration() {
        let topic1 = NotificationSettings.generateRandomTopic()
        let topic2 = NotificationSettings.generateRandomTopic()
        XCTAssertTrue(topic1.hasPrefix("allowance-"))
        XCTAssertNotEqual(topic1, topic2)
        XCTAssertTrue(NotificationSettings(ntfyTopic: topic1).isTopicValid)
    }

    func testSettingsStoreBackwardCompatibleDecoding() throws {
        // Simulates JSON from an older version missing new fields
        let partialJson = """
        {
            "macNotificationsEnabled": true,
            "ntfyTopic": "test-topic"
        }
        """
        let decoded = try JSONDecoder().decode(NotificationSettings.self, from: Data(partialJson.utf8))
        XCTAssertTrue(decoded.macNotificationsEnabled)
        XCTAssertFalse(decoded.iphoneNotificationsEnabled)
        XCTAssertEqual(decoded.ntfyTopic, "test-topic")
        XCTAssertEqual(decoded.ntfyServer, "https://ntfy.sh")
        XCTAssertTrue(decoded.notifyOnReset)
        XCTAssertFalse(decoded.notifyOnLowAllowance)
        XCTAssertEqual(decoded.lowAllowanceThreshold, 10)
        XCTAssertEqual(decoded.backgroundRefreshIntervalMinutes, 5)
    }

    @MainActor
    func testSettingsStorePersistenceAndCallbacks() {
        let suiteName = "test_settings_\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(userDefaults: userDefaults)
        var timerCallbackCount = 0
        store.onSettingsChanged = {
            timerCallbackCount += 1
        }

        // Modifying timer-relevant field fires callback
        store.settings.macNotificationsEnabled = true
        XCTAssertEqual(timerCallbackCount, 1)

        // Modifying non-timer field does not re-trigger timer callback
        store.settings.ntfyTopic = "agent-alerts-123"
        XCTAssertEqual(timerCallbackCount, 1)

        // Modifying interval fires callback
        store.settings.backgroundRefreshIntervalMinutes = 10
        XCTAssertEqual(timerCallbackCount, 2)

        // Read back in a fresh store instance
        let reloaded = SettingsStore(userDefaults: userDefaults)
        XCTAssertTrue(reloaded.settings.macNotificationsEnabled)
        XCTAssertEqual(reloaded.settings.ntfyTopic, "agent-alerts-123")
        XCTAssertEqual(reloaded.settings.backgroundRefreshIntervalMinutes, 10)
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
        XCTAssertEqual(request.value(forHTTPHeaderField: "Title"), "Claude Allowance Reset")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Priority"), "3")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Tags"), "sparkles")
        XCTAssertEqual(String(data: request.httpBody ?? Data(), encoding: .utf8), "Your 5-hour session pool has fully refreshed.")
    }

    func testMakeNtfyRequestRejectsInvalidTopicCharacters() {
        let payload = NotificationPayload(title: "Test", body: "Body")
        XCTAssertThrowsError(
            try NotificationService.makeNtfyRequest(payload: payload, topic: "foo/bar", server: "https://ntfy.sh")
        )
        XCTAssertThrowsError(
            try NotificationService.makeNtfyRequest(payload: payload, topic: "   ", server: "https://ntfy.sh")
        )
    }

    func testNotificationDispatchMacReportsDeniedPermission() async {
        let mock = MockNotificationSender()
        mock.authStatus = .denied
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(macNotificationsEnabled: true)

        let payload = NotificationPayload(title: "Test", body: "Msg")
        let result = await service.dispatch(payload: payload, settings: settings)

        XCTAssertEqual(result.macSuccess, false)
        XCTAssertTrue(result.macError?.contains("denied") ?? false)
    }

    func testNotificationDispatchBothChannels() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            iphoneNotificationsEnabled: true,
            iphoneService: .ntfy,
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

    func testMakePushoverRequestValid() throws {
        let payload = NotificationPayload(
            title: "Claude Allowance Reset",
            body: "Your 5-hour session pool has fully refreshed."
        )

        let request = try NotificationService.makePushoverRequest(
            payload: payload,
            userKey: "user-12345",
            apiToken: "app-token-67890"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.pushover.net/1/messages.json")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        let bodyData = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(json["user"] as? String, "user-12345")
        XCTAssertEqual(json["token"] as? String, "app-token-67890")
        XCTAssertEqual(json["title"] as? String, "Claude Allowance Reset")
        XCTAssertEqual(json["message"] as? String, "Your 5-hour session pool has fully refreshed.")
    }

    func testPushoverDispatchRequiresKeys() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            iphoneNotificationsEnabled: true,
            iphoneService: .pushover,
            pushoverUserKey: "",
            pushoverApiToken: ""
        )

        let payload = NotificationPayload(title: "Test", body: "Msg")
        let result = await service.dispatch(payload: payload, settings: settings)

        XCTAssertEqual(result.iphoneSuccess, false)
        XCTAssertTrue(result.iphoneError?.contains("missing") ?? false)
    }

    func testPushoverDispatchSuccess() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            iphoneNotificationsEnabled: true,
            iphoneService: .pushover,
            pushoverUserKey: "user-abc",
            pushoverApiToken: "token-xyz"
        )

        let payload = NotificationPayload(title: "Test", body: "Msg")
        let result = await service.dispatch(payload: payload, settings: settings)

        XCTAssertEqual(result.iphoneSuccess, true)
        XCTAssertEqual(mock.sentPushoverRequests.count, 1)
        XCTAssertEqual(mock.sentPushoverRequests.first?.userKey, "user-abc")
        XCTAssertEqual(mock.sentPushoverRequests.first?.apiToken, "token-xyz")
    }

    func testMakeSimplepushRequestValid() throws {
        let payload = NotificationPayload(
            title: "Claude Allowance Reset",
            body: "Your 5-hour session pool has fully refreshed."
        )

        let request = try NotificationService.makeSimplepushRequest(
            payload: payload,
            key: "key123"
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.simplepush.io/send")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json; charset=utf-8")

        let bodyData = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])

        XCTAssertEqual(json["key"] as? String, "key123")
        XCTAssertEqual(json["title"] as? String, "Claude Allowance Reset")
        XCTAssertEqual(json["msg"] as? String, "Your 5-hour session pool has fully refreshed.")
    }

    func testSimplepushDispatchRequiresKey() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            iphoneNotificationsEnabled: true,
            iphoneService: .simplepush,
            simplepushKey: ""
        )

        let payload = NotificationPayload(title: "Test", body: "Msg")
        let result = await service.dispatch(payload: payload, settings: settings)

        XCTAssertEqual(result.iphoneSuccess, false)
        XCTAssertTrue(result.iphoneError?.contains("missing") ?? false)
    }

    func testSimplepushDispatchSuccess() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            iphoneNotificationsEnabled: true,
            iphoneService: .simplepush,
            simplepushKey: "mykey123"
        )

        let payload = NotificationPayload(title: "Test", body: "Msg")
        let result = await service.dispatch(payload: payload, settings: settings)

        XCTAssertEqual(result.iphoneSuccess, true)
        XCTAssertEqual(mock.sentSimplepushRequests.count, 1)
        XCTAssertEqual(mock.sentSimplepushRequests.first?.key, "mykey123")
    }

    // MARK: - AllowanceNotificationMonitor Tests

    func testMonitorColdStartupDoesNotSpamNotifications() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: true,
            notifyOnLowAllowance: true
        )

        let usages = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 100, resetAt: Date()),
                    AllowanceWindow(id: "weekly", label: "Weekly", remainingPercent: 5, resetAt: Date())
                ],
                isLoading: false
            )
        ]

        let payloads = monitor.evaluate(usages: usages, settings: settings)
        XCTAssertTrue(payloads.isEmpty, "Cold start baseline should not emit alert payloads")
        XCTAssertEqual(monitor.snapshotCount(), 2)
    }

    func testMonitorDetectsResetFromZeroToFull() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: true
        )

        let now = Date()
        let initialResetAt = now.addingTimeInterval(3600)
        let nextResetAt = now.addingTimeInterval(5 * 3600)

        // Baseline: 0% remaining (exhausted)
        let initialUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 0, resetAt: initialResetAt)
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

    func testMonitorUnexhaustedAllowanceRollOverDoesNotNotifyReset() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: true
        )

        let now = Date()
        let pastResetAt = now.addingTimeInterval(-60) // Expired 1 minute ago

        // Baseline: 20% remaining (never dropped to 0%)
        let initialUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 20, resetAt: pastResetAt)
                ],
                isLoading: false
            )
        ]
        _ = monitor.evaluate(usages: initialUsage, settings: settings, now: now)

        // Window rolls over to new cycle at 100%: should NOT alert because user never ran out of allowance (was not 0%)
        let rolloverUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 100, resetAt: now.addingTimeInterval(5 * 3600))
                ],
                isLoading: false
            )
        ]
        let payloads = monitor.evaluate(usages: rolloverUsage, settings: settings, now: now.addingTimeInterval(10))
        XCTAssertTrue(payloads.isEmpty, "Unexhausted allowance rollover must not fire reset notification")

        // Now allowance drops to 0%
        let zeroUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 0, resetAt: now.addingTimeInterval(4 * 3600))
                ],
                isLoading: false
            )
        ]
        _ = monitor.evaluate(usages: zeroUsage, settings: settings, now: now.addingTimeInterval(3600))

        // And then resets back to 100%: MUST alert now!
        let fullRefillUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 100, resetAt: now.addingTimeInterval(9 * 3600))
                ],
                isLoading: false
            )
        ]
        let refillPayloads = monitor.evaluate(usages: fullRefillUsage, settings: settings, now: now.addingTimeInterval(4 * 3600 + 1))
        XCTAssertEqual(refillPayloads.count, 1)
        XCTAssertEqual(refillPayloads[0].title, "Claude Allowance Reset")
    }

    func testMonitorNearEmptyAllowanceRefillNotifiesReset() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: true
        )

        let now = Date()
        let initialResetAt = now.addingTimeInterval(1800)

        // Baseline: 2% remaining (near-empty poll gap case where 0% was hit between polls)
        let initialUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 2, resetAt: initialResetAt)
                ],
                isLoading: false
            )
        ]
        _ = monitor.evaluate(usages: initialUsage, settings: settings, now: now)

        // Refill occurs to 100%
        let refillUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 100, resetAt: now.addingTimeInterval(5 * 3600))
                ],
                isLoading: false
            )
        ]
        let payloads = monitor.evaluate(usages: refillUsage, settings: settings, now: now.addingTimeInterval(1805))
        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].title, "Claude Allowance Reset")
    }

    func testMonitorDetectsResetWhenResetAtIsNil() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: true
        )

        let initialUsage = [
            ProviderUsage(
                provider: .cursor,
                windows: [
                    AllowanceWindow(id: "cycle", label: "Billing cycle", remainingPercent: 0, resetAt: nil)
                ],
                isLoading: false
            )
        ]
        _ = monitor.evaluate(usages: initialUsage, settings: settings)

        // Refill occurs
        let refreshedUsage = [
            ProviderUsage(
                provider: .cursor,
                windows: [
                    AllowanceWindow(id: "cycle", label: "Billing cycle", remainingPercent: 100, resetAt: nil)
                ],
                isLoading: false
            )
        ]
        let payloads = monitor.evaluate(usages: refreshedUsage, settings: settings)

        XCTAssertEqual(payloads.count, 1)
        XCTAssertEqual(payloads[0].title, "Cursor Allowance Reset")
    }

    func testMonitorImmuneToTimestampJitter() {
        let monitor = AllowanceNotificationMonitor()
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            notifyOnReset: true
        )

        let now = Date()
        let resetAt = now.addingTimeInterval(7200)

        let initialUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 95, resetAt: resetAt)
                ],
                isLoading: false
            )
        ]
        _ = monitor.evaluate(usages: initialUsage, settings: settings, now: now)

        // Next poll returns 2 seconds drift in resetAt due to fractional parsing
        let jitterUsage = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "session", label: "5h session", remainingPercent: 95, resetAt: resetAt.addingTimeInterval(2))
                ],
                isLoading: false
            )
        ]
        let payloads = monitor.evaluate(usages: jitterUsage, settings: settings, now: now.addingTimeInterval(60))

        XCTAssertTrue(payloads.isEmpty, "Timestamp jitter must not trigger a false reset alert")
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
                    AllowanceWindow(id: "gemini-5h", label: "5h session", scope: "Gemini", remainingPercent: 0, resetAt: initialResetAt)
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

    func testNotificationDispatchWithDelay() async {
        let mock = MockNotificationSender()
        let service = NotificationService(sender: mock)
        let settings = NotificationSettings(
            macNotificationsEnabled: true,
            iphoneNotificationsEnabled: true,
            iphoneService: .ntfy,
            ntfyTopic: "delayed-topic"
        )

        let result = await service.sendTestNotificationWithDelay(seconds: 10, settings: settings)
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(mock.sentMacPayloads.count, 1)
        XCTAssertEqual(mock.sentMacPayloads.first?.delay, 10)
        XCTAssertEqual(mock.sentNtfyRequests.count, 1)
        XCTAssertEqual(mock.sentNtfyRequests.first?.delay, 10)
    }
}
