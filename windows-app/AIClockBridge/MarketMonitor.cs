using System.Buffers.Binary;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace AIClockBridge;

enum MarketInterval { OneMinute, FiveMinutes, OneHour }

static class MarketIntervalExtensions
{
    public static string Wire(this MarketInterval value) => value switch
    {
        MarketInterval.OneMinute => "1m", MarketInterval.OneHour => "60m", _ => "5m",
    };
    public static int Seconds(this MarketInterval value) => value switch
    {
        MarketInterval.OneMinute => 60, MarketInterval.OneHour => 3600, _ => 300,
    };
    public static MarketInterval ParseInterval(string value) => value switch
    {
        "1m" => MarketInterval.OneMinute, "60m" => MarketInterval.OneHour,
        _ => MarketInterval.FiveMinutes,
    };
}

enum MarketRegion { Crypto, Cn, Hk, Us, Kr }

sealed record MarketInstrument(string Id, MarketRegion Region, string ProviderCode,
                               string Symbol, string Name, string Currency, bool IsIndex = false)
{
    public string MenuTitle => $"{Name}  {Symbol}";

    public static readonly MarketInstrument Btc = new("btc-usd", MarketRegion.Crypto, "BTC-USD", "BTC/USD", "BTC", "USD");
    public static readonly MarketInstrument Eth = new("eth-usd", MarketRegion.Crypto, "ETH-USD", "ETH/USD", "ETH", "USD");
    public static readonly MarketInstrument Aapl = new("us-AAPL", MarketRegion.Us, "usAAPL", "AAPL", "Apple", "USD");
    public static readonly MarketInstrument Nvda = new("us-NVDA", MarketRegion.Us, "usNVDA", "NVDA", "NVIDIA", "USD");
    public static readonly MarketInstrument Tsla = new("us-TSLA", MarketRegion.Us, "usTSLA", "TSLA", "Tesla", "USD");

    public static readonly MarketInstrument[] Presets =
    {
        Btc, Eth,
        new("cn-sh000001", MarketRegion.Cn, "sh000001", "000001", "上证指数", "CNY", true),
        new("cn-sz399001", MarketRegion.Cn, "sz399001", "399001", "深证成指", "CNY", true),
        new("cn-sz399006", MarketRegion.Cn, "sz399006", "399006", "创业板指", "CNY", true),
        new("cn-sh000300", MarketRegion.Cn, "sh000300", "000300", "沪深300", "CNY", true),
        new("hk-HSI", MarketRegion.Hk, "hkHSI", "HSI", "恒生指数", "HKD", true),
        new("hk-HSCEI", MarketRegion.Hk, "hkHSCEI", "HSCEI", "国企指数", "HKD", true),
        new("hk-HSTECH", MarketRegion.Hk, "hkHSTECH", "HSTECH", "恒生科技", "HKD", true),
        new("us-NDX", MarketRegion.Us, "usNDX", "NDX", "纳斯达克100", "USD", true),
        new("us-INX", MarketRegion.Us, "usINX", "SPX", "标普500", "USD", true),
        new("us-DJI", MarketRegion.Us, "usDJI", "DJI", "道琼斯", "USD", true),
        new("us-IXIC", MarketRegion.Us, "usIXIC", "IXIC", "纳斯达克综合", "USD", true),
        Aapl, Nvda, Tsla,
        new("kr-KOSPI", MarketRegion.Kr, "KOSPI", "KOSPI", "韩国综合", "KRW", true),
        new("kr-KOSDAQ", MarketRegion.Kr, "KOSDAQ", "KOSDAQ", "韩国科创", "KRW", true),
        new("kr-005930", MarketRegion.Kr, "005930", "005930", "三星电子", "KRW"),
    };

    public static readonly MarketInstrument[] DefaultFavorites =
    {
        Btc, Eth, Presets[2], Presets[6], Presets[8], Presets[9], Presets[10],
        Aapl, Nvda, Tsla, Presets[16], Presets[18],
    };

    public static MarketInstrument Parse(string raw)
    {
        var text = (raw ?? "").Trim();
        if (text.Length == 0 || text.Length > 32) return null;
        var exact = Presets.FirstOrDefault(x => x.Id.Equals(text, StringComparison.OrdinalIgnoreCase));
        if (exact != null) return exact;
        var dash = text.IndexOf('-');
        if (dash > 0)
        {
            var family = text[..dash].ToUpperInvariant();
            var tail = text[(dash + 1)..];
            text = family switch { "CN" => tail, "HK" => "HK" + tail, "US" => "US" + tail, "KR" => "KR" + tail, _ => text };
        }
        var value = text.Replace(":", "").ToUpperInvariant();
        if (value.Length == 0) return null;
        var aliases = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["BTC"]="btc-usd", ["BTCUSD"]="btc-usd", ["BTC-USD"]="btc-usd",
            ["ETH"]="eth-usd", ["ETHUSD"]="eth-usd", ["ETH-USD"]="eth-usd",
            ["上证"]="cn-sh000001", ["上证指数"]="cn-sh000001", ["000001.SH"]="cn-sh000001",
            ["深证"]="cn-sz399001", ["深证成指"]="cn-sz399001", ["创业板"]="cn-sz399006",
            ["沪深300"]="cn-sh000300", ["恒生"]="hk-HSI", ["恒生指数"]="hk-HSI",
            ["恒生科技"]="hk-HSTECH", ["HSI"]="hk-HSI", ["HSCEI"]="hk-HSCEI", ["HSTECH"]="hk-HSTECH",
            ["SPX"]="us-INX", ["GSPC"]="us-INX", ["标普500"]="us-INX",
            ["NDX"]="us-NDX", ["纳斯达克100"]="us-NDX", ["NASDAQ100"]="us-NDX",
            ["DJI"]="us-DJI", ["IXIC"]="us-IXIC", ["KOSPI"]="kr-KOSPI", ["KOSDAQ"]="kr-KOSDAQ",
            ["三星"]="kr-005930", ["三星电子"]="kr-005930", ["005930"]="kr-005930",
            ["AAPL"]="us-AAPL", ["苹果"]="us-AAPL", ["NVDA"]="us-NVDA", ["英伟达"]="us-NVDA",
            ["TSLA"]="us-TSLA", ["特斯拉"]="us-TSLA",
        };
        if (aliases.TryGetValue(value, out var id)) return Presets.FirstOrDefault(x => x.Id == id);
        if ((value.StartsWith("SH") || value.StartsWith("SZ") || value.StartsWith("BJ"))
            && value.Length == 8 && value[2..].All(char.IsDigit))
        {
            var prefix = value[..2].ToLowerInvariant(); var code = value[2..];
            return new($"cn-{prefix}{code}", MarketRegion.Cn, prefix + code, code, code, "CNY");
        }
        if (value.StartsWith("HK") && value.Length == 7 && value[2..].All(char.IsDigit))
        { var code = value[2..]; return new($"hk-{code}", MarketRegion.Hk, "hk" + code, code, code, "HKD"); }
        if (value.StartsWith("US") && value.Length > 2
            && value[2..].All(c => c is >= 'A' and <= 'Z' or '.' or '-'))
        { var code = value[2..]; return new($"us-{code}", MarketRegion.Us, "us" + code, code, code, "USD"); }
        if (value.StartsWith("KR") && value.Length == 8 && value[2..].All(char.IsDigit))
        { var code = value[2..]; return new($"kr-{code}", MarketRegion.Kr, code, code, code, "KRW"); }
        if (value.Length == 5 && value.All(char.IsDigit)) return Parse("HK" + value);
        if (value.Length == 6 && value.All(char.IsDigit))
        {
            if (new[] { "600", "601", "603", "605", "688", "689" }.Any(value.StartsWith)) return Parse("SH" + value);
            if (new[] { "000", "001", "002", "003", "300", "301" }.Any(value.StartsWith)) return Parse("SZ" + value);
        }
        if (value.All(c => c is >= 'A' and <= 'Z' or '.' or '-'))
        { var code = value.Replace('-', '.'); return new($"us-{code}", MarketRegion.Us, "us" + code, code, code, "USD"); }
        return null;
    }
}

readonly record struct MarketCandle(double Time, double Low, double High, double Open, double Close);

sealed class MarketSnapshot
{
    public MarketInstrument Instrument = MarketInstrument.Btc;
    public MarketInterval Interval = MarketInterval.FiveMinutes;
    public List<MarketCandle> Candles = new();
    public double Price;
    public double Change24h;
    public string Source = "";
    public DateTime? UpdatedAt;
    public bool Stale = true;
    public bool MarketOpen;
    public bool LineOnly;
    public MarketSnapshot Clone() => new()
    {
        Instrument = Instrument, Interval = Interval, Candles = new(Candles), Price = Price,
        Change24h = Change24h, Source = Source, UpdatedAt = UpdatedAt, Stale = Stale,
        MarketOpen = MarketOpen, LineOnly = LineOnly,
    };
}

static class MarketFrameCodec
{
    public static byte[] PackRgb565(byte[] frame)
    {
        if (frame.Length != 240 * 240 * 2) return Array.Empty<byte>();
        var packed = new List<byte>(frame.Length / 4);
        var pixel = 0;
        bool Equal(int a, int b) => frame[a * 2] == frame[b * 2] && frame[a * 2 + 1] == frame[b * 2 + 1];
        while (pixel < 240 * 240)
        {
            var repeated = 1;
            while (repeated < 128 && pixel + repeated < 240 * 240 && Equal(pixel, pixel + repeated)) repeated++;
            if (repeated >= 2)
            {
                packed.Add((byte)(0x80 | (repeated - 1))); packed.Add(frame[pixel * 2]); packed.Add(frame[pixel * 2 + 1]);
                pixel += repeated; continue;
            }
            var start = pixel++;
            while (pixel - start < 128 && pixel < 240 * 240)
            {
                var next = 1;
                while (next < 128 && pixel + next < 240 * 240 && Equal(pixel, pixel + next)) next++;
                if (next >= 2) break;
                pixel++;
            }
            packed.Add((byte)(pixel - start - 1));
            for (var i = start * 2; i < pixel * 2; i++) packed.Add(frame[i]);
        }
        return packed.ToArray();
    }

    public static byte[] Envelope(byte[] packed, ulong version)
    {
        if (packed.Length == 0) return Array.Empty<byte>();
        var output = new byte[20 + packed.Length];
        "MKT1"u8.CopyTo(output);
        BinaryPrimitives.WriteUInt64BigEndian(output.AsSpan(4), version);
        BinaryPrimitives.WriteUInt16BigEndian(output.AsSpan(12), 240);
        BinaryPrimitives.WriteUInt16BigEndian(output.AsSpan(14), 240);
        BinaryPrimitives.WriteUInt32BigEndian(output.AsSpan(16), Crc32(packed));
        packed.CopyTo(output, 20);
        return output;
    }

    static uint Crc32(byte[] data)
    {
        var crc = uint.MaxValue;
        foreach (var b in data)
        {
            crc ^= b;
            for (var i = 0; i < 8; i++) crc = (crc >> 1) ^ ((crc & 1) == 0 ? 0 : 0xEDB88320);
        }
        return ~crc;
    }
}

sealed class MarketMonitor : IDisposable
{
    public const int MaxFavorites = 15;
    const string FavoritesKey = "market_favorite_ids";
    const string RefreshKey = "market_refresh_interval";
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(8) };
    readonly object _lock = new();
    readonly string _session = Guid.NewGuid().ToString("N");
    readonly Dictionary<string, MarketSnapshot> _snapshots = new();
    readonly Dictionary<string, byte[]> _frames = new();
    readonly Dictionary<string, long> _cacheUsedAt = new();
    readonly HashSet<string> _inFlight = new();
    readonly Dictionary<string, DateTime> _retryAfter = new();
    List<MarketInstrument> _favorites;
    MarketInstrument _requested;
    MarketInterval _interval;
    MarketSnapshot _value = new();
    byte[] _frame;
    byte[] _packed;
    ulong _version = 1;
    int _rotationIndex;
    int _refreshSeconds;
    System.Threading.Timer _timer;

    public MarketMonitor()
    {
        _favorites = LoadFavorites();
        _requested = MarketInstrument.Parse(Settings.Get("market_instrument_id")) ?? MarketInstrument.Btc;
        _interval = MarketIntervalExtensions.ParseInterval(Settings.Get("btc_interval"));
        _refreshSeconds = int.TryParse(Settings.Get(RefreshKey), out var seconds) && new[] { 10, 30, 60, 120 }.Contains(seconds) ? seconds : 10;
        _value.Instrument = _requested; _value.Interval = _interval;
        _frame = MarketFrameRenderer.Rgb565(_value);
        _packed = MarketFrameCodec.Envelope(MarketFrameCodec.PackRgb565(_frame), _version);
        _snapshots[Key(_requested, _interval)] = _value;
        _frames[Key(_requested, _interval)] = _frame;
        _cacheUsedAt[Key(_requested, _interval)] = DateTime.UtcNow.Ticks;
        _rotationIndex = Math.Max(0, _favorites.FindIndex(x => x.Id == _requested.Id));
    }

    public MarketSnapshot Snapshot
    {
        get
        {
            lock (_lock)
            {
                var copy = _value.Clone();
                if (copy.UpdatedAt.HasValue)
                    copy.Stale = DateTime.UtcNow - copy.UpdatedAt.Value > TimeSpan.FromSeconds(Math.Max(120, _refreshSeconds * 2));
                return copy;
            }
        }
    }
    public MarketInstrument Instrument { get { lock (_lock) return _requested; } }
    public MarketInterval Interval { get { lock (_lock) return _interval; } }
    public IReadOnlyList<MarketInstrument> Favorites { get { lock (_lock) return _favorites.ToArray(); } }
    public int RefreshSeconds { get { lock (_lock) return _refreshSeconds; } }
    public byte[] FrameRgb565 { get { lock (_lock) return (byte[])_frame.Clone(); } }
    public byte[] FrameEnvelope
    {
        get
        {
            lock (_lock)
            {
                var output = new byte[8 + _frame.Length];
                BinaryPrimitives.WriteUInt64BigEndian(output, _version);
                _frame.CopyTo(output, 8);
                return output;
            }
        }
    }
    public byte[] PackedFrameEnvelope { get { lock (_lock) return (byte[])_packed.Clone(); } }

    public void Start()
    {
        lock (_lock)
        {
            if (_timer != null) return;
            _timer = new System.Threading.Timer(_ => CadenceTick(), null, TimeSpan.FromSeconds(_refreshSeconds), TimeSpan.FromSeconds(_refreshSeconds));
        }
        Request(_requested, _interval);
    }

    public void SetRefreshInterval(int seconds)
    {
        if (!new[] { 10, 30, 60, 120 }.Contains(seconds)) return;
        lock (_lock)
        {
            _refreshSeconds = seconds;
            _timer?.Change(TimeSpan.FromSeconds(seconds), TimeSpan.FromSeconds(seconds));
        }
        Settings.Set(RefreshKey, seconds.ToString());
        Request(Instrument, _interval);
    }

    public void SetInterval(MarketInterval interval)
    {
        MarketInstrument target; MarketSnapshot cached = null; byte[] frame = null;
        lock (_lock)
        {
            _interval = interval; target = _requested;
            _snapshots.TryGetValue(Key(target, interval), out cached);
            _frames.TryGetValue(Key(target, interval), out frame);
            if (cached != null && frame != null) _cacheUsedAt[Key(target, interval)] = DateTime.UtcNow.Ticks;
        }
        Settings.Set("btc_interval", interval.Wire());
        if (cached != null && frame != null) Activate(cached, frame);
        Request(target, interval);
    }

    public void SetInstrument(MarketInstrument instrument)
    {
        MarketSnapshot cached = null; byte[] frame = null; MarketInterval interval;
        lock (_lock)
        {
            _requested = instrument; interval = _interval;
            var index = _favorites.FindIndex(x => x.Id == instrument.Id);
            if (index >= 0) _rotationIndex = index;
            _snapshots.TryGetValue(Key(instrument, interval), out cached);
            _frames.TryGetValue(Key(instrument, interval), out frame);
            if (cached != null && frame != null) _cacheUsedAt[Key(instrument, interval)] = DateTime.UtcNow.Ticks;
        }
        Settings.Set("market_instrument_id", instrument.Id);
        if (cached != null && frame != null) Activate(cached, frame);
        Request(instrument, interval);
    }

    public bool AddFavorite(MarketInstrument instrument)
    {
        lock (_lock)
        {
            var index = _favorites.FindIndex(x => x.Id == instrument.Id);
            if (index >= 0) { _rotationIndex = index; return true; }
            if (_favorites.Count >= MaxFavorites) return false;
            _favorites.Add(instrument); _rotationIndex = _favorites.Count - 1;
            SaveFavorites(); return true;
        }
    }

    public byte[] JsonData()
    {
        var s = Snapshot;
        return JsonSerializer.SerializeToUtf8Bytes(new
        {
            pair = s.Instrument.Symbol, market = s.Instrument.Region.ToString().ToLowerInvariant(),
            name = s.Instrument.Name, currency = s.Instrument.Currency, interval = s.Interval.Wire(),
            price = s.Price, change_24h = s.Change24h, source = s.Source, stale = s.Stale,
            market_open = s.MarketOpen, line_only = s.LineOnly,
            updated_at = s.UpdatedAt.HasValue ? new DateTimeOffset(s.UpdatedAt.Value).ToUnixTimeSeconds() : 0,
            candles = s.Candles.Select(c => new[] { c.Time, c.Open, c.High, c.Low, c.Close }),
        });
    }

    public byte[] FrameVersionJson
    {
        get
        {
            lock (_lock) return JsonSerializer.SerializeToUtf8Bytes(new
            {
                version = _version, session = _version > 1 ? _session : "", bytes = 240 * 240 * 2,
                packed_bytes = _packed.Length, codec = "rgb565-packbits-v1",
                instrument = _value.Instrument.Id, interval = _value.Interval.Wire(),
            });
        }
    }

    void CadenceTick()
    {
        MarketInstrument next = null; MarketInstrument current; MarketInterval interval;
        lock (_lock)
        {
            interval = _interval; current = _requested;
            for (var offset = 1; offset < _favorites.Count; offset++)
            {
                var index = (_rotationIndex + offset) % _favorites.Count;
                var candidate = _favorites[index]; var key = Key(candidate, interval);
                if (!_snapshots.ContainsKey(key) || !_frames.ContainsKey(key)) continue;
                _rotationIndex = index; next = candidate; break;
            }
        }
        if (next != null) SetInstrument(next);
        else
        {
            // A single favorite still needs quote refreshes; when a successor
            // provider is down, keep the visible frame fresh while warming the
            // next viable favorite instead of freezing both paths.
            Request(current, interval);
            PrefetchNext();
        }
    }

    void Request(MarketInstrument instrument, MarketInterval interval)
    {
        var key = Key(instrument, interval); bool current;
        lock (_lock)
        {
            current = _requested.Id == instrument.Id && _interval == interval;
            if (_inFlight.Contains(key)) { if (current) _ = Task.Run(PrefetchNext); return; }
            if (_retryAfter.TryGetValue(key, out var retry) && retry > DateTime.UtcNow) return;
            _inFlight.Add(key);
        }
        if (current) _ = Task.Run(PrefetchNext);
        _ = Task.Run(async () =>
        {
            var succeeded = false;
            try
            {
                var snapshot = await FetchMarket(instrument, interval);
                var frame = MarketFrameRenderer.Rgb565(snapshot);
                bool activate;
                lock (_lock)
                {
                    _retryAfter.Remove(key); _snapshots[key] = snapshot; _frames[key] = frame;
                    _cacheUsedAt[key] = DateTime.UtcNow.Ticks;
                    TrimCachesLocked();
                    activate = _requested.Id == instrument.Id && _interval == interval;
                }
                if (activate) Activate(snapshot, frame);
                succeeded = true;
            }
            catch (Exception e) { Console.Error.WriteLine($"[market] {instrument.Id}: {e.Message}"); }
            finally
            {
                lock (_lock)
                {
                    _inFlight.Remove(key);
                    if (!succeeded) _retryAfter[key] = DateTime.UtcNow.AddSeconds(30);
                    TrimCachesLocked();
                }
            }
            if (!succeeded) PrefetchNext();
        });
    }

    void PrefetchNext()
    {
        MarketInstrument next = null; MarketInterval interval;
        lock (_lock)
        {
            interval = _interval;
            for (var offset = 1; offset < _favorites.Count; offset++)
            {
                var candidate = _favorites[(_rotationIndex + offset) % _favorites.Count];
                var key = Key(candidate, interval);
                if (_snapshots.ContainsKey(key) && _frames.ContainsKey(key)) break;
                if (_inFlight.Contains(key)) break;
                if (_retryAfter.TryGetValue(key, out var retry) && retry > DateTime.UtcNow) continue;
                next = candidate; break;
            }
        }
        if (next != null) Request(next, interval);
    }

    void Activate(MarketSnapshot snapshot, byte[] frame)
    {
        var packed = MarketFrameCodec.PackRgb565(frame);
        lock (_lock)
        {
            if (_requested.Id != snapshot.Instrument.Id || _interval != snapshot.Interval) return;
            var changed = !_frame.AsSpan().SequenceEqual(frame) || _packed.Length == 0;
            _value = snapshot; _frame = frame;
            if (changed)
            {
                _version = Math.Max((ulong)DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(), _version + 1);
                _packed = MarketFrameCodec.Envelope(packed, _version);
            }
        }
    }

    async Task<MarketSnapshot> FetchMarket(MarketInstrument instrument, MarketInterval interval)
    {
        if (instrument.Region == MarketRegion.Crypto)
        {
            try { return await FetchCoinbase(instrument, interval); }
            catch { return await FetchBitstamp(instrument, interval); }
        }
        if (instrument.Region == MarketRegion.Kr) return await FetchNaver(instrument, interval);
        return await FetchTencent(instrument, interval);
    }

    async Task<MarketSnapshot> FetchTencent(MarketInstrument instrument, MarketInterval interval)
    {
        var quoteTask = GetText($"https://qt.gtimg.cn/q={instrument.ProviderCode}");
        Task<JsonDocument> chartTask = null;
        if (instrument.Region != MarketRegion.Us)
        {
            var url = instrument.Region == MarketRegion.Cn
                ? $"https://ifzq.gtimg.cn/appstock/app/kline/mkline?param={instrument.ProviderCode},{interval.Wire()},,36"
                : $"https://ifzq.gtimg.cn/appstock/app/fqkline/get?param={instrument.ProviderCode},{interval.Wire()},,,36,qfq";
            chartTask = GetJson(url);
        }
        var quote = ParseTencentQuote(await quoteTask) ?? throw new InvalidDataException("腾讯报价解析失败");
        if (instrument.Region == MarketRegion.Us)
            return await FetchTencentMinute(instrument, interval, quote);
        using var chart = chartTask == null ? null : await chartTask;
        var candles = chart == null ? new() : ParseTencentKlines(chart.RootElement, instrument.ProviderCode, interval.Wire(), instrument.Region);
        if (candles.Count > 0) return MakeSnapshot(instrument, interval, quote, candles, "Tencent", false);
        return await FetchTencentDaily(instrument, interval, quote);
    }

    async Task<MarketSnapshot> FetchTencentMinute(MarketInstrument instrument, MarketInterval interval, Quote quote)
    {
        var route = instrument.Region switch { MarketRegion.Us => "UsMinute/query", MarketRegion.Hk => "HkMinute/query", _ => "minute/query" };
        try
        {
            using var doc = await GetJson($"https://ifzq.gtimg.cn/appstock/app/{route}?code={instrument.ProviderCode}");
            var rows = TencentMinuteRows(doc.RootElement, instrument.ProviderCode);
            return MakeSnapshot(instrument, interval, quote, LineCandles(rows, interval, instrument.Region), "Tencent", true);
        }
        catch { return MakeSnapshot(instrument, interval, quote, new(), "Tencent", true); }
    }

    async Task<MarketSnapshot> FetchTencentDaily(MarketInstrument instrument, MarketInterval interval, Quote quote)
    {
        try
        {
            using var doc = await GetJson($"https://ifzq.gtimg.cn/appstock/app/fqkline/get?param={instrument.ProviderCode},day,,,36,qfq");
            var candles = ParseTencentKlines(doc.RootElement, instrument.ProviderCode, "day", instrument.Region);
            if (candles.Count == 0) candles = ParseTencentKlines(doc.RootElement, instrument.ProviderCode, "qfqday", instrument.Region);
            if (candles.Count > 0) return MakeSnapshot(instrument, interval, quote, candles, "Tencent-DAY", false);
        }
        catch { }
        if (instrument.Region == MarketRegion.Cn)
        {
            try
            {
                var code = instrument.ProviderCode[2..]; var market = instrument.ProviderCode.StartsWith("sh") ? "1" : "0";
                var klt = interval == MarketInterval.OneMinute ? 1 : interval == MarketInterval.FiveMinutes ? 5 : 60;
                using var doc = await GetJson($"https://push2his.eastmoney.com/api/qt/stock/kline/get?secid={market}.{code}&ut=7eea3edcaed734bea9cbfc24409ed989&fields1=f1,f2,f3,f4,f5,f6&fields2=f51,f52,f53,f54,f55,f56,f57,f58,f59,f60,f61&klt={klt}&fqt=1&beg=0&end=20500101&smplmt=460&lmt=36");
                var candles = ParseEastmoney(doc.RootElement, instrument.Region);
                if (candles.Count > 0) return MakeSnapshot(instrument, interval, quote, candles, "Eastmoney", false);
            }
            catch { }
        }
        return await FetchTencentMinute(instrument, interval, quote);
    }

    async Task<MarketSnapshot> FetchNaver(MarketInstrument instrument, MarketInterval interval)
    {
        var isIndex = instrument.ProviderCode is "KOSPI" or "KOSDAQ";
        var basic = isIndex ? $"index/{instrument.ProviderCode}" : $"stock/{instrument.ProviderCode}";
        var chart = isIndex ? $"index/{instrument.ProviderCode}" : $"item/{instrument.ProviderCode}";
        var now = TimeZoneInfo.ConvertTimeBySystemTimeZoneId(DateTime.UtcNow, "Korea Standard Time");
        var quoteTask = GetJson($"https://m.stock.naver.com/api/{basic}/basic");
        var chartTask = GetJson($"https://api.stock.naver.com/chart/domestic/{chart}/minute?startTime={now:yyyyMMdd}090000&endTime={now:yyyyMMddHHmmss}");
        using var quoteDoc = await quoteTask; using var chartDoc = await chartTask;
        var price = Number(quoteDoc.RootElement, "closePrice") ?? throw new InvalidDataException("Naver 报价解析失败");
        var delta = Number(quoteDoc.RootElement, "compareToPreviousClosePrice") ?? 0;
        var candles = Aggregate(ParseNaverCandles(chartDoc.RootElement), interval);
        return MakeSnapshot(instrument, interval, new(price, price - delta), candles, "Naver", false);
    }

    async Task<MarketSnapshot> FetchCoinbase(MarketInstrument instrument, MarketInterval interval)
    {
        var baseUrl = $"https://api.exchange.coinbase.com/products/{instrument.ProviderCode}";
        var candlesTask = GetJson($"{baseUrl}/candles?granularity={interval.Seconds()}");
        var statsTask = GetJson($"{baseUrl}/stats");
        using var candlesDoc = await candlesTask; using var statsDoc = await statsTask;
        var candles = candlesDoc.RootElement.EnumerateArray().Select(CoinbaseCandle).Where(x => x.HasValue).Select(x => x.Value).OrderBy(x => x.Time).TakeLast(36).ToList();
        var price = Number(statsDoc.RootElement, "last") ?? candles.LastOrDefault().Close;
        var open = Number(statsDoc.RootElement, "open") ?? price;
        return MakeSnapshot(instrument, interval, new(price, open), candles, "Coinbase", false);
    }

    async Task<MarketSnapshot> FetchBitstamp(MarketInstrument instrument, MarketInterval interval)
    {
        var pair = instrument.ProviderCode.Replace("-", "").ToLowerInvariant();
        var candlesTask = GetJson($"https://www.bitstamp.net/api/v2/ohlc/{pair}/?step={interval.Seconds()}&limit=36");
        var tickerTask = GetJson($"https://www.bitstamp.net/api/v2/ticker/{pair}/");
        using var candlesDoc = await candlesTask; using var tickerDoc = await tickerTask;
        var rows = candlesDoc.RootElement.GetProperty("data").GetProperty("ohlc");
        var candles = rows.EnumerateArray().Select(row => new MarketCandle(
            Number(row, "timestamp") ?? 0, Number(row, "low") ?? 0, Number(row, "high") ?? 0,
            Number(row, "open") ?? 0, Number(row, "close") ?? 0)).OrderBy(x => x.Time).ToList();
        var price = Number(tickerDoc.RootElement, "last") ?? candles.LastOrDefault().Close;
        var open = Number(tickerDoc.RootElement, "open") ?? price;
        return MakeSnapshot(instrument, interval, new(price, open), candles, "Bitstamp", false);
    }

    static MarketSnapshot MakeSnapshot(MarketInstrument i, MarketInterval interval, Quote q,
                                       List<MarketCandle> candles, string source, bool lineOnly)
    {
        if (!double.IsFinite(q.Price) || q.Price <= 0 || !double.IsFinite(q.Previous))
            throw new InvalidDataException("行情报价无效");
        var change = q.Previous > 0 ? (q.Price / q.Previous - 1) * 100 : 0;
        if (!double.IsFinite(change)) throw new InvalidDataException("行情涨跌幅无效");
        return new()
        {
            Instrument = i, Interval = interval,
            Candles = candles.Where(ValidCandle).TakeLast(36).ToList(), Price = q.Price,
            Change24h = change, Source = source,
            UpdatedAt = DateTime.UtcNow, Stale = false, MarketOpen = IsMarketOpen(i.Region), LineOnly = lineOnly,
        };
    }

    static bool ValidCandle(MarketCandle c) => double.IsFinite(c.Time) && double.IsFinite(c.Low)
        && double.IsFinite(c.High) && double.IsFinite(c.Open) && double.IsFinite(c.Close)
        && c.Time > 0 && c.Low > 0 && c.High > 0 && c.Open > 0 && c.Close > 0;

    static async Task<JsonDocument> GetJson(string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        request.Headers.TryAddWithoutValidation("User-Agent", "AIClockBridge/1.0");
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        response.EnsureSuccessStatusCode();
        return JsonDocument.Parse(await ReadLimited(response.Content, 2 * 1024 * 1024, cts.Token));
    }

    static async Task<string> GetText(string url)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
        request.Headers.TryAddWithoutValidation("User-Agent", "AIClockBridge/1.0");
        using var response = await Http.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, cts.Token);
        response.EnsureSuccessStatusCode();
        return Encoding.UTF8.GetString(await ReadLimited(response.Content, 2 * 1024 * 1024, cts.Token));
    }

    static async Task<byte[]> ReadLimited(HttpContent content, int limit, CancellationToken token)
    {
        if (content.Headers.ContentLength > limit) throw new InvalidDataException("行情响应过大");
        await using var stream = await content.ReadAsStreamAsync(token);
        using var output = new MemoryStream(Math.Min(limit, (int)(content.Headers.ContentLength ?? 4096)));
        var buffer = new byte[16 * 1024];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, token);
            if (read == 0) break;
            if (output.Length + read > limit) throw new InvalidDataException("行情响应过大");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    readonly record struct Quote(double Price, double Previous);
    static Quote? ParseTencentQuote(string text)
    {
        var equal = text.IndexOf('='); if (equal < 0) return null;
        var payload = text[(equal + 1)..].Trim(' ', '\"', ';', '\r', '\n');
        var fields = payload.Split('~');
        if (fields.Length <= 4 || !TryNumber(fields[3], out var price) || !TryNumber(fields[4], out var previous) || price <= 0) return null;
        return new(price, previous);
    }

    static List<MarketCandle> ParseTencentKlines(JsonElement root, string code, string key, MarketRegion region)
    {
        try
        {
            var rows = root.GetProperty("data").GetProperty(code).GetProperty(key);
            var result = new List<MarketCandle>();
            foreach (var row in rows.EnumerateArray())
            {
                var values = row.EnumerateArray().ToArray(); if (values.Length < 5) continue;
                if (!ParseTime(values[0], region, out var time)) continue;
                result.Add(new(time, Num(values[4]), Num(values[3]), Num(values[1]), Num(values[2])));
            }
            return result.OrderBy(x => x.Time).ToList();
        }
        catch { return new(); }
    }

    static List<MarketCandle> ParseEastmoney(JsonElement root, MarketRegion region)
    {
        try
        {
            var result = new List<MarketCandle>();
            foreach (var row in root.GetProperty("data").GetProperty("klines").EnumerateArray())
            {
                var f = row.GetString()!.Split(','); if (f.Length < 5 || !ParseTime(f[0], region, out var time)) continue;
                result.Add(new(time, Num(f[4]), Num(f[3]), Num(f[1]), Num(f[2])));
            }
            return result.OrderBy(x => x.Time).ToList();
        }
        catch { return new(); }
    }

    static List<(string Time, double Price)> TencentMinuteRows(JsonElement root, string code)
    {
        try
        {
            var rows = root.GetProperty("data").GetProperty(code).GetProperty("data").GetProperty("data");
            return rows.EnumerateArray().Select(x => x.GetString()!.Split(' ')).Where(x => x.Length >= 2 && TryNumber(x[1], out _)).Select(x => (x[0], Num(x[1]))).ToList();
        }
        catch { return new(); }
    }

    static List<MarketCandle> LineCandles(List<(string Time, double Price)> rows, MarketInterval interval, MarketRegion region)
    {
        var raw = new List<MarketCandle>();
        for (var i = 0; i < rows.Count; i++)
        {
            var time = ParseTime(rows[i].Time, region, out var parsed) ? parsed : DateTimeOffset.UtcNow.ToUnixTimeSeconds() + i;
            var previous = i > 0 ? rows[i - 1].Price : rows[i].Price;
            raw.Add(new(time, Math.Min(previous, rows[i].Price), Math.Max(previous, rows[i].Price), previous, rows[i].Price));
        }
        return Aggregate(raw, interval);
    }

    static List<MarketCandle> ParseNaverCandles(JsonElement root)
    {
        var result = new List<MarketCandle>();
        if (root.ValueKind != JsonValueKind.Array) return result;
        foreach (var row in root.EnumerateArray())
        {
            if (!row.TryGetProperty("localDateTime", out var t) || !ParseTime(t, MarketRegion.Kr, out var time)) continue;
            result.Add(new(time, Number(row, "lowPrice") ?? 0, Number(row, "highPrice") ?? 0,
                Number(row, "openPrice") ?? 0, Number(row, "currentPrice") ?? 0));
        }
        return result.OrderBy(x => x.Time).ToList();
    }

    static List<MarketCandle> Aggregate(List<MarketCandle> candles, MarketInterval interval)
    {
        if (interval == MarketInterval.OneMinute) return candles.TakeLast(36).ToList();
        return candles.GroupBy(c => (long)c.Time / interval.Seconds()).OrderBy(g => g.Key).Select(g =>
        {
            var rows = g.OrderBy(x => x.Time).ToList();
            return new MarketCandle(rows[0].Time, rows.Min(x => x.Low), rows.Max(x => x.High), rows[0].Open, rows[^1].Close);
        }).TakeLast(36).ToList();
    }

    static MarketCandle? CoinbaseCandle(JsonElement row)
    {
        if (row.ValueKind != JsonValueKind.Array || row.GetArrayLength() < 5) return null;
        var n = row.EnumerateArray().Select(Num).ToArray(); return new(n[0], n[1], n[2], n[3], n[4]);
    }

    static bool ParseTime(JsonElement value, MarketRegion region, out double epoch)
    {
        if (value.ValueKind == JsonValueKind.Number)
        {
            epoch = value.GetDouble(); if (!double.IsFinite(epoch)) return false;
            if (epoch > 1e12) epoch /= 1000; return epoch > 0;
        }
        return ParseTime(value.ToString(), region, out epoch);
    }

    static bool ParseTime(string text, MarketRegion region, out double epoch)
    {
        epoch = 0;
        var formats = new[] { "yyyyMMddHHmmss", "yyyyMMddHHmm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd", "yyyy/MM/dd HH:mm:ss", "HHmm" };
        var zone = Zone(region);
        if (text.Length == 4 && DateTime.TryParseExact(text, "HHmm", CultureInfo.InvariantCulture, DateTimeStyles.None, out var hm))
        { var local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, zone); return ToEpoch(new(local.Year, local.Month, local.Day, hm.Hour, hm.Minute, 0), zone, out epoch); }
        if (DateTime.TryParseExact(text, formats, CultureInfo.InvariantCulture, DateTimeStyles.None, out var date))
            return ToEpoch(date, zone, out epoch);
        // Provider calendar stamps such as 202607151230 must be parsed above;
        // only canonical 10/13 digit Unix values reach this fallback.
        if ((text.Length == 10 || text.Length == 13)
            && double.TryParse(text, NumberStyles.None, CultureInfo.InvariantCulture, out var numeric)
            && double.IsFinite(numeric))
        { epoch = text.Length == 13 ? numeric / 1000 : numeric; return epoch > 0; }
        return false;
    }

    static bool ToEpoch(DateTime local, TimeZoneInfo zone, out double epoch)
    { epoch = new DateTimeOffset(TimeZoneInfo.ConvertTimeToUtc(DateTime.SpecifyKind(local, DateTimeKind.Unspecified), zone)).ToUnixTimeSeconds(); return true; }

    static bool IsMarketOpen(MarketRegion region)
    {
        if (region == MarketRegion.Crypto) return true;
        var local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.UtcNow, Zone(region));
        if (local.DayOfWeek is DayOfWeek.Saturday or DayOfWeek.Sunday) return false;
        var minute = local.Hour * 60 + local.Minute;
        return region switch
        {
            MarketRegion.Cn => minute is >= 570 and <= 690 or >= 780 and <= 900,
            MarketRegion.Hk => minute is >= 570 and <= 720 or >= 780 and <= 960,
            MarketRegion.Us => minute is >= 570 and <= 960,
            MarketRegion.Kr => minute is >= 540 and <= 930,
            _ => true,
        };
    }

    static TimeZoneInfo Zone(MarketRegion region)
    {
        var id = region switch { MarketRegion.Us => "Eastern Standard Time", MarketRegion.Kr => "Korea Standard Time", MarketRegion.Crypto => "UTC", _ => "China Standard Time" };
        return TimeZoneInfo.FindSystemTimeZoneById(id);
    }

    static double Num(JsonElement value) => value.ValueKind == JsonValueKind.Number ? value.GetDouble() : Num(value.ToString());
    static double Num(string value) => TryNumber(value, out var n) ? n : 0;
    static bool TryNumber(string value, out double number) =>
        double.TryParse(value?.Replace(",", ""), NumberStyles.Float, CultureInfo.InvariantCulture, out number)
        && double.IsFinite(number);
    static double? Number(JsonElement obj, string key) => obj.TryGetProperty(key, out var value) && TryNumber(value.ToString(), out var n) ? n : null;
    static string Key(MarketInstrument i, MarketInterval interval) => i.Id + "|" + interval.Wire();

    static List<MarketInstrument> LoadFavorites()
    {
        try
        {
            var ids = JsonSerializer.Deserialize<string[]>(Settings.Get(FavoritesKey));
            var loaded = ids?.Select(MarketInstrument.Parse).Where(x => x != null).Take(MaxFavorites).ToList();
            if (loaded?.Count > 0) return loaded;
        }
        catch { }
        return MarketInstrument.DefaultFavorites.Take(MaxFavorites).ToList();
    }

    void TrimCachesLocked()
    {
        var protectedKeys = _favorites.Select(x => Key(x, _interval)).ToHashSet();
        protectedKeys.Add(Key(_requested, _interval));
        while (_frames.Count > MaxFavorites + 4)
        {
            var victim = _cacheUsedAt.Where(x => !protectedKeys.Contains(x.Key))
                .OrderBy(x => x.Value).Select(x => x.Key).FirstOrDefault();
            if (victim == null) break;
            _frames.Remove(victim); _snapshots.Remove(victim); _cacheUsedAt.Remove(victim);
        }
        foreach (var key in _retryAfter.Where(x => x.Value <= DateTime.UtcNow
                     && !_inFlight.Contains(x.Key) && !_frames.ContainsKey(x.Key))
                 .Select(x => x.Key).ToArray())
            _retryAfter.Remove(key);
        while (_retryAfter.Count > 2 * MaxFavorites)
        {
            var victim = _retryAfter.OrderBy(x => x.Value).First().Key;
            if (_inFlight.Contains(victim)) break;
            _retryAfter.Remove(victim);
        }
    }

    void SaveFavorites() => Settings.Set(FavoritesKey, JsonSerializer.Serialize(_favorites.Select(x => x.Id)));
    public void Dispose() => _timer?.Dispose();
}

static class MarketFrameRenderer
{
    public static byte[] Rgb565(MarketSnapshot snapshot)
    {
        using var bitmap = new Bitmap(240, 240, PixelFormat.Format32bppArgb);
        using (var g = Graphics.FromImage(bitmap)) Render(g, snapshot);
        var output = new byte[240 * 240 * 2];
        var data = bitmap.LockBits(new Rectangle(0, 0, 240, 240), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        unsafe
        {
            var p = (byte*)data.Scan0;
            for (var y = 0; y < 240; y++) for (var x = 0; x < 240; x++)
            {
                var pixel = p + y * data.Stride + x * 4;
                ushort v = (ushort)(((pixel[2] & 0xF8) << 8) | ((pixel[1] & 0xFC) << 3) | (pixel[0] >> 3));
                var i = (y * 240 + x) * 2; output[i] = (byte)(v >> 8); output[i + 1] = (byte)v;
            }
        }
        bitmap.UnlockBits(data); return output;
    }

    public static void Render(Graphics g, MarketSnapshot s)
    {
        g.Clear(Color.Black); g.SmoothingMode = SmoothingMode.None;
        using var titleFont = new Font("Microsoft YaHei UI", s.Instrument.Name.Length > 8 ? 8 : 10, FontStyle.Bold, GraphicsUnit.Pixel);
        using var priceFont = new Font("Consolas", 23, FontStyle.Bold, GraphicsUnit.Pixel);
        using var smallFont = new Font("Consolas", 10, FontStyle.Bold, GraphicsUnit.Pixel);
        using var footerFont = new Font("Consolas", 9, FontStyle.Regular, GraphicsUnit.Pixel);
        using var gray = new SolidBrush(Color.FromArgb(184, 184, 184));
        g.DrawString($"{s.Instrument.Name}  {s.Instrument.Symbol}  {s.Interval.Wire()}", titleFont, gray, 8, 8);
        g.DrawString(FormatPrice(s.Price, s.Instrument.Currency), priceFont, Brushes.White, 8, 22);
        var up = s.Change24h >= 0; var moveColor = MovementColor(s.Instrument.Region, up);
        using (var brush = new SolidBrush(moveColor)) g.DrawString($"{(up ? "+" : "")}{s.Change24h:F2}%", smallFont, brush, 158, 31);
        var chart = new RectangleF(9, 58, 222, 153);
        using (var grid = new Pen(Color.FromArgb(31, 31, 31))) for (var q = 0; q <= 3; q++)
        { var y = chart.Top + chart.Height * q / 3; g.DrawLine(grid, chart.Left, y, chart.Right, y); }
        if (s.Candles.Count == 0)
        {
            g.DrawString(s.Stale ? "WAITING FOR MARKET" : "NO INTRADAY DATA", footerFont, Brushes.DimGray, 48, 130);
            DrawFooter(g, s, footerFont); return;
        }
        var low = s.Candles.Min(x => x.Low); var high = s.Candles.Max(x => x.High);
        var span = Math.Max(high - low, Math.Max(Math.Abs(high), 1) * .0001); var step = chart.Width / s.Candles.Count;
        float Py(double v) => chart.Bottom - (float)((v - low) / span) * chart.Height;
        if (s.LineOnly)
        {
            var points = s.Candles.Select((c, i) => new PointF(chart.Left + step * (i + .5f), Py(c.Close))).ToArray();
            using var pen = new Pen(moveColor, 2); if (points.Length >= 2) g.DrawLines(pen, points);
        }
        else
        {
            var bodyWidth = Math.Max(2, step * .58f);
            for (var i = 0; i < s.Candles.Count; i++)
            {
                var c = s.Candles[i]; var x = chart.Left + step * (i + .5f); var color = MovementColor(s.Instrument.Region, c.Close >= c.Open);
                using var pen = new Pen(color); using var brush = new SolidBrush(color);
                g.DrawLine(pen, x, Py(c.Low), x, Py(c.High));
                var y0 = Py(Math.Max(c.Open, c.Close)); var y1 = Py(Math.Min(c.Open, c.Close));
                g.FillRectangle(brush, x - bodyWidth / 2, y0, bodyWidth, Math.Max(2, y1 - y0));
            }
        }
        DrawFooter(g, s, footerFont);
    }

    static void DrawFooter(Graphics g, MarketSnapshot s, Font font)
    {
        var state = s.Stale ? "STALE" : s.MarketOpen ? "LIVE" : "CLOSED";
        using var brush = new SolidBrush(s.Stale ? Color.Red : Color.FromArgb(115, 115, 115));
        g.DrawString($"{s.Source.ToUpperInvariant()}  {state}", font, brush, 10, 220);
    }
    static string FormatPrice(double p, string c) => p <= 0 ? "--" : c switch
    { "USD" => $"${p:F2}", "KRW" => $"₩{p:F0}", "CNY" => $"¥{p:F2}", "HKD" => $"HK${p:F2}", _ => $"{p:F2}" };
    static Color MovementColor(MarketRegion r, bool up) => r is MarketRegion.Cn or MarketRegion.Hk or MarketRegion.Kr
        ? up ? Color.Red : Color.Lime : up ? Color.Lime : Color.Red;
}
