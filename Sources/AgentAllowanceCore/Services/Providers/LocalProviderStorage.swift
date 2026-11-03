import Foundation

enum LocalProviderStorage {
    static func value(databaseURL: URL, key: String) async throws -> String? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else {
            return nil
        }

        let escapedKey = key.replacingOccurrences(of: "'", with: "''")
        let result = try await ProcessRunner.run(
            executable: "/usr/bin/sqlite3",
            arguments: [
                "-batch",
                "-readonly",
                "-noheader",
                databaseURL.path,
                "SELECT value FROM ItemTable WHERE key = '\(escapedKey)' LIMIT 1;"
            ],
            timeout: 5
        )
        guard result.terminationStatus == 0 else {
            throw UsageClientError.unavailable("The provider's local usage data could not be read.")
        }

        let value = result.outputString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
