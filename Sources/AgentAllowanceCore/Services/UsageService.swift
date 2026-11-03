import Foundation

public protocol UsageProviderClient: Sendable {
    var provider: AgentProvider { get }
    /// Whether the provider's tool exists on this machine. Providers that are
    /// not installed are hidden rather than reported as errors; a provider that
    /// is installed but signed out still reports its error.
    func isInstalled() -> Bool
    func fetchWindows() async throws -> [AllowanceWindow]
}

public struct UsageService: Sendable {
    private let clients: [any UsageProviderClient]

    public init() {
        self.init(clients: UsageService.defaultClients)
    }

    static var defaultClients: [any UsageProviderClient] {
        [
        CodexUsageClient(),
        ClaudeUsageClient(),
        CursorUsageClient(),
        DevinUsageClient(),
        GrokBuildUsageClient(),
        GrokBotUsageClient(),
        AntigravityUsageClient()
        ]
    }

    init(clients: [any UsageProviderClient]) {
        self.clients = clients
    }

    /// Providers whose tool is present, in display order. Re-evaluated on each
    /// call so installing a tool while the app runs takes effect on refresh.
    public var installedProviders: [AgentProvider] {
        let installed = Set(clients.filter { $0.isInstalled() }.map(\.provider))
        return AgentProvider.allCases.filter(installed.contains)
    }

    public func fetchAll() async -> [ProviderUsage] {
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
