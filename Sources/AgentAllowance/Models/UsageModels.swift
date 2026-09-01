import Foundation
import SwiftUI

enum AgentProvider: String, CaseIterable, Identifiable, Sendable {
    case codex = "Codex"
    case claude = "Claude"
    case cursor = "Cursor"
    case devin = "Devin"
    case grokBuild = "Grok Build"
    case grokBot = "Grok Bot"
    case antigravity = "Antigravity"

    var id: String { rawValue }

    var symbolName: String {
        switch self {
        case .codex: "terminal"
        case .claude: "sparkles"
        case .cursor: "cursorarrow.rays"
        case .devin: "brain.head.profile"
        case .grokBuild: "xmark"
        case .grokBot: "desktopcomputer"
        case .antigravity: "arrow.up.and.down.and.arrow.left.and.right"
        }
    }
}

struct AllowanceWindow: Identifiable, Equatable, Sendable {
    let id: String
    let label: String
    let scope: String?
    let remainingPercent: Double?
    let resetAt: Date?
    let note: String?

    init(
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

    var indicatorColor: Color {
        guard let remainingPercent else { return .secondary }
        if remainingPercent >= 50 { return .green }
        if remainingPercent >= 20 { return .yellow }
        return .red
    }
}

struct ProviderUsage: Identifiable, Equatable, Sendable {
    let provider: AgentProvider
    var windows: [AllowanceWindow]
    var error: String?
    var fetchedAt: Date?
    var isLoading: Bool

    var id: AgentProvider { provider }

    static func placeholder(for provider: AgentProvider) -> ProviderUsage {
        ProviderUsage(
            provider: provider,
            windows: [],
            error: nil,
            fetchedAt: nil,
            isLoading: true
        )
    }
}

enum UsageDateParser {
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

    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        return fractionalISO8601.date(from: value) ?? ISO8601.date(from: value)
    }
}

enum ResetTimeFormatter {
    static func string(until resetAt: Date?, now: Date = Date()) -> String {
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
