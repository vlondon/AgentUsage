import Foundation

struct WindowSnapshot: Equatable, Sendable {
    let provider: AgentProvider
    let windowId: String
    let label: String
    let scope: String?
    var remainingPercent: Double?
    var resetAt: Date?
    var lastNotifiedResetAt: Date?
    var lastNotifiedLow: Bool

    init(
        provider: AgentProvider,
        windowId: String,
        label: String,
        scope: String?,
        remainingPercent: Double?,
        resetAt: Date?,
        lastNotifiedResetAt: Date? = nil,
        lastNotifiedLow: Bool = false
    ) {
        self.provider = provider
        self.windowId = windowId
        self.label = label
        self.scope = scope
        self.remainingPercent = remainingPercent
        self.resetAt = resetAt
        self.lastNotifiedResetAt = lastNotifiedResetAt
        self.lastNotifiedLow = lastNotifiedLow
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

        guard settings.isAnyNotificationEnabled else {
            // If notifications are disabled, keep snapshots up to date without generating payloads
            updateSnapshotsOnly(usages: usages)
            return []
        }

        var payloads: [NotificationPayload] = []

        for usage in usages {
            for window in usage.windows {
                let key = Self.windowKey(provider: usage.provider, windowId: window.id)
                var currentSnapshot = snapshots[key] ?? WindowSnapshot(
                    provider: usage.provider,
                    windowId: window.id,
                    label: window.label,
                    scope: window.scope,
                    remainingPercent: window.remainingPercent,
                    resetAt: window.resetAt
                )

                if let previous = snapshots[key] {
                    // Check for reset notification
                    if settings.notifyOnReset,
                       let prevPercent = previous.remainingPercent,
                       let currPercent = window.remainingPercent {
                        let isReset = isResetConditionMet(
                            prevPercent: prevPercent,
                            currPercent: currPercent,
                            prevResetAt: previous.resetAt,
                            currResetAt: window.resetAt,
                            now: now
                        )

                        let isNewResetCycle = window.resetAt != previous.lastNotifiedResetAt

                        if isReset && isNewResetCycle {
                            let scopeSuffix = window.scope.map { " (\($0))" } ?? ""
                            let rounded = Int(currPercent.rounded())
                            let title = "\(usage.provider.rawValue) Allowance Reset"
                            let body = "Your \(window.label)\(scopeSuffix) allowance has reset (\(rounded)% remaining)."
                            let identifier = "reset-\(key)-\(window.resetAt?.timeIntervalSince1970 ?? now.timeIntervalSince1970)"

                            payloads.append(
                                NotificationPayload(
                                    title: title,
                                    body: body,
                                    identifier: identifier,
                                    priority: 3,
                                    tags: ["sparkles", "repeat"]
                                )
                            )
                            currentSnapshot.lastNotifiedResetAt = window.resetAt
                        }
                    }

                    // Check for low allowance notification
                    if settings.notifyOnLowAllowance,
                       let prevPercent = previous.remainingPercent,
                       let currPercent = window.remainingPercent {
                        let threshold = Double(settings.lowAllowanceThreshold)

                        if currPercent <= threshold && prevPercent > threshold && !previous.lastNotifiedLow {
                            let scopeSuffix = window.scope.map { " (\($0))" } ?? ""
                            let rounded = Int(currPercent.rounded())
                            let title = "\(usage.provider.rawValue) Low Allowance"
                            let body = "Your \(window.label)\(scopeSuffix) allowance is down to \(rounded)% remaining."
                            let identifier = "low-\(key)-\(Int(now.timeIntervalSince1970 / 3600))"

                            payloads.append(
                                NotificationPayload(
                                    title: title,
                                    body: body,
                                    identifier: identifier,
                                    priority: 4,
                                    tags: ["warning", "hourglass"]
                                )
                            )
                            currentSnapshot.lastNotifiedLow = true
                        } else if currPercent > threshold {
                            currentSnapshot.lastNotifiedLow = false
                        }
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

    private func updateSnapshotsOnly(usages: [ProviderUsage]) {
        for usage in usages {
            for window in usage.windows {
                let key = Self.windowKey(provider: usage.provider, windowId: window.id)
                var snapshot = snapshots[key] ?? WindowSnapshot(
                    provider: usage.provider,
                    windowId: window.id,
                    label: window.label,
                    scope: window.scope,
                    remainingPercent: window.remainingPercent,
                    resetAt: window.resetAt
                )
                snapshot.remainingPercent = window.remainingPercent
                snapshot.resetAt = window.resetAt
                snapshots[key] = snapshot
            }
        }
    }

    private func isResetConditionMet(
        prevPercent: Double,
        currPercent: Double,
        prevResetAt: Date?,
        currResetAt: Date?,
        now: Date
    ) -> Bool {
        // Case 1: Remaining percent increased substantially (e.g., from <90% to >=95%, or jump of >=25%)
        if currPercent > prevPercent {
            if prevPercent <= 90 && currPercent >= 95 {
                return true
            }
            if currPercent - prevPercent >= 25 {
                return true
            }
            if let prevResetAt, now >= prevResetAt {
                return true
            }
        }

        // Case 2: Reset date moved forward into the future and remaining is high
        if let prevResetAt, let currResetAt, currResetAt > prevResetAt {
            if currPercent >= prevPercent || currPercent >= 80 {
                return true
            }
        }

        return false
    }

    func snapshotCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return snapshots.count
    }
}
