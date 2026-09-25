import Foundation

struct WindowSnapshot: Equatable, Sendable {
    let provider: AgentProvider
    let windowId: String
    let label: String
    let scope: String?
    var remainingPercent: Double?
    var resetAt: Date?
    var wasExhausted: Bool
    var notifiedLowThisCycle: Bool

    init(
        provider: AgentProvider,
        windowId: String,
        label: String,
        scope: String?,
        remainingPercent: Double?,
        resetAt: Date?,
        wasExhausted: Bool = false,
        notifiedLowThisCycle: Bool = false
    ) {
        self.provider = provider
        self.windowId = windowId
        self.label = label
        self.scope = scope
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.wasExhausted = wasExhausted
        self.notifiedLowThisCycle = notifiedLowThisCycle
    }
}

/// An alert that has been raised but not yet delivered to every channel it was meant for.
struct PendingAlert: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case reset
        case low
    }

    let windowKey: String
    let kind: Kind
    let payload: NotificationPayload
    var macDelivered = false
    var iphoneDelivered = false
    var attempts = 0
}

/// One dispatch attempt: the payload plus settings narrowed to the channels still owed a copy.
struct AlertDelivery: Sendable {
    let payload: NotificationPayload
    let settings: NotificationSettings
}

final class AllowanceNotificationMonitor: @unchecked Sendable {
    static let exhaustionThreshold: Double = 5.0
    static let minRefillPercent: Double = 50.0
    static let minPercentJump: Double = 30.0
    static let maxDeliveryAttempts = 3

    private let lock = NSLock()
    private var snapshots: [String: WindowSnapshot] = [:]
    private var pending: [PendingAlert] = []

    init(initialSnapshots: [String: WindowSnapshot] = [:]) {
        self.snapshots = initialSnapshots
    }

    static func windowKey(provider: AgentProvider, windowId: String) -> String {
        "\(provider.rawValue):\(windowId)"
    }

    /// Updates window state from a poll and returns the alerts it newly raised.
    /// Raised alerts are also queued; send them through `nextDelivery(settings:skipping:)`
    /// and report each outcome with `recordDelivery(_:for:)` so failed sends are retried.
    func evaluate(
        usages: [ProviderUsage],
        settings: NotificationSettings,
        now: Date = Date()
    ) -> [NotificationPayload] {
        lock.lock()
        defer { lock.unlock() }

        var raised: [NotificationPayload] = []
        let threshold = Double(settings.lowAllowanceThreshold)

        for usage in usages {
            for window in usage.windows {
                let key = Self.windowKey(provider: usage.provider, windowId: window.id)

                guard let previous = snapshots[key] else {
                    // First time encountering this window (cold baseline):
                    let initialPercent = window.remainingPercent ?? 100
                    snapshots[key] = WindowSnapshot(
                        provider: usage.provider,
                        windowId: window.id,
                        label: window.label,
                        scope: window.scope,
                        remainingPercent: window.remainingPercent,
                        resetAt: window.resetAt,
                        wasExhausted: initialPercent <= Self.exhaustionThreshold,
                        notifiedLowThisCycle: initialPercent <= threshold
                    )
                    continue
                }

                var currentSnapshot = previous

                if let currPercent = window.remainingPercent {
                    let scopeSuffix = window.scope.map { " (\($0))" } ?? ""
                    let rounded = Int(currPercent.rounded())

                    // Exhaustion and refill are tracked whatever the notification settings are,
                    // so turning reset alerts on later cannot replay a refill that already happened.
                    if currPercent <= Self.exhaustionThreshold {
                        currentSnapshot.wasExhausted = true
                        removePending(windowKey: key, kind: .reset)
                    } else if currentSnapshot.wasExhausted {
                        let prevPercent = previous.remainingPercent ?? 0
                        let isRefilled = currPercent >= Self.minRefillPercent || currPercent - prevPercent >= Self.minPercentJump

                        if isRefilled {
                            currentSnapshot.wasExhausted = false
                            if settings.notifyOnReset && settings.isAnyNotificationEnabled {
                                let payload = NotificationPayload(
                                    title: "\(usage.provider.rawValue) Allowance Reset",
                                    body: "Your \(window.label)\(scopeSuffix) allowance has reset (\(rounded)% remaining).",
                                    identifier: "reset-\(key)-\(Int(now.timeIntervalSince1970))",
                                    priority: 4,
                                    tags: ["sparkles", "repeat"]
                                )
                                enqueue(PendingAlert(windowKey: key, kind: .reset, payload: payload))
                                raised.append(payload)
                            }
                        }
                    }

                    if currPercent <= threshold {
                        let prevPercent = previous.remainingPercent ?? 100
                        if !currentSnapshot.notifiedLowThisCycle && prevPercent > threshold {
                            currentSnapshot.notifiedLowThisCycle = true
                            if settings.notifyOnLowAllowance && settings.isAnyNotificationEnabled {
                                let payload = NotificationPayload(
                                    title: "\(usage.provider.rawValue) Low Allowance",
                                    body: "Your \(window.label)\(scopeSuffix) allowance is down to \(rounded)% remaining.",
                                    identifier: "low-\(key)-\(Int(now.timeIntervalSince1970))",
                                    priority: 4,
                                    tags: ["warning", "hourglass"]
                                )
                                enqueue(PendingAlert(windowKey: key, kind: .low, payload: payload))
                                raised.append(payload)
                            }
                        }
                    } else {
                        // Re-arm low allowance notification once allowance recovers above threshold
                        currentSnapshot.notifiedLowThisCycle = false
                        removePending(windowKey: key, kind: .low)
                    }
                }

                currentSnapshot.remainingPercent = window.remainingPercent
                currentSnapshot.resetAt = window.resetAt
                snapshots[key] = currentSnapshot
            }
        }

        return raised
    }

    /// The next queued alert to send, narrowed to the channels that have not received it yet,
    /// or nil when nothing is left. Call it right before each send so the current settings apply:
    /// alerts whose trigger or channels were switched off since they were raised are dropped.
    /// `skipping` holds identifiers already attempted in this delivery pass.
    func nextDelivery(settings: NotificationSettings, skipping: Set<String> = []) -> AlertDelivery? {
        lock.lock()
        defer { lock.unlock() }

        pending.removeAll { alert in
            let triggerEnabled = switch alert.kind {
            case .reset: settings.notifyOnReset
            case .low: settings.notifyOnLowAllowance
            }
            return !triggerEnabled || !Self.channelSettings(for: alert, from: settings).isAnyNotificationEnabled
        }

        guard let index = pending.firstIndex(where: { !skipping.contains($0.payload.identifier) }) else { return nil }
        pending[index].attempts += 1
        let alert = pending[index]
        return AlertDelivery(payload: alert.payload, settings: Self.channelSettings(for: alert, from: settings))
    }

    /// Records which channels accepted an alert. The alert stays queued for the channels that
    /// failed until it has been attempted `maxDeliveryAttempts` times.
    func recordDelivery(_ result: NotificationDispatchResult, for identifier: String) {
        lock.lock()
        defer { lock.unlock() }

        guard let index = pending.firstIndex(where: { $0.payload.identifier == identifier }) else { return }
        // A channel that was not attempted (nil) has nothing left to deliver.
        if result.macSuccess != false { pending[index].macDelivered = true }
        if result.iphoneSuccess != false { pending[index].iphoneDelivered = true }

        let alert = pending[index]
        if (alert.macDelivered && alert.iphoneDelivered) || alert.attempts >= Self.maxDeliveryAttempts {
            pending.remove(at: index)
        }
    }

    func snapshotCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.count
    }

    func pendingCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return pending.count
    }

    private static func channelSettings(for alert: PendingAlert, from settings: NotificationSettings) -> NotificationSettings {
        var narrowed = settings
        narrowed.macNotificationsEnabled = settings.macNotificationsEnabled && !alert.macDelivered
        narrowed.iphoneNotificationsEnabled = settings.iphoneNotificationsEnabled && !alert.iphoneDelivered
        return narrowed
    }

    private func enqueue(_ alert: PendingAlert) {
        removePending(windowKey: alert.windowKey, kind: alert.kind)
        pending.append(alert)
    }

    private func removePending(windowKey: String, kind: PendingAlert.Kind) {
        pending.removeAll { $0.windowKey == windowKey && $0.kind == kind }
    }
}
