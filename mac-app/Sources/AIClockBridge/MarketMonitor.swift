import AppKit
import Foundation

enum MarketInterval: String, CaseIterable {
    case oneMinute = "1m"
    case fiveMinutes = "5m"
    case oneHour = "60m"

    var seconds: Int {
        switch self {
        case .oneMinute: return 60
        case .fiveMinutes: return 300
        case .oneHour: return 3600
        }
    }
}

typealias BTCInterval = MarketInterval

enum MarketRegion: String, Codable {
    case crypto, cn, hk, us, kr

    var currency: String {
        switch self {
        case .crypto, .us: return "USD"
        case .cn: return "CNY"
        case .hk: return "HKD"
        case .kr: return "KRW"
        }
    }

    var timeZone: TimeZone {
        switch self {
        case .crypto: return TimeZone(secondsFromGMT: 0)!
        case .cn, .hk: return TimeZone(identifier: "Asia/Shanghai")!
        case .us: return TimeZone(identifier: "America/New_York")!
        case .kr: return TimeZone(identifier: "Asia/Seoul")!
        }
    }
}

struct MarketInstrument: Equatable, Codable {
    let id: String
    let region: MarketRegion
    let providerCode: String
    let symbol: String
    let name: String
    let currency: String
    let isIndex: Bool

    var menuTitle: String { "\(name)  \(symbol)" }

    static let btc = MarketInstrument(id: "btc-usd", region: .crypto, providerCode: "BTC-USD",
                                      symbol: "BTC/USD", name: "BTC", currency: "USD", isIndex: false)
    static let eth = MarketInstrument(id: "eth-usd", region: .crypto, providerCode: "ETH-USD",
                                      symbol: "ETH/USD", name: "ETH", currency: "USD", isIndex: false)
    static let aapl = MarketInstrument(id: "us-AAPL", region: .us, providerCode: "usAAPL",
                                       symbol: "AAPL", name: "Apple", currency: "USD", isIndex: false)
    static let nvda = MarketInstrument(id: "us-NVDA", region: .us, providerCode: "usNVDA",
                                       symbol: "NVDA", name: "NVIDIA", currency: "USD", isIndex: false)
    static let tsla = MarketInstrument(id: "us-TSLA", region: .us, providerCode: "usTSLA",
                                       symbol: "TSLA", name: "Tesla", currency: "USD", isIndex: false)

    static let presets: [MarketInstrument] = [
        btc,
        eth,
        MarketInstrument(id: "cn-sh000001", region: .cn, providerCode: "sh000001", symbol: "000001", name: "上证指数", currency: "CNY", isIndex: true),
        MarketInstrument(id: "cn-sz399001", region: .cn, providerCode: "sz399001", symbol: "399001", name: "深证成指", currency: "CNY", isIndex: true),
        MarketInstrument(id: "cn-sz399006", region: .cn, providerCode: "sz399006", symbol: "399006", name: "创业板指", currency: "CNY", isIndex: true),
        MarketInstrument(id: "cn-sh000300", region: .cn, providerCode: "sh000300", symbol: "000300", name: "沪深300", currency: "CNY", isIndex: true),
        MarketInstrument(id: "hk-HSI", region: .hk, providerCode: "hkHSI", symbol: "HSI", name: "恒生指数", currency: "HKD", isIndex: true),
        MarketInstrument(id: "hk-HSCEI", region: .hk, providerCode: "hkHSCEI", symbol: "HSCEI", name: "国企指数", currency: "HKD", isIndex: true),
        MarketInstrument(id: "hk-HSTECH", region: .hk, providerCode: "hkHSTECH", symbol: "HSTECH", name: "恒生科技", currency: "HKD", isIndex: true),
        MarketInstrument(id: "us-NDX", region: .us, providerCode: "usNDX", symbol: "NDX", name: "纳斯达克100", currency: "USD", isIndex: true),
        MarketInstrument(id: "us-INX", region: .us, providerCode: "usINX", symbol: "SPX", name: "标普500", currency: "USD", isIndex: true),
        MarketInstrument(id: "us-DJI", region: .us, providerCode: "usDJI", symbol: "DJI", name: "道琼斯", currency: "USD", isIndex: true),
        MarketInstrument(id: "us-IXIC", region: .us, providerCode: "usIXIC", symbol: "IXIC", name: "纳斯达克综合", currency: "USD", isIndex: true),
        aapl,
        nvda,
        tsla,
        MarketInstrument(id: "kr-KOSPI", region: .kr, providerCode: "KOSPI", symbol: "KOSPI", name: "韩国综合", currency: "KRW", isIndex: true),
        MarketInstrument(id: "kr-KOSDAQ", region: .kr, providerCode: "KOSDAQ", symbol: "KOSDAQ", name: "韩国科创", currency: "KRW", isIndex: true),
        MarketInstrument(id: "kr-005930", region: .kr, providerCode: "005930", symbol: "005930", name: "三星电子", currency: "KRW", isIndex: false),
    ]

    /// The initial rotation list. It intentionally contains the most useful
    /// cross-market glance set while leaving room for up to 15 user favorites.
    static let defaultFavorites: [MarketInstrument] = [
        btc, eth,
        MarketInstrument(id: "cn-sh000001", region: .cn, providerCode: "sh000001", symbol: "000001", name: "上证指数", currency: "CNY", isIndex: true),
        MarketInstrument(id: "hk-HSI", region: .hk, providerCode: "hkHSI", symbol: "HSI", name: "恒生指数", currency: "HKD", isIndex: true),
        MarketInstrument(id: "hk-HSTECH", region: .hk, providerCode: "hkHSTECH", symbol: "HSTECH", name: "恒生科技", currency: "HKD", isIndex: true),
        MarketInstrument(id: "us-NDX", region: .us, providerCode: "usNDX", symbol: "NDX", name: "纳斯达克100", currency: "USD", isIndex: true),
        MarketInstrument(id: "us-INX", region: .us, providerCode: "usINX", symbol: "SPX", name: "标普500", currency: "USD", isIndex: true),
        aapl, nvda, tsla,
        MarketInstrument(id: "kr-KOSPI", region: .kr, providerCode: "KOSPI", symbol: "KOSPI", name: "韩国综合", currency: "KRW", isIndex: true),
        MarketInstrument(id: "kr-005930", region: .kr, providerCode: "005930", symbol: "005930", name: "三星电子", currency: "KRW", isIndex: false),
    ]

    static func preset(id: String) -> MarketInstrument? {
        presets.first { $0.id == id }
    }

    /// Resolves a code or a small set of stable aliases without requiring an
    /// account. Prefixes remove the ambiguity between a Korean six-digit code
    /// and an A-share code: sh/sz/bj/hk/us/kr.
    static func parse(_ raw: String) -> MarketInstrument? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let dash = trimmed.firstIndex(of: "-") {
            let family = trimmed[..<dash].uppercased()
            let tail = String(trimmed[trimmed.index(after: dash)...])
            switch family {
            case "CN": return parse(tail)
            case "HK": return parse("HK\(tail)")
            case "US": return parse("US\(tail)")
            case "KR": return parse("KR\(tail)")
            default: break
            }
        }
        let value = trimmed
            .replacingOccurrences(of: ":", with: "")
            .uppercased()
        guard !value.isEmpty else { return nil }
        let aliases: [String: String] = [
            "BTC": "btc-usd", "BTCUSD": "btc-usd", "BTC/US": "btc-usd", "BTC-USD": "btc-usd",
            "ETH": "eth-usd", "ETHUSD": "eth-usd", "ETH/US": "eth-usd", "ETH-USD": "eth-usd",
            "上证": "cn-sh000001", "上证指数": "cn-sh000001", "000001.SH": "cn-sh000001",
            "深证": "cn-sz399001", "深证成指": "cn-sz399001", "创业板": "cn-sz399006",
            "沪深300": "cn-sh000300", "恒生": "hk-HSI", "恒生指数": "hk-HSI",
            "恒生科技": "hk-HSTECH", "HSI": "hk-HSI", "HSCEI": "hk-HSCEI", "HSTECH": "hk-HSTECH",
            "SPX": "us-INX", "GSPC": "us-INX", "标普500": "us-INX",
            "NDX": "us-NDX", "纳斯达克100": "us-NDX", "NASDAQ100": "us-NDX",
            "DJI": "us-DJI", "IXIC": "us-IXIC", "KOSPI": "kr-KOSPI", "KOSDAQ": "kr-KOSDAQ",
            "三星": "kr-005930", "三星电子": "kr-005930", "005930": "kr-005930",
            "AAPL": "us-AAPL", "苹果": "us-AAPL", "NVDA": "us-NVDA", "英伟达": "us-NVDA",
            "TSLA": "us-TSLA", "特斯拉": "us-TSLA",
        ]
        if let id = aliases[value], let item = preset(id: id) { return item }

        let prefix = value.prefix(2)
        if ["SH", "SZ", "BJ"].contains(String(prefix)), value.count >= 4 {
            let code = String(value.dropFirst(2))
            let regionCode = String(prefix).lowercased()
            return MarketInstrument(id: "cn-\(regionCode)\(code)", region: .cn,
                                    providerCode: "\(regionCode)\(code)", symbol: code,
                                    name: code, currency: "CNY", isIndex: false)
        }
        if prefix == "HK", value.count >= 5 {
            let code = String(value.dropFirst(2))
            return MarketInstrument(id: "hk-\(code)", region: .hk, providerCode: "hk\(code)",
                                    symbol: code, name: code, currency: "HKD", isIndex: false)
        }
        if prefix == "US", value.count > 2 {
            let code = String(value.dropFirst(2))
            return MarketInstrument(id: "us-\(code)", region: .us, providerCode: "us\(code)",
                                    symbol: code, name: code, currency: "USD", isIndex: false)
        }
        if prefix == "KR", value.count >= 8 {
            let code = String(value.dropFirst(2))
            return MarketInstrument(id: "kr-\(code)", region: .kr, providerCode: code,
                                    symbol: code, name: code, currency: "KRW", isIndex: false)
        }
        if value.count == 5, value.allSatisfy(\.isNumber) {
            return parse("HK\(value)")
        }
        if value.count == 6, value.allSatisfy(\.isNumber) {
            let code = value
            if code.hasPrefix("600") || code.hasPrefix("601") || code.hasPrefix("603") ||
                code.hasPrefix("605") || code.hasPrefix("688") || code.hasPrefix("689") {
                return parse("SH\(code)")
            }
            if code.hasPrefix("000") || code.hasPrefix("001") || code.hasPrefix("002") ||
                code.hasPrefix("003") || code.hasPrefix("300") || code.hasPrefix("301") {
                return parse("SZ\(code)")
            }
        }
        if value.allSatisfy({ $0.isLetter || $0 == "." || $0 == "-" }) {
            let ticker = value.replacingOccurrences(of: "-", with: ".")
            return MarketInstrument(id: "us-\(ticker)", region: .us, providerCode: "us\(ticker)",
                                    symbol: ticker, name: ticker, currency: "USD", isIndex: false)
        }
        return nil
    }
}

struct MarketCandle {
    let time: TimeInterval
    let low: Double
    let high: Double
    let open: Double
    let close: Double
}

typealias BTCCandle = MarketCandle

struct MarketSnapshot {
    var instrument: MarketInstrument = .btc
    var interval: MarketInterval = .fiveMinutes
    var candles: [MarketCandle] = []
    var price = 0.0
    var change24h = 0.0
    var source = ""
    var updatedAt: Date?
    var stale = true
    var marketOpen = false
    var lineOnly = false
}

typealias BTCMarketSnapshot = MarketSnapshot

final class MarketMonitor {
    static let maxFavorites = 15
    private static let favoritesKey = "market_favorite_ids"
    // The development build briefly seeded these 15 entries. Treat that exact
    // list as a generated seed, not as user-curated favorites, so it migrates
    // to the smaller default list with room for custom symbols.
    private static let legacySeedIDs = [
        "btc-usd", "eth-usd", "cn-sh000001", "cn-sz399001", "cn-sh000300",
        "hk-HSI", "hk-HSTECH", "us-NDX", "us-INX", "us-DJI", "us-AAPL",
        "us-NVDA", "us-TSLA", "kr-KOSPI", "kr-005930",
    ]
    private let queue = DispatchQueue(label: "aiclock.market")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var rotationTimer: DispatchSourceTimer?
    private var value = MarketSnapshot()
    // `value` is the complete frame currently safe to show. A rotation only
    // changes the requested instrument; it never replaces this with an empty
    // snapshot while the remote API is still loading.
    private var requestedInstrument = MarketInstrument.btc
    private var requestedInterval: MarketInterval = .fiveMinutes
    private var favoriteItems: [MarketInstrument] = []
    private var rotationIndex = 0
    private var cachedFrame = Data()
    private var cachedFrameKey = ""
    private var snapshotCache: [String: MarketSnapshot] = [:]
    private var frameCache: [String: Data] = [:]
    private var inFlightKeys = Set<String>()
    private var frameVersion: UInt64 = 1

    var snapshot: MarketSnapshot {
        lock.lock(); defer { lock.unlock() }
        var copy = value
        if let at = copy.updatedAt { copy.stale = Date().timeIntervalSince(at) > 120 }
        return copy
    }

    /// The selected item (which may be preloading) rather than the last
    /// completed frame. The HTTP `/btc` and `/btc/frame.raw` routes continue
    /// to expose `snapshot`, i.e. the complete frame that is actually shown.
    var instrument: MarketInstrument {
        lock.lock(); defer { lock.unlock() }
        return requestedInstrument
    }

    var favorites: [MarketInstrument] {
        lock.lock(); defer { lock.unlock() }
        return favoriteItems
    }

    var frameRGB565: Data {
        let current = snapshot
        let key = "\(current.instrument.id)|\(current.interval.rawValue)|\(current.updatedAt?.timeIntervalSince1970 ?? 0)|\(current.stale)|\(current.lineOnly)"
        lock.lock()
        if !cachedFrame.isEmpty, cachedFrameKey == key {
            let frame = cachedFrame
            lock.unlock()
            return frame
        }
        lock.unlock()
        let frame = MarketFrameRenderer.rgb565(snapshot: current)
        lock.lock()
        if value.instrument.id == current.instrument.id, value.interval == current.interval {
            cachedFrame = frame
            cachedFrameKey = key
        }
        lock.unlock()
        return frame
    }

    /// Versioned wire frame for the C3. The eight-byte big-endian version is
    /// deliberately separate from `frameRGB565`, which remains the 115200-byte
    /// local mirror format used by the Mac popover and tests.
    var frameEnvelope: Data {
        lock.lock()
        let current = value
        let key = "\(current.instrument.id)|\(current.interval.rawValue)|\(current.updatedAt?.timeIntervalSince1970 ?? 0)|\(current.stale)|\(current.lineOnly)"
        if !cachedFrame.isEmpty, cachedFrameKey == key {
            let frame = cachedFrame
            let version = frameVersion
            lock.unlock()
            return Self.makeFrameEnvelope(frame: frame, version: version)
        }
        lock.unlock()
        let frame = frameRGB565
        lock.lock()
        let version = frameVersion
        let currentFrame = cachedFrame.isEmpty ? frame : cachedFrame
        lock.unlock()
        return Self.makeFrameEnvelope(frame: currentFrame, version: version)
    }

    private static func makeFrameEnvelope(frame: Data, version: UInt64) -> Data {
        var out = Data(capacity: 8 + frame.count)
        for shift in stride(from: 56, through: 0, by: -8) {
            out.append(UInt8((version >> UInt64(shift)) & 0xff))
        }
        out.append(frame)
        return out
    }

    var frameVersionJSON: Data {
        lock.lock()
        let version = frameVersion
        let s = value
        lock.unlock()
        let object: [String: Any] = [
            "version": NSNumber(value: version),
            "bytes": 240 * 240 * 2,
            "instrument": s.instrument.id,
            "interval": s.interval.rawValue,
        ]
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    init() {
        let savedIDs = UserDefaults.standard.stringArray(forKey: Self.favoritesKey)
        let storedOrDefaultIDs = (savedIDs == nil || savedIDs == Self.legacySeedIDs)
            ? MarketInstrument.defaultFavorites.map(\.id) : savedIDs!
        let loaded = storedOrDefaultIDs
            .compactMap { MarketInstrument.preset(id: $0) ?? MarketInstrument.parse($0) }
        favoriteItems = Array(loaded.prefix(Self.maxFavorites))
        if favoriteItems.isEmpty { favoriteItems = Array(MarketInstrument.defaultFavorites.prefix(Self.maxFavorites)) }
        if let id = UserDefaults.standard.string(forKey: "market_instrument_id"),
           let saved = MarketInstrument.preset(id: id) ?? MarketInstrument.parse(id) {
            value.instrument = saved
        }
        if let raw = UserDefaults.standard.string(forKey: "btc_interval"),
           let saved = MarketInterval(rawValue: raw) {
            value.interval = saved
        }
        requestedInstrument = value.instrument
        requestedInterval = value.interval
        cachedFrame = MarketFrameRenderer.rgb565(snapshot: value)
        cachedFrameKey = "\(value.instrument.id)|\(value.interval.rawValue)|0|true|false"
        let initialKey = cacheKey(value.instrument, interval: value.interval)
        snapshotCache[initialKey] = value
        frameCache[initialKey] = cachedFrame
        if let index = favoriteItems.firstIndex(of: value.instrument) { rotationIndex = index }
    }

    deinit {
        timer?.cancel()
        rotationTimer?.cancel()
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: 20)
        timer.setEventHandler { [weak self] in self?.refresh() }
        timer.resume()
        self.timer = timer

        // Prime the next favorite while the current frame is being fetched.
        queue.async { [weak self] in self?.prefetchNext() }

        let rotation = DispatchSource.makeTimerSource(queue: queue)
        rotation.schedule(deadline: .now() + 10, repeating: 10)
        rotation.setEventHandler { [weak self] in self?.rotateFavorite() }
        rotation.resume()
        rotationTimer = rotation
    }

    func setInterval(_ interval: MarketInterval) {
        lock.lock()
        requestedInterval = interval
        let target = requestedInstrument
        let key = cacheKey(target, interval: interval)
        let cached = snapshotCache[key]
        let cachedFrame = frameCache[key]
        lock.unlock()
        UserDefaults.standard.set(interval.rawValue, forKey: "btc_interval")
        if let cached, let cachedFrame { activate(cached, frame: cachedFrame) }
        request(target, interval: interval)
    }

    func setInstrument(_ instrument: MarketInstrument) {
        lock.lock()
        requestedInstrument = instrument
        let interval = requestedInterval
        let key = cacheKey(instrument, interval: interval)
        let cached = snapshotCache[key]
        let cachedFrame = frameCache[key]
        if let index = favoriteItems.firstIndex(of: instrument) { rotationIndex = index }
        lock.unlock()
        UserDefaults.standard.set(instrument.id, forKey: "market_instrument_id")
        if let cached, let cachedFrame { activate(cached, frame: cachedFrame) }
        request(instrument, interval: interval)
    }

    /// Adds an instrument to the rotation list. Selecting an existing favorite
    /// succeeds; a new item is rejected only once the 15-item cap is reached.
    @discardableResult
    func addFavorite(_ instrument: MarketInstrument) -> Bool {
        lock.lock()
        if let index = favoriteItems.firstIndex(of: instrument) {
            rotationIndex = index
            lock.unlock()
            return true
        }
        guard favoriteItems.count < Self.maxFavorites else {
            lock.unlock()
            return false
        }
        favoriteItems.append(instrument)
        rotationIndex = favoriteItems.count - 1
        let ids = favoriteItems.map(\.id)
        lock.unlock()
        UserDefaults.standard.set(ids, forKey: Self.favoritesKey)
        return true
    }

    func jsonData() -> Data {
        let s = snapshot
        let dict: [String: Any] = [
            "pair": s.instrument.symbol, "market": s.instrument.region.rawValue,
            "name": s.instrument.name, "currency": s.instrument.currency,
            "interval": s.interval.rawValue, "price": s.price,
            "change_24h": s.change24h, "source": s.source, "stale": s.stale,
            "market_open": s.marketOpen, "line_only": s.lineOnly,
            "updated_at": s.updatedAt?.timeIntervalSince1970 ?? 0,
            "candles": s.candles.map { [$0.time, $0.open, $0.high, $0.low, $0.close] },
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }

    private func cacheKey(_ instrument: MarketInstrument, interval: MarketInterval) -> String {
        "\(instrument.id)|\(interval.rawValue)"
    }

    private func nextFrameVersionLocked() -> UInt64 {
        let now = UInt64(max(0, Date().timeIntervalSince1970 * 1000))
        frameVersion = max(now, frameVersion + 1)
        return frameVersion
    }

    /// Atomically swaps only a complete, rendered frame. The old frame stays
    /// visible until this function runs, so a slow API never creates a blank
    /// or half-populated market page.
    private func activate(_ snapshot: MarketSnapshot, frame: Data) {
        lock.lock()
        value = snapshot
        cachedFrame = frame
        cachedFrameKey = "\(snapshot.instrument.id)|\(snapshot.interval.rawValue)|\(snapshot.updatedAt?.timeIntervalSince1970 ?? 0)|\(snapshot.stale)|\(snapshot.lineOnly)"
        _ = nextFrameVersionLocked()
        lock.unlock()
    }

    private func refresh() {
        lock.lock()
        let target = requestedInstrument
        let interval = requestedInterval
        lock.unlock()
        request(target, interval: interval)
    }

    /// Fetches one instrument at a time per cache key. A prefetch request and
    /// a later user/rotation selection share the same in-flight request; when
    /// it completes, the current selection is activated automatically.
    private func request(_ instrument: MarketInstrument, interval: MarketInterval) {
        let key = cacheKey(instrument, interval: interval)
        lock.lock()
        guard !inFlightKeys.contains(key) else {
            lock.unlock()
            return
        }
        inFlightKeys.insert(key)
        let isCurrentTarget = requestedInstrument.id == instrument.id && requestedInterval == interval
        lock.unlock()

        // Start the next request while this one is in flight. For crypto and
        // Korean endpoints this hides most of the WAN latency behind the
        // current screen's dwell time.
        if isCurrentTarget { prefetchNext() }

        fetchMarket(instrument, interval: interval) { [weak self] result in
            self?.queue.async { [weak self] in
                self?.finishRequest(result, instrument: instrument, interval: interval, key: key)
            }
        }
    }

    private func prefetchNext() {
        lock.lock()
        guard favoriteItems.count > 1, !favoriteItems.isEmpty else {
            lock.unlock()
            return
        }
        let nextIndex = (rotationIndex + 1) % favoriteItems.count
        let next = favoriteItems[nextIndex]
        let interval = requestedInterval
        lock.unlock()
        request(next, interval: interval)
    }

    private func finishRequest(_ result: Result<MarketSnapshot, Error>,
                               instrument: MarketInstrument, interval: MarketInterval, key: String) {
        guard case let .success(snapshot) = result else {
            lock.lock(); inFlightKeys.remove(key); lock.unlock()
            return
        }
        let frame = MarketFrameRenderer.rgb565(snapshot: snapshot)
        lock.lock()
        inFlightKeys.remove(key)
        snapshotCache[key] = snapshot
        frameCache[key] = frame
        let shouldActivate = requestedInstrument.id == instrument.id && requestedInterval == interval
        lock.unlock()
        if shouldActivate { activate(snapshot, frame: frame) }
    }

    private func fetchMarket(_ instrument: MarketInstrument, interval: MarketInterval,
                             completion: @escaping (Result<MarketSnapshot, Error>) -> Void) {
        switch instrument.region {
        case .crypto:
            fetchCoinbase(instrument, interval: interval) { [weak self] result in
                switch result {
                case .success:
                    completion(result)
                case .failure:
                    self?.fetchBitstamp(instrument, interval: interval, completion: completion)
                }
            }
        case .kr:
            fetchNaver(instrument, interval: interval, completion: completion)
        case .cn, .hk, .us:
            fetchTencent(instrument, interval: interval, completion: completion)
        }
    }

    private func rotateFavorite() {
        lock.lock()
        guard favoriteItems.count > 1 else { lock.unlock(); return }
        rotationIndex = (rotationIndex + 1) % favoriteItems.count
        let next = favoriteItems[rotationIndex]
        lock.unlock()
        setInstrument(next)
    }

    private func getJSON(_ url: URL, completion: @escaping (Result<Any, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("AIClockBridge/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(.failure(Self.marketError("HTTP 请求失败"))); return
            }
            do { completion(.success(try JSONSerialization.jsonObject(with: data))) }
            catch { completion(.failure(error)) }
        }.resume()
    }

    private func getText(_ url: URL, completion: @escaping (Result<String, Error>) -> Void) {
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("AIClockBridge/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let data, (response as? HTTPURLResponse)?.statusCode == 200 else {
                completion(.failure(Self.marketError("行情请求失败"))); return
            }
            completion(.success(String(decoding: data, as: UTF8.self)))
        }.resume()
    }

    private func fetchTencent(_ instrument: MarketInstrument, interval: MarketInterval,
                              completion: @escaping (Result<MarketSnapshot, Error>) -> Void) {
        let code = instrument.providerCode
        let group = DispatchGroup()
        var quoteText: String?
        var klineObject: Any?
        group.enter()
        getText(URL(string: "https://qt.gtimg.cn/q=\(code)")!) { result in
            if case let .success(text) = result { quoteText = text }
            group.leave()
        }
        group.enter()
        if instrument.region == .us {
            group.leave()
        } else {
            let url: URL
            if instrument.region == .cn {
                url = URL(string: "https://ifzq.gtimg.cn/appstock/app/kline/mkline?param=\(code),\(interval.rawValue),,36")!
            } else {
                url = URL(string: "https://ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(code),\(interval.rawValue),,,36,qfq")!
            }
            getJSON(url) { result in
                if case let .success(object) = result { klineObject = object }
                group.leave()
            }
        }
        group.notify(queue: queue) { [weak self] in
            guard let self, let quoteText, let quote = Self.parseTencentQuote(quoteText) else {
                completion(.failure(Self.marketError("腾讯报价解析失败"))); return
            }
            if instrument.region == .us {
                self.fetchTencentMinute(instrument, interval: interval, quote: quote, completion: completion)
                return
            }
            let candles = Self.parseTencentKlines(klineObject, code: code, key: interval.rawValue,
                                                  timeZone: instrument.region.timeZone)
            if !candles.isEmpty {
                completion(.success(Self.snapshot(instrument: instrument, interval: interval, quote: quote,
                                                   candles: candles, source: "Tencent", lineOnly: false)))
                return
            }
            self.fetchTencentDaily(instrument, interval: interval, quote: quote, completion: completion)
        }
    }

    private func fetchTencentMinute(_ instrument: MarketInstrument, interval: MarketInterval, quote: TencentQuote,
                                    completion: @escaping (Result<MarketSnapshot, Error>) -> Void) {
        let route: String
        switch instrument.region {
        case .us: route = "UsMinute/query"
        case .hk: route = "HkMinute/query"
        case .cn: route = "minute/query"
        default:
            completion(.failure(Self.marketError("分钟线不支持"))); return
        }
        getJSON(URL(string: "https://ifzq.gtimg.cn/appstock/app/\(route)?code=\(instrument.providerCode)")!) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                guard case let .success(object) = result,
                      let rows = Self.tencentMinuteRows(object, code: instrument.providerCode) else {
                    completion(.success(Self.snapshot(instrument: instrument, interval: interval, quote: quote,
                                                       candles: [], source: "Tencent", lineOnly: true)))
                    return
                }
                let candles = Self.lineCandles(rows, interval: interval, timeZone: instrument.region.timeZone)
                completion(.success(Self.snapshot(instrument: instrument, interval: interval, quote: quote,
                                                   candles: candles, source: "Tencent", lineOnly: true)))
            }
        }
    }

    private func fetchTencentDaily(_ instrument: MarketInstrument, interval: MarketInterval, quote: TencentQuote,
                                   completion: @escaping (Result<MarketSnapshot, Error>) -> Void) {
        let url = URL(string: "https://ifzq.gtimg.cn/appstock/app/fqkline/get?param=\(instrument.providerCode),day,,,36,qfq")!
        getJSON(url) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                let dayCandles = Self.parseTencentKlines(result.successValue, code: instrument.providerCode, key: "day",
                                                         timeZone: instrument.region.timeZone)
                let candles = dayCandles.isEmpty
                    ? Self.parseTencentKlines(result.successValue, code: instrument.providerCode, key: "qfqday",
                                              timeZone: instrument.region.timeZone)
                    : dayCandles
                if !candles.isEmpty {
                    completion(.success(Self.snapshot(instrument: instrument, interval: interval, quote: quote,
                                                       candles: candles, source: "Tencent-DAY", lineOnly: false)))
                } else if instrument.region == .cn {
                    self.fetchEastmoney(instrument, interval: interval, quote: quote, completion: completion)
                } else {
                    self.fetchTencentMinute(instrument, interval: interval, quote: quote, completion: completion)
                }
            }
        }
    }

    private func fetchEastmoney(_ instrument: MarketInstrument, interval: MarketInterval, quote: TencentQuote,
                                completion: @escaping (Result<MarketSnapshot, Error>) -> Void) {
        let code = String(instrument.providerCode.dropFirst(2))
        let market = instrument.providerCode.hasPrefix("sh") ? "1" : "0"
        let fields1 = "f1,f2,f3,f4,f5,f6"
        let fields2 = "f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61"
        let urlString = "https://push2his.eastmoney.com/api/qt/stock/kline/get?secid=\(market).\(code)&ut=7eea3edcaed734bea9cbfc24409ed989&fields1=\(fields1)&fields2=\(fields2)&klt=\(interval.seconds == 60 ? 1 : interval.seconds == 300 ? 5 : 60)&fqt=1&beg=0&end=20500101&smplmt=460&lmt=36"
        getJSON(URL(string: urlString)!) { [weak self] result in
            guard let self else { return }
            self.queue.async {
                let candles = Self.parseEastmoney(result.successValue, timeZone: instrument.region.timeZone)
                if candles.isEmpty {
                    self.fetchTencentMinute(instrument, interval: interval, quote: quote, completion: completion)
                } else {
                    completion(.success(Self.snapshot(instrument: instrument, interval: interval, quote: quote,
                                                       candles: candles, source: "Eastmoney", lineOnly: false)))
                }
            }
        }
    }

    private func fetchNaver(_ instrument: MarketInstrument, interval: MarketInterval,
                            completion: @escaping (Result<MarketSnapshot, Error>) -> Void) {
        let isIndex = instrument.providerCode == "KOSPI" || instrument.providerCode == "KOSDAQ"
        let basicPath = isIndex ? "index/\(instrument.providerCode)" : "stock/\(instrument.providerCode)"
        let quoteURL = URL(string: "https://m.stock.naver.com/api/\(basicPath)/basic")!
        let now = Date()
        let start = Self.formatted(now, timeZone: MarketRegion.kr.timeZone, format: "yyyyMMdd") + "090000"
        let end = Self.formatted(now, timeZone: MarketRegion.kr.timeZone, format: "yyyyMMddHHmmss")
        let chartPath = isIndex ? "index/\(instrument.providerCode)" : "item/\(instrument.providerCode)"
        let chartURL = URL(string: "https://api.stock.naver.com/chart/domestic/\(chartPath)/minute?startTime=\(start)&endTime=\(end)")!
        let group = DispatchGroup()
        var quoteObject: Any?
        var chartObject: Any?
        group.enter(); getJSON(quoteURL) { result in
            if case let .success(object) = result { quoteObject = object }; group.leave()
        }
        group.enter(); getJSON(chartURL) { result in
            if case let .success(object) = result { chartObject = object }; group.leave()
        }
        group.notify(queue: queue) {
            let quote = Self.parseNaverQuote(quoteObject, marketOpen: Self.marketOpen(.kr))
            guard let quote else { completion(.failure(Self.marketError("Naver 报价解析失败"))); return }
            let oneMinute = Self.parseNaverCandles(chartObject)
            let candles = Self.aggregate(oneMinute, interval: interval)
            completion(.success(Self.snapshot(instrument: instrument, interval: interval, quote: quote,
                                               candles: candles, source: "Naver", lineOnly: false)))
        }
    }

    private func fetchCoinbase(_ instrument: MarketInstrument, interval: MarketInterval,
                               completion: @escaping (Result<MarketSnapshot, Error>) -> Void) {
        let base = "https://api.exchange.coinbase.com/products/\(instrument.providerCode)"
        let group = DispatchGroup()
        var candleObj: Any?, statsObj: Any?
        group.enter(); getJSON(URL(string: "\(base)/candles?granularity=\(interval.seconds)")!) { r in
            if case let .success(v) = r { candleObj = v }; group.leave()
        }
        group.enter(); getJSON(URL(string: "\(base)/stats")!) { r in
            if case let .success(v) = r { statsObj = v }; group.leave()
        }
        group.notify(queue: queue) {
            guard let rows = candleObj as? [[Any]], let stats = statsObj as? [String: Any] else {
                completion(.failure(Self.marketError("Coinbase 解析失败"))); return
            }
            let candles = rows.compactMap(Self.coinbaseCandle).sorted { $0.time < $1.time }.suffix(36)
            let price = Self.number(stats["last"]) ?? candles.last?.close ?? 0
            let open = Self.number(stats["open"]) ?? price
            let quote = TencentQuote(price: price, previous: open)
            completion(.success(Self.snapshot(instrument: instrument, interval: interval, quote: quote,
                                               candles: Array(candles), source: "Coinbase", lineOnly: false)))
        }
    }

    private func fetchBitstamp(_ instrument: MarketInstrument, interval: MarketInterval,
                               completion: @escaping (Result<MarketSnapshot, Error>) -> Void) {
        let base = "https://www.bitstamp.net/api/v2"
        let pair = instrument.providerCode.replacingOccurrences(of: "-", with: "").lowercased()
        let group = DispatchGroup()
        var ohlcObj: Any?, tickerObj: Any?
        group.enter(); getJSON(URL(string: "\(base)/ohlc/\(pair)/?step=\(interval.seconds)&limit=36")!) { r in
            if case let .success(v) = r { ohlcObj = v }; group.leave()
        }
        group.enter(); getJSON(URL(string: "\(base)/ticker/\(pair)/")!) { r in
            if case let .success(v) = r { tickerObj = v }; group.leave()
        }
        group.notify(queue: queue) {
            let data = (ohlcObj as? [String: Any])?["data"] as? [String: Any]
            guard let rows = data?["ohlc"] as? [[String: Any]], let ticker = tickerObj as? [String: Any] else {
                completion(.failure(Self.marketError("Bitstamp 解析失败"))); return
            }
            let candles = rows.compactMap { row -> MarketCandle? in
                guard let t = Self.number(row["timestamp"]) else { return nil }
                return MarketCandle(time: t, low: Self.number(row["low"]) ?? 0,
                                    high: Self.number(row["high"]) ?? 0,
                                    open: Self.number(row["open"]) ?? 0,
                                    close: Self.number(row["close"]) ?? 0)
            }.sorted { $0.time < $1.time }
            let price = Self.number(ticker["last"]) ?? candles.last?.close ?? 0
            let open = Self.number(ticker["open"]) ?? price
            completion(.success(Self.snapshot(instrument: instrument, interval: interval,
                                               quote: TencentQuote(price: price, previous: open), candles: candles,
                                               source: "Bitstamp", lineOnly: false)))
        }
    }

    private struct TencentQuote {
        let price: Double
        let previous: Double
    }

    private static func snapshot(instrument: MarketInstrument, interval: MarketInterval, quote: TencentQuote,
                                 candles: [MarketCandle], source: String, lineOnly: Bool) -> MarketSnapshot {
        MarketSnapshot(instrument: instrument, interval: interval, candles: Array(candles.suffix(36)),
                       price: quote.price, change24h: quote.previous > 0 ? (quote.price / quote.previous - 1) * 100 : 0,
                       source: source, updatedAt: Date(), stale: false,
                       marketOpen: marketOpen(instrument.region), lineOnly: lineOnly)
    }

    private static func parseTencentQuote(_ text: String) -> TencentQuote? {
        guard let equal = text.firstIndex(of: "=") else { return nil }
        var payload = String(text[text.index(after: equal)...])
        if payload.first == "\"" { payload.removeFirst() }
        if let end = payload.firstIndex(of: "\"") { payload = String(payload[..<end]) }
        let fields = payload.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
        guard fields.count > 4, let price = number(fields[3]), let previous = number(fields[4]), price > 0 else { return nil }
        return TencentQuote(price: price, previous: previous)
    }

    private static func parseTencentKlines(_ object: Any?, code: String, key: String,
                                           timeZone: TimeZone) -> [MarketCandle] {
        guard let root = object as? [String: Any], let data = root["data"] as? [String: Any],
              let item = data[code] as? [String: Any],
              let rows = item[key] as? [[Any]] else { return [] }
        return rows.compactMap { row in
            guard row.count >= 5, let time = parseTime(row[0], timeZone: timeZone),
                  let open = number(row[1]), let close = number(row[2]),
                  let high = number(row[3]), let low = number(row[4]) else { return nil }
            return MarketCandle(time: time, low: low, high: high, open: open, close: close)
        }.sorted { $0.time < $1.time }
    }

    private static func parseEastmoney(_ object: Any?, timeZone: TimeZone) -> [MarketCandle] {
        guard let root = object as? [String: Any], let data = root["data"] as? [String: Any],
              let rows = data["klines"] as? [String] else { return [] }
        return rows.compactMap { row in
            let f = row.split(separator: ",").map(String.init)
            guard f.count >= 5, let time = parseTime(f[0], timeZone: timeZone),
                  let open = number(f[1]), let close = number(f[2]),
                  let high = number(f[3]), let low = number(f[4]) else { return nil }
            return MarketCandle(time: time, low: low, high: high, open: open, close: close)
        }.sorted { $0.time < $1.time }
    }

    private static func tencentMinuteRows(_ object: Any, code: String) -> [(String, Double)]? {
        guard let root = object as? [String: Any], let data = root["data"] as? [String: Any],
              let item = data[code] as? [String: Any], let day = item["data"] as? [String: Any],
              let rows = day["data"] as? [String] else { return nil }
        return rows.compactMap { row in
            let fields = row.split(separator: " ").map(String.init)
            guard fields.count >= 2, let price = number(fields[1]) else { return nil }
            return (fields[0], price)
        }
    }

    private static func lineCandles(_ rows: [(String, Double)], interval: MarketInterval,
                                    timeZone: TimeZone) -> [MarketCandle] {
        let raw = rows.enumerated().compactMap { index, row -> MarketCandle? in
            let time = parseTime(row.0, timeZone: timeZone) ?? Date().timeIntervalSince1970 + Double(index)
            let previous = index > 0 ? rows[index - 1].1 : row.1
            return MarketCandle(time: time, low: min(previous, row.1), high: max(previous, row.1),
                                open: previous, close: row.1)
        }
        return aggregate(raw, interval: interval)
    }

    private static func parseNaverQuote(_ object: Any?, marketOpen: Bool) -> TencentQuote? {
        guard let dict = object as? [String: Any], let price = number(dict["closePrice"]), price > 0 else { return nil }
        let previous = number(dict["compareToPreviousClosePrice"]).map { price - $0 } ?? price
        return TencentQuote(price: price, previous: previous)
    }

    private static func parseNaverCandles(_ object: Any?) -> [MarketCandle] {
        let rows: [[String: Any]]
        if let typed = object as? [[String: Any]] { rows = typed }
        else if let array = object as? [Any] { rows = array.compactMap { $0 as? [String: Any] } }
        else { return [] }
        return rows.compactMap { row in
            guard let rawTime = row["localDateTime"], let time = parseTime(rawTime, timeZone: MarketRegion.kr.timeZone),
                  let close = number(row["currentPrice"]), let open = number(row["openPrice"]),
                  let high = number(row["highPrice"]), let low = number(row["lowPrice"]) else { return nil }
            return MarketCandle(time: time, low: low, high: high, open: open, close: close)
        }.sorted { $0.time < $1.time }
    }

    private static func aggregate(_ candles: [MarketCandle], interval: MarketInterval) -> [MarketCandle] {
        guard interval != .oneMinute else { return Array(candles.suffix(36)) }
        var grouped: [Int: [MarketCandle]] = [:]
        for candle in candles { grouped[Int(candle.time) / interval.seconds, default: []].append(candle) }
        return grouped.keys.sorted().compactMap { key in
            guard let group = grouped[key]?.sorted(by: { $0.time < $1.time }), let first = group.first,
                  let last = group.last else { return nil }
            return MarketCandle(time: first.time, low: group.map(\.low).min() ?? first.low,
                                high: group.map(\.high).max() ?? first.high, open: first.open, close: last.close)
        }.suffix(36).map { $0 }
    }

    private static func coinbaseCandle(_ row: [Any]) -> MarketCandle? {
        guard row.count >= 5 else { return nil }
        let n = row.map { number($0) ?? 0 }
        return MarketCandle(time: n[0], low: n[1], high: n[2], open: n[3], close: n[4])
    }

    private static func parseTime(_ value: Any, timeZone: TimeZone) -> TimeInterval? {
        if let n = value as? NSNumber {
            let v = n.doubleValue
            if v > 100_000_000_000 {
                return parseTime(String(Int64(v)), timeZone: timeZone)
            }
            return v > 10_000_000_000 ? v / 1000 : v
        }
        guard let text = value as? String else { return nil }
        let formats = ["yyyyMMddHHmmss", "yyyyMMddHHmm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm",
                       "yyyy-MM-dd", "yyyy/MM/dd HH:mm:ss", "HHmm"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = timeZone
            formatter.dateFormat = format
            if let date = formatter.date(from: text) {
                if format == "HHmm" {
                    let now = Calendar(identifier: .gregorian).dateComponents(in: timeZone, from: Date())
                    var c = DateComponents(); c.year = now.year; c.month = now.month; c.day = now.day
                    c.hour = Calendar(identifier: .gregorian).dateComponents([.hour], from: date).hour
                    c.minute = Calendar(identifier: .gregorian).dateComponents([.minute], from: date).minute
                    return Calendar(identifier: .gregorian).date(from: c).map { $0.timeIntervalSince1970 }
                }
                return date.timeIntervalSince1970
            }
        }
        return Double(text)
    }

    private static func formatted(_ date: Date, timeZone: TimeZone, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func marketOpen(_ region: MarketRegion, now: Date = Date()) -> Bool {
        if region == .crypto { return true }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = region.timeZone
        let parts = calendar.dateComponents([.weekday, .hour, .minute], from: now)
        guard let weekday = parts.weekday, (2...6).contains(weekday), let hour = parts.hour, let minute = parts.minute else { return false }
        let current = hour * 60 + minute
        switch region {
        case .cn: return (570...690).contains(current) || (780...900).contains(current)
        case .hk: return (570...720).contains(current) || (780...960).contains(current)
        case .us: return (570...960).contains(current)
        case .kr: return (540...930).contains(current)
        case .crypto: return true
        }
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s.replacingOccurrences(of: ",", with: "")) }
        return nil
    }

    private static func marketError(_ message: String) -> NSError {
        NSError(domain: "Market", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private extension Result where Success == Any {
    var successValue: Any? {
        if case let .success(value) = self { return value }
        return nil
    }
}

enum MarketFrameRenderer {
    private static func bitmap(snapshot: MarketSnapshot) -> NSBitmapImageRep {
        let context = CGContext(data: nil, width: 240, height: 240, bitsPerComponent: 8,
                                bytesPerRow: 240 * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.translateBy(x: 240, y: 240); context.scaleBy(x: -1, y: -1)
        context.translateBy(x: 240, y: 0); context.scaleBy(x: -1, y: 1)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        render(snapshot: snapshot, in: CGRect(x: 0, y: 0, width: 240, height: 240))
        NSGraphicsContext.restoreGraphicsState()
        return NSBitmapImageRep(cgImage: context.makeImage()!)
    }

    static func png(snapshot: MarketSnapshot) -> Data? {
        bitmap(snapshot: snapshot).representation(using: .png, properties: [:])
    }

    static func rgb565(snapshot: MarketSnapshot) -> Data {
        let rendered = bitmap(snapshot: snapshot)
        guard let bitmap = rendered.bitmapData else { return Data() }
        var out = Data(capacity: 240 * 240 * 2)
        for y in 0..<240 {
            for x in 0..<240 {
                let i = y * rendered.bytesPerRow + x * 4
                let r = UInt16(bitmap[i]), g = UInt16(bitmap[i + 1]), b = UInt16(bitmap[i + 2])
                let v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
                out.append(UInt8(v >> 8)); out.append(UInt8(v & 0xFF))
            }
        }
        return out
    }

    static func render(snapshot s: MarketSnapshot, in rect: CGRect) {
        NSColor.black.setFill(); rect.fill()
        let titleFont = NSFont.monospacedSystemFont(ofSize: s.instrument.name.count > 8 ? 8 : 10, weight: .semibold)
        let title = "\(s.instrument.name)  \(s.instrument.symbol)  \(s.interval.rawValue)"
        (title as NSString).draw(at: CGPoint(x: 8, y: 8), withAttributes: [.font: titleFont, .foregroundColor: NSColor(white: 0.72, alpha: 1)])
        let price = formatPrice(s.price, currency: s.instrument.currency)
        (price as NSString).draw(at: CGPoint(x: 8, y: 22), withAttributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 23, weight: .bold), .foregroundColor: NSColor.white,
        ])
        let up = s.change24h >= 0
        let move = String(format: "%@%.2f%%", up ? "+" : "", s.change24h)
        (move as NSString).draw(at: CGPoint(x: 158, y: 31), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold), .foregroundColor: movementColor(s.instrument.region, up: up),
        ])
        let chart = CGRect(x: 9, y: 58, width: 222, height: 153)
        NSColor(white: 0.12, alpha: 1).setStroke()
        for q in 0...3 {
            let y = chart.minY + chart.height * CGFloat(q) / 3
            NSBezierPath.strokeLine(from: CGPoint(x: chart.minX, y: y), to: CGPoint(x: chart.maxX, y: y))
        }
        guard !s.candles.isEmpty else {
            let empty = (s.stale ? "WAITING FOR MARKET" : "NO INTRADAY DATA") as NSString
            empty.draw(at: CGPoint(x: 48, y: 130), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
                .foregroundColor: NSColor.darkGray,
            ])
            drawFooter(s, at: 220)
            return
        }
        let low = s.candles.map(\.low).min() ?? 0, high = s.candles.map(\.high).max() ?? 1
        let span = max(high - low, max(abs(high), 1) * 0.0001), step = chart.width / CGFloat(s.candles.count)
        func py(_ v: Double) -> CGFloat { chart.maxY - CGFloat((v - low) / span) * chart.height }
        if s.lineOnly {
            let path = NSBezierPath()
            for (i, c) in s.candles.enumerated() {
                let point = CGPoint(x: chart.minX + step * (CGFloat(i) + 0.5), y: py(c.close))
                if i == 0 { path.move(to: point) } else { path.line(to: point) }
            }
            movementColor(s.instrument.region, up: s.change24h >= 0).setStroke()
            path.lineWidth = 2; path.stroke()
        } else {
            let bodyW = max(2, step * 0.58)
            for (i, c) in s.candles.enumerated() {
                let x = chart.minX + step * (CGFloat(i) + 0.5)
                let color = movementColor(s.instrument.region, up: c.close >= c.open)
                color.setStroke(); NSBezierPath.strokeLine(from: CGPoint(x: x, y: py(c.low)), to: CGPoint(x: x, y: py(c.high)))
                color.setFill()
                let y0 = py(max(c.open, c.close)), y1 = py(min(c.open, c.close))
                CGRect(x: x - bodyW / 2, y: y0, width: bodyW, height: max(2, y1 - y0)).fill()
            }
        }
        drawFooter(s, at: 220)
    }

    private static func drawFooter(_ s: MarketSnapshot, at y: CGFloat) {
        let state = s.stale ? "STALE" : (s.marketOpen ? "LIVE" : "CLOSED")
        let footer = "\(s.source.uppercased())  \(state)"
        (footer as NSString).draw(at: CGPoint(x: 10, y: y), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: s.stale ? NSColor.systemRed : NSColor(white: 0.45, alpha: 1),
        ])
    }

    private static func formatPrice(_ price: Double, currency: String) -> String {
        guard price > 0 else { return "--" }
        switch currency {
        case "USD": return String(format: "$%.2f", price)
        case "KRW": return String(format: "₩%.0f", price)
        case "CNY": return String(format: "¥%.2f", price)
        case "HKD": return String(format: "HK$%.2f", price)
        default: return String(format: "%.2f", price)
        }
    }

    private static func movementColor(_ region: MarketRegion, up: Bool) -> NSColor {
        switch region {
        case .cn, .hk, .kr: return up ? NSColor.systemRed : NSColor.systemGreen
        case .crypto, .us: return up ? NSColor.systemGreen : NSColor.systemRed
        }
    }
}

typealias BTCFrameRenderer = MarketFrameRenderer
