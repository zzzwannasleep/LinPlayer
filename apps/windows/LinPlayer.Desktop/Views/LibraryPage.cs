using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>媒体库总览:一屏列出所有库,点进去是网格。</summary>
public sealed class LibraryPage : PageBase
{
    /// <summary>库卡的宽度。★ 比条目卡大一圈是故意的:一台服务器通常只有三五个库,
    /// 用条目卡的尺寸画出来就是「屏幕上方三张小卡 + 下面一大片空白」。</summary>
    private const double ShelfWidth = 320;

    public LibraryPage(CoreClient core)
    {
        var rows = new StackPanel { Spacing = 14 };
        var summary = Dim("");
        rows.Children.Add(H1("媒体库"));
        rows.Children.Add(summary);
        Control busy = Skeleton.Grid(true, 4, ShelfWidth);
        rows.Children.Add(busy);
        Content = Scrolled(rows);

        /* ★★ Swap **只能在 UI 线程上调**。
           控件必须在 UI 线程创建 —— 在 Task.Run 里 new 一批 Card 出来,
           表现不是抛异常给你看,而是**整页卡在骨架屏上**:
           异常在后台线程里被 catch 吞掉,页面就那么一直呼吸下去。
           2026-09-02 真栽了一次,只有真机截图才看得出来(编译全绿)。 */
        void Swap(Control with)
        {
            var at = rows.Children.IndexOf(busy);
            if (at < 0) return;
            rows.Children[at] = with;
            busy = with;
        }

        _ = Task.Run(async () =>
        {
            try
            {
                // ★ include_blocked=true:媒体库页是**唯一**能把被屏蔽的库找回来的地方,
                //   这里也滤掉的话屏蔽就成了单向门(Rust 版栽过)。
                var s = Nav.Session!;
                var views = await core.EmbyViews(new
                {
                    s.server, s.token, s.user_id, s.device_id, include_blocked = true,
                });
                var items = views.ValueKind == JsonValueKind.Array
                    ? views.EnumerateArray().Select(CardItem.From).ToList() : [];
                Dispatcher.UIThread.Post(() =>
                {
                    if (items.Count == 0) { Swap(Dim("这台服务器上没有媒体库。")); return; }

                    /* ★★ 库卡上<b>不再写「140 项」</b>(用户 2026-09-02:「媒体库页里面
                       显示的多少项也不需要,但是媒体库这个名字下面的那个统计还是需要的」)。
                       顺带省掉的是**每个库一次额外请求** —— 三五个库就是三五次往返,
                       全是为了一行会被无视的小字。顶上那条 128 部电影 · 42 部剧
                       说的是同一件事,而且只要一次请求。 */
                    var wrap = new WrapPanel();
                    foreach (var it in items) wrap.Children.Add(Shelf(core, s.server, it));
                    Swap(wrap);
                    _ = FillSummary(core, summary);
                });
            }
            catch (Exception e)
            {
                var why = Advice(e);
                Dispatcher.UIThread.Post(() => Swap(Dim($"加载失败:{why}")));
            }
        });
    }

    /// <summary>一张库卡。<see cref="Card"/> 的横版版式,标题一行、不带副标题。</summary>
    private static Control Shelf(CoreClient core, string server, CardItem it) =>
        // titleLines: 1 —— 库名从来只有一行。
        new Card(core, server, it, true, OpenDetail(core, server), ShelfWidth, titleLines: 1)
        {
            Margin = new Thickness(0, 0, 16, 18),
        };

    /// <summary>顶上那行「128 部电影 · 42 部剧 · 1580 集」。★ 这个端点在某些 fork 上是 404。</summary>
    private static async Task FillSummary(CoreClient core, TextBlock target)
    {
        try
        {
            var s = Nav.Session!;
            var c = await core.EmbyCounts(new { s.server, s.token, s.user_id, s.device_id });
            long N(string k) => c.ValueKind == JsonValueKind.Object && c.TryGetProperty(k, out var v)
                && v.ValueKind == JsonValueKind.Number ? v.GetInt64() : 0;
            var bits = new List<string>();
            if (N("movie") > 0) bits.Add($"{N("movie")} 部电影");
            if (N("series") > 0) bits.Add($"{N("series")} 部剧");
            if (N("episode") > 0) bits.Add($"{N("episode")} 集");
            if (bits.Count > 0)
                Dispatcher.UIThread.Post(() => target.Text = string.Join("  ·  ", bits));
        }
        catch { /* 统计条是锦上添花 */ }
    }

    internal static string Advice(Exception e) => e is CoreException c ? c.Advice : e.Message;

    /// <summary>
    /// 自动铺满的网格。<b>卡自己有固定宽</b>,所以用 WrapPanel 就够,不必算列数。
    ///
    /// <para><paramref name="episodeStyle"/>:分集版式。剧集详情页里剧名是已知的,
    /// 每张卡再写一遍「某部剧 · 第 3 集」等于把仅有的两行标题位浪费掉一行半 ——
    /// 那一行要留给<b>时长</b>,那才是选集时真会看的东西。</para>
    /// </summary>
    /// <summary>
    /// 自动铺满的网格。
    ///
    /// <para>★★ 交给 <see cref="MediaGrid"/> —— 它<b>按行虚拟化</b>。
    /// 原来是 WrapPanel 一次性把所有条目 new 成卡片:140 条 = 一千四百个控件,
    /// 而真实媒体库上千条,滚到底就是上万个。这不是慢一点,是量级问题。</para>
    ///
    /// <para>★ 这一处是**四个入口共用的**(媒体库网格 / 搜索结果 / 收藏 / 详情页分集),
    /// 改在这儿四处一起受益 —— 各处各写一份网格的话,虚拟化只会做在想起来的那一处。</para>
    /// </summary>
    internal static Control Grid(CoreClient core, string server, List<CardItem> items, bool wide,
        Action<CardItem>? onOpen = null, bool episodeStyle = false, double? width = null)
    {
        using var _ = Core.Perf.Measure($"铺 {items.Count} 条(虚拟化网格)");
        var g = new MediaGrid(core, server, wide, onOpen, episodeStyle, width);
        g.Append(items);
        return g;
    }

    internal static Action<CardItem> OpenDetail(CoreClient core, string server) => item =>
    {
        // 库本身不是「详情」,点进去是网格
        if (item.Type is "CollectionFolder" or "UserView" or "Folder")
            Nav.Push(new LibraryGridPage(core, server, item.Id, item.Name));
        else
            Nav.Push(new DetailPage(core, server, item.Id));
    };
}

/// <summary>一个库里的条目网格。分页拉,滚到底再拉下一页,顶上一排排序与筛选。</summary>
public sealed class LibraryGridPage : PageBase
{
    private const int PageSize = 60;

    /// <summary>
    /// 排序档位。by/order 是 Emby 的真值,直接透传给 listItemsPage 让<b>服务端</b>排。
    ///
    /// <para>★ 本地排只能排到已加载的那一页,翻页之后顺序就乱了。</para>
    /// <para>★ 「更新时间」≠「加入时间」:<c>DateCreated</c> 是条目自己被建出来的时间
    /// (剧集 = 剧第一次入库),<c>DateLastContentAdded</c> 是**这部剧最近一集**入库的时间。
    /// 追更要的是后者,两个都得留。</para>
    /// </summary>
    private static readonly (string Label, string By, string Order)[] Sorts =
    [
        ("加入时间", "DateCreated", "Descending"),
        ("更新时间", "DateLastContentAdded", "Descending"),
        ("上映日期", "PremiereDate", "Descending"),
        ("名称 A→Z", "SortName", "Ascending"),
        ("名称 Z→A", "SortName", "Descending"),
        ("年份", "ProductionYear", "Descending"),
        ("评分", "CommunityRating", "Descending"),
    ];

    private readonly CoreClient _core;
    private readonly string _server, _parentId;
    /// <summary>★ 虚拟化网格。这一页是全站最长的一页(分页拉,能拉到上千条)。</summary>
    private readonly MediaGrid _grid;
    private readonly TextBlock _status = new() { Classes = { "dim" } };
    /// <summary>首屏骨架。★ 第一页回来之前这块是空的,不垫的话进库先见一片黑。</summary>
    private readonly ContentControl _first = new() { Content = Skeleton.Grid(false, 18) };
    private readonly ComboBox _sort = new() { Width = 150, MinHeight = 34 };
    private readonly ComboBox _genre = new() { Width = 150, MinHeight = 34 };
    private readonly ComboBox _year = new() { Width = 120, MinHeight = 34 };
    private int _loaded;
    private int _total = -1;
    private bool _busy;
    private bool _suppress;

    public LibraryGridPage(CoreClient core, string server, string parentId, string title)
    {
        _core = core; _server = server; _parentId = parentId;
        _grid = new MediaGrid(core, server, false, LibraryPage.OpenDetail(core, server));

        _sort.ItemsSource = Sorts.Select(x => x.Label).ToList();
        _sort.SelectedIndex = 0;
        _genre.ItemsSource = new List<string> { "全部类型" };
        _genre.SelectedIndex = 0;
        _year.ItemsSource = new List<string> { "全部年份" };
        _year.SelectedIndex = 0;
        // ★ 分面回来时会重设下拉的 ItemsSource/SelectedIndex,那会**触发一次 SelectionChanged** ——
        //   不挡住的话每次进库都白拉一整页(实测日志里 StartIndex=0 出现两次)。
        foreach (var b in new[] { _sort, _genre, _year })
            b.SelectionChanged += (_, _) => { if (!_suppress) Requery(); };

        var head = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children = { Back(), H1(title) },
        };
        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children = { _sort, _genre, _year },
        };
        var body = new StackPanel { Spacing = 14, Children = { head, bar, _first, _grid, _status } };

        var sv = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = new Border
            {
                // ★ 不封顶(和 PageBase.Scrolled 同一条口径,用户点名去掉留白)
                HorizontalAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(18, 18, 18, 28), Child = body,
            },
        };
        // 滚到底再拉下一页。★ 没有这个的表现是「这个库只有 60 部」——
        // 不报错、不空白,纯粹少一半内容。
        sv.ScrollChanged += (_, _) =>
        {
            if (sv.Offset.Y + sv.Viewport.Height >= sv.Extent.Height - 600) _ = LoadMore();
        };
        Content = sv;
        _ = LoadFilters();
        _ = LoadMore();
    }

    /// <summary>
    /// 换排序 / 换筛选 = 从头拉。
    ///
    /// <para>★ 必须把已加载的都清掉再拉:不清的话新旧两批混在一起,
    /// 用户看到的是「筛选之后反而变多了」。</para>
    /// </summary>
    private void Requery()
    {
        _grid.Clear();
        _loaded = 0;
        _total = -1;
        _ = LoadMore();
    }

    /// <summary>
    /// 拉分面。★ 拉不到**不报错、不挡页面** —— 某些 fork 没有 /Items/Filters,
    /// 那就只是没有筛选下拉,网格本身照样能看。
    /// </summary>
    private async Task LoadFilters()
    {
        JsonElement f;
        try
        {
            var s = Nav.Session!;
            f = await _core.EmbyGetFilters(new
            {
                s.server, s.token, s.user_id, s.device_id, parent_id = _parentId,
            });
        }
        catch { return; }

        var genres = Strings(f, "genres");
        var years = Numbers(f, "years");
        Dispatcher.UIThread.Post(() =>
        {
            _suppress = true;
            if (genres.Count > 0)
                _genre.ItemsSource = new List<string> { "全部类型" }.Concat(genres).ToList();
            if (years.Count > 0)
                _year.ItemsSource = new List<string> { "全部年份" }
                    .Concat(years.OrderByDescending(x => x).Select(x => x.ToString())).ToList();
            _genre.SelectedIndex = 0;
            _year.SelectedIndex = 0;
            _suppress = false;
        });
    }

    private static List<string> Strings(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x != "").ToList() : [];
    private static List<long> Numbers(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Where(x => x.ValueKind == JsonValueKind.Number).Select(x => x.GetInt64()).ToList() : [];

    private Control Back()
    {
        var b = new Button { Classes = { "ghost" }, Content = "← 返回" };
        b.Click += (_, _) => Nav.Back();
        return b;
    }

    private async Task LoadMore()
    {
        if (_busy || (_total >= 0 && _loaded >= _total)) return;
        _busy = true;
        Dispatcher.UIThread.Post(() => _status.Text = "加载中…");
        try
        {
            var s = Nav.Session!;
            var (_, by, order) = Sorts[Math.Max(0, _sort.SelectedIndex)];
            // 「全部XX」是第 0 项,不是一个真的筛选值
            var genres = _genre.SelectedIndex > 0 ? new[] { (string)_genre.SelectedItem! } : null;
            var years = _year.SelectedIndex > 0 ? new[] { long.Parse((string)_year.SelectedItem!) } : null;

            var page = await _core.EmbyListItemsPage(new
            {
                s.server, s.token, s.user_id, s.device_id,
                parent_id = _parentId,
                query = new
                {
                    limit = PageSize, start_index = _loaded,
                    sort_by = by, sort_order = order, genres, years,
                },
            });
            var items = page.TryGetProperty("items", out var arr) && arr.ValueKind == JsonValueKind.Array
                ? arr.EnumerateArray().Select(CardItem.From).ToList() : [];
            _total = page.TryGetProperty("total", out var t) && t.ValueKind == JsonValueKind.Number
                ? t.GetInt32() : _loaded + items.Count;
            _loaded += items.Count;

            Dispatcher.UIThread.Post(() =>
            {
                // 第一页到了就把骨架撤掉。★ 换排序 / 换筛选时它不再回来 ——
                //   那时候屏幕上已经有内容了,再闪一次骨架反而像整页重载。
                _first.IsVisible = false;
                using var _sp = Core.Perf.Measure($"追加 {items.Count} 条(虚拟化网格)");
                _grid.Append(items);
                _status.Text = _loaded >= _total ? $"共 {_total} 项" : $"已加载 {_loaded} / {_total}";
                if (_loaded == 0) _status.Text = "这个筛选下没有内容。";
            });
            // 服务器返回空页但 total 还没到:再拉就是死循环,当作到底
            if (items.Count == 0) _total = _loaded;
        }
        catch (Exception e)
        {
            Dispatcher.UIThread.Post(() =>
            {
                // ★ 失败时骨架也要撤:留着的话「加载失败」那行字底下还有一片在呼吸,
                //   用户会以为它还在重试。
                _first.IsVisible = false;
                _status.Text = $"加载失败:{LibraryPage.Advice(e)}";
            });
        }
        finally { _busy = false; }
    }
}
