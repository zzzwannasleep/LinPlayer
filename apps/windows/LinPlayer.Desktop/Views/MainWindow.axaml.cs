using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives.PopupPositioning;
using Avalonia.Controls.Presenters;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

public partial class MainWindow : Window
{
    private readonly Desktop.Core.CoreClient? _core = Program.Core;

    public MainWindow()
    {
        using var _ = Perf.Measure("MainWindow 构造");
        InitializeComponent();

        var drag = this.FindControl<Border>("DragArea")!;
        // ★ 自绘标题栏必须自己接拖拽与双击最大化 —— 不接的话窗口拖不动,
        //   而用户第一反应是「卡死了」,不会想到是标题栏没实现。
        drag.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) BeginMoveDrag(e);
        };
        drag.DoubleTapped += (_, _) => ToggleMaximize();

        this.FindControl<Button>("BtnMin")!.Click += (_, _) => WindowState = WindowState.Minimized;
        this.FindControl<Button>("BtnMax")!.Click += (_, _) => ToggleMaximize();
        this.FindControl<Button>("BtnClose")!.Click += (_, _) => Close();

        Nav.Host = Show;
        Nav.Immersive = SetImmersive;

        this.FindControl<Button>("BtnCollapse")!.Click += (_, _) => ToggleSidebar();
        // ★ 需要 Emby 会话的页面统一走 Emby():账号是网盘 / 局域网源时 Nav.Session 是 null,
        //   页面里直接解引用会抛在 Task 里 —— 没提示、不崩、就是永远停在「加载中」。
        this.FindControl<RadioButton>("NavHome")!.Checked += (_, _) => Nav.Root(Home());
        /* ★★ 「文件浏览」只在当前账号是**浏览型源**时才出现。
           Emby 账号下亮着它,点进去只会拿到一句「当前没有已登录的文件源」——
           那不是功能,那是一个专门用来报错的入口。 */
        this.FindControl<RadioButton>("NavBrowse")!.Checked += (_, _) =>
            Nav.Root(new BrowsePage(_core!, _sourceName));
        /* ★★ 「影视目录」和「文件浏览」是**两页**,不是一页的两种模式。
           资源站有分类、有分页、有分集,不是文件树 —— 塞进文件浏览页的话
           分类要伪装成文件夹、翻页要伪装成一个叫「下一页」的文件夹。
           入口按源的能力显隐:探不到影视目录能力时这一页会自己退回文件浏览。 */
        this.FindControl<RadioButton>("NavCatalog")!.Checked += (_, _) =>
            Nav.Root(new CatalogPage(_core!, () =>
                this.FindControl<RadioButton>("NavBrowse")!.IsChecked = true));
        // 插件页不需要 Emby 会话:它打的是插件源和本地插件目录,和用户的服务器无关。
        this.FindControl<RadioButton>("NavPlugins")!.Checked += (_, _) => Nav.Root(new PluginPage(_core!));
        this.FindControl<RadioButton>("NavLibrary")!.Checked += (_, _) => Emby("媒体库", () => new LibraryPage(_core!));
        this.FindControl<RadioButton>("NavSearch")!.Checked += (_, _) => Emby("搜索", () => new SearchPage(_core!));
        this.FindControl<RadioButton>("NavFavorites")!.Checked += (_, _) => Emby("收藏", () => new FavoritesPage(_core!));
        // 聚合视界和观看历史**不需要**当前会话:前者自己遍历账号表,后者读的是本地库
        this.FindControl<RadioButton>("NavAggregate")!.Checked += (_, _) => Nav.Root(new AggregatePage(_core!));
        this.FindControl<RadioButton>("NavHistory")!.Checked += (_, _) => Nav.Root(new HistoryPage(_core!));
        // ★ 排行榜**不需要** Emby 会话:它打的是弹弹Play / TMDB,和用户的服务器无关。
        //   套 Emby() 的话,网盘用户和没登录的人会被挡在 NoSessionPage 上,
        //   而那页说的是「请先登录服务器」—— 和这一页的实际前提对不上。
        this.FindControl<RadioButton>("NavRanking")!.Checked += (_, _) => Nav.Root(new RankingPage(_core!));
        // 下载页不要求 Emby 会话:列表读的是本地索引,网盘用户也看得到自己的历史任务
        this.FindControl<RadioButton>("NavDownload")!.Checked += (_, _) => Nav.Root(new DownloadPage(_core!));
        // 日历同样不要求 Emby 会话:它打的是 Bangumi / Trakt
        this.FindControl<RadioButton>("NavCalendar")!.Checked += (_, _) => Nav.Root(new CalendarPage(_core!));
        this.FindControl<RadioButton>("NavSettings")!.Checked += (_, _) => Nav.Root(new SettingsPage(_core!));

        /* ★★ 基础流程之外的入口在这里统一藏掉。表在 Features.cs —— **只有那一处**。
           散在各页里写 if 的话,过两周没人知道哪些是关着的。

           ★ 只藏不拆:接线全留着,自检台还要能跳过去(SelfCheckJump);
             藏起来的 RadioButton 照样能被程序勾中。打磨好一个就从表里删一行。 */
        foreach (var (ctl, id) in NavGates)
            this.FindControl<RadioButton>(ctl)!.IsVisible = Features.On(id);

        /* ★★ 自检模式下把窗口置顶。
           截图走的是 CopyFromScreen —— 抓的是**屏幕那块区域**,不是窗口自身内容。
           被别的程序压住时截出来的是压在上面那个窗口,而脚本照样报「成功」。
           2026-08-31 真栽过:截到了另一个程序的界面,差点当成 LinPlayer 的界面来读。
           SetForegroundWindow 在调用方不是前台进程时会被 Windows 拒掉,靠不住;
           由被截的窗口**自己置顶**才是稳的。只在自检时开,不影响产品行为。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK") == "1") Topmost = true;

        /* ★★ 兜住渲染里抛出来的异常。
           详情页那次是「一个控件同时挂两处」,它抛在 Dispatcher 回调里,
           **整个进程当场退出**。这类错误一定还会有(每加一段渲染就多一次机会),
           所以要有一个横切的接住点,而不是每页各写一个 try。
           ★ 接住之后必须**显示出来**:默默吞掉就成了「不报错、不崩、只是没画出来」,
             那是本仓最讨厌的失败形态。 */
        var bar = this.FindControl<Border>("ErrorBar")!;
        var barText = this.FindControl<TextBlock>("ErrorText")!;
        this.FindControl<Button>("ErrorClose")!.Click += (_, _) => bar.IsVisible = false;
        Dispatcher.UIThread.UnhandledException += (_, e) =>
        {
            e.Handled = true; // 不让它打死进程
            Console.WriteLine("[UI 线程] 未捕获异常: " + e.Exception);
            barText.Text = $"这一步出错了:{e.Exception.Message}";
            bar.IsVisible = true;
        };

        // 掉帧探针:只有 LP_PERF=1 时才真的挂上去
        Perf.WatchJank();
        Opened += async (_, _) =>
        {
            Perf.Log("窗口 Opened");
            await BootAsync();
            Perf.Log("BootAsync 结束");
        };
    }

    /// <summary>侧栏入口 → 功能开关 id。改开关去 <see cref="Features"/>,不是这儿。</summary>
    private static readonly (string Ctl, string Id)[] NavGates =
    [
        ("NavFavorites", "nav.favorites"), ("NavAggregate", "nav.aggregate"),
        ("NavHistory", "nav.history"), ("NavDownload", "nav.download"),
        ("NavRanking", "nav.ranking"), ("NavCalendar", "nav.calendar"),
        ("NavPlugins", "nav.plugins"), ("NavBrowse", "nav.browse"),
        ("NavCatalog", "nav.catalog"),
    ];

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    private void ToggleMaximize() =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    /// <summary>
    /// 真机自检用:环境变量 <c>LP_SELFCHECK_PAGE</c> 指到哪一页就直接落到哪一页。
    ///
    /// <para>★ 截图工具点不了按钮。没有这个钩子的话「除首页以外的每一页」
    /// 都只能靠编译通过来证明 —— 而本仓库栽过的渲染 bug **一个都不会在编译期现形**。</para>
    /// </summary>
    /// <summary>自检:在详情页点一下「下载」,然后落到下载页。</summary>
    private async Task SelfCheckDownload()
    {
        await Task.Delay(1500); // 等详情页把按钮画出来
        if (Nav.Current is DetailPage dp) dp.SelfCheckDownload();
        await Task.Delay(1200); // 等入队 + 下一点字节
        this.FindControl<RadioButton>("NavDownload")!.IsChecked = true;
    }

    private void SelfCheckJump() => SelfCheckJump(Environment.GetEnvironmentVariable("LP_SELFCHECK_PAGE"));

    /// <summary>
    /// 自检:挂一个开发目录插件、直接启用(自检不弹授权框)。
    /// <paramref name="loginKind"/> 非空时顺带把它贡献的源登录进来并落到影视目录页。
    /// </summary>
    private async Task SelfCheckMountPlugin(string dir, string? loginKind)
    {
        try
        {
            var info = await _core!.PluginPickDevDir(new { path = dir });
            var id = info.TryGetProperty("id", out var v) ? v.GetString() ?? "" : "";
            if (id != "") await _core.PluginEnable(new { id });
            if (loginKind is not null)
            {
                await _core.SourceLogin(new { kind = loginKind, base_url = "http://127.0.0.1:18096" });
                UpdateServerChip(await _core.AccountListAccounts());
                this.FindControl<RadioButton>("NavCatalog")!.IsChecked = true;
                // 自检:再把详情盖层打开一次 —— 它是这一页最容易画错的部分。
                if (Environment.GetEnvironmentVariable("LP_SELFCHECK_CATALOG_DETAIL") == "1" &&
                    Nav.Current is CatalogPage cp) await cp.SelfCheckOpenFirst();
                return;
            }
        }
        catch (Exception e) { Console.WriteLine("[自检] 挂插件失败:" + e.Message); }
        if (Nav.Current is PluginPage pp2) { pp2.SelectTab(1); await pp2.SelfCheckReload(); }
    }

    private void SelfCheckJump(string? want)
    {
        // ★ 最大化必须单独验一遍:无边框窗口最大化时四周会溢出屏幕 8px,
        //   把自绘标题栏的按钮顶到屏幕外(Rust 版栽过,根治办法是 WM_GETMINMAXINFO 钉 rcWork)。
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_MAXIMIZE") == "1")
            WindowState = WindowState.Maximized;

        /* ★★ 滚动要在**早退之前**排。
           LP_SELFCHECK_PAGE 为空(= 落在首页)时这个方法从这里就返回了,
           于是 LP_SCROLL 在首页上**从来没生效过** —— 而首页恰恰是最长的一页,
           折线以下那两条轨道一次都没被看过。
           一个「设了没反应」的自检开关比没有更糟:它会让人以为已经验过了。 */
        SelfCheckScroll();
        SelfCheckMenu();
        SelfCheckCount();
        SelfCheckHero();
        SelfCheckNavHover();
        SelfCheckGlyphs();
        SelfCheckFill();
        SelfCheckSidebar();
        SelfCheckServerMenu();
        /* 自检:把侧栏收起来。
           ★ 折叠态是这一版新加的,而它<b>收着的时候才是新形态</b> ——
             不主动收一次,截图永远拍的是展开态,图标有没有对齐、
             服务器卡会不会被裁掉半个字,全没人看过。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_COLLAPSE") == "1")
            _ = Task.Delay(1200).ContinueWith(_ => Dispatcher.UIThread.Post(ToggleSidebar));
        /* 自检:往 UI 线程上扔一个异常,验兜网。
           ★ 这个钩子是**必须留着**的:兜网本身没有任何外在表现 ——
             它没生效的唯一症状是「某天某个页面把进程打死了」,
             而那一天不会有人想起来是这里坏的。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_BOOM") == "1")
            _ = Task.Delay(2500).ContinueWith(_ => Dispatcher.UIThread.Post(
                () => throw new InvalidOperationException("自检:故意扔的异常")));
        if (string.IsNullOrEmpty(want) || _core is null) return;
        var arg = want.Contains(':') ? want[(want.IndexOf(':') + 1)..] : "";
        var srv = Nav.Session?.server ?? "";
        switch (want.Split(':')[0])
        {
            case "library": this.FindControl<RadioButton>("NavLibrary")!.IsChecked = true; break;
            case "search":
                this.FindControl<RadioButton>("NavSearch")!.IsChecked = true;
                // search:某 → 填词并让它自己搜一遍。空态和结果态是**两张不同的页**,
                // 只截空态等于结果那半从来没被看过。
                if (arg.Length > 0 && Nav.Current is SearchPage sp2) sp2.SelfCheckQuery(arg);
                break;
            case "favorites": this.FindControl<RadioButton>("NavFavorites")!.IsChecked = true; break;
            case "settings": this.FindControl<RadioButton>("NavSettings")!.IsChecked = true; break;
            case "aggregate": this.FindControl<RadioButton>("NavAggregate")!.IsChecked = true; break;
            case "history": this.FindControl<RadioButton>("NavHistory")!.IsChecked = true; break;
            case "calendar": this.FindControl<RadioButton>("NavCalendar")!.IsChecked = true; break;
            case "download": this.FindControl<RadioButton>("NavDownload")!.IsChecked = true; break;
            case "catalog":
                this.FindControl<RadioButton>("NavCatalog")!.IsChecked = true;
                break;
            /* 自检:挂一个开发目录插件并启用,再落到「已装」。
               ★ 这一条是**不能省的**:市场那两张卡片走的是 registry 解析那条路,
                 而「装上 → 授权 → 启用 → 引擎跑起来 → 贡献点出现」是另一条路,
                 只截市场页的话它一次都没被走过。 */
            case "plugindev":
                this.FindControl<RadioButton>("NavPlugins")!.IsChecked = true;
                if (arg.Length > 0) _ = SelfCheckMountPlugin(arg, null);
                break;
            /* 自检:挂插件 → 把它贡献的源登录进来 → 落到影视目录页。
               这条走的是**最长的一条链**:JS 引擎 → 贡献点 → 源分派表 →
               source.categories/catalog → 影视目录页渲染。 */
            case "plugincatalog":
                if (arg.Length > 0) _ = SelfCheckMountPlugin(arg, "plugin:com.linplayer.selfcheck/vod");
                break;
            case "plugins":
                this.FindControl<RadioButton>("NavPlugins")!.IsChecked = true;
                // 自检用:plugins:1 直接落到「已装」,plugins:2 落到「源订阅」。
                if (arg.Length > 0 && int.TryParse(arg, out var tab) && Nav.Current is PluginPage pp)
                    pp.SelectTab(tab);
                break;
            case "browse":
                this.FindControl<RadioButton>("NavBrowse")!.IsChecked = true;
                // 带参数(browse:空文件夹)时再点进那个子目录 —— 「空目录说空目录」要验得到
                if (arg.Length > 0 && Nav.Current is BrowsePage bp) bp.SelfCheckEnter(arg);
                break;
            case "ranking":
                // ★ 带参数(ranking:movie)时落到指定分组 —— TMDB 那条链和弹弹那条
                //   解析口径不同(id 数字/字符串混、图床要自己拼前缀),要分别验
                this.FindControl<RadioButton>("NavRanking")!.IsChecked = true;
                if (arg.Length > 0 && Nav.Current is RankingPage rp) rp.SelfCheckGroup(arg);
                break;
            case "servers": GoServers(); break;
            /* 自检:右键菜单那条路 —— **只编辑当前这一台**,抽屉直接拉开。
               ★ 和 servers: 是两页不同的版式(有没有全表、有没有「添加」按钮),
                 只截前者的话「定点编辑」这一版从来没被看过。 */
            case "serveredit": GoServers(srv, arg.Length > 0 ? arg : "edit"); break;
            // 自检:批量添加页(带参数时把那段文本填进去并解析)
            case "batch":
                {
                    var batchPage = new BatchAddPage(_core, OnServerSwitched);
                    Nav.Push(batchPage);
                    if (arg.Length > 0) _ = batchPage.LoadDeepLink(arg);
                    break;
                }
            case "icons": Nav.Push(new IconLibraryPage(_core, srv, () => { })); break;
            case "grid": Nav.Push(new LibraryGridPage(_core, srv, arg, "自检库")); break;
            case "detail":
                Nav.Push(new DetailPage(_core, srv, arg));
                /* 自检:选第 N 个版本再按播放。
                   ★ 判据不在界面上,在**服务器实际被请求的那条流**里 ——
                     看 fakeemby 日志里的 mediaSourceId。 */
                if (Environment.GetEnvironmentVariable("LP_SELFCHECK_VERSION") is { Length: > 0 } vn
                    && int.TryParse(vn, out var vi) && Nav.Current is DetailPage dvp)
                    _ = Task.Delay(2000).ContinueWith(_ => dvp.SelfCheckPickVersion(vi - 1));
                break;
            case "person": Nav.Push(new PersonPage(_core, srv, arg, "自检人物")); break;
            // 自检:进详情页 → 点「下载」 → 跳下载页。整条链一次走完
            case "dl":
                Nav.Push(new DetailPage(_core, srv, arg));
                _ = SelfCheckDownload();
                break;
            case "player": Nav.Push(new PlayerPage(_core, arg, "自检片", 0)); break;
        }
    }

    /// <summary>
    /// 自检:LP_SELFCHECK_SCROLL=像素 → 把当前页滚下去再截图。
    ///
    /// ★ 长页(设置十来组)一屏只装得下前两组,**折线以下的控件从来没被看过一眼**。
    ///   「编译过了」和「它在页面上」之间差的就是这一段。
    /// ★ 必须**延后**滚:页面内容是异步拉回来的,刚落页时高度还是 0,当场滚等于没滚。
    /// </summary>
    private void SelfCheckScroll()
    {
        var raw0 = Environment.GetEnvironmentVariable("LP_SELFCHECK_SCROLL");
        // LP_SCROLL=sweep → 连续拨滚轮,独立采样每一帧的位置。见 SelfCheckScrollSweep。
        if (raw0 == "sweep") { SelfCheckScrollSweep(); return; }
        if (raw0 is not { } raw || !double.TryParse(raw, out var y)) return;
        _ = Task.Delay(3000).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var sv = this.GetVisualDescendants().OfType<ScrollViewer>()
                .FirstOrDefault(v => v.Extent.Height > v.Viewport.Height);
            if (sv is not null) sv.Offset = sv.Offset.WithY(y);
        }));
    }

    /// <summary>
    /// 自检:滚动扫描。每 140ms 拨一格滚轮,同时<b>另起一路每帧采样 Offset</b>。
    ///
    /// <para>★★ 这是「滑得顺不顺」唯一的客观判据。
    /// 顺 = 两格滚轮之间有<b>一串中间位置</b>;跳 = 一格一个值,中间什么都没有。
    /// 帧率是满的、也没掉帧,但内容一格一格瞬移 —— 那正是用户说的「卡」。
    /// 光看截图和帧率永远看不出这件事。</para>
    ///
    /// <para>★ 采样是**独立的一路**,不是动画自己汇报的。
    /// 让动画自己打日志的话,它只会证明「我被调用了」。</para>
    /// </summary>
    private void SelfCheckScrollSweep()
    {
        _ = Task.Delay(2500).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var sv = this.GetVisualDescendants().OfType<ScrollViewer>()
                .FirstOrDefault(v => v.Extent.Height > v.Viewport.Height + 1);
            if (sv is null) { Console.WriteLine("[滚动扫描] 没找到能滚的 ScrollViewer"); return; }

            var samples = new List<double>();
            void Sample(TimeSpan _)
            {
                samples.Add(Math.Round(sv.Offset.Y, 1));
                if (samples.Count < 220 && TopLevel.GetTopLevel(sv) is { } t) t.RequestAnimationFrame(Sample);
                else Report();
            }
            var reported = false;
            void Report()
            {
                if (reported) return;
                reported = true;
                var distinct = samples.Distinct().Count();
                // 相邻两帧的位移:越均匀越顺。一格一跳的话这里全是 0 和一个大数
                var steps = samples.Zip(samples.Skip(1), (a, b) => Math.Abs(b - a)).Where(v => v > 0.05).ToList();
                Console.WriteLine($"[滚动扫描] 采样 {samples.Count} 帧,出现 {distinct} 个不同位置," +
                                  $"移动帧 {steps.Count},每帧位移 中位 {Med(steps):0.0}px 最大 {(steps.Count > 0 ? steps.Max() : 0):0.0}px");
                Console.WriteLine($"[滚动扫描] 轨迹 {string.Join(" ", samples.Where((_, i) => i % 2 == 0).Take(60))}");
            }
            static double Med(List<double> v)
            {
                if (v.Count == 0) return 0;
                var s = v.OrderBy(x => x).ToList();
                return s[s.Count / 2];
            }

            TopLevel.GetTopLevel(sv)?.RequestAnimationFrame(Sample);

            // 每 140ms 一格,拨 8 格。间隔要比一次缓动(约 130ms)略长 ——
            // 太密的话几格叠成一次长滑,看不出「一格滚轮长什么样」。
            var n = 0;
            var tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(140) };
            tick.Tick += (_, _) =>
            {
                Wheel(sv, -1);
                if (++n >= 8) tick.Stop();
            };
            tick.Start();
        }));
    }

    /// <summary>
    /// 自检:往一个控件上发一个<b>真的</b>滚轮事件。
    ///
    /// <para>★★ 不能直接调 <c>Smooth</c> 里的方法。那样发出去的这一格<b>绕过了事件路由</b>,
    /// 于是「平滑滚动到底有没有挂上去」「隧道阶段有没有把默认那套拦住」这两件事
    /// 一次都没被验过 —— 而 A/B 对比里关掉开关的那一边照样是平滑的,
    /// 对出来的两组数没有任何意义。我第一版就是这么错的。</para>
    /// </summary>
    private static void Wheel(ScrollViewer sv, double deltaY)
    {
        /* ★★ 必须发给 <b>ScrollContentPresenter</b>,不是 ScrollViewer 自己。
           Avalonia 的滚轮处理挂在 presenter 上,而路由事件是从 Source 往上冒的 ——
           把 Source 设成 ScrollViewer,presenter 在它下面,**永远收不到**。
           表现是「发了 8 格滚轮,位置一动不动」,而且不报任何错。 */
        Control target = sv.GetVisualDescendants().OfType<ScrollContentPresenter>().FirstOrDefault() is { } pr ? pr : sv;
        var pos = new Point(target.Bounds.Width / 2, target.Bounds.Height / 2);
        var args = new PointerWheelEventArgs(
            target, new Pointer(0, PointerType.Mouse, true), target, pos,
            (ulong)Environment.TickCount64,
            new PointerPointProperties(RawInputModifiers.None, PointerUpdateKind.Other),
            KeyModifiers.None, new Vector(0, deltaY))
        { RoutedEvent = InputElement.PointerWheelChangedEvent };
        target.RaiseEvent(args);
    }

    /// <summary>
    /// 自检:在第一张卡上真的发一次右键。
    ///
    /// <para>★★ 右键菜单改成<b>用时才建</b>之后,「菜单还出不出得来」这件事
    /// 截图是验不到的 —— 截图点不了右键。而它坏掉的样子恰恰是「点了没反应」,
    /// 不报错、不崩、编译全绿。本仓的老规矩:一个功能几套入口就得每套点一遍,
    /// 点不了的那套就得让程序自己点。</para>
    /// </summary>
    private void SelfCheckMenu()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_MENU") != "1") return;
        _ = Task.Delay(2500).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var card = this.GetVisualDescendants().OfType<Card>().FirstOrDefault();
            if (card is null) { Console.WriteLine("[右键自检] 页面上一张卡都没有"); return; }
            card.RaiseEvent(new ContextRequestedEventArgs { RoutedEvent = Control.ContextRequestedEvent });
            Dispatcher.UIThread.Post(() =>
                Console.WriteLine(card.ContextMenu is { } m
                    ? $"[右键自检] 菜单建出来了,{m.ItemCount} 项,打开={m.IsOpen}"
                    : "[右键自检] ✗ 右键之后仍然没有菜单"),
                DispatcherPriority.Background);
        }));
    }

    /// <summary>
    /// 自检:把首页 Hero 翻到第 N 张。
    ///
    /// <para>★★ 「轮播到底动没动」<b>截图判不出来</b> —— 一张静止的大图和一个
    /// 停住的轮播长得一模一样,而轮播停住恰恰是最容易发生的失败
    /// (循环挂在异常上、协程被取消、Attached 没再启动)。
    /// 所以这里让它<b>报出自己停在第几张、叫什么</b>,由日志对账。</para>
    /// </summary>
    private void SelfCheckHero()
    {
        var raw = Environment.GetEnvironmentVariable("LP_SELFCHECK_HERO");
        if (string.IsNullOrEmpty(raw) || !int.TryParse(raw, out var n)) return;
        // ★ 等随机推荐那条命令回来 —— 立刻问的话它手里一张都还没有
        _ = Task.Delay(2600).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            if (Nav.Current is HomePage hp) hp.SelfCheckHero(n);
            else Console.WriteLine("[Hero 自检] 当前不是首页");
        }));
    }

    /// <summary>
    /// 自检:数一数<b>真的被实例化出来</b>的卡片有几张。
    ///
    /// <para>★★ 「加了虚拟化」这句话本身是验不了的 —— 代码写上了、编译过了、
    /// 页面看着也对,但只要 <c>ItemsPanel</c> 那一行没生效,它就退化成全量实例化,
    /// <b>而且外观一模一样</b>。唯一的判据是数视觉树里的 <see cref="Card"/>:
    /// 服务端给了 140 条,屏幕上放得下十几张 —— 数出来接近 140 就是没虚拟化。</para>
    /// </summary>
    private void SelfCheckCount()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_COUNT") != "1") return;
        _ = Task.Delay(4000).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
            Console.WriteLine($"[卡片计数] 视觉树里实例化了 {this.GetVisualDescendants().OfType<Card>().Count()} 张卡")));
    }

    /// <summary>
    /// 自检:<b>用到的每一个 MDL2 字形是不是真的存在</b>。
    ///
    /// <para>★★ 码位写错的表现是一个<b>空心方框</b>(.notdef) —— 而它编译绿、
    /// 运行不报错、日志一个字都没有,只有真渲染 + 真看一眼才发现得了。
    /// 而截图里一排图标中间夹一个方框,人眼很容易当成「这个图标就长这样」。
    /// 所以这里直接问字体:<c>TryGetGlyph</c> 回 false 或者拿到 0 就是没有。</para>
    /// </summary>
    private static void SelfCheckGlyphs()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_GLYPH") != "1") return;
        var face = new Typeface("Segoe MDL2 Assets");
        if (!FontManager.Current.TryGetGlyphTypeface(face, out var gt))
        {
            Console.WriteLine("[字形自检] ✗ 系统里没有 Segoe MDL2 Assets 这个字体");
            return;
        }
        var all = AllGlyphs();
        var bad = 0;
        foreach (var (name, glyph) in all)
        {
            var cp = (uint)char.ConvertToUtf32(glyph, 0);
            var ok = gt.TryGetGlyph(cp, out var g) && g != 0;
            if (!ok) { bad++; Console.WriteLine($"[字形自检] ✗ {name} U+{cp:X4} 字体里没有 —— 会画成方框"); }
        }
        Console.WriteLine(bad == 0
            ? $"[字形自检] ✓ {all.Count} 个字形全都在"
            : $"[字形自检] ✗ {bad} / {all.Count} 个字形缺失");
    }

    /// <summary>全站用到的 MDL2 字形。加了新图标要往这里加一行,不然它查不到。</summary>
    private static List<(string Name, string Glyph)> AllGlyphs()
    {
        var outp = new List<(string, string)>
        {
            ("标题栏 最小化", ""), ("标题栏 最大化", ""), ("标题栏 关闭", ""),
            ("侧栏 服务器", ""), ("侧栏 收起", ""), ("侧栏 展开", ""),
            ("侧栏 首页", ""), ("侧栏 文件浏览", ""), ("侧栏 影视目录", ""),
            ("侧栏 媒体库", ""), ("侧栏 搜索", ""), ("侧栏 收藏", ""),
            ("侧栏 聚合视界", ""), ("侧栏 观看历史", ""), ("侧栏 下载", ""),
            ("侧栏 排行榜", ""), ("侧栏 追剧日历", ""), ("侧栏 插件", ""),
            ("侧栏 设置", ""),
            // 服务器右键菜单 / 侧栏服务器行(2026-09-03 新增)。
            // ★ 加了新图标**必须**往这里加一行 —— 字体里没有那个码位时
            //   Windows 画的是一个空心方框,而它编译绿、运行不报错。
            ("菜单 添加服务器", "\uE710"),
            ("菜单 编辑信息", "\uE70F"),
            ("菜单 编辑线路", "\uE774"),
            ("菜单 编辑图标", "\uE91B"),
            ("菜单 重新登录", "\uE72C"),
            ("菜单 测线路", "\uE9D9"),
        };
        foreach (var (n, g) in PlayerPage.Ico.All) outp.Add(("播放页 " + n, g));
        return outp;
    }

    /// <summary>
    /// 自检:网格<b>右边到底还剩多少空</b>。
    ///
    /// <para>★★ 这一条是被用户点名<b>两轮</b>逼出来的。第一轮我去掉了
    /// <c>MaxWidth=1560</c> 那道封顶,以为就是它;第二轮用户说「右边还是有留空」——
    /// 真因是卡片宽度**写死 158**,而 (可用宽 + 间距) 除不尽 (卡宽 + 间距),
    /// <b>余数必然留在右边</b>。这是一道算术题,不是审美题。</para>
    ///
    /// <para>★★ 判据必须量<b>真卡片的右沿</b>,不能拿 <c>_cardWidth × 列数</c> 去算 ——
    /// 那只证明我算对了,证明不了 <see cref="Card"/> 真的按这个宽度画出来了。
    /// (本仓「算得对但画得不对」栽过:ImageBrush 尺寸全对、屏幕上一片空。)</para>
    /// </summary>
    private void SelfCheckFill()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_FILL") != "1") return;
        _ = Task.Delay(3500).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var grid = this.GetVisualDescendants().OfType<MediaGrid>().FirstOrDefault();
            if (grid is null) { Console.WriteLine("[网格铺满] ✗ 这一页上没有 MediaGrid"); return; }
            var cards = grid.GetVisualDescendants().OfType<Card>().ToList();
            if (cards.Count == 0) { Console.WriteLine("[网格铺满] ✗ 一张卡都没画出来"); return; }

            var w = grid.Bounds.Width;
            double right = 0, left = w;
            foreach (var c in cards)
            {
                var p0 = c.TranslatePoint(default, grid);
                if (p0 is null) continue;
                left = Math.Min(left, p0.Value.X);
                right = Math.Max(right, p0.Value.X + c.Bounds.Width);
            }
            var gap = w - right;
            Console.WriteLine($"[网格铺满] 容器宽 {w:0}  卡片 {cards.Count} 张  " +
                              $"最左 {left:0}  最右 {right:0}  右边剩 {gap:0.0}px");
            // ★ 2px 是取整的余量(列宽用了 Math.Floor)。再多就是真的没铺满。
            Console.WriteLine(gap <= 2.5 && left <= 0.5
                ? "[网格铺满] ✓ 卡片铺到了容器右沿 —— 没有留白"
                : $"[网格铺满] ✗ 右边空着 {gap:0.0}px(左边 {left:0.0}px)—— 那是除不尽的余数,不是设计");
        }));
    }

    /// <summary>
    /// 自检:侧栏收放的<b>动效</b>和折叠态的<b>图标对齐</b>。
    ///
    /// <para>★★ 「有没有动效」<b>截图判不出来</b> —— 收起前和收起后各一张,
    /// 中间是瞬移还是插值完全看不出。所以这里按帧采样 <c>Sidebar.Width</c>:
    /// 中间读到过 72 和 212 <b>以外</b>的值 = 真的在插值。
    /// 这正是上一版漏掉这条需求的方式:代码里写着「宽度用 GridLength 直接改,不做动画」,
    /// 而 GridLength 压根<b>没有动画器</b>,想加也加不上 —— 得先把宽度挪到
    /// <c>Border.Width</c> 上(见 <see cref="ToggleSidebar"/>)。</para>
    ///
    /// <para>★★ 对齐那一条量的是<b>屏幕坐标</b>:折叠键的图标中心和导航项图标中心
    /// 必须落在同一条竖线上。用户 2026-09-03 原话「收起/展开没有和其他图标一样居中」。
    /// 只看 <c>HorizontalContentAlignment</c> 是查不出来的 ——
    /// 那一版它已经是 Center 了,偏出去的是 Padding 和图标宽度。</para>
    /// </summary>
    private void SelfCheckSidebar()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_SIDEBAR") != "1") return;
        _ = Task.Delay(2200).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var bar = this.FindControl<Border>("Sidebar")!;
            var seen = new List<double>();
            var n = 0;
            ToggleSidebar();
            void Sample(TimeSpan _)
            {
                seen.Add(Math.Round(bar.Width, 1));
                if (++n < 26) TopLevel.GetTopLevel(bar)!.RequestAnimationFrame(Sample);
                else Report();
            }
            void Report()
            {
                var mid = seen.Where(v => v is > 73 and < 211).ToList();
                Console.WriteLine($"[侧栏动效] 采到的宽度 {string.Join(" ", seen.Distinct())}");
                Console.WriteLine(mid.Count > 0
                    ? $"[侧栏动效] ✓ 中间经过了 {mid.Count} 个插值宽度 —— 是在动,不是瞬移"
                    : "[侧栏动效] ✗ 只有 212 和 72 两个值 —— 宽度是瞬间跳过去的,没有动效");
                Align();
            }
            void Align()
            {
                var icon = this.FindControl<TextBlock>("CollapseIcon")!;
                var navIcon = this.FindControl<RadioButton>("NavHome")!
                    .GetVisualDescendants().OfType<TextBlock>().FirstOrDefault(t => t.Name == "icon");
                if (navIcon is null) { Console.WriteLine("[折叠图标] ✗ 找不到导航项的图标"); return; }
                double? Mid(Visual v) =>
                    v.TranslatePoint(new Point(v.Bounds.Width / 2, 0), bar)?.X;
                var a = Mid(icon); var b = Mid(navIcon);
                if (a is null || b is null) { Console.WriteLine("[折叠图标] ✗ 量不到坐标"); return; }
                Console.WriteLine($"[折叠图标] 折叠键中心 {a:0.0}  导航图标中心 {b:0.0}  侧栏宽 {bar.Width:0}");
                Console.WriteLine(Math.Abs(a.Value - b.Value) < 1.5
                    ? "[折叠图标] ✓ 和上面那一列落在同一条竖线上"
                    : $"[折叠图标] ✗ 偏了 {Math.Abs(a.Value - b.Value):0.0}px —— 折叠态下它没和别的图标居中对齐");
            }
            TopLevel.GetTopLevel(bar)!.RequestAnimationFrame(Sample);
        }));
    }

    /// <summary>
    /// 自检:把侧栏里第一台服务器的<b>右键菜单</b>弹出来。
    ///
    /// <para>★★ 这一版把服务器页那四组编辑动作全搬进了右键菜单 ——
    /// 而<b>收起来的东西在截图里等于不存在</b>:菜单有几项、图标是不是方框、
    /// 文字排没排齐,不弹一次就永远没人看过。上一版「四组抽屉」也是这么补的自检。</para>
    /// </summary>
    private void SelfCheckServerMenu()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_SRVMENU") != "1") return;
        _ = Task.Delay(2600).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var list = this.FindControl<StackPanel>("ServerList")!;
            // 第 0 个是「添加服务器」,第 1 个才是第一台服务器
            var row = list.Children.OfType<Button>().Skip(1).FirstOrDefault();
            if (row?.ContextMenu is null)
            {
                Console.WriteLine("[服务器菜单] ✗ 侧栏里没有服务器行,或者那一行没挂右键菜单");
                return;
            }
            /* ★★ 弹之前要把置顶摘掉。
               自检模式下主窗是 Topmost(防止截到别的程序),而 Avalonia 在 Windows 上
               把右键菜单画在**另一个顶层窗口**里 —— 那个窗口不是 Topmost,
               于是它被主窗压在下面,**截图里什么都没有而日志报「已弹出」**。
               这一条本身就是个「自检说绿、屏幕上没有」的典型:
               第一次跑就是这么白拍了一张。 */
            Topmost = false;
            /* ★★ 还得把摆放方式从「跟着指针」改成「贴着这一行」。
               ContextMenu 默认 Placement=Pointer —— 自检里<b>鼠标在哪儿是不确定的</b>
               (多半根本不在窗口上),于是菜单弹在屏幕的某个角落,
               截窗口那块区域自然什么都截不到,而日志照样报「已弹出」。
               ★ 这是**自检专用**的改动:真用户是右键点出来的,指针位置天然就是对的。 */
            row.ContextMenu.Placement = PlacementMode.RightEdgeAlignedTop;
            row.ContextMenu.Open(row);
            Console.WriteLine($"[服务器菜单] ✓ 已弹出,{row.ContextMenu.Items.Count} 项");
        }));
    }

    /// <summary>侧栏收起来了没有。</summary>
    private bool _collapsed;

    /// <summary>当前该多宽。折叠 72(Tokens 里的 SidebarCollapsedWidth),展开 212。</summary>
    private double SidebarWidth => _collapsed ? 72 : 212;

    /// <summary>
    /// 收起 / 展开侧栏。
    ///
    /// <para>★ 折叠态<b>只留图标</b>,不是把整条藏掉 —— 藏掉的话导航就没了,
    /// 用户得先展开才能换页,那不叫折叠,那叫隐藏。</para>
    ///
    /// <para>★★ 宽度写在 <c>Sidebar.Width</c> 上而<b>不是列宽</b>(列宽已改成 Auto)——
    /// <c>GridLength</c> 没有动画器,挂 Transition 无声不生效。
    /// 用户 2026-09-03:「侧边栏收起/展开没有动效」。</para>
    ///
    /// <para>★★ 折叠态下这个按钮的图标要和上面那一列<b>落在同一条竖线上</b>
    /// (用户同一轮点名)。导航项靠 <c>.icononly</c> 把图标撑成 56 宽 + Padding 0,
    /// 而这一个是 <see cref="Button"/>,那条选择器是 <c>RadioButton.nav.icononly</c>,
    /// <b>选不中它</b> —— 所以这里手动同步同一组数。
    /// 一开始只改了 <c>HorizontalContentAlignment</c>,那治不了:
    /// 外面还有 10px 的 Padding 和 18px 的图标宽,居中的是「图标+空文字」这一整块。</para>
    /// </summary>
    private void ToggleSidebar()
    {
        _collapsed = !_collapsed;
        this.FindControl<Border>("Sidebar")!.Width = SidebarWidth;
        foreach (var rb in this.GetVisualDescendants().OfType<RadioButton>())
            if (rb.Classes.Contains("nav")) rb.Classes.Set("icononly", _collapsed);
        SyncCollapsed();
    }

    /// <summary>
    /// 把「折叠态」这件事同步到那几个不吃 <c>.icononly</c> 的控件上。
    /// <para>★ 单独抽出来是因为**服务器行是运行期建的** —— 建完之后
    /// 还得再按当前折叠态收一次,不然收着侧栏切服务器,新建的行是展开版式。</para>
    /// </summary>
    private void SyncCollapsed()
    {
        var icon = this.FindControl<TextBlock>("CollapseIcon")!;
        var box = this.FindControl<StackPanel>("CollapseBox")!;
        var btn = this.FindControl<Button>("BtnCollapse")!;
        this.FindControl<TextBlock>("CollapseText")!.IsVisible = !_collapsed;
        // ★ 56 / Padding 0 —— 和 RadioButton.nav.icononly 那条样式里的数**必须一样**,
        //   差一个像素这一个图标就比上面那一列偏出去
        icon.Width = _collapsed ? 56 : 18;
        box.Spacing = _collapsed ? 0 : 10;
        btn.Padding = new Thickness(_collapsed ? 0 : 10, 0);
        icon.Text = _collapsed ? "" : "";   // › / ‹
        ToolTip.SetTip(btn, _collapsed ? "展开侧栏" : "收起侧栏");

        // 服务器区:标题和每行的名字在折叠态下收掉,只留图标
        this.FindControl<TextBlock>("ServerSectionTitle")!.IsVisible = !_collapsed;
        foreach (var row in this.FindControl<StackPanel>("ServerList")!.Children.OfType<Button>())
            if (row.Content is StackPanel sp)
            {
                sp.Spacing = _collapsed ? 0 : 10;
                row.Padding = new Thickness(_collapsed ? 0 : 10, 0);
                foreach (var c in sp.Children)
                {
                    if (c is TextBlock t && (string?)t.Tag == "name") t.IsVisible = !_collapsed;
                    else c.Width = _collapsed ? 56 : 18;
                }
            }
    }

    /// <summary>
    /// 自检:侧栏高亮退场<b>会不会闪一下</b>。
    ///
    /// <para>★★ 这个 bug 截图判不出来 —— 它只活在过渡的中间几帧。
    /// 根因:原来的写法给 <c>Border#root</c> 的 Background 挂 BrushTransition,
    /// 从 PanelAlt 插到 <c>Transparent</c>,而这条插值路径<b>中途会经过又亮又透的颜色</b>——
    /// 实测合成亮度 35(悬停)→ <b>114</b>(中途)→ 26(静止),中途比两端亮三倍多。
    /// 那就是用户说的「滑到下一个的时候上一个会闪亮一下」。</para>
    ///
    /// <para>★★ 判据<b>不是</b>「我自己算一遍合成亮度」—— 那一版实测<b>假绿</b>:
    /// 注入旧写法之后它照样报 ✓,因为我算的合成和渲染器算的对不上。
    /// 现在直接断言<b>机制</b>:退场时只许 Opacity 在动,
    /// <c>root</c> 的底色<b>一动就是老写法</b>(而只要它在动,就一定会经过那个暗谷)。
    /// 这条断言无法被「算错」,而且注入旧样式当场变红。</para>
    /// </summary>
    private void SelfCheckNavHover()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_NAVHOVER") != "1") return;
        _ = Task.Delay(2000).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var rb = this.FindControl<RadioButton>("NavLibrary")!;
            var borders = rb.GetVisualDescendants().OfType<Border>().ToList();
            var root = borders.FirstOrDefault(b => b.Name == "root");
            var hov = borders.FirstOrDefault(b => b.Name == "hov");
            if (root is null)
            {
                Console.WriteLine("[侧栏高亮] ✗ 模板里没有 Border#root,选择器八成写错了");
                return;
            }

            static string Bg(Border? b) =>
                (b?.Background as ISolidColorBrush)?.Color.ToString() ?? "无";

            ((Avalonia.Controls.IPseudoClasses)rb.Classes).Set(":pointerover", true);
            var rootBg = new List<string>();
            var hovOp = new List<double>();
            var n = 0;
            void Sample(TimeSpan _)
            {
                rootBg.Add(Bg(root));
                hovOp.Add(Math.Round(hov?.Opacity ?? -1, 2));
                if (++n == 10) ((Avalonia.Controls.IPseudoClasses)rb.Classes).Set(":pointerover", false);
                if (n < 30) TopLevel.GetTopLevel(rb)!.RequestAnimationFrame(Sample);
                else Report();
            }
            void Report()
            {
                var outBg = rootBg.Skip(10).ToList();     // 退场那一段
                var outOp = hovOp.Skip(10).ToList();
                var bgMoved = outBg.Distinct().Count() > 1;
                var opMoved = outOp.Distinct().Count() > 1;
                Console.WriteLine($"[侧栏高亮] 退场 root 底色 {string.Join(" ", outBg.Distinct())}");
                Console.WriteLine($"[侧栏高亮] 退场 hov 透明度 {string.Join(" ", outOp)}");
                if (bgMoved)
                    Console.WriteLine("[侧栏高亮] ✗ root 的底色在动 —— 那是插值到 Transparent 那条路,中途会比两端都暗(闪一下)");
                else if (!opMoved)
                    Console.WriteLine("[侧栏高亮] ✗ 退场时什么都没动 —— 悬停态压根没生效");
                else
                    Console.WriteLine("[侧栏高亮] ✓ 只有 Opacity 在动,底色纹丝不动 —— 预乘合成,不可能有暗谷");
            }
            TopLevel.GetTopLevel(rb)!.RequestAnimationFrame(Sample);
        }));
    }

    /// <summary>全屏/退出全屏。行高列宽一起归零,否则画面会被挤在偏右下的框里。</summary>
    private void SetImmersive(bool on)
    {
        var root = this.FindControl<Grid>("RootGrid")!;
        var body = this.FindControl<Grid>("BodyGrid")!;
        root.RowDefinitions[0].Height = on ? new GridLength(0) : new GridLength(36);
        // ★ 退全屏要回到**当前的**侧栏宽度,不是写死的 212 ——
        //   否则收着侧栏去看片,回来侧栏自己展开了。
        // ★ 列宽现在是 Auto,宽度在 Sidebar 自己身上(为了能做收放动效)
        _ = body;
        this.FindControl<Border>("Sidebar")!.Width = on ? 0 : SidebarWidth;
        this.FindControl<Grid>("TitleBar")!.IsVisible = !on;
        this.FindControl<Border>("Sidebar")!.IsVisible = !on;
        WindowState = on ? WindowState.FullScreen : WindowState.Normal;
    }

    /// <summary>
    /// 打开服务器编辑器。
    ///
    /// <para>★★ 2026-09-03 之后它<b>不再是一个导航目的地</b> —— 侧栏里已经能直接
    /// 切服务器,而编辑动作全在右键菜单上。这个方法只剩两个调用者:
    /// 右键菜单(带 <paramref name="focus"/> / <paramref name="drawer"/> 定点打开)
    /// 和自检台。用户原话:「这样就省略了服务器页和添加服务器页了」。</para>
    ///
    /// <para>★ 顺手把侧栏的选中态摘掉 —— 不摘的话界面在说「你在首页」,
    /// 而实际在编辑器上,用户会以为点了没反应。</para>
    /// </summary>
    private void GoServers(string? focus = null, string? drawer = null)
    {
        if (_core is null) return;
        foreach (var n in new[] { "NavHome", "NavLibrary", "NavSearch", "NavFavorites",
                                  "NavAggregate", "NavHistory", "NavSettings" })
            this.FindControl<RadioButton>(n)!.IsChecked = false;
        Nav.Root(new ServersPage(_core, OnServerSwitched, focus, drawer));
    }

    /// <summary>添加服务器。★ 侧栏「＋ 添加服务器」和首登闸口走的是同一页。</summary>
    private void GoAddServer()
    {
        if (_core is null) return;
        Nav.Push(new AddServerPage(_core, () => { OnServerSwitched(); Nav.Back(); }));
    }

    /// <summary>需要 Emby 会话的页面。没会话就落到防崩页,别让它自己去解引用 null。</summary>
    private void Emby(string name, Func<Control> make) =>
        Nav.Root(Nav.Session is null ? new NoSessionPage(name) : make());

    private void Show(Control page)
    {
        if (Perf.On) Perf.Log($"换页 → {page.GetType().Name}");
        this.FindControl<ContentControl>("PageHost")!.Content = page;
    }

    /// <summary>首页。点卡片进详情 —— 库卡进网格,条目卡进详情(判断在 OpenDetail 一处)。</summary>
    private Control Home() =>
        new HomePage(_core, Nav.Session is null ? null
            : LibraryPage.OpenDetail(_core!, Nav.Session.server),
            _sourceName == "" ? "首页" : _sourceName);

    /// <summary>
    /// 启动流程:核心层没起来就如实说;没有账号就进首登闸口;有账号就进首页。
    /// </summary>
    private async Task BootAsync()
    {
        if (_core is null)
        {
            Show(new FatalPage(Program.CoreError ?? "核心层没起来,原因未知"));
            return;
        }

        try
        {
            var accounts = await _core.AccountListAccounts();
            /* ★ 判「要不要进登录页」看的是**账号表是否为空**,不是 emby.currentSession ——
               只判后者的话网盘用户永远进不了门(他有账号,只是不是 Emby 的)。
               这条在 Rust 版害过一次。 */
            if (accounts.ValueKind != JsonValueKind.Array || accounts.GetArrayLength() == 0)
            {
                /* ★★ 首登时把导航整条藏掉。
                   之前是亮着的 —— 还没有服务器,「首页 / 媒体库 / 搜索」全能点,
                   点进去清一色「请先登录服务器」。**摆一堆必定失败的入口**
                   和摆一个必定失败的按钮是同一个毛病(详情页的外部播放器那条已经这么处理了)。
                   ★ 设置留着:代理配错了连不上服务器,那是首登时真的要改的东西。 */
                this.FindControl<StackPanel>("NavList")!.IsVisible = false;
                // ★ 服务器区也要一起藏:一台都没有的时候它只剩一条分隔线和「服务器」两个字,
                //   看着像没加载出来。而这一屏本来就整页都是「添加服务器」。
                this.FindControl<StackPanel>("ServerSection")!.IsVisible = false;
                Show(new AddServerPage(_core, OnLoggedIn));
                return;
            }
            UpdateServerChip(accounts);
            // ★ 会话拉一次存住:命令层迁移期还要显式传 server/token/user_id,
            //   每页各拉一次就是每页多一次往返。
            try { Nav.Session = Sess.From(await _core.EmbyCurrentSession()); } catch { /* 非 Emby 账号没有会话 */ }
            Nav.Root(Home());
            SelfCheckJump();
            await StartupDeepLinkAsync();
        }
        catch (Exception e)
        {
            Show(new FatalPage($"读账号表失败:{e.Message}"));
        }
    }

    /// <summary>
    /// 冷启动时点了一条 <c>linplayer://</c> 链接:落到批量添加页让用户核对。
    ///
    /// <para>★★ **绝不直接添加**。链接可能来自任何网页或聊天窗口 ——
    /// 核心层解得开只表示格式对,不表示这台服务器是用户想加的。
    /// 必须让他看清地址和用户名再点。</para>
    /// </summary>
    private async Task StartupDeepLinkAsync()
    {
        if (_core is null) return;
        try
        {
            var r = await _core.AccountStartupDeepLink(new { });
            if (r.ValueKind != JsonValueKind.String) return;
            var page = new BatchAddPage(_core, () => { OnServerSwitched(); Nav.Back(); });
            Nav.Push(page);
            await page.LoadDeepLink(r.GetString() ?? "");
        }
        catch { /* 没有深链是常态,不是错误 */ }
    }

    /// <summary>
    /// 切了服务器 / 改了账号之后:会话和侧栏都要重来。
    ///
    /// <para>★ 只刷侧栏不刷会话的话,整个应用还在拿旧 token 打新服务器 ——
    /// 表现是切完之后每一页都 401,而侧栏显示的是新服务器的名字。</para>
    /// </summary>
    private async void OnServerSwitched()
    {
        try
        {
            UpdateServerChip(await _core!.AccountListAccounts());
            Nav.Session = Sess.From(await _core.EmbyCurrentSession());
        }
        catch { /* 非 Emby 账号没有会话 */ }
    }

    private async void OnLoggedIn()
    {
        try
        {
            UpdateServerChip(await _core!.AccountListAccounts());
        }
        catch { /* 服务器名没刷新不影响用 */ }
        try { Nav.Session = Sess.From(await _core!.EmbyCurrentSession()); } catch { /* 同上 */ }
        this.FindControl<StackPanel>("NavList")!.IsVisible = true;
        this.FindControl<StackPanel>("ServerSection")!.IsVisible = true;
        this.FindControl<RadioButton>("NavHome")!.IsChecked = true;
        Nav.Root(Home());
        // 真机自检:登录成功之后再跳到指定页面(LP_SELFCHECK_PAGE 那会儿装的是 login:...)
        SelfCheckJump(Environment.GetEnvironmentVariable("LP_SELFCHECK_AFTER"));
    }

    /// <summary>当前源的显示名。文件浏览页的面包屑根节点用它。</summary>
    private string _sourceName = "";

    /// <summary>
    /// 刷新侧栏的服务器区 + 按账号类型开关导航入口。
    /// </summary>
    private void UpdateServerChip(JsonElement accounts)
    {
        if (accounts.ValueKind != JsonValueKind.Array) return;
        var rows = accounts.EnumerateArray().ToList();
        var active = rows.FirstOrDefault(a => a.TryGetProperty("active", out var v) && v.GetBoolean());
        if (active.ValueKind != JsonValueKind.Object) active = rows.FirstOrDefault();
        if (active.ValueKind != JsonValueKind.Object) return;

        /* 浏览型源(网盘 / 局域网 / 本地)和 Emby 的可用页面是**两套**。
           ★ 判据是 `source_kind != "emby"`,**线上一律小写**。
             前端曾整套写成首字母大写:每处比较恒 false、登录送错值,而两边都不报错。
           ★ 没有这个键 = 老配置 = Emby(这个键是后加的)。 */
        var kind = active.TryGetProperty("source_kind", out var sk) && sk.ValueKind == JsonValueKind.String
            ? sk.GetString() ?? "emby" : "emby";
        var isBrowse = kind.Length > 0 && kind != "emby";
        _sourceName = active.TryGetProperty("name", out var sn) ? sn.GetString() ?? "" : "";

        Dispatcher.UIThread.Post(() =>
        {
            BuildServerList(rows);

            /* ★★ 按账号类型显隐入口,而不是全都亮着。
               全亮的话:Emby 账号点「文件浏览」拿到「当前没有已登录的文件源」,
               网盘账号点「媒体库」拿到「请先登录服务器」—— 两个都是**专门用来报错的入口**。 */
            // ★ 和功能开关**取与**:这里按账号类型算出来的「该亮」,
            //   碰上 Features 里关着的仍然不亮 —— 否则切个账号就把下线的入口放出来了。
            void Gate(string ctl, string id, bool want) =>
                this.FindControl<RadioButton>(ctl)!.IsVisible = want && Features.On(id);

            Gate("NavBrowse", "nav.browse", isBrowse);
            Gate("NavCatalog", "nav.catalog", isBrowse);
            Gate("NavLibrary", "nav.library", !isBrowse);
            Gate("NavSearch", "nav.search", !isBrowse);
            Gate("NavFavorites", "nav.favorites", !isBrowse);

            // 浏览型源进来时,首页那一套是空的 —— 直接落到文件浏览
            if (isBrowse && Nav.Current is HomePage)
                this.FindControl<RadioButton>("NavBrowse")!.IsChecked = true;
        });
    }

    /// <summary>
    /// 侧栏那一段服务器列表。
    ///
    /// <para>★★ 用户 2026-09-03:「只需要鼠标往左边点点,就可以切换服务器了」——
    /// 所以<b>左键就是切换</b>,不是「打开一个能切换的页面」。
    /// 少一层跳转,这一条才成立。</para>
    ///
    /// <para>★ 「＋ 添加服务器」在列表<b>上面</b>(用户点名的位置)。
    /// 放下面的话服务器越多它越往下跑,而它的位置应当是固定的。</para>
    /// </summary>
    private void BuildServerList(List<JsonElement> rows)
    {
        var list = this.FindControl<StackPanel>("ServerList")!;
        list.Children.Clear();

        var add = NavRow("\uE710", "添加服务器", null);
        add.Click += (_, _) => GoAddServer();
        list.Children.Add(add);

        foreach (var a in rows)
        {
            var server = Str(a, "server");
            var name = Str(a, "name") is { Length: > 0 } n ? n : server;
            var on = a.TryGetProperty("active", out var v) && v.ValueKind == JsonValueKind.True;
            // \uE968 = 一台服务器的通用图标。真图标随后由 account.icon 换上去(见 FillServerIcon)
            var row = NavRow("\uE968", name, on ? "on" : null);
            ToolTip.SetTip(row, on ? $"{name}(使用中) —— 右键有编辑 / 线路 / 图标 / 重新登录"
                                   : $"切到 {name} —— 右键有编辑 / 线路 / 图标 / 重新登录");
            row.Click += async (_, _) =>
            {
                if (on) return;
                try
                {
                    await _core!.AccountSetActiveServer(new { server_id = server });
                    OnServerSwitched();
                    // ★ 切完必须**换页**:留在原来那一页的话,页面上还是上一台服务器的内容,
                    //   而侧栏已经把新的那台标成使用中了 —— 那是界面在撒谎。
                    this.FindControl<RadioButton>("NavHome")!.IsChecked = true;
                    Nav.Root(Home());
                }
                catch (Exception e) { Console.WriteLine("[切服务器] " + e.Message); }
            };
            row.ContextMenu = ServerMenu(server, name);
            list.Children.Add(row);
            _ = FillServerIcon(row, server);
        }
        SyncCollapsed();
    }

    /// <summary>
    /// 右键菜单:把原来服务器页上那四组编辑动作搬过来。
    ///
    /// <para>★ 删除单独列在分隔线下面,并且**它自己再确认一次** ——
    /// 设置页整体是「零二次确认」的,但删账号不可逆,这一条是例外。</para>
    /// </summary>
    private ContextMenu ServerMenu(string server, string name)
    {
        MenuItem Item(string header, string glyph, Action go)
        {
            var mi = new MenuItem
            {
                Header = header,
                Icon = new TextBlock
                {
                    Text = glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 13,
                },
            };
            mi.Click += (_, _) => go();
            return mi;
        }

        var del = new MenuItem { Header = "删除这台服务器" };
        del.Click += async (_, _) =>
        {
            // 第一次点变成「确认删除?」,再点一次才真删
            if ((string?)del.Header != "确认删除?") { del.Header = "确认删除?"; return; }
            try
            {
                await _core!.AccountRemoveAccount(new { server_id = server });
                OnServerSwitched();
            }
            catch (Exception e) { Console.WriteLine("[删服务器] " + e.Message); }
        };

        return new ContextMenu
        {
            ItemsSource = new List<Control>
            {
                new MenuItem { Header = name, IsEnabled = false },
                new Separator(),
                Item("编辑信息", "\uE70F", () => GoServers(server, "edit")),
                Item("编辑线路", "\uE774", () => GoServers(server, "lines")),
                Item("编辑图标", "\uE91B", () => GoServers(server, "icon")),
                Item("重新登录", "\uE72C", () => GoServers(server, "relogin")),
                new Separator(),
                Item("测线路", "\uE9D9", () => GoServers(server, "probe")),
                new Separator(),
                del,
            },
        };
    }

    /// <summary>侧栏里一行(图标 + 文字)。和导航项同一套版式,但它不是单选项。</summary>
    private static Button NavRow(string glyph, string text, string? extraClass)
    {
        var sp = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new TextBlock
                {
                    Text = glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"),
                    FontSize = 14, Width = 18, TextAlignment = TextAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
                new TextBlock
                {
                    // ★ Tag 标成 name:折叠态要按这个把文字收掉(见 SyncCollapsed)
                    Tag = "name", Text = text, FontSize = 13,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };
        var b = new Button
        {
            Classes = { "navbtn" }, Height = 38, Margin = new Thickness(8, 1),
            Padding = new Thickness(10, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(8), Cursor = new Cursor(StandardCursorType.Hand),
            Content = sp,
        };
        if (extraClass is not null) b.Classes.Add(extraClass);
        return b;
    }

    /// <summary>
    /// 换上这台服务器的真图标。
    ///
    /// <para>★★ 用户 2026-09-03:「获取服务器图标,一个是官方 API,一个是从用户头像获取,
    /// 这两个都是 Emby 服常见的服图标获取方式,这样就不需要做一些奇奇怪怪的图标代替了」。
    /// 两条路<b>核心层早就都实现了</b>(<c>account.icon</c>:登录时按用户头像建地址,
    /// 没头像退回 <c>/web/touchicon.png</c>)—— 缺的只是 UI 从来没调过它。
    /// 又一条零调用命令。</para>
    ///
    /// <para>★ 取不到就保持那个 MDL2 通用图标,不报错:没设过头像、
    /// 官方图标 404,都是很常见的情况。</para>
    /// </summary>
    private async Task FillServerIcon(Button row, string server)
    {
        if (_core is null) return;
        string uri;
        try
        {
            var r = await _core.AccountIcon(new { server_id = server });
            uri = Str(r, "data_uri");
        }
        catch { return; }
        if (!uri.StartsWith("data:", StringComparison.Ordinal)) return;
        var at = uri.IndexOf("base64,", StringComparison.Ordinal);
        if (at < 0) return;
        byte[] bytes;
        try { bytes = Convert.FromBase64String(uri[(at + 7)..]); }
        catch { return; }

        Dispatcher.UIThread.Post(() =>
        {
            try
            {
                using var ms = new MemoryStream(bytes);
                var img = new Avalonia.Media.Imaging.Bitmap(ms);
                if (row.Content is not StackPanel sp || sp.Children.Count == 0) return;
                sp.Children[0] = new Border
                {
                    Width = sp.Children[0].Width, Height = 18,
                    CornerRadius = new CornerRadius(4), ClipToBounds = true,
                    VerticalAlignment = VerticalAlignment.Center,
                    Child = new Image
                    {
                        Source = img, Width = 18, Height = 18,
                        Stretch = Avalonia.Media.Stretch.UniformToFill,
                    },
                };
            }
            // 图标解不开不该把整条侧栏拖红(某些服务器返回的是 SVG,Avalonia 解不了)
            catch (Exception e) { Console.WriteLine("[服务器图标] " + e.Message); }
        });
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}
