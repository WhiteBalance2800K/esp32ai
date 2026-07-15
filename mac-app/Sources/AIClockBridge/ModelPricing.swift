import Foundation

struct TokenPrice {
    let input: Double
    let cachedInput: Double
    let cacheWrite: Double
    let cacheWrite1h: Double
    let output: Double
    let priorityInput: Double?
    let priorityCachedInput: Double?
    let priorityOutput: Double?
}

/// Small, dependency-free pricing catalog. A bundled fallback keeps totals
/// useful offline; LiteLLM's public catalog refreshes exact model prices at
/// launch and is cached locally for the next offline run.
final class ModelPricing {
    static let shared = ModelPricing()

    private let lock = NSLock()
    private var prices: [String: TokenPrice] = [:]
    private let source = URL(string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json")!
    private let cacheURL: URL

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("AIClockBridge", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        cacheURL = support.appendingPathComponent("model-prices.json")
        prices = Self.fallback
        if let data = try? Data(contentsOf: cacheURL) { merge(data) }
    }

    func refresh() {
        var request = URLRequest(url: source)
        request.timeoutInterval = 12
        URLSession.shared.dataTask(with: request) { [weak self] data, response, _ in
            guard let self, let data,
                  (response as? HTTPURLResponse)?.statusCode == 200 else { return }
            self.merge(data)
            try? data.write(to: self.cacheURL, options: .atomic)
        }.resume()
    }

    func price(for rawModel: String, priority: Bool) -> TokenPrice? {
        var model = rawModel.lowercased()
        if let slash = model.lastIndex(of: "/") { model = String(model[model.index(after: slash)...]) }
        let effortSuffixes = ["-extra-high", "-xhigh", "-ultra", "-medium", "-high", "-none", "-low", "-max"]
        let normalized = effortSuffixes.first(where: { model.hasSuffix($0) })
            .map { String(model.dropLast($0.count)) } ?? model
        lock.lock()
        defer { lock.unlock() }
        let base = prices[model] ?? prices[normalized] ?? fallbackFamilyPrice(normalized)
        guard let p = base, priority else { return base }
        let multiplier: Double?
        if p.priorityInput != nil || p.priorityOutput != nil { multiplier = 1 }
        else if model.hasPrefix("gpt-5.5") || model.hasPrefix("gpt-5.6") { multiplier = 2.5 }
        else if model.hasPrefix("gpt-5") { multiplier = 2 }
        else { multiplier = nil }
        guard let multiplier else { return nil }
        return TokenPrice(input: p.priorityInput ?? p.input * multiplier,
                          cachedInput: p.priorityCachedInput ?? p.cachedInput * multiplier,
                          cacheWrite: p.cacheWrite * multiplier,
                          cacheWrite1h: p.cacheWrite1h * multiplier,
                          output: p.priorityOutput ?? p.output * multiplier,
                          priorityInput: p.priorityInput,
                          priorityCachedInput: p.priorityCachedInput,
                          priorityOutput: p.priorityOutput)
    }

    private func fallbackFamilyPrice(_ model: String) -> TokenPrice? {
        if model.hasPrefix("claude-opus-4-") { return prices["claude-opus-4"] }
        if model.hasPrefix("claude-sonnet-4-") { return prices["claude-sonnet-4"] }
        if model.hasPrefix("claude-haiku-4-") { return prices["claude-haiku-4"] }
        if model.hasPrefix("gpt-5-codex-") { return prices["gpt-5-codex"] }
        return nil
    }

    private func merge(_ data: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var parsed: [String: TokenPrice] = [:]
        for (name, value) in root {
            guard let v = value as? [String: Any],
                  let input = (v["input_cost_per_token"] as? NSNumber)?.doubleValue,
                  let output = (v["output_cost_per_token"] as? NSNumber)?.doubleValue else { continue }
            parsed[name.lowercased()] = TokenPrice(
                input: input,
                cachedInput: (v["cache_read_input_token_cost"] as? NSNumber)?.doubleValue ?? input,
                cacheWrite: (v["cache_creation_input_token_cost"] as? NSNumber)?.doubleValue ?? input,
                cacheWrite1h: (v["cache_creation_input_token_cost_above_1hr"] as? NSNumber)?.doubleValue
                    ?? input * 2,
                output: output,
                priorityInput: (v["input_cost_per_token_priority"] as? NSNumber)?.doubleValue,
                priorityCachedInput: (v["cache_read_input_token_cost_priority"] as? NSNumber)?.doubleValue,
                priorityOutput: (v["output_cost_per_token_priority"] as? NSNumber)?.doubleValue
            )
        }
        guard !parsed.isEmpty else { return }
        lock.lock()
        prices.merge(parsed) { _, new in new }
        lock.unlock()
    }

    private static let fallback: [String: TokenPrice] = [
        "gpt-5": .init(input: 0.00000125, cachedInput: 0.000000125, cacheWrite: 0.00000125,
                       cacheWrite1h: 0.0000025,
                       output: 0.00001, priorityInput: 0.0000025,
                       priorityCachedInput: 0.00000025, priorityOutput: 0.00002),
        "gpt-5-codex": .init(input: 0.00000125, cachedInput: 0.000000125, cacheWrite: 0.00000125,
                             cacheWrite1h: 0.0000025,
                             output: 0.00001, priorityInput: nil,
                             priorityCachedInput: nil, priorityOutput: nil),
        "gpt-5.6-sol": .init(input: 0.000005, cachedInput: 0.0000005, cacheWrite: 0.000005,
                             cacheWrite1h: 0.00001,
                             output: 0.00003, priorityInput: 0.00001,
                             priorityCachedInput: 0.000001, priorityOutput: 0.00006),
        "claude-opus-4": .init(input: 0.000015, cachedInput: 0.0000015, cacheWrite: 0.00001875,
                               cacheWrite1h: 0.00003,
                               output: 0.000075, priorityInput: nil,
                               priorityCachedInput: nil, priorityOutput: nil),
        "claude-sonnet-4": .init(input: 0.000003, cachedInput: 0.0000003, cacheWrite: 0.00000375,
                                 cacheWrite1h: 0.000006,
                                 output: 0.000015, priorityInput: nil,
                                 priorityCachedInput: nil, priorityOutput: nil),
        "claude-haiku-4": .init(input: 0.000001, cachedInput: 0.0000001, cacheWrite: 0.00000125,
                                cacheWrite1h: 0.000002,
                                output: 0.000005, priorityInput: nil,
                                priorityCachedInput: nil, priorityOutput: nil),
    ]
}
