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

    func testMarketRefreshIntervalsExposeRequestedCadences() {
        XCTAssertEqual(MarketRefreshInterval.allCases.map(\.seconds), [10, 30, 60, 120])
        XCTAssertEqual(MarketRefreshInterval.allCases.map(\.title), ["10 秒", "30 秒", "60 秒", "120 秒"])
    }

    func testMarketFrameKeepsDeviceWireSize() {
        let instrument = MarketInstrument.parse("600519")!
        let snapshot = MarketSnapshot(instrument: instrument, interval: .fiveMinutes)
        XCTAssertEqual(MarketFrameRenderer.rgb565(snapshot: snapshot).count, 240 * 240 * 2)
    }

    func testPackedMarketFrameRoundTripsAndFitsC3StagingBuffer() throws {
        let instrument = MarketInstrument.parse("600519")!
        let candles = (0..<36).map { index in
            let open = 1_400.0 + Double(index % 7) * 2.5
            let close = open + (index.isMultiple(of: 2) ? 4.0 : -3.0)
            return MarketCandle(time: Double(index * 300), low: min(open, close) - 2,
                                high: max(open, close) + 3, open: open, close: close)
        }
        let snapshot = MarketSnapshot(instrument: instrument, interval: .fiveMinutes,
                                      candles: candles, price: 1_418.5, change24h: 1.27,
                                      source: "Tencent", updatedAt: Date(), stale: false,
                                      marketOpen: true, lineOnly: false)
        let raw = MarketFrameRenderer.rgb565(snapshot: snapshot)
        let envelope = MarketFrameCodec.envelope(packed: MarketFrameCodec.packRGB565(raw),
                                                 version: 0x0102030405060708)

        XCTAssertLessThan(envelope.count, 32 * 1024,
                          "market renderer outgrew the C3's fixed staging buffer")
        let decoded = try XCTUnwrap(Self.decodePackedEnvelope(envelope))
        XCTAssertEqual(decoded.version, 0x0102030405060708)
        XCTAssertEqual(decoded.frame, raw)
    }

    func testPackedMarketFrameRejectsCorruptPayload() {
        let raw = Data(repeating: 0, count: 240 * 240 * 2)
        var envelope = MarketFrameCodec.envelope(packed: MarketFrameCodec.packRGB565(raw), version: 7)
        envelope[envelope.count - 1] ^= 0x01
        XCTAssertNil(Self.decodePackedEnvelope(envelope))
    }

    func testMarketFrameCRCMatchesStandardVector() {
        XCTAssertEqual(MarketFrameCodec.crc32(Data("123456789".utf8)), 0xCBF4_3926)
    }

    func testVersionedFrameEnvelopeAddsOnlyItsHeader() throws {
        let monitor = MarketMonitor()
        XCTAssertEqual(monitor.frameEnvelope.count, 8 + 240 * 240 * 2)
        XCTAssertLessThan(monitor.packedFrameEnvelope.count, 32 * 1024)
        let version = try XCTUnwrap(
            JSONSerialization.jsonObject(with: monitor.frameVersionJSON) as? [String: Any]
        )
        XCTAssertEqual(version["codec"] as? String, "rgb565-packbits-v1")
        XCTAssertEqual((version["packed_bytes"] as? NSNumber)?.intValue,
                       monitor.packedFrameEnvelope.count)
        XCTAssertEqual(version["session"] as? String, "",
                       "the startup WAITING frame must not replace a good frame after app restart")
    }

    private static func decodePackedEnvelope(_ envelope: Data) -> (version: UInt64, frame: Data)? {
        let bytes = [UInt8](envelope)
        guard bytes.count >= MarketFrameCodec.headerBytes,
              Array(bytes[0..<4]) == [0x4D, 0x4B, 0x54, 0x31],
              Int(bytes[12]) << 8 | Int(bytes[13]) == 240,
              Int(bytes[14]) << 8 | Int(bytes[15]) == 240 else { return nil }
        var version: UInt64 = 0
        for byte in bytes[4..<12] { version = (version << 8) | UInt64(byte) }
        let expectedCRC = bytes[16..<20].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let payload = envelope.dropFirst(MarketFrameCodec.headerBytes)
        guard MarketFrameCodec.crc32(Data(payload)) == expectedCRC else { return nil }

        var frame = Data(capacity: 240 * 240 * 2)
        var cursor = MarketFrameCodec.headerBytes
        while cursor < bytes.count {
            let control = bytes[cursor]
            cursor += 1
            let count = Int(control & 0x7F) + 1
            if control & 0x80 != 0 {
                guard cursor + 2 <= bytes.count else { return nil }
                let high = bytes[cursor], low = bytes[cursor + 1]
                cursor += 2
                for _ in 0..<count { frame.append(high); frame.append(low) }
            } else {
                let byteCount = count * 2
                guard cursor + byteCount <= bytes.count else { return nil }
                frame.append(contentsOf: bytes[cursor..<(cursor + byteCount)])
                cursor += byteCount
            }
            guard frame.count <= 240 * 240 * 2 else { return nil }
        }
        return frame.count == 240 * 240 * 2 ? (version, frame) : nil
    }
}
