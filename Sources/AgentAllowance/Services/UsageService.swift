import Foundation
import Observation

protocol UsageProviderClient: Sendable {
    var provider: AgentProvider { get }
    /// Whether the provider's tool exists on this machine. Providers that are
    /// not installed are hidden rather than reported as errors; a provider that
    /// is installed but signed out still reports its error.
    func isInstalled() -> Bool
    func fetchWindows() async throws -> [AllowanceWindow]
}

struct UsageService: Sendable {
    private let clients: [any UsageProviderClient]

    init(clients: [any UsageProviderClient] = [
        CodexUsageClient(),
        ClaudeUsageClient(),
        CursorUsageClient(),
        DevinUsageClient(),
        GrokBuildUsageClient(),
        GrokBotUsageClient(),
        AntigravityUsageClient()
    ]) {
        self.clients = clients
    }

    /// Providers whose tool is present, in display order. Re-evaluated on each
    /// call so installing a tool while the app runs takes effect on refresh.
    var installedProviders: [AgentProvider] {
        let installed = Set(clients.filter { $0.isInstalled() }.map(\.provider))
        return AgentProvider.allCases.filter(installed.contains)
    }

    func fetchAll() async -> [ProviderUsage] {
        await withTaskGroup(of: ProviderUsage.self, returning: [ProviderUsage].self) { group in
            for client in clients where client.isInstalled() {
                group.addTask {
                    do {
                        return ProviderUsage(
                            provider: client.provider,
                            windows: try await client.fetchWindows(),
                            error: nil,
                            fetchedAt: Date(),
                            isLoading: false
                        )
                    } catch {
                        return ProviderUsage(
                            provider: client.provider,
                            windows: [],
                            error: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription,
                            fetchedAt: Date(),
                            isLoading: false
                        )
                    }
                }
            }

            var usages: [ProviderUsage] = []
            for await usage in group {
                usages.append(usage)
            }
            return AgentProvider.allCases.compactMap { provider in
                usages.first { $0.provider == provider }
            }
        }
    }
}

@MainActor
@Observable
final class UsageStore {
    private let service: UsageService
    private var refreshTask: Task<Void, Never>?
    private var backgroundTimerTask: Task<Void, Never>?

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

        let task = Task { [service, settingsStore, notificationService, notificationMonitor] in
            let results = await service.fetchAll()
            guard !Task.isCancelled else { return }

            let payloads = notificationMonitor.evaluate(usages: results, settings: settingsStore.settings)
            for payload in payloads {
                _ = await notificationService.dispatch(payload: payload, settings: settingsStore.settings)
            }

            usages = results
            lastUpdated = Date()
            isRefreshing = false
            refreshTask = nil
        }
        refreshTask = task
        await task.value
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
