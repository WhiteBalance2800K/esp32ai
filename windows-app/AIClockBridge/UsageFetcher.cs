using System.Text;
using System.Text.Json;

namespace AIClockBridge;

// Real quota ("额度") for local AI CLIs, fetched by reusing the OAuth tokens the
// CLIs already store locally, no extra login. On Windows both live in files
// (no Keychain):
//   Claude: %USERPROFILE%\.claude\.credentials.json, then GET
//           https://api.anthropic.com/api/oauth/usage  (5h + 7d windows)
//   Codex:  %USERPROFILE%\.codex\auth.json, then GET
//           https://chatgpt.com/backend-api/wham/usage (the app shows weekly only)
//   Grok:   %USERPROFILE%\.grok\auth.json (fallback: Pi xAI auth)
//   Kimi:   fresh Kimi Code CLI credentials, then Credential Manager API key
// Tokens never leave this machine except toward their own vendor's API.

class ProviderUsage
{
    public double? PrimaryPct;     // 5h window used %
    public int? PrimaryResetMin;   // minutes until it resets
    public double? WeeklyPct;      // 7d / weekly window used %
    public int? WeeklyResetMin;
    public string Error;
    public DateTime? FetchedAt;
    public bool RateLimited;
}

sealed class UsageFetcher
{
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(20) };

    readonly object _lock = new();
    ProviderUsage _claude = new();
    ProviderUsage _codex = new();
    ProviderUsage _grok = new();
    ProviderUsage _kimi = new();
    System.Windows.Forms.Timer _timer;
    bool _fetching;
    DateTime _nextAllowedFetch = DateTime.MinValue; // throttle + 429 backoff

    static readonly TimeSpan MinFetchInterval = TimeSpan.FromSeconds(60);
    static readonly TimeSpan RateLimitBackoff = TimeSpan.FromSeconds(300);

    public ProviderUsage Claude { get { lock (_lock) return _claude; } }
    public ProviderUsage Codex { get { lock (_lock) return _codex; } }
    public ProviderUsage Grok { get { lock (_lock) return _grok; } }
    public ProviderUsage Kimi { get { lock (_lock) return _kimi; } }

    /// Raised on the UI thread after either provider updates.
    public Action OnUpdate;

    System.Threading.SynchronizationContext _ui;

    public void StartAutoRefresh(int intervalSeconds = 120)
    {
        _ui = System.Threading.SynchronizationContext.Current;
        Refresh();
        _timer = new System.Windows.Forms.Timer { Interval = intervalSeconds * 1000 };
        _timer.Tick += (_, _) => Refresh();
        _timer.Start();
    }

    public void Refresh()
    {
        lock (_lock)
        {
            if (_fetching || DateTime.UtcNow < _nextAllowedFetch) return;
            _fetching = true;
        }

        Task.Run(async () =>
        {
            var claudeTask = FetchClaude();
            var codexTask = FetchCodex();
            var grokTask = FetchGrok();
            var kimiTask = FetchKimi();
            await Task.WhenAll(claudeTask, codexTask, grokTask, kimiTask);
            var claude = claudeTask.Result;
            var codex = codexTask.Result;
            var grok = grokTask.Result;
            var kimi = kimiTask.Result;
            lock (_lock)
            {
                // Keep the last good numbers when a refresh only produced an
                // error (network hiccup / 429) - stale quota beats no quota.
                _claude = Merge(_claude, claude);
                _codex = Merge(_codex, codex);
                _grok = Merge(_grok, grok);
                _kimi = Merge(_kimi, kimi);
                _fetching = false;
                var backoff = new[] { claude, codex, grok, kimi }.Any(x => x.RateLimited)
                    ? RateLimitBackoff : MinFetchInterval;
                _nextAllowedFetch = DateTime.UtcNow + backoff;
            }
            if (claude.Error != null) Console.Error.WriteLine($"[usage] claude: {claude.Error}");
            if (codex.Error != null) Console.Error.WriteLine($"[usage] codex: {codex.Error}");
            if (grok.Error != null) Console.Error.WriteLine($"[usage] grok: {grok.Error}");
            if (kimi.Error != null) Console.Error.WriteLine($"[usage] kimi: {kimi.Error}");
            if (_ui != null) _ui.Post(_ => OnUpdate?.Invoke(), null);
            else OnUpdate?.Invoke();
        });
    }

    static ProviderUsage Merge(ProviderUsage old, ProviderUsage fresh)
    {
        if (fresh.PrimaryPct == null && fresh.WeeklyPct == null
            && (old.PrimaryPct != null || old.WeeklyPct != null))
        {
            return new ProviderUsage
            {
                PrimaryPct = old.PrimaryPct,
                PrimaryResetMin = old.PrimaryResetMin,
                WeeklyPct = old.WeeklyPct,
                WeeklyResetMin = old.WeeklyResetMin,
                FetchedAt = old.FetchedAt,
                Error = fresh.Error,
            };
        }
        return fresh;
    }

    // MARK: - Claude (api.anthropic.com/api/oauth/usage)

    static async Task<ProviderUsage> FetchClaude()
    {
        var usage = new ProviderUsage();
        var token = ClaudeAccessToken();
        if (token == null)
        {
            usage.Error = "未找到 Claude Code 登录凭据（~/.claude/.credentials.json）";
            return usage;
        }
        using var req = new HttpRequestMessage(HttpMethod.Get,
            "https://api.anthropic.com/api/oauth/usage");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        req.Headers.TryAddWithoutValidation("anthropic-beta", "oauth-2025-04-20");
        req.Headers.TryAddWithoutValidation("User-Agent", "claude-code/2.1.0");

        string body;
        int code;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            code = (int)resp.StatusCode;
            body = Encoding.UTF8.GetString(await ReadLimited(resp.Content, 512 * 1024, cts.Token));
        }
        catch
        {
            usage.Error = "Claude 用量请求失败";
            return usage;
        }
        if (code != 200)
        {
            usage.RateLimited = code == 429;
            usage.Error = code == 401 ? "Claude 凭据过期，运行 claude 重新登录"
                : code == 429 ? "Claude 用量接口限流，稍后自动重试"
                : $"Claude 用量接口 HTTP {code}";
            return usage;
        }
        try
        {
            using var doc = JsonDocument.Parse(body);
            var now = DateTimeOffset.UtcNow;
            if (doc.RootElement.TryGetProperty("five_hour", out var fiveHour))
            {
                usage.PrimaryPct = NumberOrNull(fiveHour, "utilization");
                usage.PrimaryResetMin = MinutesUntil(StringOrNull(fiveHour, "resets_at"), now);
            }
            if (doc.RootElement.TryGetProperty("seven_day", out var sevenDay))
            {
                usage.WeeklyPct = NumberOrNull(sevenDay, "utilization");
                usage.WeeklyResetMin = MinutesUntil(StringOrNull(sevenDay, "resets_at"), now);
            }
            usage.FetchedAt = DateTime.UtcNow;
        }
        catch
        {
            usage.Error = "Claude 用量响应解析失败";
        }
        return usage;
    }

    /// Claude Code on Windows stores OAuth credentials as a plain JSON file:
    /// {"claudeAiOauth":{"accessToken":…}}
    static string ClaudeAccessToken()
    {
        var credFile = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".claude", ".credentials.json");
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(credFile));
            if (doc.RootElement.TryGetProperty("claudeAiOauth", out var oauth)
                && oauth.TryGetProperty("accessToken", out var token)
                && token.ValueKind == JsonValueKind.String)
            {
                var t = token.GetString();
                return string.IsNullOrEmpty(t) ? null : t;
            }
        }
        catch
        {
            // missing / unreadable
        }
        return null;
    }

    // MARK: - Codex (chatgpt.com/backend-api/wham/usage)

    static async Task<ProviderUsage> FetchCodex()
    {
        var usage = new ProviderUsage();
        var creds = CodexCredentials();
        if (creds == null)
        {
            usage.Error = "未找到 Codex 登录凭据 (~/.codex/auth.json)";
            return usage;
        }
        using var req = new HttpRequestMessage(HttpMethod.Get,
            "https://chatgpt.com/backend-api/wham/usage");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {creds.Value.AccessToken}");
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        req.Headers.TryAddWithoutValidation("User-Agent", "AIClockBridge");
        if (creds.Value.AccountId != null)
            req.Headers.TryAddWithoutValidation("ChatGPT-Account-Id", creds.Value.AccountId);

        string body;
        int code;
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            code = (int)resp.StatusCode;
            body = Encoding.UTF8.GetString(await ReadLimited(resp.Content, 512 * 1024, cts.Token));
        }
        catch
        {
            usage.Error = "Codex 用量请求失败";
            return usage;
        }
        if (code < 200 || code > 299)
        {
            usage.Error = code == 401 || code == 403
                ? "Codex 凭据过期，运行 codex 重新登录" : $"Codex 用量接口 HTTP {code}";
            return usage;
        }
        try
        {
            using var doc = JsonDocument.Parse(body);
            if (!doc.RootElement.TryGetProperty("rate_limit", out var rateLimit))
            {
                usage.Error = "Codex 用量响应解析失败";
                return usage;
            }
            var now = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;
            var weekly = CodexWeeklyWindow(rateLimit);
            if (weekly.HasValue)
            {
                usage.WeeklyPct = NumberOrNull(weekly.Value, "used_percent");
                var reset = NumberOrNull(weekly.Value, "reset_at")
                    ?? NumberOrNull(weekly.Value, "resets_at");
                if (reset.HasValue) usage.WeeklyResetMin = Math.Max(0, (int)((reset.Value - now) / 60));
            }
            usage.FetchedAt = DateTime.UtcNow;
        }
        catch
        {
            usage.Error = "Codex 用量响应解析失败";
        }
        return usage;
    }

    static (string AccessToken, string AccountId)? CodexCredentials()
    {
        var path = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "auth.json");
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(path));
            if (!doc.RootElement.TryGetProperty("tokens", out var tokens)
                || !tokens.TryGetProperty("access_token", out var accessEl)
                || accessEl.ValueKind != JsonValueKind.String) return null;
            var access = accessEl.GetString();
            if (string.IsNullOrEmpty(access)) return null;
            string accountId = null;
            if (tokens.TryGetProperty("account_id", out var acc) && acc.ValueKind == JsonValueKind.String)
                accountId = acc.GetString();
            if (accountId == null && tokens.TryGetProperty("id_token", out var idTok)
                && idTok.ValueKind == JsonValueKind.String)
                accountId = AccountIdFromJwt(idTok.GetString());
            return (access, accountId);
        }
        catch
        {
            return null;
        }
    }

    static JsonElement? CodexWeeklyWindow(JsonElement limits)
    {
        var parsed = new List<(string Name, JsonElement Value, int? Minutes)>();
        foreach (var name in new[] { "primary", "secondary", "primary_window", "secondary_window" })
        {
            if (!limits.TryGetProperty(name, out var value)
                || !NumberOrNull(value, "used_percent").HasValue) continue;
            parsed.Add((name, value, (int?)NumberOrNull(value, "window_minutes")));
        }
        var exact = parsed.FirstOrDefault(x => x.Minutes == 7 * 24 * 60);
        if (exact.Value.ValueKind != JsonValueKind.Undefined) return exact.Value;
        var secondary = parsed.FirstOrDefault(x => x.Name is "secondary" or "secondary_window");
        if (secondary.Value.ValueKind != JsonValueKind.Undefined) return secondary.Value;
        return parsed.Count == 1 && parsed[0].Minutes == null ? parsed[0].Value : null;
    }

    /// auth.json without a top-level account_id keeps it inside the id_token
    /// JWT claims (https://api.openai.com/auth -> chatgpt_account_id).
    static string AccountIdFromJwt(string jwt)
    {
        var parts = jwt.Split('.');
        if (parts.Length < 2) return null;
        var b64 = parts[1].Replace('-', '+').Replace('_', '/');
        while (b64.Length % 4 != 0) b64 += "=";
        try
        {
            using var doc = JsonDocument.Parse(Convert.FromBase64String(b64));
            if (doc.RootElement.TryGetProperty("https://api.openai.com/auth", out var auth)
                && auth.TryGetProperty("chatgpt_account_id", out var id)
                && id.ValueKind == JsonValueKind.String)
                return id.GetString();
        }
        catch
        {
            // malformed JWT
        }
        return null;
    }

    // MARK: - Grok Build (cli-chat-proxy.grok.com)

    static async Task<ProviderUsage> FetchGrok()
    {
        var usage = new ProviderUsage();
        var token = GrokAccessToken();
        if (token == null)
        {
            usage.Error = "未找到 Grok/Pi 登录凭据，请运行 grok login 或在 Pi 登录 xAI";
            return usage;
        }
        using var req = new HttpRequestMessage(HttpMethod.Get,
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {token}");
        req.Headers.TryAddWithoutValidation("x-xai-token-auth", "xai-grok-cli");
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        req.Headers.TryAddWithoutValidation("User-Agent", "AIClockBridge");
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            var code = (int)resp.StatusCode;
            var data = await ReadLimited(resp.Content, 512 * 1024, cts.Token);
            if (code != 200)
            {
                usage.RateLimited = code == 429;
                usage.Error = code is 401 or 403 ? "Grok 凭据过期，请重新登录 Grok/Pi"
                    : code == 429 ? "Grok 用量接口限流，稍后自动重试"
                    : $"Grok 用量接口 HTTP {code}";
                return usage;
            }
            return ParseGrokUsage(data) ?? new ProviderUsage { Error = "Grok 周额度响应解析失败" };
        }
        catch
        {
            usage.Error = "Grok 用量请求失败";
            return usage;
        }
    }

    internal static ProviderUsage ParseGrokUsage(byte[] data, DateTimeOffset? now = null)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            if (!doc.RootElement.TryGetProperty("config", out var config)) return null;
            var pct = NumberOrNull(config, "creditUsagePercent");
            if (!pct.HasValue) return null;
            if (config.TryGetProperty("currentPeriod", out var period)
                && StringOrNull(period, "type") is string type
                && type != "USAGE_PERIOD_TYPE_WEEKLY") return null;
            return new ProviderUsage
            {
                WeeklyPct = pct,
                WeeklyResetMin = MinutesUntilValue(config, "billingPeriodEnd",
                    now ?? DateTimeOffset.UtcNow),
                FetchedAt = DateTime.UtcNow,
            };
        }
        catch { return null; }
    }

    static string GrokAccessToken()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(home, ".grok", "auth.json")));
            var entries = doc.RootElement.EnumerateObject()
                .OrderByDescending(x => x.Name.StartsWith("https://auth.x.ai::")).ToArray();
            foreach (var entry in entries)
            {
                if (entry.Value.ValueKind != JsonValueKind.Object) continue;
                var token = StringOrNull(entry.Value, "key");
                if (!string.IsNullOrEmpty(token) && !IsExpired(entry.Value, "expires_at")) return token;
            }
        }
        catch { }
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(Path.Combine(home, ".pi", "agent", "auth.json")));
            if (doc.RootElement.TryGetProperty("xai", out var xai))
            {
                var token = StringOrNull(xai, "access");
                if (!string.IsNullOrEmpty(token) && !IsExpired(xai, "expires")) return token;
            }
        }
        catch { }
        return null;
    }

    // MARK: - Kimi Code (api.kimi.com/coding/v1/usages)

    static async Task<ProviderUsage> FetchKimi()
    {
        var credential = KimiCredential();
        if (credential == null)
            return new ProviderUsage { Error = "未找到 Kimi Code 登录凭据或 API Key" };
        using var req = new HttpRequestMessage(HttpMethod.Get,
            "https://api.kimi.com/coding/v1/usages");
        req.Headers.TryAddWithoutValidation("Authorization", $"Bearer {credential.Value.Token}");
        req.Headers.TryAddWithoutValidation("Accept", "application/json");
        req.Headers.TryAddWithoutValidation("User-Agent", "AIClockBridge");
        req.Headers.TryAddWithoutValidation("X-Msh-Platform", "kimi_code_cli");
        req.Headers.TryAddWithoutValidation("X-Msh-Version", "AIClockBridge");
        req.Headers.TryAddWithoutValidation("X-Msh-Device-Name", AsciiHeader(Environment.MachineName));
        req.Headers.TryAddWithoutValidation("X-Msh-Device-Model", "Windows");
        req.Headers.TryAddWithoutValidation("X-Msh-Os-Version",
            AsciiHeader(Environment.OSVersion.VersionString));
        req.Headers.TryAddWithoutValidation("X-Msh-Device-Id", KimiDeviceId());
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(20));
            using var resp = await Http.SendAsync(req, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            var code = (int)resp.StatusCode;
            var data = await ReadLimited(resp.Content, 512 * 1024, cts.Token);
            if (code != 200)
            {
                return new ProviderUsage
                {
                    RateLimited = code == 429,
                    Error = code is 401 or 403 ? "Kimi Code 凭据无效或过期"
                        : code == 429 ? "Kimi Code 用量接口限流，稍后自动重试"
                        : $"Kimi Code 用量接口 HTTP {code}",
                };
            }
            return ParseKimiUsage(data) ?? new ProviderUsage { Error = "Kimi Code 用量响应解析失败" };
        }
        catch
        {
            return new ProviderUsage { Error = "Kimi Code 用量请求失败" };
        }
    }

    internal static ProviderUsage ParseKimiUsage(byte[] data, DateTimeOffset? now = null)
    {
        try
        {
            using var doc = JsonDocument.Parse(data);
            var root = doc.RootElement;
            if (!root.TryGetProperty("usage", out var weekly)) return null;
            var weeklyPct = DetailPercent(weekly);
            if (!weeklyPct.HasValue) return null;
            var current = now ?? DateTimeOffset.UtcNow;
            var usage = new ProviderUsage
            {
                WeeklyPct = weeklyPct,
                WeeklyResetMin = MinutesUntilAnyReset(weekly, current),
                FetchedAt = DateTime.UtcNow,
            };
            if (root.TryGetProperty("limits", out var limits) && limits.ValueKind == JsonValueKind.Array)
            {
                foreach (var limit in limits.EnumerateArray())
                {
                    if (!limit.TryGetProperty("window", out var window)) continue;
                    var duration = NumberOrNull(window, "duration");
                    var unit = StringOrNull(window, "timeUnit");
                    if (!((unit == "TIME_UNIT_MINUTE" && duration == 300)
                          || (unit == "TIME_UNIT_HOUR" && duration == 5))) continue;
                    if (limit.TryGetProperty("detail", out var detail))
                    {
                        usage.PrimaryPct = DetailPercent(detail);
                        usage.PrimaryResetMin = MinutesUntilAnyReset(detail, current);
                    }
                    break;
                }
            }
            return usage;
        }
        catch { return null; }
    }

    static (string Token, bool IsCli)? KimiCredential()
    {
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(
                Path.Combine(home, ".kimi-code", "credentials", "kimi-code.json")));
            var token = StringOrNull(doc.RootElement, "access_token");
            if (!string.IsNullOrEmpty(token) && !IsExpired(doc.RootElement, "expires_at", 60))
                return (token, true);
        }
        catch { }
        var env = Environment.GetEnvironmentVariable("KIMI_CODE_API_KEY")?.Trim();
        if (!string.IsNullOrEmpty(env)) return (env, false);
        var stored = SecureCredentialStore.LoadKimiApiKey();
        return string.IsNullOrEmpty(stored) ? null : (stored, false);
    }

    static string KimiDeviceId()
    {
        var home = Path.Combine(Environment.GetFolderPath(
            Environment.SpecialFolder.UserProfile), ".kimi-code");
        var path = Path.Combine(home, "device_id");
        try
        {
            var existing = File.ReadAllText(path).Trim();
            if (existing.Length > 0) return existing;
        }
        catch { }
        var id = Guid.NewGuid().ToString().ToLowerInvariant();
        try { Directory.CreateDirectory(home); File.WriteAllText(path, id); } catch { }
        return id;
    }

    // MARK: - helpers

    static double? NumberOrNull(JsonElement obj, string key)
    {
        if (obj.ValueKind != JsonValueKind.Object || !obj.TryGetProperty(key, out var v)) return null;
        if (v.ValueKind == JsonValueKind.Number) return v.GetDouble();
        if (v.ValueKind == JsonValueKind.String && double.TryParse(
                v.GetString(), System.Globalization.NumberStyles.Float,
                System.Globalization.CultureInfo.InvariantCulture, out var value))
            return value;
        return null;
    }

    static double? DetailPercent(JsonElement detail)
    {
        var limit = NumberOrNull(detail, "limit");
        if (!limit.HasValue || limit <= 0) return null;
        var used = NumberOrNull(detail, "used");
        if (used.HasValue) return Math.Clamp(used.Value / limit.Value * 100, 0, 100);
        var remaining = NumberOrNull(detail, "remaining");
        return remaining.HasValue
            ? Math.Clamp((limit.Value - remaining.Value) / limit.Value * 100, 0, 100) : null;
    }

    static async Task<byte[]> ReadLimited(HttpContent content, int limit, CancellationToken token)
    {
        if (content.Headers.ContentLength > limit) throw new InvalidDataException("usage response too large");
        await using var stream = await content.ReadAsStreamAsync(token);
        using var output = new MemoryStream(Math.Min(limit, (int)(content.Headers.ContentLength ?? 4096)));
        var buffer = new byte[16 * 1024];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, token);
            if (read == 0) break;
            if (output.Length + read > limit) throw new InvalidDataException("usage response too large");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    static string StringOrNull(JsonElement obj, string key)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var v)
            && v.ValueKind == JsonValueKind.String)
            return v.GetString();
        return null;
    }

    static int? MinutesUntilAnyReset(JsonElement obj, DateTimeOffset now)
    {
        foreach (var key in new[] { "resetTime", "resetAt", "reset_time", "reset_at" })
        {
            var value = MinutesUntilValue(obj, key, now);
            if (value.HasValue) return value;
        }
        return null;
    }

    static int? MinutesUntilValue(JsonElement obj, string key, DateTimeOffset now)
    {
        if (!obj.TryGetProperty(key, out var value)) return null;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var epoch))
        {
            if (epoch > 10_000_000_000) epoch /= 1000;
            return Math.Max(0, (int)(DateTimeOffset.FromUnixTimeSeconds((long)epoch) - now).TotalMinutes);
        }
        return value.ValueKind == JsonValueKind.String ? MinutesUntil(value.GetString(), now) : null;
    }

    static bool IsExpired(JsonElement obj, string key, int graceSeconds = 0)
    {
        if (!obj.TryGetProperty(key, out var value)) return false;
        double raw;
        if (value.ValueKind == JsonValueKind.Number) raw = value.GetDouble();
        else if (value.ValueKind == JsonValueKind.String && double.TryParse(
                     value.GetString(), System.Globalization.NumberStyles.Float,
                     System.Globalization.CultureInfo.InvariantCulture, out var parsed)) raw = parsed;
        else if (value.ValueKind == JsonValueKind.String
                 && DateTimeOffset.TryParse(value.GetString(), out var date))
            return date <= DateTimeOffset.UtcNow.AddSeconds(graceSeconds);
        else return false;
        if (raw > 10_000_000_000) raw /= 1000;
        return raw <= DateTimeOffset.UtcNow.AddSeconds(graceSeconds).ToUnixTimeSeconds();
    }

    static string AsciiHeader(string value)
    {
        var chars = value.Where(c => c >= 0x20 && c <= 0x7e).ToArray();
        return chars.Length == 0 ? "unknown" : new string(chars);
    }

    static int? MinutesUntil(string iso, DateTimeOffset now)
    {
        if (iso == null) return null;
        if (!DateTimeOffset.TryParse(iso, null, System.Globalization.DateTimeStyles.RoundtripKind, out var d))
            return null;
        return Math.Max(0, (int)((d - now).TotalMinutes));
    }
}
