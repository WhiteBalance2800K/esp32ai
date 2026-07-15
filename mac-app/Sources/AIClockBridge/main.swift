import AppKit

// Development/CI visual check: fetch live BTC data and render the exact
// 240x240 frame the device receives.
if CommandLine.arguments.count >= 3, CommandLine.arguments[1] == "--preview-btc" {
    let output = URL(fileURLWithPath: CommandLine.arguments[2])
    let previewMarket = MarketMonitor()
    previewMarket.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
        let data = output.pathExtension.lowercased() == "raw"
            ? previewMarket.frameRGB565 : BTCFrameRenderer.png(snapshot: previewMarket.snapshot)
        guard let data else { exit(1) }
        do { try data.write(to: output, options: .atomic); exit(0) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    RunLoop.main.run()
    exit(0)
}

if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--preview-market" {
    let output = URL(fileURLWithPath: CommandLine.arguments[3])
    guard let instrument = MarketInstrument.parse(CommandLine.arguments[2]) else {
        FileHandle.standardError.write(Data("unknown market symbol\n".utf8))
        exit(2)
    }
    let previewMarket = MarketMonitor()
    previewMarket.setInstrument(instrument)
    previewMarket.start()
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
        let data = output.pathExtension.lowercased() == "raw"
            ? previewMarket.frameRGB565 : MarketFrameRenderer.png(snapshot: previewMarket.snapshot)
        guard let data else { exit(1) }
        do { try data.write(to: output, options: .atomic); exit(0) }
        catch { FileHandle.standardError.write(Data("\(error)\n".utf8)); exit(1) }
    }
    RunLoop.main.run()
    exit(0)
}

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--status-json" {
    FileHandle.standardOutput.write(StatusService().snapshot(waitForRefresh: true).jsonData())
    FileHandle.standardOutput.write(Data("\n".utf8))
    exit(0)
}

if CommandLine.arguments.count >= 2, CommandLine.arguments[1] == "--self-test" {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
    let sample = calendar.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 18))!
    let start = StatusService.usageWindowStart(for: sample, calendar: calendar)
    let parts = calendar.dateComponents([.hour, .minute], from: start)
    guard parts.hour == 0, parts.minute == 1 else { fatalError("usage window must start at 00:01") }
    guard BTCFrameRenderer.rgb565(snapshot: BTCMarketSnapshot()).count == 240 * 240 * 2 else {
        fatalError("BTC wire frame must be exactly 115200 bytes")
    }
    let symbols = ["600519", "hk00700", "AAPL", "kr005930", "SPX"]
    guard symbols.allSatisfy({ MarketInstrument.parse($0) != nil }) else {
        fatalError("market symbol parser failed")
    }
    print("self-test: usage-window=00:01 market-symbols=5 btc-frame=115200 OK")
    exit(0)
}

// Entry point. Runs as an "accessory" app (menu-bar only, no Dock icon, no main
// window) and starts the /status HTTP server that the ESP8266 clock polls.
// Headless smoke test for the petdex -> GIF -> device pipeline (same code the
// pet picker window uses): AIClockBridge --test-pet <slug> <claude|codex> <host>
if CommandLine.arguments.count >= 4, CommandLine.arguments[1] == "--test-pet" {
    let slug = CommandLine.arguments[2]
    let slot = CommandLine.arguments[3]
    if CommandLine.arguments.count >= 5 { DeviceClient.host = CommandLine.arguments[4] }
    let size = slot == "claude" ? (w: 111, h: 120) : (w: 120, h: 120)
    let state = PetdexService.states.first { $0.id == "running" }!
    PetdexService.loadManifest { result in
        guard case let .success(pets) = result, let pet = pets.first(where: { $0.slug == slug }) else {
            print("manifest load failed or slug not found"); exit(1)
        }
        print("pet: \(pet.displayName) \(pet.spritesheetUrl)")
        PetdexService.downloadSpritesheet(pet) { result in
            guard case let .success(sheet) = result else { print("sheet download failed"); exit(1) }
            print("sheet: \(sheet.width)x\(sheet.height)")
            guard let gif = PetdexService.buildGif(sheet: sheet, state: state,
                                                   targetW: size.w, targetH: size.h) else {
                print("gif build failed"); exit(1)
            }
            print("gif: \(gif.count) bytes, uploading to \(DeviceClient.host) slot \(slot)...")
            DeviceClient.uploadGif(gif, slot: slot) { error in
                print(error.map { "upload failed: \($0.localizedDescription)" } ?? "upload ok")
                exit(error == nil ? 0 : 1)
            }
        }
    }
    RunLoop.main.run() // completions land on the main queue; exit() above ends us
    exit(0)
}

let port: UInt16 = 8765
let service = StatusService()
let usage = UsageFetcher()
service.usage = usage
let netMonitor = NetSpeedMonitor()
netMonitor.start()
let nowPlaying = NowPlayingMonitor()
nowPlaying.start()
let market = MarketMonitor()
market.start()
ModelPricing.shared.refresh()
service.musicPlayingProvider = { nowPlaying.snapshot.playing }

// Wired fallback: if the clock is plugged in over USB, push status/net down
// the serial line (works around AP client isolation; no WiFi setup needed).
let serialLink = SerialLink(service: service, netMonitor: netMonitor)
serialLink.start()

let server = HTTPServer(port: port, routes: [
    "/": { service.snapshot().jsonData() },
    "/status": { service.snapshot().jsonData() },
    "/net": {
        let stats = SystemStatsMonitor.shared.snapshot()
        return netMonitor.jsonData(cpu: stats.cpu, mem: stats.mem)
    },
    "/music": { nowPlaying.jsonData() },
    "/btc": { market.jsonData() },
    "/btc/version": { market.frameVersionJSON },
], binaryRoutes: [
    "/music/cover.raw": { nowPlaying.coverRGB565 },
    "/music/text.raw": { nowPlaying.textRGB565 },
    "/btc/frame.rle": { market.packedFrameEnvelope },
    "/btc/frame.raw": { market.frameEnvelope },
], postRoutes: [
    // Claude Code / Codex hooks push lifecycle events here (see README §7):
    // curl -d '{"agent":"claude","event":"PreToolUse"}' http://127.0.0.1:8765/event
    "/event": { body in
        if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
           let agent = obj["agent"] as? String, let event = obj["event"] as? String {
            service.recordEvent(agent: agent, event: event, message: obj["message"] as? String)
            return Data("{\"ok\":true}".utf8)
        }
        return Data("{\"ok\":false}".utf8)
    },
])
// Passive discovery: the clock polls us, so its source IP identifies it.
// Remember it (for auto-pairing / DHCP-change self-healing) and adopt it
// outright when no device is configured yet.
server.onRequest = { path, ip in
    guard path == "/status" || path == "/net" || path == "/music",
          ip != "127.0.0.1", ip != "::1", !ip.isEmpty else { return }
    DeviceClient.devicePollAt = Date()
    DeviceClient.lastSeenIP = ip
    if DeviceClient.host.isEmpty { DeviceClient.host = ip }
}
// Active fallback for when the passive route can't fire at all (fresh /
// erased device knows no bridge host, so it never polls anyone): if the
// device stays silent, find it ourselves and hand it our address.
Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
    DeviceClient.healPairingIfNeeded(port: port)
}

do {
    try server.start()
    FileHandle.standardError.write(Data("[bridge] serving /status on 0.0.0.0:\(port)\n".utf8))
} catch {
    FileHandle.standardError.write(Data("[bridge] failed to bind port \(port): \(error)\n".utf8))
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let menuBar = MenuBarController(service: service, usage: usage, netMonitor: netMonitor,
                                nowPlaying: nowPlaying, market: market, port: port)
_ = menuBar // retain
usage.startAutoRefresh()
app.run()
