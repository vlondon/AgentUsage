import Foundation

struct CodexUsageClient: UsageProviderClient {
    let provider: AgentProvider = .codex

    func isInstalled() -> Bool {
        ProviderInstallation.hasExecutable("codex")
    }

    func fetchWindows() async throws -> [AllowanceWindow] {
        guard let executable = ProcessRunner.findExecutable(named: "codex") else {
            throw ProcessRunnerError.executableNotFound("Codex CLI")
        }

        let requests = [
            #"{"id":1,"method":"initialize","params":{"clientInfo":{"name":"AgentAllowance","version":"0.1.0"}}}"#,
            #"{"method":"initialized"}"#,
            #"{"id":2,"method":"account/rateLimits/read"}"#
        ].joined(separator: "\n") + "\n"

        let result = try await ProcessRunner.run(
            executable: executable,
            arguments: ["app-server", "--stdio"],
            input: Data(requests.utf8),
            timeout: 12,
            waitForOutputContaining: #""id":2"#
        )

        guard result.terminationStatus == 0 else {
            throw UsageClientError.unavailable("Codex usage is unavailable. Run codex login and try again.")
        }
        return try Self.parse(result.standardOutput)
    }

    static func parse(_ data: Data) throws -> [AllowanceWindow] {
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        for line in lines {
            guard let lineData = String(line).data(using: .utf8),
                  let root = try? JSONSupport.dictionary(from: lineData),
                  JSONSupport.double(root["id"]) == 2,
                  let result = root["result"] as? [String: Any]
            else { continue }

            let direct = result["rateLimits"] as? [String: Any]
            let byID = (result["rateLimitsByLimitId"] as? [String: Any])?["codex"] as? [String: Any]
            guard let limits = direct ?? byID else { continue }

            let primary = makeWindow(
                id: "codex-primary",
                fallbackLabel: "Session",
                object: limits["primary"] as? [String: Any]
            )
            let secondary = makeWindow(
                id: "codex-secondary",
                fallbackLabel: "Weekly",
                object: limits["secondary"] as? [String: Any]
            )
            let windows = [primary, secondary].compactMap { $0 }
            if !windows.isEmpty { return windows }
        }
        throw UsageClientError.invalidResponse("Codex did not report any allowance windows.")
    }

    private static func makeWindow(
        id: String,
        fallbackLabel: String,
        object: [String: Any]?
    ) -> AllowanceWindow? {
        guard let object,
              let used = JSONSupport.double(object["usedPercent"])
        else { return nil }

        let minutes = Int(JSONSupport.double(object["windowDurationMins"]) ?? 0)
        let label: String
        switch minutes {
        case 300: label = "5h session"
        case 10_080: label = "Weekly"
        case let value where value > 0: label = "\(value / 60)h window"
        default: label = fallbackLabel
        }

        let resetAt = JSONSupport.double(object["resetsAt"])
            .map { Date(timeIntervalSince1970: $0) }
        return AllowanceWindow(
            id: id,
            label: label,
            remainingPercent: 100 - used,
            resetAt: resetAt
        )
    }
}
