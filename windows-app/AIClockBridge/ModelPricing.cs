using System.Text.Json;

namespace AIClockBridge;

readonly record struct TokenPrice(
    double Input, double CachedInput, double CacheWrite, double CacheWrite1h, double Output,
    double? PriorityInput = null, double? PriorityCachedInput = null, double? PriorityOutput = null);

/// Offline-first model price catalog. Prices are USD/token. The bundled table
/// works immediately; LiteLLM's public catalog refreshes it in the background.
sealed class ModelPricing
{
    public static readonly ModelPricing Shared = new();

    static readonly Uri Source = new(
        "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json");
    static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(12) };
    readonly object _lock = new();
    readonly string _cachePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData),
        "AIClockBridge", "model-prices.json");
    readonly Dictionary<string, TokenPrice> _prices = new(StringComparer.OrdinalIgnoreCase);

    ModelPricing()
    {
        foreach (var pair in Fallback) _prices[pair.Key] = pair.Value;
        try { Merge(File.ReadAllBytes(_cachePath)); } catch { }
    }

    public void Refresh() => _ = Task.Run(async () =>
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(12));
            using var response = await Http.GetAsync(Source, HttpCompletionOption.ResponseHeadersRead, cts.Token);
            response.EnsureSuccessStatusCode();
            var data = await ReadLimited(response.Content, 16 * 1024 * 1024, cts.Token);
            Merge(data);
            Directory.CreateDirectory(Path.GetDirectoryName(_cachePath)!);
            await File.WriteAllBytesAsync(_cachePath, data);
        }
        catch { }
    });

    static async Task<byte[]> ReadLimited(HttpContent content, int limit, CancellationToken token)
    {
        if (content.Headers.ContentLength > limit) throw new InvalidDataException("model price catalog too large");
        await using var stream = await content.ReadAsStreamAsync(token);
        using var output = new MemoryStream(Math.Min(limit, (int)(content.Headers.ContentLength ?? 4096)));
        var buffer = new byte[32 * 1024];
        while (true)
        {
            var read = await stream.ReadAsync(buffer, token);
            if (read == 0) break;
            if (output.Length + read > limit) throw new InvalidDataException("model price catalog too large");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    public TokenPrice? Price(string rawModel, bool priority)
    {
        var model = (rawModel ?? "").ToLowerInvariant();
        var slash = model.LastIndexOf('/');
        if (slash >= 0) model = model[(slash + 1)..];
        var normalized = model;
        foreach (var suffix in new[] { "-extra-high", "-xhigh", "-ultra", "-medium", "-high", "-none", "-low", "-max" })
        {
            if (!model.EndsWith(suffix)) continue;
            normalized = model[..^suffix.Length];
            break;
        }

        TokenPrice? result;
        lock (_lock)
        {
            if (_prices.TryGetValue(model, out var exact)) result = exact;
            else if (_prices.TryGetValue(normalized, out var basePrice)) result = basePrice;
            else result = FamilyPrice(normalized);
        }
        if (!priority || result == null) return result;

        var p = result.Value;
        double? multiplier = p.PriorityInput.HasValue || p.PriorityOutput.HasValue ? 1
            : model.StartsWith("gpt-5.5") || model.StartsWith("gpt-5.6") ? 2.5
            : model.StartsWith("gpt-5") ? 2 : null;
        if (!multiplier.HasValue) return null;
        return new TokenPrice(
            p.PriorityInput ?? p.Input * multiplier.Value,
            p.PriorityCachedInput ?? p.CachedInput * multiplier.Value,
            p.CacheWrite * multiplier.Value, p.CacheWrite1h * multiplier.Value,
            p.PriorityOutput ?? p.Output * multiplier.Value,
            p.PriorityInput, p.PriorityCachedInput, p.PriorityOutput);
    }

    TokenPrice? FamilyPrice(string model)
    {
        string key = model.StartsWith("claude-opus-4-") ? "claude-opus-4"
            : model.StartsWith("claude-sonnet-4-") ? "claude-sonnet-4"
            : model.StartsWith("claude-haiku-4-") ? "claude-haiku-4"
            : model.StartsWith("gpt-5-codex-") ? "gpt-5-codex" : null;
        return key != null && _prices.TryGetValue(key, out var price) ? price : null;
    }

    void Merge(byte[] data)
    {
        using var doc = JsonDocument.Parse(data);
        var parsed = new Dictionary<string, TokenPrice>(StringComparer.OrdinalIgnoreCase);
        foreach (var model in doc.RootElement.EnumerateObject())
        {
            var v = model.Value;
            if (!Number(v, "input_cost_per_token", out var input)
                || !Number(v, "output_cost_per_token", out var output)) continue;
            parsed[model.Name] = new TokenPrice(
                input, Number(v, "cache_read_input_token_cost") ?? input,
                Number(v, "cache_creation_input_token_cost") ?? input,
                Number(v, "cache_creation_input_token_cost_above_1hr") ?? input * 2,
                output, Number(v, "input_cost_per_token_priority"),
                Number(v, "cache_read_input_token_cost_priority"),
                Number(v, "output_cost_per_token_priority"));
        }
        if (parsed.Count == 0) return;
        lock (_lock) foreach (var pair in parsed) _prices[pair.Key] = pair.Value;
    }

    static bool Number(JsonElement obj, string name, out double value)
    {
        value = 0;
        return obj.TryGetProperty(name, out var v) && v.ValueKind == JsonValueKind.Number
            && v.TryGetDouble(out value) && double.IsFinite(value) && value >= 0 && value <= 1;
    }

    static double? Number(JsonElement obj, string name)
        => Number(obj, name, out var value) ? value : null;

    static readonly Dictionary<string, TokenPrice> Fallback = new(StringComparer.OrdinalIgnoreCase)
    {
        ["gpt-5"] = new(0.00000125, 0.000000125, 0.00000125, 0.0000025, 0.00001,
            0.0000025, 0.00000025, 0.00002),
        ["gpt-5-codex"] = new(0.00000125, 0.000000125, 0.00000125, 0.0000025, 0.00001),
        ["gpt-5.6-sol"] = new(0.000005, 0.0000005, 0.000005, 0.00001, 0.00003,
            0.00001, 0.000001, 0.00006),
        ["claude-opus-4"] = new(0.000015, 0.0000015, 0.00001875, 0.00003, 0.000075),
        ["claude-sonnet-4"] = new(0.000003, 0.0000003, 0.00000375, 0.000006, 0.000015),
        ["claude-haiku-4"] = new(0.000001, 0.0000001, 0.00000125, 0.000002, 0.000005),
    };
}
