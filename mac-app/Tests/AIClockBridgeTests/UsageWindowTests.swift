import XCTest
@testable import AIClockBridge

final class UsageWindowTests: XCTestCase {
    func testUsageDayStartsAtLocal0001() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Shanghai"))
        let date = try XCTUnwrap(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 7, day: 14, hour: 18, minute: 30
        )))
        let start = StatusService.usageWindowStart(for: date, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        XCTAssertEqual(parts.year, 2026)
        XCTAssertEqual(parts.month, 7)
        XCTAssertEqual(parts.day, 14)
        XCTAssertEqual(parts.hour, 0)
        XCTAssertEqual(parts.minute, 1)
    }

    func testBTCFrameHasExactDeviceWireSize() {
        let frame = BTCFrameRenderer.rgb565(snapshot: BTCMarketSnapshot())
        XCTAssertEqual(frame.count, 240 * 240 * 2)
    }
}
