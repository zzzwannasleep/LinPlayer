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
/// <para>★ 「没值就整行不画,不留空位」:标语实测只有约三分之一的条目有,
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

    /// <summary>头图区(全宽出血)。</summary>
    private readonly ContentControl _heroHost = new();

    /// <summary>媒体信息 / 版本条的挂点(在播放按钮下面)。</summary>
    private readonly StackPanel _mediaHost = new() { Spacing = 8 };

    /// <summary>当前选中的版本 id。空 = 交给核心层按正则挑(preferred)。</summary>
    private string _versionId = "";

    /// <summary>这一页有没有发过预热。发两遍不会错,但会白起一次请求。</summary>
    private bool _preloaded;

    /// <summary>
    /// 停在详情页时**提前把这一片的头部拉到本地**(<c>prefs.preloadItem</c>)。
    ///
    /// <para>☠☠ 这条命令核心层<b>一直都在,而 UI 从来没调过</b> —— 又一条零调用命令。
    /// 后果有两个,都不报错:①「预加载了多少就吐多少出来」那条口径(用户 2026-08-02 定的)
    /// 在这一端根本没生效,起播还是从零开始下;②<b>进度条缩略图整个用不了</b> ——
    /// 缩略图只读本地已缓存的字节,而没有预热就没有本地代理、也就没有那份环形缓存。</para>
    ///
    /// <para>★ fire-and-forget:核心层那边立刻返回、后台慢慢热。等它 = 把一个纯优化
    /// 做成了一个卡顿。</para>
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

    public DetailPage(CoreClient core, string server, string itemId)
    {
        _core = core; _server = server;

        var body = new StackPanel { Spacing = 16 };
        /* ★ 返回按钮在**数据回来之前**就得能点:详情拉了 10 秒还在转的时候,
           用户第一件想做的事就是退出去。所以它先挂上,渲染时再被搬进头图里。 */
        var back = new Button { Classes = { "ghost" }, Content = "← 返回", HorizontalAlignment = HorizontalAlignment.Left };
        back.Click += (_, _) => Nav.Back();
        _back = back;
        _heroHost.Content = new StackPanel { Margin = new Thickness(18, 18, 18, 0), Children = { back } };
        /* ★ 占位用骨架,不是「加载中…」三个字 —— 详情页是全站内容最高的一页,
           从 20px 撑到 1200px 的那一跳最明显。 */
        Control busy = Skeleton.Detail();
        body.Children.Add(busy);

        /* ★★ 详情页<b>不能整页塞进 1560 的水槽里</b>。
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
                        // ★ 不封顶(和 PageBase.Scrolled 同一条口径,2026-09-02 用户点名去掉留白)
                        HorizontalAlignment = HorizontalAlignment.Stretch,
                        Padding = new Thickness(18, 18, 18, 28), Child = body,
                    },
                },
            },
        };

        _ = Task.Run(async () =>
        {
            try
            {
                var s = Nav.Session!;
                /* ★★ <b>with_children = false</b>。
                   原来是 true —— 核心层会在**同一条命令里**先拉条目、再把**全部分集**
                   拉完才返回。实测最长的剧全量拉 1.8MB / 1841ms,
                   于是海报、标题、简介、播放按钮这些**早就到手的东西**,
                   要陪着分集一起等将近两秒。用户说的「详情页加载慢」就是这一下。

                   现在拆成两条:头部先画(一次小请求),分集自己在后面补。
                   这正是本仓已经写过的那条教训 —— 「不秒加载」的根因是加载结构里的屏障,
                   不是渲染慢。首页早就是各轨道各自渲染了,详情页这里漏了。 */
                /* ★★ <b>缓存先行</b>(用户 2026-09-03:「各个页面的封面、简介、元数据
                   都是可以缓存的,这样下次打开就很快了…其他页面也一样」)。
                   详情页是全站被反复进出最多的一页 —— 看完一集退出来再点进去,
                   海报、简介、标签这些**一个字都没变**,却要再等一次完整往返。 */
                var key = MetaCache.Key("emby.itemDetail", new { s.server, item_id = itemId });
                var cached = MetaCache.Peek(key);
                if (cached is { ValueKind: JsonValueKind.Object } c0)
                {
                    if (Str(c0, "type_") is "Series" or "Season") _episodesTask = LoadEpisodes(itemId);
                    Dispatcher.UIThread.Post(() => Paint(c0));
                    if (_episodesTask is not null) _ = FillEpisodes();
                }

                var d = await core.EmbyItemDetail(new
                {
                    s.server, s.token, s.user_id, s.device_id,
                    item_id = itemId, with_children = false,
                });
                MetaCache.Put(key, d);
                /* ★★ 内容一个字没变就<b>不要重画</b>。
                   重画一次这一页要重建海报、按钮、分集网格 —— 用户看到的是
                   「刚出来的页面当场闪一下又变回同样的样子」,那看着像 bug。
                   ★ 比的是整段原文,不是挑几个字段:挑字段就得跟着核心层的输出走,
                     漏一个就成了「改了不刷新」。 */
                if (cached is { } c1 && c1.GetRawText() == d.GetRawText()) return;

                // 是剧 / 季才有分集。★ 在渲染之前就发出去,让它和布局并行跑。
                var type = Str(d, "type_");
                if (type is "Series" or "Season") _episodesTask = LoadEpisodes(itemId);

                Dispatcher.UIThread.Post(() => Paint(d));
                if (_episodesTask is not null) await FillEpisodes();
                return;

                void Paint(JsonElement data)
                {
                    KickPreload(core, s, itemId);
                    body.Children.Remove(busy);
                    /* ★★ 渲染要有边界。这一页的渲染抛异常时**整个进程会当场退出** ——
                       没有对话框、没有日志窗口,用户看到的是「点了详情,软件没了」。
                       (刚刚就撞上了一次:一个控件同时挂两处。)
                       Rust 版为此有 PageBoundary,这边一直没有对应的东西。 */
                    // ★ 重画之前先清干净:缓存那一版已经把整页画出来了,
                    //   不清的话真数据会**再叠一份**上去(标题海报按钮全出现两遍)。
                    body.Children.Clear();
                    try { Render(body, data); }
                    catch (Exception re)
                    {
                        body.Children.Clear();
                        body.Children.Add(_back);
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
    /// <para>★ 不做「滚到底再拉」:剧集详情页是按季分组的,少一半集会让某一季整个空掉,
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
                // ★ 空页就停。只看 total 的话,服务端 total 报大了就是个死循环。
                if (got.Count == 0) break;
                all.AddRange(got);
                var total = page.TryGetProperty("total", out var t) && t.ValueKind == JsonValueKind.Number
                    ? t.GetInt32() : all.Count;
                if (all.Count >= total) break;
            }
            MetaCache.PutList(key, all.Select(CardItem.ToJson).ToList());
        }
        /* ★ 分集拉不动**不该让整页失败** —— 头部已经在屏幕上了。
           ★★ 而且这时候要<b>回落到缓存</b>:离线 / 服务器抽风时,
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

    /// <summary>分集到了,把骨架换成真内容。</summary>
    private async Task FillEpisodes()
    {
        var eps = await _episodesTask!;
        Dispatcher.UIThread.Post(() =>
        {
            _episodesHost.Content = eps.Count > 0
                ? Episodes(eps)
                // ★ 说清是「没有」而不是「没拉到」。空着的话和还在加载长得一样。
                : Dim("这部剧下面没有分集(或者服务器没有返回)。");
        });
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
        /* ★ 分集这会儿<b>还没到</b>(它是第二条命令)。先放和真内容同尺寸的骨架 ——
           放「加载中…」三个字的话,内容到了这一块会从 20px 撑到上千像素,
           用户正在读的简介会被顶走。 */
        if (isShow)
        {
            _episodesHost.Content = Skeleton.Grid(true, 8, 214);
            body.Children.Add(_episodesHost);
        }

        // ---- 演职人员 ----
        /* ★★ 一行,左右滑(用户 2026-09-03:「演职人员信息一样,可以左右滑动,
           不需要按钮查询了就」—— 即:要滑动,但不要季/集那两个下拉)。
           ★ 原来是 WrapPanel + `Take(24)`:折成三四行占掉半屏,而且**第 25 位之后
             的人根本看不到**,还没有任何东西说明它被截断了。
             改成横轨之后全表都在,而虚拟化保证只造屏幕上那几张。 */
        var people = Arr2(d, "people");
        if (people.Count > 0)
        {
            body.Children.Add(H2($"演职人员 · {people.Count} 人"));
            body.Children.Add(Carousel.Rail(people, PersonCell, 84, out _));
        }
    }

    /// <summary>演职人员一格:圆头像 + 姓名 + 角色。</summary>
    private Control PersonCell(JsonElement p)
    {
        var av = new Border
        {
            Width = 84, Height = 84, CornerRadius = new CornerRadius(42), ClipToBounds = true,
            Background = new SolidColorBrush(Color.Parse("#1b212c")),
        };
        if (Bool(p, "has_primary"))
        {
            var im = new Image { Stretch = Stretch.UniformToFill, Opacity = 0, Classes = { "art" } };
            av.Child = im;
            _ = Fill(im, Images.EmbyImageUrl(_server, Str(p, "id"), "Primary"), 168);
        }
        else
        {
            /* ★ 没有头像时放姓氏,不留一个空圆。
               演职员表里**大半都没有头像**(刮削器很少刮全),
               一排空圆看着像加载失败,而它其实已经加载完了。 */
            av.Child = new TextBlock
            {
                Text = Str(p, "name") is { Length: > 0 } nm ? nm[..1] : "?",
                FontSize = 30, FontWeight = FontWeight.SemiBold,
                Foreground = new SolidColorBrush(Color.Parse("#4a5464")),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            };
        }
        // ★ 头像可点 → 人物详情。做成 Button 而不是给 Border 挂 PointerPressed:
        //   Button 自带 hover / focus / 键盘可达,手写那三样迟早漏一个。
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
            Width = 100, Spacing = 6, Margin = new Thickness(0, 0, 10, 4),
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
                    Foreground = new SolidColorBrush(Color.Parse("#6b7688")),
                },
            },
        };
        return cell;
    }


    /// <summary>
    /// 头图:背景大图出血 + 海报 + 标题信息。
    ///
    /// <para>★★ 这一块<b>不受正文 1560 水槽约束</b>,背景图铺满整个内容区宽度;
    /// 里面的文字和海报仍然按 1560 对齐,和下面的正文成一条线。
    /// 都封在 1560 里的话,1920 窗口上图只占中间一条,两侧是死白 ——
    /// 那不叫背景图,那叫一张插图。</para>
    /// </summary>
    private Control Hero(JsonElement d, string id, string type, string name, string series)
    {
        /* ★★ <b>集封面是横的,海报是竖的 —— 两种图不能塞进同一个槽</b>
           (用户 2026-09-03:「集封面和海报封面/季封面是不一样的,集封面是横着的」)。
           Emby 给分集的 Primary 是一张 16:9 的**剧照**;塞进 220×330 的 2:3 槽里
           再 UniformToFill,等于把左右各裁掉三分之一 —— 人脸经常就在被裁掉的那一侧。
           而且它**不报错**:画面是满的,只是内容错了。
           ★ 392×220 是同一个 16:9,高度比海报矮一截 —— 分集本来也没有那么多头部信息要配。 */
        var still = type is "Episode";
        var poster = new Border
        {
            Width = still ? 392 : 220, Height = still ? 220 : 330,
            CornerRadius = new CornerRadius(12), ClipToBounds = true,
            VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(Color.Parse("#1b212c")),
        };
        if (Bool(d, "has_primary"))
        {
            var im = new Image { Stretch = Stretch.UniformToFill, Opacity = 0, Classes = { "art" } };
            poster.Child = im;
            _ = Fill(im, Images.EmbyImageUrl(_server, id, "Primary"), still ? 440 : 660);
        }

        var head = new StackPanel { Spacing = 12 };
        head.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(series) ? name : $"{series} · {name}",
            FontSize = 34, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap,
        });

        /* ★★ 元信息做成<b>一排小片</b>,不是一串用「·」连起来的长句。
           连成一句的问题不是不好看:它<b>不换行</b>,类型一多就被挤出可视区,
           而且年份、评分、分级、类型是四种不同的东西,拿同一个分隔符串起来
           等于告诉眼睛「它们是一类」。片状可以自然折行,也能一眼数清有几项。 */
        var chips = new WrapPanel();
        void Chip(string t)
        {
            if (t == "") return;
            chips.Children.Add(new Border
            {
                Margin = new Thickness(0, 0, 8, 8), Padding = new Thickness(10, 4),
                CornerRadius = new CornerRadius(6),
                Background = new SolidColorBrush(Color.Parse("#2622293a")),
                BorderBrush = new SolidColorBrush(Color.Parse("#333b4a")),
                BorderThickness = new Thickness(1),
                Child = new TextBlock { Text = t, FontSize = 12.5, Foreground = new SolidColorBrush(Color.Parse("#c2cbdb")) },
            });
        }
        if (Num(d, "year") > 0) Chip(((int)Num(d, "year")).ToString());
        if (Num(d, "rating") > 0) Chip($"★ {Num(d, "rating"):0.0}");
        Chip(StatusText(Str(d, "status")));
        Chip(Str(d, "official_rating"));
        if (Num(d, "runtime_secs") > 0) Chip($"{(int)(Num(d, "runtime_secs") / 60)} 分钟");
        /* 剧的季数用 child_count(Series 上它就是季数)。
           ★ 集数<b>不在这儿写</b> —— 分集还没拉回来,写不出来。
             它在下面「剧集 · N 季 · 共 M 集」那一行,那时候数据已经在手上了。
             为了凑一个数去等分集,等于把整个头部又拖回去等那 1.8MB。 */
        if (type == "Series" && Num(d, "child_count") > 0) Chip($"{(int)Num(d, "child_count")} 季");
        foreach (var g in Arr(d, "genres").Take(4)) Chip(g);
        if (chips.Children.Count > 0) head.Children.Add(chips);

        // 标语:没有就整行不画(实测只有约三分之一的条目有)
        var tagline = Str(d, "tagline");
        if (tagline != "")
        {
            head.Children.Add(new TextBlock
            {
                Text = tagline, FontStyle = FontStyle.Italic, TextWrapping = TextWrapping.Wrap,
                Foreground = new SolidColorBrush(Color.Parse("#9aa5b8")),
            });
        }

        /* ★★ 简介放在<b>头图右列</b>,不放到正文里。
           放正文的话头图右边那一大片是空的 —— 1920 的窗口上,
           标题 + 几个小片只占掉左边 40%,剩下 60% 什么都没有,
           而简介正是唯一一段「宽度越大越好读」的内容。
           (Emby 自己的详情页也是这么排的。) */
        var overview = Str(d, "overview");
        if (overview != "") head.Children.Add(Overview(overview));

        head.Children.Add(PlayRow(d, id, type));
        /* ★★ 媒体信息 / 版本条。**异步补,不挡头部** ——
           它要多打一次 PlaybackInfo,为了这一行让海报标题晚出来是本末倒置。 */
        head.Children.Add(_mediaHost);
        if (type is "Movie" or "Episode" or "Video" or "MusicVideo") _ = LoadMedia(id);

        var headRow = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 26,
            Children = { poster, head },
        };
        /* ★ 返回按钮盖在背景图上,不压在它上面一行 ——
           压在上面的话图是从页面中间才开始的,顶上留一条黑边。
           ★★ 换父之前必须**先从原来的容器里摘掉**。Avalonia 里一个控件同时挂两处
             不是「后者生效」,是当场抛 InvalidOperationException ——
             而它抛在渲染里,整个进程就没了。 */
        (_back.Parent as Panel)?.Children.Remove(_back);
        _back.Margin = new Thickness(0, 0, 0, 14);
        var inner = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(18, 18, 18, 18),
            Child = new StackPanel { Spacing = 0, Children = { _back, headRow } },
        };
        return Backdrop(d, id, inner);
    }

    /// <summary>
    /// 简介。<b>默认收起到 4 行,长了给「展开」</b>。
    ///
    /// <para>★ 不收的话一段十几行的简介会把分集整个推到折线以下 ——
    /// 而进详情页最常见的动作是找集,不是读简介。</para>
    /// <para>★ 短简介不画「展开」:一个点了什么都不会变的按钮比没有更糟。</para>
    /// </summary>
    private static Control Overview(string text)
    {
        var tb = new TextBlock
        {
            Text = text, TextWrapping = TextWrapping.Wrap, LineHeight = 23,
            MaxWidth = 860, HorizontalAlignment = HorizontalAlignment.Left,
            Foreground = new SolidColorBrush(Color.Parse("#c2cbdb")),
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
    /// 媒体信息 + 版本选择。
    ///
    /// <para>★★ 这是详情页<b>唯一还缺的信息</b>:用户点播放之前想知道
    /// 「我要放的这个到底是什么货色」—— 分辨率、编码、多大、有几条音轨字幕。
    /// 一个媒体播放器的详情页不写这些,就只是一张海报加一段简介。</para>
    ///
    /// <para>★ 旧 React 版这里有<b>四个</b>下拉:线路 / 版本 / 音轨 / 字幕。
    /// 这一版只做<b>版本</b>,是想清楚的取舍,不是没做完:
    /// <br/>· <b>线路</b>是服务器级设置,不该在每个条目页各摆一份;
    /// <br/>· <b>音轨 / 字幕</b>播放页的抽屉里已经有了,而且那里才是真正会改它的时刻
    ///   ——「放之前先在详情页选好字幕」不是一个真实的使用姿势。
    /// 重复的入口不是多一个选择,是多一处会不一致的状态。</para>
    ///
    /// <para>★★ 版本条<b>只在多于一个版本时才画</b>。一个选项的选择器是纯噪音
    /// (本仓已有的口径:源类型条、季条都这么处理)。</para>
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
        catch { return; } // ★ 拿不到就整块不画 —— 详情页主体已经在屏幕上了
        if (vers.Count == 0) return;

        /* ★ 默认落在**核心层挑中的那一条**(preferred),不是第一条。
           落第一条的话:正则明明选对了版本,详情页却在说另一条 ——
           「界面在撒谎」那个老坑就是这么来的。 */
        var pick = vers.FindIndex(v => Bool(v, "preferred"));
        if (pick < 0) pick = 0;

        Dispatcher.UIThread.Post(() =>
        {
            _mediaHost.Children.Clear();
            var line = Dim("");
            void Use(int i)
            {
                _versionId = Str(vers[i], "id");
                line.Text = MediaLine(vers[i]);
            }

            if (vers.Count > 1)
            {
                var bar = new WrapPanel();
                for (var i = 0; i < vers.Count; i++)
                {
                    var idx = i;
                    var chip = new Button
                    {
                        Classes = { "chip" }, Margin = new Thickness(0, 0, 8, 0),
                        Content = Str(vers[i], "name") is { Length: > 0 } n ? n : $"版本 {i + 1}",
                    };
                    chip.Click += (_, _) =>
                    {
                        for (var k = 0; k < bar.Children.Count; k++)
                            ((Button)bar.Children[k]).Classes.Set("on", k == idx);
                        Use(idx);
                    };
                    bar.Children.Add(chip);
                }
                ((Button)bar.Children[pick]).Classes.Set("on", true);
                _mediaHost.Children.Add(bar);
            }
            Use(pick);
            _mediaHost.Children.Add(line);
        });
    }

    /// <summary>
    /// 一行人话的媒体信息。
    ///
    /// <para>★ 只写<b>选片时真会看的</b>:分辨率、编码、大小、有几条音轨 / 字幕。
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
            // ★ 写 1080p 不写 1920×1080:高度才是大家用来说话的那个数
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
        // ★ 「0 条字幕」也要写:「这片没有字幕」是选片时的真信息,
        //   不写的话用户以为是没加载出来。
        bits.Add(subs > 0 ? $"{subs} 条字幕" : "无字幕");

        return string.Join("  ·  ", bits);
    }

    /// <summary>
    /// 编码的通用写法。
    /// <para>★ 直接 <c>ToUpper</c> 会得到 <c>H264</c> / <c>HEVC</c> 混排 ——
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
    /// <para>★★ 「选了版本有没有真的播那一条」<b>看界面是看不出来的</b> ——
    /// 版本条高亮了、按钮也点得动,而送下去的 media_source_id 可能根本没变。
    /// 本仓栽过一次同款(正则选对了版本,详情页和播放器却全写死回落第一条),
    /// 而它活了几个月。判据只有一个:<b>服务器实际被请求的是哪一条流</b>。</para>
    /// </summary>
    /// <summary>
    /// 自检:直接按「播放」。
    ///
    /// <para>★★ 必须<b>经由详情页</b>起播,不能直接 push 播放页 —— 预热(<c>prefs.preloadItem</c>)
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
            if (_mediaHost.Children.FirstOrDefault() is not WrapPanel bar || bar.Children.Count <= idx)
            {
                Console.WriteLine("[版本自检] 没有版本条(或者版本不够多)");
                return;
            }
            ((Button)bar.Children[idx]).RaiseEvent(
                new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
            Console.WriteLine($"[版本自检] 点了第 {idx + 1} 个版本,现在的 id = {_versionId}");
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
    /// <para>★ 超过一小时要写成 <c>1:05:30</c>。只按「分:秒」写的话
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
    /// <para>★★ Emby 回的是 <c>Continuing</c> / <c>Ended</c> —— <b>英文原文</b>。
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
    /// <para>★★ 淡出用的是 <b>OpacityMask</b>,不是「盖一层背景色的渐变」——
    /// 盖色要知道当前主题的底色,而本仓有深浅两套皮;写死一个色号就等于
    /// 浅色主题下头顶一道黑边。遮罩让页面底色自己透上来,换皮不用改这里。</para>
    ///
    /// <para>★ 没有背景图就<b>原样返回内容</b>,不留空高度 —— 留着的话
    /// 没刮削背景的条目头顶会空出 420px。</para>
    /// </summary>
    private Control Backdrop(JsonElement d, string id, Control content)
    {
        if (!Bool(d, "has_backdrop")) return content;

        /* ★★ 背景图用 <b>ImageBrush 当底纹</b>,不是塞一个 Image 进去。
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
    /// <para>★ 0.42:实测 0.30 在深色底上<b>几乎看不见</b>,等于白做;
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
    /// <para>★★ <b>多季必须分组</b>。20 集平铺成一片,想找「第二季第 1 集」只能从头数 ——
    /// 而剧集详情页最常见的动作恰恰就是这个。只有一季时不画季条:
    /// 一个只有一个选项的选择器是纯噪音。</para>
    ///
    /// <para>★ 默认落在**接着看的那一季**,不是第一季。追到第三季的人每次进来
    /// 都得先点一下第三季,那这个默认值等于没有。</para>
    /// </summary>
    private Control Episodes(List<CardItem> episodes)
    {
        var groups = episodes.GroupBy(e => e.SeasonNo).OrderBy(g => g.Key).ToList();
        var host = new StackPanel { Spacing = 14 };
        var railHost = new ContentControl();
        /* ★★ 集详情<b>就地展开</b>,不另开一页(用户 2026-09-02:
           「剧详情页到集详情页这是一个固定的程序,不然就把集详情页的东西
           放到剧详情页里面切换」)。 */
        var epHost = new ContentControl { IsVisible = false };

        /* ★ 「下一集」按**整部剧**的顺序算,不是当前这一季 ——
           一季的最后一集之后是下一季的第一集,按季算的话那儿就没有下一集了。 */
        var ordered = episodes.OrderBy(e => e.SeasonNo).ThenBy(e => e.EpisodeNo).ToList();
        CardItem? NextOf(CardItem cur)
        {
            var at = ordered.FindIndex(e => e.Id == cur.Id);
            return at >= 0 && at + 1 < ordered.Count ? ordered[at + 1] : null;
        }

        // 当前这一季的集表 + 它的滚动容器(「跳到第 N 集」要滚它)
        var shown = new List<CardItem>();
        ScrollViewer? rail = null;

        /* ★★ 一行,虚拟化,左右翻页(用户 2026-09-03:
           「做成一行的,可以点击左右的按钮滑动展示的」)。
           ☠ 光「做成一行」治不了「上千集卡死」—— 一行一千张卡还是一千张卡。
             真正救命的是 Carousel.Rail 里那个 VirtualizingStackPanel。 */
        void ShowSeason(List<CardItem> list)
        {
            shown.Clear();
            shown.AddRange(list);
            railHost.Content = Carousel.Rail(list,
                it => new Card(_core, _server, it, true,
                    x => ShowEpisode(epHost, x, NextOf(x)),
                    width: EpisodeCardWidth, subtitle: it.RuntimeLabel, title: it.Name, titleLines: 1),
                EpisodeCardWidth * 9 / 16, out var sv);
            rail = sv;
        }

        // ── 季 / 集 两个下拉 ────────────────────────────────────────
        /* ★★ 用户 2026-09-03:「同时给两个按钮,点击出现列表,滑动浏览季度/集数」。
           原来季是一排**平铺的按钮**:三季还行,而《海贼王》那种二十几季会折成四五行,
           把分集整个推到折线以下。集更没法平铺 —— 它本来就有上千个。
           下拉里的列表自己是滚动的,这正是「滑动浏览」要的东西。 */
        var seasonBtn = new Button { Classes = { "chip" }, Margin = new Thickness(0, 0, 8, 0) };
        var epBtn = new Button { Classes = { "chip" } };
        var current = 0;

        void Pick(int idx)
        {
            current = idx;
            var g = groups[idx];
            seasonBtn.Content = (g.Key > 0 ? $"第 {g.Key} 季" : "其它") + $" · {g.Count()} 集  ▾";
            // ★ 换季要把展开的那一集收掉:它属于上一季,留着就是「季换了、
            //   上面还摆着另一季的某一集」—— 一眼看不出是 bug,但对不上。
            epHost.IsVisible = false;
            _openEpisode = "";
            ShowSeason(g.ToList());
            epBtn.Content = $"跳到某一集  ▾";
        }

        seasonBtn.Click += (_, _) => Flyout(seasonBtn, groups.Select((g, i) =>
            ((g.Key > 0 ? $"第 {g.Key} 季" : "其它") + $" · {g.Count()} 集", (Action)(() => Pick(i)))).ToList());

        epBtn.Click += (_, _) => Flyout(epBtn, shown.Select((e, i) =>
            (e.DisplayTitle, (Action)(() => JumpTo(i)))).ToList());

        /* 跳到第 N 集:滚过去 + 就地展开它。
           ★ 只滚不展开的话,用户在一千集里选中的那一集会**混在一排卡里**,
             他还得再找一遍自己刚点的是哪个。 */
        void JumpTo(int i)
        {
            if (i < 0 || i >= shown.Count) return;
            var it = shown[i];
            ShowEpisode(epHost, it, NextOf(it));
            // 虚拟化面板不能按控件求位置(那一张多半还没造出来),按**卡宽**算
            if (rail is not null)
                rail.Offset = rail.Offset.WithX(Math.Max(0,
                    i * (EpisodeCardWidth + 12) - rail.Viewport.Width / 2 + EpisodeCardWidth / 2));
        }

        host.Children.Add(H2(groups.Count <= 1
            ? $"剧集 · 共 {episodes.Count} 集"
            : $"剧集 · {groups.Count} 季 · 共 {episodes.Count} 集"));

        // ★ 默认落在**接着看的那一季**,不是第一季。追到第三季的人每次进来
        //   都得先点一下第三季,那这个默认值等于没有。
        var next = NextEpisode(episodes);
        var at0 = groups.FindIndex(g => g.Key == next.SeasonNo);
        Pick(at0 < 0 ? 0 : at0);

        // ★ 只有一季就不画季按钮:一个只有一个选项的选择器是纯噪音
        var bar = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 0 };
        if (groups.Count > 1) bar.Children.Add(seasonBtn);
        bar.Children.Add(epBtn);
        host.Children.Add(bar);

        SelfCheckOpenEpisode(epHost, shown[0], NextOf(shown[0]));
        host.Children.Add(epHost);
        host.Children.Add(railHost);
        return host;
    }

    /// <summary>
    /// 分集卡宽。
    /// <para>★ 214(默认 256):分集列表是<b>用来找集的</b>,一屏看得到的越多越好 ——
    /// 单张再大也提供不了更多信息(同一部剧的剧照长得都差不多)。</para>
    /// </summary>
    private const double EpisodeCardWidth = 214;

    /// <summary>
    /// 挂在按钮下面的一列可选项。
    ///
    /// <para>★ 列表自己滚动并封顶 420 高 —— 上千集的话不封顶就是一条比屏幕还长的菜单,
    /// 顶端和底端都点不到。</para>
    /// <para>★ 每次点开<b>重建</b>:季一换,集表就换了。留着上一次那份是「换了季、
    /// 跳集列表还是上一季的」,而它不报错。</para>
    /// </summary>
    private static void Flyout(Button anchor, List<(string Label, Action Go)> items)
    {
        var list = new StackPanel { Spacing = 2 };
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
            var b = new Button
            {
                Content = label, Classes = { "ghost" },
                HorizontalAlignment = HorizontalAlignment.Stretch,
                HorizontalContentAlignment = HorizontalAlignment.Left,
            };
            b.Click += (_, _) => { fly.Hide(); go(); };
            list.Children.Add(b);
        }
        fly.ShowAt(anchor);
    }

    /// <summary>
    /// 自检:<c>LP_SELFCHECK_EPISODE=1</c> 直接把第一集的详情展开。
    ///
    /// <para>★★ 收起来的东西<b>截图里等于不存在</b> —— 这一块是这一版新加的,
    /// 而它最容易错的地方(剧照比例、文字列有没有和剧照顶对齐、按钮排没排齐)
    /// 全都只有展开之后才看得见。截图工具点不了卡片,所以要有这个钩子。</para>
    /// </summary>
    private void SelfCheckOpenEpisode(ContentControl slot, CardItem ep, CardItem? next)
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_EPISODE") != "1") return;
        Dispatcher.UIThread.Post(() => ShowEpisode(slot, ep, next), DispatcherPriority.Background);
    }

    /// <summary>现在展开着的是哪一集。再点同一张卡就收起来。</summary>
    private string _openEpisode = "";

    /// <summary>
    /// 就地展开一集的详情:剧照 + 集号 + 时长 / 播出日期 + 简介 + 播放。
    ///
    /// <para>★ 手里已经有的那几样(标题 / 集号 / 时长 / 进度)<b>先画出来</b> ——
    /// 简介要再打一次服务器,为了它让整块面板晚半秒出现是本末倒置。
    /// 这和详情页主按钮「不等分集就先出来」是同一条口径。</para>
    /// </summary>
    private void ShowEpisode(ContentControl slot, CardItem ep, CardItem? next)
    {
        // 再点同一张 = 收起来。没有这一下的话面板打开之后只能靠「收起」关,
        // 而用户的直觉是「再点一次那张卡」。
        if (_openEpisode == ep.Id && slot.IsVisible) { slot.IsVisible = false; _openEpisode = ""; return; }
        _openEpisode = ep.Id;

        var shot = new Border
        {
            Width = 300, Height = 169, CornerRadius = new CornerRadius(10), ClipToBounds = true,
            VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(Color.Parse("#1b212c")),
        };
        if (ep.HasPrimary)
        {
            var im = new Image { Stretch = Stretch.UniformToFill, Opacity = 0, Classes = { "art" } };
            shot.Child = im;
            _ = Fill(im, Images.EmbyImageUrl(_server, ep.Id, "Primary"), 338);
        }

        /* ★ 分集<b>常常没有真标题</b> —— Emby 会把 Name 填成「第 N 集」。
           无脑拼的话标题就成了「第 1 季 第 1 集 · 第 1 集」,同一件事说两遍。
           所以名字和集号一样时只写集号。 */
        var num = ep.SeasonNo > 0 && ep.EpisodeNo > 0
            ? $"第 {ep.SeasonNo} 季 第 {ep.EpisodeNo} 集"
            : ep.EpisodeNo > 0 ? $"第 {ep.EpisodeNo} 集" : "";
        var plain = ep.Name == "" || ep.Name == $"第 {ep.EpisodeNo} 集" || ep.Name == num;
        var head = num == "" ? ep.Name : plain ? num : $"{num} · {ep.Name}";
        var meta = new List<string>();
        if (ep.RuntimeLabel != "") meta.Add(ep.RuntimeLabel);
        if (ep.ResumeSecs > 0) meta.Add($"已看到 {Clock(ep.ResumeSecs)}");
        else if (ep.Played) meta.Add("已看完");

        var metaLine = new TextBlock
        {
            Text = string.Join("  ·  ", meta), Classes = { "dim" }, FontSize = 12.5,
            // ★ 没有元信息就整行不画:空一行等于这块面板每次高度都不一样
            IsVisible = meta.Count > 0,
        };
        var overview = new TextBlock
        {
            Text = "", Classes = { "dim" }, FontSize = 13, LineHeight = 21,
            TextWrapping = TextWrapping.Wrap, MaxLines = 5,
            TextTrimming = TextTrimming.CharacterEllipsis, IsVisible = false,
        };
        _ = FillEpisodeOverview(ep.Id, overview);

        var play = new Button
        {
            Classes = { "primary" },
            Content = ep.ResumeSecs > 0 ? $"▶ 继续播放 · 已看到 {Clock(ep.ResumeSecs)}" : "▶ 播放",
        };
        play.Click += (_, _) =>
            Nav.Push(new PlayerPage(_core, ep.Id, ep.DisplayTitle, ep.ResumeSecs, next: next));
        var close = new Button { Classes = { "ghost" }, Content = "收起" };
        close.Click += (_, _) => { slot.IsVisible = false; _openEpisode = ""; };

        var text = new StackPanel
        {
            Spacing = 10, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(18, 0, 0, 0),
            Children =
            {
                new TextBlock
                {
                    Text = head, FontSize = 17, FontWeight = FontWeight.SemiBold,
                    TextWrapping = TextWrapping.Wrap,
                },
                metaLine, overview,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { play, close },
                },
            },
        };
        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*") };
        Grid.SetColumn(shot, 0);
        Grid.SetColumn(text, 1);
        grid.Children.Add(shot);
        grid.Children.Add(text);

        slot.Content = new Border { Classes = { "card" }, Padding = new Thickness(16), Child = grid };
        slot.IsVisible = true;
    }

    /// <summary>
    /// 补这一集的简介(第二条命令)。
    ///
    /// <para>★ 拿不到就<b>整段不画</b>,不写「暂无简介」—— 相当一部分分集本来就没刮到简介,
    /// 每集都顶着一句「暂无简介」比留空更像坏了。</para>
    /// <para>★ 回来时要认一下<b>现在展开的还是不是这一集</b>:用户点得比网络快,
    /// 不认的话上一集的简介会贴到这一集上。</para>
    /// </summary>
    private async Task FillEpisodeOverview(string id, TextBlock overview)
    {
        try
        {
            var s = Nav.Session!;
            var d = await _core.EmbyItemDetail(new
            {
                s.server, s.token, s.user_id, s.device_id, item_id = id, with_children = false,
            });
            var text = Str(d, "overview");
            /* ★ **没有首播日期这一项**。核心层的 ItemDetail 里根本没有 premiere_date
               (Fields 里问了 PremiereDate,但结构体没往外透)——
               照写的话拿到的永远是空串,而界面上只会表现成「这一栏怎么从来不出现」。
               迁移期不动核心层的输出形状(会破坏差分对账基准),这一项就先不做。 */
            Dispatcher.UIThread.Post(() =>
            {
                if (_openEpisode != id) return;
                if (text == "") return;
                overview.Text = text;
                overview.IsVisible = true;
            });
        }
        catch { /* 简介是锦上添花,拿不到就没有 */ }
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
    /// <para>★ <b>这个顺序和 Emby 的「继续观看」一致</b>,主按钮和季条默认值共用它 ——
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
            // ★ 版本在 _versionId 里,**点的那一刻才读** —— 用户可能在按之前换过版本
            play.Click += (_, _) =>
                Nav.Push(new PlayerPage(_core, id, name, resume, mediaSourceId: _versionId));
            _play = play;
            row.Children.Add(play);
        }
        else if (type is "Series" or "Season")
        {
            /* ★★ 剧集详情页**必须有主按钮**。之前只有 Movie/Episode 有,
               剧的详情页上一个播放按钮都没有 —— 用户得滚到下面的分集网格里
               自己找「我看到第几集了」。那不是详情页,那是目录。

               ★★ 按钮<b>不等分集就先出来</b>。分集是第二条命令,慢的时候要一两秒;
                 为了在按钮上写出「第 3 集」而让整个按钮晚一秒出现,是本末倒置 ——
                 用户点它的意图是「接着看」,哪一集是我们该算出来的,不是他要读的。
                 点了之后再等那条命令(通常早就到了),把集号补在按钮上。
               ★ 挑哪一集的顺序在 NextEpisode 里,和季条的默认季共用同一份。 */
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
                Nav.Push(new PlayerPage(_core, next.Id, next.DisplayTitle, next.ResumeSecs, next: after));
            };
            row.Children.Add(play);
            // 分集到了就把集号补上去 —— 在此之前按钮已经可点了
            _ = LabelPlayLater(play);
        }

        // ★ 收藏跟 Features 走 —— 侧栏的「收藏」下线了,这里还留着按钮的话,
        //   用户收藏完找不到地方看,和「屏蔽了没有解除列表」是同一类坑。
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
                // ★ 参数名是 fav,不是 favorite。写错了**不报错** ——
                //   布尔默认成 false,表现是「点收藏反而取消了收藏」。
                await _core.EmbySetFavorite(new
                {
                    s.server, s.token, s.user_id, s.device_id, item_id = id, fav = on,
                });
                fav.Content = on ? "♥ 已收藏" : "♡ 收藏";
            }
            catch (Exception e) { fav.Content = LibraryPage.Advice(e); }
        };
        if (Features.On("card.favorite")) row.Children.Add(fav);

        // ★ 下载只对**可播条目**给。给一部剧的总条目下载按钮,点了不知道该下哪一集。
        if (playable)
        {
            var dl = new Button { Classes = { "ghost" }, Content = "⭳ 下载" };
            dl.Click += async (_, _) =>
            {
                dl.IsEnabled = false;
                try
                {
                    /* ★ container 从媒体信息里取。给错的话文件后缀就错 ——
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
                    // ★ 下载权限是**服务端**判的:没权限时如实说,别写成「网络错误」
                    dl.Content = LibraryPage.Advice(e);
                    dl.IsEnabled = true;
                }
            };
            row.Children.Add(dl);

            /* 用外部播放器打开。
               ★ 按钮**只在配了外部播放器时才出现**:没配的话点了只会得到
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
    /// <para>★★ <b>必须把 Opacity 拨回 1</b>。这些 Image 起手是 <c>Opacity=0</c>
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
}
