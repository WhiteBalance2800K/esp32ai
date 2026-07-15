import AppKit

// Menu-bar item: a retro Macintosh icon (drawn in code, template so it adapts
// to light/dark menu bars). Left click opens a live mirror of the ESP8266
// screen (MirrorPopover); right click opens the control menu with usage
// meters and device remote control. No quota text lives in the bar itself.
final class MenuBarController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let service: StatusService
    private let usage: UsageFetcher
    private let port: UInt16
    private let market: MarketMonitor
    private let controlMenu = NSMenu()
    private let mirrorPopover: MirrorPopoverController

    private let claudeUsageItem = NSMenuItem(title: "Claude …", action: nil, keyEquivalent: "")
    private let codexUsageItem = NSMenuItem(title: "Codex …", action: nil, keyEquivalent: "")
    private let deviceInfoItem = NSMenuItem(title: "设备：未设置", action: nil, keyEquivalent: "")
    private var modeItems: [String: NSMenuItem] = [:]
    private var marketInstrumentItems: [String: NSMenuItem] = [:]
    private let instrumentMenu = NSMenu()

    init(service: StatusService, usage: UsageFetcher, netMonitor: NetSpeedMonitor,
         nowPlaying: NowPlayingMonitor, market: MarketMonitor, port: UInt16) {
        self.service = service
        self.usage = usage
        self.port = port
        self.market = market
        self.mirrorPopover = MirrorPopoverController(service: service, netMonitor: netMonitor,
                                                     nowPlaying: nowPlaying, market: market)
        super.init()
        buildMenu()
        if let button = statusItem.button {
            button.image = Self.retroMacIcon()
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    /// User-supplied device logo (bezel + dark screen + smiley + green status
    /// dot). Full-color, so NOT a template image — it keeps its colors in
    /// both light and dark menu bars.
    private static func retroMacIcon() -> NSImage {
        guard let img = Bundle.aiClockResources.image(forResource: "happy-mac") else {
            return NSImage(size: NSSize(width: 18, height: 18))
        }
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = false
        return img
    }

    /// Left click -> mirror popover; right click -> control menu.
    @objc private func statusItemClicked() {
        guard let button = statusItem.button else { return }
        let event = NSApp.currentEvent
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            statusItem.menu = controlMenu
            button.performClick(nil)
            statusItem.menu = nil // detach so left click keeps toggling the popover
        } else {
            mirrorPopover.toggle(relativeTo: button)
        }
    }

    // MARK: - menu construction

    private func buildMenu() {
        let menu = controlMenu
        menu.delegate = self

        claudeUsageItem.isEnabled = false
        codexUsageItem.isEnabled = false
        menu.addItem(claudeUsageItem)
        menu.addItem(codexUsageItem)
        menu.addItem(.separator())

        deviceInfoItem.isEnabled = false
        menu.addItem(deviceInfoItem)

        menu.addItem(makeItem("自动查找并配对设备", #selector(autoPairAction)))
        menu.addItem(makeItem("设置设备地址…", #selector(setDeviceAddress)))
        menu.addItem(makeItem("打开设备网页", #selector(openDevicePage)))

        let displayMenu = NSMenu()
        for (title, mode) in [("自动（谁在干活显示谁）", "auto"), ("固定 Claude", "claude"),
                              ("固定 Codex", "codex"), ("网速曲线", "net"),
                              ("音乐播放", "music"), ("行情", "btc")] {
            let item = NSMenuItem(title: title, action: #selector(setDisplayMode(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode
            modeItems[mode] = item
            displayMenu.addItem(item)
        }
        let displayItem = NSMenuItem(title: "屏幕显示", action: nil, keyEquivalent: "")
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)

        let btcIntervalMenu = NSMenu()
        for interval in MarketInterval.allCases {
            let item = NSMenuItem(title: interval.rawValue, action: #selector(setBTCInterval(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval.rawValue
            item.state = market.snapshot.interval == interval ? .on : .off
            btcIntervalMenu.addItem(item)
        }
        let btcIntervalItem = NSMenuItem(title: "行情 K线周期", action: nil, keyEquivalent: "")
        btcIntervalItem.submenu = btcIntervalMenu
        menu.addItem(btcIntervalItem)

        rebuildMarketInstrumentMenu()
        let instrumentItem = NSMenuItem(title: "行情标的", action: nil, keyEquivalent: "")
        instrumentItem.submenu = instrumentMenu
        menu.addItem(instrumentItem)
        menu.addItem(makeItem("搜索/添加行情…", #selector(searchMarket)))
        // (屏幕亮度在左键弹出的镜像页底部，做成滑条了)

        menu.addItem(makeItem("更换桌宠动画…（petdex）", #selector(openPetPicker)))

        let resetMenu = NSMenu()
        for (title, slot) in [("Claude 恢复默认", "claude"), ("Codex 恢复默认", "codex")] {
            let item = NSMenuItem(title: title, action: #selector(resetSprite(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = slot
            resetMenu.addItem(item)
        }
        let resetItem = NSMenuItem(title: "恢复默认动画", action: nil, keyEquivalent: "")
        resetItem.submenu = resetMenu
        menu.addItem(resetItem)

        menu.addItem(makeItem("把本机设为设备桥接", #selector(pointBridgeHere)))
        menu.addItem(.separator())
        menu.addItem(makeItem("刷新", #selector(refreshAction), key: "r"))
        menu.addItem(makeItem("桥接服务地址", #selector(showAddress)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    private func makeItem(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    // MARK: - refresh

    func menuWillOpen(_ menu: NSMenu) {
        usage.refresh()
        refreshUsageLines()
        refreshDeviceSection()
        rebuildMarketInstrumentMenu()
        updateMarketInstrumentStates()
    }

    private func refreshUsageLines() {
        claudeUsageItem.title = Self.usageLine(name: "Claude", u: usage.claude, weeklyLabel: "7天",
                                               showPrimary: true)
        codexUsageItem.title = Self.usageLine(name: "Codex", u: usage.codex, weeklyLabel: "周",
                                              showPrimary: false)
        let snap = service.snapshot()
        claudeUsageItem.title += Self.todaySuffix(tokens: snap.claude.tokensToday, cost: snap.claude.costToday)
        codexUsageItem.title += Self.todaySuffix(tokens: snap.codex.tokensToday, cost: snap.codex.costToday)
    }

    private static func usageLine(name: String, u: ProviderUsage, weeklyLabel: String,
                                  showPrimary: Bool) -> String {
        let hasQuota = u.weeklyPct != nil || (showPrimary && u.primaryPct != nil)
        if let err = u.error, !hasQuota { return "\(name)：\(err)" }
        var parts: [String] = []
        if showPrimary, let p = u.primaryPct {
            var s = "5h \(Int(p))%"
            if let m = u.primaryResetMin { s += "（\(fmtMin(m))后重置）" }
            parts.append(s)
        }
        if let p = u.weeklyPct {
            var s = "\(weeklyLabel) \(Int(p))%"
            if let m = u.weeklyResetMin { s += "（\(fmtMin(m))）" }
            parts.append(s)
        }
        return parts.isEmpty ? "\(name)：额度未知" : "\(name)　" + parts.joined(separator: "　")
    }

    private static func fmtMin(_ min: Int) -> String {
        if min >= 48 * 60 { return "\(min / (24 * 60))天" }
        if min >= 60 { return "\(min / 60)h\(min % 60 > 0 ? "\(min % 60)m" : "")" }
        return "\(min)m"
    }

    private static func todaySuffix(tokens: Int, cost: Double?) -> String {
        let amount = cost.map { String(format: "$%.2f", $0) } ?? "$?"
        return "　今日 \(tokens.formatted()) tok ≈\(amount)"
    }

    private func refreshDeviceSection() {
        let host = DeviceClient.host
        guard !host.isEmpty || DeviceClient.wiredAvailable else {
            deviceInfoItem.title = "设备：未设置地址"
            modeItems.values.forEach { $0.state = .off }
            return
        }
        deviceInfoItem.title = host.isEmpty ? "设备：USB 串口（连接中…）" : "设备：\(host)（连接中…）"
        DeviceClient.fetchInfo { [weak self] result in
            guard let self = self else { return }
            switch result {
            case let .success(info):
                let sprites = [info.claudeCustomSprite ? "C:自定义" : "C:默认",
                               info.codexCustomSprite ? "X:自定义" : "X:默认"]
                let showing = info.mode == "net" ? "网速"
                    : info.mode == "music" ? "音乐"
                    : info.mode == "btc" ? "行情"
                    : (info.showing == "claude" ? "Claude" : "Codex")
                let endpoint = info.wired ? "USB 串口" : info.ip
                self.deviceInfoItem.title =
                    "设备：\(endpoint) · 正在显示 \(showing) · \(sprites.joined(separator: " "))"
                for (mode, item) in self.modeItems { item.state = mode == info.mode ? .on : .off }
            case .failure:
                self.deviceInfoItem.title = host.isEmpty
                    ? "设备：USB 串口（无法读取状态）"
                    : "设备：\(host)（无法连接）"
                self.modeItems.values.forEach { $0.state = .off }
                // self-heal: the device may have moved to a new DHCP address;
                // if it recently polled us from a different IP, adopt that.
                let seen = DeviceClient.lastSeenIP
                if !seen.isEmpty, !host.hasPrefix(seen) {
                    DeviceClient.verifyDevice(ip: seen) { ok in
                        if ok {
                            DeviceClient.host = seen
                            self.refreshDeviceSection()
                        }
                    }
                }
            }
        }
    }

    // MARK: - pairing

    @objc private func autoPairAction() {
        deviceInfoItem.title = "设备：正在查找…"
        DeviceClient.autoPair(progress: { [weak self] msg in
            self?.deviceInfoItem.title = "设备：\(msg)"
        }, completion: { [weak self] ip in
            if let ip = ip {
                Self.toast("配对成功", "已找到设备并配对：\(ip)")
                self?.refreshDeviceSection()
            } else {
                Self.toast("未找到设备", """
                局域网内没有发现 ESP8266 时钟。请确认：
                1. 设备已通电并连上同一个 WiFi（首次使用需通过 AI-Clock-Setup 热点配网）
                2. 路由器未开启"客户端隔离"
                """)
                self?.refreshDeviceSection()
            }
        })
    }

    // MARK: - actions

    @objc private func refreshAction() {
        usage.refresh()
        refreshUsageLines()
        refreshDeviceSection()
    }

    @objc private func setDeviceAddress() {
        let alert = NSAlert()
        alert.messageText = "设备地址"
        alert.informativeText = "ESP8266 时钟的 IP（设备开机时屏幕上会显示，例如 192.168.1.50）"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        input.stringValue = DeviceClient.host
        input.placeholderString = "192.168.1.50"
        alert.accessoryView = input
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            DeviceClient.host = input.stringValue.trimmingCharacters(in: .whitespaces)
            refreshDeviceSection()
        }
    }

    @objc private func openDevicePage() {
        guard let url = DeviceClient.baseURL else {
            setDeviceAddress()
            return
        }
        NSWorkspace.shared.open(url)
    }

    @objc private func setDisplayMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? String else { return }
        DeviceClient.setDisplayMode(mode) { [weak self] error in
            if let error = error {
                Self.toast("切换失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func setBTCInterval(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let interval = MarketInterval(rawValue: raw) else { return }
        market.setInterval(interval)
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    }

    @objc private func setMarketInstrument(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let instrument = market.favorites.first(where: { $0.id == id }) else { return }
        market.setInstrument(instrument)
        updateMarketInstrumentStates()
    }

    @objc private func searchMarket() {
        let alert = NSAlert()
        alert.messageText = "搜索/添加行情"
        alert.informativeText = "输入 A 股、港股、美股或韩股代码；可带 sh/sz/bj/hk/us/kr 前缀。例：600519、hk00700、AAPL、kr005930"
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.placeholderString = "600519 / hk00700 / AAPL / kr005930"
        alert.accessoryView = input
        alert.addButton(withTitle: "显示并收藏")
        alert.addButton(withTitle: "仅显示")
        alert.addButton(withTitle: "取消")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn || response == .alertSecondButtonReturn else { return }
        guard let instrument = MarketInstrument.parse(input.stringValue) else {
            Self.toast("无法识别", "请使用代码或带市场前缀的代码，例如 sh600519、hk00700、AAPL、kr005930。")
            return
        }
        if response == .alertFirstButtonReturn, !market.addFavorite(instrument) {
            Self.toast("收藏已满", "行情标的最多收藏 15 个；本次已仅显示该标的。")
        }
        market.setInstrument(instrument)
        rebuildMarketInstrumentMenu()
        updateMarketInstrumentStates()
    }

    private func rebuildMarketInstrumentMenu() {
        instrumentMenu.removeAllItems()
        marketInstrumentItems.removeAll()
        for instrument in market.favorites {
            let item = NSMenuItem(title: instrument.menuTitle, action: #selector(setMarketInstrument(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = instrument.id
            marketInstrumentItems[instrument.id] = item
            instrumentMenu.addItem(item)
        }
        updateMarketInstrumentStates()
    }

    private func updateMarketInstrumentStates() {
        let selected = market.instrument.id
        marketInstrumentItems.values.forEach { $0.state = .off }
        marketInstrumentItems[selected]?.state = .on
    }

    @objc private func openPetPicker() {
        if DeviceClient.host.isEmpty { setDeviceAddress() }
        PetPickerWindowController.shared.show()
    }

    @objc private func resetSprite(_ sender: NSMenuItem) {
        guard let slot = sender.representedObject as? String else { return }
        DeviceClient.resetSprite(slot: slot) { [weak self] error in
            if let error = error {
                Self.toast("恢复失败", error.localizedDescription)
            } else {
                self?.refreshDeviceSection()
            }
        }
    }

    @objc private func pointBridgeHere() {
        guard let ip = DeviceClient.localIPv4() else {
            Self.toast("失败", "获取本机局域网 IP 失败")
            return
        }
        let bridge = "\(ip):\(port)"
        DeviceClient.setBridgeHost(bridge) { error in
            if let error = error {
                Self.toast("设置失败", error.localizedDescription)
            } else {
                Self.toast("已设置", "设备将从 http://\(bridge)/status 拉取状态")
            }
        }
    }

    @objc private func showAddress() {
        let ip = DeviceClient.localIPv4() ?? "<本机局域网IP>"
        Self.toast("桥接服务地址", "http://\(ip):\(port)/status\n\n设备端 Bridge host 填：\(ip):\(port)")
    }

    private static func toast(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
