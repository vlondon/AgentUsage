import Foundation

/// Machine-readable view of every provider's allowance (schema 1). This is the
/// contract read by other local processes; see README, "Machine-readable output".
public struct AllowanceSnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion = 1

    public struct Window: Codable, Equatable, Sendable {
        public var id: String
        public var label: String
        public var remainingPct: Double?
        public var resetsAt: Date?
        public var windowMinutes: Int?
        public var scope: String?

        enum CodingKeys: String, CodingKey {
            case id, label, scope
            case remainingPct = "remaining_pct"
            case resetsAt = "resets_at"
            case windowMinutes = "window_minutes"
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(label, forKey: .label)
            try c.encode(remainingPct, forKey: .remainingPct)
            try c.encode(resetsAt, forKey: .resetsAt)
            try c.encode(windowMinutes, forKey: .windowMinutes)
            try c.encode(scope, forKey: .scope)
        }
    }

    public struct Provider: Codable, Equatable, Sendable {
        public var id: String
        public var name: String
        public var installed: Bool
        public var error: String?
        public var windows: [Window]

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(installed, forKey: .installed)
            try c.encode(error, forKey: .error)
            try c.encode(windows, forKey: .windows)
        }
    }

    public var schema: Int
    public var generatedAt: Date
    public var providers: [Provider]

    enum CodingKeys: String, CodingKey {
        case schema, providers
        case generatedAt = "generated_at"
    }

    /// `usages` holds only installed providers (as `UsageService.fetchAll` returns);
    /// every other provider is listed with `installed: false`.
    public init(usages: [ProviderUsage], generatedAt: Date = Date()) {
        schema = Self.schemaVersion
        self.generatedAt = generatedAt
        providers = AgentProvider.allCases.map { provider in
            guard let usage = usages.first(where: { $0.provider == provider }) else {
                return Provider(
                    id: provider.jsonID, name: provider.rawValue,
                    installed: false, error: nil, windows: []
                )
            }
            return Provider(
                id: provider.jsonID,
                name: provider.rawValue,
                installed: true,
                error: usage.error,
                windows: usage.windows.map { Window(provider: provider, window: $0) }
            )
        }
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.formatter().string(from: date))
        }
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> AllowanceSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let string = try decoder.singleValueContainer().decode(String.self)
            guard let date = formatter().date(from: string) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: string))
            }
            return date
        }
        return try decoder.decode(AllowanceSnapshot.self, from: data)
    }

    private static func formatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }

    /// `~/Library/Caches/AgentAllowance/usage.json`
    public static var defaultCacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Caches/AgentAllowance/usage.json")
    }

    /// Writes atomically: a temp file in the same directory, then rename over the target.
    public func writeCache(to url: URL = AllowanceSnapshot.defaultCacheURL) throws {
        let data = try jsonData()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp)
            guard rename(temp.path, url.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }
}

extension AgentProvider {
    var jsonID: String {
        switch self {
        case .codex: "codex"
        case .claude: "claude"
        case .cursor: "cursor"
        case .devin: "devin"
        case .grokBuild: "grok_build"
        case .grokBot: "grok_bot"
        case .antigravity: "antigravity"
        }
    }
}

extension AllowanceSnapshot.Window {
    init(provider: AgentProvider, window: AllowanceWindow) {
        let (kind, minutes) = Self.kind(of: window)
        id = kind
        label = window.label
        remainingPct = window.remainingPercent
        resetsAt = window.resetAt
        windowMinutes = minutes
        scope = Self.scope(of: window, provider: provider)
    }

    /// Stable snake_case kind plus the window length, derived from the window's label.
    static func kind(of window: AllowanceWindow) -> (String, Int?) {
        let label = window.label.lowercased()
        switch label {
        case "5h session", "session", "five hour": return ("five_hour", 300)
        case "weekly": return ("weekly", 10_080)
        case "daily": return ("daily", 1_440)
        case "billing cycle":
            // Devin reports two billing-cycle pools (ACU and credits); keep them distinct.
            return (window.id.contains("credits") ? "billing_cycle_credits" : "billing_cycle", nil)
        default:
            if label.hasSuffix("h window"), let hours = Int(label.dropLast("h window".count)) {
                return ("window_\(hours)h", hours * 60)
            }
            return (snake(window.label), nil)
        }
    }

    /// Only meaningful scopes are exported: model or pool names, never plan names.
    static func scope(of window: AllowanceWindow, provider: AgentProvider) -> String? {
        guard let scope = window.scope else { return nil }
        switch provider {
        case .claude:
            return scope == "All models" ? nil : snake(scope)
        case .antigravity:
            return scope == "Claude and GPT" ? "claude_gpt" : snake(scope)
        default:
            return nil
        }
    }

    static func snake(_ value: String) -> String {
        let mapped = value.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        return String(mapped).split(separator: "_").joined(separator: "_")
    }
}
