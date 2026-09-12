using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 设置页里几组「有核心层命令撑着」的分组。
///
/// <para>越界值一律<b>由核心层拒绝并回滚</b>,UI 不夹紧 —— 悄悄夹紧会让用户
/// 以为设了 8 线程生效了,实际跑的是 4。所以这里失败就把控件恢复成原值 + 显示原因。</para>
/// </summary>
public static class SettingsSections
{
    // ---------------------------------------------------------------- 多线程加载

    public static Control Prefetch(CoreClient core, JsonElement s)
    {
        var hint = Hint();
        var threads = new ComboBox
        {
            Width = 120, MinHeight = 34,
            ItemsSource = new[] { 2, 3, 4 },
            SelectedItem = (int)Math.Clamp(Num(s, "threads"), 2, 4),
        };
        // 缓存上限:核心层认字节,界面按 MB 给档 —— 上下限 64MB~4GB 是核心层定的
        var caches = new[] { 64, 256, 512, 1024, 2048, 4096 };
        var cache = new ComboBox
        {
            Width = 140, MinHeight = 34,
            ItemsSource = caches.Select(m => m >= 1024 ? $"{m / 1024} GB" : $"{m} MB").ToList(),
        };
        var curMb = (int)(Num(s, "cache_bytes") / 1024 / 1024);
        cache.SelectedIndex = Math.Max(0, Array.FindIndex(caches, m => m >= curMb));

        var save = new Button { Classes = { "primary" }, Content = "保存" };
        save.Click += async (_, _) =>
        {
            try
            {
                await core.PrefsSetPrefetchSettings(new
                {
                    settings = new
                    {
                        threads = (int)threads.SelectedItem!,
                        cache_bytes = (long)caches[cache.SelectedIndex] * 1024 * 1024,
                        // servers 是「哪几台服开了多线程加载」。这一版没做逐服开关,
                        // 原样送回去 —— 不送的话核心层会把已开的服务器全清掉。
                        servers = Strings(s, "servers"),
                    },
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        return Group("多线程加载", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("对支持 Range 的直连流并发预取。预取的粒度不是供给的粒度 —— " +
                     "核心层边收边吐,所以开着也不会拖慢起播。"),
                Field("并发数", threads), Field("缓存上限", cache),
                Row(save, hint),
            },
        });
    }

    // ---------------------------------------------------------------- 首页栏目

    /// <summary>
    /// 首页要画哪几条栏目。<b>按服务器</b>存,作用对象是当前登录的那台。
    ///
    /// <para>开着也不保证看得到:服务器上<b>没有</b>合集时那一栏整条不画。
    /// 所以这里的措辞必须是「有就显示」而不是「显示合集栏」——
    /// 后者会让用户在一台没有合集的服务器上打开开关,然后以为功能坏了。</para>
    ///
    /// <para><b>每一台服务器一行</b>。一个「按 X 定制」的开关,
    /// 必须有一处能看到全部 X 的状态 —— 否则用户只能靠一台台切过去才知道自己设了什么。</para>
    /// </summary>
    public static Control Home(CoreClient core, JsonElement h)
    {
        var hint = Hint();
        var rows = new StackPanel { Spacing = 10 };

        /* **每一台服务器一行**,不只是当前登录的那台。
           一个「按 X 定制」的开关,必须有一处能看到全部 X 的状态 ——
           只给当前那台的话,用户在 A 服关掉、到 B 服看见还在,
           只能靠一台台切过去才知道自己到底设了什么。 */
        if (h.TryGetProperty("servers", out var list) && list.ValueKind == JsonValueKind.Array)
        {
            foreach (var it in list.EnumerateArray())
            {
                var srv = Str(it, "server");
                var active = it.TryGetProperty("active", out var ac) && ac.ValueKind == JsonValueKind.True;
                var box = new CheckBox
                {
                    // 标出当前登录的那台 —— 一排服务器名里,用户得先认出自己在哪
                    Content = Str(it, "name") + (active ? "(当前)" : ""),
                    IsChecked = !it.TryGetProperty("enabled", out var en) || en.ValueKind != JsonValueKind.False,
                };
                box.IsCheckedChanged += async (_, _) =>
                {
                    try
                    {
                        // 明着把 server 送过去。不送就是「改当前登录那台」,
                        // 而这张表里点的可能是别的服 —— 那会改错人。
                        await core.PrefsSetHomeSettings(new
                        {
                            settings = new { server = srv, collections_enabled = box.IsChecked == true },
                        });
                        hint.Text = "已保存,回首页生效。";
                    }
                    catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
                };
                rows.Children.Add(box);
            }
        }
        if (rows.Children.Count == 0) rows.Children.Add(Note("还没有登录任何服务器。"));

        /* 自检:把这张表打出来(LP_SELFCHECK_HOMESET=1)。
            判据是**行数和每行的勾选态**,不是截图 —— 这一组排在设置页很靠下的位置,
             一屏根本截不到,而「只画了当前那台」和「两台都画了」在截不到的地方
             长得一模一样。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_HOMESET") == "1")
        {
            var desc = rows.Children.OfType<CheckBox>()
                .Select(b => $"{b.Content}={(b.IsChecked == true ? "开" : "关")}").ToList();
            Console.WriteLine($"[首页栏目] {desc.Count} 台服务器:{string.Join(" | ", desc)}");
        }

        return Group("首页栏目", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("勾上 = 这台服务器有合集时显示合集栏。没有合集的服务器本来就不画这一栏。"),
                rows,
                Note("关掉之后连请求都不发。"),
                hint,
            },
        });
    }

    // ---------------------------------------------------------------- 预加载

    public static Control Preload(CoreClient core, JsonElement s)
    {
        var hint = Hint();
        var on = new CheckBox { Content = "起播前预热文件头", IsChecked = Bool(s, "enabled") };
        var head = new ComboBox
        {
            Width = 120, MinHeight = 34,
            ItemsSource = new[] { 2, 4, 8, 16, 32 },
            SelectedItem = (int)Math.Max(2, Num(s, "head_mb")),
        };

        async void Save()
        {
            try
            {
                await core.PrefsSetPreloadSettings(new
                {
                    settings = new { enabled = on.IsChecked == true, head_mb = (int)head.SelectedItem! },
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }
        on.IsCheckedChanged += (_, _) => Save();
        head.SelectionChanged += (_, _) => Save();

        return Group("预加载", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                // 预热的字节**必须被复用**:只跑热路不留字节,在慢链路上等于白烧带宽
                Note("提前把片头拉到本地缓存。起播时复用同一份字节,不会重下一遍。"),
                on, Field("预热大小", head), hint,
            },
        });
    }

    // ---------------------------------------------------------------- 跨服回写

    public static Control Writeback(CoreClient core, JsonElement s)
    {
        var hint = Hint();
        var on = new CheckBox { Content = "把进度回写到其它服务器", IsChecked = Bool(s, "enabled") };
        var progress = new CheckBox { Content = "连播放位置一起回写", IsChecked = Bool(s, "include_progress") };

        var ranges = new[] { ("所有匹配到的服务器", "all"), ("只回写首次看过的那台", "first"), ("只回写最近看过的那台", "latest") };
        var range = new ComboBox
        {
            Width = 220, MinHeight = 34,
            ItemsSource = ranges.Select(x => x.Item1).ToList(),
            SelectedIndex = Math.Max(0, Array.FindIndex(ranges, x => x.Item2 == Str(s, "range"))),
        };

        async void Save()
        {
            try
            {
                await core.PrefsSetWritebackSettings(new
                {
                    settings = new
                    {
                        enabled = on.IsChecked == true,
                        include_progress = progress.IsChecked == true,
                        range = ranges[Math.Max(0, range.SelectedIndex)].Item2,
                    },
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }
        foreach (var c in new CheckBox[] { on, progress }) c.IsCheckedChanged += (_, _) => Save();
        range.SelectionChanged += (_, _) => Save();

        return Group("跨服务器进度", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("同一部片在多台服务器上都有时,把「看到哪儿了」同步过去。"),
                on, progress, Field("回写范围", range), CrossResume(core), hint,
            },
        });
    }

    /// <summary>
    /// 「起播时取跨服最大进度」开关。
    ///
    /// <para>它和上面那三项是**两个方向**:上面是「看完之后把进度推给别台」,
    /// 这条是「起播时从别台把进度拉回来」。合成一个开关的话,想要单向的人没法配。</para>
    /// </summary>
    private static Control CrossResume(CoreClient core)
    {
        var box = new CheckBox { Content = "起播时取各服务器里最靠后的进度" };
        var hint = Hint();
        // 初值从核心层**读回来**,不是默认一个再灌下去
        _ = Task.Run(async () =>
        {
            try
            {
                var v = await core.AccountGetCrossServerResume();
                Dispatcher.UIThread.Post(() =>
                {
                    box.IsChecked = v.ValueKind == JsonValueKind.True;
                    box.IsCheckedChanged += async (_, _) =>
                    {
                        try
                        {
                            await core.AccountSetCrossServerResume(new { enabled = box.IsChecked == true });
                            hint.Text = "已保存。";
                        }
                        catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
                    };
                });
            }
            catch { /* 读不到就让它保持未勾,别显示一个错的状态 */ }
        });
        return new StackPanel { Spacing = 6, Children = { box, hint } };
    }

    // ---------------------------------------------------------------- 更新

    /// <summary>
    /// 备份 / 搬迁(UI_PC §7.15)。
    ///
    /// <para>导出的载荷里**带着所有服务器的登录凭据**(只是混淆级加密,
    /// 密钥随载荷走)。用户会把它截图发群里 —— 警示必须显眼,不能只写在提示行里。</para>
    ///
    /// <para>**导入是合并不是覆盖**:覆盖的话用户在新机器上已经加好的服务器
    /// 会被静默抹掉,而他以为只是「把老机器上的搬过来」。核心层已经按合并做了,
    /// 界面上也要这么说。</para>
    /// </summary>
    public static Control Transfer(CoreClient core)
    {
        var hint = Hint();
        var box = new TextBox
        {
            Classes = { "field" }, AcceptsReturn = true, Height = 90,
            TextWrapping = TextWrapping.Wrap,
            Watermark = "导出的载荷会出现在这里;导入时把另一台设备上的载荷贴进来",
        };

        var export = new Button { Classes = { "ghost" }, Content = "导出" };
        export.Click += async (_, _) =>
        {
            try
            {
                var r = await core.PrefsConfigExportQr(new { });
                box.Text = Str(r, "payload");
                hint.Text = $"已导出 {Num(r, "count")} 台服务器。{Str(r, "warning")}";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        var import = new Button { Classes = { "ghost" }, Content = "导入(合并)" };
        import.Click += async (_, _) =>
        {
            try
            {
                var r = await core.PrefsConfigImportQr(new { payload = box.Text ?? "" });
                hint.Text = $"导入 {Num(r, "imported")} 台,现在共 {Num(r, "total")} 台。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        return Group("备份 / 搬迁", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("⚠ 导出的内容包含所有服务器的登录凭据,只做了混淆,别公开分享。"),
                box,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { export, import },
                },
                Note("导入是合并:同一台服务器会被覆盖,新机器上原有的其它服务器保留。"),
                hint,
            },
        });
    }

    /// <summary>
    /// 备份与还原(用户 2026-09-08)。**文件档**,不是上面那张二维码卡。
    ///
    /// <para>区别:二维码只装账号、只在两台设备当面搬;这里出一个 <c>.lpbak</c>,
    /// 装账号 <b>+ 设置</b>,PC 和手机读同一份格式,也能交给第三方播放器
    /// (<c>docs/backup-format.md</c>)。「只导设置」那一档给的是
    /// 「把设置发给别人而不发凭据」。</para>
    /// </summary>
    public static Control Backup(CoreClient core)
    {
        var hint = Hint();
        var withAccounts = new CheckBox { Content = "包含服务器地址与账号密码", IsChecked = true };
        var withSettings = new CheckBox { Content = "包含软件设置", IsChecked = true };

        async Task<IStorageProvider?> Sp() =>
            await Task.FromResult(TopLevel.GetTopLevel(hint)?.StorageProvider);

        var export = new Button { Classes = { "ghost" }, Content = "导出到文件…" };
        export.Click += async (_, _) =>
        {
            try
            {
                if (await Sp() is not { } sp) return;
                var name = "LinPlayer-备份-" + DateTime.Now.ToString("yyyyMMdd-HHmmss") + ".lpbak";
                var f = await sp.SaveFilePickerAsync(new FilePickerSaveOptions
                {
                    Title = "导出备份", SuggestedFileName = name,
                    FileTypeChoices = [new FilePickerFileType("LinPlayer 备份") { Patterns = ["*.lpbak", "*.json"] }],
                });
                if (f?.TryGetLocalPath() is not { } path) return;
                // 让核心层直接落盘:内容里带着凭据,少一次跨 FFI 的大字符串就少一处泄漏面
                var r = await core.PrefsBackupExport(new
                {
                    path,
                    accounts = withAccounts.IsChecked == true,
                    settings = withSettings.IsChecked == true,
                });
                hint.Text = $"已导出到 {Str(r, "path")}({Num(r, "bytes")} 字节)。{Str(r, "warning")}";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        var import = new Button { Classes = { "ghost" }, Content = "从文件还原(合并)…" };
        import.Click += async (_, _) =>
        {
            try
            {
                if (await Sp() is not { } sp) return;
                var files = await sp.OpenFilePickerAsync(new FilePickerOpenOptions
                {
                    Title = "选择备份文件", AllowMultiple = false,
                    FileTypeFilter = [new FilePickerFileType("LinPlayer 备份") { Patterns = ["*.lpbak", "*.json", "*.txt"] }],
                });
                if (files.FirstOrDefault()?.TryGetLocalPath() is not { } path) return;
                /* 先看清楚再写。**没有这一步的话「还原」是一个不可逆的盲操作** ——
                   用户点错一个文件,合并进来的账号只能一台一台删回去。 */
                var pv = await core.PrefsBackupPreview(new { path });
                hint.Text = $"这份备份来自 {Str(pv, "from")},{Num(pv, "accounts")} 台服务器"
                    + (pv.TryGetProperty("has_settings", out var hs) && hs.ValueKind == JsonValueKind.True
                        ? "、含软件设置" : "、不含软件设置") + " —— 正在还原…";
                var r = await core.PrefsBackupImport(new
                {
                    path,
                    accounts = withAccounts.IsChecked == true,
                    settings = withSettings.IsChecked == true,
                });
                hint.Text = $"还原 {Num(r, "imported")} 台,现在共 {Num(r, "total")} 台;"
                    + (r.TryGetProperty("settings_restored", out var sr) && sr.ValueKind == JsonValueKind.True
                        ? "软件设置已还原,重启后全部生效。" : "这份备份里没有软件设置。");
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        return Group("备份与还原", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("⚠ 勾了「包含账号密码」的备份文件里有你所有服务器的登录凭据,"
                    + "只做了混淆加密,别公开分享。想把设置发给别人就取消那个勾。"),
                withAccounts,
                withSettings,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { export, import },
                },
                Note("还原是合并:同一台服务器会被更新,这台机器上原有的其它服务器保留。"
                    + "手机端读的是同一份文件,格式说明在 docs/backup-format.md。"),
                hint,
            },
        });
    }

    /// <summary>
    /// CF 优选测速(UI_PC §6)。
    ///
    /// <para>这条命令要跑几十秒(256 个候选 IP × 4 次握手 + 若干次下载测速)。
    /// 按钮必须**当场变成「测速中…」并禁用** —— 一个转圈四十秒毫无反馈的按钮,
    /// 用户会当它卡死了然后反复点,而每点一次就是又一轮几十秒。</para>
    /// </summary>
    public static Control CfSpeed(CoreClient core)
    {
        var hint = Hint();
        var host = new TextBox
        {
            Classes = { "field" }, Width = 260,
            Watermark = "校验域名(通常是你的服务器域名)",
        };
        var results = new StackPanel { Spacing = 6 };
        var run = new Button { Classes = { "ghost" }, Content = "开始测速" };
        run.Click += async (_, _) =>
        {
            run.IsEnabled = false;
            run.Content = "测速中…";
            hint.Text = "正在抽样 CF 边缘并测速,要几十秒。";
            results.Children.Clear();
            try
            {
                var r = await core.PrefsCfSpeedTest(new { validate_host = (host.Text ?? "").Trim() });
                var list = r.TryGetProperty("results", out var rs) && rs.ValueKind == JsonValueKind.Array
                    ? rs.EnumerateArray().ToList() : [];
                if (list.Count == 0)
                {
                    // 「一个都没过校验」多半是这个域名根本不走 CF —— 说清楚,
                    // 别让用户以为是网不好然后一遍遍重测。
                    hint.Text = "没有可用的边缘 IP。如果填了校验域名,先确认它确实走 Cloudflare。";
                    return;
                }
                foreach (var e in list.Take(10))
                {
                    var kb = e.TryGetProperty("download_kbps", out var k) && k.ValueKind == JsonValueKind.Number
                        ? $" · {k.GetDouble() / 1024:0.0} MB/s" : "";
                    results.Children.Add(new TextBlock
                    {
                        Text = $"{Str(e, "ip")} — {Num(e, "latency_ms")} ms{kb}",
                        FontSize = 12.5,
                    });
                }
                hint.Text = $"测出 {list.Count} 个可用边缘,最优在最上面。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
            finally { run.IsEnabled = true; run.Content = "开始测速"; }
        };

        return Group("Cloudflare 优选", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("给走 Cloudflare 的服务器挑一个更快的边缘节点。要跑几十秒。"),
                Field("校验域名", host),
                new StackPanel { Orientation = Orientation.Horizontal, Children = { run } },
                hint, results,
            },
        });
    }

    public static Control Update(CoreClient core, JsonElement s)
    {
        var hint = Hint();
        // 线上值是 `prerelease`,不是 `preview`。写错的那一版选「预览版」会被核心层
        // 顶回「未知的更新渠道」—— 渠道从来就切不过去。
        var channels = new[] { ("正式版", "stable"), ("预览版", "prerelease") };
        var ch = new ComboBox
        {
            Width = 160, MinHeight = 34,
            ItemsSource = channels.Select(x => x.Item1).ToList(),
            SelectedIndex = Math.Max(0, Array.FindIndex(channels, x => x.Item2 == Str(s, "channel"))),
        };
        // 默认**关**(用户 2026-09-12)。不勾就只有下面那颗手动按钮 ——
        // 这是个会自己联网的行为,得用户点头
        var auto = new CheckBox { Content = "启动时自动检查更新", IsChecked = Bool(s, "auto_check") };

        /* GitHub 代理。做成**输入框 + 几颗快填按钮**,不是一个下拉:
           用户点名要「支持用户自定义」,而这类公共代理今天能用明天就 404 ——
           只给下拉等于把人锁在坏掉的那几个上。档位表来自核心层,不在这儿抄一份。 */
        var proxy = new TextBox
        {
            Watermark = "留空 = 直连 GitHub", Text = Str(s, "proxy"), MinHeight = 34,
        };

        async void Save()
        {
            try
            {
                await core.PrefsSetUpdateSettings(new
                {
                    channel = channels[Math.Max(0, ch.SelectedIndex)].Item2,
                    auto_check = auto.IsChecked == true,
                    proxy = proxy.Text ?? "",
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }
        ch.SelectionChanged += (_, _) => Save();
        auto.IsCheckedChanged += (_, _) => Save();
        proxy.LostFocus += (_, _) => Save();

        var picks = new WrapPanel { ItemSpacing = 6, LineSpacing = 6 };
        foreach (var (label, value) in Strings(s, "proxies").Select(x => (x, x)).Prepend(("直连", "")))
        {
            var b = new Button { Classes = { "chip" }, Content = label };
            b.Click += (_, _) => { proxy.Text = value; Save(); };
            picks.Children.Add(b);
        }

        var body = new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Field("更新渠道", ch), auto,
                Note("GitHub 在部分网络下连不上。填一个代理,查版本和下载都会走它。"),
                Field("GitHub 代理", proxy), picks,
            },
        };
        body.Children.Add(new TextBlock
        {
            Text = $"当前版本 {Str(s, "current_version")}",
            Classes = { "dim" }, FontSize = 12,
        });
        /* 立即检查更新 —— 查到了就一路走完:下载、装上、重启。
           「检查更新」只吐一条下载链接的那一版等于半条链路(用户 2026-09-11:
           「不然检查更新也没啥用」)。整条流程在 Updater 里,启动自检共用同一份。 */
        var check = new Button { Classes = { "ghost" }, Content = "检查更新" };
        check.Click += async (_, _) =>
        {
            check.IsEnabled = false;
            hint.Text = "检查中…";
            await Updater.Check(body, core, quiet: false);
            hint.Text = "";
            check.IsEnabled = true;
        };

        // 绿色包解压在写不进去的地方(多半是 Program Files)时覆盖不了。
        // 如实说清楚 —— 摆一个点了必然失败的「立即更新」比没有更糟。
        if (!Bool(s, "can_self_update"))
            body.Children.Add(Note("程序所在的文件夹写不进去,装不了更新。把整个文件夹挪到个人目录下就能自动更新。"));
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10, Children = { check },
        });
        body.Children.Add(hint);

        return Group("更新", body);
    }

    // ---------------------------------------------------------------- 已屏蔽的内容

    /// <summary>
    /// 解除屏蔽的入口。
    ///
    /// <para><b>隐藏类功能必须配一个集中解除列表</b>。没有的话屏蔽就是单向门 ——
    /// 用户屏蔽错了以后再也找不回来(Rust 版为此栽过:媒体库网格故意不滤,
    /// 就是为了留一条解除的路)。</para>
    /// </summary>
    public static Control Blocked(CoreClient core)
    {
        var list = new StackPanel { Spacing = 6 };
        var status = new TextBlock { Classes = { "dim" }, Text = "加载中…" };

        async Task Reload()
        {
            JsonElement r;
            try { r = await core.EmbyBlockedList(new { }); }
            catch (Exception e) { status.Text = LibraryPage.Advice(e); return; }
            var rows = r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().ToList() : [];
            Dispatcher.UIThread.Post(() =>
            {
                list.Children.Clear();
                status.Text = rows.Count == 0 ? "没有屏蔽任何内容。" : $"{rows.Count} 项";
                foreach (var b in rows)
                {
                    var id = Str(b, "id");
                    var un = new Button { Classes = { "ghost" }, Content = "解除" };
                    un.Click += async (_, _) =>
                    {
                        try
                        {
                            await core.EmbySetBlocked(new { id, name = Str(b, "name"), blocked = false });
                            await Reload();
                        }
                        catch (Exception e) { status.Text = LibraryPage.Advice(e); }
                    };
                    list.Children.Add(new StackPanel
                    {
                        Orientation = Orientation.Horizontal, Spacing = 10,
                        Children =
                        {
                            new TextBlock
                            {
                                Text = Str(b, "name") is { Length: > 0 } n ? n : id,
                                Width = 320, VerticalAlignment = VerticalAlignment.Center,
                                TextTrimming = TextTrimming.CharacterEllipsis,
                            },
                            un,
                        },
                    });
                }
            });
        }
        _ = Reload();

        return Group("已屏蔽的内容", new StackPanel
        {
            Spacing = 10,
            Children = { Note("屏蔽掉的条目和媒体库都在这里,随时可以解除。"), status, list },
        });
    }

    // ---------------------------------------------------------------- 日志

    /// <summary>
    /// 日志档位。<b>切换立即生效,不用重启</b>。
    ///
    /// <para>为什么要有这一格:有些现象只在用户那台机器上出现(2026-09-05 的
    /// 「播放页按钮会闪」就是 —— 连拍截图、真指针悬停、属性翻转计数全试过,
    /// 我这边一次都没复现)。复现不了就只能把探针交到用户手上,
    /// 而 <c>LP_*</c> 那些环境变量只有开发机会用。</para>
    ///
    /// <para>默认 warn。debug 是抓现场用的,抓完切回来 —— 它一场播放能写几万行。</para>
    /// </summary>
    public static Control Logging(CoreClient core)
    {
        var pick = new ComboBox
        {
            Width = 210, MinHeight = 32,
            ItemsSource = new[] { "warn(默认,只记异常)", "info(记关键动作)", "debug(记一切,抓现场用)" },
            SelectedIndex = (int)Log.Current,
        };
        var hint = Note(Log.FilePath == "" ? "日志文件建不出来(目录不可写?)" : Log.FilePath);
        pick.SelectionChanged += (_, _) =>
        {
            Log.SetLevel((Log.Level)Math.Max(0, pick.SelectedIndex));
            hint.Text = $"已切到 {Log.Current}。{Log.FilePath}";
        };

        var open = new Button { Classes = { "ghost" }, Content = "打开日志目录" };
        open.Click += async (_, _) =>
        {
            // 白名单在核心层,UI 侧不自己拼 explorer 命令(Linux 壳还要再抄一份)
            try { await core.SystemOpenDataDir(new { sub = "logs" }); }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        return Group("日志", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("排查问题时切到 debug,复现一次,然后把 logs/desktop.log 发出来。" +
                     "切换立即生效,不用重启、也不用重进播放页。" +
                     "查完记得切回 warn —— debug 档一场播放能写几万行。"),
                Field("档位", pick),
                Row(open, hint),
            },
        });
    }

    // ---------------------------------------------------------------- 跳过片头片尾

    /// <summary>
    /// 自动跳过片头片尾。
    ///
    /// <para>这一组以前<b>一个入口都没有</b>:核心层的 skip_intro / skip_outro 齐全、
    /// 单测也写了,默认却是关的 —— 于是这个功能从上线起一次都没跑过。</para>
    /// <para>四个开关分开给:认不认这一段、要不要替用户按、缺数据时能不能联网,
    /// 是三件不同的事,合成一个开关就总有人被迫连带着打开自己不想要的那件。</para>
    /// </summary>
    public static Control SkipSegments(CoreClient core, JsonElement p)
    {
        var hint = Hint();
        var intro = new CheckBox { Content = "识别片头", IsChecked = Bool(p, "skip_intro") };
        var outro = new CheckBox { Content = "识别片尾", IsChecked = Bool(p, "skip_outro") };
        var auto = new CheckBox { Content = "到了就直接跳过去(不用点按钮)", IsChecked = Bool(p, "skip_auto") };
        var online = new CheckBox
        {
            Content = "服务器没有数据时,联网去第三方库查",
            IsChecked = Bool(p, "skip_use_online"),
        };

        async void Save()
        {
            try
            {
                await core.PlayerSetPlaybackPrefs(new
                {
                    settings = new
                    {
                        skip_intro = intro.IsChecked == true,
                        skip_outro = outro.IsChecked == true,
                        skip_auto = auto.IsChecked == true,
                        skip_use_online = online.IsChecked == true,
                    },
                });
                hint.Text = "已保存,下一次起播生效。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }
        foreach (var c in new[] { intro, outro, auto, online }) c.IsCheckedChanged += (_, _) => Save();

        return Group("跳过片头片尾", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                intro, outro, auto, online,
                Note("先用服务器自己刮的章节;没有章节时按 IntroDB → TheIntroDB → AniSkip 的顺序问一遍,"
                     + "缺片头补片头、缺片尾补片尾。三个都是免费接口,不需要账号。"),
                Note("章节和第三方库都对不上的片子,可以在播放页的设置抽屉里手动量一次 ——"
                     + "手动设的按剧存,同一部剧只用设一遍。"),
                hint,
            },
        });
    }

    // ---------------------------------------------------------------- 界面字体

    /// <summary>
    /// 界面字体【用户定 2026-09-08:「让用户可以导入字体更改应用内字体」】。
    ///
    /// <para>存的是**路径**不是字体名:用户导入的字体多半没装进系统,按名字找不到它。</para>
    /// <para>换完**当场生效**,不要求重启 —— 重启才生效的设置,用户第一反应是「没生效」。</para>
    /// </summary>
    public static Control UiFontSection(CoreClient core, JsonElement p)
    {
        var hint = Hint();
        var cur = new TextBlock { Classes = { "dim" }, TextWrapping = TextWrapping.Wrap };
        var pick = new Button { Classes = { "primary" }, Content = "选择字体文件…" };
        var clear = new Button { Classes = { "ghost" }, Content = "恢复默认" };

        void Show(string path)
        {
            cur.Text = path.Length == 0 ? "当前:系统默认字体" : $"当前:{path}";
            clear.IsVisible = path.Length > 0;
        }
        Show(Str(p, "ui_font"));

        async Task Set(string path)
        {
            try
            {
                /* ☠ 先装再存。装不上就**不落库** —— 存了一个装不上的路径,
                   下次开机它会安静地失败,而设置页显示「已换成 xxx」。 */
                if (path.Length > 0 && !UiFont.Apply(path))
                {
                    hint.Text = "这个文件读不了,或者根本不是字体。";
                    return;
                }
                if (path.Length == 0) UiFont.Apply("");
                await core.PrefsSetPrefs(new { ui_font = path });
                Show(path);
                hint.Text = path.Length == 0 ? "已回到默认字体。" : "已换上。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }

        pick.Click += async (_, _) =>
        {
            var top = TopLevel.GetTopLevel(pick);
            if (top is null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "选择界面字体", AllowMultiple = false,
                FileTypeFilter = [new FilePickerFileType("字体文件") { Patterns = ["*.ttf", "*.otf", "*.ttc"] }],
            });
            if (files.Count > 0) await Set(files[0].Path.LocalPath);
        };
        clear.Click += async (_, _) => await Set("");

        return Group("界面字体", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("换掉整个界面的字体。选一个 .ttf / .otf 就行,不需要先装进系统。"),
                cur,
                Row(pick, clear),
                hint,
            },
        });
    }

    // ---------------------------------------------------------------- mpv.conf

    /// <summary>
    /// 用户自己的 mpv.conf【用户定 2026-09-08】。
    ///
    /// <para>直接给一个可编辑的文本框,不做「一行一个开关」的表单:mpv 的选项有上千个,
    /// 会来导 conf 的人本来就知道自己在写什么,而做成表单只会盖住其中十几个。</para>
    /// <para>☠ 决定画面往哪儿画的那几行(<c>vo</c> / <c>wid</c> / <c>gpu-context</c> ……)
    /// <b>会被核心层摘掉</b>。放过去就是全程黑屏且一条错都不报 —— 这句话得写在界面上,
    /// 否则用户会以为是我们没读他的配置。</para>
    /// </summary>
    public static Control MpvConf(CoreClient core)
    {
        var hint = Hint();
        var where = new TextBlock { Classes = { "dim" }, TextWrapping = TextWrapping.Wrap };
        var box = new TextBox
        {
            Classes = { "field" }, AcceptsReturn = true, TextWrapping = TextWrapping.NoWrap,
            MinHeight = 160, MaxHeight = 320, FontFamily = new FontFamily("Consolas, monospace"),
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };

        void Fill(JsonElement r)
        {
            box.Text = Str(r, "text");
            var path = Str(r, "path");
            where.Text = Bool(r, "active") ? $"文件:{path}" : $"还没有配置文件(将写到 {path})";
        }

        _ = Task.Run(async () =>
        {
            try
            {
                var r = await core.PlayerGetMpvConf(new { });
                Dispatcher.UIThread.Post(() => Fill(r));
            }
            catch (Exception e)
            {
                Dispatcher.UIThread.Post(() => hint.Text = LibraryPage.Advice(e));
            }
        });

        var save = new Button { Classes = { "primary" }, Content = "保存" };
        save.Click += async (_, _) =>
        {
            try
            {
                Fill(await core.PlayerSetMpvConf(new { text = box.Text ?? "" }));
                hint.Text = "已保存。下次起播生效。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        var import = new Button { Classes = { "ghost" }, Content = "从文件导入…" };
        import.Click += async (_, _) =>
        {
            var top = TopLevel.GetTopLevel(import);
            if (top is null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "选择 mpv.conf", AllowMultiple = false,
                FileTypeFilter = [new FilePickerFileType("配置文件") { Patterns = ["*.conf", "*.txt", "*"] }],
            });
            if (files.Count == 0) return;
            try
            {
                // 导入只是**把文本填进框里**,存不存由用户按保存 —— 选错文件时
                // 还能直接改回来,不用去数据目录里翻
                box.Text = await File.ReadAllTextAsync(files[0].Path.LocalPath);
                hint.Text = "已读入,按「保存」才生效。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        var clear = new Button { Classes = { "ghost" }, Content = "清空" };
        clear.Click += (_, _) => { box.Text = ""; hint.Text = "按「保存」后回到出厂状态。"; };

        return Group("mpv 配置", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("你自己的 mpv.conf。整份存下来,交给 mpv 解析(profile、include 都照常)。"),
                Note("决定画面往哪儿画的那几行(vo / wid / gpu-context / config-dir / include)"
                     + "会被摘掉 —— 它们能让画面整个没掉,而且一条错都不报。被摘掉的行会写进日志。"),
                where,
                box,
                Row(save, import, clear, hint),
            },
        });
    }

    // ---------------------------------------------------------------- 弹幕

    /// <summary>
    /// 弹幕源与屏蔽词。<b>极简</b>【用户 2026-09-10】:加源是一颗按钮 + 一个两格的弹窗。
    ///
    /// <para><b>顺序有用</b>:搜索结果按这张表的顺序分组(核心层 searchAllGrouped),
    /// 常用的源排第一位就排最上面 —— 没有这一条的话排序就是个摆设。</para>
    /// <para>屏蔽词落核心层:它跟着「备份与还原」走,自动加载和手动搜索得用同一份。</para>
    /// </summary>
    public static Control Danmaku(CoreClient core)
    {
        var official = Note("正在看官方源可不可用…");
        var list = new StackPanel { Spacing = 6 };
        var hint = Hint();
        var words = new TextBox
        {
            AcceptsReturn = true, MinHeight = 96, MaxHeight = 180,
            TextWrapping = TextWrapping.NoWrap, Watermark = "屏蔽词,一行一个",
        };
        var users = Note("");

        List<JsonElement> sources = [];

        async Task Save()
        {
            try { await core.DanmakuSetDanmakuConfig(new { sources }); }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }

        void Paint()
        {
            list.Children.Clear();
            if (sources.Count == 0) { list.Children.Add(Note("还没有自建源")); return; }
            foreach (var (s, i) in sources.Select((s, i) => (s, i)))
            {
                var at = i;
                var up = new Button { Classes = { "ghost" }, Content = "↑", IsEnabled = i > 0 };
                var down = new Button
                {
                    Classes = { "ghost" }, Content = "↓", IsEnabled = i < sources.Count - 1,
                };
                var del = new Button { Classes = { "ghost" }, Content = "删除" };
                async void Move(int d)
                {
                    var item = sources[at];
                    sources.RemoveAt(at);
                    sources.Insert(at + d, item);
                    Paint();
                    await Save();
                }
                up.Click += (_, _) => Move(-1);
                down.Click += (_, _) => Move(1);
                del.Click += async (_, _) => { sources.RemoveAt(at); Paint(); await Save(); };
                list.Children.Add(Row(
                    new TextBlock
                    {
                        Text = Str(s, "name") is { Length: > 0 } n ? n : "(没名字)",
                        Width = 150, VerticalAlignment = VerticalAlignment.Center,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    },
                    new TextBlock
                    {
                        Text = Str(s, "api_url"), Width = 300, Classes = { "dim" },
                        VerticalAlignment = VerticalAlignment.Center,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                    },
                    up, down, del));
            }
        }

        async Task Reload()
        {
            try
            {
                // 三个请求互不依赖 —— 串起来的话这张卡片要等三个往返才画得出来
                var t1 = core.DanmakuGetOfficialDanmaku();
                var t2 = core.DanmakuGetDanmakuConfig();
                var t3 = core.DanmakuGetBlockwords();
                await Task.WhenAll(t1, t2, t3);
                var o = await t1;
                var cfg = await t2;
                var bw = await t3;
                Dispatcher.UIThread.Post(() =>
                {
                    official.Text = Bool(o, "enabled")
                        ? $"弹弹Play 官方源:可用"
                        // ★ 「没有」和「坏了」是两件事,核心层把原因写清楚了,原样转给用户
                        : "弹弹Play 官方源不可用 —— " + Str(o, "reason");
                    sources = cfg.ValueKind == JsonValueKind.Array
                        ? cfg.EnumerateArray().Where(x => !Bool(x, "official")).ToList() : [];
                    Paint();
                    words.Text = string.Join("\n", Strings(bw, "words"));
                    users.Text = $"屏蔽用户 {Strings(bw, "users").Length} 个";
                });
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }
        _ = Reload();

        var add = new Button { Classes = { "primary" }, Content = "添加源" };
        add.Click += async (_, _) =>
        {
            /* 鉴权方式**不问用户** —— 他也不知道什么是 pathToken。核心层从地址里推
               (setDanmakuConfig 里的 DeriveAuth),推错了也比给一个四选一的下拉框强:
               那个框选错了同样不报错,只是搜不到。 */
            var nameBox = new TextBox { Watermark = "弹幕源名字", MinHeight = 32 };
            var urlBox = new TextBox { Watermark = "弹幕源链接", MinHeight = 32, MinWidth = 360 };
            var body = new StackPanel { Spacing = 10, Children = { nameBox, urlBox } };
            if (!await Dialogs.Show(add, "添加弹幕源", body, "添加", "取消")) return;
            var u = (urlBox.Text ?? "").Trim();
            if (u.Length == 0) { hint.Text = "地址是空的,没加。"; return; }
            sources.Add(JsonSerializer.SerializeToElement(new
            {
                id = "u" + DateTimeOffset.UtcNow.ToUnixTimeMilliseconds(),
                name = (nameBox.Text ?? "").Trim() is { Length: > 0 } n ? n : "自建源",
                api_url = u,
            }));
            Paint();
            await Save();
        };

        var saveWords = new Button { Classes = { "primary" }, Content = "保存屏蔽词" };
        saveWords.Click += async (_, _) =>
        {
            var ws = (words.Text ?? "").Split('\n')
                .Select(x => x.Trim()).Where(x => x.Length > 0).Distinct().ToArray();
            try
            {
                await core.DanmakuSetBlockwords(new { words = ws });
                hint.Text = $"已保存 {ws.Length} 个屏蔽词。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        var import = new Button { Classes = { "ghost" }, Content = "导入弹弹Play 屏蔽表" };
        import.Click += async (_, _) =>
        {
            var top = TopLevel.GetTopLevel(import);
            if (top is null) return;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "选一份弹弹Play 的屏蔽列表",
                FileTypeFilter = [new FilePickerFileType("屏蔽表") { Patterns = ["*.xml"] }],
            });
            if (files.Count == 0) return;
            try
            {
                await using var st = await files[0].OpenReadAsync();
                using var sr = new StreamReader(st);
                var xml = await sr.ReadToEndAsync();
                // 合并落库由核心层做 —— 两端各写一份合并逻辑,漏掉去重的那边会越导越长
                var r = await core.DanmakuImportBlocklist(new { xml });
                hint.Text = $"导入 {Num(r, "total_words"):0} 个词、{Num(r, "total_users"):0} 个用户。";
                await Reload();
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        return Group("弹幕", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                official,
                list,
                add,
                new TextBlock { Text = "屏蔽", Classes = { "h2" }, Margin = new Thickness(0, 10, 0, 0) },
                words,
                Row(saveWords, import),
                users,
                hint,
            },
        });
    }

    // ---------------------------------------------------------------- 小工具

    private static Control Group(string title, Control body) => new Border
    {
        Classes = { "card" }, Padding = new Thickness(18, 18),
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Child = new StackPanel
        {
            Spacing = 10,
            Children = { new TextBlock { Text = title, Classes = { "h2" } }, body },
        },
    };

    /// <summary>一行「说明 + 控件」。 标签右对齐、列宽 88 —— 三处 Field 必须一致,
    /// 口径见 <see cref="SettingsPage"/> 里那一份的注释。</summary>
    private static Control Field(string label, Control input) => new StackPanel
    {
        Orientation = Orientation.Horizontal, Spacing = 10,
        Children =
        {
            new TextBlock
            {
                Text = label, Width = 88, TextAlignment = TextAlignment.Right,
                VerticalAlignment = VerticalAlignment.Center,
            },
            input,
        },
    };

    private static Control Row(params Control[] cs)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        foreach (var c in cs) p.Children.Add(c);
        return p;
    }

    private static TextBlock Hint() => new()
    {
        Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap,
    };

    private static TextBlock Note(string t) => new()
    {
        Text = t, FontSize = 12, TextWrapping = TextWrapping.Wrap,
        Foreground = Tok.Of("Ink3"),
    };

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
    private static string[] Strings(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x != "").ToArray() : [];
}
