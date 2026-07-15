using System.Diagnostics;
using System.Drawing;

namespace AIClockBridge;

// Tray icon: the retro Macintosh device logo. Left click opens a live mirror
// of the ESP8266 screen (MirrorForm); right click opens the control menu with
// usage meters and device remote control. No quota text lives in the tray
// itself.
sealed class TrayAppContext : ApplicationContext
{
    readonly NotifyIcon _trayIcon;
    readonly StatusService _service;
    readonly UsageFetcher _usage;
    readonly int _port;
    readonly MarketMonitor _market;
    readonly MirrorForm _mirror;
    readonly ContextMenuStrip _menu = new();

    readonly ToolStripMenuItem _claudeUsageItem = new("Claude …") { Enabled = false };
    readonly ToolStripMenuItem _codexUsageItem = new("Codex …") { Enabled = false };
    readonly ToolStripMenuItem _deviceInfoItem = new("设备：未设置") { Enabled = false };
    readonly Dictionary<string, ToolStripMenuItem> _modeItems = new();
    readonly ToolStripMenuItem _marketInstrumentMenu = new("行情标的");
    readonly Dictionary<string, ToolStripMenuItem> _marketInstrumentItems = new();
    readonly Dictionary<int, ToolStripMenuItem> _marketRefreshItems = new();

    public TrayAppContext(StatusService service, UsageFetcher usage, NetSpeedMonitor netMonitor,
                          NowPlayingMonitor nowPlaying, MarketMonitor market, int port)
    {
        _service = service;
        _usage = usage;
        _port = port;
        _market = market;
        _mirror = new MirrorForm(service, netMonitor, nowPlaying, market);

        BuildMenu();
        _trayIcon = new NotifyIcon
        {
            Icon = TrayIconFromAsset(),
            Text = "AI Clock Bridge",
            Visible = true,
            ContextMenuStrip = _menu,
        };
        _trayIcon.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left) _mirror.Toggle();
        };
        _menu.Opening += (_, _) =>
        {
            _usage.Refresh();
            RefreshUsageLines();
            _ = RefreshDeviceSection();
            RebuildMarketInstrumentMenu();
            UpdateMarketMenuStates();
        };
        _usage.OnUpdate = RefreshUsageLines;
    }

    /// User-supplied device logo (bezel + dark screen + smiley + green status
    /// dot). Full-color, matching the Mac menu-bar icon.
    static Icon TrayIconFromAsset()
    {
        using var bmp = new Bitmap(MirrorControl.LoadAsset("happy-mac.png"),
                                   new Size(32, 32));
        var handle = bmp.GetHicon();
        // clone so the icon owns its data; the GetHicon handle would leak
        // otherwise but a single tray icon for the app lifetime is fine
        return Icon.FromHandle(handle);
    }

    // MARK: - menu construction

    void BuildMenu()
    {
        _menu.Items.Add(_claudeUsageItem);
        _menu.Items.Add(_codexUsageItem);
        _menu.Items.Add(new ToolStripSeparator());

        _menu.Items.Add(_deviceInfoItem);
        _menu.Items.Add(MakeItem("自动查找并配对设备", async (_, _) => await AutoPairAction()));
        _menu.Items.Add(MakeItem("设置设备地址…", (_, _) => SetDeviceAddress()));
        _menu.Items.Add(MakeItem("打开设备网页", (_, _) => OpenDevicePage()));

        var displayMenu = new ToolStripMenuItem("屏幕显示");
        foreach (var (title, mode) in new[]
        {
            ("自动（谁在干活显示谁）", "auto"), ("固定 Claude", "claude"),
            ("固定 Codex", "codex"), ("网速曲线", "net"), ("音乐播放", "music"), ("行情", "btc"),
        })
        {
            var item = new ToolStripMenuItem(title);
            item.Click += async (_, _) => await SetDisplayMode(mode);
            _modeItems[mode] = item;
            displayMenu.DropDownItems.Add(item);
        }
        _menu.Items.Add(displayMenu);

        var intervalMenu = new ToolStripMenuItem("行情 K线周期");
        foreach (var (title, interval) in new[]
        {
            ("1 分钟", MarketInterval.OneMinute), ("5 分钟", MarketInterval.FiveMinutes),
            ("60 分钟", MarketInterval.OneHour),
        })
        {
            var item = new ToolStripMenuItem(title) { Tag = interval };
            item.Click += (_, _) => { _market.SetInterval(interval); UpdateMarketMenuStates(); };
            intervalMenu.DropDownItems.Add(item);
        }
        _menu.Items.Add(intervalMenu);

        var refreshMenu = new ToolStripMenuItem("行情刷新间隔");
        foreach (var seconds in new[] { 10, 30, 60, 120 })
        {
            var item = new ToolStripMenuItem($"{seconds} 秒");
            item.Click += (_, _) => { _market.SetRefreshInterval(seconds); UpdateMarketMenuStates(); };
            _marketRefreshItems[seconds] = item; refreshMenu.DropDownItems.Add(item);
        }
        _menu.Items.Add(refreshMenu);
        RebuildMarketInstrumentMenu();
        _menu.Items.Add(_marketInstrumentMenu);
        _menu.Items.Add(MakeItem("搜索/添加行情…", (_, _) => SearchMarket()));
        // (屏幕亮度在左键弹出的镜像页底部，做成滑条了)

        _menu.Items.Add(MakeItem("更换桌宠动画…（petdex）", (_, _) => OpenPetPicker()));

        var resetMenu = new ToolStripMenuItem("恢复默认动画");
        foreach (var (title, slot) in new[] { ("Claude 恢复默认", "claude"), ("Codex 恢复默认", "codex") })
        {
            var item = new ToolStripMenuItem(title);
            item.Click += async (_, _) => await ResetSprite(slot);
            resetMenu.DropDownItems.Add(item);
        }
        _menu.Items.Add(resetMenu);

        _menu.Items.Add(MakeItem("把本机设为设备桥接", async (_, _) => await PointBridgeHere()));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(MakeItem("刷新", (_, _) =>
        {
            _usage.Refresh();
            RefreshUsageLines();
            _ = RefreshDeviceSection();
        }));
        _menu.Items.Add(MakeItem("桥接服务地址", (_, _) => ShowAddress()));
        _menu.Items.Add(new ToolStripSeparator());
        _menu.Items.Add(MakeItem("退出", (_, _) =>
        {
            _trayIcon.Visible = false;
            Application.Exit();
        }));
    }

    static ToolStripMenuItem MakeItem(string title, EventHandler onClick)
    {
        var item = new ToolStripMenuItem(title);
        item.Click += onClick;
        return item;
    }

    // MARK: - refresh

    void RefreshUsageLines()
    {
        var snap = _service.Snapshot();
        _claudeUsageItem.Text = UsageLine("Claude", _usage.Claude, "7天", true)
            + TodaySuffix(snap.Claude.TokensToday, snap.Claude.CostToday);
        _codexUsageItem.Text = UsageLine("Codex", _usage.Codex, "周", false)
            + TodaySuffix(snap.Codex.TokensToday, snap.Codex.CostToday);
    }

    static string UsageLine(string name, ProviderUsage u, string weeklyLabel, bool showPrimary)
    {
        if (u.Error != null && u.WeeklyPct == null && (!showPrimary || u.PrimaryPct == null)) return $"{name}：{u.Error}";
        var parts = new List<string>();
        if (showPrimary && u.PrimaryPct.HasValue)
        {
            var s = $"5h {(int)u.PrimaryPct.Value}%";
            if (u.PrimaryResetMin.HasValue) s += $"（{FmtMin(u.PrimaryResetMin.Value)}后重置）";
            parts.Add(s);
        }
        if (u.WeeklyPct.HasValue)
        {
            var s = $"{weeklyLabel} {(int)u.WeeklyPct.Value}%";
            if (u.WeeklyResetMin.HasValue) s += $"（{FmtMin(u.WeeklyResetMin.Value)}）";
            parts.Add(s);
        }
        return parts.Count == 0 ? $"{name}：额度未知" : $"{name}　" + string.Join("　", parts);
    }

    static string TodaySuffix(int tokens, double? cost)
        => $"　今日 {tokens:N0} tok ≈{(cost.HasValue ? $"${cost.Value:F2}" : "$?")}";

    static string FmtMin(int min)
    {
        if (min >= 48 * 60) return $"{min / (24 * 60)}天";
        if (min >= 60) return $"{min / 60}h{(min % 60 > 0 ? $"{min % 60}m" : "")}";
        return $"{min}m";
    }

    async Task RefreshDeviceSection()
    {
        var host = DeviceClient.Host;
        if (host.Length == 0)
        {
            _deviceInfoItem.Text = "设备：未设置地址";
            foreach (var item in _modeItems.Values) item.Checked = false;
            return;
        }
        _deviceInfoItem.Text = $"设备：{host}（连接中…）";
        DeviceInfo info;
        try
        {
            info = await DeviceClient.FetchInfo();
        }
        catch (Exception)
        {
            _deviceInfoItem.Text = $"设备：{host}（无法连接）";
            foreach (var item in _modeItems.Values) item.Checked = false;
            // self-heal: the device may have moved to a new DHCP address;
            // if it recently polled us from a different IP, adopt that.
            var seen = DeviceClient.LastSeenIp;
            if (seen.Length > 0 && !host.StartsWith(seen) && await DeviceClient.VerifyDevice(seen))
            {
                DeviceClient.Host = seen;
                await RefreshDeviceSection();
            }
            return;
        }
        var sprites = new[]
        {
            info.ClaudeCustomSprite ? "C:自定义" : "C:默认",
            info.CodexCustomSprite ? "X:自定义" : "X:默认",
        };
        var showing = info.Mode == "net" ? "网速"
            : info.Mode == "music" ? "音乐"
            : info.Mode == "btc" ? "行情"
            : (info.Showing == "claude" ? "Claude" : "Codex");
        _deviceInfoItem.Text =
            $"设备：{info.Ip} · 正在显示 {showing} · {string.Join(" ", sprites)}";
        foreach (var (mode, item) in _modeItems) item.Checked = mode == info.Mode;
    }

    // MARK: - pairing

    async Task AutoPairAction()
    {
        _deviceInfoItem.Text = "设备：正在查找…";
        var ip = await DeviceClient.AutoPair(msg => _deviceInfoItem.Text = $"设备：{msg}");
        if (ip != null)
        {
            Toast("配对成功", $"已找到设备并配对：{ip}");
        }
        else
        {
            Toast("未找到设备", """
                局域网内没有发现 ESP8266 时钟。请确认：
                1. 设备已通电并连上同一个 WiFi（首次使用需通过 AI-Clock-Setup 热点配网）
                2. 路由器未开启"客户端隔离"
                """);
        }
        await RefreshDeviceSection();
    }

    // MARK: - actions

    void SetDeviceAddress()
    {
        var input = InputDialog.Show(
            "设备地址",
            "ESP8266 时钟的 IP（设备开机时屏幕上会显示，例如 192.168.1.50）",
            DeviceClient.Host, "192.168.1.50");
        if (input == null) return;
        DeviceClient.Host = input.Trim();
        _ = RefreshDeviceSection();
    }

    void OpenDevicePage()
    {
        var url = DeviceClient.BaseUrl;
        if (url == null)
        {
            SetDeviceAddress();
            return;
        }
        Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true });
    }

    async Task SetDisplayMode(string mode)
    {
        try
        {
            await DeviceClient.SetDisplayMode(mode);
            await RefreshDeviceSection();
        }
        catch (Exception e)
        {
            Toast("切换失败", e.Message);
        }
    }

    void RebuildMarketInstrumentMenu()
    {
        _marketInstrumentMenu.DropDownItems.Clear();
        _marketInstrumentItems.Clear();
        foreach (var instrument in _market.Favorites)
        {
            var item = new ToolStripMenuItem(instrument.MenuTitle) { Tag = instrument.Id };
            item.Click += (_, _) => { _market.SetInstrument(instrument); UpdateMarketMenuStates(); };
            _marketInstrumentItems[instrument.Id] = item;
            _marketInstrumentMenu.DropDownItems.Add(item);
        }
        UpdateMarketMenuStates();
    }

    void UpdateMarketMenuStates()
    {
        foreach (var pair in _marketInstrumentItems) pair.Value.Checked = pair.Key == _market.Instrument.Id;
        foreach (var pair in _marketRefreshItems) pair.Value.Checked = pair.Key == _market.RefreshSeconds;
        foreach (ToolStripItem parent in _menu.Items)
        {
            if (parent is not ToolStripMenuItem { Text: "行情 K线周期" } intervalMenu) continue;
            foreach (ToolStripItem child in intervalMenu.DropDownItems)
                if (child is ToolStripMenuItem item && item.Tag is MarketInterval interval)
                    item.Checked = interval == _market.Interval;
        }
    }

    void SearchMarket()
    {
        var input = InputDialog.Show("搜索/添加行情",
            "输入 A股、港股、美股或韩股代码，例如 600519、hk00700、AAPL、kr005930",
            "", "600519 / hk00700 / AAPL / kr005930");
        if (input == null) return;
        var instrument = MarketInstrument.Parse(input);
        if (instrument == null)
        {
            Toast("无法识别", "请使用代码或带市场前缀的代码，例如 sh600519、hk00700、AAPL、kr005930。");
            return;
        }
        var favorite = MessageBox.Show("是否同时收藏该标的？\n\n选择“否”将仅显示，不加入轮换列表。",
            "显示行情", MessageBoxButtons.YesNo, MessageBoxIcon.Question) == DialogResult.Yes;
        if (favorite && !_market.AddFavorite(instrument))
            Toast("收藏已满", "行情标的最多收藏 15 个；本次已仅显示该标的。");
        _market.SetInstrument(instrument);
        RebuildMarketInstrumentMenu();
    }

    void OpenPetPicker()
    {
        if (DeviceClient.Host.Length == 0) SetDeviceAddress();
        PetPickerForm.ShowShared();
    }

    async Task ResetSprite(string slot)
    {
        try
        {
            await DeviceClient.ResetSprite(slot);
            await RefreshDeviceSection();
        }
        catch (Exception e)
        {
            Toast("恢复失败", e.Message);
        }
    }

    async Task PointBridgeHere()
    {
        var ip = DeviceClient.LocalIPv4();
        if (ip == null)
        {
            Toast("失败", "获取本机局域网 IP 失败");
            return;
        }
        var bridge = $"{ip}:{_port}";
        try
        {
            await DeviceClient.SetBridgeHost(bridge);
            Toast("已设置", $"设备将从 http://{bridge}/status 拉取状态");
        }
        catch (Exception e)
        {
            Toast("设置失败", e.Message);
        }
    }

    void ShowAddress()
    {
        var ip = DeviceClient.LocalIPv4() ?? "<本机局域网IP>";
        Toast("桥接服务地址",
              $"http://{ip}:{_port}/status\n\n设备端 Bridge host 填：{ip}:{_port}");
    }

    static void Toast(string title, string text)
    {
        MessageBox.Show(text, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
    }
}

// Small modal prompt, the NSAlert-with-text-field equivalent.
static class InputDialog
{
    public static string Show(string title, string message, string value, string placeholder)
    {
        using var form = new Form
        {
            Text = title,
            FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterScreen,
            MinimizeBox = false,
            MaximizeBox = false,
            ShowInTaskbar = false,
            Font = new Font("Microsoft YaHei UI", 9f),
            ClientSize = new Size(380, 140),
            TopMost = true,
        };
        var label = new Label { Text = message };
        label.SetBounds(14, 12, 352, 40);
        var textBox = new TextBox { Text = value, PlaceholderText = placeholder };
        textBox.SetBounds(14, 58, 352, 24);
        var ok = new Button { Text = "保存", DialogResult = DialogResult.OK };
        ok.SetBounds(196, 96, 80, 28);
        var cancel = new Button { Text = "取消", DialogResult = DialogResult.Cancel };
        cancel.SetBounds(286, 96, 80, 28);
        form.Controls.AddRange(new Control[] { label, textBox, ok, cancel });
        form.AcceptButton = ok;
        form.CancelButton = cancel;
        return form.ShowDialog() == DialogResult.OK ? textBox.Text : null;
    }
}
