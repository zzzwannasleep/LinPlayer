using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Animation.Easings;
using Avalonia.Animation;
using Avalonia.VisualTree;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 详情页(UI_PC §7.3)。
///
/// <para>「没值就整行不画,不留空位」:标语实测只有约三分之一的条目有,
/// 留空位的话大部分条目看上去像少加载了什么。</para>
/// </summary>
public sealed class DetailPage : PageBase
{
    private readonly CoreClient _core;
    private readonly string _server;
    private readonly Button _back = null!;

    /// <summary>分集。<b>和头部分开拉</b> —— 见构造函数里那段注释。</summary>
    private Task<List<CardItem>>? _episodesTask;
    private readonly ContentControl _episodesHost = new();
    /* 相似推荐。桌面端此前**整块没有**,而移动端一直有
       (用户 2026-09-12:「桌面端集/电影详情页需要优化,缺少很多东西,
       参考移动端集/电影详情页」)。异步补,拉不到就整块不画。 */
    private readonly ContentControl _similarHost = new();

    /// <summary>头图区(全宽出血)。</summary>
    private readonly ContentControl _heroHost = new();

    /// <summary>媒体信息 / 版本条的挂点(在播放按钮下面)。</summary>
    private readonly StackPanel _mediaHost = new() { Spacing = 10 };

    /// <summary>媒体信息那一整块(草稿 03 页第 20 条)。在正文里,不在头图右列。</summary>
    private readonly ContentControl _mediaBlocksHost = new();

    /// <summary>当前选中的版本 id。空 = 交给核心层按正则挑(preferred)。</summary>
    private string _versionId = "";

    /// <summary>
    /// 播放前选好的音轨 / 字幕,值是 <b>Emby 的流下标</b>(<c>MediaStream.Index</c>)。
    ///
    /// <para>-1 = 不指定(交给核心层的选轨正则);字幕另有 -2 = 明确不要字幕。</para>
    /// <para>存下标而不是存 mpv 的 track id:详情页这会儿 mpv 还没起,
    /// 拿不到 track-list。下标是**容器里的流序号**,两边说的是同一个东西
    /// (映射在 <see cref="PlayerPage"/> 里按 <c>ff_index</c> 做)。</para>
    /// </summary>
    private int _audioIndex = -1;
    private int _subIndex = -1;

    /// <summary>这一页有没有发过预热。发两遍不会错,但会白起一次请求。</summary>
    private bool _preloaded;

    /// <summary>
    /// 停在详情页时提前把这一片的头部拉到本地(<c>prefs.preloadItem</c>)。
    ///
    /// <para>这条命令核心层一直都在,而 UI 从来没调过 —— 又一条零调用命令。
    /// 后果有两个,都不报错:「预加载了多少就吐多少」那条口径在这一端没生效;
    /// 进度条缩略图整个不工作(它只读本地已缓存的字节)。
    /// fire-and-forget:等它 = 把一次预热做成了一次卡顿。</para>
    /// </summary>
    private void KickPreload(CoreClient core, Sess s, string itemId)
    {
        if (_preloaded) return;
        _preloaded = true;
        _ = core.PrefsPreloadItem(new
        {
            s.server, s.token, s.user_id, s.device_id,
            item_id = itemId, media_source_id = _versionId,
        });
    }

    /// <summary>主播放按钮 —— 换版本时要把它指向的版本一起换掉。</summary>
    private Button? _play;

    /* 换档时要重新量的四块。**按槽存不按表存** —— 用列表的话每次重画都会再挂一份,
       而详情页的重画路径是真实存在的(见 Redraw 那一段),挂两份就是同一块画两遍。 */
    private Action? _rescaleHead, _rescaleEpisodes, _rescalePeople, _rescaleCollection, _rescaleSimilar;

    public DetailPage(CoreClient core, string server, string itemId)
    {
        _core = core; _server = server;

        /* 窗口能拉到任意大小之后,**页面里那些写死的尺寸得自己跟上**
           (用户 2026-09-11:「里面的样式也要能够自由缩放才行呀」)。
           档位由 Responsive 量化到 8 档,所以这里不会每帧重建。 */
        Responsive.Watch(this, _ =>
        {
            _rescaleHead?.Invoke();
            _rescaleEpisodes?.Invoke();
            _rescalePeople?.Invoke();
            _rescaleSimilar?.Invoke();
            _rescaleCollection?.Invoke();
        });

        var body = new StackPanel { Spacing = 14 };
        /* 返回按钮在**数据回来之前**就得能点:详情拉了 10 秒还在转的时候,
           用户第一件想做的事就是退出去。所以它先挂上,渲染时再被搬进头图里。 */
        var back = new Button { Classes = { "ghost" }, Content = "← 返回", HorizontalAlignment = HorizontalAlignment.Left };
        back.Click += (_, _) => Nav.Back();
        _back = back;
        _heroHost.Content = new StackPanel { Margin = new Thickness(18, 18, 18, 0), Children = { back } };
        /* 占位用骨架,不是「加载中…」三个字 —— 详情页是全站内容最高的一页,
           从 20px 撑到 1200px 的那一跳最明显。 */
        Control busy = Skeleton.Detail();
        body.Children.Add(busy);

        /* 详情页<b>不能整页塞进 1560 的水槽里</b>。
           原来头图和正文一起被封在 1560 + 头部信息列又自己封了 900 ——
           1920 的窗口上右边有将近一半是**死白**,而背景大图本该铺在那儿。
           这一页的结构是:头图**全宽出血**,正文另外封顶。
           (旧 React 版就是这么分的:dt-hero 在 dt-body 外面。) */
        Content = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = new StackPanel
            {
                Spacing = 0,
                Children =
                {
                    _heroHost,
                    new Border
                    {
                        // 不封顶(和 PageBase.Scrolled 同一条口径,2026-09-02 用户点名去掉留白)
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        Padding = new Thickness(18, 18, 18, 26), Child = body,
                    },
                },
            },
        };

        _ = Task.Run(async () =>
        {
            try
            {
                var s = Nav.Session!;
                /* <b>with_children = false</b>。
                   原来是 true —— 核心层会在**同一条命令里**先拉条目、再把**全部分集**
                   拉完才返回。实测最长的剧全量拉 1.8MB / 1841ms,
                   于是海报、标题、简介、播放按钮这些**早就到手的东西**,
                   要陪着分集一起等将近两秒。用户说的「详情页加载慢」就是这一下。

                   现在拆成两条:头部先画(一次小请求),分集自己在后面补。
                   这正是本仓已经写过的那条教训 —— 「不秒加载」的根因是加载结构里的屏障,
                   不是渲染慢。首页早就是各轨道各自渲染了,详情页这里漏了。 */
                /* <b>缓存先行</b>(用户 2026-09-03:「各个页面的封面、简介、元数据
                   都是可以缓存的,这样下次打开就很快了…其他页面也一样」)。
                   详情页是全站被反复进出最多的一页 —— 看完一集退出来再点进去,
                   海报、简介、标签这些**一个字都没变**,却要再等一次完整往返。 */
                var key = MetaCache.Key("emby.itemDetail", new { s.server, item_id = itemId });
                var cached = MetaCache.Peek(key);
                if (cached is { ValueKind: JsonValueKind.Object } c0)
                {
                    if (Str(c0, "type_") is "Series" or "Season") _episodesTask = LoadEpisodes(itemId);
                    else if (Str(c0, "type_") == "BoxSet") _ = FillCollection(itemId);
                    Dispatcher.UIThread.Post(() => Paint(c0));
                    if (_episodesTask is not null)
                    {
                        PaintEpisodesFromCache(itemId);   // 必须排在 Paint 之后,见方法注释
                        _ = FillEpisodes();
                    }
                }

                var d = await core.EmbyItemDetail(new
                {
                    s.server, s.token, s.user_id, s.device_id,
                    item_id = itemId, with_children = false,
                });
                MetaCache.Put(key, d);
                /* 内容一个字没变就<b>不要重画</b>。
                   重画一次这一页要重建海报、按钮、分集网格 —— 用户看到的是
                   「刚出来的页面当场闪一下又变回同样的样子」,那看着像 bug。
                   比的是整段原文,不是挑几个字段:挑字段就得跟着核心层的输出走,
                     漏一个就成了「改了不刷新」。 */
                if (cached is { } c1 && c1.GetRawText() == d.GetRawText()) return;

                // 是剧 / 季才有分集。 在渲染之前就发出去,让它和布局并行跑。
                var type = Str(d, "type_");
                if (type is "Series" or "Season") _episodesTask = LoadEpisodes(itemId);
                /* ☠ **合集原来一个字都画不出来。** 这条判断和 core 的 withChildren
                   判断一样只认 Series/Season,而合集本身没有简介、没有年份、
                   没有演职员 —— 整页就只剩一个标题(用户 2026-09-08:
                   「合集无法正确显示,显示不出来任何的东西」)。 */
                else if (type == "BoxSet") _ = FillCollection(itemId);

                Dispatcher.UIThread.Post(() => Paint(d));
                if (_episodesTask is not null)
                {
                    PaintEpisodesFromCache(itemId);   // 必须排在 Paint 之后,见方法注释
                    await FillEpisodes();
                }
                return;

                void Paint(JsonElement data)
                {
                    _paint = Paint;
                    _painted = data;
                    KickPreload(core, s, itemId);
                    body.Children.Remove(busy);
                    /* 渲染要有边界。这一页的渲染抛异常时**整个进程会当场退出** ——
                       没有对话框、没有日志窗口,用户看到的是「点了详情,软件没了」。
                       (刚刚就撞上了一次:一个控件同时挂两处。)
                       Rust 版为此有 PageBoundary,这边一直没有对应的东西。 */
                    // 重画之前先清干净:缓存那一版已经把整页画出来了,
                    // 不清的话真数据会**再叠一份**上去(标题海报按钮全出现两遍)。
                    body.Children.Clear();
                    try { Render(body, data); }
                    catch (Exception re)
                    {
                        _renderFailed = re.Message;
                        body.Children.Clear();
                        body.Children.Add(Loose(_back));
                        body.Children.Add(Dim($"这一页画不出来:{re.Message}"));
                        Console.WriteLine("[详情页] 渲染失败: " + re);
                    }
                }
            }
            catch (Exception e)
            {
                var why = LibraryPage.Advice(e);
                Dispatcher.UIThread.Post(() =>
                {
                    var at = body.Children.IndexOf(busy);
                    if (at >= 0) body.Children[at] = Dim($"加载失败:{why}");
                });
            }
        });
    }

    /// <summary>
    /// 拉分集。<b>一次拉不完就接着拉</b>(服务端单页有上限)。
    ///
    /// <para>不做「滚到底再拉」:剧集详情页是按季分组的,少一半集会让某一季整个空掉,
    /// 而用户看不出那是「还没拉完」还是「这季就这么几集」。</para>
    /// </summary>
    private async Task<List<CardItem>> LoadEpisodes(string itemId)
    {
        var all = new List<CardItem>();
        try
        {
            var s = Nav.Session!;
            var key = MetaCache.Key("emby.seasonEpisodes", new { s.server, parent_id = itemId });
            while (true)
            {
                var page = await _core.EmbySeasonEpisodes(new
                {
                    s.server, s.token, s.user_id, s.device_id,
                    parent_id = itemId, start_index = all.Count, limit = 200,
                });
                var got = page.TryGetProperty("items", out var arr) && arr.ValueKind == JsonValueKind.Array
                    ? arr.EnumerateArray().Select(CardItem.From).ToList() : [];
                // 空页就停。只看 total 的话,服务端 total 报大了就是个死循环。
                if (got.Count == 0) break;
                all.AddRange(got);
                var total = page.TryGetProperty("total", out var t) && t.ValueKind == JsonValueKind.Number
                    ? t.GetInt32() : all.Count;
                if (all.Count >= total) break;
            }
            MetaCache.PutList(key, all.Select(CardItem.ToJson).ToList());
        }
        /* 分集拉不动**不该让整页失败** —— 头部已经在屏幕上了。
            而且这时候要<b>回落到缓存</b>:离线 / 服务器抽风时,
            上一次拉到的分集表仍然是能看的东西,给一张空表等于白白丢掉它。 */
        catch
        {
            var s2 = Nav.Session;
            if (s2 is not null && MetaCache.PeekList(
                    MetaCache.Key("emby.seasonEpisodes", new { s2.server, parent_id = itemId }))
                is { Count: > 0 } old)
                return old.Select(CardItem.From).ToList();
        }
        return all;
    }

    /// <summary>
    /// 合集的成员。**影片和剧集分成两段**(用户 2026-09-08:「合集要把影片和剧集分开,
    /// 方便用户查找」)。
    ///
    /// <para>分堆在核心层做(<c>emby.collectionItems</c>)——两端各分一次的话,
    /// 迟早会在「其它类型往哪儿归」上分叉,而那种不一致没人会报上来。</para>
    /// </summary>
    private async Task FillCollection(string itemId)
    {
        var s = Nav.Session;
        if (s is null) return;
        var key = MetaCache.Key("emby.collectionItems", new { s.server, item_id = itemId });
        // 缓存先行,和详情主体同一条口径:合集页也是会被反复进出的
        if (MetaCache.Peek(key) is { ValueKind: JsonValueKind.Object } hit)
            Dispatcher.UIThread.Post(() => PaintCollection(hit));
        try
        {
            var r = await _core.EmbyCollectionItems(new
            {
                s.server, s.token, s.user_id, s.device_id, item_id = itemId,
            });
            MetaCache.Put(key, r);
            Dispatcher.UIThread.Post(() => PaintCollection(r));
        }
        catch (Exception e)
        {
            // 已经有缓存就别用报错盖掉它 —— 那是「本来看得见,刷新一下没了」
            if (MetaCache.Peek(key) is { ValueKind: JsonValueKind.Object }) return;
            Dispatcher.UIThread.Post(() =>
                _episodesHost.Content = Dim($"这个合集拉不出来:{LibraryPage.Advice(e)}"));
        }
    }

    private void PaintCollection(JsonElement r)
    {
        _rescaleCollection = () => PaintCollection(r);
        var host = new StackPanel { Spacing = 18 };
        void Section(string title, string field, bool wide)
        {
            var items = r.TryGetProperty(field, out var arr) && arr.ValueKind == JsonValueKind.Array
                ? arr.EnumerateArray().Select(CardItem.From).ToList() : [];
            if (items.Count == 0) return;   // 一部电影都没有的合集,不画一行空标题
            host.Children.Add(H2($"{title} · {items.Count}"));
            host.Children.Add(Carousel.Rail(items,
                it => new Card(_core, _server, it, wide,
                    x => Nav.Push(new DetailPage(_core, _server, x.Id)),
                    width: wide ? EpisodeCardWidth : Responsive.S(Bounds.Width, 168, 112)),
                wide ? EpisodeCardWidth * 9 / 16
                    : Responsive.S(Bounds.Width, 168, 112) * 3 / 2, out _));
        }
        // 影片在前:合集绝大多数是电影系列,把它排在剧集后面等于每次都要多滚一屏
        Section("影片", "movies", false);
        Section("剧集", "series", false);
        Section("其它", "others", false);
        _episodesHost.Content = host.Children.Count > 0
            ? host
            // 说清是「空的」而不是「没拉到」。空着的话和还在加载长得一样。
            : Dim("这个合集里没有内容(或者服务器没有返回)。");
    }

    /// <summary>分集列表最近一次画出来的那一份(原文)。用来判「真数据和缓存一个字没变」。</summary>
    private string _episodesRaw = "";

    /// <summary>
    /// 分集缓存先行:命中就当场画,一次往返都不等。
    ///
    /// <para>用户 2026-09-04:「季详情页加载有点慢」。根因不是命令慢,是分集这一块
    /// 从来没吃过缓存 —— 主体早就走了缓存先行,分集只在请求失败时才回落。
    /// 于是每次进来上半页秒出、下半页干等一次往返,而要画的东西一个字都没变。
    /// 必须排在 <c>Paint()</c> 那次 Post 之后:Paint 会把内容重置成骨架。</para>
    /// </summary>
    private void PaintEpisodesFromCache(string itemId)
    {
        var s = Nav.Session;
        if (s is null) return;
        var hit = MetaCache.PeekList(
            MetaCache.Key("emby.seasonEpisodes", new { s.server, parent_id = itemId }));
        if (hit is not { Count: > 0 }) return;
        var raw = string.Concat(hit.Select(x => x.GetRawText()));
        var eps = hit.Select(CardItem.From).ToList();
        Dispatcher.UIThread.Post(() =>
        {
            _episodesRaw = raw;
            _episodesHost.Content = Episodes(eps);
        });
    }

    /// <summary>分集到了,把骨架换成真内容。</summary>
    private async Task FillEpisodes()
    {
        var eps = await _episodesTask!;
        var raw = string.Concat(eps.Select(e => CardItem.ToJson(e).GetRawText()));
        /* 一个字没变就<b>不重画</b>。重画一次要重建整条分集轨 ——
           用户看到的是「刚出来的列表当场闪一下又变回同样的样子」,那看着像 bug。
           (和详情主体那边同一条口径。) */
        if (raw == _episodesRaw && _episodesRaw != "") return;
        Dispatcher.UIThread.Post(() =>
        {
            _episodesRaw = raw;
            _episodesHost.Content = eps.Count > 0
                ? Episodes(eps)
                // 说清是「没有」而不是「没拉到」。空着的话和还在加载长得一样。
                : Dim("这部剧下面没有分集(或者服务器没有返回)。");
        });
    }

    /// <summary>
    /// 把控件从它现在挂着的地方摘下来,再交给新家。
    ///
    /// <para>「反复几次突然报 already has a visual parent」的根因不是「快速」,
    /// 是这一页会画两遍(缓存先行一遍、真数据再一遍),而 <c>Children.Clear()</c>
    /// 只摘得掉直接孩子 —— <see cref="_mediaHost"/> 挂在头图里好几层深。
    /// 从继续观看进来的集详情必然走两遍(续播位置变了,两份逐字比对必不相等),
    /// 所以它不是偶发。修在一处:跨渲染留着的控件,挂之前都过这一道。</para>
    /// </summary>
    private static T Loose<T>(T c) where T : Control
    {
        switch (c.Parent)
        {
            case Panel p: p.Children.Remove(c); break;
            case ContentControl cc when ReferenceEquals(cc.Content, c): cc.Content = null; break;
            case Decorator dec when ReferenceEquals(dec.Child, c): dec.Child = null; break;
        }
        return c;
    }

    /// <summary>最近画的那一份数据 + 画它的那个闭包。自检要用它逼出「第二遍」。</summary>
    private Action<JsonElement>? _paint;
    private JsonElement _painted;

    /// <summary>这一遍渲染有没有掉进兜底。<b>自检的判据必须看它</b> —— 兜底把异常吞了,
    /// 只看「有没有抛出来」的话,一页画不出来的详情页照样是绿的。</summary>
    private string? _renderFailed;

    /// <summary>
    /// 自检:<b>把这一页再画一遍</b>(<c>LP_SELFCHECK_REPAINT=1</c>)。
    ///
    /// <para>这条钩子对着的是真实路径:缓存先行 + 真数据不同 = 每天都会走的两遍渲染。
    /// 反向注入验红的方法是把上面几处 <c>Loose(...)</c> 去掉一个 ——
    /// 去掉哪一个都会在这里抛,而抛出来的正是用户报的那句话。</para>
    /// </summary>
    internal void SelfCheckRepaint()
    {
        if (_paint is null) { Console.WriteLine("[详情页重画] · 第一遍还没画完,跳过"); return; }
        _renderFailed = null;
        try
        {
            _paint(_painted);
            if (_renderFailed is { } why)
            {
                Console.WriteLine("[详情页重画] ✗ 第二遍掉进渲染兜底了:" + why);
                return;
            }
            Console.WriteLine("[详情页重画] ✓ 第二遍画完了,没抛 —— 跨渲染留着的控件都摘干净了");
        }
        catch (Exception e)
        {
            Console.WriteLine("[详情页重画] ✗ 第二遍抛了:" + e.Message);
        }
    }

    private void Render(StackPanel body, JsonElement d)
    {
        var id = Str(d, "id");
        var type = Str(d, "type_");
        var name = Str(d, "name");
        var series = Str(d, "series_name");
        var isShow = type is "Series" or "Season";

        // ---- ① 头图:全宽出血 ----
        _heroHost.Content = Hero(d, id, type, name, series);

        // ---- ② 分集 ----
        /* 分集这会儿<b>还没到</b>(它是第二条命令)。先放和真内容同尺寸的骨架 ——
           放「加载中…」三个字的话,内容到了这一块会从 20px 撑到上千像素,
           用户正在读的简介会被顶走。 */
        if (isShow)
        {
            _episodesHost.Content = Skeleton.Grid(true, 8, EpisodeCardWidth);
            body.Children.Add(Loose(_episodesHost));
        }
        // 合集的成员和分集共用这个挂点:两者是同一件事(「这个条目下面有什么」),
        // 各挂一个的话重画时要记得清两处,而漏清的表现是内容叠两份。
        else if (type == "BoxSet")
        {
            _episodesHost.Content = Skeleton.Grid(false, 8, Responsive.S(Bounds.Width, 168, 112));
            body.Children.Add(Loose(_episodesHost));
        }

        // ---- 演职人员 ----
        /* 一行,左右滑(用户 2026-09-03:「演职人员信息一样,可以左右滑动,
           不需要按钮查询了就」—— 即:要滑动,但不要季/集那两个下拉)。
            原来是 WrapPanel + `Take(24)`:折成三四行占掉半屏,而且**第 25 位之后
             的人根本看不到**,还没有任何东西说明它被截断了。
             改成横轨之后全表都在,而虚拟化保证只造屏幕上那几张。 */
        var people = Arr2(d, "people");
        if (people.Count > 0)
        {
            body.Children.Add(H2($"演职人员 · {people.Count} 人"));
            // 头像 84 在窄窗口上一排只摆得下三个,换档要整条重建(虚拟化下只造屏上那几个)
            var peopleHost = new ContentControl();
            _rescalePeople = () =>
            {
                var av = Responsive.S(Bounds.Width, 84, 56);
                peopleHost.Content = Carousel.Rail(people, x => PersonCell(x, av), av, out _);
            };
            _rescalePeople();
            body.Children.Add(peopleHost);
        }

        // ---- 媒体信息 ----
        // 挂点先摆上,内容跟着版本表一起补(LoadMedia)。电影 / 分集才有版本。
        body.Children.Add(Loose(_mediaBlocksHost));

        // ---- 相似推荐 ----
        // 挂点先摆上,内容异步补:为了这一块让整页晚出来是本末倒置,
        // 而它又常常是空的(刮削不全的库上 Similar 直接回空)
        body.Children.Add(Loose(_similarHost));
        _ = LoadSimilar(id);
    }

    /// <summary>
    /// 相似推荐。<b>拉不到 / 没有就整块不画</b> —— 摆一个「暂无相似内容」的空标题
    /// 比没有更糟:它占着一屏高度,而且每次进详情页都提醒一次「这里本该有东西」。
    /// </summary>
    private async Task LoadSimilar(string id)
    {
        List<CardItem> items;
        try
        {
            var s = Nav.Session!;
            var r = await _core.EmbySimilarItems(new
            {
                s.server, s.token, s.user_id, s.device_id, item_id = id, limit = 12,
            });
            items = r.ValueKind == JsonValueKind.Array
                ? r.EnumerateArray().Select(CardItem.From).ToList() : [];
        }
        catch
        {
            // 拉不到就当没有。相似推荐是锦上添花,为它把详情页拖红不值当
            return;
        }
        if (items.Count == 0) return;
        Dispatcher.UIThread.Post(() =>
        {
            var host = new ContentControl();
            _rescaleSimilar = () =>
            {
                var w = Responsive.S(Bounds.Width, 168, 112);
                host.Content = Carousel.Rail(items,
                    it => new Card(_core, _server, it, false,
                        LibraryPage.OpenDetail(_core, _server), width: w),
                    w * 3 / 2, out _);
            };
            _rescaleSimilar();
            _similarHost.Content = new StackPanel
            {
                Spacing = 14, Children = { H2($"相似推荐 · {items.Count}"), host },
            };
        });
    }

    /// <summary>演职人员一格:圆头像 + 姓名 + 角色。</summary>
    private Control PersonCell(JsonElement p, double size)
    {
        var av = new Border
        {
            Width = size, Height = size, CornerRadius = new CornerRadius(999), ClipToBounds = true,
            Background = Tok.Of("PanelAlt"),
        };
        if (Bool(p, "has_primary"))
        {
            var im = new Image { Stretch = Stretch.UniformToFill, Opacity = 0, Classes = { "art" } };
            av.Child = im;
            _ = Fill(im, Images.EmbyImageUrl(_server, Str(p, "id"), "Primary"), 168);
        }
        else
        {
            /* 没有头像时放姓氏,不留一个空圆。
               演职员表里**大半都没有头像**(刮削器很少刮全),
               一排空圆看着像加载失败,而它其实已经加载完了。 */
            av.Child = new TextBlock
            {
                Text = Str(p, "name") is { Length: > 0 } nm ? nm[..1] : "?",
                FontSize = 30, FontWeight = FontWeight.SemiBold,
                Foreground = Tok.Of("Ink3"),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
        }
        // 头像可点 → 人物详情。做成 Button 而不是给 Border 挂 PointerPressed:
        // Button 自带 hover / focus / 键盘可达,手写那三样迟早漏一个。
        var pid = Str(p, "id");
        var pname = Str(p, "name");
        var cell = new Button
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(0),
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
        };
        cell.Click += (_, _) => Nav.Push(new PersonPage(_core, _server, pid, pname));
        cell.Content = new StackPanel
        {
            Width = size * 100 / 84, Spacing = 6, Margin = new Thickness(0, 0, 10, 6),
            Children =
            {
                av,
                new TextBlock
                {
                    Text = pname, FontSize = 12, MaxLines = 2,
                    TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center,
                },
                new TextBlock
                {
                    Text = Str(p, "role"), FontSize = 11, MaxLines = 1,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    TextAlignment = TextAlignment.Center,
                    Foreground = Tok.Of("Ink3"),
                },
            },
        };
        return cell;
    }


    /// <summary>
    /// 头图:背景大图出血 + 海报 + 标题信息。
    ///
    /// <para>这一块<b>不受正文 1560 水槽约束</b>,背景图铺满整个内容区宽度;
    /// 里面的文字和海报仍然按 1560 对齐,和下面的正文成一条线。
    /// 都封在 1560 里的话,1920 窗口上图只占中间一条,两侧是死白 ——
    /// 那不叫背景图,那叫一张插图。</para>
    /// </summary>
    private Control Hero(JsonElement d, string id, string type, string name, string series)
    {
        /* <b>集封面是横的,海报是竖的 —— 两种图不能塞进同一个槽</b>
           (用户 2026-09-03:「集封面和海报封面/季封面是不一样的,集封面是横着的」)。
           Emby 给分集的 Primary 是一张 16:9 的**剧照**;塞进 220×330 的 2:3 槽里
           再 UniformToFill,等于把左右各裁掉三分之一 —— 人脸经常就在被裁掉的那一侧。
           而且它**不报错**:画面是满的,只是内容错了。
           392×220 是同一个 16:9,高度比海报矮一截 —— 分集本来也没有那么多头部信息要配。 */
        var still = type is "Episode";
        var poster = new Border
        {
            Width = still ? 392 : 220, Height = still ? 220 : 330,
            CornerRadius = new CornerRadius(10), ClipToBounds = true,
            VerticalAlignment = VerticalAlignment.Top,
            Background = Tok.Of("PanelAlt"),
        };
        TextBlock? crumbRef = null;
        if (Bool(d, "has_primary"))
        {
            var im = new Image { Stretch = Stretch.UniformToFill, Opacity = 0, Classes = { "art" } };
            poster.Child = im;
            _ = Fill(im, Images.EmbyImageUrl(_server, id, "Primary"), still ? 440 : 660);
        }

        var head = new StackPanel { Spacing = 10 };
        /* 剧名单独一行,而且**点得动** —— Emby 上点集详情页的剧名就回到剧集主页,
           我们原来把它和集名拼成一句话(「剧名 · 第 3 集」),那一整句都是死的:
           从某一集想回到整部剧,只能一路按返回(用户 2026-09-11)。
           ★ 判据是拿不拿得到 series_id:刮削不全的库上这个字段是空的,
             那时候照旧只显示文字,不摆一个点了没反应的链接。 */
        var seriesId = Str(d, "series_id");
        if (!string.IsNullOrEmpty(series))
        {
            var crumb = new TextBlock
            {
                Text = series, FontSize = 15, FontWeight = FontWeight.SemiBold,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = Tok.Of(seriesId.Length > 0 ? "Accent" : "Ink2"),
                HorizontalAlignment = HorizontalAlignment.Left,
            };
            if (seriesId.Length > 0)
            {
                crumb.Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand);
                ToolTip.SetTip(crumb, "回到《" + series + "》");
                crumb.PointerPressed += (_, _) => Nav.Push(new DetailPage(_core, _server, seriesId));
            }
            head.Children.Add(crumb);
            crumbRef = crumb;
        }
        var titleRef = new TextBlock
        {
            Text = name,
            FontSize = 34, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap,
        };
        head.Children.Add(titleRef);

        /* 元信息做成<b>一排小片</b>,不是一串用「·」连起来的长句。
           连成一句的问题不是不好看:它<b>不换行</b>,类型一多就被挤出可视区,
           而且年份、评分、分级、类型是四种不同的东西,拿同一个分隔符串起来
           等于告诉眼睛「它们是一类」。片状可以自然折行,也能一眼数清有几项。 */
        var chips = new WrapPanel();
        void Chip(string t) => chips.Children.Add(Views.Chips.Plain(t));

        /* 类型 / 标签 / 工作室这三种片是**能点的**
           【用户定 2026-09-12:「同时支持点击 标签 工作室 类型 的跳转」】。
           年份、评分、分级那几种不给点:它们要么不是一个可以「按它列一串」的维度,
           要么点出来是全库。能点和不能点长得不一样,别让人去试。 */
        void Jump(string kind, string label, string value)
        {
            if (label == "" || value == "") return;
            chips.Children.Add(Views.Chips.Clickable(label,
                () => Nav.Push(new LibraryGridPage(_core, _server, "", label, (kind, value)))));
        }
        if (Num(d, "year") > 0) Chip(((int)Num(d, "year")).ToString());
        if (Num(d, "rating") > 0) Chip($"★ {Num(d, "rating"):0.0}");
        Chip(StatusText(Str(d, "status")));
        Chip(Str(d, "official_rating"));
        if (Num(d, "runtime_secs") > 0) Chip($"{(int)(Num(d, "runtime_secs") / 60)} 分钟");
        /* 剧的季数用 child_count(Series 上它就是季数)。
            集数<b>不在这儿写</b> —— 分集还没拉回来,写不出来。
             它在下面「剧集 · N 季 · 共 M 集」那一行,那时候数据已经在手上了。
             为了凑一个数去等分集,等于把整个头部又拖回去等那 1.8MB。 */
        if (type == "Series" && Num(d, "child_count") > 0) Chip($"{(int)Num(d, "child_count")} 季");
        foreach (var g in Arr(d, "genres").Take(4)) Jump("genre", g, g);
        foreach (var t in Arr(d, "tags").Take(6)) Jump("tag", t, t);
        /* 工作室点过去要带 **id 不是名字** —— 实测(Emby 4.9.5)`Studios=<名字>`
           被完全无视,返回全库 1673 条;`StudioIds=` 才精确命中。 */
        foreach (var st in Named(d, "studios").Take(4)) Jump("studio", st.Name, st.Id);
        if (chips.Children.Count > 0) head.Children.Add(chips);

        // 标语:没有就整行不画(实测只有约三分之一的条目有)
        var tagline = Str(d, "tagline");
        if (tagline != "")
        {
            head.Children.Add(new TextBlock
            {
                Text = tagline, FontStyle = FontStyle.Italic, TextWrapping = TextWrapping.Wrap,
                Foreground = Tok.Of("Ink2"),
            });
        }

        /* 简介放在<b>头图右列</b>,不放到正文里。
           放正文的话头图右边那一大片是空的 —— 1920 的窗口上,
           标题 + 几个小片只占掉左边 40%,剩下 60% 什么都没有,
           而简介正是唯一一段「宽度越大越好读」的内容。
           (Emby 自己的详情页也是这么排的。) */
        var overview = Str(d, "overview");
        if (overview != "") head.Children.Add(Overview(overview));

        head.Children.Add(PlayRow(d, id, type));
        /* 媒体信息 / 版本条。**异步补,不挡头部** ——
           它要多打一次 PlaybackInfo,为了这一行让海报标题晚出来是本末倒置。 */
        head.Children.Add(Loose(_mediaHost));
        if (type is "Movie" or "Episode" or "Video" or "MusicVideo") _ = LoadMedia(id);

        var headRow = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 26,
            Children = { poster, head },
        };
        /* ☠☠ **窄窗口上这一行必须改成上下排。**
           海报本身就 220 宽,内容区只剩 330 时它和右边那一列是抢同一条宽度 ——
           StackPanel 不报错,只是把标题、小片、简介、播放键整片挤到画面外面去。
           620 是实测的分界:低于它右列已经窄到简介一行放不下十个字。
           海报与标题的字号另外按档缩,比例(2:3 / 16:9)原样保住。 */
        _rescaleHead = () =>
        {
            var w = Bounds.Width;
            var narrow = w > 1 && w < 620;
            headRow.Orientation = narrow ? Orientation.Vertical : Orientation.Horizontal;
            headRow.Spacing = narrow ? 14 : 26;
            poster.Width = Responsive.S(w, still ? 392 : 220, still ? 208 : 116);
            poster.Height = poster.Width * (still ? 220.0 / 392 : 330.0 / 220);
            titleRef.FontSize = Responsive.Font(w, 34, 21);
            if (crumbRef is not null) crumbRef.FontSize = Responsive.Font(w, 15, 12.5);
        };
        _rescaleHead();
        // 返回按钮盖在背景图上,不压在它上面一行 —— 压在上面的话图是从页面
        // 中间才开始的,顶上留一条黑边。换父之前先 Loose 一手,见它的注释。
        _back.Margin = new Thickness(0, 0, 0, 14);
        var inner = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(18, 18, 18, 18),
            Child = new StackPanel { Spacing = 0, Children = { Loose(_back), headRow } },
        };
        return Backdrop(d, id, inner);
    }

    /// <summary>
    /// 简介。<b>默认收起到 4 行,长了给「展开」</b>。
    ///
    /// <para>不收的话一段十几行的简介会把分集整个推到折线以下 ——
    /// 而进详情页最常见的动作是找集,不是读简介。</para>
    /// <para>短简介不画「展开」:一个点了什么都不会变的按钮比没有更糟。</para>
    /// </summary>
    private static Control Overview(string text)
    {
        var tb = new TextBlock
        {
            Text = text, TextWrapping = TextWrapping.Wrap, LineHeight = 23,
            MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Left,
            Foreground = Tok.Of("Ink"),
            MaxLines = 3, TextTrimming = TextTrimming.CharacterEllipsis,
        };
        var box = new StackPanel { Spacing = 6, Children = { tb } };
        // 3 行 × 每行约 45 个中文字 —— 到不了这个量就不可能被截,没必要给一个点了不动的按钮
        if (text.Length <= 135) return box;

        var more = new Button { Classes = { "ghost" }, Content = "展开", HorizontalAlignment = HorizontalAlignment.Left };
        more.Click += (_, _) =>
        {
            var open = (string?)more.Content == "展开";
            tb.MaxLines = open ? 0 : 3;
            more.Content = open ? "收起" : "展开";
        };
        box.Children.Add(more);
        return box;
    }

    /// <summary>
    /// 媒体信息 + 播放前四选:版本 / 音轨 / 字幕 / 线路。
    ///
    /// <para>上一版只做了版本,理由是「音轨/字幕播放页抽屉里已经有了」——
    /// 这条判断被推翻了:在播放页改字幕意味着片子已经用错的轨道解码了几秒,
    /// 而线路更是起播之后再换就要重开流。每个下拉只在有得选时才画(&gt;1 项),
    /// 字幕例外 —— 它还带着「不要字幕」。默认落在核心层挑中的那条(preferred),
    /// 落第一条就是「界面在撒谎」。</para>
    /// </summary>
    private async Task LoadMedia(string itemId)
    {
        List<JsonElement> vers;
        try
        {
            var s = Nav.Session!;
            var d = await _core.EmbyItemMedia(new
            {
                s.server, s.token, s.user_id, s.device_id, item_id = itemId,
            });
            vers = d.ValueKind == JsonValueKind.Array ? d.EnumerateArray().ToList() : [];
        }
        catch { return; } // 拿不到就整块不画 —— 详情页主体已经在屏幕上了
        if (vers.Count == 0) return;

        /* 版本<b>按文件体积从大到小</b>排(用户 2026-09-04:「版本选择那里
           增加一个排序逻辑,按从大到小排序」)。多版本的片子里体积基本就是画质档
           —— 4K 原盘 / 1080p / 一个小转码档;服务端给的顺序是**入库顺序**,
           和用户想先看到的顺序没有任何关系。
           排序必须排在算 <c>pick</c> <b>之前</b> —— pick 是**下标**,
             先算后排的话它会指到另一条上,而那正是「界面在撒谎」那个老坑。
           拿不到体积的排最后(<c>Num</c> 缺字段给 0):没有 size_bytes 多半是
             转码 / 流式源,把它顶到最前面等于把最差的一条推给用户。
           OrderByDescending 是稳定排序 —— 体积相同的几条保持服务端的原顺序。 */
        vers = vers.OrderByDescending(v => Num(v, "size_bytes")).ToList();

        /* 默认落在**核心层挑中的那一条**(preferred),不是第一条。
           落第一条的话:正则明明选对了版本,详情页却在说另一条 ——
           「界面在撒谎」那个老坑就是这么来的。 */
        var pick = vers.FindIndex(v => Bool(v, "preferred"));
        if (pick < 0) pick = 0;

        Dispatcher.UIThread.Post(() =>
        {
            _mediaHost.Children.Clear();
            var line = Dim("");
            // 四个选择器排一行,放不下自己折行 —— 窄窗口下不会把标题挤出去
            var picks = new WrapPanel();
            var tracksHost = new StackPanel { Orientation = Orientation.Horizontal };

            _vers.Clear();
            foreach (var v in vers) _vers.Add(new VerPick(_server, "", "", true, "", v));

            /* 版本键做成**和选集栏同一副样子**(chip + 浮层),不是下拉框
               (用户 2026-09-05:「做成和选集栏一样的样式」)。
               ComboBox 在这里有两个治不了的毛病:它的每一项只能是一行纯文本,
                 装不下「哪台服务器 + 画质 + 体积」这三样;而跨服聚合进来之后
                 这个列表会长到十几条,下拉框没有分组、没有小标题。 */
            var verBtn = new Button { Classes = { "chip" }, Margin = new Thickness(0, 0, 14, 6) };
            verBtn.Click += (_, _) => Flyout(verBtn, VersionMenu(i => Use(i)));

            void Use(int i)
            {
                if (i < 0 || i >= _vers.Count) return;
                var p = _vers[i];
                _versionId = Str(p.V, "id");
                // 跨服那几条要**连它那台的 item_id 一起记下**:起播拿错 id
                // 就是「选了乙服的 4K,却拿甲服的 id 去打乙服」——404 或者另一部片。
                _versionServer = p.Current ? "" : p.ServerId;
                _versionItem = p.Current ? "" : p.ItemId;
                verBtn.Content = VersionChipLabel(p);
                line.Text = MediaLine(p.V) + (p.Current ? "" : $"  ·  来自 {p.ServerName}({p.Reason})");
                // 换版本就要重建音轨 / 字幕两个下拉:不同版本的轨道表是两回事,
                // 留着上一版的表 = 用户选中一条这个文件里根本不存在的轨道。
                tracksHost.Children.Clear();
                _audioIndex = -1;
                _subIndex = -1;
                BuildTrackPickers(tracksHost, Arr2(p.V, "streams"));
            }
            _useVersion = Use;

            /* 只有一个版本时**先不画**这个键:一个点了什么都不会变的按钮比没有更糟。
               但别台可能还有别的版本 —— 真聚合出来了再把它插进去(见 _verCell)。 */
            _verCell = new ContentControl();
            if (vers.Count > 1) _verCell.Content = verBtn;
            _verBtn = verBtn;
            picks.Children.Add(_verCell);
            picks.Children.Add(tracksHost);
            _ = BuildLinePicker(picks);

            Use(pick);
            _mediaHost.Children.Add(picks);
            _mediaHost.Children.Add(line);
            _mediaBlocksHost.Content = MediaBlocks(vers);
            // 别台的版本**另起一趟拉**:它要在每台服上搜片 + 逐条拉全字段,
            // 一台就是好几个来回。挡在这儿的话本服的版本表要陪着一起等。
            _ = LoadCrossVersions(itemId);
        });
    }

    /// <summary>一条可选的版本。跨服那几条要连**它那台的** item_id 一起带着。</summary>
    private sealed record VerPick(
        string ServerId, string ServerName, string ItemId, bool Current, string Reason, JsonElement V);

    private readonly List<VerPick> _vers = [];
    private ContentControl? _verCell;
    private Button? _verBtn;
    private Action<int>? _useVersion;

    /// <summary>选中的版本在**哪台服务器**上。空 = 就是本页这台(绝大多数情况)。</summary>
    private string _versionServer = "";

    /// <summary>选中的版本在那台服务器上的条目 id。空 = 就是本页这个条目。</summary>
    private string _versionItem = "";

    /// <summary>
    /// 把别的服务器上的同一部片的版本**并进同一个列表**
    /// (用户 2026-09-05:「聚合不同服务器的版本,这样就可以方便用户选择了」)。
    ///
    /// <para><b>只追加,不重画</b>:浮层是每次点开现建的。重画一次的代价是
    /// 用户刚选好的音轨 / 字幕被悄悄清回「自动」,而他什么都没做。</para>
    /// <para>一台都没匹配上是常态(别的服务器上没有这部片),整段静默。</para>
    /// </summary>
    private async Task LoadCrossVersions(string itemId)
    {
        List<JsonElement> groups;
        try
        {
            var g = await _core.EmbyAggregateVersions(new { item_id = itemId, server_id = _server });
            groups = g.ValueKind == JsonValueKind.Array ? g.EnumerateArray().ToList() : [];
        }
        catch { return; }   // 别台的版本是增值项,拉不到不该在主体页面上留一行错误

        var add = new List<VerPick>();
        foreach (var g in groups)
        {
            if (Bool(g, "current")) continue;   // 本服那组第一趟已经拿过了
            var sid = Str(g, "server_id");
            var name = Str(g, "server_name") is { Length: > 0 } n ? n : sid;
            var iid = Str(g, "item_id");
            foreach (var v in Arr2(g, "versions").OrderByDescending(v => Num(v, "size_bytes")))
                add.Add(new VerPick(sid, name, iid, false, Str(g, "reason"), v));
        }
        if (add.Count == 0) return;

        Dispatcher.UIThread.Post(() =>
        {
            _vers.AddRange(add);
            // 本服只有一条版本时那个键还没画出来 —— 现在有得选了,补上
            if (_verCell is { Content: null } cell && _verBtn is { } b) cell.Content = b;
        });
    }

    /// <summary>版本键上写什么。 跨服那几条**必须带服务器名**,否则两条 2160p 分不清谁是谁。</summary>
    private static string VersionChipLabel(VerPick p)
    {
        var name = Str(p.V, "name") is { Length: > 0 } n ? n : "版本";
        return (p.Current ? name : $"{p.ServerName} · {name}") + "  ▾";
    }

    /// <summary>
    /// 版本浮层的内容。<b>按服务器分组</b>,每组一个小标题。
    ///
    /// <para>拌成一锅的话同一档画质在两台服上都有时,用户看到两条一模一样的
    /// 「2160p」,而点哪一条会从哪台起播,界面上一个字都没说
    /// (聚合搜索栽过同一个坑)。</para>
    /// </summary>
    private List<(string Label, Action? Go)> VersionMenu(Action<int> use)
    {
        var items = new List<(string, Action?)>();
        var head = "";
        for (var i = 0; i < _vers.Count; i++)
        {
            var p = _vers[i];
            var group = p.Current ? "本服务器" : p.ServerName;
            if (group != head)
            {
                head = group;
                items.Add((group, null));   // null = 小标题,不是可点项
            }
            var idx = i;
            var name = Str(p.V, "name") is { Length: > 0 } n ? n : $"版本 {i + 1}";
            var size = Size(p.V) is { Length: > 0 } sz ? $"  ·  {sz}" : "";
            items.Add((name + size, (Action?)(() => use(idx))));
        }
        return items;
    }

    /// <summary>一格「标签 + 下拉」。 右边留 12 —— 折行之后上下两行也对得齐。</summary>
    private static Control PickerCell(string label, Control input) => new StackPanel
    {
        Orientation = Orientation.Horizontal, Spacing = 10,
        Margin = new Thickness(0, 0, 14, 6),
        Children =
        {
            new TextBlock
            {
                Text = label, Classes = { "dim" }, FontSize = 12.5,
                VerticalAlignment = VerticalAlignment.Center,
            },
            input,
        },
    };

    /// <summary>
    /// 音轨 / 字幕两个下拉,由当前版本的流表生成。
    ///
    /// <para>送出去的是 Emby 的 <c>index</c>,播放页按 mpv 的 <c>ff_index</c> 对号。
    /// 两个下拉第一项都是「自动」,而且默认停在它。第一版默认落「服务器标了
    /// default 的那条」,那会盖掉核心层的选轨正则和「默认开启字幕」偏好 ——
    /// 表现是只要点进详情页字幕就被关掉,而用户什么都没选。
    /// 加一个选择器,不该改变不碰它时的行为。</para>
    /// </summary>
    private void BuildTrackPickers(StackPanel host, List<JsonElement> streams)
    {
        var audio = streams.Where(x => Str(x, "type_") == "Audio").ToList();
        var subs = streams.Where(x => Str(x, "type_") == "Subtitle").ToList();

        if (audio.Count > 1)
        {
            var box = new ComboBox { MinWidth = Responsive.S(Bounds.Width, 190, 130) };
            var labels = new List<string> { "自动(按设置里的偏好)" };
            labels.AddRange(audio.Select(StreamLabel));
            box.ItemsSource = labels;
            box.SelectedIndex = 0;
            box.SelectionChanged += (_, _) =>
                _audioIndex = box.SelectedIndex <= 0
                    ? -1 : (int)Num(audio[box.SelectedIndex - 1], "index");
            host.Children.Add(PickerCell("音轨", box));
        }

        if (subs.Count > 0)
        {
            var box = new ComboBox { MinWidth = Responsive.S(Bounds.Width, 190, 130) };
            // 第 0 项「自动」= -1(交给核心层),第 1 项「不加载」= -2,再往后才是真流
            var labels = new List<string> { "自动(按设置里的偏好)", "不加载字幕" };
            labels.AddRange(subs.Select(StreamLabel));
            box.ItemsSource = labels;
            box.SelectedIndex = 0;
            box.SelectionChanged += (_, _) => _subIndex = box.SelectedIndex switch
            {
                <= 0 => -1,
                1 => -2,
                _ => (int)Num(subs[box.SelectedIndex - 2], "index"),
            };
            host.Children.Add(PickerCell("字幕", box));
        }
    }

    /// <summary>一条流在下拉里怎么写。 轨道真名(title)优先,它才是压制组写的那个名字;
    /// display_title 是服务器拼的「语言 + 格式」,看着像名字但不是。</summary>
    private static string StreamLabel(JsonElement s)
    {
        if (Str(s, "title") is { Length: > 0 } t) return t;
        if (Str(s, "display_title") is { Length: > 0 } d) return d;
        var bits = new List<string>();
        if (Str(s, "language") is { Length: > 0 } l) bits.Add(l);
        if (Str(s, "codec") is { Length: > 0 } c) bits.Add(c.ToUpperInvariant());
        return bits.Count > 0 ? string.Join(" · ", bits) : "轨道 " + Num(s, "index");
    }

    /// <summary>
    /// 线路下拉。
    ///
    /// <para>线路是**服务器级**设置,这里改的是全局的当前线路 ——
    /// 但用户要的正是「起播之前把线换掉」,而这一页正是他决定要播什么的地方。
    /// 换完立刻生效,不用退出去进设置。</para>
    /// <para>只有一条(或者没有备用线路)就整个不画。</para>
    /// </summary>
    private async Task BuildLinePicker(Panel host)
    {
        List<JsonElement> lines;
        int active;
        string serverId;
        try
        {
            var accounts = await _core.AccountListAccounts();
            if (accounts.ValueKind != JsonValueKind.Array) return;
            var me = accounts.EnumerateArray()
                .FirstOrDefault(a => Str(a, "server") == _server);
            if (me.ValueKind != JsonValueKind.Object) return;
            lines = Arr2(me, "lines");
            active = (int)Num(me, "active_line");
            serverId = Str(me, "server");
        }
        catch { return; }   // 拿不到账号表就不画这一格 —— 它是增值项
        if (lines.Count < 2 || serverId == "") return;

        Dispatcher.UIThread.Post(() =>
        {
            var box = new ComboBox { MinWidth = Responsive.S(Bounds.Width, 190, 130) };
            box.ItemsSource = lines
                .Select((l, i) => Str(l, "name") is { Length: > 0 } n ? n : $"线路 {i + 1}")
                .ToList();
            box.SelectedIndex = active >= 0 && active < lines.Count ? active : 0;
            box.SelectionChanged += async (_, _) =>
            {
                var at = box.SelectedIndex;
                if (at < 0 || at == active) return;
                try
                {
                    await _core.AccountSetActiveLine(new { server_id = serverId, index = at });
                    active = at;
                }
                catch (Exception e) { Console.WriteLine("[详情页 换线路] " + e.Message); }
            };
            host.Children.Add(PickerCell("线路", box));
        });
    }

    // ---------------------------------------------------------------- 媒体信息

    /// <summary>流卡的宽。窄窗口下缩一档 —— 一张 200 宽的卡在 420 的内容区里只摆得下两张。</summary>
    private double StreamCardWidth => Responsive.S(Bounds.Width, 196, 148);

    /// <summary>
    /// 一条流(或者「常规」那一块)在卡上要写的几行。
    ///
    /// <para><b>抽成纯函数是为了能钉住它</b>:哪一行该出现、缺值时是不是整行不画,
    /// 这两件事错了都不报错,画面上只是少一行 —— 而少的那一行往往正是用户在找的。</para>
    /// <para>缺值一律**整行不画**,不写「未知」。</para>
    /// </summary>
    internal static List<(string K, string V)> StreamRows(JsonElement s)
    {
        var rows = new List<(string, string)>();
        void Add(string k, string v) { if (!string.IsNullOrEmpty(v)) rows.Add((k, v)); }

        switch (Str(s, "type_"))
        {
            case "Video":
                Add("编码", Str(s, "codec") is { Length: > 0 } vc ? CodecName(vc) : "");
                if (Num(s, "width") > 0 && Num(s, "height") > 0)
                    Add("分辨率", $"{(int)Num(s, "width")}×{(int)Num(s, "height")}");
                Add("码率", Mbps(Num(s, "bitrate")));
                if (Num(s, "frame_rate") > 0) Add("帧率", $"{Num(s, "frame_rate"):0.###} fps");
                // 制式决定要不要切软解(见杜比那条),值得单独一行
                Add("制式", Str(s, "video_range_type"));
                Add("规格", Str(s, "profile"));
                break;
            case "Audio":
                Add("编码", Str(s, "codec") is { Length: > 0 } ac ? CodecName(ac) : "");
                Add("语言", Str(s, "language"));
                Add("声道", Str(s, "channel_layout") is { Length: > 0 } cl ? cl
                    : Num(s, "channels") > 0 ? $"{(int)Num(s, "channels")} 声道" : "");
                Add("码率", Mbps(Num(s, "bitrate")));
                Add("轨道名", Str(s, "title"));
                break;
            case "Subtitle":
                Add("语言", Str(s, "language"));
                Add("格式", Str(s, "codec").ToUpperInvariant());
                Add("轨道名", Str(s, "title"));
                // 外挂字幕是**另一个文件**,要单独挂载 —— 它和内封的行为不一样,得说出来
                if (Bool(s, "is_external")) Add("来源", "外挂");
                break;
        }
        if (Bool(s, "is_default")) Add("默认", "是");
        return rows;
    }

    /// <summary>「常规」那一块:整个版本的容器 / 体积 / 总码率 / 时长。</summary>
    internal static List<(string K, string V)> VersionRows(JsonElement v)
    {
        var rows = new List<(string, string)>();
        void Add(string k, string s) { if (!string.IsNullOrEmpty(s)) rows.Add((k, s)); }
        Add("容器", Str(v, "container").ToUpperInvariant());
        Add("体积", Size(v));
        Add("总码率", Mbps(Num(v, "bitrate")));
        if (Num(v, "runtime_secs") >= 60) Add("时长", $"{(int)(Num(v, "runtime_secs") / 60)} 分钟");
        return rows;
    }

    /// <summary>码率的人话。0 / 缺值就是空串 —— 整行不画,不写「0 Mbps」。</summary>
    private static string Mbps(double bps) => bps <= 0 ? "" : $"{bps / 1_000_000.0:0.##} Mbps";

    /// <summary>
    /// 媒体信息(桌面草稿 03 页第 20 条)。<b>每个版本一整块竖排,块内每条流一张
    /// 纵向卡片横排全铺开</b>,不用点按钮切换 —— 和 Emby 官端一致。
    ///
    /// <para>原来这一块只有<b>一行文字</b>(「4K · HEVC · 18.4 GB · 3 条音轨 · 2 条字幕」):
    /// 想知道第二条音轨是什么语言、字幕是不是外挂,只能起播之后到播放页去翻。</para>
    /// </summary>
    private Control MediaBlocks(List<JsonElement> vers)
    {
        var host = new StackPanel { Spacing = 10 };
        host.Children.Add(H2("媒体信息"));
        foreach (var v in vers)
        {
            if (vers.Count > 1) host.Children.Add(Dim(VersionChipLabel(new VerPick(_server, "", "", true, "", v))));
            var blocks = new List<(string Title, List<(string K, string V)> Rows)>
            {
                ("常规", VersionRows(v)),
            };
            foreach (var s in Arr2(v, "streams"))
            {
                var rows = StreamRows(s);
                if (rows.Count == 0) continue;   // 一行都写不出来的流不占一张卡
                blocks.Add((StreamCardTitle(s), rows));
            }
            // 横排 + 可拖 = 和选集轨道同一个驱动器(草稿:「块内卡片鼠标左右拖动滑动」)
            host.Children.Add(Carousel.Rail(blocks, StreamCard, StreamCardHeight(blocks), out _));
        }
        return host;
    }

    /// <summary>流卡的抬头。字幕用语言,音轨用语言 —— 三条「音频」并排是认不出谁是谁的。</summary>
    private static string StreamCardTitle(JsonElement s) => Str(s, "type_") switch
    {
        "Video" => "视频",
        "Audio" => Str(s, "language") is { Length: > 0 } al ? $"音频 · {al}" : "音频",
        "Subtitle" => Str(s, "language") is { Length: > 0 } sl ? $"字幕 · {sl}" : "字幕",
        _ => "其它",
    };

    /// <summary>
    /// 卡高按**最长的那一块**算,所有卡一样高。
    /// <para>各算各的高度会让这一排参差不齐,而看上去像是间距没调好。</para>
    /// </summary>
    private static double StreamCardHeight(List<(string Title, List<(string K, string V)> Rows)> blocks) =>
        34 + blocks.Max(b => b.Rows.Count) * 20 + 20;

    private Control StreamCard((string Title, List<(string K, string V)> Rows) b)
    {
        var col = new StackPanel { Spacing = 2 };
        col.Children.Add(new TextBlock
        {
            Text = b.Title, FontSize = 12.5, FontWeight = FontWeight.SemiBold,
            Margin = new Thickness(0, 0, 0, 6),
            TextTrimming = TextTrimming.CharacterEllipsis,
        });
        foreach (var (k, v) in b.Rows)
        {
            col.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 6,
                Children =
                {
                    new TextBlock { Text = k, FontSize = 11.5, Width = 46, Foreground = Tok.Of("Ink2") },
                    new TextBlock
                    {
                        Text = v, FontSize = 11.5, TextTrimming = TextTrimming.CharacterEllipsis,
                        MaxWidth = StreamValueMax,
                    },
                },
            });
        }
        return new Border
        {
            Width = StreamCardWidth, Padding = new Thickness(10),
            CornerRadius = new CornerRadius(10), Background = Tok.Of("PanelAlt"),
            Child = col,
        };
    }

    /// <summary>值那一列最宽能占多少。写死一个大数会把卡撑破,而卡宽是响应式的。</summary>
    private double StreamValueMax => StreamCardWidth - 46 - 6 - 20;

    /// <summary>
    /// 一行人话的媒体信息。
    ///
    /// <para>只写<b>选片时真会看的</b>:分辨率、编码、大小、有几条音轨 / 字幕。
    /// 码率、帧率、声道布局这些放进来会把这一行挤成一段技术参数表,
    /// 而真要看的人会去看播放页的抽屉。</para>
    /// </summary>
    private static string MediaLine(JsonElement v)
    {
        var streams = Arr2(v, "streams");
        var bits = new List<string>();

        var video = streams.FirstOrDefault(x => Str(x, "type_") == "Video");
        if (video.ValueKind == JsonValueKind.Object)
        {
            var h = (int)Num(video, "height");
            // 写 1080p 不写 1920×1080:高度才是大家用来说话的那个数
            if (h > 0) bits.Add(h >= 2160 ? "4K" : $"{h}p");
            if (Str(video, "codec") is { Length: > 0 } c) bits.Add(CodecName(c));
            // HDR 值得单独标 —— 它决定要不要切软解(见杜比那条)
            var range = Str(video, "video_range_type");
            if (range != "" && !range.Equals("SDR", StringComparison.OrdinalIgnoreCase)) bits.Add(range);
        }
        if (Size(v) is { Length: > 0 } sz) bits.Add(sz);

        var audio = streams.Count(x => Str(x, "type_") == "Audio");
        var subs = streams.Count(x => Str(x, "type_") == "Subtitle");
        if (audio > 0) bits.Add($"{audio} 条音轨");
        // 「0 条字幕」也要写:「这片没有字幕」是选片时的真信息,
        // 不写的话用户以为是没加载出来。
        bits.Add(subs > 0 ? $"{subs} 条字幕" : "无字幕");

        return string.Join("  ·  ", bits);
    }

    /// <summary>
    /// 编码的通用写法。
    /// <para>直接 <c>ToUpper</c> 会得到 <c>H264</c> / <c>HEVC</c> 混排 ——
    /// 前者看着像打错了。认不出来的就原样大写,不硬编一张永远补不全的表。</para>
    /// </summary>
    private static string CodecName(string c) => c.ToLowerInvariant() switch
    {
        "h264" or "avc" => "H.264",
        "hevc" or "h265" => "HEVC",
        "av1" => "AV1",
        "vp9" => "VP9",
        "mpeg2video" => "MPEG-2",
        _ => c.ToUpperInvariant(),
    };

    /// <summary>
    /// 自检:选第 <paramref name="idx"/> 个版本,然后按播放。
    ///
    /// <para>「选了版本有没有真的播那一条」<b>看界面是看不出来的</b> ——
    /// 版本条高亮了、按钮也点得动,而送下去的 media_source_id 可能根本没变。
    /// 本仓栽过一次同款(正则选对了版本,详情页和播放器却全写死回落第一条),
    /// 而它活了几个月。判据只有一个:<b>服务器实际被请求的是哪一条流</b>。</para>
    /// </summary>
    /// <summary>
    /// 自检:直接按「播放」。
    ///
    /// <para>必须<b>经由详情页</b>起播,不能直接 push 播放页 —— 预热(<c>prefs.preloadItem</c>)
    /// 是详情页发的,而本地代理和那份环形缓存是预热建起来的。跳过详情页去测缩略图,
    /// 测的是一条<b>用户走不到</b>的路,而且必然是「一段缓存都没有」。</para>
    /// </summary>
    internal void SelfCheckPlay(int delayMs)
    {
        _ = Task.Delay(delayMs).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            if (_play is null) { Console.WriteLine("[自检起播] 详情页还没画出播放按钮"); return; }
            Console.WriteLine("[自检起播] 点播放");
            _play.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        }));
    }

    internal void SelfCheckPickVersion(int idx)
    {
        Dispatcher.UIThread.Post(() =>
        {
            if (_useVersion is null || idx >= _vers.Count)
            {
                Console.WriteLine("[版本自检] 没有版本条(或者版本不够多)");
                return;
            }
            _useVersion(idx);
            Console.WriteLine($"[版本自检] 选了第 {idx + 1} 个版本,现在的 id = {_versionId}" +
                              (_versionServer == "" ? "" : $",在 {_versionServer}"));
            _play?.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        });
    }

    /// <summary>文件大小的人话。拿不到就空串 —— 整项不写,不写「未知」。</summary>
    private static string Size(JsonElement v)
    {
        var b = Num(v, "size_bytes");
        if (b <= 0) return "";
        return b >= 1L << 30 ? $"{b / (double)(1L << 30):0.#} GB" : $"{b / (double)(1L << 20):0} MB";
    }

    /// <summary>
    /// 秒 → 时间点。
    ///
    /// <para>超过一小时要写成 <c>1:05:30</c>。只按「分:秒」写的话
    /// 一部两小时的片会显示成 <c>95:12</c> —— 那不是任何人读得懂的时间。</para>
    /// </summary>
    private static string Clock(double secs)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, secs));
        return t.TotalHours >= 1
            ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}"
            : $"{t.Minutes}:{t.Seconds:00}";
    }

    /// <summary>
    /// 连载状态的人话。
    ///
    /// <para>Emby 回的是 <c>Continuing</c> / <c>Ended</c> —— <b>英文原文</b>。
    /// 原样摆在一整页中文里不是「没翻译」这种小事,是**用户读不懂这一栏在说什么**。
    /// 认不出来的值就整个不显示:摆一个原文英文比不摆更像 bug。</para>
    /// </summary>
    private static string StatusText(string raw) => raw switch
    {
        "Continuing" => "连载中",
        "Ended" => "已完结",
        "Unreleased" => "未播出",
        _ => "",
    };

    /// <summary>
    /// 给头部垫一张背景大图。
    ///
    /// <para>淡出用的是 <b>OpacityMask</b>,不是「盖一层背景色的渐变」——
    /// 盖色要知道当前主题的底色,而本仓有深浅两套皮;写死一个色号就等于
    /// 浅色主题下头顶一道黑边。遮罩让页面底色自己透上来,换皮不用改这里。</para>
    ///
    /// <para>没有背景图就<b>原样返回内容</b>,不留空高度 —— 留着的话
    /// 没刮削背景的条目头顶会空出 420px。</para>
    /// </summary>
    private Control Backdrop(JsonElement d, string id, Control content)
    {
        if (!Bool(d, "has_backdrop")) return content;

        /* 背景图用 <b>ImageBrush 当底纹</b>,不是塞一个 Image 进去。
           Image 会<b>把自己的自然尺寸算进布局</b>:一张 16:9 的图铺到 1600 宽,
           它就要 900 的高,于是头图被撑到近 900px —— 海报底下空出一大片,
           而那片什么都没有。原来用 `Height = 420` 钉死能挡住这件事,
           但那样图的下沿又会卡在海报中间。
           画刷不参与测量:这一层有多高完全由头图内容决定,图自己去适配。 */
        var brush = new ImageBrush
        {
            Stretch = Stretch.UniformToFill,
            AlignmentY = AlignmentY.Top,
        };
        var layer = new Border
        {
            Opacity = 0, // 图到了再淡入 —— 直接出现会「啪」地闪一下
            VerticalAlignment = VerticalAlignment.Stretch,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Background = brush,
            ClipToBounds = true,
            // 上半段实,下半段化开 —— 图和正文之间不要留一条硬边。
            OpacityMask = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
                EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops =
                {
                    new GradientStop(Colors.White, 0),
                    new GradientStop(Colors.White, 0.45),
                    new GradientStop(Color.FromArgb(0, 255, 255, 255), 1),
                },
            },
            Transitions =
            [
                new DoubleTransition
                {
                    Property = OpacityProperty,
                    Duration = TimeSpan.FromMilliseconds(220),
                    Easing = new CubicEaseOut(),
                },
            ],
        };

        _ = FillBrush(brush, layer, Images.EmbyImageUrl(_server, id, "Backdrop"), 720);
        return new Panel { Children = { layer, content } };
    }

    /// <summary>
    /// 取背景图 →(取到了才)淡入。
    ///
    /// <para>0.42:实测 0.30 在深色底上<b>几乎看不见</b>,等于白做;
    /// 再往上标题就压不住图上的高光,读起来吃力。
    /// 背景是氛围不是内容 —— 它不许和正文抢注意力,但也得存在。</para>
    /// </summary>
    private static async Task FillBrush(ImageBrush brush, Visual layer, string url, int maxH)
    {
        var bmp = await Images.LoadAsync(Program.Core!, url, maxH);
        if (bmp is null) return;
        Dispatcher.UIThread.Post(() => { brush.Source = bmp; layer.Opacity = 0.42; });
    }

    /// <summary>
    /// 分集区。
    ///
    /// <para><b>多季必须分组</b>。20 集平铺成一片,想找「第二季第 1 集」只能从头数 ——
    /// 而剧集详情页最常见的动作恰恰就是这个。只有一季时不画季条:
    /// 一个只有一个选项的选择器是纯噪音。</para>
    ///
    /// <para>默认落在**接着看的那一季**,不是第一季。追到第三季的人每次进来
    /// 都得先点一下第三季,那这个默认值等于没有。</para>
    /// </summary>
    private Control Episodes(List<CardItem> episodes)
    {
        var groups = episodes.GroupBy(e => e.SeasonNo).OrderBy(g => g.Key).ToList();
        var host = new StackPanel { Spacing = 14 };
        var railHost = new ContentControl();

        /* 「下一集」不在这一层算了 —— 2026-09-04 之后点一集是**进它自己的详情页**,
           而那一页会自己算(它就是一个普通条目详情页)。
           主按钮那条链路的「下一集」在 PlayRow 里,用的是同一份排序。 */

        // 当前这一季的集表 + 它的滚动容器(「跳到第 N 集」要滚它)
        var shown = new List<CardItem>();
        ScrollViewer? rail = null;
        // 横排时是 0(按 X 跳),网格/列表时是每行几张(按 Y 跳)
        var perRow = 0;
        var rowH = 0.0;

        // 三种版式共用同一张卡 —— 各写一遍的话「点一集去哪」迟早分叉
        Control EpCard(CardItem it) => new Card(_core, _server, it, true,
            x => Nav.Push(new DetailPage(_core, _server, x.Id)),
            // 分辨率 / 码率 / 大小(草稿 03 页第 16 条),缺了回落到时长
            width: EpisodeCardWidth, subtitle: it.EpisodeSubtitle,
            title: it.Name, titleLines: 1);

        /* 一行,虚拟化,左右翻页(用户 2026-09-03:
           「做成一行的,可以点击左右的按钮滑动展示的」)。
           光「做成一行」治不了「上千集卡死」—— 一行一千张卡还是一千张卡。
             真正救命的是 Carousel.Rail 里那个 VirtualizingStackPanel。 */
        void ShowSeason(List<CardItem> list)
        {
            shown.Clear();
            shown.AddRange(list);
            /* 点一集 = <b>进这一集自己的详情页</b>(用户 2026-09-04:
               「点击单集后没有正确进入单集详情页去选那些选项,点击后应该进入集详情页」)。
               上一版是就地展开一块面板(2026-09-02 的口径),现在推翻了 ——
               展开的那块面板上<b>没有版本 / 音轨 / 字幕 / 线路</b>,
               而那正是用户点进来要选的东西;集详情页天生就有那一套。
               复用 DetailPage 而不是另写一个「集详情」:一集就是一个条目,
                 它和电影走的是同一段渲染。 */
            ScrollViewer sv;
            switch (_epView)
            {
                case 1:
                    perRow = Math.Max(1, (int)((EpisodeBoxWidth + Carousel.RailGap)
                                               / (EpisodeCardWidth + Carousel.RailGap)));
                    rowH = EpisodeCardWidth * 9 / 16 + EpisodeRowExtra;
                    var rows = new List<List<CardItem>>();
                    for (var i = 0; i < list.Count; i += perRow)
                        rows.Add(list.GetRange(i, Math.Min(perRow, list.Count - i)));
                    railHost.Content = Carousel.Column(rows, r =>
                    {
                        var p = new StackPanel
                        {
                            Orientation = Orientation.Horizontal, Spacing = Carousel.RailGap,
                        };
                        foreach (var it in r) p.Children.Add(EpCard(it));
                        return p;
                    }, EpisodeBoxHeight, out sv);
                    break;
                case 2:
                    perRow = 1;
                    rowH = EpisodeListRowHeight;
                    railHost.Content = Carousel.Column(list, EpRow, EpisodeBoxHeight, out sv, 6);
                    break;
                default:
                    perRow = 0;
                    railHost.Content = Carousel.Rail(list, EpCard, EpisodeCardWidth * 9 / 16, out sv);
                    break;
            }
            rail = sv;
        }

        // ── 季 / 集 两个下拉 ────────────────────────────────────────
        /* 用户 2026-09-03:「同时给两个按钮,点击出现列表,滑动浏览季度/集数」。
           原来季是一排**平铺的按钮**:三季还行,而《海贼王》那种二十几季会折成四五行,
           把分集整个推到折线以下。集更没法平铺 —— 它本来就有上千个。
           下拉里的列表自己是滚动的,这正是「滑动浏览」要的东西。 */
        var seasonBtn = new Button { Classes = { "chip" }, Margin = new Thickness(0, 0, 10, 0) };
        var epBtn = new Button { Classes = { "chip" } };
        var current = 0;

        void Pick(int idx)
        {
            current = idx;
            var g = groups[idx];
            seasonBtn.Content = (g.Key > 0 ? $"第 {g.Key} 季" : "其它") + $" · {g.Count()} 集  ▾";
            ShowSeason(g.ToList());
            epBtn.Content = $"跳到某一集  ▾";
        }

        seasonBtn.Click += (_, _) => Flyout(seasonBtn, groups.Select((g, i) =>
            ((g.Key > 0 ? $"第 {g.Key} 季" : "其它") + $" · {g.Count()} 集", (Action?)(() => Pick(i)))).ToList());

        epBtn.Click += (_, _) => Flyout(epBtn, shown.Select((e, i) =>
            (e.PickerLabel, (Action?)(() => JumpTo(i)))).ToList());

        /* 跳到第 N 集:把它滚到视野正中。
            滚到**正中**而不是滚到左边:滚到边上的话用户还得自己认哪一张是刚选的。 */
        void JumpTo(int i)
        {
            if (i < 0 || i >= shown.Count) return;
            // 虚拟化面板不能按控件求位置(那一张多半还没造出来),按**卡宽 + 间距**算。
            // 间距用 Carousel.RailGap,别再写一个字面量 —— 两处对不上时卡会越滚越偏。
            if (rail is null) return;
            if (perRow == 0)
                rail.Offset = rail.Offset.WithX(Math.Max(0,
                    i * (EpisodeCardWidth + Carousel.RailGap)
                    - rail.Viewport.Width / 2 + EpisodeCardWidth / 2));
            else
                rail.Offset = rail.Offset.WithY(Math.Max(0,
                    i / perRow * rowH - rail.Viewport.Height / 2 + rowH / 2));
        }

        host.Children.Add(H2(groups.Count <= 1
            ? $"剧集 · 共 {episodes.Count} 集"
            : $"剧集 · {groups.Count} 季 · 共 {episodes.Count} 集"));

        // 默认落在**接着看的那一季**,不是第一季。追到第三季的人每次进来
        // 都得先点一下第三季,那这个默认值等于没有。
        var next = NextEpisode(episodes);
        var at0 = groups.FindIndex(g => g.Key == next.SeasonNo);
        Pick(at0 < 0 ? 0 : at0);

        // 只有一季就不画季按钮:一个只有一个选项的选择器是纯噪音
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        if (groups.Count > 1) bar.Children.Add(seasonBtn);
        bar.Children.Add(epBtn);

        /* 版式切换,靠右(草稿 03 页第 15 条)。三档不是两档:草稿画的是 ▦/☰,
           而「横排 + 左右翻页」是用户 2026-09-03 自己点名要的 ——
           草稿和用户各要一半,那就都留着。找第 300 集时网格/列表比横排快得多,
           而横排是「接着看下一集」那个动作的版式。 */
        var viewBar = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var viewBtns = new List<Button>();
        foreach (var (label, idx) in EpisodeViews.Select((v, i) => (v, i)))
        {
            var b = new Button { Classes = { "chip" }, Content = label };
            b.Click += (_, _) =>
            {
                if (_epView == idx) return;
                _epView = idx;
                MarkView(viewBtns);
                if (shown.Count > 0) ShowSeason([.. shown]);
            };
            viewBtns.Add(b);
            viewBar.Children.Add(b);
        }
        MarkView(viewBtns);
        var barRow = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(viewBar, Dock.Right);
        barRow.Children.Add(viewBar);
        barRow.Children.Add(bar);
        host.Children.Add(barRow);

        host.Children.Add(railHost);
        // 换档整条重建。shown 要先拷一份 —— ShowSeason 第一句就是 shown.Clear()
        _rescaleEpisodes = () =>
        {
            if (shown.Count > 0) ShowSeason([.. shown]);
        };
        return host;
    }

    /// <summary>
    /// 分集版式:0 横排 / 1 网格 / 2 列表。
    ///
    /// <para><b>静态</b>是故意的:点一集就是推一页新的 DetailPage,存在实例上等于
    /// 每点一集都被打回横排。也<b>不落库</b> —— 这是「这会儿想怎么看」,不是设置项。</para>
    /// </summary>
    private static int _epView;

    private static readonly string[] EpisodeViews = ["横排", "网格", "列表"];

    private static void MarkView(List<Button> btns)
    {
        for (var i = 0; i < btns.Count; i++) btns[i].Classes.Set("on", i == _epView);
    }

    /// <summary>一张分集卡除了剧照还占多高:标题一行 + 小字一行 + 行间距。</summary>
    private const double EpisodeRowExtra = 62;

    /// <summary>列表版一行多高。没有剧照,所以只够放一行字。</summary>
    private const double EpisodeListRowHeight = 40;

    /// <summary>
    /// 网格 / 列表那一块的高度上限。
    ///
    /// <para><b>必须封顶</b>:整页本来就在一个竖向 ScrollViewer 里,不封顶的话
    /// 外层用无限高去量,虚拟化面板会把上千行全造出来。三行是「一眼扫得完、
    /// 又不会把相似推荐推出屏幕」的量。</para>
    /// </summary>
    private double EpisodeBoxHeight => (EpisodeCardWidth * 9 / 16 + EpisodeRowExtra) * 3;

    /// <summary>网格算列数用的可用宽。还没量到就退回整页宽,_rescaleEpisodes 之后会纠正。</summary>
    private double EpisodeBoxWidth =>
        _episodesHost.Bounds.Width > 1 ? _episodesHost.Bounds.Width : Bounds.Width;

    /// <summary>
    /// 列表版的一行:集号 + 标题 + 那行小字。<b>不放剧照</b> ——
    /// 列表是给「找第 300 集」用的,一屏得摆得下二十行才有意义。
    /// </summary>
    private Control EpRow(CardItem it)
    {
        var code = new TextBlock
        {
            Text = it.EpisodeCode, Width = 88, Classes = { "dim" },
            VerticalAlignment = VerticalAlignment.Center,
        };
        var meta = new TextBlock
        {
            Text = it.EpisodeSubtitle, Classes = { "dim" },
            VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0),
        };
        var name = new TextBlock
        {
            Text = it.Name, TextTrimming = TextTrimming.CharacterEllipsis,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var row = new DockPanel { LastChildFill = true };
        DockPanel.SetDock(code, Dock.Left);
        DockPanel.SetDock(meta, Dock.Right);
        row.Children.Add(code);
        row.Children.Add(meta);
        row.Children.Add(name);
        var b = new Button
        {
            Classes = { "ghost" }, Content = row,
            Padding = new Thickness(10, 6),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
        };
        b.Click += (_, _) => Nav.Push(new DetailPage(_core, _server, it.Id));
        // 右键菜单和卡片共用一份:两种版式给两套菜单,用户会以为是两种东西
        CardActions.Attach(b, _core, it);
        return b;
    }

    /// <summary>
    /// 分集卡宽。
    /// <para>214(默认 256):分集列表是<b>用来找集的</b>,一屏看得到的越多越好 ——
    /// 单张再大也提供不了更多信息(同一部剧的剧照长得都差不多)。</para>
    /// </summary>
    private double EpisodeCardWidth => Responsive.S(Bounds.Width, 214, 140);

    /// <summary>
    /// 挂在按钮下面的一列可选项。
    ///
    /// <para>列表自己滚动并封顶 420 高 —— 上千集的话不封顶就是一条比屏幕还长的菜单,
    /// 顶端和底端都点不到。</para>
    /// <para>每次点开<b>重建</b>:季一换,集表就换了。留着上一次那份是「换了季、
    /// 跳集列表还是上一季的」,而它不报错。</para>
    /// </summary>
    /// <param name="focus">
    /// 打开时滚进视野的那一项(下标按 <paramref name="items"/> 算),-1 = 不滚。
    /// <para>播放页的选集浮层要它:第 500 集时浮层停在第 1 集,
    /// 等于让用户在一千行里自己找。</para>
    /// </param>
    internal static void Flyout(Button anchor, List<(string Label, Action? Go)> items, int focus = -1)
    {
        var list = new StackPanel { Spacing = 2 };
        Control? mark = null;
        var nth = -1;   // 第几个**可点项**(小标题不算),focus 按它数
        var fly = new Flyout
        {
            Placement = PlacementMode.BottomEdgeAlignedLeft,
            Content = new ScrollViewer
            {
                MaxHeight = 420, MaxWidth = 380,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = list,
            },
        };
        foreach (var (label, go) in items)
        {
            // go 为 null = 分组小标题(版本浮层按服务器分组用)。
            // 做成一个点不动的按钮的话,用户点上去浮层会关掉而什么都没发生。
            if (go is null)
            {
                list.Children.Add(new TextBlock
                {
                    Text = label, Classes = { "dim" }, FontSize = 12,
                    Margin = new Thickness(10, 6, 0, 2),
                });
                continue;
            }
            var b = new Button
            {
                Content = label, Classes = { "ghost" },
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            b.Click += (_, _) => { fly.Hide(); go(); };
            if (++nth == focus) mark = b;
            list.Children.Add(b);
        }
        fly.ShowAt(anchor);
        // 浮层是这一刻才布局的,直接 BringIntoView 会按「还没算出来的位置」滚。
        // 排到下一轮布局之后再滚 —— 那时候每一行的高度才是真的。
        if (mark is not null) Dispatcher.UIThread.Post(() => mark.BringIntoView(), DispatcherPriority.Loaded);
    }

    /// <summary>分集到了之后,把「第 N 季 · 第 M 集」补到主按钮上。</summary>
    private async Task LabelPlayLater(Button play)
    {
        if (_episodesTask is null) return;
        var eps = await _episodesTask;
        if (eps.Count == 0) return;
        var next = NextEpisode(eps);
        var label = next.SeasonNo > 0 && next.EpisodeNo > 0
            ? $"第 {next.SeasonNo} 季 · {next.Name}" : next.Name;
        Dispatcher.UIThread.Post(() =>
            play.Content = next.ResumeSecs > 0 ? $"▶ 继续观看 · {label}" : $"▶ 播放 · {label}");
    }

    /// <summary>
    /// 接着该看哪一集:①看了一半的 → ②第一集没看过的 → ③第一集。
    ///
    /// <para><b>这个顺序和 Emby 的「继续观看」一致</b>,主按钮和季条默认值共用它 ——
    /// 两处各写一份的话迟早会指到不同的集上,而那种不一致没人会当成 bug 报上来。</para>
    /// </summary>
    private static CardItem NextEpisode(List<CardItem> eps) =>
        eps.FirstOrDefault(e => e.ResumeSecs > 0)
        ?? eps.FirstOrDefault(e => !e.Played)
        ?? eps[0];

    /// <summary>播放按钮行。有进度就把时间点写在按钮上 —— 只写「播放」用户会以为要从头看。</summary>
    private Control PlayRow(JsonElement d, string id, string type)
    {
        var resume = Num(d, "resume_secs");
        var name = Str(d, "name");
        var playable = type is "Movie" or "Episode" or "Video" or "MusicVideo";

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        if (playable)
        {
            var play = new Button
            {
                Classes = { "primary" },
                Content = resume > 0 ? $"▶ 继续播放 · 已看到 {Clock(resume)}" : "▶ 播放",
            };
            // 版本 / 音轨 / 字幕都**点的那一刻才读** —— 用户可能在按之前又换过
            /* 选了别台的版本就**整个换到那台**去播:item_id 和会话必须成对换。
               只换 media_source_id 的话是拿甲服的条目 id 去打乙服 ——404,
               或者更糟:乙服上恰好有这个 id,放出来是另一部片。 */
            play.Click += (_, _) =>
                Nav.Push(new PlayerPage(_core, _versionItem != "" ? _versionItem : id, name, resume,
                    mediaSourceId: _versionId, audioIndex: _audioIndex, subIndex: _subIndex,
                    serverId: _versionServer));
            _play = play;
            row.Children.Add(play);
        }
        else if (type is "Series" or "Season")
        {
            /* 剧集详情页**必须有主按钮**。之前只有 Movie/Episode 有,
               剧的详情页上一个播放按钮都没有 —— 用户得滚到下面的分集网格里
               自己找「我看到第几集了」。那不是详情页,那是目录。

                按钮<b>不等分集就先出来</b>。分集是第二条命令,慢的时候要一两秒;
                 为了在按钮上写出「第 3 集」而让整个按钮晚一秒出现,是本末倒置 ——
                 用户点它的意图是「接着看」,哪一集是我们该算出来的,不是他要读的。
                 点了之后再等那条命令(通常早就到了),把集号补在按钮上。
                挑哪一集的顺序在 NextEpisode 里,和季条的默认季共用同一份。 */
            var play = new Button { Classes = { "primary" }, Content = "▶ 继续观看" };
            play.Click += async (_, _) =>
            {
                if (_episodesTask is null) return;
                play.IsEnabled = false;
                var eps = await _episodesTask;
                play.IsEnabled = true;
                if (eps.Count == 0) { play.Content = "没有可播的分集"; return; }
                var ordered = eps.OrderBy(e => e.SeasonNo).ThenBy(e => e.EpisodeNo).ToList();
                var next = NextEpisode(eps);
                var at = ordered.FindIndex(e => e.Id == next.Id);
                var after = at >= 0 && at + 1 < ordered.Count ? ordered[at + 1] : null;
                Nav.Push(new PlayerPage(_core, next.Id, next.DisplayTitle, next.ResumeSecs, next: after,
                    audioIndex: _audioIndex, subIndex: _subIndex));
            };
            row.Children.Add(play);
            // 分集到了就把集号补上去 —— 在此之前按钮已经可点了
            _ = LabelPlayLater(play);
        }

        // 收藏跟 Features 走 —— 侧栏的「收藏」下线了,这里还留着按钮的话,
        // 用户收藏完找不到地方看,和「屏蔽了没有解除列表」是同一类坑。
        var fav = new Button
        {
            Classes = { "ghost" },
            Content = Bool(d, "is_favorite") ? "♥ 已收藏" : "♡ 收藏",
        };
        fav.Click += async (_, _) =>
        {
            var on = (string?)fav.Content == "♡ 收藏";
            try
            {
                var s = Nav.Session!;
                // 参数名是 fav,不是 favorite。写错了**不报错** ——
                // 布尔默认成 false,表现是「点收藏反而取消了收藏」。
                await _core.EmbySetFavorite(new
                {
                    s.server, s.token, s.user_id, s.device_id, item_id = id, fav = on,
                });
                fav.Content = on ? "♥ 已收藏" : "♡ 收藏";
            }
            catch (Exception e) { fav.Content = LibraryPage.Advice(e); }
        };
        if (Features.On("card.favorite")) row.Children.Add(fav);

        /* 下载只对**可播条目**给。给一部剧的总条目下载按钮,点了不知道该下哪一集。
           而且**服务器没给下载权限时整个不出现**(用户 2026-09-06)——
           从前是「摆着,点了再由服务端拒」,那是一个专门用来报错的按钮。
           判据是 Emby 的 Policy.EnableContentDownloading(字段名打真服务器核对过),
           缺字段一律判否。先建后显:异步拿到权限再点亮,免得按钮插到别人后面去。 */
        if (playable)
        {
            var dl = new Button { Classes = { "ghost" }, Content = "⭳ 下载", IsVisible = false };
            _ = Task.Run(async () =>
            {
                try
                {
                    var s = Nav.Session!;
                    var perm = await _core.EmbyPermissions(new { s.server, s.token, s.user_id, s.device_id });
                    if (Bool(perm, "can_download"))
                        Dispatcher.UIThread.Post(() => dl.IsVisible = true);
                }
                catch { /* 问不到权限就不给按钮 —— 宁可少给,也不摆一个必定失败的 */ }
            });
            dl.Click += async (_, _) =>
            {
                dl.IsEnabled = false;
                try
                {
                    /* container 从媒体信息里取。给错的话文件后缀就错 ——
                       播放器认后缀,mkv 存成 mp4 有的播放器直接不认。
                       取不到就交给核心层兜底(它默认 mkv)。 */
                    await _core.DownloadEnqueue(new
                    {
                        item_id = id, type_ = type, title = name,
                        container = Str(d, "container"),
                        poster_url = (string?)null,
                    });
                    dl.Content = "已加入下载";
                }
                catch (Exception e)
                {
                    // 下载权限是**服务端**判的:没权限时如实说,别写成「网络错误」
                    dl.Content = LibraryPage.Advice(e);
                    dl.IsEnabled = true;
                }
            };
            row.Children.Add(dl);

            /* 用外部播放器打开。
                按钮**只在配了外部播放器时才出现**:没配的话点了只会得到
                 「未设置外部播放器」,那是一条纯噪音 —— 摆一个必定失败的按钮
                 比没有更糟。所以先问核心层,拿到非空才加。 */
            var ext = new Button { Classes = { "ghost" }, Content = "⧉ 外部播放器" };
            ext.Click += async (_, _) =>
            {
                ext.IsEnabled = false;
                try
                {
                    var s = Nav.Session!;
                    await _core.PlayerPlayExternal(new
                    {
                        s.server, s.token, s.user_id, s.device_id,
                        item_id = id, resume_secs = resume,
                    });
                    ext.Content = "已交给外部播放器";
                }
                catch (Exception e) { ext.Content = LibraryPage.Advice(e); }
                finally { ext.IsEnabled = true; }
            };
            _ = Task.Run(async () =>
            {
                try
                {
                    var p = await _core.PlayerGetPlaybackPrefs(new { });
                    if (Str(p, "external_player") != "")
                        Dispatcher.UIThread.Post(() => row.Children.Add(ext));
                }
                catch { /* 拿不到就当没配 —— 这一个按钮不值得把详情页拖红 */ }
            });
        }
        return row;
    }

    /// <summary>自检用:点一下「下载」按钮。</summary>
    internal void SelfCheckDownload()
    {
        foreach (var b in this.GetVisualDescendants().OfType<Button>())
            if ((b.Content as string) == "⭳ 下载") { b.Command?.Execute(null); RaiseClick(b); return; }
    }

    private static void RaiseClick(Button b) =>
        b.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));

    /// <summary>
    /// 取一张图挂上去。
    ///
    /// <para><b>必须把 Opacity 拨回 1</b>。这些 Image 起手是 <c>Opacity=0</c>
    /// (配 <c>Image.art</c> 的过渡做淡入),只塞 Source 不拨透明度的话
    /// 图<b>拉回来了、也画上去了、就是看不见</b> —— 表现是海报和背景大图
    /// 永远是一块空底色,而请求日志里明明有 200。
    /// 2026-09-02 栽过一次,编译绿、日志绿,只有截图看得出来。</para>
    /// </summary>
    private static async Task Fill(Image target, string url, int maxH)
    {
        var bmp = await Images.LoadAsync(Program.Core!, url, maxH);
        if (bmp is null) return;
        Dispatcher.UIThread.Post(() =>
        {
            target.Source = bmp;
            target.Opacity = 1;
        });
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
    private static List<string> Arr(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x != "").ToList() : [];
    private static List<JsonElement> Arr2(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().ToList() : [];

    /// <summary>一串 <c>{name, id}</c>。没名字的丢掉 —— 画出来是个空片,点了还搜不出东西。</summary>
    private static List<(string Name, string Id)> Named(JsonElement e, string k) =>
        Arr2(e, k)
            .Select(x => (Name: Str(x, "name"), Id: Str(x, "id")))
            .Where(x => x.Name != "").ToList();
}
