using System.Linq;
using System.Collections.Generic;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>媒体库总览:一屏列出所有库,点进去是网格。</summary>
public sealed class LibraryPage : PageBase
{
    /// <summary>库卡<b>最少</b>多宽。 比条目卡大一圈是故意的:一台服务器通常只有三五个库,
    /// 用条目卡的尺寸画出来就是「屏幕上方三张小卡 + 下面一大片空白」。
    /// 实宽由 <see cref="MediaGrid"/> 按行宽均分算出来,右边不留余数。</summary>
    private const double ShelfWidth = 320;

    public LibraryPage(CoreClient core)
    {
        var rows = new StackPanel { Spacing = 14 };
        var summary = Dim("");
        rows.Children.Add(H1("媒体库"));
        rows.Children.Add(summary);
        Control busy = Skeleton.Grid(true, 4, ShelfWidth);
        rows.Children.Add(busy);
        /* 库卡下面还得有东西。
           用户 2026-09-03 之前三轮都没点名,但这一页的形状摆在那儿:
           一台服务器通常只有三五个库,画完一行就到底了,<b>下面三分之二是空的</b>。
           填的不能是装饰,得是这一页真该有的内容 —— 「合集」是"从库这一层
           往下看"的自然下一步,而且命令核心层早就有。
           「最近加入」2026-09-04 撤了,见 FillExtra。 */
        var extra = new StackPanel { Spacing = 18, Margin = new Thickness(0, 10, 0, 0) };
        rows.Children.Add(extra);
        Content = Scrolled(rows);

        /* Swap **只能在 UI 线程上调**。
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
                // include_blocked=true:媒体库页是**唯一**能把被屏蔽的库找回来的地方,
                // 这里也滤掉的话屏蔽就成了单向门(Rust 版栽过)。
                var s = Nav.Session!;
                // 缓存先行:库表是这一页的全部内容,而它几乎从不变 ——
                // 每次进来等一次往返只为了拿回同样的三五行。
                var key = MetaCache.Key("emby.views", new { s.server, s.user_id, blocked = true });
                var cachedRaw = "";
                if (MetaCache.PeekList(key) is { Count: > 0 } hit)
                {
                    cachedRaw = string.Concat(hit.Select(x => x.GetRawText()));
                    Dispatcher.UIThread.Post(() => Paint(hit.Select(CardItem.From).ToList()));
                }

                var views = await core.EmbyViews(new
                {
                    s.server, s.token, s.user_id, s.device_id, include_blocked = true,
                });
                var raw = views.ValueKind == JsonValueKind.Array
                    ? views.EnumerateArray().ToList() : [];
                MetaCache.PutList(key, raw);
                // 一个字没变就不重画 —— 重画一次整页网格会当场闪一下
                if (cachedRaw.Length > 0 && cachedRaw == string.Concat(raw.Select(x => x.GetRawText())))
                    return;
                var items = raw.Select(CardItem.From).ToList();
                Dispatcher.UIThread.Post(() => Paint(items));
                return;

                void Paint(List<CardItem> items)
                {
                    if (items.Count == 0) { Swap(Dim("这台服务器上没有媒体库。")); return; }

                    /* 库卡上<b>不再写「140 项」</b>(用户 2026-09-02:「媒体库页里面
                       显示的多少项也不需要,但是媒体库这个名字下面的那个统计还是需要的」)。
                       顺带省掉的是**每个库一次额外请求** —— 三五个库就是三五次往返,
                       全是为了一行会被无视的小字。顶上那条 128 部电影 · 42 部剧
                       说的是同一件事,而且只要一次请求。 */
                    /* 库卡改走 <see cref="MediaGrid"/>(用户 2026-09-03 第二次点名右边留白)。
                       原来是 WrapPanel + 写死 320 宽:1400 的区域放得下 4 张(4×320+3×16=1328),
                       <b>右边必然剩 72px</b>。WrapPanel 只会换行,它没有「把这一行铺满」的概念。 */
                    // titleLines:1 —— 库名从来只有一行,留两行会让每张卡白高 17px
                    Swap(Grid(core, s.server, items, true, OpenDetail(core, s.server),
                        width: ShelfWidth, titleLines: 1));
                    _ = FillSummary(core, summary);
                    // 只画一次:SWR 第二遍(内容真变了)才会走到这儿,那时候 extra 得先清空
                    extra.Children.Clear();
                    _ = FillExtra(core, s, extra);
                }
            }
            catch (Exception e)
            {
                var why = Advice(e);
                Dispatcher.UIThread.Post(() => Swap(Dim($"加载失败:{why}")));
            }
        });
    }

    /// <summary>
    /// 库卡下面那一段:合集。
    ///
    /// <para>一条命令没结果就<b>整段不画</b>,不摆一个写着「暂无」的空标题
    /// —— 合集端点在某些 fork 上是 404。</para>
    /// </summary>
    private static async Task FillExtra(CoreClient core, Sess s, StackPanel host)
    {
        async Task One(string title, Func<Task<JsonElement>> load, bool wide, string key)
        {
            List<CardItem> items;
            var hit = MetaCache.PeekList(key);
            if (hit is { Count: > 0 })
            {
                items = hit.Select(CardItem.From).ToList();
                Dispatcher.UIThread.Post(() => Paint(core, s.server, title, items, wide, host));
            }
            try
            {
                var r = await load();
                var raw = r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().ToList() : [];
                MetaCache.PutList(key, raw);
                if (hit is { Count: > 0 } && string.Concat(hit.Select(x => x.GetRawText()))
                    == string.Concat(raw.Select(x => x.GetRawText()))) return;
                items = raw.Select(CardItem.From).ToList();
            }
            catch { return; }   // 端点 404 / 这一段就不出现
            Dispatcher.UIThread.Post(() => Paint(core, s.server, title, items, wide, host));
        }

        // emby.listCollections 早就注册着,UI 一次没调过 —— 又一条零调用命令
        /* 「最近加入」2026-09-04 <b>撤了</b>(用户:「媒体库里应该只有媒体库内容,
           不要多放一个最近加入」)。首页已经**按库**各出一条最新,
           这里再来一条全局的是同一件事说第二遍,而且它把库卡往下推了一整行。
           合集留着:合集是「库这一层的另一种分法」,不是最新内容的重复。 */
        await One("合集", () => core.EmbyListCollections(new { s.server, s.token, s.user_id, s.device_id }),
            false, MetaCache.Key("emby.listCollections", new { s.server, s.user_id }));
    }

    /// <summary>把一段画进去。 同名的先摘掉 —— SWR 第二遍会再画一次。</summary>
    private static void Paint(CoreClient core, string server, string title,
        List<CardItem> items, bool wide, StackPanel host)
    {
        for (var i = host.Children.Count - 1; i >= 0; i--)
            if ((string?)host.Children[i].Tag == title) host.Children.RemoveAt(i);
        if (items.Count == 0) return;

        var block = new StackPanel
        {
            Tag = title, Spacing = 10,
            Children = { H2($"{title} · {items.Count}") },
        };
        /* 横向轨道,不是网格:这一页的主角是上面那排库卡,
           这两段再铺成网格会把库卡推到看不见的地方 —— 那是把一个空页面
           换成了一个主次颠倒的页面。 */
        /* 卡宽跟着窗口缩,而且换档整条重建(走 Rail 顺带虚拟化 ——
           原来是 StackPanel + Take(40),四十张卡一次全造)。 */
        var railHost = new ContentControl();
        var shown = items.Take(40).ToList();
        Responsive.Watch(railHost, avail =>
        {
            var w = Responsive.CardMin(avail, wide);
            railHost.Content = Carousel.Rail(shown,
                it => new Card(core, server, it, wide, OpenDetail(core, server), width: w),
                wide ? w * 9 / 16 : w * 3 / 2, out _);
        });
        block.Children.Add(railHost);
        host.Children.Add(block);
    }

    /// <summary>顶上那行「128 部电影 · 42 部剧 · 1580 集」。 这个端点在某些 fork 上是 404。</summary>
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
    /// 自动铺满的网格。四个入口共用(媒体库网格 / 搜索结果 / 收藏 / 演职人员)。
    ///
    /// <para><paramref name="episodeStyle"/>:分集版式。剧集详情页里剧名是已知的,
    /// 每张卡再写一遍等于把仅有的两行标题位浪费掉一行 —— 那一行要留给时长。
    /// 网格交给 <see cref="MediaGrid"/> 按行虚拟化:原来是 WrapPanel 一次性 new 完,
    /// 140 条就是一千四百个控件,而真实媒体库上千条,滚到底就是上万个。</para>
    /// </summary>
    internal static MediaGrid Grid(CoreClient core, string server, List<CardItem> items, bool wide,
        Action<CardItem>? onOpen = null, bool episodeStyle = false, double? width = null,
        int titleLines = 2)
    {
        using var _ = Core.Perf.Measure($"铺 {items.Count} 条(虚拟化网格)");
        var g = new MediaGrid(core, server, wide, onOpen, episodeStyle, width, titleLines);
        g.Append(items);
        return g;
    }

    internal static Action<CardItem> OpenDetail(CoreClient core, string server) => item =>
    {
        // 库本身不是「详情」,点进去是网格。造法一并交给 Nav —— 那是「刷新」的入口
        if (item.Type is "CollectionFolder" or "UserView" or "Folder")
        {
            Nav.Push(new LibraryGridPage(core, server, item.Id, item.Name),
                () => new LibraryGridPage(core, server, item.Id, item.Name));
        }
        else
        {
            Nav.Push(new DetailPage(core, server, item.Id),
                () => new DetailPage(core, server, item.Id));
        }
    };
}

/// <summary>一个库里的条目网格。分页拉,滚到底再拉下一页,顶上一排排序与筛选。</summary>
public sealed class LibraryGridPage : PageBase
{
    private const int PageSize = 60;

    /// <summary>
    /// 排序档位。by/order 是 Emby 的真值,直接透传给 listItemsPage 让<b>服务端</b>排。
    ///
    /// <para>本地排只能排到已加载的那一页,翻页之后顺序就乱了。</para>
    /// <para>「更新时间」≠「加入时间」:<c>DateCreated</c> 是条目自己被建出来的时间
    /// (剧集 = 剧第一次入库),<c>DateLastContentAdded</c> 是**这部剧最近一集**入库的时间。
    /// 追更要的是后者,两个都得留。</para>
    /// </summary>
    private static readonly (string Label, string By, string Order)[] Sorts =
    [
        // 第一条就是默认档【用户定 2026-09-12:「默认从新到旧排序」】
        ("更新时间", "DateLastContentAdded", "Descending"),
        ("加入时间", "DateCreated", "Descending"),
        ("上映日期", "PremiereDate", "Descending"),
        ("名称 A→Z", "SortName", "Ascending"),
        ("名称 Z→A", "SortName", "Descending"),
        ("年份", "ProductionYear", "Descending"),
        ("评分", "CommunityRating", "Descending"),
    ];

    private readonly CoreClient _core;
    private readonly string _server, _parentId;
    /* 这一页是不是「按某个类型 / 标签 / 工作室 列条目」。空 = 普通的库网格。
       复用这一页而不是另写一张:分页、排序、代次、滚到底再拉,那几件事一模一样,
       另写一份的下场是其中一件在这儿修了、在那儿没修。 */
    private readonly (string Kind, string Value) _facet;
    /// <summary> 虚拟化网格。这一页是全站最长的一页(分页拉,能拉到上千条)。</summary>
    private readonly MediaGrid _grid;
    private readonly TextBlock _status = new() { Classes = { "dim" } };
    /// <summary>首屏骨架。 第一页回来之前这块是空的,不垫的话进库先见一片黑。</summary>
    private readonly ContentControl _first = new() { Content = Skeleton.Grid(false, 18) };
    private readonly ComboBox _sort = new() { Width = 150, MinHeight = 34 };
    private readonly ComboBox _genre = new() { Width = 150, MinHeight = 34 };
    private readonly ComboBox _year = new() { Width = 120, MinHeight = 34 };
    /// <summary>筛选条三个下拉的基准宽。换档时按比例缩,见构造里的 Responsive.Watch。</summary>
    private static readonly double[] FilterWidths = [150, 150, 120];
    /// <summary>已选筛选项那一行(草稿 08 页第 10 条)。一条都没选时整行不占高度。</summary>
    private readonly WrapPanel _active = new() { ItemSpacing = 10, ItemHeight = double.NaN };
    /// <summary>版式开关:海报网格 ⇄ 列表(草稿 08 页第 9 条)。收藏页那颗共用同一份状态。</summary>
    private readonly Button _view;
    private int _loaded;
    private int _total = -1;
    private bool _busy;
    private bool _suppress;
    /* 筛选的代次。换一次筛选加一,在途的那一次回来发现代次变了就把结果丢掉。
       没有它的表现是用户报的「筛选了不刷新」—— 见 Requery 与 LoadMore。 */
    private int _gen;

    /// <param name="facet">
    /// 按某一项列条目:<c>("genre"|"tag"|"studio", 值)</c>。工作室那一档传的是
    /// <b>id 不是名字</b> —— 实测(Emby 4.9.5)<c>Studios=&lt;名字&gt;</c> 被完全无视,
    /// 返回全库 1673 条,只有 <c>StudioIds=</c> 才精确命中。
    /// </param>
    public LibraryGridPage(CoreClient core, string server, string parentId, string title,
        (string Kind, string Value) facet = default)
    {
        _core = core; _server = server; _parentId = parentId;
        _facet = (facet.Kind ?? "", facet.Value ?? "");
        _grid = new MediaGrid(core, server, false, LibraryPage.OpenDetail(core, server));

        _sort.ItemsSource = Sorts.Select(x => x.Label).ToList();
        _sort.SelectedIndex = 0;
        _genre.ItemsSource = new List<string> { "全部类型" };
        _genre.SelectedIndex = 0;
        _year.ItemsSource = new List<string> { "全部年份" };
        _year.SelectedIndex = 0;
        // 分面回来时会重设下拉的 ItemsSource/SelectedIndex,那会**触发一次 SelectionChanged** ——
        // 不挡住的话每次进库都白拉一整页(实测日志里 StartIndex=0 出现两次)。
        foreach (var b in new[] { _sort, _genre, _year })
            b.SelectionChanged += (_, _) => { if (!_suppress) Requery(); };

        var head = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children = { Back(), Crumb(title) },
        };
        /* 筛选条用 WrapPanel 不用 StackPanel:三个下拉加起来 440px 宽,
           窗口收窄之后 StackPanel 会把最后一个**直接切掉**,而且一点提示都没有。
           换行至少还看得见。 */
        var bar = new WrapPanel { ItemSpacing = 10, ItemHeight = double.NaN };
        // 类型落地页上不摆「类型」下拉:这一页本身就是一个类型,再给一个能改的
        // 下拉等于让人把自己筛出去,而标题还写着原来那个类型
        var combosInBar = _facet.Kind == "genre"
            ? new Control[] { _sort, _year } : [_sort, _genre, _year];
        foreach (var b in combosInBar)
        {
            b.Margin = new Thickness(0, 0, 0, 6);
            bar.Children.Add(b);
        }
        _view = GridView.Toggle(core, list => _grid.ListMode = list);
        _view.Margin = new Thickness(0, 0, 0, 6);
        bar.Children.Add(_view);
        var body = new StackPanel
        {
            Spacing = 14, Children = { head, bar, _active, _first, _grid, _status },
        };
        SyncActive();

        var box = new Border
        {
            // 不封顶(和 PageBase.Scrolled 同一条口径,用户点名去掉留白)
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(18, 18, 18, 26), Child = body,
        };
        var sv = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = box,
        };
        /* 这一页自己搭了滚动容器,吃不到 PageBase.Scrolled 里那条水槽规则 ——
           所以水槽和筛选条的宽度在这儿自己接一次。漏了的表现是:全站都跟着窗口缩,
           **只有媒体库详情页**还是宽水槽 + 一条被切掉最后一项的筛选条。 */
        Responsive.Watch(sv, avail =>
        {
            var g = avail > 1 && avail < 640 ? 10d : 18d;
            box.Padding = new Thickness(g, g, g, g + 8);
            var combos = new[] { _sort, _genre, _year };
            for (var i = 0; i < combos.Length; i++)
                combos[i].Width = Responsive.S(avail, FilterWidths[i], FilterWidths[i] * 0.66);
        });
        // 滚到底再拉下一页。 没有这个的表现是「这个库只有 60 部」——
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
    /// 自检:点一下版式按钮该真的换版式。
    ///
    /// <para>三件事一起判:<b>行数</b>(列表是一条一行)、<b>行里画的是什么</b>
    /// (MediaRow 还是 Card)、<b>按钮上的字</b>。只判按钮的话「文案变了、
    /// 网格没变」这个真 bug 照样绿。</para>
    /// </summary>
    internal void SelfCheckView()
    {
        int Rows() => _grid.GetVisualDescendants().OfType<MediaRow>().Count();
        int Cards() => _grid.GetVisualDescendants().OfType<Card>().Count();
        if (_grid.Count == 0)
        {
            Console.WriteLine("[版式] ✗ 网格里一条都没有 —— 假服务器没给条目?");
            return;
        }
        var was = Cards();
        Console.WriteLine($"[版式] 起手:海报 {was} 张 / 列表行 {Rows()} 行,按钮写「{_view.Content}」");
        _view.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        Dispatcher.UIThread.Post(() =>
        {
            var ok = Rows() > 0 && Cards() == 0 && (string?)_view.Content == "▦ 网格";
            Console.WriteLine(ok
                ? $"[版式] ✓ 换成列表了:{Rows()} 行,一张海报卡都不剩"
                : $"[版式] ✗ 换列表没生效:列表行 {Rows()} / 海报 {Cards()},按钮写「{_view.Content}」");
            _view.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
            /* 换回来要**数得对得上**。 只判「有海报卡」的话,列数没重算、
               一行只剩一张的退化照样绿 —— 那时候屏上还是有卡,只是少了一多半。 */
            Dispatcher.UIThread.Post(() => Console.WriteLine(
                Cards() == was && Rows() == 0
                    ? $"[版式] ✓ 换回网格了:还是 {Cards()} 张海报"
                    : $"[版式] ✗ 换不回网格:列表行 {Rows()} / 海报 {Cards()}(起手是 {was})"),
                DispatcherPriority.Background);
        }, DispatcherPriority.Background);
    }

    /// <summary>
    /// 换排序 / 换筛选 = 从头拉。
    ///
    /// <para>必须把已加载的都清掉再拉:不清的话新旧两批混在一起,
    /// 用户看到的是「筛选之后反而变多了」。</para>
    /// </summary>
    private void Requery()
    {
        /* ☠ **必须换代 + 松开 _busy。** 原来这两句都没有:
           换筛选时只要有一次请求在途(进库那一次、滚到底那一次),
           LoadMore 第一行的 `if (_busy) return` 就把这一次换筛选**整个吞掉** ——
           界面一动不动(用户 2026-09-12:「筛选了不会刷新出现筛选结果,PC 端也是」)。
           松开之后旧那一次仍在跑,靠代次把它的结果丢掉,否则它会把旧筛选的一页
           追加到刚清空的网格里。 */
        _gen++;
        _busy = false;
        SyncActive();
        _grid.Clear();
        _loaded = 0;
        _total = -1;
        _ = LoadMore();
    }

    /// <summary>
    /// 拉分面。 拉不到**不报错、不挡页面** —— 某些 fork 没有 /Items/Filters,
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
        catch { return; }   // 筛选面板拉不到就不画,媒体库本体已经在屏幕上了

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

    /// <summary>
    /// 面包屑「媒体库 › 这个库」(草稿 08 页第 8 条)。
    ///
    /// <para>「媒体库」那一截走 <see cref="Nav.Top"/> <b>不走返回栈</b>:这一页可能是从
    /// 详情页的类型片跳过来的,栈上根本没有库列表,返回会退到详情页去。</para>
    /// </summary>
    private Control Crumb(string title)
    {
        var root = new Button
        {
            Classes = { "ghost" }, Content = "媒体库", Padding = new Thickness(6, 2),
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
        };
        root.Click += (_, _) => Nav.Top?.Invoke("NavLibrary");
        return new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 2,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                root,
                new TextBlock
                {
                    Text = "›", FontSize = 18, Classes = { "dim" },
                    VerticalAlignment = VerticalAlignment.Center,
                },
                H1(title),
            },
        };
    }

    /// <summary>
    /// 把「现在筛了什么」画成一行可去掉的片(草稿 08 页第 10 条)。
    ///
    /// <para>落地页那一档(类型 / 标签 / 工作室)<b>画出来但不给 ×</b>:
    /// 这一页存在的理由就是它,去掉之后这一页是什么就说不清了。</para>
    /// </summary>
    private void SyncActive()
    {
        _active.Children.Clear();
        if (_facet.Kind != "")
        {
            var what = _facet.Kind switch
            {
                "genre" => "类型", "tag" => "标签", _ => "工作室",
            };
            _active.Children.Add(Chips.Plain($"{what} · {_facet.Value}"));
        }
        var n = 0;
        if (_genre.SelectedIndex > 0)
        {
            n++;
            _active.Children.Add(Chips.Removable($"类型 · {_genre.SelectedItem}", () => Drop(_genre)));
        }
        if (_year.SelectedIndex > 0)
        {
            n++;
            _active.Children.Add(Chips.Removable($"年份 · {_year.SelectedItem}", () => Drop(_year)));
        }
        // 一条都没有时**连「清除」都不画** —— 一个点了什么都不会变的按钮比没有更糟
        if (n < 2) return;
        var clear = new Button { Classes = { "ghost" }, Content = "清除筛选" };
        clear.Click += (_, _) =>
        {
            _suppress = true;
            _genre.SelectedIndex = 0;
            _year.SelectedIndex = 0;
            _suppress = false;
            Requery();
        };
        _active.Children.Add(clear);
    }

    /// <summary>
    /// 自检:选一个类型 → 该出一个「类型 · X ✕」的片 → 点那个 ✕ → 该回到一条都没有。
    ///
    /// <para>「状态外显」这件事只有真渲染才验得到:片没画出来、× 点了不生效、
    /// 或者点完片还赖着不走,三样在编译期全是绿的。</para>
    /// </summary>
    internal void SelfCheckFilterChips()
    {
        if (_genre.ItemCount < 2)
        {
            Console.WriteLine("[筛选片] ✗ 类型下拉只有「全部类型」—— 假服务器没给分面?");
            return;
        }
        _genre.SelectedIndex = 1;
        Dispatcher.UIThread.Post(() =>
        {
            var chips = Labels();
            Console.WriteLine($"[筛选片] 选了「{_genre.SelectedItem}」之后:{Join(chips)}");
            var want = $"类型 · {_genre.SelectedItem}";
            if (!chips.Contains(want))
            {
                Console.WriteLine($"[筛选片] ✗ 没有「{want}」这一片 —— 筛了什么看不出来");
                return;
            }
            Drop(_genre);
            Dispatcher.UIThread.Post(() =>
            {
                var left = Labels();
                /* 两件都要判。只判片没没了的话,「✕ 只把片删掉、
                   筛选其实还在」这个真 bug 照样绿 —— 实测注入过。 */
                var cleared = _genre.SelectedIndex == 0;
                Console.WriteLine(left.Count == 0 && cleared
                    ? "[筛选片] ✓ 点 ✕ 之后那一片没了,筛选也跟着清了"
                    : $"[筛选片] ✗ 点 ✕ 之后还剩 {Join(left)},"
                      + $"类型下拉停在「{_genre.SelectedItem}」");
            }, DispatcherPriority.Background);
        }, DispatcherPriority.Background);
    }

    /// <summary>自检:换成列表<b>停在那儿</b>,给截图看。</summary>
    internal void SelfCheckShowList()
    {
        if (!GridView.IsList) _view.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        Dispatcher.UIThread.Post(() => Console.WriteLine(
            $"[版式] 列表版式:{_grid.GetVisualDescendants().OfType<MediaRow>().Count()} 行在屏上"),
            DispatcherPriority.Background);
    }

    private List<string> Labels() => _active.Children
        .SelectMany(c => c.GetVisualDescendants().OfType<TextBlock>())
        .Select(t => t.Text ?? "").Where(t => t != "" && t != "✕").ToList();

    private static string Join(List<string> xs) => xs.Count == 0 ? "(空)" : string.Join(" / ", xs);

    /// <summary>去掉一条筛选 = 把那个下拉拨回「全部」,再走同一条重查。</summary>
    private void Drop(ComboBox box)
    {
        box.SelectedIndex = 0; // 它自己会触发 SelectionChanged → Requery
    }

    private async Task LoadMore()
    {
        if (_busy || (_total >= 0 && _loaded >= _total)) return;
        _busy = true;
        var gen = _gen;
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
                    sort_by = by, sort_order = order, years,
                    // 落地页那一档压过下拉框:这一页存在的理由就是「只看这一个」
                    genres = _facet.Kind == "genre" ? [_facet.Value] : genres,
                    tags = _facet.Kind == "tag" ? new[] { _facet.Value } : null,
                    studio_ids = _facet.Kind == "studio" ? new[] { _facet.Value } : null,
                },
            });
            // 等这一趟网络的工夫里用户换了筛选:这批是旧筛选的结果,一个字都不能落地
            if (gen != _gen) return;
            var items = page.TryGetProperty("items", out var arr) && arr.ValueKind == JsonValueKind.Array
                ? arr.EnumerateArray().Select(CardItem.From).ToList() : [];
            _total = page.TryGetProperty("total", out var t) && t.ValueKind == JsonValueKind.Number
                ? t.GetInt32() : _loaded + items.Count;
            _loaded += items.Count;

            Dispatcher.UIThread.Post(() =>
            {
                if (gen != _gen) return;   // Post 排队期间换了筛选,同上
                // 第一页到了就把骨架撤掉。 换排序 / 换筛选时它不再回来 ——
                // 那时候屏幕上已经有内容了,再闪一次骨架反而像整页重载。
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
                if (gen != _gen) return;   // 旧筛选的失败别盖在新筛选的结果上
                // 失败时骨架也要撤:留着的话「加载失败」那行字底下还有一片在呼吸,
                // 用户会以为它还在重试。
                _first.IsVisible = false;
                _status.Text = $"加载失败:{LibraryPage.Advice(e)}";
            });
        }
        // 换过代就别动 _busy:那是新一轮的闩,这里放开会让两轮同时在跑
        finally { if (gen == _gen) _busy = false; }
    }
}
