using System.Text;
using System.Text.Json;

namespace AIClockBridge;

// Port of the Mac StatusReader. No account APIs / keys are touched -
// everything comes from the JSONL session logs Claude Code and Codex CLI
// already write to disk (same paths on Windows, under %USERPROFILE%):
//   ~/.claude/projects/**/*.jsonl   (Claude Code transcripts)
//   ~/.codex/sessions/**/*.jsonl    (Codex CLI rollouts, incl. rate_limits)

class ClaudeStatus
{
    public string Status = "offline";
    public int TokensToday;
    public int SessionMin;
    public int SessionWindowMin = 300;
    public double? FiveHourPct;
    public int? FiveHourResetMin;
    public double? SevenDayPct;
    public int? SevenDayResetMin;
    public bool NeedsInput; // waiting on a permission/approval prompt
    public double? CostToday;
    public bool CostComplete = true;
    public long LastActivityAt;
    public bool FastMode;
    public long FastTaskSeq;
    internal long SessionStartedAt;
}

class CodexStatus
{
    public string Status = "offline";
    public int TokensToday;
    public double? WeeklyPct;
    public int? WeeklyWindowMin;
    public int? WeeklyResetMin;
    public bool NeedsInput;
    public double? CostToday;
    public bool CostComplete = true;
    public long LastActivityAt;
    public bool FastMode;
    public long FastTaskSeq;
    internal long WeeklyResetAt;
}

class StatusSnapshot
{
    public ClaudeStatus Claude = new();
    public CodexStatus Codex = new();
    public long Ts;
    public bool MusicPlaying;
    public string PreferredAgent = "codex";

    /// Serializes to the exact JSON shape the firmware's parseStatusJson expects.
    public byte[] ToJson()
    {
        using var ms = new MemoryStream();
        using (var w = new Utf8JsonWriter(ms))
        {
            w.WriteStartObject();
            w.WriteNumber("ts", Ts);
            w.WriteBoolean("music_playing", MusicPlaying);
            w.WriteString("preferred_agent", PreferredAgent);
            w.WriteStartObject("claude");
            w.WriteString("status", Claude.Status);
            w.WriteNumber("tokens_today", Claude.TokensToday);
            w.WriteNumber("session_min", Claude.SessionMin);
            w.WriteNumber("session_window_min", Claude.SessionWindowMin);
            WriteNullable(w, "five_hour_pct", Claude.FiveHourPct);
            WriteNullable(w, "five_hour_reset_min", Claude.FiveHourResetMin);
            WriteNullable(w, "seven_day_pct", Claude.SevenDayPct);
            WriteNullable(w, "seven_day_reset_min", Claude.SevenDayResetMin);
            w.WriteBoolean("needs_input", Claude.NeedsInput);
            WriteNullable(w, "cost_today_usd", Claude.CostToday);
            w.WriteBoolean("cost_complete", Claude.CostComplete);
            w.WriteNumber("last_activity_at", Claude.LastActivityAt);
            w.WriteBoolean("fast_mode", Claude.FastMode);
            w.WriteNumber("fast_task_seq", Claude.FastTaskSeq);
            w.WriteEndObject();
            w.WriteStartObject("codex");
            w.WriteString("status", Codex.Status);
            w.WriteNumber("tokens_today", Codex.TokensToday);
            WriteNullable(w, "weekly_pct", Codex.WeeklyPct);
            WriteNullable(w, "weekly_window_min", Codex.WeeklyWindowMin);
            WriteNullable(w, "weekly_reset_min", Codex.WeeklyResetMin);
            w.WriteBoolean("needs_input", Codex.NeedsInput);
            WriteNullable(w, "cost_today_usd", Codex.CostToday);
            w.WriteBoolean("cost_complete", Codex.CostComplete);
            w.WriteNumber("last_activity_at", Codex.LastActivityAt);
            w.WriteBoolean("fast_mode", Codex.FastMode);
            w.WriteNumber("fast_task_seq", Codex.FastTaskSeq);
            w.WriteEndObject();
            w.WriteEndObject();
        }
        return ms.ToArray();
    }

    static void WriteNullable(Utf8JsonWriter w, string name, double? v)
    {
        if (v.HasValue) w.WriteNumber(name, v.Value); else w.WriteNull(name);
    }

    static void WriteNullable(Utf8JsonWriter w, string name, int? v)
    {
        if (v.HasValue) w.WriteNumber(name, v.Value); else w.WriteNull(name);
    }

    StatusSnapshot() { }

    public StatusSnapshot(ClaudeStatus claude, CodexStatus codex, long ts)
    {
        Claude = claude;
        Codex = codex;
        Ts = ts;
    }

    public StatusSnapshot Clone()
    {
        return new StatusSnapshot
        {
            Claude = (ClaudeStatus)Claude.MemberwiseCloneOf(),
            Codex = (CodexStatus)Codex.MemberwiseCloneOf(),
            Ts = Ts,
            MusicPlaying = MusicPlaying,
            PreferredAgent = PreferredAgent,
        };
    }
}

static class CloneHelper
{
    public static object MemberwiseCloneOf(this object o)
    {
        var clone = Activator.CreateInstance(o.GetType());
        foreach (var f in o.GetType().GetFields(System.Reflection.BindingFlags.Instance
                                                | System.Reflection.BindingFlags.Public
                                                | System.Reflection.BindingFlags.NonPublic))
            f.SetValue(clone, f.GetValue(o));
        return clone;
    }
}

/// Reads the logs and derives status, with a small time cache so back-to-back
/// HTTP polls and the mirror timer don't each re-scan the whole tree.
sealed class StatusService
{
    readonly string _claudeDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".claude", "projects");
    readonly string _codexDir = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".codex", "sessions");

    /// Real OAuth quota (5h/weekly windows) merged into snapshots when set;
    /// log-derived values remain the fallback for offline use.
    public UsageFetcher Usage;

    /// Whether audio is playing right now (drives the device's AUTO -> music
    /// auto-switch). Set from NowPlayingMonitor in Program.
    public Func<bool> MusicPlayingProvider;

    // Hook-pushed live state (POST /event from Claude Code / Codex hooks).
    // Events beat the mtime heuristic while fresh: "working" for up to 10min
    // (a long tool run emits nothing between PreToolUse and PostToolUse),
    // "idle" for 60s (long enough to kill the mtime tail after Stop, short
    // enough that a session without hooks isn't stuck idle).
    record AgentEvent(string State, double At);

    AgentEvent _claudeEvent;
    AgentEvent _codexEvent;
    // "needs input": a permission/approval prompt is on screen, waiting on the
    // user. Set by an attention event, cleared by the next concrete lifecycle
    // event (the prompt got answered) or by TTL.
    double? _claudeNeedsInputAt;
    double? _codexNeedsInputAt;
    bool _claudeFastMode;
    bool _codexFastMode;
    long _claudeHookTaskSeq;
    long _codexHookTaskSeq;
    long _claudePendingTaskSeq;
    long _codexPendingTaskSeq;
    int _claudePendingScanCount;
    int _codexPendingScanCount;
    ulong _taskEventGeneration;
    const double WorkingEventTTL = 10 * 60;
    const double IdleEventTTL = 60;
    const double NeedsInputTTL = 5 * 60;

    static readonly HashSet<string> WorkingEvents = new()
    {
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "WorktreeCreate", "task_started", "TaskStarted",
    };
    static readonly HashSet<string> IdleEvents = new() { "Stop", "SessionEnd", "SessionStart" };
    // Codex PermissionRequest and MCP Elicitation are always a real "act now"
    // prompt. Claude's Notification is broader — it also fires on task
    // completion / 60s-idle — so it only counts as needs-input when its
    // message is actually a permission request.
    static readonly HashSet<string> AttentionEvents = new() { "Elicitation", "PermissionRequest" };

    static bool IsPermissionNotification(string message)
    {
        var m = message?.ToLowerInvariant() ?? "";
        return m.Contains("permission") || m.Contains("approve") || m.Contains("approval");
    }

    /// Called by the /event endpoint. Unknown event names are ignored.
    /// `message` is only sent for Claude's Notification hook.
    public void RecordEvent(string agent, string ev, string message = null)
    {
        lock (_lock)
        {
            var now = Now();
            if (ev is "UserPromptSubmit" or "task_started" or "TaskStarted")
            {
                _taskEventGeneration++;
                // The hook can arrive before the CLI appends fast/priority
                // metadata to JSONL, so the next refresh must not take the
                // unchanged-fingerprint shortcut.
                _lastLogFingerprint = DirtyLogFingerprint;
                _cachedAt = 0;
                var seq = (long)(now * 1000);
                if (agent == "claude")
                {
                    _claudePendingTaskSeq = Math.Max(_claudePendingTaskSeq, seq);
                    _claudePendingScanCount = 0;
                    if (_claudeFastMode) _claudeHookTaskSeq = Math.Max(_claudeHookTaskSeq, seq);
                }
                else if (agent == "codex")
                {
                    _codexPendingTaskSeq = Math.Max(_codexPendingTaskSeq, seq);
                    _codexPendingScanCount = 0;
                    if (_codexFastMode) _codexHookTaskSeq = Math.Max(_codexHookTaskSeq, seq);
                }
            }
            // Claude Notification: flash only for permission prompts, not for
            // "task done / waiting for your input" notifications.
            if (ev == "Notification")
            {
                if (IsPermissionNotification(message))
                {
                    if (agent == "claude") _claudeNeedsInputAt = now;
                    else if (agent == "codex") _codexNeedsInputAt = now;
                }
                return;
            }
            if (AttentionEvents.Contains(ev))
            {
                if (agent == "claude") _claudeNeedsInputAt = now;
                else if (agent == "codex") _codexNeedsInputAt = now;
                return;
            }
            string state;
            if (WorkingEvents.Contains(ev)) state = "working";
            else if (IdleEvents.Contains(ev)) state = "idle";
            else return;
            var e = new AgentEvent(state, now);
            // any concrete lifecycle event means the prompt (if any) was answered
            if (agent == "claude") { _claudeEvent = e; _claudeNeedsInputAt = null; }
            else if (agent == "codex") { _codexEvent = e; _codexNeedsInputAt = null; }
        }
    }

    static bool NeedsInput(double? at, double now) => at.HasValue && now - at.Value < NeedsInputTTL;

    /// Event override, applied on top of the log-derived status. "offline"
    /// from logs is only upgraded by a fresh working event (a live hook means
    /// the CLI is definitely running).
    static string OverrideStatus(string logStatus, AgentEvent ev, double now)
    {
        if (ev == null) return logStatus;
        var age = now - ev.At;
        if (ev.State == "working" && age < WorkingEventTTL) return "working";
        if (ev.State == "idle" && age < IdleEventTTL && logStatus == "working") return "idle";
        return logStatus;
    }

    const double WorkingThreshold = 20;        // log touched within this -> "working"
    const double IdleThreshold = 30 * 60;      // within this -> "idle", else "offline"
    const double CacheTTL = 5;

    readonly object _lock = new();
    StatusSnapshot _cached;
    double _cachedAt;
    bool _refreshInFlight;
    long _lastLogFingerprint;
    const long DirtyLogFingerprint = long.MinValue;

    static double Now() => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() / 1000.0;

    public StatusSnapshot Snapshot()
    {
        StatusSnapshot snap;
        UsageFetcher usage;
        Func<bool> music;
        AgentEvent claudeEvent, codexEvent;
        double? claudeInputAt, codexInputAt;
        long claudeHookSeq, codexHookSeq;
        var now = Now();
        lock (_lock)
        {
            var needsRefresh = _cached == null || now - _cachedAt >= CacheTTL;
            if (needsRefresh && !_refreshInFlight)
            {
                _refreshInFlight = true;
                _ = Task.Run(RefreshCache);
            }
            snap = (_cached ?? new StatusSnapshot(new(), new(), (long)now)).Clone();
            usage = Usage; music = MusicPlayingProvider;
            claudeEvent = _claudeEvent; codexEvent = _codexEvent;
            claudeInputAt = _claudeNeedsInputAt; codexInputAt = _codexNeedsInputAt;
            claudeHookSeq = _claudeHookTaskSeq; codexHookSeq = _codexHookTaskSeq;
        }
        snap.Ts = (long)now;
        snap.Claude.Status = StatusFromDelta(snap.Claude.LastActivityAt > 0 ? now - snap.Claude.LastActivityAt : 1e9);
        snap.Codex.Status = StatusFromDelta(snap.Codex.LastActivityAt > 0 ? now - snap.Codex.LastActivityAt : 1e9);
        if (snap.Claude.SessionStartedAt > 0)
        {
            var elapsed = now - snap.Claude.SessionStartedAt;
            snap.Claude.SessionMin = elapsed is >= 0 and < 5 * 3600 ? (int)(elapsed / 60) : 0;
        }
        if (snap.Codex.WeeklyResetAt > 0)
            snap.Codex.WeeklyResetMin = Math.Max(0, (int)((snap.Codex.WeeklyResetAt - now) / 60));
        if (usage != null)
        {
            var cu = usage.Claude;
            snap.Claude.FiveHourPct = cu.PrimaryPct; snap.Claude.FiveHourResetMin = cu.PrimaryResetMin;
            snap.Claude.SevenDayPct = cu.WeeklyPct; snap.Claude.SevenDayResetMin = cu.WeeklyResetMin;
            var xu = usage.Codex;
            if (xu.WeeklyPct.HasValue) { snap.Codex.WeeklyPct = xu.WeeklyPct; snap.Codex.WeeklyResetMin = xu.WeeklyResetMin; }
        }
        snap.Claude.Status = OverrideStatus(snap.Claude.Status, claudeEvent, now);
        snap.Codex.Status = OverrideStatus(snap.Codex.Status, codexEvent, now);
        snap.Claude.NeedsInput = NeedsInput(claudeInputAt, now); snap.Codex.NeedsInput = NeedsInput(codexInputAt, now);
        snap.Claude.FastTaskSeq = Math.Max(snap.Claude.FastTaskSeq, claudeHookSeq);
        snap.Codex.FastTaskSeq = Math.Max(snap.Codex.FastTaskSeq, codexHookSeq);
        snap.PreferredAgent = snap.Claude.LastActivityAt > snap.Codex.LastActivityAt ? "claude" : "codex";
        snap.MusicPlaying = music?.Invoke() ?? false;
        return snap;
    }

    void RefreshCache()
    {
        ulong generation;
        lock (_lock) generation = _taskEventGeneration;
        var fingerprint = LogFingerprint();
        lock (_lock)
        {
            if (_cached != null && fingerprint == _lastLogFingerprint)
            {
                _cachedAt = Now(); _refreshInFlight = false;
                return;
            }
        }
        StatusSnapshot refreshed = null;
        try { refreshed = new StatusSnapshot(ReadClaude(), ReadCodex(), (long)Now()); }
        catch (Exception e) { Console.Error.WriteLine($"[status] scan failed: {e.Message}"); }
        lock (_lock)
        {
            var taskArrived = generation != _taskEventGeneration;
            if (refreshed != null && !taskArrived)
            {
                _claudeFastMode = refreshed.Claude.FastMode; _codexFastMode = refreshed.Codex.FastMode;
                if (_claudeFastMode)
                {
                    _claudeHookTaskSeq = Math.Max(_claudeHookTaskSeq, _claudePendingTaskSeq);
                    _claudePendingTaskSeq = 0;
                    _claudePendingScanCount = 0;
                }
                else if (_claudePendingTaskSeq > 0 && ++_claudePendingScanCount >= 2)
                    _claudePendingTaskSeq = 0;
                if (_codexFastMode)
                {
                    _codexHookTaskSeq = Math.Max(_codexHookTaskSeq, _codexPendingTaskSeq);
                    _codexPendingTaskSeq = 0;
                    _codexPendingScanCount = 0;
                }
                else if (_codexPendingTaskSeq > 0 && ++_codexPendingScanCount >= 2)
                    _codexPendingTaskSeq = 0;
            }
            if (refreshed != null) _cached = refreshed;
            var pendingFastDetection = _claudePendingTaskSeq > 0 || _codexPendingTaskSeq > 0;
            _lastLogFingerprint = refreshed != null && !taskArrived && !pendingFastDetection
                ? fingerprint : DirtyLogFingerprint;
            _cachedAt = refreshed == null || taskArrived ? 0 : Now();
            _refreshInFlight = false;
        }
    }

    long LogFingerprint()
    {
        unchecked
        {
            // Daily totals roll over at local 00:01 even if no CLI log changes.
            var localNow = DateTime.Now;
            var usageDay = localNow < localNow.Date.AddMinutes(1) ? localNow.Date.AddDays(-1) : localNow.Date;
            long hash = 17 * 31 + usageDay.Ticks;
            foreach (var root in new[] { _claudeDir, _codexDir })
            {
                if (!Directory.Exists(root)) continue;
                try
                {
                    foreach (var path in Directory.EnumerateFiles(root, "*.jsonl", SearchOption.AllDirectories))
                    {
                        var info = new FileInfo(path);
                        hash = hash * 31 + info.Length;
                        hash = hash * 31 + info.LastWriteTimeUtc.Ticks;
                    }
                }
                catch { hash = hash * 31 + root.GetHashCode(); }
            }
            return hash;
        }
    }

    // MARK: - helpers

    static string StatusFromDelta(double delta)
    {
        if (delta < WorkingThreshold) return "working";
        if (delta < IdleThreshold) return "idle";
        return "offline";
    }

    static double? ParseIso(string s)
    {
        if (s == null) return null;
        if (DateTimeOffset.TryParse(s, null, System.Globalization.DateTimeStyles.RoundtripKind, out var d))
            return d.ToUnixTimeMilliseconds() / 1000.0;
        return null;
    }

    internal static DateTime UsageWindowStart(DateTime date) => date.Date.AddMinutes(1);
    static double TodayStartEpoch() => new DateTimeOffset(UsageWindowStart(DateTime.Now)).ToUnixTimeMilliseconds() / 1000.0;
    static double TodayEndEpoch() => new DateTimeOffset(DateTime.Today.AddDays(1)).ToUnixTimeMilliseconds() / 1000.0;

    /// Stream one line at a time while the CLI may still be appending. Avoid
    /// ReadToEnd+Split: current session logs can be hundreds of MB and that
    /// allocation caused global GC pauses even though scanning is background.
    static IEnumerable<string> ReadLines(string path)
    {
        FileStream fs;
        try
        {
            fs = new FileStream(path, FileMode.Open, FileAccess.Read,
                                FileShare.ReadWrite | FileShare.Delete);
        }
        catch
        {
            yield break;
        }
        using (fs)
        using (var reader = new StreamReader(fs, Encoding.UTF8))
        {
            while (true)
            {
                string line;
                try { line = reader.ReadLine(); }
                catch { yield break; }
                if (line == null) yield break;
                if (line.Length > 0) yield return line;
            }
        }
    }

    static int IntVal(JsonElement obj, string key)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var v)
            && v.ValueKind == JsonValueKind.Number)
            return (int)v.GetDouble();
        return 0;
    }

    static double? DoubleVal(JsonElement obj, string key)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var v)
            && v.ValueKind == JsonValueKind.Number)
            return v.GetDouble();
        return null;
    }

    static string StringVal(JsonElement obj, string key)
    {
        if (obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out var v)
            && v.ValueKind == JsonValueKind.String)
            return v.GetString();
        return null;
    }

    static bool TryProp(JsonElement obj, string key, out JsonElement value)
    {
        value = default;
        return obj.ValueKind == JsonValueKind.Object && obj.TryGetProperty(key, out value);
    }

    // MARK: - Claude

    ClaudeStatus ReadClaude()
    {
        var todayStart = TodayStartEpoch();
        var todayEnd = TodayEndEpoch();
        var now = Now();
        var tokensToday = 0;
        var costToday = 0.0;
        var costComplete = true;
        double lastMtime = 0, lastActivity = 0, latestFastAt = 0;
        double? firstActiveInWindow = null;
        var fastMode = false;
        long fastTaskSeq = 0;
        var usageEntries = new Dictionary<string, ClaudeUsageEntry>();

        if (Directory.Exists(_claudeDir))
        {
            IEnumerable<string> files;
            try
            {
                files = Directory.GetFiles(_claudeDir, "*.jsonl", SearchOption.AllDirectories);
            }
            catch
            {
                files = Array.Empty<string>();
            }
            foreach (var file in files)
            {
                double mtime;
                try
                {
                    mtime = new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero)
                        .ToUnixTimeMilliseconds() / 1000.0;
                }
                catch
                {
                    continue;
                }
                if (mtime > lastMtime) lastMtime = mtime;
                if (mtime < todayStart) continue; // no activity today, skip parsing
                var lines = ReadLines(file);
                if (lines == null) continue;
                var fileFastMode = false;
                double? fileLastUserAt = null;
                foreach (var line in lines)
                {
                    JsonDocument doc;
                    try { doc = JsonDocument.Parse(line); } catch { continue; }
                    using (doc)
                    {
                        var root = doc.RootElement;
                        var entryEpoch = ParseIso(StringVal(root, "timestamp"));
                        var type = StringVal(root, "type") ?? "";
                        if (entryEpoch.HasValue && (type == "user" || type == "assistant"))
                            lastActivity = Math.Max(lastActivity, entryEpoch.Value);
                        if (type == "user" && entryEpoch.HasValue)
                        {
                            fileLastUserAt = entryEpoch;
                            if (fileFastMode) fastTaskSeq = Math.Max(fastTaskSeq, (long)(entryEpoch.Value * 1000));
                        }
                        if (!TryProp(root, "message", out var message)
                            || !TryProp(message, "usage", out var usage)) continue;
                        var speed = StringVal(usage, "speed");
                        if (speed != null)
                        {
                            fileFastMode = speed.Equals("fast", StringComparison.OrdinalIgnoreCase);
                            if ((entryEpoch ?? 0) >= latestFastAt) { latestFastAt = entryEpoch ?? 0; fastMode = fileFastMode; }
                        }
                        if (fileFastMode && fileLastUserAt.HasValue)
                            fastTaskSeq = Math.Max(fastTaskSeq, (long)(fileLastUserAt.Value * 1000));
                        if (entryEpoch.HasValue && (entryEpoch.Value < todayStart || entryEpoch.Value >= todayEnd)) continue;
                        var input = IntVal(usage, "input_tokens"); var output = IntVal(usage, "output_tokens");
                        var split5m = 0; var split1h = 0;
                        if (TryProp(usage, "cache_creation", out var creation))
                        { split5m = IntVal(creation, "ephemeral_5m_input_tokens"); split1h = IntVal(creation, "ephemeral_1h_input_tokens"); }
                        var cache5m = split5m + split1h > 0 ? split5m : IntVal(usage, "cache_creation_input_tokens");
                        var cacheRead = IntVal(usage, "cache_read_input_tokens");
                        var id = StringVal(message, "id") ?? StringVal(root, "uuid")
                            ?? $"{StringVal(root, "timestamp")}:{input}:{output}:{cache5m}:{split1h}:{cacheRead}";
                        var model = StringVal(message, "model"); if (model == "<synthetic>") model = null;
                        var explicitCost = DoubleVal(root, "costUSD") ?? DoubleVal(message, "costUSD");
                        var entry = new ClaudeUsageEntry(input, output, cache5m, split1h, cacheRead, model, fileFastMode, explicitCost);
                        if (!usageEntries.TryGetValue(id, out var old) || entry.Total > old.Total) usageEntries[id] = entry;
                        if (entryEpoch.HasValue && now - entryEpoch.Value < 5 * 3600)
                        {
                            if (!firstActiveInWindow.HasValue || entryEpoch.Value < firstActiveInWindow.Value)
                                firstActiveInWindow = entryEpoch.Value;
                        }
                    }
                }
            }
        }

        foreach (var entry in usageEntries.Values)
        {
            tokensToday += entry.Total;
            if (entry.ExplicitCost.HasValue) costToday += entry.ExplicitCost.Value;
            else if (entry.Model != null && ModelPricing.Shared.Price(entry.Model, entry.Fast) is TokenPrice p)
                costToday += entry.Input * p.Input + entry.Output * p.Output + entry.Cache5m * p.CacheWrite
                    + entry.Cache1h * p.CacheWrite1h + entry.CacheRead * p.CachedInput;
            else if (entry.Total > 0) costComplete = false;
        }
        if (!double.IsFinite(costToday)) costComplete = false;
        lastActivity = Math.Max(lastActivity, lastMtime);
        var s = new ClaudeStatus
        {
            TokensToday = tokensToday, CostToday = costComplete ? costToday : null,
            CostComplete = costComplete, LastActivityAt = (long)lastActivity,
            FastMode = fastMode, FastTaskSeq = fastTaskSeq,
            SessionStartedAt = (long)(firstActiveInWindow ?? 0),
        };
        if (firstActiveInWindow.HasValue) s.SessionMin = (int)((now - firstActiveInWindow.Value) / 60);
        s.Status = StatusFromDelta(lastActivity > 0 ? now - lastActivity : 1e9);
        return s;
    }

    readonly record struct ClaudeUsageEntry(int Input, int Output, int Cache5m, int Cache1h,
                                             int CacheRead, string Model, bool Fast, double? ExplicitCost)
    { public int Total => Input + Output + Cache5m + Cache1h + CacheRead; }

    // MARK: - Codex

    CodexStatus ReadCodex()
    {
        var now = Now();
        var todayStart = TodayStartEpoch(); var todayEnd = TodayEndEpoch();
        double lastMtime = 0, lastActivity = 0, latestFastAt = 0;
        var candidates = new List<string>();

        // Whole-tree scan just for the freshest mtime (drives working/idle).
        if (Directory.Exists(_codexDir))
        {
            try
            {
                foreach (var file in Directory.EnumerateFiles(_codexDir, "*.jsonl", SearchOption.AllDirectories))
                {
                    var mtime = new DateTimeOffset(File.GetLastWriteTimeUtc(file), TimeSpan.Zero)
                        .ToUnixTimeMilliseconds() / 1000.0;
                    if (mtime > lastMtime) lastMtime = mtime;
                    if (mtime >= todayStart - 24 * 3600) candidates.Add(file);
                }
            }
            catch
            {
                // partial scan is fine
            }
        }

        var tokensToday = 0;
        var costToday = 0.0; var costComplete = true; var fastMode = false; long fastTaskSeq = 0;
        JsonElement? latestRateLimits = null;
        double latestRateLimitsTs = 0;

        foreach (var file in candidates)
        {
            var lines = ReadLines(file); if (lines == null) continue;
            JsonElement? previousTotal = null;
            var currentModel = ""; var currentPriority = false;
            foreach (var line in lines)
            {
                JsonDocument doc;
                try { doc = JsonDocument.Parse(line); } catch { continue; }
                using (doc)
                {
                    var root = doc.RootElement;
                    if (!TryProp(root, "payload", out var payload)) continue;
                    var entryEpoch = ParseIso(StringVal(root, "timestamp")) ?? 0;
                    var outerType = StringVal(root, "type") ?? "";
                    var type = StringVal(payload, "type") ?? "";
                    if (outerType == "turn_context")
                    {
                        currentModel = StringVal(payload, "model") ?? currentModel;
                        lastActivity = Math.Max(lastActivity, entryEpoch);
                        continue;
                    }
                    if (type == "thread_settings_applied")
                    {
                        if (TryProp(payload, "thread_settings", out var settings))
                        {
                            var tier = (StringVal(settings, "service_tier") ?? "").ToLowerInvariant();
                            currentPriority = tier is "fast" or "priority";
                            if (entryEpoch >= latestFastAt) { latestFastAt = entryEpoch; fastMode = currentPriority; }
                        }
                        continue;
                    }
                    if (type == "task_started")
                    {
                        lastActivity = Math.Max(lastActivity, entryEpoch);
                        if (currentPriority) fastTaskSeq = Math.Max(fastTaskSeq, (long)(entryEpoch * 1000));
                        continue;
                    }
                    if (type != "token_count") continue;
                    JsonElement info = default, totalUsage = default;
                    var hasInfo = TryProp(payload, "info", out info);
                    var hasTotal = hasInfo && TryProp(info, "total_token_usage", out totalUsage);
                    if (TryProp(payload, "rate_limits", out var rl)
                        || (hasInfo && TryProp(info, "rate_limits", out rl)))
                    {
                        if (entryEpoch >= latestRateLimitsTs)
                        {
                            latestRateLimitsTs = entryEpoch; latestRateLimits = rl.Clone();
                        }
                    }
                    if (!hasTotal) continue;
                    if (entryEpoch >= todayStart && entryEpoch < todayEnd)
                    {
                        var last = hasInfo && TryProp(info, "last_token_usage", out var lastUsage) ? lastUsage : default;
                        int Delta(string key) => previousTotal.HasValue
                            ? Math.Max(0, IntVal(totalUsage, key) - IntVal(previousTotal.Value, key))
                            : IntVal(last, key);
                        var total = Delta("total_tokens");
                        if (total > 0)
                        {
                            var input = Delta("input_tokens"); var cached = Delta("cached_input_tokens"); var output = Delta("output_tokens");
                            tokensToday += total;
                            if (ModelPricing.Shared.Price(currentModel, currentPriority) is TokenPrice p)
                                costToday += Math.Max(0, input - cached) * p.Input + cached * p.CachedInput + output * p.Output;
                            else costComplete = false;
                        }
                    }
                    previousTotal = totalUsage.Clone();
                }
            }
        }

        lastActivity = Math.Max(lastActivity, lastMtime);
        if (!double.IsFinite(costToday)) costComplete = false;
        var s = new CodexStatus
        {
            TokensToday = tokensToday, CostToday = costComplete ? costToday : null,
            CostComplete = costComplete, LastActivityAt = (long)lastActivity,
            FastMode = fastMode, FastTaskSeq = fastTaskSeq,
        };
        s.Status = StatusFromDelta(lastActivity > 0 ? now - lastActivity : 1e9);
        if (latestRateLimits.HasValue)
        {
            var weekly = CodexWeeklyWindow(latestRateLimits.Value);
            if (weekly.HasValue)
            {
                var w = weekly.Value; s.WeeklyPct = DoubleVal(w, "used_percent");
                s.WeeklyWindowMin = (int?)DoubleVal(w, "window_minutes");
                var reset = DoubleVal(w, "resets_at") ?? DoubleVal(w, "reset_at");
                if (reset.HasValue)
                {
                    s.WeeklyResetAt = (long)reset.Value;
                    s.WeeklyResetMin = Math.Max(0, (int)((reset.Value - now) / 60));
                }
            }
        }
        return s;
    }

    static JsonElement? CodexWeeklyWindow(JsonElement limits)
    {
        var parsed = new List<(string Name, JsonElement Value, int? Minutes)>();
        foreach (var name in new[] { "primary", "secondary", "primary_window", "secondary_window" })
        {
            if (!TryProp(limits, name, out var value) || !DoubleVal(value, "used_percent").HasValue) continue;
            parsed.Add((name, value, (int?)DoubleVal(value, "window_minutes")));
        }
        var exact = parsed.FirstOrDefault(x => x.Minutes == 7 * 24 * 60);
        if (exact.Value.ValueKind != JsonValueKind.Undefined) return exact.Value;
        var secondary = parsed.FirstOrDefault(x => x.Name is "secondary" or "secondary_window");
        if (secondary.Value.ValueKind != JsonValueKind.Undefined) return secondary.Value;
        return parsed.Count == 1 && parsed[0].Minutes == null ? parsed[0].Value : null;
    }
}
