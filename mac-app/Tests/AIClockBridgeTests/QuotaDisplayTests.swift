import XCTest
@testable import AIClockBridge

final class QuotaDisplayTests: XCTestCase {
    func testCodexWeeklyBorderThresholds() {
        XCTAssertEqual(codexWeeklyBorderLevel(nil), .green)
        XCTAssertEqual(codexWeeklyBorderLevel(49.9), .green)
        XCTAssertEqual(codexWeeklyBorderLevel(50), .yellow)
        XCTAssertEqual(codexWeeklyBorderLevel(74.9), .yellow)
        XCTAssertEqual(codexWeeklyBorderLevel(75), .red)
        XCTAssertEqual(codexWeeklyBorderLevel(100), .red)
    }

    func testCodexStatusJSONContainsWeeklyOnly() throws {
        var codex = CodexStatus()
        codex.weeklyPct = 68
        codex.weeklyWindowMin = 10_080
        codex.weeklyResetMin = 120
        let data = Snapshot(claude: ClaudeStatus(), codex: codex, ts: 1).jsonData()
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let encoded = try XCTUnwrap(root["codex"] as? [String: Any])

        XCTAssertEqual((encoded["weekly_pct"] as? NSNumber)?.doubleValue, 68)
        XCTAssertNil(encoded["primary_pct"])
        XCTAssertNil(encoded["primary_window_min"])
        XCTAssertNil(encoded["primary_reset_min"])
    }

    func testBridgeStatusJSONContainsOptionalScreenProviders() throws {
        var snapshot = Snapshot(claude: ClaudeStatus(), codex: CodexStatus(), ts: 1)
        snapshot.grok.weeklyPct = 63
        snapshot.grok.weeklyResetMin = 720
        snapshot.kimi.primaryPct = 25
        snapshot.kimi.primaryResetMin = 180
        snapshot.kimi.weeklyPct = 41
        let root = try XCTUnwrap(
            JSONSerialization.jsonObject(with: snapshot.jsonData()) as? [String: Any]
        )
        let grok = try XCTUnwrap(root["grok"] as? [String: Any])
        let kimi = try XCTUnwrap(root["kimi"] as? [String: Any])

        XCTAssertEqual((grok["weekly_pct"] as? NSNumber)?.doubleValue, 63)
        XCTAssertEqual((grok["weekly_reset_min"] as? NSNumber)?.intValue, 720)
        XCTAssertEqual((kimi["five_hour_pct"] as? NSNumber)?.doubleValue, 25)
        XCTAssertEqual((kimi["five_hour_reset_min"] as? NSNumber)?.intValue, 180)
        XCTAssertEqual((kimi["weekly_pct"] as? NSNumber)?.doubleValue, 41)
    }

    func testClaudeFableScopedWeeklyPayloadAndStatusJSON() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "five_hour": ["utilization": 11.0, "resets_at": "2026-08-01T05:00:00Z"],
            "seven_day": ["utilization": 9.0, "resets_at": "2026-08-07T00:00:00Z"],
            "limits": [[
                "kind": "weekly_scoped", "group": "weekly", "percent": 5.0,
                "resets_at": "2026-08-07T00:00:00Z",
                "scope": ["model": ["display_name": "Fable"]],
            ]],
        ])
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"))
        let usage = try XCTUnwrap(UsageFetcher.parseClaudeUsage(data, now: now))
        XCTAssertEqual(usage.primaryPct, 11)
        XCTAssertEqual(usage.weeklyPct, 9)
        XCTAssertEqual(usage.fablePct, 5)
        XCTAssertEqual(usage.fableResetMin, 6 * 24 * 60)

        var claude = ClaudeStatus()
        claude.fablePct = usage.fablePct
        let root = try XCTUnwrap(JSONSerialization.jsonObject(
            with: Snapshot(claude: claude, codex: CodexStatus(), ts: 1).jsonData()
        ) as? [String: Any])
        let encoded = try XCTUnwrap(root["claude"] as? [String: Any])
        XCTAssertEqual((encoded["fable_pct"] as? NSNumber)?.doubleValue, 5)
        XCTAssertNil(encoded["fable_reset_min"])
    }

    func testClaudeIgnoresUnrelatedScopedWeeklyLimit() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "limits": [[
                "kind": "weekly_scoped", "percent": 33.0,
                "scope": ["model": ["display_name": "Sonnet"]],
            ]],
        ])
        XCTAssertNil(UsageFetcher.parseClaudeUsage(data)?.fablePct)
    }

    func testCodexWeeklyWindowAcceptsCurrentPrimaryShape() {
        let limits: [String: Any] = [
            "primary": [
                "used_percent": 10.0,
                "window_minutes": 10_080,
                "resets_at": 1_782_000_000,
            ],
            "secondary": NSNull(),
        ]
        let weekly = codexWeeklyWindow(from: limits)
        XCTAssertEqual(weekly?.usedPercent, 10)
        XCTAssertEqual(weekly?.windowMinutes, 10_080)
        XCTAssertEqual(weekly?.resetsAt, 1_782_000_000)
    }

    func testCodexWeeklyWindowKeepsLegacySecondaryShape() {
        let limits: [String: Any] = [
            "primary": ["used_percent": 32.0, "window_minutes": 300],
            "secondary": ["used_percent": 68.0, "window_minutes": 10_080],
        ]
        let weekly = codexWeeklyWindow(from: limits)
        XCTAssertEqual(weekly?.usedPercent, 68)
        XCTAssertEqual(weekly?.windowMinutes, 10_080)
    }

    func testCodexWeeklyWindowDoesNotPromoteFiveHourPrimary() {
        let limits: [String: Any] = [
            "primary": ["used_percent": 32.0, "window_minutes": 300],
            "secondary": NSNull(),
        ]
        XCTAssertNil(codexWeeklyWindow(from: limits))
    }

    func testGrokWeeklyCreditsPayload() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "config": [
                "creditUsagePercent": 62.5,
                "billingPeriodEnd": "2026-08-03T00:00:00Z",
                "currentPeriod": ["type": "USAGE_PERIOD_TYPE_WEEKLY"],
            ],
        ])
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-02T00:00:00Z"))
        let usage = try XCTUnwrap(UsageFetcher.parseGrokUsage(data, now: now))
        XCTAssertEqual(usage.weeklyPct, 62.5)
        XCTAssertEqual(usage.weeklyResetMin, 24 * 60)
    }

    func testGrokRejectsNonWeeklyPeriod() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "config": [
                "creditUsagePercent": 10,
                "currentPeriod": ["type": "USAGE_PERIOD_TYPE_DAILY"],
            ],
        ])
        XCTAssertNil(UsageFetcher.parseGrokUsage(data))
    }

    func testKimiFiveHourAndWeeklyPayload() throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "usage": ["limit": "1000", "used": "250", "resetTime": "2026-08-07T00:00:00Z"],
            "limits": [[
                "window": ["duration": 300, "timeUnit": "TIME_UNIT_MINUTE"],
                "detail": ["limit": "100", "remaining": "60", "resetTime": "2026-08-01T05:00:00Z"],
            ]],
        ])
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-01T00:00:00Z"))
        let usage = try XCTUnwrap(UsageFetcher.parseKimiUsage(data, now: now))
        XCTAssertEqual(usage.primaryPct, 40)
        XCTAssertEqual(usage.primaryResetMin, 300)
        XCTAssertEqual(usage.weeklyPct, 25)
    }
}
