using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.VisualTree;
using Avalonia.Media;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 搜索页。
///
/// <para>这一页最容易做成<b>一片黑</b>:还没搜之前它什么都没有。
/// 空态不是装饰 —— 没有空态时用户看到的是「这一页坏了」,而不是「等我输入」。</para>
///
/// <para>打开就聚焦。搜索页只有一件事可做,还要用户先点一下输入框,
/// 那一下点击是白让人做的。</para>
/// </summary>
public sealed class SearchPage : PageBase
{
    /// <summary>停手多久自动搜。 太短会把每个字都发出去,太长会让人以为要自己点按钮。</summary>
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(420);

    /// <summary>
    /// 第几次搜索。
    ///
    /// <para>边打字边搜时<b>响应会乱序回来</b>:「三体」发出去之后「三」才回来,
    /// 结果就是屏幕上显示的是上一个词的结果,而输入框里写着新词 ——
    /// 用户只会觉得「搜出来的东西不对」。每次发请求记一个号,回来时对不上就丢掉。</para>
    /// </summary>
    private int _seq;

    private CancellationTokenSource? _typing;

    /// <summary>自检用:留住输入框,好让 <see cref="SelfCheckQuery"/> 往里填词。</summary>
    private readonly TextBox _box;

    public SearchPage(CoreClient core)
    {
        /* 不设 MaxWidth。
           Stretch + MaxWidth 在 Avalonia 里是「拉满、再按上限收窄、然后**居中**」——
           表现是搜索框浮在内容区中间,左边空一大块,看着像没对齐。
           要么真撑满,要么给死宽度;两者中间那档不存在。 */
        var box = new TextBox
        {
            Classes = { "field" }, Watermark = "搜片名、剧名、演员…",
            HorizontalAlignment = HorizontalAlignment.Stretch,
        };
        var go = new Button { Classes = { "primary" }, Content = "搜索" };
        /* 这里原来是「包括分集」,2026-09-02 换成<b>聚合搜索</b>(用户点名)。
           理由站得住:分集本来就不该混进片名搜索的结果里(一部剧能刷出几十条
           「第 N 集」,把剧本身挤到屏幕外),而找某一集的正确入口是进剧的详情页;
           而「这部片我到底存在哪台服务器上」是多服务器用户天天遇到、
           **原来只能一台台切过去搜**的问题。
           做成开关不是按钮:它要能关回来 —— 只搜当前这台仍然是默认动作。 */
        var everywhere = new CheckBox
        {
            Content = "聚合搜索(所有服务器)", IsChecked = false,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var status = Dim("");
        var host = new ContentControl();
        /* 空态摆<b>搜索历史</b>(草稿 09 页第 34 条)。
           写「暂无数据」等于白占一屏,而「上次搜的那个」正是这里最可能的下一步。
           历史落在核心层偏好里(去重/置顶/封顶也在那儿),不在界面自己攒一份 ——
           三端各攒一份的话「同一个词搜两次会不会出两条」迟早说不一样的话。 */
        void ShowEmpty(List<string> hist) => host.Content = Empty(hist,
            q => { box.Text = q; box.CaretIndex = q.Length; },
            () => _ = ClearHistory(core, ShowEmpty));
        ShowEmpty([]);
        _ = LoadHistory(core, ShowEmpty);

        var bar = new Grid { ColumnDefinitions = new ColumnDefinitions("*,Auto,Auto") };
        Grid.SetColumn(box, 0);
        Grid.SetColumn(go, 1);
        Grid.SetColumn(everywhere, 2);
        go.Margin = new Thickness(10, 0, 0, 0);
        everywhere.Margin = new Thickness(18, 0, 0, 0);
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
                _ = LoadHistory(core, ShowEmpty);
                return;
            }

            var mine = ++_seq;
            status.Text = $"正在搜「{q}」…";
            host.Content = Skeleton.Grid(false, 12);
            var all = everywhere.IsChecked == true;
            try
            {
                /* types 必须**显式传**:不传的话核心层会连分集一起要,
                   搜一部剧会先刷出几十条「第 N 集」(Rust 版栽过)。
                    聚合那条<b>也要带</b> —— 两条路各写一份筛选的话,
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
                    _ = Push(core, q);
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
                /* 搜出来了才记。<b>搜不到的不记</b> —— 历史是「回到刚才那次」的入口,
                   把一个搜不到的词摆在那儿,点了还是搜不到。 */
                if (items.Count > 0) _ = Push(core, q);
            }
            catch (Exception e)
            {
                if (mine != _seq) return;
                status.Text = $"搜索失败:{LibraryPage.Advice(e)}";
                host.Content = new StackPanel();
            }
        }

        /* 聚合结果<b>按服务器分组</b>,不是拌成一锅。
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
                        /* 点开的详情页要用**那一台**的地址,不是当前活跃的那台 ——
                           拿当前会话去打另一台的 item_id,拿到的是 404 或者一条别的片。 */
                        LibraryPage.Grid(c, srv, items, false, LibraryPage.OpenDetail(c, srv)),
                    },
                });
            }
            return host2;
        }

        /* 停手就搜。
            每敲一下就撤销上一次的等待 —— 不撤的话敲 5 个字会排 5 次搜索,
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

        // 打开就把光标放进输入框。必须等挂到可视树之后 —— 在构造函数里 Focus()
        // 是对着一个还没上屏的控件调,静默无效。
        AttachedToVisualTree += (_, _) => Dispatcher.UIThread.Post(() => box.Focus());
        _box = box;
    }

    /// <summary>
    /// 自检用:填一个词进去,让它自己走一遍防抖 → 搜索 → 渲染结果。
    ///
    /// <para>直接调内部的 Run() 就把**防抖那一段**跳过去了 —— 而
    /// 「边打字边搜、乱序回来的结果要丢掉」正是这一页最容易写错的地方。
    /// 走真实入口才验得到。</para>
    /// </summary>
    internal void SelfCheckQuery(string q) => Dispatcher.UIThread.Post(() => _box.Text = q);

    /// <summary>
    /// 还没搜之前的那一屏:提示 + <b>搜索历史片</b>(草稿 09 页第 34 条)。
    ///
    /// <para>不写「暂无数据」:这里根本不是没数据,是<b>还没问</b>。
    /// 一条历史都没有时只画提示,不画一个空的「历史」标题。</para>
    /// </summary>
    private static Control Empty(List<string> hist, Action<string> pick, Action clear)
    {
        var col = new StackPanel { Spacing = 14 };
        if (hist.Count > 0)
        {
            var row = new WrapPanel();
            foreach (var q in hist) row.Children.Add(Chips.Clickable(q, () => pick(q)));
            var head = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 10,
                Children = { H2("搜过的") },
            };
            var del = new Button { Classes = { "ghost" }, Content = "清除历史" };
            del.Click += (_, _) => clear();
            head.Children.Add(del);
            col.Children.Add(head);
            col.Children.Add(row);
        }
        col.Children.Add(Frame(
            "🔍", "搜这台服务器上的片名、剧名、演员",
            "输入后停一下就会自动搜,回车也行。\n结果里默认只有电影和剧集 —— 要跨服务器找,把上面的「聚合搜索」勾上。"));
        return col;
    }

    /// <summary>拉搜索历史。拉不到就当没有 —— 它不值得把这一页拖红。</summary>
    private static async Task LoadHistory(CoreClient core, Action<List<string>> show)
    {
        List<string> hist;
        try { hist = Strings(await core.PrefsGetPrefs(new { }), "search_history"); }
        // 拉不到就当没有:历史是锦上添花,为它把搜索这一屏拖红不值
        catch { return; }
        Dispatcher.UIThread.Post(() => show(hist));
    }

    private static async Task ClearHistory(CoreClient core, Action<List<string>> show)
    {
        try { await core.PrefsSetPrefs(new { search_history = Array.Empty<string>() }); }
        catch (Exception e) { Toast.Error(LibraryPage.Advice(e)); return; }
        Dispatcher.UIThread.Post(() => show([]));
    }

    /// <summary>记一笔。失败**不打扰用户** —— 他要的是搜索结果,不是历史。</summary>
    private static async Task Push(CoreClient core, string q)
    {
        try { await core.PrefsPushSearch(new { query = q }); }
        catch { /* 记不上就算了,下次还能搜 */ }
    }

    private static List<string> Strings(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v)
        && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x != "").ToList()
            : [];

    /// <summary>
    /// 搜不到时的那一屏。
    /// <para>要给<b>下一步</b>,不是只说一句「没有」。</para>
    /// <para>这里<b>不放图标</b>:能表达「没找到」的表情在 Windows 上一律渲染成
    /// 一张古怪的脸,比不放更糟。空态的图标是给「还没开始」用的,不是给失败用的。</para>
    /// </summary>
    private static Control NoHit(string q, bool everywhere) => Frame(
        "", $"没有搜到「{q}」",
        everywhere
            ? "所有连得上的服务器都问过了。换个更短的词试试 —— 服务器按片名匹配,输全名反而更容易落空。"
            : "换个更短的词试试。或者勾上「聚合搜索」,把这个词发给所有服务器再找一遍。");

    /// <summary>
    /// 空态文案的上下留白。上下不对称是故意的:文字落在视觉中心要比几何中心略高。
    /// </summary>
    private const double EmptyTop = 70, EmptyBottom = 90;

    private static Control Frame(string glyph, string title, string body) => new Border
    {
        Padding = new Thickness(26, EmptyTop, 26, EmptyBottom),
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Child = new StackPanel
        {
            Spacing = 10, MaxWidth = 460,
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
                    Foreground = Tok.Of("Ink3"),
                },
            },
        },
    };
}

/// <summary>收藏页。</summary>
public sealed class FavoritesPage : PageBase
{
    /// <summary>
    /// 排序档位。<b>必须和核心层 <c>emby.FavoriteSorts</c> 逐字一致</b> —— 对不上就静默落回第一档。
    ///
    /// <para>排序是核心层<b>本地</b>做的:某 fork 在 <c>Filters=IsFavorite</c> 上无视
    /// SortBy 且照样回 200,送上去等于什么都没做。</para>
    /// </summary>
    private static readonly string[] Sorts = ["更新时间", "名称", "评分", "年份"];

    /// <summary>版式开关。<b>和媒体库共用同一份状态</b>(<see cref="GridView"/>)——
    /// 两边各存各的话,「在收藏页换成列表、回媒体库还是网格」这种分叉不报错,
    /// 用户只会觉得这个开关时灵时不灵。</summary>
    private readonly Button _view;

    public FavoritesPage(CoreClient core)
    {
        var rows = new StackPanel { Spacing = 14, Children = { H1("收藏") } };
        var busy = Dim("加载中…");
        var sort = Sorts[0];
        var picks = new WrapPanel { ItemSpacing = 6, LineSpacing = 6 };
        /* 版式按重画之后还要在:这一页每换一次排序就整页重来一遍,
           而那两个网格是新造的 —— 所以按可视树现找,不是记住上一批的引用。 */
        _view = GridView.Toggle(core, list =>
        {
            foreach (var g in this.GetVisualDescendants().OfType<MediaGrid>()) g.ListMode = list;
        });
        picks.Children.Add(_view);
        rows.Children.Add(picks);
        rows.Children.Add(busy);
        Content = Scrolled(rows);

        // 档位换了整页重画:收藏是一次全量拉回来的(没有分页),重排就是重来一遍
        void Load()
        {
            foreach (var b in picks.Children.OfType<Button>())
                b.Classes.Set("on", (string?)b.Tag == sort);
            while (rows.Children.Count > 2) rows.Children.RemoveAt(2);
            busy.Text = "加载中…";
            if (!rows.Children.Contains(busy)) rows.Children.Add(busy);
            Fetch();
        }

        foreach (var name in Sorts)
        {
            var b = new Button { Classes = { "chip" }, Content = name, Tag = name };
            b.Click += (_, _) => { sort = name; Load(); };
            picks.Children.Add(b);
        }
        Load();

        void Fetch() =>
        _ = Task.Run(async () =>
        {
            try
            {
                var s = Nav.Session!;
                var want = sort;
                var res = await core.EmbyListFavorites(new { s.server, s.token, s.user_id, s.device_id, sort });
                var items = res.ValueKind == JsonValueKind.Array
                    ? res.EnumerateArray().Select(CardItem.From).ToList() : [];
                Dispatcher.UIThread.Post(() =>
                {
                    // 等这一趟网络的工夫里用户换了档位:这批是旧档位的结果,别落地
                    if (want != sort) return;
                    rows.Children.Remove(busy);
                    if (items.Count == 0) { rows.Children.Add(Dim("还没有收藏。详情页点「收藏」就会出现在这里。")); return; }

                    /* <b>分集单独一栏,横版</b>(接着 2026-09-03 那条
                       「集封面和海报封面/季封面是不一样的,集封面是横着的」)。
                       收藏里电影、剧、分集是混着的,而一个网格只能有一种比例 ——
                       把分集塞进 2:3 的格子里再 UniformToFill,等于左右各裁掉三分之一,
                       <b>而且画面是满的,不报错</b>。
                       分成两栏而不是按条目各画各的比例:同一行里高矮不一会让整页参差,
                         而「一行对齐」正是网格存在的理由。旧栈当年也是这么分的。 */
                    var eps = items.Where(i => i.Type == "Episode").ToList();
                    var rest = items.Where(i => i.Type != "Episode").ToList();
                    if (rest.Count > 0)
                    {
                        if (eps.Count > 0) rows.Children.Add(H2($"影片与剧集 · {rest.Count}"));
                        var g = LibraryPage.Grid(core, s.server, rest, false);
                        // 新造的网格要跟上当前版式 —— 不跟的话换完排序又回到海报网格
                        g.ListMode = GridView.IsList;
                        rows.Children.Add(g);
                    }
                    if (eps.Count > 0)
                    {
                        rows.Children.Add(H2($"分集 · {eps.Count}"));
                        var g = LibraryPage.Grid(core, s.server, eps, true,
                            LibraryPage.OpenDetail(core, s.server), episodeStyle: true, width: 214);
                        g.ListMode = GridView.IsList;
                        rows.Children.Add(g);
                    }
                });
            }
            catch (Exception e)
            {
                Dispatcher.UIThread.Post(() => busy.Text = $"加载失败:{LibraryPage.Advice(e)}");
            }
        });
    }

    /// <summary>
    /// 自检:收藏页的版式开关。
    ///
    /// <para>这一页有<b>两个</b>网格(影片与剧集 / 分集),所以判的是「一个海报卡都不剩」——
    /// 只看第一个网格的话,「分集那一栏没跟上」这个真 bug 照样绿。</para>
    /// </summary>
    internal void SelfCheckView()
    {
        int Rows() => this.GetVisualDescendants().OfType<MediaRow>().Count();
        int Cards() => this.GetVisualDescendants().OfType<Card>().Count();
        var grids = this.GetVisualDescendants().OfType<MediaGrid>().Count();
        if (Cards() == 0)
        {
            Console.WriteLine("[收藏版式] ✗ 一张卡都没有 —— 假服务器没给收藏?");
            return;
        }
        var was = Cards();
        Console.WriteLine($"[收藏版式] 起手:{grids} 个网格 / 海报 {was} 张 / 列表行 {Rows()} 行");
        _view.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        Dispatcher.UIThread.Post(() =>
        {
            Console.WriteLine(Rows() > 0 && Cards() == 0
                ? $"[收藏版式] ✓ 两栏一起换成列表了:{Rows()} 行"
                : $"[收藏版式] ✗ 没换干净:列表行 {Rows()} / 还剩海报 {Cards()}");
            _view.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
            Dispatcher.UIThread.Post(() => Console.WriteLine(
                Cards() == was && Rows() == 0
                    ? $"[收藏版式] ✓ 换回网格了:还是 {Cards()} 张海报"
                    : $"[收藏版式] ✗ 换不回网格:列表行 {Rows()} / 海报 {Cards()}(起手是 {was})"),
                DispatcherPriority.Background);
        }, DispatcherPriority.Background);
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
        /* <b>居中单列</b>(用户 2026-09-04:「不要做成现在的块状,也不要做成
           一列一列导致视线需要从左往右拉很长去对齐」「建议直接做成居中布局」)。
           原来是 WrapPanel —— 1920 的窗口上它把 620 宽的卡铺成三列,
           于是「读完这一组、找下一组」要把视线从屏幕最右甩回最左,
           而且每次窗口一变宽窄,分组的排布就整个换一遍位置。
           MaxWidth + Stretch 在 Avalonia 里等于「最宽 760,再宽就居中」——
             不用写死 Width,窄窗口照样铺满。 */
        var groups = new StackPanel { Spacing = 14 };
        var busy = Dim("加载中…");
        var rows = new StackPanel
        {
            Spacing = 14, MaxWidth = 760,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Children = { H1("设置"), busy, groups },
        };
        Content = Scrolled(rows);

        _ = Task.Run(async () =>
        {
            try
            {
                // 各组**各拉各的**,一组失败不该把整页拖红 ——
                // 有的组对应的命令在某些平台上就是没有的。
                var p = await core.PrefsGetPrefs(new { });
                var paths = await core.SystemDataPaths(new { });
                var prefetch = await Safe(() => core.PrefsGetPrefetchSettings(new { }));
                var preload = await Safe(() => core.PrefsGetPreloadSettings(new { }));
                var home = await Safe(() => core.PrefsGetHomeSettings(new { }));
                var writeback = await Safe(() => core.PrefsGetWritebackSettings(new { }));
                var update = await Safe(() => core.PrefsGetUpdateSettings(new { }));
                string transErr = "";
                JsonElement? trans;
                try { trans = await core.PrefsGetTranslationSettings(new { }); }
                catch (Exception te) { trans = null; transErr = LibraryPage.Advice(te); }

                Dispatcher.UIThread.Post(() =>
                {
                    rows.Children.Remove(busy);
                    // 组间距交给 groups 的 Spacing,这里不再各自加外边距 ——
                    // 两处都设的话卡与卡之间是 16+18=34,而设计上只该有一个数
                    void Add(Control c) => groups.Children.Add(c);
                    Add(TrackPrefs(core, p));
                    Add(SettingsSections.UiFontSection(core, p));
                    Add(Playback(core, p));
                    // mpv 配置排在播放那组后面:它是同一件事的「高级」那一档
                    Add(SettingsSections.MpvConf(core));
                    Add(SettingsSections.SkipSegments(core, p));
                    if (home is { } hm) Add(SettingsSections.Home(core, hm));
                    if (prefetch is { } pf) Add(SettingsSections.Prefetch(core, pf));
                    // 下线的分组一并不画。开关表在 Features.cs,这里只查表。
                    if (Features.On("set.preload") && preload is { } pl) Add(SettingsSections.Preload(core, pl));
                    if (Features.On("set.writeback") && writeback is { } wb) Add(SettingsSections.Writeback(core, wb));
                    if (update is { } up) Add(SettingsSections.Update(core, up));
                    if (Features.On("set.blocked")) Add(SettingsSections.Blocked(core));
                    /* 翻译设置**拉不到也要出这一组**,只是里面写清楚原因。
                       静默跳过的表现是「设置页里根本没有字幕翻译」——
                       用户会以为这个版本没做这个功能,而不是「这次没拉到」。
                       这条只管「拉不到」,和「整组下线」是两回事:下线时连组都不出。 */
                    if (Features.On("set.translate"))
                    {
                        Add(trans is { } tr
                            ? SettingsTranslate.Section(core, tr)
                            : SettingsTranslate.Unavailable(transErr));
                    }
                    if (Features.On("set.whisper") && trans is not null) Add(SettingsTranslate.Whisper(core));
                    if (Features.On("set.cfspeed")) Add(SettingsSections.CfSpeed(core));
                    if (Features.On("set.transfer")) Add(SettingsSections.Transfer(core));
                    // 备份与还原和上面那张「搬迁」是两件事:那张出二维码只搬账号,
                    // 这张出文件、带设置、和手机端互通(用户 2026-09-08)
                    Add(SettingsSections.Danmaku(core));
                    Add(SettingsSections.Backup(core));
                    Add(Storage(core, paths));
                    Add(Shortcut(core));
                    // 快捷键不挂 Features 开关:它是操作方式,不是一块可下线的功能
                    Add(SettingsKeys.Section(core));
                    // 不挂 Features 开关:它是排查工具,任何版本都得有
                    Add(SettingsSections.Logging(core));
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
        // 弹幕开关。放在选轨这组里是因为它和「默认开字幕」是同一类:起播时的默认行为。
        // 以前三端发的都是 danmaku.setDanmakuConfig(那条收的是**弹幕源清单**),
        // 核心层当未知键忽略、照常返回成功 —— 一个永远不生效又不报错的开关。
        var dm = new CheckBox { Content = "默认开启弹幕", IsChecked = Bool(p, "danmaku_enabled") };
        var hint = Dim("");

        var save = new Button { Classes = { "primary" }, Content = "保存" };
        save.Click += async (_, _) =>
        {
            try
            {
                // 只送这几项。核心层也只改这几项 ——
                // 整体覆盖会把跨服续播之类的悄悄重置成默认值。
                await core.PrefsSetPrefs(new
                {
                    sub_lang = Nz(sub.Text), audio_lang = Nz(audio.Text),
                    sub_enabled = on.IsChecked == true,
                    danmaku_enabled = dm.IsChecked == true,
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
                Field("字幕语言", sub), Field("音频语言", audio), on, dm,
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
        // 系统文件对话框由**宿主**弹(核心层是个库,弹不了对话框 ——
        // system.pickFile 在核心层就是明着返回 E_UNSUPPORTED 的)。
        // 挑完把路径交给 player.setPlaybackPrefs,由核心层校验它真的存在:
        // 存一个打不开的路径,等到起播时才炸,那时用户早忘了自己填过什么。
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
            // 后缀过滤要**按平台给**:`*.exe` 在 Linux 上会把列表滤空,
            // 而用户看到的是一个「什么都没有」的对话框。
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

        /* 观看阈值。**一个数字管两件事**:
             ① 看到这里就标「已观看」(明着调 emby.setPlayed,不靠服务器自己那条线 ——
                服务器各 fork 的阈值不一样,只靠它的话这个设置等于没有);
             ② 下次再点这一集,**从头放**而不是接着片尾。
            两件事共用一个值是刻意的:分成两个的话会出现「标了已看完
             却仍然从 97% 续播」这种自相矛盾的状态,而且没人看得出是哪儿设错了。
            下限 50 是核心层定的,这里只给到 70 —— 再低的档位没有实际用处,
             而列出来就会有人选,选完丢的是自己的续播位置。 */
        var watchedVals = new[] { 70, 80, 85, 90, 95, 100 };
        var watched = new ComboBox
        {
            Width = 220,
            ItemsSource = watchedVals.Select(v => v == 100 ? "100%(必须放到结尾)" : $"{v}%").ToList(),
        };
        var curWatched = (int)Num(p, "watched_threshold_percent");
        if (curWatched <= 0) curWatched = 90;
        watched.SelectedIndex = Math.Max(0, Array.FindIndex(watchedVals, v => v >= curWatched));
        watched.SelectionChanged += async (_, _) =>
        {
            if (watched.SelectedIndex < 0) return;
            try
            {
                await core.PlayerSetPlaybackPrefs(new
                {
                    settings = new { watched_threshold_percent = watchedVals[watched.SelectedIndex] },
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        return Card("播放", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Field("硬件解码", hw),
                Field("已观看阈值", watched),
                Dim("看到这个比例就标记为「已观看」;下次再点这一集会从头开始放,不接着片尾。"),
                Field("外部播放器", new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { ext, pick, clearExt },
                }),
                Dim("设了之后,详情页会多一个「用外部播放器打开」。"),
                hint,
            },
        });
    }

    /// <summary>
    /// 桌面快捷方式。
    ///
    /// <para>绿色包是「解压到哪算哪」—— 挪一次文件夹,用户手搓的那个 .lnk 就指着
    /// 一个不存在的文件了(用户 2026-09-12:「自动更新完之后,用户自己创建的
    /// 快捷方式不能使用了」)。所以这颗按钮不是锦上添花:它是那个症状的出口。</para>
    ///
    /// <para>非 Windows 上<b>整块不画</b> —— 那儿没有 .lnk 这回事,
    /// 摆一个必定失败的按钮比不摆更糟。</para>
    /// </summary>
    private static Control Shortcut(CoreClient core)
    {
        var state = Dim("检查中…");
        var host = new StackPanel { Spacing = 10, IsVisible = false };
        var make = new Button { Classes = { "ghost" }, Content = "创建桌面快捷方式" };

        void Show(JsonElement r)
        {
            if (!Bool(r, "supported")) return;
            host.IsVisible = true;
            var exists = Bool(r, "exists");
            var ok = Bool(r, "ok");
            make.Content = exists ? "修复桌面快捷方式" : "创建桌面快捷方式";
            state.Text = !exists ? "桌面上还没有。"
                : ok ? "桌面上那个指得对。"
                // 指坏了要**把它指着哪说出来**:用户才明白「为什么点了没反应」
                : $"桌面上那个指着「{Str(r, "target")}」,这个文件已经不在了。";
        }

        _ = Task.Run(async () =>
        {
            try
            {
                var r = await core.SystemShortcutStatus(new { });
                Dispatcher.UIThread.Post(() => Show(r));
            }
            catch { /* 问不出来就整块不画 —— 这一块不值得把设置页拖红 */ }
        });
        make.Click += async (_, _) =>
        {
            make.IsEnabled = false;
            try { Show(await core.SystemMakeShortcut(new { })); state.Text = "好了,去桌面看看。"; }
            catch (Exception e) { state.Text = LibraryPage.Advice(e); }
            finally { make.IsEnabled = true; }
        };

        host.Children.Add(state);
        host.Children.Add(make);
        host.Children.Add(Dim("程序换了位置之后,启动时会自动把已经指坏的快捷方式修回来。"));
        return Card("桌面快捷方式", host);
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

        // 打开目录交给核心层(system.openDataDir):UI 里自己拼 explorer 的话,
        // Linux 壳上就得再抄一份,而且**白名单在核心层**,绕过去等于没有白名单。
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
                // 绿色包:数据全在 exe 同级 userdata/,把路径写出来用户才知道备份什么
                Dim(root == "" ? "" : $"数据目录:{root}"),
                size,
                new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10, Children = { clear, open } },
            },
        });
    }

    /// <summary>
    /// 设置里的一组。
    ///
    /// <para>2026-09-04 改成居中单列、宽度自适应(用户:「不要做成现在的块状,也不要
    /// 做成一条从左往右拉很长去对齐」「建议直接做成居中布局」)。原来是 <c>Width=620</c>
    /// + 左对齐 + 外层 WrapPanel:宽窗口上排成两三列,读完一组要把视线从最右甩回最左;
    /// 窄窗口上又死死贴着左边。宽度交给外层那根 MaxWidth 的柱子,卡自己 Stretch ——
    /// 这样只有一处定宽度,不会两处打架。</para>
    /// </summary>
    private static Control Card(string title, Control body) => new Border
    {
        Classes = { "card" }, Padding = new Thickness(18, 18),
        HorizontalAlignment = HorizontalAlignment.Stretch,
        Child = new StackPanel { Spacing = 10, Children = { H2(title), body } },
    };

    /// <summary>
    /// 一行「说明 + 控件」。标签右对齐,列宽收到 88。
    ///
    /// <para>用户 2026-09-04:「输入框与说明名称之间的距离不要离太远,避免用户视觉
    /// 对齐吃力」。原来是左对齐 + 宽 90/100 ——「字幕语言」四个字只占 52px,剩下的
    /// 38px 全是空隙,而每一行的空隙宽度还都不一样(三个字空 52px,五个字空 26px)。
    /// 右对齐之后标签右缘和输入框左缘各自成一条竖线,中间恒定 10px。</para>
    /// </summary>
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

    private static string? Nz(string? s) => string.IsNullOrWhiteSpace(s) ? null : s.Trim();

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
}
