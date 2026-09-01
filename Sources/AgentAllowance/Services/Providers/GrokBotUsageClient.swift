import CElectronSafeStorage
import Foundation
import Security

struct GrokBotUsageClient: UsageProviderClient {
    let provider: AgentProvider = .grokBot

    func isInstalled() -> Bool {
        ProviderInstallation.hasHomePath("Library/Application Support/Grok Bot")
    }

    func fetchWindows() async throws -> [AllowanceWindow] {
        let credentials = try GrokBotCredentialStore.load()
        var request = URLRequest(
            url: URL(
                string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetSandUsageStatus"
            )!
        )
        request.httpMethod = "POST"
        request.httpBody = Data()
        request.timeoutInterval = 10
        request.setValue("application/proto", forHTTPHeaderField: "Content-Type")
        request.setValue("application/proto", forHTTPHeaderField: "Accept")
        request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(
            Self.cursorChecksum(machineID: credentials.machineID),
            forHTTPHeaderField: "x-cursor-checksum"
        )
        request.setValue("sand", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue("0.30.0", forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("prod", forHTTPHeaderField: "x-sand-box-namespace")
        request.setValue("true", forHTTPHeaderField: "x-ghost-mode")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")
        if let teamID = credentials.teamID {
            request.setValue(String(teamID), forHTTPHeaderField: "x-cursor-team-id")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.unavailable("Grok Bot usage could not be reached.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageClientError.notAuthenticated(
                "Grok Bot sign-in expired. Open Grok Bot, then refresh again."
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageClientError.unavailable("Grok Bot usage returned HTTP \(http.statusCode).")
        }

        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [AllowanceWindow] {
        let status = try GrokBotUsageStatus(protobuf: data)
        if status.usesPooledEnterpriseAllowance {
            throw UsageClientError.unavailable(
                "Grok Bot uses a pooled team allowance instead of a personal weekly limit."
            )
        }
        guard let usedPercent = status.usedPercent, usedPercent.isFinite else {
            throw UsageClientError.invalidResponse("Grok Bot did not report a weekly allowance.")
        }

        return [
            AllowanceWindow(
                id: "grok-bot-weekly",
                label: "Weekly",
                scope: status.planLabel,
                remainingPercent: 100 - usedPercent,
                resetAt: status.resetAt
            )
        ]
    }

    static func cursorChecksum(machineID: String, now: Date = Date()) -> String {
        CursorProtocolSupport.checksum(machineID: machineID, now: now)
    }
}

private struct GrokBotCredentials {
    let accessToken: String
    let machineID: String
    let teamID: Int?
}

private enum GrokBotCredentialStore {
    private static let keychainService = "Grok Bot Safe Storage"
    private static let keychainAccount = "Grok Bot Key"

    static func load() throws -> GrokBotCredentials {
        let secretsURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Grok Bot/sand-secrets.json")
        let data: Data
        do {
            data = try Data(contentsOf: secretsURL)
        } catch {
            throw UsageClientError.notAuthenticated(
                "Grok Bot is not signed in. Open Grok Bot and sign in first."
            )
        }

        guard let root = try? JSONDecoder().decode([String: String].self, from: data),
              let accountsJSON = root["cursor-accounts"],
              let accountsData = accountsJSON.data(using: .utf8),
              let accounts = try? JSONDecoder().decode(AccountsRecord.self, from: accountsData),
              let activeID = accounts.active,
              let activeAccount = accounts.accounts[activeID],
              let encryptedToken = activeAccount["cursor-access-token"],
              let encryptedMachineID = root["cursor-machine-id"]
        else {
            throw UsageClientError.notAuthenticated(
                "Grok Bot has no active local sign-in. Open Grok Bot and sign in first."
            )
        }

        let keychainPassword = try readKeychainPassword()
        let accessToken = try decrypt(encryptedToken, password: keychainPassword)
        let machineID = try decrypt(encryptedMachineID, password: keychainPassword)
        let teamID = activeAccount["cursor-selected-team-id"]
            .flatMap { try? decrypt($0, password: keychainPassword) }
            .flatMap(Int.init)

        return GrokBotCredentials(
            accessToken: accessToken,
            machineID: machineID,
            teamID: teamID
        )
    }

    private static func readKeychainPassword() throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: keychainAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let password = result as? Data else {
            if status == errSecUserCanceled || status == errSecAuthFailed {
                throw UsageClientError.notAuthenticated(
                    "Keychain access was not allowed for Grok Bot usage."
                )
            }
            throw UsageClientError.notAuthenticated(
                "Grok Bot's local Keychain sign-in could not be read."
            )
        }
        return password
    }

    private static func decrypt(_ storedValue: String, password: Data) throws -> String {
        let ciphertextBase64: Substring
        if storedValue.hasPrefix("scoped:v1:") {
            guard let finalColon = storedValue.lastIndex(of: ":") else {
                throw UsageClientError.invalidResponse("Grok Bot's local sign-in is invalid.")
            }
            ciphertextBase64 = storedValue[storedValue.index(after: finalColon)...]
        } else {
            ciphertextBase64 = Substring(storedValue)
        }

        guard let encrypted = Data(base64Encoded: String(ciphertextBase64)) else {
            throw UsageClientError.invalidResponse("Grok Bot's local sign-in is invalid.")
        }
        var plaintext = Data(count: encrypted.count)
        let plaintextCapacity = plaintext.count
        var plaintextLength = 0
        let result = plaintext.withUnsafeMutableBytes { output in
            encrypted.withUnsafeBytes { payload in
                password.withUnsafeBytes { passwordBytes in
                    ElectronSafeStorageDecrypt(
                        payload.bindMemory(to: UInt8.self).baseAddress,
                        encrypted.count,
                        passwordBytes.bindMemory(to: UInt8.self).baseAddress,
                        password.count,
                        output.bindMemory(to: UInt8.self).baseAddress,
                        plaintextCapacity,
                        &plaintextLength
                    )
                }
            }
        }
        guard result == ElectronSafeStorageSuccess.rawValue,
              plaintextLength <= plaintext.count
        else {
            throw UsageClientError.notAuthenticated(
                "Grok Bot's local sign-in could not be decrypted."
            )
        }
        plaintext.removeSubrange(plaintextLength..<plaintext.count)
        guard let value = String(data: plaintext, encoding: .utf8), !value.isEmpty else {
            throw UsageClientError.invalidResponse("Grok Bot's local sign-in is invalid.")
        }
        return value
    }

    private struct AccountsRecord: Decodable {
        let active: String?
        let accounts: [String: [String: String]]
    }
}

private struct GrokBotUsageStatus {
    var usedPercent: Double?
    var resetAt: Date?
    var usesPooledEnterpriseAllowance = false
    var planLabel: String?

    init(protobuf data: Data) throws {
        var reader = ProtobufReader(
            data: data,
            errorMessage: "Grok Bot returned an invalid usage response."
        )
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (2, 2):
                resetAt = try ProtobufSupport.timestamp(
                    from: reader.readLengthDelimited(),
                    errorMessage: "Grok Bot returned an invalid usage response."
                )
            case (3, 1):
                usedPercent = Double(bitPattern: try reader.readFixed64())
            case (6, 0):
                usesPooledEnterpriseAllowance = try reader.readVarint() != 0
            case (15, 2):
                let value = String(data: try reader.readLengthDelimited(), encoding: .utf8)
                planLabel = value?.isEmpty == false ? value : nil
            default:
                try reader.skip(wireType: field.wireType)
            }
        }
    }

}
