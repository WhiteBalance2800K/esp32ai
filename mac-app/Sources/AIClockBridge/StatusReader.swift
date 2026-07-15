import Foundation

// Port of the old bridge.py log-reading logic. No account APIs / keys are
// touched - everything comes from the JSONL session logs Claude Code and Codex
// CLI already write to disk:
//   ~/.claude/projects/**/*.jsonl   (Claude Code transcripts)
//   ~/.codex/sessions/**/*.jsonl    (Codex CLI rollouts, incl. rate_limits)

struct ClaudeStatus {
    var status: String = "offline"
    var tokensToday: Int = 0
    var sessionMin: Int = 0
    var sessionWindowMin: Int = 300
    var fiveHourPct: Double? = nil
    var fiveHourResetMin: Int? = nil
    var sevenDayPct: Double? = nil
    var sevenDayResetMin: Int? = nil
    var needsInput: Bool = false // waiting on a permission/approval prompt
    var costToday: Double? = 0
    var costComplete: Bool = true
    var lastActivityAt: Int64 = 0
    var fastMode: Bool = false
    var fastTaskSeq: Int64 = 0
}

struct CodexStatus {
    var status: String = "offline"
    var tokensToday: Int = 0
    var weeklyPct: Double? = nil
    var weeklyWindowMin: Int? = nil
    var weeklyResetMin: Int? = nil
    var needsInput: Bool = false
    var costToday: Double? = 0
    var costComplete: Bool = true
    var lastActivityAt: Int64 = 0
    var fastMode: Bool = false
    var fastTaskSeq: Int64 = 0
}

struct Snapshot {
    var claude: ClaudeStatus
    var codex: CodexStatus
    var ts: Int
    var musicPlaying: Bool = false
    var preferredAgent: String = "codex"
}

/// Codex has used both primary/secondary names for its quota windows.  The
/// weekly window is the one whose duration is 10080 minutes; older logs also
/// reliably identify it as `secondary`.  Keep this parser in one place so the
/// log reader and the OAuth response reader agree on the same value.
struct CodexWeeklyWindow {
    let usedPercent: Double?
    let windowMinutes: Int?
    let resetsAt: Double?
}

func codexWeeklyWindow(from limits: [String: Any]) -> CodexWeeklyWindow? {
    let candidates: [(name: String, value: Any?)] = [
        ("primary", limits["primary"]),
        ("secondary", limits["secondary"]),
        ("primary_window", limits["primary_window"]),
        ("secondary_window", limits["secondary_window"]),
    ]
    var parsed: [(name: String, window: CodexWeeklyWindow)] = []
    for candidate in candidates {
        guard let dict = candidate.value as? [String: Any],
              let used = (dict["used_percent"] as? NSNumber)?.doubleValue else { continue }
        let minutes = (dict["window_minutes"] as? NSNumber)?.intValue
        let reset = (dict["resets_at"] as? NSNumber)?.doubleValue
            ?? (dict["reset_at"] as? NSNumber)?.doubleValue
        parsed.append((candidate.name, CodexWeeklyWindow(usedPercent: used,
                                                         windowMinutes: minutes,
                                                         resetsAt: reset)))
    }
    // Explicit duration wins even if it is stored under the newer `primary`
    // key.  This is the shape emitted by current Codex sessions.
    if let weekly = parsed.first(where: { $0.window.windowMinutes == 7 * 24 * 60 }) {
        return weekly.window
    }
    // In older payloads secondary was the weekly window even when a duration
    // was omitted.  Prefer it over the 5-hour primary window.
    if let secondary = parsed.first(where: { $0.name == "secondary" || $0.name == "secondary_window" }) {
        return secondary.window
    }
    // A single-window response may omit the duration. Never promote an
    // explicitly short (5-hour) primary window to Weekly.
    if let single = parsed.first?.window, single.windowMinutes == nil { return single }
    return nil
}

/// Reads the logs and derives status, with a small time cache so back-to-back
/// HTTP polls and the menu-bar timer don't each re-scan the whole tree.
final class StatusService {
    private let claudeDir = ("~/.claude/projects" as NSString).expandingTildeInPath
    private let codexDir = ("~/.codex/sessions" as NSString).expandingTildeInPath

    /// Real OAuth quota merged into snapshots when set: Claude 5h/weekly and
    /// Codex weekly only. Log-derived values remain the offline fallback.
    var usage: UsageFetcher?

    /// Whether audio is playing right now (drives the device's AUTO -> music
    /// auto-switch). Set from NowPlayingMonitor in main.
    var musicPlayingProvider: (() -> Bool)?

    // Hook-pushed live state (POST /event from Claude Code / Codex hooks).
    // Events beat the mtime heuristic while fresh: "working" for up to 10min
    // (a long tool run emits nothing between PreToolUse and PostToolUse),
    // "idle" for 60s (long enough to kill the mtime tail after Stop, short
    // enough that a session without hooks isn't stuck idle).
    private struct AgentEvent {
        let state: String // "working" | "idle"
        let at: TimeInterval
    }

    private var claudeEvent: AgentEvent?
    private var codexEvent: AgentEvent?
    // "needs input": a permission/approval prompt is on screen, waiting on the
    // user. Set by an attention event, cleared by the next concrete lifecycle
    // event (the prompt got answered) or by TTL.
    private var claudeNeedsInputAt: TimeInterval?
    private var codexNeedsInputAt: TimeInterval?
    private var claudeFastMode = false
    private var codexFastMode = false
    private var claudeHookTaskSeq: Int64 = 0
    private var codexHookTaskSeq: Int64 = 0
    private let workingEventTTL: TimeInterval = 10 * 60
    private let idleEventTTL: TimeInterval = 60
    private let needsInputTTL: TimeInterval = 5 * 60

    private static let workingEvents: Set<String> = [
        "UserPromptSubmit", "PreToolUse", "PostToolUse", "SubagentStart", "SubagentStop",
        "PreCompact", "PostCompact", "WorktreeCreate", "task_started", "TaskStarted",
    ]
    private static let idleEvents: Set<String> = [
        "Stop", "SessionEnd", "SessionStart",
    ]
    // Codex PermissionRequest and MCP Elicitation are always a real "act now"
    // prompt. Claude's Notification is broader — it also fires on task
    // completion / 60s-idle — so it only counts as needs-input when its
    // message is actually a permission request (see isPermissionNotification).
    private static let attentionEvents: Set<String> = [
        "Elicitation", "PermissionRequest",
    ]

    private func isPermissionNotification(_ message: String?) -> Bool {
        guard let m = message?.lowercased() else { return false }
        return m.contains("permission") || m.contains("approve") || m.contains("approval")
    }

    /// Called by the /event endpoint. Unknown event names are ignored.
    /// `message` is only sent for Claude's Notification hook.
    func recordEvent(agent: String, event: String, message: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        if event == "UserPromptSubmit" || event == "task_started" || event == "TaskStarted" {
            let seq = Int64(now * 1000)
            if agent == "claude", claudeFastMode { claudeHookTaskSeq = seq }
            if agent == "codex", codexFastMode { codexHookTaskSeq = seq }
        }
        // Claude Notification: flash only for permission prompts, not for
        // "task done / waiting for your input" notifications.
        if event == "Notification" {
            if isPermissionNotification(message) {
                if agent == "claude" { claudeNeedsInputAt = now }
                else if agent == "codex" { codexNeedsInputAt = now }
            }
            return
        }
        if Self.attentionEvents.contains(event) {
            if agent == "claude" { claudeNeedsInputAt = now }
            else if agent == "codex" { codexNeedsInputAt = now }
            return
        }
        let state: String
        if Self.workingEvents.contains(event) { state = "working" }
        else if Self.idleEvents.contains(event) { state = "idle" }
        else { return }
        let ev = AgentEvent(state: state, at: now)
        // any concrete lifecycle event means the prompt (if any) was answered
        if agent == "claude" { claudeEvent = ev; claudeNeedsInputAt = nil }
        else if agent == "codex" { codexEvent = ev; codexNeedsInputAt = nil }
    }

    private func needsInput(_ at: TimeInterval?, now: TimeInterval) -> Bool {
        guard let at = at else { return false }
        return now - at < needsInputTTL
    }

    /// Event override, applied on top of the log-derived status. "offline"
    /// from logs is only upgraded by a fresh working event (a live hook means
    /// the CLI is definitely running).
    private func overrideStatus(_ logStatus: String, with event: AgentEvent?, now: TimeInterval) -> String {
        guard let ev = event else { return logStatus }
        let age = now - ev.at
        if ev.state == "working", age < workingEventTTL { return "working" }
        if ev.state == "idle", age < idleEventTTL, logStatus == "working" { return "idle" }
        return logStatus
    }

    private let workingThreshold: TimeInterval = 20        // log touched within this -> "working"
    private let idleThreshold: TimeInterval = 30 * 60      // within this -> "idle", else "offline"
    private let cacheTTL: TimeInterval = 5

    private let lock = NSLock()
    private var cached: Snapshot?
    private var cachedAt: TimeInterval = 0

    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        let now = Date().timeIntervalSince1970
        var snap: Snapshot
        if let c = cached, now - cachedAt < cacheTTL {
            snap = c
        } else {
            snap = Snapshot(claude: readClaude(), codex: readCodex(), ts: Int(now))
            claudeFastMode = snap.claude.fastMode
            codexFastMode = snap.codex.fastMode
            cached = snap
            cachedAt = now
        }
        snap.ts = Int(now)

        // overlays are cheap and applied on every call, so hook events and
        // fresh quota show through instantly even while the log scan is cached
        if let u = usage {
            let claudeUsage = u.claude
            snap.claude.fiveHourPct = claudeUsage.primaryPct
            snap.claude.fiveHourResetMin = claudeUsage.primaryResetMin
            snap.claude.sevenDayPct = claudeUsage.weeklyPct
            snap.claude.sevenDayResetMin = claudeUsage.weeklyResetMin
            let codexUsage = u.codex
            if let pct = codexUsage.weeklyPct {
                snap.codex.weeklyPct = pct
                snap.codex.weeklyResetMin = codexUsage.weeklyResetMin
            }
        }
        snap.claude.status = overrideStatus(snap.claude.status, with: claudeEvent, now: now)
        snap.codex.status = overrideStatus(snap.codex.status, with: codexEvent, now: now)
        snap.claude.needsInput = needsInput(claudeNeedsInputAt, now: now)
        snap.codex.needsInput = needsInput(codexNeedsInputAt, now: now)
        snap.claude.fastTaskSeq = max(snap.claude.fastTaskSeq, claudeHookTaskSeq)
        snap.codex.fastTaskSeq = max(snap.codex.fastTaskSeq, codexHookTaskSeq)
        snap.preferredAgent = snap.claude.lastActivityAt > snap.codex.lastActivityAt ? "claude" : "codex"
        snap.musicPlaying = musicPlayingProvider?() ?? false
        return snap
    }

    // MARK: - helpers

    private func statusFromDelta(_ delta: TimeInterval) -> String {
        if delta < workingThreshold { return "working" }
        if delta < idleThreshold { return "idle" }
        return "offline"
    }

    private func parseISO(_ s: String?) -> Double? {
        guard let s = s else { return nil }
        if let d = isoFrac.date(from: s) { return d.timeIntervalSince1970 }
        if let d = isoPlain.date(from: s) { return d.timeIntervalSince1970 }
        return nil
    }

    static func usageWindowStart(for date: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .minute, value: 1, to: calendar.startOfDay(for: date))!
    }

    private func todayStartEpoch() -> Double {
        Self.usageWindowStart(for: Date()).timeIntervalSince1970
    }

    private func todayEndEpoch() -> Double {
        Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))!
            .timeIntervalSince1970
    }

    /// Lossy UTF-8 read (matches Python's errors="ignore") split into lines.
    private func readLines(_ url: URL) -> [Substring]? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
    }

    private func intVal(_ any: Any?) -> Int {
        (any as? NSNumber)?.intValue ?? 0
    }

    // MARK: - Claude

    private func readClaude() -> ClaudeStatus {
        struct UsageEntry {
            let input, output, cacheWrite5m, cacheWrite1h, cacheRead: Int
            let model: String?
            let fast: Bool
            let explicitCost: Double?
            var total: Int { input + output + cacheWrite5m + cacheWrite1h + cacheRead }
        }
        let todayStart = todayStartEpoch()
        let todayEnd = todayEndEpoch()
        let now = Date().timeIntervalSince1970
        var tokensToday = 0
        var costToday = 0.0
        var costComplete = true
        var lastActivity: TimeInterval = 0
        var latestMtime: TimeInterval = 0
        var latestFastStateAt: TimeInterval = 0
        var firstActiveInWindow: Double? = nil
        var fastMode = false
        var fastTaskSeq: Int64 = 0
        var usageEntries: [String: UsageEntry] = [:]

        let fm = FileManager.default
        let root = URL(fileURLWithPath: claudeDir)
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                guard let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 else { continue }
                if mtime > latestMtime { latestMtime = mtime }
                if mtime < todayStart { continue } // no activity today, skip parsing
                guard let lines = readLines(url) else { continue }
                var fileFastMode = false
                var fileLastUserAt: Double?
                for line in lines {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                        continue
                    }
                    let entryEpoch = parseISO(obj["timestamp"] as? String)
                    if let e = entryEpoch, ["user", "assistant"].contains(obj["type"] as? String ?? "") {
                        lastActivity = max(lastActivity, e)
                    }
                    if obj["type"] as? String == "user", let e = entryEpoch {
                        fileLastUserAt = e
                        if fileFastMode { fastTaskSeq = max(fastTaskSeq, Int64(e * 1000)) }
                    }
                    guard let message = obj["message"] as? [String: Any],
                          let usage = message["usage"] as? [String: Any] else { continue }
                    if let speed = usage["speed"] as? String, (entryEpoch ?? 0) >= latestFastStateAt {
                        latestFastStateAt = entryEpoch ?? 0
                        fastMode = speed.lowercased() == "fast"
                    }
                    if let speed = usage["speed"] as? String { fileFastMode = speed.lowercased() == "fast" }
                    if fileFastMode, let userAt = fileLastUserAt {
                        fastTaskSeq = max(fastTaskSeq, Int64(userAt * 1000))
                    }
                    if let e = entryEpoch, e < todayStart || e >= todayEnd { continue }
                    let input = intVal(usage["input_tokens"])
                    let output = intVal(usage["output_tokens"])
                    let cacheCreation = usage["cache_creation"] as? [String: Any]
                    let split5m = intVal(cacheCreation?["ephemeral_5m_input_tokens"])
                    let split1h = intVal(cacheCreation?["ephemeral_1h_input_tokens"])
                    let cacheWrite5m = split5m + split1h > 0
                        ? split5m : intVal(usage["cache_creation_input_tokens"])
                    let cacheWrite1h = split1h
                    let cacheRead = intVal(usage["cache_read_input_tokens"])
                    let id = (message["id"] as? String) ?? (obj["uuid"] as? String) ?? ""
                    let key = !id.isEmpty ? id
                        : "\(obj["timestamp"] as? String ?? ""):\(input):\(output):\(cacheWrite5m):\(cacheWrite1h):\(cacheRead)"
                    let model = message["model"] as? String
                    let entry = UsageEntry(input: input, output: output, cacheWrite5m: cacheWrite5m,
                                           cacheWrite1h: cacheWrite1h, cacheRead: cacheRead,
                                           model: model == "<synthetic>" ? nil : model, fast: fileFastMode,
                                           explicitCost: (obj["costUSD"] as? NSNumber)?.doubleValue
                                               ?? (message["costUSD"] as? NSNumber)?.doubleValue)
                    if usageEntries[key] == nil || entry.total > usageEntries[key]!.total {
                        usageEntries[key] = entry
                    }
                    if let e = entryEpoch, now - e < 5 * 3600 {
                        if firstActiveInWindow == nil || e < firstActiveInWindow! { firstActiveInWindow = e }
                    }
                }
            }
        }

        for entry in usageEntries.values {
            tokensToday += entry.total
            if let explicit = entry.explicitCost {
                costToday += explicit
            } else if let model = entry.model,
                      let p = ModelPricing.shared.price(for: model, priority: entry.fast) {
                costToday += Double(entry.input) * p.input + Double(entry.output) * p.output
                    + Double(entry.cacheWrite5m) * p.cacheWrite
                    + Double(entry.cacheWrite1h) * p.cacheWrite1h
                    + Double(entry.cacheRead) * p.cachedInput
            } else if entry.total > 0 {
                costComplete = false
            }
        }

        var s = ClaudeStatus()
        lastActivity = max(lastActivity, latestMtime)
        s.tokensToday = tokensToday
        s.costToday = costComplete ? costToday : nil
        s.costComplete = costComplete
        s.lastActivityAt = Int64(lastActivity)
        s.fastMode = fastMode
        s.fastTaskSeq = fastTaskSeq
        if let first = firstActiveInWindow { s.sessionMin = Int((now - first) / 60) }
        s.status = statusFromDelta(lastActivity > 0 ? now - lastActivity : 1e9)
        return s
    }

    // MARK: - Codex

    private func readCodex() -> CodexStatus {
        let now = Date().timeIntervalSince1970
        let todayStart = todayStartEpoch()
        let todayEnd = todayEndEpoch()
        var lastActivity: TimeInterval = 0
        var latestMtime: TimeInterval = 0
        var latestFastStateAt: TimeInterval = 0
        let fm = FileManager.default
        let root = URL(fileURLWithPath: codexDir)
        var candidateFiles: [URL] = []

        // Whole-tree scan just for the freshest mtime (drives working/idle).
        if let en = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey]) {
            for case let url as URL in en where url.pathExtension == "jsonl" {
                if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970, mtime > latestMtime {
                    latestMtime = mtime
                    if mtime >= todayStart - 24 * 3600 { candidateFiles.append(url) }
                } else if let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970, mtime >= todayStart - 24 * 3600 {
                    candidateFiles.append(url)
                }
            }
        }

        var tokensToday = 0
        var costToday = 0.0
        var costComplete = true
        var fastMode = false
        var fastTaskSeq: Int64 = 0
        var latestRateLimits: [String: Any]? = nil
        var latestRateLimitsTs: Double = 0

        for url in candidateFiles {
                guard let lines = readLines(url) else { continue }
                var previousTotal: [String: Any]?
                var currentModel = ""
                var currentPriority = false
                for line in lines {
                    guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any] else { continue }
                    let entryEpoch = parseISO(obj["timestamp"] as? String) ?? 0
                    if obj["type"] as? String == "turn_context" {
                        currentModel = payload["model"] as? String ?? currentModel
                        lastActivity = max(lastActivity, entryEpoch)
                        continue
                    }
                    let type = payload["type"] as? String ?? ""
                    if type == "thread_settings_applied" {
                        let settings = payload["thread_settings"] as? [String: Any]
                        let tier = (settings?["service_tier"] as? String ?? "").lowercased()
                        currentPriority = tier == "fast" || tier == "priority"
                        if entryEpoch >= latestFastStateAt {
                            latestFastStateAt = entryEpoch
                            fastMode = currentPriority
                        }
                        continue
                    }
                    if type == "task_started" {
                        lastActivity = max(lastActivity, entryEpoch)
                        if currentPriority { fastTaskSeq = max(fastTaskSeq, Int64(entryEpoch * 1000)) }
                        continue
                    }
                    guard type == "token_count" else { continue }
                    let info = payload["info"] as? [String: Any]
                    let totalUsage = info?["total_token_usage"] as? [String: Any]
                    defer { if let totalUsage { previousTotal = totalUsage } }
                    guard entryEpoch >= todayStart, entryEpoch < todayEnd, let totalUsage else { continue }
                    let last = info?["last_token_usage"] as? [String: Any]
                    func delta(_ key: String) -> Int {
                        if let previousTotal {
                            return max(0, intVal(totalUsage[key]) - intVal(previousTotal[key]))
                        }
                        return intVal(last?[key])
                    }
                    let total = delta("total_tokens")
                    guard total > 0 else { continue }
                    let input = delta("input_tokens")
                    let cached = delta("cached_input_tokens")
                    let output = delta("output_tokens")
                    tokensToday += total
                    if let p = ModelPricing.shared.price(for: currentModel, priority: currentPriority) {
                        costToday += Double(max(0, input - cached)) * p.input
                            + Double(cached) * p.cachedInput + Double(output) * p.output
                    } else {
                        costComplete = false
                    }
                    if let rl = (payload["rate_limits"] as? [String: Any])
                        ?? (info?["rate_limits"] as? [String: Any]) {
                        if entryEpoch >= latestRateLimitsTs { latestRateLimitsTs = entryEpoch; latestRateLimits = rl }
                    }
                }
        }

        var s = CodexStatus()
        lastActivity = max(lastActivity, latestMtime)
        s.tokensToday = tokensToday
        s.costToday = costComplete ? costToday : nil
        s.costComplete = costComplete
        s.lastActivityAt = Int64(lastActivity)
        s.fastMode = fastMode
        s.fastTaskSeq = fastTaskSeq
        s.status = statusFromDelta(lastActivity > 0 ? now - lastActivity : 1e9)
        if let rl = latestRateLimits {
            let weekly = codexWeeklyWindow(from: rl)
            s.weeklyPct = weekly?.usedPercent
            s.weeklyWindowMin = weekly?.windowMinutes
            if let reset = weekly?.resetsAt {
                s.weeklyResetMin = max(0, Int((reset - now) / 60))
            }
        }
        return s
    }
}

extension Snapshot {
    /// Serializes to the exact JSON shape the firmware's parseStatusJson expects.
    func jsonData() -> Data {
        func num(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
        func num(_ v: Double?) -> Any { v.map { $0 as Any } ?? NSNull() }
        let dict: [String: Any] = [
            "ts": ts,
            "music_playing": musicPlaying,
            "preferred_agent": preferredAgent,
            "claude": [
                "status": claude.status,
                "tokens_today": claude.tokensToday,
                "session_min": claude.sessionMin,
                "session_window_min": claude.sessionWindowMin,
                "five_hour_pct": num(claude.fiveHourPct),
                "five_hour_reset_min": num(claude.fiveHourResetMin),
                "seven_day_pct": num(claude.sevenDayPct),
                "seven_day_reset_min": num(claude.sevenDayResetMin),
                "needs_input": claude.needsInput,
                "cost_today_usd": num(claude.costToday),
                "cost_complete": claude.costComplete,
                "last_activity_at": claude.lastActivityAt,
                "fast_mode": claude.fastMode,
                "fast_task_seq": claude.fastTaskSeq,
            ],
            "codex": [
                "status": codex.status,
                "tokens_today": codex.tokensToday,
                "weekly_pct": num(codex.weeklyPct),
                "weekly_window_min": num(codex.weeklyWindowMin),
                "weekly_reset_min": num(codex.weeklyResetMin),
                "needs_input": codex.needsInput,
                "cost_today_usd": num(codex.costToday),
                "cost_complete": codex.costComplete,
                "last_activity_at": codex.lastActivityAt,
                "fast_mode": codex.fastMode,
                "fast_task_seq": codex.fastTaskSeq,
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data("{}".utf8)
    }
}
