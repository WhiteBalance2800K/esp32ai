import XCTest
@testable import AIClockBridge

final class MarketMonitorTests: XCTestCase {
    func testCommonMarketSymbolsResolve() {
        XCTAssertEqual(MarketInstrument.parse("600519")?.providerCode, "sh600519")
        XCTAssertEqual(MarketInstrument.parse("hk00700")?.providerCode, "hk00700")
        XCTAssertEqual(MarketInstrument.parse("AAPL")?.providerCode, "usAAPL")
        XCTAssertEqual(MarketInstrument.parse("BRK.B")?.providerCode, "usBRK.B")
        XCTAssertEqual(MarketInstrument.parse("kr005930")?.providerCode, "005930")
        XCTAssertEqual(MarketInstrument.parse("SPX")?.id, "us-INX")
        XCTAssertEqual(MarketInstrument.parse("cn-sh600519")?.providerCode, "sh600519")
        XCTAssertEqual(MarketInstrument.parse("hk-00700")?.providerCode, "hk00700")
        XCTAssertEqual(MarketInstrument.parse("ETH")?.id, "eth-usd")
        XCTAssertEqual(MarketInstrument.parse("NVDA")?.id, "us-NVDA")
    }

    func testDefaultFavoritesAreNamedAndCapped() {
        XCTAssertEqual(MarketInstrument.defaultFavorites.count, 12)
        XCTAssertLessThanOrEqual(MarketInstrument.defaultFavorites.count, MarketMonitor.maxFavorites)
        XCTAssertTrue(MarketInstrument.defaultFavorites.contains { $0.name == "上证指数" && $0.symbol == "000001" })
        XCTAssertTrue(MarketInstrument.defaultFavorites.contains { $0.name == "纳斯达克100" && $0.symbol == "NDX" })
        XCTAssertTrue(MarketInstrument.defaultFavorites.contains { $0.name == "Apple" && $0.symbol == "AAPL" })
        XCTAssertTrue(MarketInstrument.defaultFavorites.contains { $0.name == "ETH" && $0.symbol == "ETH/USD" })
    }

    func testMarketFrameKeepsDeviceWireSize() {
        let instrument = MarketInstrument.parse("600519")!
        let snapshot = MarketSnapshot(instrument: instrument, interval: .fiveMinutes)
        XCTAssertEqual(MarketFrameRenderer.rgb565(snapshot: snapshot).count, 240 * 240 * 2)
    }

    func testVersionedFrameEnvelopeAddsOnlyItsHeader() {
        let monitor = MarketMonitor()
        XCTAssertEqual(monitor.frameEnvelope.count, 8 + 240 * 240 * 2)
        XCTAssertGreaterThan(monitor.frameVersionJSON.count, 0)
    }
}
