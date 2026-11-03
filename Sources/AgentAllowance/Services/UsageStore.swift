import AgentAllowanceCore
import Foundation
import Observation

@MainActor
@Observable
final class UsageStore {
    private let service: UsageService
    private var refreshTask: Task<Void, Never>?
    private var backgroundTimerTask: Task<Void, Never>?
    private var deliveryTask: Task<Void, Never>?

    let settingsStore: SettingsStore
    let notificationService: NotificationService
    let notificationMonitor: AllowanceNotificationMonitor

    var usages: [ProviderUsage]
    var lastUpdated: Date?
    var isRefreshing = false

    init(
        service: UsageService = UsageService(),
        settingsStore: SettingsStore? = nil,
        notificationService: NotificationService = NotificationService(),
        notificationMonitor: AllowanceNotificationMonitor = AllowanceNotificationMonitor()
    ) {
        self.service = service
        let effectiveSettingsStore = settingsStore ?? SettingsStore()
        self.settingsStore = effectiveSettingsStore
        self.notificationService = notificationService
        self.notificationMonitor = notificationMonitor
        self.usages = service.installedProviders.map(ProviderUsage.placeholder)

        effectiveSettingsStore.onSettingsChanged = { [weak self] in
            Task { @MainActor [weak self] in
                self?.updateBackgroundTimer()
            }
        }

        if effectiveSettingsStore.settings.macNotificationsEnabled {
            Task {
                _ = await notificationService.requestMacAuthorization()
            }
        }

        updateBackgroundTimer()
    }

    func refreshIfNeeded() async {
        if let lastUpdated, Date().timeIntervalSince(lastUpdated) < 60 {
            return
        }
        await refresh()
    }

    func refresh() async {
        if let refreshTask {
            await refreshTask.value
            return
        }

        isRefreshing = true
        for index in usages.indices {
            usages[index].isLoading = true
        }

        let task = Task { [service, notificationMonitor] in
            let results = await service.fetchAll()
            guard !Task.isCancelled else { return }

            _ = notificationMonitor.evaluate(usages: results, settings: settingsStore.settings)

            usages = results
            lastUpdated = Date()
            // Machine-readable copy for other local processes; failure must not affect the app.
            try? AllowanceSnapshot(usages: results, generatedAt: lastUpdated ?? Date()).writeCache()
            isRefreshing = false
            refreshTask = nil

            deliverPendingAlerts()
        }
        refreshTask = task
        await task.value
    }

    /// Sends queued alerts without holding up the refresh. Only one pass runs at a time, and each
    /// alert is re-checked against the queue and current settings right before it is sent.
    /// Alerts that fail stay queued in the monitor and are retried after the next poll.
    private func deliverPendingAlerts() {
        guard deliveryTask == nil else { return }

        deliveryTask = Task { [notificationService, notificationMonitor] in
            var attempted: Set<String> = []
            while let delivery = notificationMonitor.nextDelivery(settings: settingsStore.settings, skipping: attempted) {
                attempted.insert(delivery.payload.identifier)
                let result = await notificationService.dispatch(payload: delivery.payload, settings: delivery.settings)
                notificationMonitor.recordDelivery(result, for: delivery.payload.identifier)
            }
            deliveryTask = nil
        }
    }

    func updateBackgroundTimer() {
        backgroundTimerTask?.cancel()
        backgroundTimerTask = nil

        guard settingsStore.settings.isAnyNotificationEnabled else { return }

        let intervalMinutes = settingsStore.settings.backgroundRefreshIntervalMinutes
        let intervalSeconds = max(60, Double(intervalMinutes) * 60)

        backgroundTimerTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(intervalSeconds * 1_000_000_000))
                guard !Task.isCancelled else { break }
                await self?.refresh()
            }
        }
    }
}
