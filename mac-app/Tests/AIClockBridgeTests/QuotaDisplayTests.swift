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
}
