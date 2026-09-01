using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>搜索页。</summary>
public sealed class SearchPage : PageBase
{
    public SearchPage(CoreClient core)
    {
        var box = new TextBox { Classes = { "field" }, Watermark = "搜片名、剧名、演员…", Width = 420 };
        var go = new Button { Classes = { "primary" }, Content = "搜索" };
        // ★ 「包括集」默认**关**:开着的话搜一部剧会先刷出几十条「第 N 集」,
        //   把剧本身挤到屏幕外。开关本身要有,不然找某一集就没法搜。
        var withEps = new CheckBox { Content = "包括分集", IsChecked = false };
        var status = Dim("");
        var results = new WrapPanel();

        var body = new StackPanel
        {
            Spacing = 14,
            Children =
            {
                H1("搜索"),
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { box, go, withEps },
                },
                status, results,
            },
        };
        Content = Scrolled(body);

        async Task Run()
        {
            var q = (box.Text ?? "").Trim();
            results.Children.Clear();
            if (q == "") { status.Text = "输入点什么再搜。"; return; }
            status.Text = "搜索中…";
            try
            {
                var s = Nav.Session!;
                // ★ types 必须**显式传**:关着「包括分集」时前端不传的话核心层会全要,
                //   开关就成了摆设(Rust 版栽过,聚合那条也要一起带)。
                var res = withEps.IsChecked == true
                    ? await core.EmbySearch(new { s.server, s.token, s.user_id, s.device_id, query = q })
                    : await core.EmbySearch(new
                    {
                        s.server, s.token, s.user_id, s.device_id, query = q,
                        types = new[] { "Movie", "Series" },
                    });
                var items = res.ValueKind == JsonValueKind.Array
                    ? res.EnumerateArray().Select(CardItem.From).ToList() : [];
                Dispatcher.UIThread.Post(() =>
                {
                    status.Text = items.Count == 0 ? $"没有搜到「{q}」。" : $"{items.Count} 条结果";
                    foreach (var it in items)
                        results.Children.Add(new Card(core, s.server, it, false,
                            LibraryPage.OpenDetail(core, s.server))
                        { Margin = new Thickness(0, 0, 14, 16) });
                });
            }
            catch (Exception e) { status.Text = $"搜索失败:{LibraryPage.Advice(e)}"; }
        }

        go.Click += async (_, _) => await Run();
        box.KeyDown += async (_, e) => { if (e.Key == Avalonia.Input.Key.Enter) await Run(); };
    }
}

/// <summary>收藏页。</summary>
public sealed class FavoritesPage : PageBase
{
    public FavoritesPage(CoreClient core)
    {
        var rows = new StackPanel { Spacing = 14, Children = { H1("收藏") } };
        var busy = Dim("加载中…");
        rows.Children.Add(busy);
        Content = Scrolled(rows);

        _ = Task.Run(async () =>
        {
            try
            {
                var s = Nav.Session!;
                var res = await core.EmbyListFavorites(new { s.server, s.token, s.user_id, s.device_id });
                var items = res.ValueKind == JsonValueKind.Array
                    ? res.EnumerateArray().Select(CardItem.From).ToList() : [];
                Dispatcher.UIThread.Post(() =>
                {
                    rows.Children.Remove(busy);
                    if (items.Count == 0) { rows.Children.Add(Dim("还没有收藏。详情页点「收藏」就会出现在这里。")); return; }
                    rows.Children.Add(LibraryPage.Grid(core, s.server, items, false));
                });
            }
            catch (Exception e)
            {
                Dispatcher.UIThread.Post(() => busy.Text = $"加载失败:{LibraryPage.Advice(e)}");
            }
        });
    }
}

/// <summary>
/// 设置页。<b>只放已经接了核心层命令的那几项</b> ——
/// 摆一堆点了不生效的开关比没有更糟。
/// </summary>
public sealed class SettingsPage : PageBase
{
    public SettingsPage(CoreClient core)
    {
        // ★ 分组横向铺开(卡固定 720 宽):竖着排的话十来组要滚三屏,
        //   而「设置里有什么」本身就得一眼看全。
        var groups = new WrapPanel();
        var busy = Dim("加载中…");
        var rows = new StackPanel { Spacing = 18, Children = { H1("设置"), busy, groups } };
        Content = Scrolled(rows);

        _ = Task.Run(async () =>
        {
            try
            {
                // ★ 各组**各拉各的**,一组失败不该把整页拖红 ——
                //   有的组对应的命令在某些平台上就是没有的。
                var p = await core.PrefsGetPrefs(new { });
                var paths = await core.SystemDataPaths(new { });
                var prefetch = await Safe(() => core.PrefsGetPrefetchSettings(new { }));
                var preload = await Safe(() => core.PrefsGetPreloadSettings(new { }));
                var writeback = await Safe(() => core.PrefsGetWritebackSettings(new { }));
                var update = await Safe(() => core.PrefsGetUpdateSettings(new { }));

                Dispatcher.UIThread.Post(() =>
                {
                    rows.Children.Remove(busy);
                    void Add(Control c)
                    {
                        c.Margin = new Thickness(0, 0, 18, 18);
                        groups.Children.Add(c);
                    }
                    Add(TrackPrefs(core, p));
                    Add(Playback(core, p));
                    if (prefetch is { } pf) Add(SettingsSections.Prefetch(core, pf));
                    if (preload is { } pl) Add(SettingsSections.Preload(core, pl));
                    if (writeback is { } wb) Add(SettingsSections.Writeback(core, wb));
                    if (update is { } up) Add(SettingsSections.Update(core, up));
                    Add(SettingsSections.Blocked(core));
                    Add(Storage(core, paths));
                });
            }
            catch (Exception e)
            {
                Dispatcher.UIThread.Post(() => busy.Text = $"加载失败:{LibraryPage.Advice(e)}");
            }
        });
    }

    /// <summary>拉一组设置,拉不到就返回 null —— 那一组不画,别把整页拖红。</summary>
    private static async Task<JsonElement?> Safe(Func<Task<JsonElement>> f)
    {
        try { return await f(); }
        catch { return null; }
    }

    private static Control TrackPrefs(CoreClient core, JsonElement p)
    {
        var sub = new TextBox { Classes = { "field" }, Width = 220, Text = Str(p, "sub_lang") };
        var audio = new TextBox { Classes = { "field" }, Width = 220, Text = Str(p, "audio_lang") };
        var on = new CheckBox { Content = "默认开启字幕", IsChecked = Bool(p, "sub_enabled") };
        var hint = Dim("");

        var save = new Button { Classes = { "primary" }, Content = "保存" };
        save.Click += async (_, _) =>
        {
            try
            {
                // ★ 只送这三项。核心层也只改这三项 ——
                //   整体覆盖会把跨服续播之类的悄悄重置成默认值。
                await core.PrefsSetPrefs(new
                {
                    sub_lang = Nz(sub.Text), audio_lang = Nz(audio.Text),
                    sub_enabled = on.IsChecked == true,
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        return Card("选轨偏好", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Dim("三字母语言码,如 chi / jpn / eng。留空表示不指定。"),
                Field("字幕语言", sub), Field("音频语言", audio), on,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { save, hint } },
            },
        });
    }

    private static Control Playback(CoreClient core, JsonElement p)
    {
        var hint = Dim("");
        var hw = new ComboBox
        {
            Width = 220,
            ItemsSource = new[] { "auto-safe", "d3d11va", "d3d11va-copy", "no" },
            SelectedItem = Str(p, "hwdec") is { Length: > 0 } h ? h : "auto-safe",
        };
        hw.SelectionChanged += async (_, _) =>
        {
            try
            {
                await core.PlayerSetHwdec(new { hwdec = hw.SelectedItem as string ?? "auto-safe" });
                hint.Text = "已保存,下一次起播生效。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        // 外部播放器。
        //
        // ★ 系统文件对话框由**宿主**弹(核心层是个库,弹不了对话框 ——
        //   system.pickFile 在核心层就是明着返回 E_UNSUPPORTED 的)。
        //   挑完把路径交给 player.setPlaybackPrefs,由核心层校验它真的存在:
        //   存一个打不开的路径,等到起播时才炸,那时用户早忘了自己填过什么。
        var ext = new TextBox { Classes = { "field" }, Width = 300, IsReadOnly = true };
        var pick = new Button { Classes = { "ghost" }, Content = "选择…" };
        var clearExt = new Button { Classes = { "ghost" }, Content = "清除" };
        _ = Task.Run(async () =>
        {
            var got = await Safe(() => core.PlayerGetPlaybackPrefs(new { }));
            if (got is { } g)
                Dispatcher.UIThread.Post(() => ext.Text = Str(g, "external_player"));
        });
        async Task SetExt(string path)
        {
            try
            {
                await core.PlayerSetPlaybackPrefs(new { settings = new { external_player = path } });
                ext.Text = path;
                hint.Text = path == "" ? "已清除外部播放器。" : "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }
        pick.Click += async (_, _) =>
        {
            var top = TopLevel.GetTopLevel(pick);
            if (top is null) return;
            // ★ 后缀过滤要**按平台给**:`*.exe` 在 Linux 上会把列表滤空,
            //   而用户看到的是一个「什么都没有」的对话框。
            var types = OperatingSystem.IsWindows()
                ? new List<FilePickerFileType> { new("可执行文件") { Patterns = ["*.exe"] } }
                : null;
            var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
            {
                Title = "选择外部播放器", AllowMultiple = false, FileTypeFilter = types,
            });
            if (files.Count > 0) await SetExt(files[0].Path.LocalPath);
        };
        clearExt.Click += async (_, _) => await SetExt("");

        return Card("播放", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Field("硬件解码", hw),
                Field("外部播放器", new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 8,
                    Children = { ext, pick, clearExt },
                }),
                Dim("设了之后,详情页会多一个「用外部播放器打开」。"),
                hint,
            },
        });
    }

    private static Control Storage(CoreClient core, JsonElement paths)
    {
        var size = Dim("统计中…");
        _ = Task.Run(async () =>
        {
            try
            {
                var r = await core.SystemCacheSize(new { });
                var bytes = r.ValueKind == JsonValueKind.Number ? r.GetInt64()
                    : r.TryGetProperty("bytes", out var b) ? b.GetInt64() : 0;
                Dispatcher.UIThread.Post(() => size.Text = $"缓存占用 {bytes / 1024.0 / 1024:0.0} MB");
            }
            catch (Exception e) { Dispatcher.UIThread.Post(() => size.Text = LibraryPage.Advice(e)); }
        });

        var clear = new Button { Classes = { "ghost" }, Content = "清理缓存" };
        clear.Click += async (_, _) =>
        {
            try { await core.SystemClearCache(new { }); size.Text = "已清理。"; }
            catch (Exception e) { size.Text = LibraryPage.Advice(e); }
        };

        // ★ 打开目录交给核心层(system.openDataDir):UI 里自己拼 explorer 的话,
        //   Linux 壳上就得再抄一份,而且**白名单在核心层**,绕过去等于没有白名单。
        var open = new Button { Classes = { "ghost" }, Content = "打开数据目录" };
        open.Click += async (_, _) =>
        {
            try { await core.SystemOpenDataDir(new { }); }
            catch (Exception e) { size.Text = LibraryPage.Advice(e); }
        };

        var root = paths.TryGetProperty("root", out var r2) ? r2.GetString() ?? "" : "";
        return Card("存储", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                // ★ 绿色包:数据全在 exe 同级 userdata/,把路径写出来用户才知道备份什么
                Dim(root == "" ? "" : $"数据目录:{root}"),
                size,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { clear, open } },
            },
        });
    }

    private static Control Card(string title, Control body) => new Border
    {
        Classes = { "card" }, Padding = new Thickness(18), Width = 620,
        HorizontalAlignment = HorizontalAlignment.Left,
        Child = new StackPanel { Spacing = 12, Children = { H2(title), body } },
    };

    private static Control Field(string label, Control input) => new StackPanel
    {
        Orientation = Orientation.Horizontal, Spacing = 12,
        Children =
        {
            new TextBlock { Text = label, Width = 90, VerticalAlignment = VerticalAlignment.Center },
            input,
        },
    };

    private static string? Nz(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
}
