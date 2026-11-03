import SwiftUI
import AgentAllowanceCore

extension AgentProvider {
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

extension AllowanceWindow {
    var indicatorColor: Color {
        guard let remainingPercent else { return .secondary }
        if remainingPercent >= 50 { return .green }
        if remainingPercent >= 20 { return .yellow }
        return .red
    }
}
