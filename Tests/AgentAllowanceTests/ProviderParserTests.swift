import CElectronSafeStorage
import Foundation
import XCTest
@testable import AgentAllowance

final class ProviderParserTests: XCTestCase {
    func testProcessRunnerKeepsInputOpenUntilResponseMarker() async throws {
        let script = "IFS= read -r request; printf '%s\\n' '{\"id\":2}'; IFS= read -r rest || true"

        let result = try await ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            input: Data("request\n".utf8),
            timeout: 2,
            waitForOutputContaining: #""id":2"#
        )

        XCTAssertEqual(result.terminationStatus, 0)
        XCTAssertTrue(result.outputString.contains(#""id":2"#))
    }

    func testCodexParserConvertsUsedToRemaining() throws {
        let response = #"{"id":2,"result":{"rateLimits":{"limitId":"codex","primary":{"usedPercent":43,"windowDurationMins":300,"resetsAt":1788196416},"secondary":{"usedPercent":14,"windowDurationMins":10080,"resetsAt":1788783216}}}}"#

        let windows = try CodexUsageClient.parse(Data(response.utf8))

        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].label, "5h session")
        XCTAssertEqual(windows[0].remainingPercent, 57)
        XCTAssertEqual(windows[1].label, "Weekly")
        XCTAssertEqual(windows[1].remainingPercent, 86)
    }

    func testClaudeParserSupportsFractionalUtilization() throws {
        let response = #"{"five_hour":{"utilization":0.46,"resets_at":"2026-08-31T17:15:00.000000+00:00"},"seven_day":{"utilization":0.98,"resets_at":"2026-09-01T03:04:00Z"}}"#

        let windows = try ClaudeUsageClient.parse(Data(response.utf8))

        XCTAssertEqual(windows.map(\.remainingPercent), [54, 2])
        XCTAssertNotNil(windows[0].resetAt)
        XCTAssertNotNil(windows[1].resetAt)
    }

    func testCursorParserConvertsBillingCycleUsageToRemaining() throws {
        var planUsage = Data([0x10])
        planUsage.appendVarint(43)
        planUsage.append(0x28)
        planUsage.appendVarint(100)

        var response = Data([0x10])
        response.appendVarint(1_788_196_416_000)
        response.append(0x1a)
        response.appendVarint(UInt64(planUsage.count))
        response.append(planUsage)

        let windows = try CursorUsageClient.parse(response)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "Billing cycle")
        XCTAssertEqual(windows[0].remainingPercent, 57)
        XCTAssertEqual(windows[0].resetAt?.timeIntervalSince1970, 1_788_196_416)
    }

    func testDevinParserKeepsDailyAndWeeklyQuotaWindows() throws {
        var planInfo = Data([0x12, 0x04])
        planInfo.append(Data("Free".utf8))
        planInfo.append(contentsOf: [0x90, 0x02, 0x01])
        planInfo.append(contentsOf: [0x98, 0x02, 0x02])

        var planStatus = Data([0x0a])
        planStatus.appendVarint(UInt64(planInfo.count))
        planStatus.append(planInfo)
        planStatus.append(0x70)
        planStatus.appendVarint(57)
        planStatus.append(0x78)
        planStatus.appendVarint(86)
        planStatus.append(contentsOf: [0x88, 0x01])
        planStatus.appendVarint(1_788_196_416)
        planStatus.append(contentsOf: [0x90, 0x01])
        planStatus.appendVarint(1_788_783_216)

        var userStatus = Data([0x6a])
        userStatus.appendVarint(UInt64(planStatus.count))
        userStatus.append(planStatus)

        let windows = try DevinUsageClient.parse(
            userStatus,
            now: Date(timeIntervalSince1970: 1_788_000_000)
        )

        XCTAssertEqual(windows.map(\.label), ["Daily", "Weekly"])
        XCTAssertEqual(windows.map(\.scope), ["Free", "Free"])
        XCTAssertEqual(windows.map(\.remainingPercent), [57, 86])
    }

    func testDevinParserOmitsAnExpiredDailyQuotaWindow() throws {
        var planInfo = Data([0x12, 0x04])
        planInfo.append(Data("Free".utf8))
        planInfo.append(contentsOf: [0x90, 0x02, 0x01])
        planInfo.append(contentsOf: [0x98, 0x02, 0x02])

        var planStatus = Data([0x0a])
        planStatus.appendVarint(UInt64(planInfo.count))
        planStatus.append(planInfo)
        planStatus.append(0x70)
        planStatus.appendVarint(57)
        planStatus.append(0x78)
        planStatus.appendVarint(86)
        planStatus.append(contentsOf: [0x88, 0x01])
        planStatus.appendVarint(1_787_999_999)
        planStatus.append(contentsOf: [0x90, 0x01])
        planStatus.appendVarint(1_788_783_216)

        var userStatus = Data([0x6a])
        userStatus.appendVarint(UInt64(planStatus.count))
        userStatus.append(planStatus)

        let windows = try DevinUsageClient.parse(
            userStatus,
            now: Date(timeIntervalSince1970: 1_788_000_000)
        )

        XCTAssertEqual(windows.map(\.label), ["Weekly"])
        XCTAssertEqual(windows.map(\.remainingPercent), [86])
    }

    func testGrokParserTreatsOmittedZeroUsageAsFullRemaining() throws {
        let response = #"{"config":{"currentPeriod":{"type":"USAGE_PERIOD_TYPE_WEEKLY","start":"2026-08-30T21:48:05.596090+00:00","end":"2026-09-06T21:48:05.596090+00:00"}}}"#

        let windows = try GrokBuildUsageClient.parse(Data(response.utf8))

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "Weekly")
        XCTAssertEqual(windows[0].remainingPercent, 100)
        XCTAssertNotNil(windows[0].resetAt)
    }

    func testGrokBotParserConvertsUsedToRemaining() throws {
        let resetSeconds: UInt64 = 1_788_783_216
        var timestamp = Data([0x08])
        timestamp.appendVarint(resetSeconds)

        var response = Data([0x12])
        response.appendVarint(UInt64(timestamp.count))
        response.append(timestamp)
        response.append(0x19)
        response.appendFixed64(57.0.bitPattern)
        response.append(contentsOf: [0x30, 0x00])
        let plan = Data("SuperGrok".utf8)
        response.append(0x7a)
        response.appendVarint(UInt64(plan.count))
        response.append(plan)

        let windows = try GrokBotUsageClient.parse(response)

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "Weekly")
        XCTAssertEqual(windows[0].scope, "SuperGrok")
        XCTAssertEqual(windows[0].remainingPercent, 43)
        XCTAssertEqual(windows[0].resetAt?.timeIntervalSince1970, Double(resetSeconds))
    }

    func testGrokBotChecksumMatchesInstalledClientAlgorithm() {
        let date = Date(timeIntervalSince1970: 1_788_000_000)

        XCTAssertEqual(
            GrokBotUsageClient.cursorChecksum(machineID: "machine", now: date),
            "7Y6Qjsqvmachine"
        )
    }

    func testElectronSafeStorageDecryptsKnownMacPayload() throws {
        let payload = Data([
            0x76, 0x31, 0x30, 0xc7, 0xa5, 0x63, 0x0b, 0x0c, 0xc8, 0xb8,
            0x6b, 0xd0, 0xd1, 0x70, 0x94, 0x75, 0x2a, 0x4e, 0x70
        ])
        let password = Data("testpassword".utf8)
        var plaintext = Data(count: payload.count)
        let capacity = plaintext.count
        var plaintextLength = 0

        let result = plaintext.withUnsafeMutableBytes { output in
            payload.withUnsafeBytes { encrypted in
                password.withUnsafeBytes { passwordBytes in
                    ElectronSafeStorageDecrypt(
                        encrypted.bindMemory(to: UInt8.self).baseAddress,
                        payload.count,
                        passwordBytes.bindMemory(to: UInt8.self).baseAddress,
                        password.count,
                        output.bindMemory(to: UInt8.self).baseAddress,
                        capacity,
                        &plaintextLength
                    )
                }
            }
        }

        XCTAssertEqual(result, Int32(ElectronSafeStorageSuccess.rawValue))
        plaintext.removeSubrange(plaintextLength..<plaintext.count)
        XCTAssertEqual(String(data: plaintext, encoding: .utf8), "hello Electron")
    }

    func testGrokBotLiveUsageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_GROK_BOT_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set RUN_GROK_BOT_LIVE_TEST=1 to query the local Grok Bot account.")
        }

        let windows = try await GrokBotUsageClient().fetchWindows()

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].label, "Weekly")
        XCTAssertNotNil(windows[0].remainingPercent)
        XCTAssertNotNil(windows[0].resetAt)
    }

    func testCursorLiveUsageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_CURSOR_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set RUN_CURSOR_LIVE_TEST=1 to query the local Cursor account.")
        }

        let windows = try await CursorUsageClient().fetchWindows()

        XCTAssertEqual(windows.count, 1)
        XCTAssertNotNil(windows[0].remainingPercent)
        XCTAssertNotNil(windows[0].resetAt)
    }

    func testDevinLiveUsageWhenEnabled() async throws {
        guard ProcessInfo.processInfo.environment["RUN_DEVIN_LIVE_TEST"] == "1" else {
            throw XCTSkip("Set RUN_DEVIN_LIVE_TEST=1 to read Devin's local usage cache.")
        }

        let windows = try await DevinUsageClient().fetchWindows()

        XCTAssertFalse(windows.isEmpty)
        XCTAssertTrue(windows.allSatisfy { $0.remainingPercent != nil })
        XCTAssertTrue(windows.allSatisfy { $0.resetAt != nil })
    }

    func testAntigravityParserKeepsBothModelPools() throws {
        let output = """
        Gemini Models\tWeekly Limit Remaining\t86%\t2026-09-07T12:48:47Z
        Gemini Models\tFive Hour Limit Remaining\t57%\t2026-08-31T17:48:47Z
        Claude and GPT models\tWeekly Limit Remaining\t2%\t2026-09-07T13:05:06Z
        Claude and GPT models\tFive Hour Limit Remaining\t54%\t2026-08-31T18:05:06Z
        """

        let windows = try AntigravityUsageClient.parse(output)

        XCTAssertEqual(windows.count, 4)
        XCTAssertEqual(windows.map(\.scope), ["Gemini", "Gemini", "Claude and GPT", "Claude and GPT"])
        XCTAssertEqual(windows.map(\.label), ["5h session", "Weekly", "5h session", "Weekly"])
        XCTAssertEqual(windows.map(\.remainingPercent), [57, 86, 54, 2])
    }

    func testResetTimeFormatting() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            ResetTimeFormatter.string(until: now.addingTimeInterval(4 * 3_600 + 23 * 60), now: now),
            "4h 23m"
        )
        XCTAssertEqual(
            ResetTimeFormatter.string(until: now.addingTimeInterval(6 * 86_400 + 4 * 3_600), now: now),
            "6d 4h"
        )
    }

    // MARK: - Installed-provider filtering

    private struct StubClient: UsageProviderClient {
        let provider: AgentProvider
        let installed: Bool
        var windows: [AllowanceWindow] = []
        var failure: (any Error)?

        func isInstalled() -> Bool { installed }

        func fetchWindows() async throws -> [AllowanceWindow] {
            if let failure { throw failure }
            return windows
        }
    }

    private func window(_ id: String) -> AllowanceWindow {
        AllowanceWindow(
            id: id,
            label: "Weekly",
            remainingPercent: 50,
            resetAt: Date(timeIntervalSince1970: 4_000_000_000)
        )
    }

    func testFetchAllOmitsProvidersThatAreNotInstalled() async {
        let service = UsageService(clients: [
            StubClient(provider: .codex, installed: true, windows: [window("a")]),
            StubClient(provider: .cursor, installed: false)
        ])

        let usages = await service.fetchAll()

        XCTAssertEqual(usages.map(\.provider), [.codex])
    }

    func testFetchAllKeepsInstalledProvidersThatFail() async {
        let service = UsageService(clients: [
            StubClient(
                provider: .cursor,
                installed: true,
                failure: UsageClientError.notAuthenticated("Cursor is not signed in.")
            )
        ])

        let usages = await service.fetchAll()

        XCTAssertEqual(usages.map(\.provider), [.cursor])
        XCTAssertEqual(usages.first?.error, "Cursor is not signed in.")
    }

    func testInstalledProvidersFollowsDisplayOrder() {
        let service = UsageService(clients: [
            StubClient(provider: .antigravity, installed: true),
            StubClient(provider: .codex, installed: true),
            StubClient(provider: .devin, installed: false)
        ])

        XCTAssertEqual(service.installedProviders, [.codex, .antigravity])
    }
}

private extension Data {
    mutating func appendVarint(_ value: UInt64) {
        var remainder = value
        while remainder >= 0x80 {
            append(UInt8(remainder & 0x7f) | 0x80)
            remainder >>= 7
        }
        append(UInt8(remainder))
    }

    mutating func appendFixed64(_ value: UInt64) {
        for byteOffset in 0..<8 {
            append(UInt8(truncatingIfNeeded: value >> UInt64(byteOffset * 8)))
        }
    }
}
