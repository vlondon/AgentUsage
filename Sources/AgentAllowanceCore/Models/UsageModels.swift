import Foundation

public enum AgentProvider: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case devin = "Devin"
    case grokBuild = "Grok Build"
    case grokBot = "Grok Bot"
    case antigravity = "Antigravity"

    public var id: String { rawValue }
}

public struct AllowanceWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let scope: String?
    public let remainingPercent: Double?
    public let resetAt: Date?
    public let note: String?

    public init(
        id: String,
        label: String,
        scope: String? = nil,
        remainingPercent: Double? = nil,
        resetAt: Date? = nil,
        note: String? = nil
    ) {
        self.id = id
        self.label = label
        self.scope = scope
        self.remainingPercent = remainingPercent.map { min(max($0, 0), 100) }
        self.resetAt = resetAt
        self.note = note
    }
}

public struct ProviderUsage: Identifiable, Equatable, Sendable {
    public let provider: AgentProvider
    public var windows: [AllowanceWindow]
    public var error: String?
    public var fetchedAt: Date?
    public var isLoading: Bool

    public init(
        provider: AgentProvider,
        windows: [AllowanceWindow],
        error: String? = nil,
        fetchedAt: Date? = nil,
        isLoading: Bool = false
    ) {
        self.provider = provider
        self.windows = windows
        self.error = error
        self.fetchedAt = fetchedAt
        self.isLoading = isLoading
    }

    public var id: AgentProvider { provider }

    public static func placeholder(for provider: AgentProvider) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            windows: [],
            error: nil,
            fetchedAt: nil,
            isLoading: true
        )
    }
}

public enum UsageDateParser {
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let ISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalISO8601.date(from: value) ?? ISO8601.date(from: value)
    }
}

public enum ResetTimeFormatter {
    public static func string(until resetAt: Date?, now: Date = Date()) -> String {
        guard let resetAt else { return "—" }
        let seconds = max(0, Int(resetAt.timeIntervalSince(now)))
        if seconds == 0 { return "now" }

        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60

        if days > 0 { return "\(days)d \(hours)h" }
        if hours > 0 {
            return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h"
        }
        return "\(max(1, minutes))m"
    }
}
