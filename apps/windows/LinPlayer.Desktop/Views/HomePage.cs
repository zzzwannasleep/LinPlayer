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
using Avalonia.VisualTree;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 首页(UI_PC §7.1):Hero → 继续观看 → 每个媒体库一条「最新」。
///
/// <para>各块各自渲染,不设屏障 ——「不秒加载」的根因从来不是动画,是加载结构:
/// 一个 <c>Promise.all</c> 屏障就能把最快的那块拖到最慢的那块(实测 5.5 倍)。
/// 2026-09-03 又加两层(用户:「仍然是等全部加载完才显示」):缓存先行(命中
/// <see cref="MetaCache"/> 就当场画旧数据,零往返),折线以下的轨道滚到了才拉 ——
/// 库多的服务器开场并发十几条,会把最上面那条挤在同一个连接池里排队。</para>
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

    /// <summary>Hero 用几张。 这一批<b>只给 Hero</b> —— 「随便看看」那条 2026-09-03 撤了。</summary>
    private const int HeroCount = 5;

    /// <summary>
    /// 开场就直接拉的轨道数(含「继续观看」)。再往下的等滚到了再拉。
    ///
    /// <para>3 是「首屏能看到的条数」:Hero 340 + 继续观看一条 + 半条,
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
        /* <b>首页不写页头</b>(用户 2026-09-02:「继续观看上面的服务器名称也去掉」)。
           原来这儿写的是当前服务器名 —— 但侧栏那块已经在说同一件事,
           而且它一直在屏幕上;首页再写一遍,等于把 Hero 往下顶 40 多像素
           去重复一条用户已经看得见的信息。 */
        _ = title;

        /* 首页<b>不能整页塞进水槽里</b> —— Hero 是全宽出血的,
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
                    Padding = new Thickness(18, 26, 18, 26), Child = _rows,
                },
            },
        };
        _sv = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = _column,
        };
        // 滚到哪儿就把那儿的轨道拉起来。 也在布局变化时泵一次 —— 窗口很高的时候
        // 折线以下的轨道一开始就在屏幕上,而那时候一次滚动事件都还没发生过。
        _sv.ScrollChanged += (_, _) => PumpLazy();
        _rows.LayoutUpdated += (_, _) => PumpLazy();
        SelfCheckHome();
        Content = _sv;
        if (core is not null) _ = LoadAsync(core);
    }

    private async Task LoadAsync(CoreClient core)
    {
        /* 会话<b>优先用外壳已经拉好的那份</b>(<see cref="Nav.Session"/>)。
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

        /* 各块并发发出去,各自渲染 —— 谁先回来谁先出现,不互相等。
            但**位置是先占好的**:每条轨道在发请求之前就把自己那一块(骨架)挂上去,
            所以屏幕上的顺序是固定的,不是「谁先回来谁排前面」。 */
        var resume = Track("继续观看", () => ResumeAndNextUp(core, s), true,
            key: MetaCache.Key("home.resume", s));

        /* 合集。<b><c>emby.listCollections</c> 早就注册着,UI 一次没调过</b> ——
           这是本仓第五次撞上「后端领先前端」。
            一条**懒**轨道:合集是锦上添花,不该和继续观看抢首屏那次往返。
            没有合集的服务器很常见,那就**整条不画**(hideWhenEmpty)——
            不是画一行「这台服务器上没有合集」。用户 2026-09-03 定的:
            「如果该 Emby 没有 那么就不显示」。空态提示对**用户点进来的**页面
            有意义(他在找那个东西),对首页上一条他没要求过的轨道只是噪音。
            另有一个**按服务器**的开关(设置页「首页栏目」),关了就连请求都不发。 */
        /* 按服务器关掉的话**连请求都不发** —— 只把结果丢掉的话,
           每次进首页仍然白打一次服务器,而用户以为自己关掉了这个东西。

           2026-09-04:这个开关<b>不能在这儿 await</b>。
           原来写的是 `var boxsets = await CollectionsOn(core) ? Track(…) : …` ——
           `await` 落在三元表达式**前面**,于是 prefs.getHomeSettings 这一次往返
           成了整页的**屏障**:它没回来之前,「各库最新」和 Hero 连排都还没排上,
           一条请求都发不出去。用户 2026-09-04 报的「打开软件偶发加载不出来,
           只显示一个没有封面的栏目」就是这一下 —— 屏障那头卡住时,
           屏幕上就只剩它前面那条「继续观看」。
           这一页整个文件都在讲「各块各自渲染不设屏障」,而这里自己开了一个。
           改法:开关**在这条轨道自己的 loader 里问**(它本来就是 lazy 的,
             滚到了才跑),关掉就回空表 + hideWhenEmpty 整条不画,行为一模一样。 */
        var boxsets = Track("合集", async () =>
                await CollectionsOn(core)
                    ? await Arr(core.EmbyListCollections(
                        new { s.server, s.token, s.user_id, s.device_id }))
                    : [], false,
            key: MetaCache.Key("emby.listCollections", new { s.server, s.user_id }),
            lazy: true, hideWhenEmpty: true);

        /* 「各库最新」这一段要**先占住位置**再去拉。
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
        /* 确认是 Emby 了就先把 Hero 的位置占住(骨架)。
           它在页面最顶上,晚出现一次就把**整页**往下顶一次。 */
        _hero.Reserve();
        await Task.WhenAll(resume, boxsets, views, HeroItems(core, s));
    }

    /// <summary>
    /// 自检:首页上有没有「合集」这一栏(<c>LP_SELFCHECK_HOME=1</c>)。
    ///
    /// <para>判据是整条轨道在不在,不是「有没有合集卡片」。用户说「没有就不显示」,
    /// 而上一版画的是一行「这台服务器上没有合集的内容。」—— 那也是显示了。
    /// 只数卡片的话两种行为都是 0 张卡,分不出来。所以同时报「标题行在不在」
    /// 和「那句空态文案在不在」。</para>
    /// </summary>
    private void SelfCheckHome()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_HOME") != "1") return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(5000);
            Dispatcher.UIThread.Post(() =>
            {
                var titles = new List<string>();
                var emptyNote = false;
                foreach (var t in _rows.GetVisualDescendants().OfType<TextBlock>())
                {
                    var s2 = t.Text ?? "";
                    if (s2.Contains("没有「合集」")) emptyNote = true;
                    if (s2.Length is > 0 and < 12) titles.Add(s2);
                }
                var has = titles.Contains("合集");
                /* 虚拟化到底省没省事,界面上<b>看不出来</b> —— 虚拟化的和不虚拟化的
                   长得一模一样,差别只在造了多少个控件、发了多少次封面请求。
                   所以判据只能是这个数:轨道数 × 20 是「全量实例化」的量,
                   实际造出来的应该远小于它。
                   反向注入:把 Strip 改回 StackPanel + foreach,这个数当场翻几倍。 */
                var rails = _rows.GetVisualDescendants().OfType<ItemsControl>().Count();
                Console.WriteLine($"[首页卡片] 轨道 {rails} 条 × 每条最多 20 张 = 全量要 {rails * 20} 张;" +
                                  $"实际造了 {Card.Made} 张");
                Console.WriteLine(rails > 0 && Card.Made < rails * 20
                    ? "[首页卡片] ✓ 虚拟化生效:只造了看得见的那些"
                    : "[首页卡片] ✗ 每条轨道都在全量实例化 —— 全屏(视口更高)时这个量会成倍涨");
                Console.WriteLine($"[合集栏] 轨道标题:{string.Join(" / ", titles.Distinct().Take(12))}");
                Console.WriteLine(has
                    ? "[合集栏] 有「合集」这一栏"
                    : "[合集栏] 没有「合集」这一栏");
                Console.WriteLine(emptyNote
                    ? "[合集栏] ✗ 还画着「这台服务器上没有合集」那行空态 —— 用户要的是整条不画"
                    : "[合集栏] ✓ 没有空态文案");
            });
        });
    }

    /// <summary>
    /// 这台服务器的首页要不要画合集栏(设置页「首页栏目」里按服务器定的)。
    ///
    /// <para>拉不到就当<b>开着</b>。这是个「隐藏某个栏目」的开关 ——
    /// 读取失败时默认隐藏的话,用户看到的是「合集栏没了」,而他什么都没改过,
    /// 也没有任何提示告诉他为什么。宁可多画一条。</para>
    /// </summary>
    private static async Task<bool> CollectionsOn(CoreClient core)
    {
        try
        {
            var r = await core.PrefsGetHomeSettings(new { });
            return !r.TryGetProperty("collections_enabled", out var v) || v.ValueKind != JsonValueKind.False;
        }
        catch { return true; }   // 读不到设置就按「开」走:首页少一块比多一块更像坏了
    }

    /// <summary>
    /// Hero 那几张。
    ///
    /// <para>「随便看看」那条轨道 2026-09-03 撤了(用户:「不知道存在的意义在哪」),
    /// 现在只剩 Hero 一个消费者,limit 从 13 降到 5。拉失败要把 Hero 收掉,
    /// 否则骨架一直闪 —— 那看着像「永远在加载」,而它其实已经失败了。
    /// 缓存命中时先用旧的那几张点亮:大图空着的两秒等于整页都还没加载。</para>
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
        /* 内容没变就<b>不要再 Show 一次</b>。Show 会重建圆点、复位轮播、重发预取,
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
    /// 各库最新:每个库一条轨道,不是一条全局的「最新加入」。
    ///
    /// <para>全局那条会稀释信息:一部剧更新几集就能占满一整行。所有库都出
    /// (用户 2026-09-03:「不该只能看到部分媒体库」)—— 原来砍到前 6 个,
    /// 理由是「库多会把首页拉成一条竖直目录」,但那是版式问题、滚动是免费的,
    /// 砍掉的却是「这个库有什么新的」。开销那头改用滚到了才拉(<see cref="PumpLazy"/>)。
    /// 一个库都没有时回落成一条全局的。</para>
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
                /* 标题只写库名,<b>不写「· 最新」</b>(用户 2026-09-02)——
                   首页整段本来就是「最新加入」,每一条再重复一次是纯噪音。
                   后面那个 › 点进这个库的网格页。 */
                _ = Track(name,
                    () => Arr(core.EmbyListLatest(With(s, new { parent_id = id, limit = 16 }))),
                    false, host: section, libraryId: id,
                    key: MetaCache.Key("emby.listLatest", new { _server, id }),
                    // 第一条库轨道跟「继续观看」一起算进首屏,再往下的等滚到了再拉
                    lazy: ++n + 1 > EagerRows);
            }
        });
    }

    /// <summary>
    /// 「继续观看」= <b>看了一半的</b> + <b>接着看下一集</b>,合并成一条轨道。
    ///
    /// <para>按剧去重,<b>看了一半的优先</b>。同一部剧不该出现两张卡 ——
    /// 「第 3 集看了一半」和「下一集是第 4 集」是同一件事的两种说法。</para>
    ///
    /// <para>去重键优先用 <c>series_id</c>(分集),没有就用条目自己的 id(电影)。</para>
    ///
    /// <para>两条各自吞错:NextUp 在某些 fork 上没有,不能因此把「看了一半」也弄没。</para>
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
    /// <para>这就是「回到首页要等四五秒」的解 —— 那四五秒里屏幕上其实
    /// **已经能画出内容了**,只是没人存过上一次的结果。</para>
    /// </param>
    /// <param name="lazy">true = 先只占位,滚到跟前了再真去拉。</param>
    private async Task Track(string title, Func<Task<List<JsonElement>>> load, bool wide,
        Action<List<JsonElement>>? onItems = null, StackPanel? host = null, string? libraryId = null,
        string? key = null, bool lazy = false, bool hideWhenEmpty = false)
    {
        /* 占位用**骨架**,不是「加载中…」。
           三个字只有 20px 高,内容一回来这一行从 20px 撑到 280px,
           下面几条轨道全被顶下去 —— 用户正看着的东西会跳走。
           骨架和真卡同尺寸,换上去是「填色」而不是「撑开」。 */
        var box = new StackPanel { Spacing = 10 };
        Control body = Skeleton.Strip(wide);
        box.Children.Add(RowHead(title, libraryId));
        box.Children.Add(body);
        if (host is null) AddRow(box);
        else Dispatcher.UIThread.Post(() => host.Children.Add(box));

        /* 整条轨道消失(标题行一起)。
            从**它实际挂进去的那个容器**里摘 —— host 给了就是 host,没给才是 _rows。
             写死 _rows 的话,挂在「最新加入」小节里的轨道摘不掉,而且**不报错**:
             Remove 一个不在表里的元素返回 false,谁也不会去看那个返回值。 */
        void Vanish() => Dispatcher.UIThread.Post(() =>
        {
            Core.Perf.Log($"轨道「{title}」<- 0 条,整条不画");
            (host ?? _rows).Children.Remove(box);
        });

        void Swap(Control with) => Dispatcher.UIThread.Post(() =>
        {
            var at = box.Children.IndexOf(body);
            if (at < 0) return;
            box.Children[at] = with;
            body = with;
        });

        // 缓存先行:命中就当场画,一次往返都不等
        var hit = key is null ? null : MetaCache.PeekList(key);
        if (hit is not null)
        {
            Core.Perf.Log($"轨道「{title}」<- 缓存 {hit.Count} 条(零往返)");
            if (hit.Count == 0 && hideWhenEmpty) Vanish();
            else Swap(hit.Count == 0 ? Dim($"这台服务器上没有「{title}」的内容。") : Strip(hit, wide));
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
                // 空态要说清「为什么空」,不是干放一句「暂无数据」(§6.4)
                // hideWhenEmpty 的轨道例外:它整条消失,连标题都不留 ——
                // 首页上一条用户没要求过的空轨道,写什么都是噪音。
                if (items.Count == 0 && hideWhenEmpty) Vanish();
                else Swap(items.Count == 0 ? Dim($"这台服务器上没有「{title}」的内容。") : Strip(items, wide));
            }
            /* 已经用缓存画出内容之后再失败(离线 / 服务器挂了),<b>不要把内容换成一行红字</b> ——
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
    /// <para>提前 800px 开拉:等它进了视口才发请求的话,用户看到的是
    /// 「滑到这儿了,然后这一行开始加载」——那比一开始就全拉更像卡。</para>
    /// <para>拉过的从表里摘掉。不摘的话每次滚动都会重发一遍请求。</para>
    /// </summary>
    private void PumpLazy()
    {
        if (_lazy.Count == 0) return;
        var edge = _sv.Offset.Y + _sv.Viewport.Height + 800;
        for (var i = _lazy.Count - 1; i >= 0; i--)
        {
            var (box, run) = _lazy[i];
            /* 坐标必须换算到<b>滚动内容那根柱子</b>的坐标系里 ——
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
    /// <para>交给 <see cref="Carousel"/> 包一层翻页键 —— 光有滚轮不够,一条轨道 20 张卡
    /// 屏幕上只看得到五六张。2026-09-04 从 <c>StackPanel + foreach</c> 换成虚拟化的
    /// <see cref="Carousel.Rail"/>(用户:「全屏后滑动首页变卡了,窗口的时候流畅」)——
    /// 全屏视口变高,一次判成「该拉了」的轨道更多,要造的卡和封面请求成倍涨,
    /// 而多出来的一张都不在屏幕上。间距仍传 12:这一轮没人要求改首页的间距。</para>
    /// </summary>
    private Control Strip(List<JsonElement> items, bool wide)
    {
        var shown = items.Take(20).ToList();
        using var _m = Core.Perf.Measure($"排 {shown.Count} 张卡(虚拟化,只造看得见的)");
        // 图区高度:翻页按钮要对齐图的中线,不是整张卡的中线(卡下面还有两行标题)
        var w = wide ? 256.0 : 158.0;
        return Carousel.Rail(shown,
            it => new Card(_core!, _server, CardItem.From(it), wide, _onOpen),
            wide ? w * 9 / 16 : w * 3 / 2, out _, gap: 12);
    }

    /// <summary>
    /// 一条轨道的标题行。<paramref name="libraryId"/> 非空时后面跟一个 <c>›</c>,
    /// 点了直接进这个库的网格页。
    ///
    /// <para>首页每个库只出 16 条,而库里可能有几千条 —— 用户看完这一行之后
    /// <b>没有任何入口</b>能就地进到这个库里,只能绕去侧栏的「媒体库」再点一次。</para>
    ///
    /// <para>整行可点,不只是那个箭头:一个 12px 宽的箭头是个很难瞄的靶子。</para>
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
