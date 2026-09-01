import Foundation

struct ClaudeUsageClient: UsageProviderClient {
    let provider: AgentProvider = .claude

    func isInstalled() -> Bool {
        ProviderInstallation.hasExecutable("claude")
            || ProviderInstallation.hasHomePath(".claude")
    }

    func fetchWindows() async throws -> [AllowanceWindow] {
        guard let token = try await ClaudeCredentialReader.accessToken() else {
            throw UsageClientError.notAuthenticated(
                "Claude is not signed in. Run claude login to connect the subscription account."
            )
        }

        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.unavailable("Claude usage could not be reached.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageClientError.notAuthenticated("Claude sign-in expired. Run claude login again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageClientError.unavailable("Claude usage returned HTTP \(http.statusCode).")
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [AllowanceWindow] {
        let root = try JSONSupport.dictionary(from: data)
        if let windows = parseLimits(root["limits"]), !windows.isEmpty {
            return windows
        }

        // Older responses only carried the per-window objects, where utilization
        // was a 0...1 fraction.
        let limits = (root["rate_limits"] as? [String: Any]) ?? root
        let fiveHour = makeWindow(
            id: "claude-five-hour",
            label: "5h session",
            object: limits["five_hour"] as? [String: Any]
        )
        let sevenDay = makeWindow(
            id: "claude-seven-day",
            label: "Weekly",
            object: limits["seven_day"] as? [String: Any]
        )
        let windows = [fiveHour, sevenDay].compactMap { $0 }
        guard !windows.isEmpty else {
            throw UsageClientError.invalidResponse("Claude did not report session or weekly usage.")
        }
        return windows
    }

    /// Parses the `limits` array, where `percent` is always the used percentage
    /// of the window on a 0...100 scale.
    private static func parseLimits(_ value: Any?) -> [AllowanceWindow]? {
        guard let entries = value as? [[String: Any]] else { return nil }
        // Plans without a model-scoped weekly allowance show a single, unqualified
        // "Weekly" row; when a scoped one exists, both rows name their scope.
        let hasScopedWeekly = entries.contains { JSONSupport.string($0["kind"]) == "weekly_scoped" }
        return entries.compactMap { entry -> AllowanceWindow? in
            guard let kind = JSONSupport.string(entry["kind"]),
                  let usedPercent = JSONSupport.double(entry["percent"])
            else { return nil }

            // Only present for plans that have a model-scoped weekly allowance.
            let scope = (entry["scope"] as? [String: Any])
                .flatMap { $0["model"] as? [String: Any] }
                .flatMap { JSONSupport.string($0["display_name"]) }

            let id: String
            let label: String
            let displayScope: String?
            switch kind {
            case "session":
                id = "claude-five-hour"
                label = "5h session"
                displayScope = nil
            case "weekly_all":
                id = "claude-seven-day"
                label = "Weekly"
                displayScope = hasScopedWeekly ? "All models" : nil
            case "weekly_scoped":
                id = "claude-seven-day-\(scope ?? "scoped")"
                label = "Weekly"
                displayScope = scope
            default:
                return nil
            }

            return AllowanceWindow(
                id: id,
                label: label,
                scope: displayScope,
                remainingPercent: 100 - usedPercent,
                resetAt: UsageDateParser.parse(JSONSupport.string(entry["resets_at"]))
            )
        }
    }

    private static func makeWindow(
        id: String,
        label: String,
        object: [String: Any]?
    ) -> AllowanceWindow? {
        guard let object,
              let utilization = JSONSupport.double(object["utilization"])
        else { return nil }
        let usedPercent = utilization <= 1 ? utilization * 100 : utilization
        return AllowanceWindow(
            id: id,
            label: label,
            remainingPercent: 100 - usedPercent,
            resetAt: UsageDateParser.parse(JSONSupport.string(object["resets_at"]))
        )
    }
}

private enum ClaudeCredentialReader {
    static func accessToken() async throws -> String? {
        if let token = ProcessInfo.processInfo.environment["CLAUDE_CODE_OAUTH_TOKEN"],
           !token.isEmpty {
            return token
        }

        let credentialsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: credentialsURL),
           let token = token(from: data) {
            return token
        }

        guard let security = ProcessRunner.findExecutable(
            named: "security",
            preferredPaths: ["/usr/bin/security"]
        ) else { return nil }

        let result = try await ProcessRunner.run(
            executable: security,
            arguments: [
                "find-generic-password",
                "-a", NSUserName(),
                "-w",
                "-s", "Claude Code-credentials"
            ],
            timeout: 5
        )
        guard result.terminationStatus == 0 else { return nil }
        return token(from: result.standardOutput)
            ?? String(data: result.standardOutput, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .nilIfEmpty
    }

    private static func token(from data: Data) -> String? {
        guard let root = try? JSONSupport.dictionary(from: data) else { return nil }
        if let oauth = root["claudeAiOauth"] as? [String: Any],
           let token = oauth["accessToken"] as? String {
            return token
        }
        return root["accessToken"] as? String
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
