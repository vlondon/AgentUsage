import Foundation
import XCTest
@testable import AgentAllowanceCore

final class AllowanceSnapshotTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func object(_ snapshot: AllowanceSnapshot) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: snapshot.jsonData()) as? [String: Any])
    }

    func testContractShapeAndUninstalledProviders() throws {
        let reset = Date(timeIntervalSince1970: 1_800_003_600)
        let usages = [
            ProviderUsage(
                provider: .claude,
                windows: [
                    AllowanceWindow(id: "claude-five-hour", label: "5h session", remainingPercent: 72, resetAt: reset),
                    AllowanceWindow(id: "claude-seven-day", label: "Weekly", scope: "All models", remainingPercent: 50, resetAt: nil),
                    AllowanceWindow(id: "claude-seven-day-opus", label: "Weekly", scope: "Opus", remainingPercent: 10, resetAt: reset)
                ],
                error: nil, fetchedAt: now, isLoading: false
            ),
            ProviderUsage(provider: .codex, windows: [], error: "Sign in", fetchedAt: now, isLoading: false)
        ]
        let root = try object(AllowanceSnapshot(usages: usages, generatedAt: now))
        XCTAssertEqual(root["schema"] as? Int, 1)
        XCTAssertEqual(root["generated_at"] as? String, "2027-01-15T08:00:00Z")

        let providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.map { $0["id"] as? String },
                       ["codex", "claude", "cursor", "devin", "grok_build", "grok_bot", "antigravity"])
        XCTAssertEqual(providers[0]["error"] as? String, "Sign in")
        XCTAssertEqual(providers[2]["installed"] as? Bool, false)
        XCTAssertTrue(providers[2]["error"] is NSNull)
        XCTAssertEqual((providers[2]["windows"] as? [Any])?.count, 0)

        let windows = try XCTUnwrap(providers[1]["windows"] as? [[String: Any]])
        XCTAssertEqual(windows[0]["id"] as? String, "five_hour")
        XCTAssertEqual(windows[0]["label"] as? String, "5h session")
        XCTAssertEqual(windows[0]["remaining_pct"] as? Double, 72)
        XCTAssertEqual(windows[0]["resets_at"] as? String, "2027-01-15T09:00:00Z")
        XCTAssertEqual(windows[0]["window_minutes"] as? Int, 300)
        XCTAssertTrue(windows[0]["scope"] is NSNull)
        XCTAssertTrue(windows[1]["resets_at"] is NSNull)
        XCTAssertTrue(windows[1]["scope"] is NSNull)
        XCTAssertEqual(windows[2]["id"] as? String, "weekly")
        XCTAssertEqual(windows[2]["scope"] as? String, "opus")
        XCTAssertEqual(windows[2]["window_minutes"] as? Int, 10_080)
    }

    func testWindowKindsAndScopes() {
        func map(_ provider: AgentProvider, _ id: String, _ label: String, _ scope: String? = nil) -> AllowanceSnapshot.Window {
            .init(provider: provider, window: AllowanceWindow(id: id, label: label, scope: scope, remainingPercent: 1))
        }
        XCTAssertEqual(map(.codex, "codex-primary", "Session").id, "five_hour")
        XCTAssertEqual(map(.codex, "codex-secondary", "3h window").windowMinutes, 180)
        XCTAssertEqual(map(.devin, "devin-daily", "Daily", "Pro").id, "daily")
        XCTAssertEqual(map(.devin, "devin-daily", "Daily", "Pro").windowMinutes, 1_440)
        XCTAssertNil(map(.devin, "devin-daily", "Daily", "Pro").scope)
        XCTAssertEqual(map(.cursor, "cursor-billing-cycle", "Billing cycle").id, "billing_cycle")
        XCTAssertNil(map(.cursor, "cursor-billing-cycle", "Billing cycle").windowMinutes)
        XCTAssertEqual(map(.devin, "devin-credits-billing-cycle", "Billing cycle").id, "billing_cycle_credits")
        XCTAssertEqual(map(.antigravity, "x", "Weekly", "Gemini").scope, "gemini")
        XCTAssertEqual(map(.antigravity, "x", "5h session", "Claude and GPT").scope, "claude_gpt")
    }

    func testRoundTripAndAtomicCacheWrite() throws {
        let snapshot = AllowanceSnapshot(usages: [], generatedAt: now)
        XCTAssertEqual(try AllowanceSnapshot.decode(snapshot.jsonData()), snapshot)

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/usage.json")
        try snapshot.writeCache(to: url)
        try snapshot.writeCache(to: url)
        XCTAssertEqual(try AllowanceSnapshot.decode(Data(contentsOf: url)), snapshot)
        let siblings = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(siblings, ["usage.json"])
    }
}
