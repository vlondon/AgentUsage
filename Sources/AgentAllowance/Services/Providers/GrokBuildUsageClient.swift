import Foundation

struct GrokBuildUsageClient: UsageProviderClient {
    let provider: AgentProvider = .grokBuild

    func isInstalled() -> Bool {
        ProviderInstallation.hasExecutable("grok")
            || ProviderInstallation.hasHomePath(".grok")
    }

    func fetchWindows() async throws -> [AllowanceWindow] {
        guard let token = Self.accessToken() else {
            throw UsageClientError.notAuthenticated("Grok is not signed in. Run grok login and try again.")
        }

        var request = URLRequest(
            url: URL(string: "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!
        )
        request.timeoutInterval = 10
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.unavailable("Grok usage could not be reached.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageClientError.notAuthenticated("Grok sign-in expired. Run grok login again.")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageClientError.unavailable("Grok usage returned HTTP \(http.statusCode).")
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [AllowanceWindow] {
        let root = try JSONSupport.dictionary(from: data)
        guard let config = root["config"] as? [String: Any],
              let period = config["currentPeriod"] as? [String: Any]
        else {
            throw UsageClientError.invalidResponse("Grok did not report a weekly allowance window.")
        }

        let used = JSONSupport.double(config["creditUsagePercent"])
            ?? JSONSupport.double(period["creditUsagePercent"])
            ?? 0
        let resetAt = UsageDateParser.parse(JSONSupport.string(period["end"]))

        return [
            AllowanceWindow(
                id: "grok-build-weekly",
                label: "Weekly",
                remainingPercent: 100 - used,
                resetAt: resetAt
            )
        ]
    }

    private static func accessToken() -> String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".grok/auth.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSupport.dictionary(from: data)
        else { return nil }

        if let token = root["key"] as? String { return token }
        for value in root.values {
            if let account = value as? [String: Any],
               let token = account["key"] as? String {
                return token
            }
        }
        return nil
    }
}
