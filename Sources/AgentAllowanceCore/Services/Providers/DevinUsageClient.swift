import Foundation

struct DevinUsageClient: UsageProviderClient {
    let provider: AgentProvider = .devin

    func isInstalled() -> Bool {
        ProviderInstallation.hasHomePath("Library/Application Support/Devin")
    }

    func fetchWindows() async throws -> [AllowanceWindow] {
        let databaseURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/Devin/User/globalStorage/state.vscdb"
            )
        guard let storedValue = try await LocalProviderStorage.value(
            databaseURL: databaseURL,
            key: "windsurfAuthStatus"
        ) else {
            throw UsageClientError.notAuthenticated(
                "Devin has no local sign-in. Open Devin and sign in first."
            )
        }
        return try Self.parseCache(Data(storedValue.utf8), now: Date())
    }

    static func parseCache(_ data: Data, now: Date = Date()) throws -> [AllowanceWindow] {
        let cache: DevinAuthStatusCache
        do {
            cache = try JSONDecoder().decode(DevinAuthStatusCache.self, from: data)
        } catch {
            throw UsageClientError.invalidResponse("Devin's local usage data is invalid.")
        }
        guard let encodedStatus = cache.userStatusProtoBinaryBase64,
              let statusData = Data(base64Encoded: encodedStatus)
        else {
            throw UsageClientError.notAuthenticated(
                "Devin has no local sign-in. Open Devin and sign in first."
            )
        }
        return try Self.parse(statusData, now: now)
    }

    static func parse(_ data: Data, now: Date = Date()) throws -> [AllowanceWindow] {
        let status = try DevinUserStatus(protobuf: data)
        guard let plan = status.planStatus, plan.planInfo.isDevin else {
            throw UsageClientError.invalidResponse(
                "Devin did not report an allowance for the active account."
            )
        }

        switch plan.planInfo.billingStrategy {
        case 2:
            return try quotaWindows(for: plan, now: now)
        case 3:
            guard let consumed = plan.acuConsumed,
                  let limit = plan.acuLimit,
                  limit > 0
            else {
                throw UsageClientError.invalidResponse("Devin did not report its ACU allowance.")
            }
            try requireFresh(plan.planEnd, now: now)
            return [
                AllowanceWindow(
                    id: "devin-acu-billing-cycle",
                    label: "Billing cycle",
                    scope: plan.planInfo.planName,
                    remainingPercent: 100 - consumed / limit * 100,
                    resetAt: plan.planEnd
                )
            ]
        default:
            guard let available = plan.availablePromptCredits,
                  available > 0,
                  let used = plan.usedPromptCredits
            else {
                throw UsageClientError.invalidResponse(
                    "Devin did not report a percentage-based allowance."
                )
            }
            try requireFresh(plan.planEnd, now: now)
            return [
                AllowanceWindow(
                    id: "devin-credits-billing-cycle",
                    label: "Billing cycle",
                    scope: plan.planInfo.planName,
                    remainingPercent: 100 - used / available * 100,
                    resetAt: plan.planEnd
                )
            ]
        }
    }

    private static func quotaWindows(
        for plan: DevinPlanStatus,
        now: Date
    ) throws -> [AllowanceWindow] {
        var windows: [AllowanceWindow] = []
        if !plan.planInfo.hideDailyQuota,
           let remaining = plan.dailyRemainingPercent,
           let resetAt = plan.dailyResetAt,
           resetAt > now {
            windows.append(
                AllowanceWindow(
                    id: "devin-daily",
                    label: "Daily",
                    scope: plan.planInfo.planName,
                    remainingPercent: remaining,
                    resetAt: resetAt
                )
            )
        }
        if !plan.planInfo.hideWeeklyQuota,
           let remaining = plan.weeklyRemainingPercent,
           let resetAt = plan.weeklyResetAt,
           resetAt > now {
            windows.append(
                AllowanceWindow(
                    id: "devin-weekly",
                    label: "Weekly",
                    scope: plan.planInfo.planName,
                    remainingPercent: remaining,
                    resetAt: resetAt
                )
            )
        }
        guard !windows.isEmpty else {
            throw UsageClientError.unavailable(
                "Devin usage is out of date. Open Devin once, then refresh again."
            )
        }
        return windows
    }

    private static func requireFresh(_ resetAt: Date?, now: Date) throws {
        guard let resetAt, resetAt > now else {
            throw UsageClientError.unavailable(
                "Devin usage is out of date. Open Devin once, then refresh again."
            )
        }
    }
}

private struct DevinAuthStatusCache: Decodable {
    let userStatusProtoBinaryBase64: String?
}

private struct DevinUserStatus {
    var planStatus: DevinPlanStatus?

    init(protobuf data: Data) throws {
        var reader = ProtobufReader(
            data: data,
            errorMessage: "Devin returned invalid local usage data."
        )
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (13, 2):
                planStatus = try DevinPlanStatus(protobuf: reader.readLengthDelimited())
            default:
                try reader.skip(wireType: field.wireType)
            }
        }
    }
}

private struct DevinPlanStatus {
    var planInfo = DevinPlanInfo()
    var planEnd: Date?
    var availablePromptCredits: Double?
    var usedPromptCredits: Double?
    var dailyRemainingPercent: Double?
    var weeklyRemainingPercent: Double?
    var dailyResetAt: Date?
    var weeklyResetAt: Date?
    var acuConsumed: Double?
    var acuLimit: Double?

    init(protobuf data: Data) throws {
        var reader = ProtobufReader(
            data: data,
            errorMessage: "Devin returned invalid local usage data."
        )
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (1, 2):
                planInfo = try DevinPlanInfo(protobuf: reader.readLengthDelimited())
            case (3, 2):
                planEnd = try ProtobufSupport.timestamp(
                    from: reader.readLengthDelimited(),
                    errorMessage: "Devin returned invalid local usage data."
                )
            case (6, 0):
                usedPromptCredits = Double(try reader.readVarint())
            case (8, 0):
                availablePromptCredits = Double(try reader.readVarint())
            case (14, 0):
                dailyRemainingPercent = Double(Int32(truncatingIfNeeded: try reader.readVarint()))
            case (15, 0):
                weeklyRemainingPercent = Double(Int32(truncatingIfNeeded: try reader.readVarint()))
            case (17, 0):
                dailyResetAt = Date(timeIntervalSince1970: Double(try reader.readVarint()))
            case (18, 0):
                weeklyResetAt = Date(timeIntervalSince1970: Double(try reader.readVarint()))
            case (19, 1):
                acuConsumed = Double(bitPattern: try reader.readFixed64())
            case (20, 1):
                acuLimit = Double(bitPattern: try reader.readFixed64())
            default:
                try reader.skip(wireType: field.wireType)
            }
        }
    }
}

private struct DevinPlanInfo {
    var planName: String?
    var isDevin = false
    var billingStrategy = 0
    var hideDailyQuota = false
    var hideWeeklyQuota = false

    init() {}

    init(protobuf data: Data) throws {
        self.init()
        var reader = ProtobufReader(
            data: data,
            errorMessage: "Devin returned invalid local usage data."
        )
        while let field = try reader.nextField() {
            switch (field.number, field.wireType) {
            case (2, 2):
                planName = String(data: try reader.readLengthDelimited(), encoding: .utf8)
            case (34, 0):
                isDevin = try reader.readVarint() != 0
            case (35, 0):
                billingStrategy = Int(try reader.readVarint())
            case (36, 0):
                hideDailyQuota = try reader.readVarint() != 0
            case (37, 0):
                hideWeeklyQuota = try reader.readVarint() != 0
            default:
                try reader.skip(wireType: field.wireType)
            }
        }
    }
}
