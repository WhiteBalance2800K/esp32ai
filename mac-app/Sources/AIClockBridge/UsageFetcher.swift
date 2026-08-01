import Foundation

// Real quota ("额度") for local AI CLIs, fetched the same way CodexBar does it —
// by reusing the OAuth tokens the CLIs already store locally, no extra login:
//   Claude: token from macOS Keychain item "Claude Code-credentials" (or
//           ~/.claude/.credentials.json), then GET
//           https://api.anthropic.com/api/oauth/usage  (5H + Weekly + Fable)
//   Codex:  token from ~/.codex/auth.json, then GET
//           https://chatgpt.com/backend-api/wham/usage (weekly window only)
//   Grok:   token from ~/.grok/auth.json (fallback: Pi xAI auth), then GET
//           https://cli-chat-proxy.grok.com/v1/billing?format=credits
//   Kimi:   fresh ~/.kimi-code credential, then a Keychain/API-key fallback,
//           GET https://api.kimi.com/coding/v1/usages
// Tokens never leave this machine except toward their own vendor's API.

struct ProviderUsage {
    var primaryPct: Double?     // Claude 5h window used %
    var primaryResetMin: Int?   // minutes until it resets
    var weeklyPct: Double?      // 7d / weekly window used %
    var weeklyResetMin: Int?
    var fablePct: Double?       // Claude model-scoped weekly Fable window
    var fableResetMin: Int?
    var error: String?
    var fetchedAt: Date?
    var rateLimited = false
}

private final class UsageBatch {
    private let lock = NSLock()
    private var values = Array(repeating: ProviderUsage(), count: 4)

    func set(_ index: Int, _ value: ProviderUsage) {
        lock.lock()
        values[index] = value
        lock.unlock()
    }

    func snapshot() -> [ProviderUsage] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

final class UsageFetcher {
    private let lock = NSLock()
    private var _claude = ProviderUsage()
    private var _codex = ProviderUsage()
    private var _grok = ProviderUsage()
    private var _kimi = ProviderUsage()
    private var timer: Timer?
    private var fetching = false
    private var nextAllowedFetch = Date.distantPast // throttle + 429 backoff

    private let minFetchInterval: TimeInterval = 60
    private let rateLimitBackoff: TimeInterval = 300

    var claude: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _claude }
    var codex: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _codex }
    var grok: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _grok }
    var kimi: ProviderUsage { lock.lock(); defer { lock.unlock() }; return _kimi }

    /// Called on the main thread after either provider updates.
    var onUpdate: (() -> Void)?

    func startAutoRefresh(interval: TimeInterval = 120) {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func refresh() {
        lock.lock()
        let blocked = fetching || Date() < nextAllowedFetch
        if !blocked { fetching = true }
        lock.unlock()
        if blocked { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self = self else { return }
            // A slow/missing provider must not delay the other three quota
            // lines. All requests are independent and finish within one
            // shared 20-second ceiling instead of four sequential ceilings.
            let batch = UsageBatch()
            let group = DispatchGroup()
            let jobs: [() -> ProviderUsage] = [
                self.fetchClaude, self.fetchCodex, self.fetchGrok, self.fetchKimi,
            ]
            for (index, job) in jobs.enumerated() {
                group.enter()
                DispatchQueue.global(qos: .utility).async {
                    batch.set(index, job())
                    group.leave()
                }
            }
            group.wait()
            let values = batch.snapshot()
            let claude = values[0], codex = values[1], grok = values[2], kimi = values[3]
            self.lock.lock()
            // Keep the last good numbers when a refresh only produced an
            // error (network hiccup / 429) - stale quota beats no quota.
            self._claude = Self.merge(old: self._claude, new: claude)
            self._codex = Self.merge(old: self._codex, new: codex)
            self._grok = Self.merge(old: self._grok, new: grok)
            self._kimi = Self.merge(old: self._kimi, new: kimi)
            self.fetching = false
            let limited = [claude, codex, grok, kimi].contains { $0.rateLimited }
            let backoff: TimeInterval = limited ? self.rateLimitBackoff : self.minFetchInterval
            self.nextAllowedFetch = Date().addingTimeInterval(backoff)
            self.lock.unlock()
            if let e = claude.error { FileHandle.standardError.write(Data("[usage] claude: \(e)\n".utf8)) }
            if let e = codex.error { FileHandle.standardError.write(Data("[usage] codex: \(e)\n".utf8)) }
            if let e = grok.error { FileHandle.standardError.write(Data("[usage] grok: \(e)\n".utf8)) }
            if let e = kimi.error { FileHandle.standardError.write(Data("[usage] kimi: \(e)\n".utf8)) }
            DispatchQueue.main.async { self.onUpdate?() }
        }
    }

    private static func merge(old: ProviderUsage, new: ProviderUsage) -> ProviderUsage {
        if new.primaryPct == nil && new.weeklyPct == nil && new.fablePct == nil
            && (old.primaryPct != nil || old.weeklyPct != nil || old.fablePct != nil) {
            var kept = old
            kept.error = new.error
            return kept
        }
        return new
    }

    // MARK: - Claude (api.anthropic.com/api/oauth/usage)

    private func fetchClaude() -> ProviderUsage {
        var usage = ProviderUsage()
        guard let token = Self.claudeAccessToken() else {
            usage.error = "未找到 Claude Code 登录凭据"
            return usage
        }
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("claude-code/2.1.0", forHTTPHeaderField: "User-Agent")

        guard let (data, code) = Self.syncRequest(req) else {
            usage.error = "Claude 用量请求失败"
            return usage
        }
        guard code == 200 else {
            usage.rateLimited = code == 429
            usage.error = code == 401 ? "Claude 凭据过期，运行 claude 重新登录"
                : code == 429 ? "Claude 用量接口限流，稍后自动重试"
                : "Claude 用量接口 HTTP \(code)"
            return usage
        }
        guard let parsed = Self.parseClaudeUsage(data) else {
            usage.error = "Claude 用量响应解析失败"
            return usage
        }
        return parsed
    }

    static func parseClaudeUsage(_ data: Data, now: Date = Date()) -> ProviderUsage? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        var usage = ProviderUsage()
        let timestamp = now.timeIntervalSince1970
        if let w = obj["five_hour"] as? [String: Any] {
            usage.primaryPct = (w["utilization"] as? NSNumber)?.doubleValue
            usage.primaryResetMin = Self.minutesUntil(iso: w["resets_at"] as? String, now: timestamp)
        }
        if let w = obj["seven_day"] as? [String: Any] {
            usage.weeklyPct = (w["utilization"] as? NSNumber)?.doubleValue
            usage.weeklyResetMin = Self.minutesUntil(iso: w["resets_at"] as? String, now: timestamp)
        }
        if let limits = obj["limits"] as? [[String: Any]] {
            for limit in limits where (limit["kind"] as? String ?? "").lowercased() == "weekly_scoped" {
                let scope = limit["scope"] as? [String: Any]
                let model = scope?["model"] as? [String: Any]
                let name = (model?["display_name"] as? String ?? "").lowercased()
                guard name.contains("fable") else { continue }
                usage.fablePct = Self.number(limit["percent"])
                usage.fableResetMin = Self.minutesUntil(iso: limit["resets_at"] as? String,
                                                         now: timestamp)
                break
            }
        }
        usage.fetchedAt = Date()
        return usage
    }

    /// Claude Code stores OAuth credentials in the login Keychain on macOS
    /// (file fallback for older setups). JSON: {"claudeAiOauth":{"accessToken":…}}
    static func claudeAccessToken() -> String? {
        var raw: Data?
        let credFile = ("~/.claude/.credentials.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: credFile) {
            raw = data
        } else {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = Pipe()
            guard (try? p.run()) != nil else { return nil }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            guard p.terminationStatus == 0 else { return nil }
            raw = Data(String(decoding: out, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        }
        guard let data = raw,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String, !token.isEmpty else { return nil }
        return token
    }

    // MARK: - Codex (chatgpt.com/backend-api/wham/usage)

    private func fetchCodex() -> ProviderUsage {
        var usage = ProviderUsage()
        guard let creds = Self.codexCredentials() else {
            usage.error = "未找到 Codex 登录凭据 (~/.codex/auth.json)"
            return usage
        }
        var req = URLRequest(url: URL(string: "https://chatgpt.com/backend-api/wham/usage")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AIClockBridge", forHTTPHeaderField: "User-Agent")
        if let account = creds.accountId {
            req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-Id")
        }

        guard let (data, code) = Self.syncRequest(req) else {
            usage.error = "Codex 用量请求失败"
            return usage
        }
        guard (200...299).contains(code) else {
            usage.error = code == 401 || code == 403 ? "Codex 凭据过期，运行 codex 重新登录" : "Codex 用量接口 HTTP \(code)"
            return usage
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rateLimit = obj["rate_limit"] as? [String: Any] else {
            usage.error = "Codex 用量响应解析失败"
            return usage
        }
        let now = Date().timeIntervalSince1970
        if let weekly = codexWeeklyWindow(from: rateLimit) {
            usage.weeklyPct = weekly.usedPercent
            if let reset = weekly.resetsAt {
                usage.weeklyResetMin = max(0, Int((reset - now) / 60))
            }
        }
        usage.fetchedAt = Date()
        return usage
    }

    private static func codexCredentials() -> (accessToken: String, accountId: String?)? {
        let path = ("~/.codex/auth.json" as NSString).expandingTildeInPath
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else { return nil }
        var accountId = tokens["account_id"] as? String
        if accountId == nil, let idToken = tokens["id_token"] as? String {
            accountId = Self.accountIdFromJWT(idToken)
        }
        return (access, accountId)
    }

    /// auth.json without a top-level account_id keeps it inside the id_token
    /// JWT claims (https://api.openai.com/auth -> chatgpt_account_id).
    private static func accountIdFromJWT(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let auth = obj["https://api.openai.com/auth"] as? [String: Any] {
            return auth["chatgpt_account_id"] as? String
        }
        return nil
    }

    // MARK: - Grok Build (cli-chat-proxy.grok.com)

    private func fetchGrok() -> ProviderUsage {
        var usage = ProviderUsage()
        guard let token = Self.grokAccessToken() else {
            usage.error = "未找到 Grok/Pi 登录凭据，请运行 grok login 或在 Pi 登录 xAI"
            return usage
        }
        var req = URLRequest(url: URL(string:
            "https://cli-chat-proxy.grok.com/v1/billing?format=credits")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("xai-grok-cli", forHTTPHeaderField: "x-xai-token-auth")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AIClockBridge", forHTTPHeaderField: "User-Agent")
        guard let (data, code) = Self.syncRequest(req) else {
            usage.error = "Grok 用量请求失败"
            return usage
        }
        guard code == 200 else {
            usage.rateLimited = code == 429
            usage.error = code == 401 || code == 403
                ? "Grok 凭据过期，请重新登录 Grok/Pi"
                : code == 429 ? "Grok 用量接口限流，稍后自动重试"
                : "Grok 用量接口 HTTP \(code)"
            return usage
        }
        guard let parsed = Self.parseGrokUsage(data) else {
            usage.error = "Grok 周额度响应解析失败"
            return usage
        }
        return parsed
    }

    static func parseGrokUsage(_ data: Data, now: Date = Date()) -> ProviderUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = root["config"] as? [String: Any],
              let pct = number(config["creditUsagePercent"]) else { return nil }
        if let period = config["currentPeriod"] as? [String: Any],
           let type = period["type"] as? String,
           type != "USAGE_PERIOD_TYPE_WEEKLY" { return nil }
        var usage = ProviderUsage()
        usage.weeklyPct = pct
        usage.weeklyResetMin = minutesUntil(value: config["billingPeriodEnd"], now: now)
        usage.fetchedAt = now
        return usage
    }

    private static func grokAccessToken() -> String? {
        let grokPath = ("~/.grok/auth.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: grokPath),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let ordered = root.sorted { lhs, rhs in
                let lp = lhs.key.hasPrefix("https://auth.x.ai::")
                let rp = rhs.key.hasPrefix("https://auth.x.ai::")
                return lp && !rp
            }
            for (_, raw) in ordered {
                guard let entry = raw as? [String: Any],
                      let token = entry["key"] as? String, !token.isEmpty else { continue }
                if !isExpired(entry["expires_at"]) { return token }
            }
        }
        let piPath = ("~/.pi/agent/auth.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: piPath),
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let xai = root["xai"] as? [String: Any],
           let token = xai["access"] as? String, !token.isEmpty,
           !isExpired(xai["expires"]) { return token }
        return nil
    }

    // MARK: - Kimi Code (api.kimi.com/coding/v1/usages)

    private func fetchKimi() -> ProviderUsage {
        var usage = ProviderUsage()
        guard let credential = Self.kimiCredential() else {
            usage.error = "未找到 Kimi Code 登录凭据或 API Key"
            return usage
        }
        var req = URLRequest(url: URL(string: "https://api.kimi.com/coding/v1/usages")!)
        req.timeoutInterval = 20
        req.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("AIClockBridge", forHTTPHeaderField: "User-Agent")
        req.setValue("kimi_code_cli", forHTTPHeaderField: "X-Msh-Platform")
        req.setValue("AIClockBridge", forHTTPHeaderField: "X-Msh-Version")
        req.setValue(ProcessInfo.processInfo.hostName.asciiHeaderValue,
                     forHTTPHeaderField: "X-Msh-Device-Name")
        req.setValue("macOS".asciiHeaderValue, forHTTPHeaderField: "X-Msh-Device-Model")
        req.setValue(ProcessInfo.processInfo.operatingSystemVersionString.asciiHeaderValue,
                     forHTTPHeaderField: "X-Msh-Os-Version")
        req.setValue(Self.kimiDeviceID(), forHTTPHeaderField: "X-Msh-Device-Id")
        guard let (data, code) = Self.syncRequest(req) else {
            usage.error = "Kimi Code 用量请求失败"
            return usage
        }
        guard code == 200 else {
            usage.rateLimited = code == 429
            usage.error = code == 401 || code == 403
                ? "Kimi Code 凭据无效或过期"
                : code == 429 ? "Kimi Code 用量接口限流，稍后自动重试"
                : "Kimi Code 用量接口 HTTP \(code)"
            return usage
        }
        guard let parsed = Self.parseKimiUsage(data) else {
            usage.error = "Kimi Code 用量响应解析失败"
            return usage
        }
        return parsed
    }

    static func parseKimiUsage(_ data: Data, now: Date = Date()) -> ProviderUsage? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let weekly = root["usage"] as? [String: Any],
              let weeklyPct = percent(detail: weekly) else { return nil }
        var usage = ProviderUsage()
        usage.weeklyPct = weeklyPct
        usage.weeklyResetMin = minutesUntil(value: resetValue(weekly), now: now)
        if let limits = root["limits"] as? [[String: Any]] {
            let fiveHour = limits.first { limit in
                guard let window = limit["window"] as? [String: Any],
                      let duration = number(window["duration"]),
                      let unit = window["timeUnit"] as? String else { return false }
                return (unit == "TIME_UNIT_MINUTE" && Int(duration) == 300)
                    || (unit == "TIME_UNIT_HOUR" && Int(duration) == 5)
            }
            if let detail = fiveHour?["detail"] as? [String: Any] {
                usage.primaryPct = percent(detail: detail)
                usage.primaryResetMin = minutesUntil(value: resetValue(detail), now: now)
            }
        }
        usage.fetchedAt = now
        return usage
    }

    private static func kimiCredential() -> (token: String, isCLI: Bool)? {
        let path = ("~/.kimi-code/credentials/kimi-code.json" as NSString).expandingTildeInPath
        if let data = FileManager.default.contents(atPath: path),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let token = obj["access_token"] as? String, !token.isEmpty,
           !isExpired(obj["expires_at"], grace: 60) {
            return (token, true)
        }
        if let token = ProcessInfo.processInfo.environment["KIMI_CODE_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return (token, false)
        }
        if let token = SecureCredentialStore.load(account: "kimi-code-api-key") {
            return (token, false)
        }
        return nil
    }

    private static func kimiDeviceID() -> String {
        let home = ("~/.kimi-code" as NSString).expandingTildeInPath
        let path = "\(home)/device_id"
        if let existing = try? String(contentsOfFile: path, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), !existing.isEmpty {
            return existing
        }
        let id = UUID().uuidString.lowercased()
        try? FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        try? id.write(toFile: path, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        return id
    }

    // MARK: - helpers

    private static func minutesUntil(iso: String?, now: Double) -> Int? {
        guard let iso = iso else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = f.date(from: iso)
        if date == nil {
            f.formatOptions = [.withInternetDateTime]
            date = f.date(from: iso)
        }
        guard let d = date else { return nil }
        return max(0, Int((d.timeIntervalSince1970 - now) / 60))
    }

    private static func number(_ value: Any?) -> Double? {
        if let n = value as? NSNumber { return n.doubleValue }
        if let s = value as? String { return Double(s) }
        return nil
    }

    private static func percent(detail: [String: Any]) -> Double? {
        guard let limit = number(detail["limit"]), limit > 0 else { return nil }
        if let used = number(detail["used"]) {
            return min(100, max(0, used / limit * 100))
        }
        if let remaining = number(detail["remaining"]) {
            return min(100, max(0, (limit - remaining) / limit * 100))
        }
        return nil
    }

    private static func resetValue(_ detail: [String: Any]) -> Any? {
        detail["resetTime"] ?? detail["resetAt"] ?? detail["reset_time"] ?? detail["reset_at"]
    }

    private static func minutesUntil(value: Any?, now: Date) -> Int? {
        if let epoch = number(value) {
            let seconds = epoch > 10_000_000_000 ? epoch / 1000 : epoch
            return max(0, Int((seconds - now.timeIntervalSince1970) / 60))
        }
        guard let iso = value as? String else { return nil }
        return minutesUntil(iso: iso, now: now.timeIntervalSince1970)
    }

    private static func isExpired(_ value: Any?, grace: TimeInterval = 0) -> Bool {
        let deadline = Date().addingTimeInterval(grace)
        if let raw = number(value) {
            let seconds = raw > 10_000_000_000 ? raw / 1000 : raw
            return seconds <= deadline.timeIntervalSince1970
        }
        guard let iso = value as? String else { return false }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: iso)
        }()
        return date.map { $0 <= deadline } ?? false
    }

    private static func syncRequest(_ req: URLRequest) -> (Data, Int)? {
        let sem = DispatchSemaphore(value: 0)
        var result: (Data, Int)?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let data = data, let http = resp as? HTTPURLResponse {
                result = (data, http.statusCode)
            }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}

private extension String {
    var asciiHeaderValue: String {
        let scalars = unicodeScalars.filter { (0x20...0x7e).contains($0.value) }
        let value = String(String.UnicodeScalarView(scalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "unknown" : value
    }
}
