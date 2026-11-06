import Foundation

public protocol UsageProviderClient: Sendable {
    var provider: AgentProvider { get }
    /// Whether the provider's tool exists on this machine. Providers that are
    /// not installed are hidden rather than reported as errors; a provider that
    /// is installed but signed out still reports its error.
    func isInstalled() -> Bool
    func fetchWindows() async throws -> [AllowanceWindow]
    /// Windows plus any reset credits from one provider call. Providers without
    /// credits keep the default.
    func fetchResult() async throws -> ProviderFetchResult
}

public struct ProviderFetchResult: Sendable {
    public var windows: [AllowanceWindow]
    public var resetCredits: ResetCredits

    public init(windows: [AllowanceWindow], resetCredits: ResetCredits = .none) {
        self.windows = windows
        self.resetCredits = resetCredits
    }
}

extension UsageProviderClient {
    public func fetchResult() async throws -> ProviderFetchResult {
        ProviderFetchResult(windows: try await fetchWindows())
    }
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
        let off = UsageService.disabledProviders()
        self.clients = clients.filter { !off.contains($0.provider.rawValue.lowercased()) }
    }

    /// Providers the owner switched off (lowercased raw values), shared by the menu-bar app and the `allowance` CLI:
    /// `defaults write com.vlondon.AgentAllowance DisabledProviders -array antigravity`, or ALLOWANCE_DISABLED=a,b.
    /// Added 2026-11-06: agy 1.5.1 raised a «Keychain Not Found … antigravity» dialog on every refresh.
    static func disabledProviders() -> Set<String> {
        var names = UserDefaults(suiteName: "com.vlondon.AgentAllowance")?.stringArray(forKey: "DisabledProviders") ?? []
        if let env = ProcessInfo.processInfo.environment["ALLOWANCE_DISABLED"] {
            names += env.split(separator: ",").map(String.init)
        }
        return Set(names.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })
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
                        let result = try await client.fetchResult()
                        return ProviderUsage(
                            provider: client.provider,
                            windows: result.windows,
                            error: nil,
                            fetchedAt: Date(),
                            isLoading: false,
                            resetCredits: result.resetCredits
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
