import Foundation

struct CursorUsageClient: UsageProviderClient {
    let provider: AgentProvider = .cursor

    func isInstalled() -> Bool {
        ProviderInstallation.hasHomePath("Library/Application Support/Cursor")
    }

    func fetchWindows() async throws -> [AllowanceWindow] {
        let credentials = try await CursorCredentialStore.load()
        var request = URLRequest(
            url: URL(
                string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage"
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
            CursorProtocolSupport.checksum(
                machineID: credentials.machineID,
                macMachineID: credentials.macMachineID
            ),
            forHTTPHeaderField: "x-cursor-checksum"
        )
        request.setValue("ide", forHTTPHeaderField: "x-cursor-client-type")
        request.setValue(credentials.clientVersion, forHTTPHeaderField: "x-cursor-client-version")
        request.setValue("darwin", forHTTPHeaderField: "x-cursor-client-os")
        request.setValue(Self.clientArchitecture, forHTTPHeaderField: "x-cursor-client-arch")
        request.setValue("desktop", forHTTPHeaderField: "x-cursor-client-device-type")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "x-request-id")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw UsageClientError.unavailable("Cursor usage could not be reached.")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw UsageClientError.notAuthenticated(
                "Cursor sign-in expired. Open Cursor, sign in, then refresh again."
            )
        }
        guard (200..<300).contains(http.statusCode) else {
            throw UsageClientError.unavailable("Cursor usage returned HTTP \(http.statusCode).")
        }
        return try Self.parse(data)
    }

    static func parse(_ data: Data) throws -> [AllowanceWindow] {
        let usage = try CursorCurrentPeriodUsage(protobuf: data)
        guard let remainingPercent = usage.remainingPercent,
              remainingPercent.isFinite
        else {
            throw UsageClientError.invalidResponse(
                "Cursor did not report a billing-cycle allowance."
            )
        }

        return [
            AllowanceWindow(
                id: "cursor-billing-cycle",
                label: "Billing cycle",
                remainingPercent: remainingPercent,
                resetAt: usage.resetAt
            )
        ]
    }

    private static var clientArchitecture: String {
        #if arch(arm64)
        "arm64"
        #elseif arch(x86_64)
        "x64"
        #else
        "unknown"
        #endif
    }
}

private struct CursorCredentials {
    let accessToken: String
    let machineID: String
    let macMachineID: String?
    let clientVersion: String
}

private enum CursorCredentialStore {
    static func load() async throws -> CursorCredentials {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let supportURL = home.appendingPathComponent(
            "Library/Application Support/Cursor/User/globalStorage"
        )
        let databaseURL = supportURL.appendingPathComponent("state.vscdb")
        guard var accessToken = try await LocalProviderStorage.value(
            databaseURL: databaseURL,
            key: "cursorAuth/accessToken"
        ) else {
            throw UsageClientError.notAuthenticated(
                "Cursor is not signed in. Open Cursor and sign in first."
            )
        }
        if accessToken.hasPrefix("\"") {
            accessToken = (try? JSONDecoder().decode(String.self, from: Data(accessToken.utf8)))
                ?? accessToken
        }

        let storageURL = supportURL.appendingPathComponent("storage.json")
        guard let storageData = try? Data(contentsOf: storageURL),
              let storage = try? JSONSerialization.jsonObject(with: storageData) as? [String: Any],
              let machineID = storage["telemetry.machineId"] as? String,
              !machineID.isEmpty
        else {
            throw UsageClientError.unavailable(
                "Cursor's local device identity could not be read."
            )
        }

        return CursorCredentials(
            accessToken: accessToken,
            machineID: machineID,
            macMachineID: nonempty(storage["telemetry.macMachineId"] as? String),
            clientVersion: clientVersion()
        )
    }

    private static func clientVersion() -> String {
        let plistURL = URL(fileURLWithPath: "/Applications/Cursor.app/Contents/Info.plist")
        guard let data = try? Data(contentsOf: plistURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let root = plist as? [String: Any],
              let version = root["CFBundleShortVersionString"] as? String,
              !version.isEmpty
        else { return "unknown" }
        return version
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}

private struct CursorCurrentPeriodUsage {
    var billingCycleEnd: UInt64?
    var planUsage: CursorPlanUsage?

    init(protobuf data: Data) throws {
        var reader = ProtobufReader(
            data: data,
            errorMessage: "Cursor returned an invalid usage response."
        )
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (2, 0):
                billingCycleEnd = try reader.readVarint()
            case (3, 2):
                planUsage = try CursorPlanUsage(protobuf: reader.readLengthDelimited())
            default:
                try reader.skip(wireType: field.wireType)
            }
        }
    }

    var remainingPercent: Double? {
        guard let planUsage else { return nil }
        if let limit = planUsage.limit, limit > 0,
           let includedSpend = planUsage.includedSpend {
            return 100 - min(includedSpend / limit * 100, 100)
        }
        return planUsage.totalPercentUsed.map { 100 - $0 }
    }

    var resetAt: Date? {
        guard let billingCycleEnd else { return nil }
        let raw = Double(billingCycleEnd)
        let seconds = raw > 10_000_000_000 ? raw / 1_000 : raw
        return Date(timeIntervalSince1970: seconds)
    }
}

private struct CursorPlanUsage {
    var includedSpend: Double?
    var limit: Double?
    var totalPercentUsed: Double?

    init(protobuf data: Data) throws {
        var reader = ProtobufReader(
            data: data,
            errorMessage: "Cursor returned an invalid usage response."
        )
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (2, 0):
                includedSpend = Double(try reader.readVarint())
            case (5, 0):
                limit = Double(try reader.readVarint())
            case (14, 1):
                totalPercentUsed = Double(bitPattern: try reader.readFixed64())
            default:
                try reader.skip(wireType: field.wireType)
            }
        }
    }
}
