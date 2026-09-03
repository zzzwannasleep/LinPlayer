using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 首页(UI_PC §7.1):Hero → 继续观看 → <b>每个媒体库一条「最新」</b>。
///
/// <para>★★ <b>各块各自渲染,不设屏障</b>。「不秒加载」的根因从来不是动画,
/// 是加载结构:一个 <c>Promise.all</c> 屏障就能把最快的那块拖到最慢的那块之后
/// (实测 5.5 倍差距)。所以这里每条轨道**自己拉自己的**,谁先回来谁先出现。</para>
///
/// <para>★★ 2026-09-03 又加了两层(用户:「首页你没有做好加载,仍然是等全部加载完了才加载」):
/// ①<b>缓存先行</b> —— 命中 <see cref="MetaCache"/> 就当场把旧数据画出来,
/// 零往返;真数据回来再覆盖一次。②<b>折线以下的轨道滚到了才拉</b> ——
/// 库多的服务器有十几个库,开场就并发十几条请求,最上面那条「继续观看」
/// 会被后面十几条挤在同一个连接池里排队。用户看不见的东西不该抢带宽。</para>
/// </summary>
public sealed class HomePage : PageBase
{
    private readonly StackPanel _rows = new() { Spacing = 26 };
    /// <summary>滚动容器里那根柱子。懒加载判位要用它的坐标系(<see cref="ScrollViewer.Offset"/> 也在这个系里)。</summary>
    private readonly StackPanel _column;
    private readonly ScrollViewer _sv;
    private readonly Action<CardItem>? _onOpen;
    private readonly Hero _hero;
    private CoreClient? _core;
    private string _server = "";

    /// <summary>Hero 用几张。★ 这一批<b>只给 Hero</b> —— 「随便看看」那条 2026-09-03 撤了。</summary>
    private const int HeroCount = 5;

    /// <summary>
    /// 开场就直接拉的轨道数(含「继续观看」)。再往下的等滚到了再拉。
    ///
    /// <para>★ 3 是「首屏能看到的条数」:Hero 340 + 继续观看一条 + 半条,
    /// 1080 高的窗口上折线大约就落在这儿。</para>
    /// </summary>
    private const int EagerRows = 3;

    /// <summary>还没拉的轨道:控件 + 拉它的动作。滚到跟前了才执行,见 <see cref="PumpLazy"/>。</summary>
    private readonly List<(Control Box, Func<Task> Run)> _lazy = [];

    /// <param name="title">保留形参:外壳按源类型算出来的名字,别的入口还在传。</param>
    public HomePage(CoreClient core, Action<CardItem>? onOpen = null, string title = "首页")
    {
        _core = core;
        _onOpen = onOpen;
        /* ★★ <b>首页不写页头</b>(用户 2026-09-02:「继续观看上面的服务器名称也去掉」)。
           原来这儿写的是当前服务器名 —— 但侧栏那块已经在说同一件事,
           而且它一直在屏幕上;首页再写一遍,等于把 Hero 往下顶 40 多像素
           去重复一条用户已经看得见的信息。 */
        _ = title;

        /* ★★ 首页<b>不能整页塞进水槽里</b> —— Hero 是全宽出血的,
           封进去就成了「一张居中的插图」,两侧留白、顶上一道描边。
           所以这一页的结构和详情页一样:头图在水槽外面,正文另外排。 */
        _hero = new Hero(core!, onOpen);
        _column = new StackPanel
        {
            Spacing = 0,
            Children =
            {
                _hero,
                new Border
                {
                    HorizontalAlignment = HorizontalAlignment.Stretch,
                    Padding = new Thickness(18, 22, 18, 28), Child = _rows,
                },
            },
        };
        _sv = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _column,
        };
        // 滚到哪儿就把那儿的轨道拉起来。★ 也在布局变化时泵一次 —— 窗口很高的时候
        //   折线以下的轨道一开始就在屏幕上,而那时候一次滚动事件都还没发生过。
        _sv.ScrollChanged += (_, _) => PumpLazy();
        _rows.LayoutUpdated += (_, _) => PumpLazy();
        Content = _sv;
        if (core is not null) _ = LoadAsync(core);
    }

    private async Task LoadAsync(CoreClient core)
    {
        /* ★★ 会话<b>优先用外壳已经拉好的那份</b>(<see cref="Nav.Session"/>)。
           原来这一页自己再拉一次 emby.currentSession —— 而外壳启动时刚拉过,
           首页每次构造都白花一次往返,**而且这一次是串行的**:
           它没回来之前下面所有轨道一条都发不出去。 */
        JsonElement session = default;
        if (Nav.Session is null)
        {
            try { session = await core.EmbyCurrentSession(); }
            catch (Exception e) { AddRow(Dim($"读会话失败:{e.Message}")); return; }
            if (session.ValueKind != JsonValueKind.Object)
            {
                AddRow(Dim("当前账号不是 Emby(网盘 / 局域网源的首页还没做)。"));
                return;
            }
        }
        _server = Nav.Session?.server ?? Str(session, "server");
        var s = Nav.Session is { } ns
            ? new { server = ns.server, token = ns.token, user_id = ns.user_id, device_id = ns.device_id }
            : new
            {
                server = _server,
                token = Str(session, "token"),
                user_id = Str(session, "user_id"),
                device_id = "linplayer-desktop",
            };

        /* ★ 各块并发发出去,各自渲染 —— 谁先回来谁先出现,不互相等。
           ★★ 但**位置是先占好的**:每条轨道在发请求之前就把自己那一块(骨架)挂上去,
             所以屏幕上的顺序是固定的,不是「谁先回来谁排前面」。 */
        var resume = Track("继续观看", () => ResumeAndNextUp(core, s), true,
            key: MetaCache.Key("home.resume", s));

        /* ★★ 「各库最新」这一段要**先占住位置**再去拉。
           它依赖媒体库列表(得先知道有哪些库),比别的块晚一步;
           不先占位的话它只能被追加到最后,而且是等库表回来那一刻**当场跳一下**。 */
        var libSection = new StackPanel { Spacing = 26 };
        var libBusy = new StackPanel { Spacing = 10, Children = { H2("最新加入"), Skeleton.Strip(false) } };
        libSection.Children.Add(libBusy);

        var views = Track("媒体库",
            () => Arr(core.EmbyViews(new { s.server, s.token, s.user_id, s.device_id })), true,
            key: MetaCache.Key("emby.views", new { s.server, s.user_id }),
            onItems: libs => LatestPerLibrary(core, s, libSection, libBusy, libs));
        AddRow(libSection);
        /* ★ 确认是 Emby 了就先把 Hero 的位置占住(骨架)。
           它在页面最顶上,晚出现一次就把**整页**往下顶一次。 */
        _hero.Reserve();
        await Task.WhenAll(resume, views, HeroItems(core, s));
    }

    /// <summary>
    /// Hero 那几张。
    ///
    /// <para>★★ 「随便看看」那条轨道 2026-09-03 <b>撤了</b>(用户:「首页最底下的
    /// 随便看看去掉,不知道存在的意义在哪」)。原来两块共用一次 listRandom,
    /// 现在只剩 Hero 一个消费者,limit 也跟着从 13 降到 5 —— 少拉 8 条。</para>
    ///
    /// <para>★ 拉失败时要把 Hero <b>收掉</b>,否则骨架会一直闪 ——
    /// 那看着像「永远在加载」,而它其实已经失败了。</para>
    ///
    /// <para>★ 缓存命中时先用旧的那几张把 Hero 点亮:大图是首页上最显眼的一块,
    /// 它空着的那两秒等于整页都还没加载。</para>
    /// </summary>
    private async Task HeroItems(CoreClient core, object s)
    {
        var key = MetaCache.Key("emby.listRandom", new { _server, hero = HeroCount });
        var cached = MetaCache.PeekList(key);
        if (cached is { Count: > 0 }) _hero.Show(_server, cached);

        List<JsonElement> all;
        try { all = await Arr(core.EmbyListRandom(With(s, new { limit = HeroCount }))); }
        catch { if (cached is null) _hero.Hide(); return; }
        if (all.Count == 0) { _hero.Hide(); return; }
        /* ★ 内容没变就<b>不要再 Show 一次</b>。Show 会重建圆点、复位轮播、重发预取,
           用户看到的是刚出来的大图当场闪一下换成同一张 —— 那看着像 bug。 */
        if (cached is not null && cached.Select(Id).SequenceEqual(all.Select(Id)))
        {
            MetaCache.PutList(key, all);
            return;
        }
        MetaCache.PutList(key, all);
        _hero.Show(_server, all);
    }

    /// <summary>自检:把 Hero 翻到第 n 张(1 起)。</summary>
    internal void SelfCheckHero(int n) => _hero.SelfCheckJump(n);

    /// <summary>
    /// 各库最新:<b>每个库一条轨道</b>,不是一条全局的「最新加入」。
    ///
    /// <para>★★ 全局那一条的问题是**信息被稀释**:电影和剧集混在一起按时间排,
    /// 一部剧更新几集就能把一整行占满,想看「电影有什么新的」根本看不到。</para>
    ///
    /// <para>★★ <b>所有库都出</b>(用户 2026-09-03:「首页往下滑动应该是看到各个媒体库的最新,
    /// 而不是像现在这样只能看到部分媒体库」)。原来砍到前 6 个 ——
    /// 理由是「库多的服务器会把首页拉成一条竖直的目录」,但那是**滚动的成本**,
    /// 而滚动本来就是免费的;砍掉的却是「这个库有什么新的」这件事本身。
    /// 开销那一头改用<b>滚到了才拉</b>解决(见 <see cref="PumpLazy"/>),
    /// 而不是让用户看不到自己的库。</para>
    ///
    /// <para>★ 一个库都没有(或者库表拉失败)时**回落成一条全局的** ——
    /// 总比这一整段空着强。</para>
    /// </summary>
    private void LatestPerLibrary(CoreClient core, object s, StackPanel section,
        Control busy, List<JsonElement> libs)
    {
        Dispatcher.UIThread.Post(() =>
        {
            section.Children.Remove(busy);
            if (libs.Count == 0)
            {
                _ = Track("最新加入", () => Arr(core.EmbyListLatest(With(s, new { limit = 16 }))), false,
                    key: MetaCache.Key("emby.listLatest", new { _server }), host: section);
                return;
            }
            var n = 0;
            foreach (var lib in libs)
            {
                var id = Str(lib, "id");
                var name = Str(lib, "name");
                if (id == "") continue;
                /* ★ 标题只写库名,<b>不写「· 最新」</b>(用户 2026-09-02)——
                   首页整段本来就是「最新加入」,每一条再重复一次是纯噪音。
                   ★ 后面那个 › 点进这个库的网格页。 */
                _ = Track(name,
                    () => Arr(core.EmbyListLatest(With(s, new { parent_id = id, limit = 16 }))),
                    false, host: section, libraryId: id,
                    key: MetaCache.Key("emby.listLatest", new { _server, id }),
                    // ★ 第一条库轨道跟「继续观看」一起算进首屏,再往下的等滚到了再拉
                    lazy: ++n + 1 > EagerRows);
            }
        });
    }

    /// <summary>
    /// 「继续观看」= <b>看了一半的</b> + <b>接着看下一集</b>,合并成一条轨道。
    ///
    /// <para>★★ 按剧去重,<b>看了一半的优先</b>。同一部剧不该出现两张卡 ——
    /// 「第 3 集看了一半」和「下一集是第 4 集」是同一件事的两种说法。</para>
    ///
    /// <para>★ 去重键优先用 <c>series_id</c>(分集),没有就用条目自己的 id(电影)。</para>
    ///
    /// <para>★ 两条各自吞错:NextUp 在某些 fork 上没有,不能因此把「看了一半」也弄没。</para>
    /// </summary>
    private static async Task<List<JsonElement>> ResumeAndNextUp(CoreClient core, object s)
    {
        var a = Arr(core.EmbyListResume(With(s, new { limit = 12 })));
        var b = Arr(core.EmbyListNextUp(With(s, new { limit = 12 })));
        var resume = await Safe(a);
        var nextUp = await Safe(b);

        var seen = new HashSet<string>();
        var outp = new List<JsonElement>();
        foreach (var it in resume.Concat(nextUp))
        {
            var key = Str(it, "series_id") is { Length: > 0 } sid ? "s:" + sid : "i:" + Str(it, "id");
            if (seen.Add(key)) outp.Add(it);
        }
        return outp;
    }

    /// <summary>失败当空表 —— 合并的两条里挂了一条,不该把另一条也弄没。</summary>
    private static async Task<List<JsonElement>> Safe(Task<List<JsonElement>> t)
    {
        try { return await t; }
        catch { return []; }
    }

    private static async Task<List<JsonElement>> Arr(Task<JsonElement> t)
    {
        var d = await t;
        return d.ValueKind == JsonValueKind.Array ? d.EnumerateArray().ToList() : [];
    }

    /// <summary>把会话四件套和额外参数并成一个字典(匿名类型合不了)。</summary>
    private static Dictionary<string, object?> With(object sess, object extra)
    {
        var d = new Dictionary<string, object?>();
        foreach (var p in sess.GetType().GetProperties()) d[p.Name] = p.GetValue(sess);
        foreach (var p in extra.GetType().GetProperties()) d[p.Name] = p.GetValue(extra);
        return d;
    }

    /// <param name="onItems">数据到手时顺带回调一次(「各库最新」靠它拿库表)。</param>
    /// <param name="host">挂到哪儿。null = 挂到页面根上。</param>
    /// <param name="libraryId">非空 = 标题后面画一个 <c>›</c>,点了进这个库的网格页。</param>
    /// <param name="key">
    /// 缓存键。非空时<b>先把上一次的结果画出来</b>,再拿真数据覆盖一次。
    /// <para>★★ 这就是「回到首页要等四五秒」的解 —— 那四五秒里屏幕上其实
    /// **已经能画出内容了**,只是没人存过上一次的结果。</para>
    /// </param>
    /// <param name="lazy">true = 先只占位,滚到跟前了再真去拉。</param>
    private async Task Track(string title, Func<Task<List<JsonElement>>> load, bool wide,
        Action<List<JsonElement>>? onItems = null, StackPanel? host = null, string? libraryId = null,
        string? key = null, bool lazy = false)
    {
        /* ★★ 占位用**骨架**,不是「加载中…」。
           三个字只有 20px 高,内容一回来这一行从 20px 撑到 280px,
           下面几条轨道全被顶下去 —— 用户正看着的东西会跳走。
           骨架和真卡同尺寸,换上去是「填色」而不是「撑开」。 */
        var box = new StackPanel { Spacing = 10 };
        Control body = Skeleton.Strip(wide);
        box.Children.Add(RowHead(title, libraryId));
        box.Children.Add(body);
        if (host is null) AddRow(box);
        else Dispatcher.UIThread.Post(() => host.Children.Add(box));

        void Swap(Control with) => Dispatcher.UIThread.Post(() =>
        {
            var at = box.Children.IndexOf(body);
            if (at < 0) return;
            box.Children[at] = with;
            body = with;
        });

        // ★ 缓存先行:命中就当场画,一次往返都不等
        var hit = key is null ? null : MetaCache.PeekList(key);
        if (hit is not null)
        {
            Core.Perf.Log($"轨道「{title}」<- 缓存 {hit.Count} 条(零往返)");
            Swap(hit.Count == 0 ? Dim($"这台服务器上没有「{title}」的内容。") : Strip(hit, wide));
        }

        async Task Run()
        {
            var t0 = Core.Perf.Ms;
            try
            {
                var items = await load();
                Core.Perf.Log($"轨道「{title}」<- 服务器 {items.Count} 条,{Core.Perf.Ms - t0:0} ms");
                if (key is not null) MetaCache.PutList(key, items);
                onItems?.Invoke(items);
                // ★ 空态要说清「为什么空」,不是干放一句「暂无数据」(§6.4)
                Swap(items.Count == 0 ? Dim($"这台服务器上没有「{title}」的内容。") : Strip(items, wide));
            }
            /* ★ 已经用缓存画出内容之后再失败(离线 / 服务器挂了),<b>不要把内容换成一行红字</b> ——
               屏幕上那批旧数据仍然是用户能用的东西,擦掉它换成「加载失败」是纯粹的损失。 */
            catch (CoreException e) { if (hit is null) Swap(Dim($"{title}加载失败:{e.Advice}")); }
            catch (Exception e) { if (hit is null) Swap(Dim($"{title}加载失败:{e.Message}")); }
        }

        if (!lazy) { await Run(); return; }
        _lazy.Add((box, Run));
        Dispatcher.UIThread.Post(PumpLazy, DispatcherPriority.Background);
    }

    /// <summary>
    /// 把已经滚到跟前的懒轨道拉起来。
    ///
    /// <para>★ 提前 800px 开拉:等它进了视口才发请求的话,用户看到的是
    /// 「滑到这儿了,然后这一行开始加载」——那比一开始就全拉更像卡。</para>
    /// <para>★ 拉过的从表里摘掉。不摘的话每次滚动都会重发一遍请求。</para>
    /// </summary>
    private void PumpLazy()
    {
        if (_lazy.Count == 0) return;
        var edge = _sv.Offset.Y + _sv.Viewport.Height + 800;
        for (var i = _lazy.Count - 1; i >= 0; i--)
        {
            var (box, run) = _lazy[i];
            /* ★★ 坐标必须换算到<b>滚动内容那根柱子</b>的坐标系里 ——
               <c>_sv.Offset.Y</c> 说的就是这根柱子被推上去了多少。
               换算到 <c>_rows</c> 上的话少算了 Hero 那 340px + 水槽,
               表现是「一进首页十几条全被判成已经在屏幕上」,懒加载等于没做。 */
            var at = box.TranslatePoint(default, _column);
            // 还没排上版(高度为 0 / 拿不到坐标):这一轮先放着,LayoutUpdated 会再泵
            if (at is null || at.Value.Y <= 0) continue;
            if (at.Value.Y > edge) continue;
            _lazy.RemoveAt(i);
            _ = run();
        }
    }

    /// <summary>
    /// 横向轨道。宽卡 256×144(16:9),窄卡 158×237(2:3)。
    ///
    /// <para>★ 交给 <see cref="Carousel"/> 包一层翻页按钮 —— <b>光有滚轮不够</b>:
    /// 一条轨道 20 张卡,屏幕上只看得到五六张,后面十几张没有任何东西
    /// 告诉用户它们存在。</para>
    /// </summary>
    private Control Strip(List<JsonElement> items, bool wide)
    {
        using var _ = Core.Perf.Measure($"造 {Math.Min(items.Count, 20)} 张卡");
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        foreach (var it in items.Take(20))
            panel.Children.Add(new Card(_core!, _server, CardItem.From(it), wide, _onOpen));
        // 图区高度:翻页按钮要对齐图的中线,不是整张卡的中线(卡下面还有两行标题)
        var w = wide ? 256.0 : 158.0;
        return Carousel.Wrap(panel, wide ? w * 9 / 16 : w * 3 / 2);
    }

    /// <summary>
    /// 一条轨道的标题行。<paramref name="libraryId"/> 非空时后面跟一个 <c>›</c>,
    /// 点了直接进这个库的网格页。
    ///
    /// <para>★★ 首页每个库只出 16 条,而库里可能有几千条 —— 用户看完这一行之后
    /// <b>没有任何入口</b>能就地进到这个库里,只能绕去侧栏的「媒体库」再点一次。</para>
    ///
    /// <para>★ 整行可点,不只是那个箭头:一个 12px 宽的箭头是个很难瞄的靶子。</para>
    /// </summary>
    private Control RowHead(string title, string? libraryId)
    {
        var head = H2(title);
        if (libraryId is null || _core is null) return head;

        var arrow = new TextBlock
        {
            Text = "›", FontSize = 20, Margin = new Thickness(6, -2, 0, 0),
            VerticalAlignment = VerticalAlignment.Center, Classes = { "dim" },
        };
        var b = new Button
        {
            Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Left,
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
            Content = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                Children = { head, arrow },
            },
        };
        b.Click += (_, _) => Nav.Push(new LibraryGridPage(_core, _server, libraryId, title));
        return b;
    }

    private void AddRow(Control c) => Dispatcher.UIThread.Post(() => _rows.Children.Add(c));

    private static string Id(JsonElement e) => Str(e, "id");

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}
