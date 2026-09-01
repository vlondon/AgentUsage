import Foundation

enum UsageClientError: LocalizedError {
    case notAuthenticated(String)
    case unavailable(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .notAuthenticated(let message),
             .unavailable(let message),
             .invalidResponse(let message):
            message
        }
    }
}

enum JSONSupport {
    static func dictionary(from data: Data) throws -> [String: Any] {
        guard let dictionary = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UsageClientError.invalidResponse("The provider returned an unexpected response.")
        }
        return dictionary
    }

    static func double(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }

    static func string(_ value: Any?) -> String? {
        value as? String
    }
}

/// Whether a provider's tool is present at all, as opposed to present but
/// signed out. Absent tools are hidden instead of reported as errors.
enum ProviderInstallation {
    static func hasExecutable(_ name: String) -> Bool {
        ProcessRunner.findExecutable(named: name) != nil
    }

    static func hasHomePath(_ relativePath: String) -> Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(relativePath)
        return FileManager.default.fileExists(atPath: url.path)
    }
}
