import AppKit

// Live "mirror" of the ESP8266 screen, shown in a popover from the menu-bar
// icon. Not a video stream: the Mac re-renders the same scene from the same
// data — /api/info says which app the device is showing (and a sprite_rev
// that bumps when animations change), /sprite/<app>/raw provides the exact
// frames the device draws (custom upload or built-in), and the local
// StatusService supplies the quota numbers the device gets from /status.
// Result: what you see here is what the panel shows, including the walk
// cycle animating only while that app is "working".

// MARK: - RGB565 frame decoding

private func decodeSpriteFrames(_ data: Data, w: Int, h: Int) -> [CGImage] {
    guard data.count >= 1 else { return [] }
    let count = Int(data[data.startIndex])
    let frameBytes = w * h * 2
    guard count > 0, data.count >= 1 + count * frameBytes else { return [] }
    var frames: [CGImage] = []
    let bytes = [UInt8](data)
    for f in 0..<count {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        var src = 1 + f * frameBytes
        for p in 0..<(w * h) {
            // wire order is big-endian RGB565 (see tools/convert_sprites.py)
            let v = (UInt16(bytes[src]) << 8) | UInt16(bytes[src + 1])
            src += 2
            rgba[p * 4 + 0] = UInt8((v >> 11) & 0x1F) << 3
            rgba[p * 4 + 1] = UInt8((v >> 5) & 0x3F) << 2
            rgba[p * 4 + 2] = UInt8(v & 0x1F) << 3
        }
        let data = CFDataCreate(nil, rgba, rgba.count)!
        if let provider = CGDataProvider(data: data),
           let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                             provider: provider, decode: nil, shouldInterpolate: false,
                             intent: .defaultIntent) {
            frames.append(img)
        }
    }
    return frames
}

private func decodeCover(_ data: Data, w: Int, h: Int) -> CGImage? {
    let frameBytes = w * h * 2
    guard data.count >= frameBytes else { return nil }
    let bytes = [UInt8](data)
    var rgba = [UInt8](repeating: 255, count: w * h * 4)
    var src = 0
    for p in 0..<(w * h) {
        let v = (UInt16(bytes[src]) << 8) | UInt16(bytes[src + 1])
        src += 2
        rgba[p * 4 + 0] = UInt8((v >> 11) & 0x1F) << 3
        rgba[p * 4 + 1] = UInt8((v >> 5) & 0x3F) << 2
        rgba[p * 4 + 2] = UInt8(v & 0x1F) << 3
    }
    let data = CFDataCreate(nil, rgba, rgba.count)!
    guard let provider = CGDataProvider(data: data) else { return nil }
    return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                   bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                   bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                   provider: provider, decode: nil, shouldInterpolate: false,
                   intent: .defaultIntent)
}

// MARK: - the 240x240 replica view

enum QuotaBorderLevel: Equatable {
    case green, yellow, red
}

func codexWeeklyBorderLevel(_ pct: Double?) -> QuotaBorderLevel {
    guard let pct else { return .green }
    if pct >= 75 { return .red }
    if pct >= 50 { return .yellow }
    return .green
}

final class MirrorView: NSView {
    // scene state, all in the device's 240x240 logical coordinates
    var frames: [CGImage] = []
    var frameIdx = 0
    var spriteW = 120, spriteH = 120
    var ringPct: Double = 0
    var ringLevel: QuotaBorderLevel = .green
    var needsInput = false // shown app waiting on approval -> red border flash
    var flashOn = false
    var line1 = "5h -"
    var line2 = "Weekly -"
    var dailyLine = "TODAY 0  ~$0.00"
    var showingClaude = true
    var deviceOK = false
    // net-mode mirror: same scrolling area-chart model as the firmware —
    // one column per 250ms sample, 224-column (56s) window, shared "nice"
    // full-scale, dim-green download area + yellow upload line.
    var netMode = false
    var netCPU = -1 // -1 = hidden (CPU/MEM row disabled in the menu)
    var netMem = -1
    var netHeaderDL = "0B"
    var netHeaderUL = "0B"
    private static let netCols = 224 // NET_CHART_W
    private var histRx = [Double](repeating: 0, count: netCols)
    private var histTx = [Double](repeating: 0, count: netCols)

    func resetNetSweep() {
        histRx = [Double](repeating: 0, count: Self.netCols)
        histTx = [Double](repeating: 0, count: Self.netCols)
    }

    func pushNetSample(rx: Double, tx: Double) {
        histRx.removeFirst()
        histRx.append(rx)
        histTx.removeFirst()
        histTx.append(tx)
        needsDisplay = true
    }

    /// Firmware's adaptiveNetScale: the window peak sits at ~87% of the chart.
    private static func adaptiveNetScale(_ maxV: Double) -> Double {
        max(maxV * 1.15, 10240)
    }

    var musicMode = false
    var musicTitle = ""
    var musicArtist = ""
    var musicElapsed: Double = 0
    var musicDuration: Double = 0
    var musicPlaying = false
    var musicCover: CGImage?
    var btcMode = false
    var btcFrame: CGImage?
    var ludicrousProgress: Double? = nil

    private static let claudeLogo = Bundle.aiClockResources.image(forResource: "claude-logo")
    private static let codexLogo = Bundle.aiClockResources.image(forResource: "codex-logo")

    override var isFlipped: Bool { true } // draw in the panel's top-left origin

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let scale = bounds.width / 240.0
        ctx.saveGState()
        ctx.scaleBy(x: scale, y: scale)

        // panel background
        let panel = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 240, height: 240),
                                 xRadius: 10, yRadius: 10)
        NSColor.black.setFill()
        panel.fill()
        panel.addClip()

        if let progress = ludicrousProgress {
            drawLudicrous(ctx, progress: progress)
            ctx.restoreGState()
            return
        }
        if btcMode {
            if let btcFrame {
                ctx.saveGState()
                ctx.translateBy(x: 0, y: 240)
                ctx.scaleBy(x: 1, y: -1)
                ctx.draw(btcFrame, in: CGRect(x: 0, y: 0, width: 240, height: 240))
                ctx.restoreGState()
            }
            ctx.restoreGState()
            return
        }
        if netMode {
            drawNetScene(ctx)
            ctx.restoreGState()
            return
        }
        if musicMode {
            drawMusicScene(ctx)
            ctx.restoreGState()
            return
        }

        // square quota ring: margin 4, thickness 10, clockwise from top-left
        let m: CGFloat = 4, t: CGFloat = 10
        let side: CGFloat = 240 - 2 * m
        let activeColor: NSColor
        switch ringLevel {
        case .green: activeColor = NSColor(calibratedRed: 0, green: 0.85, blue: 0.2, alpha: 1)
        case .yellow: activeColor = .systemYellow
        case .red: activeColor = .systemRed
        }
        let color = deviceOK ? activeColor : NSColor.darkGray
        color.setFill()
        var remaining = side * 4 * CGFloat(max(0, min(ringPct, 100)) / 100)
        let x0 = m, y0 = m, x1 = 240 - m
        var seg = min(remaining, side)
        if seg > 0 { NSRect(x: x0, y: y0, width: seg, height: t).fill() }          // top
        remaining -= side
        seg = min(remaining, side)
        if seg > 0 { NSRect(x: x1 - t, y: y0, width: t, height: seg).fill() }      // right
        remaining -= side
        seg = min(remaining, side)
        if seg > 0 { NSRect(x: x1 - seg, y: 240 - m - t, width: seg, height: t).fill() } // bottom
        remaining -= side
        seg = min(remaining, side)
        if seg > 0 { NSRect(x: x0, y: 240 - m - seg, width: t, height: seg).fill() }     // left

        // sprite, upper-right, pixel-crisp (matches firmware coordinates)
        if !frames.isEmpty {
            let img = frames[min(frameIdx, frames.count - 1)]
            let rect = CGRect(x: 224 - spriteW, y: 18,
                              width: spriteW, height: spriteH)
            ctx.saveGState()
            ctx.interpolationQuality = .none
            // CGContext draws images bottom-up; flip locally around the rect
            ctx.translateBy(x: 0, y: rect.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -rect.midY)
            ctx.draw(img, in: rect)
            ctx.restoreGState()
        }

        // app logo, top-left inside the ring (firmware draws it at 14,18 @40px)
        if let logo = Self.claudeLogo, let logo2 = Self.codexLogo {
            (showingClaude ? logo : logo2).draw(in: NSRect(x: 14, y: 18, width: 40, height: 40))
        }

        // quota text
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: style,
        ]
        (line1 as NSString).draw(in: NSRect(x: 0, y: 188, width: 240, height: 18), withAttributes: attrs)
        (line2 as NSString).draw(in: NSRect(x: 0, y: 206, width: 240, height: 18), withAttributes: attrs)
        (dailyLine as NSString).draw(in: NSRect(x: 0, y: 164, width: 240, height: 20), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .medium),
            .foregroundColor: NSColor(white: 0.68, alpha: 1), .paragraphStyle: style,
        ])

        if !deviceOK {
            let overlay: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 14, weight: .bold),
                .foregroundColor: NSColor.systemRed,
                .paragraphStyle: style,
            ]
            ("设备离线" as NSString).draw(in: NSRect(x: 0, y: 60, width: 240, height: 20),
                                          withAttributes: overlay)
        }

        // approval pending: blink the whole border red over everything else
        if needsInput && flashOn {
            let m: CGFloat = 4, t: CGFloat = 10, side: CGFloat = 240 - 2 * m
            NSColor.systemRed.setFill()
            NSRect(x: m, y: m, width: side, height: t).fill()
            NSRect(x: m, y: 240 - m - t, width: side, height: t).fill()
            NSRect(x: m, y: m, width: t, height: side).fill()
            NSRect(x: 240 - m - t, y: m, width: t, height: side).fill()
        }
        ctx.restoreGState()
    }

    private func drawLudicrous(_ ctx: CGContext, progress p: Double) {
        let pulse = CGFloat(sin(min(1, p) * .pi))
        let cx: CGFloat = 120, cy: CGFloat = 120
        ctx.setStrokeColor(NSColor(white: 0.78, alpha: 0.75).cgColor)
        ctx.setLineWidth(1)
        for i in 0..<14 {
            let a = CGFloat(i) / 14 * .pi * 2 + CGFloat(p) * 0.45
            let inner = 12 + CGFloat(p) * 45
            let outer = 34 + CGFloat(p) * 190
            ctx.move(to: CGPoint(x: cx + cos(a) * inner, y: cy + sin(a) * inner))
            ctx.addLine(to: CGPoint(x: cx + cos(a) * outer, y: cy + sin(a) * outer))
        }
        ctx.strokePath()
        ctx.setStrokeColor(NSColor.systemRed.withAlphaComponent(0.9).cgColor)
        ctx.setLineWidth(2)
        for ring in 0..<3 {
            let radius = (CGFloat(p) * 150 + CGFloat(ring) * 28).truncatingRemainder(dividingBy: 170)
            ctx.strokeEllipse(in: CGRect(x: cx - radius, y: cy - radius, width: radius * 2, height: radius * 2))
        }
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.7).cgColor)
        for i in 0..<34 {
            let seed = CGFloat((i * 47) % 101) / 101
            let a = CGFloat(i * 29) * .pi / 90
            let d = 18 + (seed + CGFloat(p)) * 145
            let r = 0.5 + pulse * 1.6
            ctx.fillEllipse(in: CGRect(x: cx + cos(a) * d - r, y: cy + sin(a) * d - r,
                                       width: r * 2, height: r * 2))
        }
        let style = NSMutableParagraphStyle(); style.alignment = .center
        ("LUDICROUS  +" as NSString).draw(in: NSRect(x: 0, y: 105, width: 240, height: 24), withAttributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 16, weight: .bold),
            .foregroundColor: NSColor.white, .paragraphStyle: style,
        ])
    }

    private func drawMusicScene(_ ctx: CGContext) {
        let coverRect = CGRect(x: 56, y: 16, width: 128, height: 128)
        if let musicCover {
            ctx.saveGState()
            ctx.interpolationQuality = .none
            ctx.translateBy(x: 0, y: coverRect.midY)
            ctx.scaleBy(x: 1, y: -1)
            ctx.translateBy(x: 0, y: -coverRect.midY)
            ctx.draw(musicCover, in: coverRect)
            ctx.restoreGState()
        } else {
            ctx.setFillColor(NSColor.darkGray.cgColor)
            ctx.fill(coverRect)
            let style = NSMutableParagraphStyle()
            style.alignment = .center
            ("No Art" as NSString).draw(in: NSRect(x: 56, y: 72, width: 128, height: 20), withAttributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.lightGray,
                .paragraphStyle: style,
            ])
        }

        let titleStyle = NSMutableParagraphStyle()
        titleStyle.alignment = .center
        titleStyle.lineBreakMode = .byTruncatingTail
        let title = musicTitle.isEmpty ? "No Music" : musicTitle
        (title as NSString).draw(in: NSRect(x: 12, y: 154, width: 216, height: 24), withAttributes: [
            .font: NSFont.systemFont(ofSize: 15, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: titleStyle,
        ])
        (musicArtist as NSString).draw(in: NSRect(x: 12, y: 178, width: 216, height: 20), withAttributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .regular),
            .foregroundColor: NSColor.lightGray,
            .paragraphStyle: titleStyle,
        ])

        let bar = CGRect(x: 20, y: 210, width: 200, height: 8)
        ctx.setFillColor(NSColor.darkGray.cgColor)
        ctx.fill(bar)
        let frac = musicDuration > 0 ? max(0, min(1, musicElapsed / musicDuration)) : 0
        ctx.setFillColor((musicPlaying ? NSColor.systemGreen : NSColor.gray).cgColor)
        ctx.fill(CGRect(x: bar.minX, y: bar.minY, width: bar.width * frac, height: bar.height))
    }

    /// Replica of the firmware's net-speed screen v2: header readouts, then
    /// a 224x128 area chart at (8,60) — dim-green DL fill with bright top
    /// edge, 2px yellow UL line, quarter gridlines, shared nice scale.
    private func drawNetScene(_ ctx: CGContext) {
        let green = NSColor(calibratedRed: 0, green: 0.85, blue: 0.2, alpha: 1)
        let yellow = NSColor(calibratedRed: 1, green: 0.8, blue: 0, alpha: 1)
        let grey = NSColor(white: 0.55, alpha: 1)
        let labelFont = NSFont.monospacedSystemFont(ofSize: 8, weight: .medium)

        ("DOWN" as NSString).draw(at: NSPoint(x: 14, y: 8), withAttributes: [
            .font: labelFont, .foregroundColor: grey,
        ])
        ("UP" as NSString).draw(at: NSPoint(x: 134, y: 8), withAttributes: [
            .font: labelFont, .foregroundColor: grey,
        ])
        let valueFont = NSFont.monospacedSystemFont(ofSize: 19, weight: .semibold)
        ((netHeaderDL + "/s") as NSString).draw(at: NSPoint(x: 12, y: 19), withAttributes: [
            .font: valueFont, .foregroundColor: green,
        ])
        ((netHeaderUL + "/s") as NSString).draw(at: NSPoint(x: 132, y: 19), withAttributes: [
            .font: valueFont, .foregroundColor: yellow,
        ])

        let cx: CGFloat = 8, cy: CGFloat = 60, cw: CGFloat = 224, ch: CGFloat = 128
        let scale = Self.adaptiveNetScale(max(histRx.max() ?? 0, histTx.max() ?? 0))

        // quarter gridlines
        ctx.setStrokeColor(NSColor(white: 0.16, alpha: 1).cgColor)
        ctx.setLineWidth(1)
        for q in 1...3 {
            let y = cy + ch * CGFloat(q) / 4
            ctx.move(to: CGPoint(x: cx, y: y))
            ctx.addLine(to: CGPoint(x: cx + cw, y: y))
        }
        ctx.strokePath()

        // 3-tap smoothed points, one per column (matches the device)
        func points(_ vals: [Double]) -> [CGPoint] {
            (0..<Self.netCols).map { i in
                let lo = max(0, i - 1), hi = min(Self.netCols - 1, i + 1)
                let v = (vals[lo] + vals[i] + vals[hi]) / 3
                let h = min(CGFloat(v / scale), 1) * (ch - 2)
                return CGPoint(x: cx + CGFloat(i), y: cy + ch - 1 - h)
            }
        }

        // download: filled area + bright top edge
        let dl = points(histRx)
        ctx.saveGState()
        ctx.beginPath()
        ctx.move(to: CGPoint(x: cx, y: cy + ch - 1))
        for p in dl { ctx.addLine(to: p) }
        ctx.addLine(to: CGPoint(x: cx + cw - 1, y: cy + ch - 1))
        ctx.closePath()
        ctx.setFillColor(NSColor(calibratedRed: 0, green: 0.33, blue: 0, alpha: 1).cgColor)
        ctx.fillPath()
        ctx.restoreGState()
        // NOT the firmware's LINE_T: the popover is ~4x the panel's physical
        // size, so a thin stroke here matches the device's thick one visually.
        ctx.setStrokeColor(green.cgColor)
        ctx.setLineWidth(3)
        ctx.setLineJoin(.round)
        ctx.beginPath()
        ctx.move(to: dl[0])
        for p in dl.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()

        // upload: yellow line
        let ul = points(histTx)
        ctx.setStrokeColor(yellow.cgColor)
        ctx.setLineWidth(3)
        ctx.beginPath()
        ctx.move(to: ul[0])
        for p in ul.dropFirst() { ctx.addLine(to: p) }
        ctx.strokePath()

        // axis + footer labels
        let style = NSMutableParagraphStyle()
        style.alignment = .right
        (Self.deviceSpeedText(scale) as NSString).draw(
            in: NSRect(x: 120, y: 46, width: 112, height: 12), withAttributes: [
                .font: labelFont, .foregroundColor: grey, .paragraphStyle: style,
            ])
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        if netCPU >= 0 {
            // fixed-x label + value columns, so a value width change (5% ->
            // 30%) never shifts the rest of the row (matches the firmware)
            let sysLabelFont = NSFont.monospacedSystemFont(ofSize: 9, weight: .medium)
            let sysValueFont = NSFont.monospacedSystemFont(ofSize: 15, weight: .bold)
            ("CPU" as NSString).draw(at: NSPoint(x: 28, y: 196), withAttributes: [
                .font: sysLabelFont, .foregroundColor: grey,
            ])
            ("\(netCPU)%" as NSString).draw(at: NSPoint(x: 62, y: 190), withAttributes: [
                .font: sysValueFont, .foregroundColor: NSColor.white,
            ])
            ("MEM" as NSString).draw(at: NSPoint(x: 130, y: 196), withAttributes: [
                .font: sysLabelFont, .foregroundColor: grey,
            ])
            ("\(netMem)%" as NSString).draw(at: NSPoint(x: 164, y: 190), withAttributes: [
                .font: sysValueFont, .foregroundColor: NSColor.white,
            ])
        }
        ("MAC NET  -  56s" as NSString).draw(
            in: NSRect(x: 0, y: 212, width: 240, height: 12), withAttributes: [
                .font: labelFont, .foregroundColor: grey, .paragraphStyle: center,
            ])
    }

    /// Same compact unit strings the firmware prints ("2.3M", "480K").
    static func deviceSpeedText(_ bps: Double) -> String {
        if bps >= 1_000_000 { return String(format: "%.1fM", bps / 1_000_000) }
        if bps >= 1_000 { return String(format: "%.0fK", bps / 1_000) }
        return String(format: "%.0fB", bps)
    }
}

// MARK: - popover controller

final class MirrorPopoverController: NSObject, NSPopoverDelegate {
    private let service: StatusService
    private let netMonitor: NetSpeedMonitor
    private let nowPlaying: NowPlayingMonitor
    private let market: MarketMonitor
    private let popover = NSPopover()
    private let mirror = MirrorView()
    private let modeControl = NSSegmentedControl(labels: ["自动", "Claude", "Codex", "网速", "音乐", "行情"],
                                                 trackingMode: .selectOne, target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "连接设备中…")
    private let brightnessSlider = NSSlider(value: 100, minValue: 0, maxValue: 100,
                                            target: nil, action: nil)
    private let brightnessValueLabel = NSTextField(labelWithString: "100%")
    // Drag streams many slider events; posts to the single-threaded ESP8266 web
    // server are throttled mid-drag and the final value always flushes on mouse-up.
    private var pendingBrightness: Int?
    private var lastBrightnessSentAt = Date.distantPast

    private var pollTimer: Timer?
    private var animTimer: Timer?
    private var sweepTimer: Timer?
    private var spriteCache: [String: (rev: Int, frames: [CGImage], w: Int, h: Int, drawW: Int, drawH: Int)] = [:]
    private var lastInfo: DeviceInfo?
    private var fetchingSlot: String?

    init(service: StatusService, netMonitor: NetSpeedMonitor, nowPlaying: NowPlayingMonitor,
         market: MarketMonitor) {
        self.service = service
        self.netMonitor = netMonitor
        self.nowPlaying = nowPlaying
        self.market = market
        super.init()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentViewController = makeContent()
    }

    private func makeContent() -> NSViewController {
        let vc = NSViewController()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 316, height: 424))

        modeControl.target = self
        modeControl.action = #selector(modeChanged)
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byTruncatingMiddle

        brightnessSlider.target = self
        brightnessSlider.action = #selector(brightnessChanged)
        brightnessSlider.isContinuous = true
        brightnessValueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        brightnessValueLabel.textColor = .secondaryLabelColor
        brightnessValueLabel.alignment = .right
        let brightnessIcon = NSImageView(image: NSImage(systemSymbolName: "sun.max.fill",
                                                        accessibilityDescription: "亮度") ?? NSImage())
        brightnessIcon.contentTintColor = .secondaryLabelColor

        for v in [mirror, modeControl, brightnessIcon, brightnessSlider, brightnessValueLabel, statusLabel] {
            v.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(v)
        }
        NSLayoutConstraint.activate([
            mirror.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            mirror.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            mirror.widthAnchor.constraint(equalToConstant: 288),
            mirror.heightAnchor.constraint(equalToConstant: 288),
            modeControl.topAnchor.constraint(equalTo: mirror.bottomAnchor, constant: 12),
            modeControl.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            brightnessIcon.centerYAnchor.constraint(equalTo: brightnessSlider.centerYAnchor),
            brightnessIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            brightnessSlider.topAnchor.constraint(equalTo: modeControl.bottomAnchor, constant: 10),
            brightnessSlider.leadingAnchor.constraint(equalTo: brightnessIcon.trailingAnchor, constant: 8),
            brightnessSlider.trailingAnchor.constraint(equalTo: brightnessValueLabel.leadingAnchor, constant: -8),
            brightnessValueLabel.centerYAnchor.constraint(equalTo: brightnessSlider.centerYAnchor),
            brightnessValueLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            brightnessValueLabel.widthAnchor.constraint(equalToConstant: 40),
            statusLabel.topAnchor.constraint(equalTo: brightnessSlider.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
        ])
        vc.view = container
        return vc
    }

    // MARK: - brightness slider

    @objc private func brightnessChanged() {
        let level = Int(brightnessSlider.doubleValue.rounded())
        brightnessValueLabel.stringValue = "\(level)%"
        let isFinal = NSApp.currentEvent.map { $0.type != .leftMouseDragged } ?? true
        pendingBrightness = level
        if !isFinal && Date().timeIntervalSince(lastBrightnessSentAt) < 0.25 { return }
        flushBrightness()
    }

    private func flushBrightness() {
        guard let level = pendingBrightness else { return }
        pendingBrightness = nil
        lastBrightnessSentAt = Date()
        DeviceClient.setBrightness(level) { _ in }
    }

    func toggle(relativeTo button: NSStatusBarButton) {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            startTimers()
            tick()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        pollTimer?.invalidate()
        animTimer?.invalidate()
        sweepTimer?.invalidate()
        pollTimer = nil
        animTimer = nil
        sweepTimer = nil
    }

    private func startTimers() {
        pollTimer?.invalidate()
        animTimer?.invalidate()
        sweepTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.tick()
        }
        // same cadence as the firmware's ANIM_INTERVAL_MS
        animTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            self?.animTick()
        }
        // same cadence as the firmware's NET_DRAW_INTERVAL_MS sweep
        sweepTimer = Timer.scheduledTimer(withTimeInterval: NetSpeedMonitor.sampleInterval,
                                          repeats: true) { [weak self] _ in
            self?.sweepTick()
        }
    }

    /// One sweep step: push the newest 4Hz sample, refresh the DL/UL readout.
    private func sweepTick() {
        guard mirror.netMode, popover.isShown else { return }
        let cur = netMonitor.current
        let smoothed = netMonitor.currentSmoothed
        mirror.netHeaderDL = MirrorView.deviceSpeedText(smoothed.rx)
        mirror.netHeaderUL = MirrorView.deviceSpeedText(smoothed.tx)
        let stats = SystemStatsMonitor.shared.snapshot() // internally 1s-cached
        mirror.netCPU = stats.cpu
        mirror.netMem = stats.mem
        mirror.pushNetSample(rx: cur.rx, tx: cur.tx)
    }

    private func tick() {
        DeviceClient.fetchInfo { [weak self] result in
            guard let self = self, self.popover.isShown else { return }
            switch result {
            case let .success(info):
                self.lastInfo = info
                self.mirror.deviceOK = true
                self.applyScene(info)
                self.ensureSprite(info)
                self.syncBrightness(info)
                let modeIdx = ["auto": 0, "claude": 1, "codex": 2, "net": 3, "music": 4, "btc": 5][info.mode] ?? 0
                self.modeControl.selectedSegment = modeIdx
                let modeText = info.mode == "auto" ? "自动切换"
                    : info.mode == "net" ? "网速曲线"
                    : info.mode == "music" ? "音乐播放"
                    : info.mode == "btc" ? "行情" : "固定显示"
                let endpoint = info.wired ? "USB 串口" : info.ip
                self.statusLabel.stringValue = "\(endpoint) · \(modeText) · 数据 \(info.bridge)"
            case .failure:
                self.mirror.deviceOK = false
                self.mirror.needsDisplay = true
                self.statusLabel.stringValue = DeviceClient.host.isEmpty
                    ? "未设置设备地址（右键菜单 → 设置设备地址）" : "无法连接 \(DeviceClient.host)"
            }
        }
    }

    /// Follow the device's reported brightness (changed via its web page or
    /// another client) — but never while the user is mid-adjustment here.
    private func syncBrightness(_ info: DeviceInfo) {
        guard pendingBrightness == nil,
              Date().timeIntervalSince(lastBrightnessSentAt) > 2 else { return }
        brightnessSlider.doubleValue = Double(info.brightness)
        brightnessValueLabel.stringValue = "\(info.brightness)%"
    }

    /// Quota lines & ring exactly as the firmware computes them from /status.
    private func applyScene(_ info: DeviceInfo) {
        let snap = service.snapshot()
        updateFastAnimation(info: info, snapshot: snap)
        // mirror what's actually on the device screen (effective), so an
        // AUTO device that auto-switched to music shows music here too
        let enteringNet = info.effective == "net" && !mirror.netMode
        mirror.netMode = info.effective == "net"
        mirror.musicMode = info.effective == "music"
        mirror.btcMode = info.effective == "btc"
        if mirror.btcMode {
            mirror.btcFrame = decodeCover(market.frameRGB565, w: 240, h: 240)
            mirror.needsDisplay = true
            return
        }
        if mirror.netMode {
            if enteringNet { mirror.resetNetSweep() } // fresh sweep, like the device's chrome reset
            mirror.needsDisplay = true
            return
        }
        if mirror.musicMode {
            let s = nowPlaying.snapshot
            mirror.musicTitle = s.title
            mirror.musicArtist = s.artist
            mirror.musicElapsed = s.elapsed
            mirror.musicDuration = s.duration
            mirror.musicPlaying = s.playing
            mirror.musicCover = decodeCover(nowPlaying.coverRGB565, w: 128, h: 128)
            mirror.needsDisplay = true
            return
        }
        mirror.showingClaude = info.showing != "codex"
        if mirror.showingClaude {
            let pct = snap.claude.fiveHourPct
                ?? (snap.claude.sessionWindowMin > 0
                    ? 100.0 * Double(snap.claude.sessionMin) / Double(snap.claude.sessionWindowMin) : 0)
            mirror.ringPct = pct
            mirror.ringLevel = .green
            mirror.line1 = "5h " + Self.pctText(pct)
            mirror.line2 = "Weekly " + Self.pctText(snap.claude.sevenDayPct)
            mirror.needsInput = snap.claude.needsInput
            mirror.dailyLine = Self.dailyLine(tokens: snap.claude.tokensToday, cost: snap.claude.costToday)
        } else {
            mirror.ringPct = snap.codex.weeklyPct ?? 0
            mirror.ringLevel = codexWeeklyBorderLevel(snap.codex.weeklyPct)
            mirror.line1 = "Weekly"
            mirror.line2 = Self.pctText(snap.codex.weeklyPct)
            mirror.needsInput = snap.codex.needsInput
            mirror.dailyLine = Self.dailyLine(tokens: snap.codex.tokensToday, cost: snap.codex.costToday)
        }
        mirror.needsDisplay = true
    }

    private static func pctText(_ pct: Double?) -> String {
        guard let p = pct, p >= 0 else { return "-" }
        return "\(Int(p))%"
    }

    private static func dailyLine(tokens: Int, cost: Double?) -> String {
        let tokenText: String
        if tokens >= 1_000_000 { tokenText = String(format: "%.1fM", Double(tokens) / 1_000_000) }
        else if tokens >= 1_000 { tokenText = String(format: "%.1fK", Double(tokens) / 1_000) }
        else { tokenText = String(tokens) }
        return "TODAY \(tokenText)  ~\(cost.map { String(format: "$%.2f", $0) } ?? "$?")"
    }

    private func ensureSprite(_ info: DeviceInfo) {
        let slot = info.showing == "codex" ? "codex" : "claude"
        let w = slot == "claude" ? info.claudeW : info.codexW
        let h = slot == "claude" ? info.claudeH : info.codexH
        let drawW = slot == "claude" ? info.claudeDisplayW : info.codexDisplayW
        let drawH = slot == "claude" ? info.claudeDisplayH : info.codexDisplayH
        if let cached = spriteCache[slot], cached.rev == info.spriteRev {
            mirror.frames = cached.frames
            mirror.spriteW = cached.drawW
            mirror.spriteH = cached.drawH
            return
        }
        guard fetchingSlot != slot else { return }
        fetchingSlot = slot
        DeviceClient.fetchSpriteRaw(slot: slot) { [weak self] result in
            guard let self = self else { return }
            self.fetchingSlot = nil
            if case let .success(data) = result {
                let frames = decodeSpriteFrames(data, w: w, h: h)
                guard !frames.isEmpty else { return }
                self.spriteCache[slot] = (info.spriteRev, frames, w, h, drawW, drawH)
                if (self.lastInfo?.showing == "codex" ? "codex" : "claude") == slot {
                    self.mirror.frames = frames
                    self.mirror.spriteW = drawW
                    self.mirror.spriteH = drawH
                    self.mirror.needsDisplay = true
                }
            }
        }
    }

    private var flashCounter = 0
    private var baselineFastSeq: [String: Int64] = [:]
    private var ludicrousStartedAt: Date?

    private func updateFastAnimation(info: DeviceInfo, snapshot: Snapshot) {
        let agent = info.showing == "codex" ? "codex" : "claude"
        let sequences = ["claude": snapshot.claude.fastTaskSeq, "codex": snapshot.codex.fastTaskSeq]
        guard !baselineFastSeq.isEmpty else { baselineFastSeq = sequences; return }
        let seq = sequences[agent] ?? 0
        let previous = baselineFastSeq[agent] ?? seq
        baselineFastSeq = sequences
        if seq > previous, info.effective != "net", info.effective != "music", info.effective != "btc" {
            ludicrousStartedAt = Date()
            mirror.ludicrousProgress = 0
        }
    }

    private func animTick() {
        guard let info = lastInfo, !mirror.netMode else { return }
        if let started = ludicrousStartedAt {
            let progress = Date().timeIntervalSince(started) / 2.4
            if progress >= 1 {
                ludicrousStartedAt = nil
                mirror.ludicrousProgress = nil
            } else {
                mirror.ludicrousProgress = progress
            }
            mirror.needsDisplay = true
            return
        }

        // ~400ms red-border flash while an approval is pending (device cadence)
        if mirror.needsInput {
            flashCounter += 1
            if flashCounter >= 3 { // 3 * 0.12s ≈ 0.36s
                flashCounter = 0
                mirror.flashOn.toggle()
                mirror.needsDisplay = true
            }
        } else if mirror.flashOn {
            mirror.flashOn = false
            mirror.needsDisplay = true
        }

        guard !mirror.frames.isEmpty else { return }
        let snap = service.snapshot()
        let working = info.showing == "codex"
            ? snap.codex.status == "working" : snap.claude.status == "working"
        if working {
            mirror.frameIdx = (mirror.frameIdx + 1) % mirror.frames.count
        } else if mirror.frameIdx != 0 {
            mirror.frameIdx = 0
        }
        mirror.needsDisplay = true
    }

    @objc private func modeChanged() {
        let mode = ["auto", "claude", "codex", "net", "music", "btc"][max(0, modeControl.selectedSegment)]
        DeviceClient.setDisplayMode(mode) { [weak self] _ in self?.tick() }
    }
}
