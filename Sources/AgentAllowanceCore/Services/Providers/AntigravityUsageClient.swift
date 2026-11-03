import Foundation

struct AntigravityUsageClient: UsageProviderClient {
    let provider: AgentProvider = .antigravity

    func isInstalled() -> Bool {
        ProviderInstallation.hasExecutable("agy")
    }

    func fetchWindows() async throws -> [AllowanceWindow] {
        guard let executable = ProcessRunner.findExecutable(named: "agy") else {
            throw ProcessRunnerError.executableNotFound("Antigravity CLI (agy)")
        }

        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: ["-p", "/usage", "--output-format", "text", "--print-timeout", "30s"],
            timeout: 35
        )
        guard result.terminationStatus == 0 else {
            throw UsageClientError.unavailable(
                "Antigravity usage is unavailable. Open agy and confirm you are signed in."
            )
        }
        return try Self.parse(result.outputString)
    }

    static func parse(_ output: String) throws -> [AllowanceWindow] {
        let parsed = output.split(separator: "\n").compactMap { rawLine -> AllowanceWindow? in
            let columns = rawLine.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard columns.count >= 4 else { return nil }
            let scope = columns[0]
                .replacingOccurrences(of: " Models", with: "")
                .replacingOccurrences(of: " models", with: "")
            let rawLabel = columns[1].lowercased()
            let label = rawLabel.contains("five hour") ? "5h session" : "Weekly"
            guard let remaining = Double(columns[2].replacingOccurrences(of: "%", with: "")) else {
                return nil
            }
            let stableScope = scope.lowercased().replacingOccurrences(of: " ", with: "-")
            let stableWindow = label == "Weekly" ? "weekly" : "five-hour"
            return AllowanceWindow(
                id: "antigravity-\(stableScope)-\(stableWindow)",
                label: label,
                scope: scope,
                remainingPercent: remaining,
                resetAt: UsageDateParser.parse(columns[3])
            )
        }

        guard !parsed.isEmpty else {
            throw UsageClientError.invalidResponse("Antigravity did not report any allowance windows.")
        }

        let scopeOrder = ["Gemini": 0, "Claude and GPT": 1]
        return parsed.sorted { lhs, rhs in
            let leftScope = scopeOrder[lhs.scope ?? ""] ?? 99
            let rightScope = scopeOrder[rhs.scope ?? ""] ?? 99
            if leftScope != rightScope { return leftScope < rightScope }
            return lhs.label == "5h session" && rhs.label != "5h session"
        }
    }
}
