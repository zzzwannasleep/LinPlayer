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
/// 搜索页。
///
/// <para>★★ 这一页最容易做成<b>一片黑</b>:还没搜之前它什么都没有。
/// 空态不是装饰 —— 没有空态时用户看到的是「这一页坏了」,而不是「等我输入」。</para>
///
/// <para>★ 打开就聚焦。搜索页只有一件事可做,还要用户先点一下输入框,
/// 那一下点击是白让人做的。</para>
/// </summary>
public sealed class SearchPage : PageBase
{
    /// <summary>停手多久自动搜。★ 太短会把每个字都发出去,太长会让人以为要自己点按钮。</summary>
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(420);

    /// <summary>
    /// 第几次搜索。
    ///
    /// <para>★★ 边打字边搜时<b>响应会乱序回来</b>:「三体」发出去之后「三」才回来,
    /// 结果就是屏幕上显示的是上一个词的结果,而输入框里写着新词 ——
    /// 用户只会觉得「搜出来的东西不对」。每次发请求记一个号,回来时对不上就丢掉。</para>
    /// </summary>
    private int _seq;

    private CancellationTokenSource? _typing;

    /// <summary>自检用:留住输入框,好让 <see cref="SelfCheckQuery"/> 往里填词。</summary>
    private readonly TextBox _box;

    public SearchPage(CoreClient core)
    {
        /* ★ 不设 MaxWidth。
           Stretch + MaxWidth 在 Avalonia 里是「拉满、再按上限收窄、然后**居中**」——
           表现是搜索框浮在内容区中间,左边空一大块,看着像没对齐。
           要么真撑满,要么给死宽度;两者中间那档不存在。 */
        var box = new TextBox
        {
            Classes = { "field" }, Watermark = "搜片名、剧名、演员…",
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var go = new Button { Classes = { "primary" }, Content = "搜索" };
        /* ★★ 这里原来是「包括分集」,2026-09-02 换成<b>聚合搜索</b>(用户点名)。
           理由站得住:分集本来就不该混进片名搜索的结果里(一部剧能刷出几十条
           「第 N 集」,把剧本身挤到屏幕外),而找某一集的正确入口是进剧的详情页;
           而「这部片我到底存在哪台服务器上」是多服务器用户天天遇到、
           **原来只能一台台切过去搜**的问题。
           ★ 做成开关不是按钮:它要能关回来 —— 只搜当前这台仍然是默认动作。 */
        var everywhere = new CheckBox
        {
            Content = "聚合搜索(所有服务器)", IsChecked = false,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var status = Dim("");
        var host = new ContentControl { Content = Empty() };

        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
        Grid.SetColumn(box, 0);
        Grid.SetColumn(go, 1);
        Grid.SetColumn(everywhere, 2);
        go.Margin = new Thickness(10, 0, 0, 0);
        everywhere.Margin = new Thickness(16, 0, 0, 0);
        bar.Children.Add(box);
        bar.Children.Add(go);
        bar.Children.Add(everywhere);

        Content = Scrolled(new StackPanel
        {
            Spacing = 14,
            Children = { H1("搜索"), bar, status, host },
        });

        async Task Run()
        {
            var q = (box.Text ?? "").Trim();
            if (q == "")
            {
                // 清空输入框 = 回到空态,不是「没搜到」。两者不能混。
                _seq++;
                status.Text = "";
                host.Content = Empty();
                return;
            }

            var mine = ++_seq;
            status.Text = $"正在搜「{q}」…";
            host.Content = Skeleton.Grid(false, 12);
            var all = everywhere.IsChecked == true;
            try
            {
                /* ★ types 必须**显式传**:不传的话核心层会连分集一起要,
                   搜一部剧会先刷出几十条「第 N 集」(Rust 版栽过)。
                   ★★ 聚合那条<b>也要带</b> —— 两条路各写一份筛选的话,
                     漏掉的那条就是「只有聚合搜索会冒出一堆分集」。
                     核心层的 aggregateSearch 默认就收敛到 Movie/Series,这里不必再传;
                     但**别给它 include_episodes**。 */
                if (all)
                {
                    var res = await core.EmbyAggregateSearch(new { query = q });
                    if (mine != _seq) return;
                    var groups = res.ValueKind == JsonValueKind.Array
                        ? res.EnumerateArray().ToList() : [];
                    var total = groups.Sum(g => g.TryGetProperty("items", out var it)
                        && it.ValueKind == JsonValueKind.Array ? it.GetArrayLength() : 0);
                    Dispatcher.UIThread.Post(() =>
                    {
                        if (mine != _seq) return;
                        status.Text = total == 0 ? "" : $"{groups.Count} 台服务器 · 共 {total} 条";
                        host.Content = total == 0 ? NoHit(q, true) : Groups(core, groups);
                    });
                    return;
                }

                var s = Nav.Session!;
                var one = await core.EmbySearch(new
                {
                    s.server, s.token, s.user_id, s.device_id, query = q,
                    types = new[] { "Movie", "Series" },
                });
                if (mine != _seq) return; // 过期结果,丢掉
                var items = one.ValueKind == JsonValueKind.Array
                    ? one.EnumerateArray().Select(CardItem.From).ToList() : [];
                Dispatcher.UIThread.Post(() =>
                {
                    if (mine != _seq) return;
                    status.Text = items.Count == 0 ? "" : $"{items.Count} 条结果";
                    host.Content = items.Count == 0
                        ? NoHit(q, false)
                        : LibraryPage.Grid(core, s.server, items, false,
                            LibraryPage.OpenDetail(core, s.server));
                });
            }
            catch (Exception e)
            {
                if (mine != _seq) return;
                status.Text = $"搜索失败:{LibraryPage.Advice(e)}";
                host.Content = new StackPanel();
            }
        }

        /* ★★ 聚合结果<b>按服务器分组</b>,不是拌成一锅。
           拌起来的话同一部片会出现三张一模一样的卡,而用户点哪张、
           实际会从哪台服务器起播,界面上一个字都没说。 */
        Control Groups(CoreClient c, List<JsonElement> groups)
        {
            var host2 = new StackPanel { Spacing = 18 };
            foreach (var g in groups)
            {
                var srv = g.TryGetProperty("server_id", out var sv) ? sv.GetString() ?? "" : "";
                var nm = g.TryGetProperty("server_name", out var nv) ? nv.GetString() ?? "" : "";
                var items = g.TryGetProperty("items", out var iv) && iv.ValueKind == JsonValueKind.Array
                    ? iv.EnumerateArray().Select(CardItem.From).ToList() : [];
                if (items.Count == 0) continue;
                host2.Children.Add(new StackPanel
                {
                    Spacing = 10,
                    Children =
                    {
                        H2($"{(nm == "" ? srv : nm)} · {items.Count} 条"),
                        /* ★ 点开的详情页要用**那一台**的地址,不是当前活跃的那台 ——
                           拿当前会话去打另一台的 item_id,拿到的是 404 或者一条别的片。 */
                        LibraryPage.Grid(c, srv, items, false, LibraryPage.OpenDetail(c, srv)),
                    },
                });
            }
            return host2;
        }

        /* 停手就搜。
           ★ 每敲一下就撤销上一次的等待 —— 不撤的话敲 5 个字会排 5 次搜索,
             前 4 次全是白发的请求,而且它们乱序回来还会盖掉最后一次的结果。 */
        box.TextChanged += (_, _) =>
        {
            _typing?.Cancel();
            var cts = new CancellationTokenSource();
            _typing = cts;
            _ = Task.Delay(Debounce, cts.Token)
                .ContinueWith(t =>
                {
                    if (t.IsCanceled) return;
                    Dispatcher.UIThread.Post(async () => await Run());
                }, TaskScheduler.Default);
        };

        go.Click += async (_, _) => { _typing?.Cancel(); await Run(); };
        box.KeyDown += async (_, e) =>
        {
            if (e.Key != Avalonia.Input.Key.Enter) return;
            _typing?.Cancel();
            await Run();
        };
        // 换了「聚合搜索」要重搜 —— 不重搜的话开关看着像没生效。
        everywhere.IsCheckedChanged += async (_, _) => { if ((box.Text ?? "") != "") await Run(); };

        // ★ 打开就把光标放进输入框。必须等挂到可视树之后 —— 在构造函数里 Focus()
        //   是对着一个还没上屏的控件调,静默无效。
        AttachedToVisualTree += (_, _) => Dispatcher.UIThread.Post(() => box.Focus());
        _box = box;
    }

    /// <summary>
    /// 自检用:填一个词进去,让它自己走一遍防抖 → 搜索 → 渲染结果。
    ///
    /// <para>★ 直接调内部的 Run() 就把**防抖那一段**跳过去了 —— 而
    /// 「边打字边搜、乱序回来的结果要丢掉」正是这一页最容易写错的地方。
    /// 走真实入口才验得到。</para>
    /// </summary>
    internal void SelfCheckQuery(string q) => Dispatcher.UIThread.Post(() => _box.Text = q);

    /// <summary>
    /// 还没搜之前的那一屏。
    ///
    /// <para>★ 不写「暂无数据」:这里根本不是没数据,是<b>还没问</b>。
    /// 空态要说清下一步该做什么(§6.4)。</para>
    /// </summary>
    private static Control Empty() => Frame(
        "🔍", "搜这台服务器上的片名、剧名、演员",
        "输入后停一下就会自动搜,回车也行。\n结果里默认只有电影和剧集 —— 要找某一集,把上面的「包括分集」勾上。");

    /// <summary>
    /// 搜不到时的那一屏。
    /// <para>★ 要给<b>下一步</b>,不是只说一句「没有」。</para>
    /// <para>★ 这里<b>不放图标</b>:能表达「没找到」的表情在 Windows 上一律渲染成
    /// 一张古怪的脸,比不放更糟。空态的图标是给「还没开始」用的,不是给失败用的。</para>
    /// </summary>
    private static Control NoHit(string q, bool everywhere) => Frame(
        "", $"没有搜到「{q}」",
        everywhere
            ? "所有连得上的服务器都问过了。换个更短的词试试 —— 服务器按片名匹配,输全名反而更容易落空。"
            : "换个更短的词试试。或者勾上「聚合搜索」,把这个词发给所有服务器再找一遍。");

    private static Control Frame(string glyph, string title, string body) => new Border
    {
        Padding = new Thickness(24, 70, 24, 90),
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Child = new StackPanel
        {
            Spacing = 12, MaxWidth = 460,
            HorizontalAlignment = HorizontalAlignment.Center,
            Children =
            {
                new TextBlock
                {
                    Text = glyph, FontSize = 40, Opacity = 0.55,
                    IsVisible = glyph != "",
                    HorizontalAlignment = HorizontalAlignment.Center,
                },
                new TextBlock
                {
                    Text = title, FontSize = 16, FontWeight = FontWeight.SemiBold,
                    TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap,
                    HorizontalAlignment = HorizontalAlignment.Center,
                },
                new TextBlock
                {
                    Text = body, FontSize = 13, LineHeight = 21,
                    TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    Foreground = new SolidColorBrush(Color.Parse("#6b7688")),
                },
            },
        },
    };
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

                    /* ★★ <b>分集单独一栏,横版</b>(接着 2026-09-03 那条
                       「集封面和海报封面/季封面是不一样的,集封面是横着的」)。
                       收藏里电影、剧、分集是混着的,而一个网格只能有一种比例 ——
                       把分集塞进 2:3 的格子里再 UniformToFill,等于左右各裁掉三分之一,
                       <b>而且画面是满的,不报错</b>。
                       ★ 分成两栏而不是按条目各画各的比例:同一行里高矮不一会让整页参差,
                         而「一行对齐」正是网格存在的理由。旧栈当年也是这么分的。 */
                    var eps = items.Where(i => i.Type == "Episode").ToList();
                    var rest = items.Where(i => i.Type != "Episode").ToList();
                    if (rest.Count > 0)
                    {
                        if (eps.Count > 0) rows.Children.Add(H2($"影片与剧集 · {rest.Count}"));
                        rows.Children.Add(LibraryPage.Grid(core, s.server, rest, false));
                    }
                    if (eps.Count > 0)
                    {
                        rows.Children.Add(H2($"分集 · {eps.Count}"));
                        rows.Children.Add(LibraryPage.Grid(core, s.server, eps, true,
                            LibraryPage.OpenDetail(core, s.server), episodeStyle: true, width: 214));
                    }
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
                string transErr = "";
                JsonElement? trans;
                try { trans = await core.PrefsGetTranslationSettings(new { }); }
                catch (Exception te) { trans = null; transErr = LibraryPage.Advice(te); }

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
                    // ★ 下线的分组一并不画。开关表在 Features.cs,这里只查表。
                    if (Features.On("set.preload") && preload is { } pl) Add(SettingsSections.Preload(core, pl));
                    if (Features.On("set.writeback") && writeback is { } wb) Add(SettingsSections.Writeback(core, wb));
                    if (update is { } up) Add(SettingsSections.Update(core, up));
                    if (Features.On("set.blocked")) Add(SettingsSections.Blocked(core));
                    /* ★ 翻译设置**拉不到也要出这一组**,只是里面写清楚原因。
                       静默跳过的表现是「设置页里根本没有字幕翻译」——
                       用户会以为这个版本没做这个功能,而不是「这次没拉到」。
                       ⚠️ 这条只管「拉不到」,和「整组下线」是两回事:下线时连组都不出。 */
                    if (Features.On("set.translate"))
                    {
                        Add(trans is { } tr
                            ? SettingsTranslate.Section(core, tr)
                            : SettingsTranslate.Unavailable(transErr));
                    }
                    if (Features.On("set.whisper") && trans is not null) Add(SettingsTranslate.Whisper(core));
                    if (Features.On("set.cfspeed")) Add(SettingsSections.CfSpeed(core));
                    if (Features.On("set.transfer")) Add(SettingsSections.Transfer(core));
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
