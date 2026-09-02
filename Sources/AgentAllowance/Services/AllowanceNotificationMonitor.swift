import Foundation

struct WindowSnapshot: Equatable, Sendable {
    let provider: AgentProvider
    let windowId: String
    let label: String
    let scope: String?
    var remainingPercent: Double?
    var resetAt: Date?
    var wasExhausted: Bool
    var notifiedResetThisCycle: Bool
    var notifiedLowThisCycle: Bool

    init(
        provider: AgentProvider,
        windowId: String,
        label: String,
        scope: String?,
        remainingPercent: Double?,
        resetAt: Date?,
        wasExhausted: Bool = false,
        notifiedResetThisCycle: Bool = false,
        notifiedLowThisCycle: Bool = false
    ) {
        self.provider = provider
        self.windowId = windowId
        self.label = label
        self.scope = scope
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.wasExhausted = wasExhausted
        self.notifiedResetThisCycle = notifiedResetThisCycle
        self.notifiedLowThisCycle = notifiedLowThisCycle
    }
}

final class AllowanceNotificationMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private var snapshots: [String: WindowSnapshot] = [:]

    init(initialSnapshots: [String: WindowSnapshot] = [:]) {
        self.snapshots = initialSnapshots
    }

    static func windowKey(provider: AgentProvider, windowId: String) -> String {
        "\(provider.rawValue):\(windowId)"
    }

    func evaluate(
        usages: [ProviderUsage],
        settings: NotificationSettings,
        now: Date = Date()
    ) -> [NotificationPayload] {
        lock.lock()
        defer { lock.unlock() }

        var payloads: [NotificationPayload] = []

        for usage in usages {
            for window in usage.windows {
                let key = Self.windowKey(provider: usage.provider, windowId: window.id)
                let threshold = Double(settings.lowAllowanceThreshold)

                guard let previous = snapshots[key] else {
                    // First time encountering this window (cold baseline):
                    let initialPercent = window.remainingPercent ?? 100
                    let isExhausted = initialPercent <= 0
                    let snapshot = WindowSnapshot(
                        provider: usage.provider,
                        windowId: window.id,
                        label: window.label,
                        scope: window.scope,
                        remainingPercent: window.remainingPercent,
                        resetAt: window.resetAt,
                        wasExhausted: isExhausted,
                        notifiedResetThisCycle: !isExhausted,
                        notifiedLowThisCycle: initialPercent <= threshold
                    )
                    snapshots[key] = snapshot
                    continue
                }

                var currentSnapshot = previous

                if let currPercent = window.remainingPercent {
                    // If allowance reached 0%, mark it as exhausted and re-arm for reset notification
                    if currPercent <= 0 {
                        currentSnapshot.wasExhausted = true
                        currentSnapshot.notifiedResetThisCycle = false
                    }

                    // Check for reset notification:
                    // ONLY fire if this window had 0% left (wasExhausted) and has now reset (> 0%)
                    if settings.notifyOnReset && settings.isAnyNotificationEnabled && !currentSnapshot.notifiedResetThisCycle && currentSnapshot.wasExhausted {
                        let isReset = isResetConditionMet(
                            previous: previous,
                            currentPercent: currPercent,
                            currentResetAt: window.resetAt,
                            now: now
                        )

                        if isReset {
                            let scopeSuffix = window.scope.map { " (\($0))" } ?? ""
                            let rounded = Int(currPercent.rounded())
                            let title = "\(usage.provider.rawValue) Allowance Reset"
                            let body = "Your \(window.label)\(scopeSuffix) allowance has reset (\(rounded)% remaining)."
                            let identifier = "reset-\(key)-\(Int(now.timeIntervalSince1970))"

                            payloads.append(
                                NotificationPayload(
                                    title: title,
                                    body: body,
                                    identifier: identifier,
                                    priority: 4,
                                    tags: ["sparkles", "repeat"]
                                )
                            )
                            currentSnapshot.wasExhausted = false
                            currentSnapshot.notifiedResetThisCycle = true
                        }
                    }

                    // Check for low allowance notification
                    if currPercent <= threshold {
                        let prevPercent = previous.remainingPercent ?? 100
                        if settings.notifyOnLowAllowance && settings.isAnyNotificationEnabled && !currentSnapshot.notifiedLowThisCycle && prevPercent > threshold {
                            let scopeSuffix = window.scope.map { " (\($0))" } ?? ""
                            let rounded = Int(currPercent.rounded())
                            let title = "\(usage.provider.rawValue) Low Allowance"
                            let body = "Your \(window.label)\(scopeSuffix) allowance is down to \(rounded)% remaining."
                            let identifier = "low-\(key)-\(Int(now.timeIntervalSince1970))"

                            payloads.append(
                                NotificationPayload(
                                    title: title,
                                    body: body,
                                    identifier: identifier,
                                    priority: 4,
                                    tags: ["warning", "hourglass"]
                                )
                            )
                            currentSnapshot.notifiedLowThisCycle = true
                        }
                    } else if currPercent > threshold {
                        // Re-arm low allowance notification once allowance recovers above threshold
                        currentSnapshot.notifiedLowThisCycle = false
                    }
                }

                // Update snapshot values
                currentSnapshot.remainingPercent = window.remainingPercent
                currentSnapshot.resetAt = window.resetAt
                snapshots[key] = currentSnapshot
            }
        }

        return payloads
    }

    private func isResetConditionMet(
        previous: WindowSnapshot,
        currentPercent: Double,
        currentResetAt: Date?,
        now: Date
    ) -> Bool {
        // Since wasExhausted is true (was at 0%), any replenishment to > 0% is a reset
        if currentPercent > 0 {
            return true
        }

        return false
    }

    func snapshotCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.count
    }
}
