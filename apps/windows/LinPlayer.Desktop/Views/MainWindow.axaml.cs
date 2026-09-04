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
using Avalonia.LogicalTree;
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

        /* 窗口图标 —— 用户 2026-09-03:「软件没有图标,以前有的,用回以前那个就行」。
           <c>ApplicationIcon</c>(csproj)只管 exe 文件在资源管理器里的样子;
           **任务栏、Alt-Tab、窗口左上角是另一回事**,得在运行期给 Window.Icon 赋值。
           两处都得有,少哪个哪个是空的,而且都不报错。 */
        SetAppIcon();

        var drag = this.FindControl<Border>("DragArea")!;
        // 自绘标题栏必须自己接拖拽与双击最大化 —— 不接的话窗口拖不动,
        // 而用户第一反应是「卡死了」,不会想到是标题栏没实现。
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
        Nav.Fullscreen = SetFullscreen;
        WireNavReclick();

        this.FindControl<Button>("BtnCollapse")!.Click += (_, _) => ToggleSidebar();
        // 需要 Emby 会话的页面统一走 Emby():账号是网盘 / 局域网源时 Nav.Session 是 null,
        // 页面里直接解引用会抛在 Task 里 —— 没提示、不崩、就是永远停在「加载中」。
        this.FindControl<RadioButton>("NavHome")!.Checked += (_, _) => Nav.Root(Home());
        /* 「文件浏览」只在当前账号是**浏览型源**时才出现。
           Emby 账号下亮着它,点进去只会拿到一句「当前没有已登录的文件源」——
           那不是功能,那是一个专门用来报错的入口。 */
        this.FindControl<RadioButton>("NavBrowse")!.Checked += (_, _) =>
            Nav.Root(new BrowsePage(_core!, _sourceName));
        /* 「影视目录」和「文件浏览」是**两页**,不是一页的两种模式。
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
        // 排行榜**不需要** Emby 会话:它打的是弹弹Play / TMDB,和用户的服务器无关。
        // 套 Emby() 的话,网盘用户和没登录的人会被挡在 NoSessionPage 上,
        // 而那页说的是「请先登录服务器」—— 和这一页的实际前提对不上。
        this.FindControl<RadioButton>("NavRanking")!.Checked += (_, _) => Nav.Root(new RankingPage(_core!));
        // 下载页不要求 Emby 会话:列表读的是本地索引,网盘用户也看得到自己的历史任务
        this.FindControl<RadioButton>("NavDownload")!.Checked += (_, _) =>
        {
            var dl = new DownloadPage(_core!);
            Nav.Root(dl);
            dl.SelfCheck();          // LP_DL=1 才做事,平时是一句 return
        };
        // 日历同样不要求 Emby 会话:它打的是 Bangumi / Trakt
        this.FindControl<RadioButton>("NavCalendar")!.Checked += (_, _) => Nav.Root(new CalendarPage(_core!));
        this.FindControl<RadioButton>("NavSettings")!.Checked += (_, _) => Nav.Root(new SettingsPage(_core!));

        /* 基础流程之外的入口在这里统一藏掉。表在 Features.cs —— **只有那一处**。
           散在各页里写 if 的话,过两周没人知道哪些是关着的。

           只藏不拆:接线全留着,自检台还要能跳过去(SelfCheckJump);
             藏起来的 RadioButton 照样能被程序勾中。打磨好一个就从表里删一行。 */
        foreach (var (ctl, id) in NavGates)
            this.FindControl<RadioButton>(ctl)!.IsVisible = Features.On(id);

        /* 自检模式下把窗口置顶。
           截图走的是 CopyFromScreen —— 抓的是**屏幕那块区域**,不是窗口自身内容。
           被别的程序压住时截出来的是压在上面那个窗口,而脚本照样报「成功」。
           2026-08-31 真栽过:截到了另一个程序的界面,差点当成 LinPlayer 的界面来读。
           SetForegroundWindow 在调用方不是前台进程时会被 Windows 拒掉,靠不住;
           由被截的窗口**自己置顶**才是稳的。只在自检时开,不影响产品行为。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK") == "1") Topmost = true;

        /* 兜住渲染里抛出来的异常。
           详情页那次是「一个控件同时挂两处」,它抛在 Dispatcher 回调里,
           **整个进程当场退出**。这类错误一定还会有(每加一段渲染就多一次机会),
           所以要有一个横切的接住点,而不是每页各写一个 try。
           接住之后必须**显示出来**:默默吞掉就成了「不报错、不崩、只是没画出来」,
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

        /* 轻提示的宿主 = 出错横幅那一层(内容区的 Panel),不是某一页。
           挂在页里的话「点了收藏 → 页面刷新 → 提示跟着被销毁」,用户什么都看不到。
           见 Toast.cs 的文件头。 */
        Toast.Host = (Panel)bar.Parent!;
        Shortcuts.Attach(this);

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
    /// <para>截图工具点不了按钮。没有这个钩子的话「除首页以外的每一页」
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
        // 最大化必须单独验一遍:无边框窗口最大化时四周会溢出屏幕 8px,
        // 把自绘标题栏的按钮顶到屏幕外(Rust 版栽过,根治办法是 WM_GETMINMAXINFO 钉 rcWork)。
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_MAXIMIZE") == "1")
            WindowState = WindowState.Maximized;

        /* 滚动要在**早退之前**排。
           LP_SELFCHECK_PAGE 为空(= 落在首页)时这个方法从这里就返回了,
           于是 LP_SCROLL 在首页上**从来没生效过** —— 而首页恰恰是最长的一页,
           折线以下那两条轨道一次都没被看过。
           一个「设了没反应」的自检开关比没有更糟:它会让人以为已经验过了。 */
        SelfCheckScroll();
        SelfCheckMenu();
        SelfCheckToast();
        SelfCheckKeys();
        SelfCheckCount();
        SelfCheckHero();
        SelfCheckNavHover();
        SelfCheckGlyphs();
        SelfCheckFill();
        SelfCheckSidebar();
        SelfCheckServerMenu();
        SelfCheckRail();
        SelfCheckChrome();
        SelfCheckReclick();
        SelfCheckServerIcon();
        /* 自检:把侧栏收起来。
            折叠态是这一版新加的,而它<b>收着的时候才是新形态</b> ——
             不主动收一次,截图永远拍的是展开态,图标有没有对齐、
             服务器卡会不会被裁掉半个字,全没人看过。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_COLLAPSE") == "1")
            _ = Task.Delay(1200).ContinueWith(_ => Dispatcher.UIThread.Post(ToggleSidebar));
        /* 自检:往 UI 线程上扔一个异常,验兜网。
            这个钩子是**必须留着**的:兜网本身没有任何外在表现 ——
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
                这一条是**不能省的**:市场那两张卡片走的是 registry 解析那条路,
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
                // 带参数(ranking:movie)时落到指定分组 —— TMDB 那条链和弹弹那条
                // 解析口径不同(id 数字/字符串混、图床要自己拼前缀),要分别验
                this.FindControl<RadioButton>("NavRanking")!.IsChecked = true;
                if (arg.Length > 0 && Nav.Current is RankingPage rp) rp.SelfCheckGroup(arg);
                break;
            /* 自检:侧栏那条「＋ 添加服务器」。
                要看的是**选中态落在哪一行** —— 用户 2026-09-04 报的正是
                 「点添加服务器,悬浮效果还停在已添加的服务器上」。
                 光看「添加页画出来了没有」是看不出这件事的。 */
            case "addserver": GoAddServer(); break;
            case "servers": GoServers(); break;
            /* 自检:右键菜单那条路 —— **只编辑当前这一台**,抽屉直接拉开。
                和 servers: 是两页不同的版式(有没有全表、有没有「添加」按钮),
                只截前者的话「定点编辑」这一版从来没被看过。 */
            case "serveredit": GoServers(srv, arg.Length > 0 ? arg : "edit"); break;
            // 自检:批量添加页(带参数时把那段文本填进去并解析)
            case "batch":
                {
                    var batchPage = new BatchAddPage(_core, () => _ = OnServerSwitched());
                    Nav.Push(batchPage);
                    if (arg.Length > 0) _ = batchPage.LoadDeepLink(arg);
                    break;
                }
            case "icons": Nav.Push(new IconLibraryPage(_core, srv, () => { })); break;
            case "grid": Nav.Push(new LibraryGridPage(_core, srv, arg, "自检库")); break;
            case "detail":
                Nav.Push(new DetailPage(_core, srv, arg));
                /* 自检:选第 N 个版本再按播放。
                    判据不在界面上,在**服务器实际被请求的那条流**里 ——
                    看 fakeemby 日志里的 mediaSourceId。 */
                if (Environment.GetEnvironmentVariable("LP_SELFCHECK_VERSION") is { Length: > 0 } vn
                    && int.TryParse(vn, out var vi) && Nav.Current is DetailPage dvp)
                    _ = Task.Delay(2000).ContinueWith(_ => dvp.SelfCheckPickVersion(vi - 1));
                /* 自检:<b>把这一页再画一遍</b>(LP_SELFCHECK_REPAINT=1)。
                    对着的是用户 2026-09-04 报的那条崩溃:缓存先行画一遍、
                    真数据回来内容不同再画一遍 —— 而跨渲染留着的控件
                    (媒体信息条、返回键)那会儿还挂在上一版那棵树上。
                    反向注入:把 DetailPage 里任意一处 Loose(...) 去掉,这条当场红。 */
                if (Environment.GetEnvironmentVariable("LP_SELFCHECK_REPAINT") == "1"
                    && Nav.Current is DetailPage drp)
                    _ = Task.Delay(3500).ContinueWith(_ =>
                        Dispatcher.UIThread.Post(drp.SelfCheckRepaint));
                break;
            /* 「详情页停一会儿 → 按播放」。这是**用户真实走的那条路**:
                 预热在详情页发出,本地代理和环形缓存靠它建起来,
                 而进度条缩略图只读那份缓存。直接 push 播放页测不到。 */
            case "play":
                Nav.Push(new DetailPage(_core, srv, arg));
                if (Nav.Current is DetailPage dpp) dpp.SelfCheckPlay(4000);
                break;
            case "person": Nav.Push(new PersonPage(_core, srv, arg, "自检人物")); break;
            // 自检:进详情页 → 点「下载」 → 跳下载页。整条链一次走完
            case "dl":
                Nav.Push(new DetailPage(_core, srv, arg));
                _ = SelfCheckDownload();
                break;
            /* 续播位置从 <c>LP_SELFCHECK_RESUME</c> 来,默认 0。
               这不是可有可无的开关:<b>带 <c>start=</c> 的那条 loadfile 和不带的是两条路</b>,
               而 2026-09-03 那个「继续观看点了就 loadfile 失败」的 bug
               **只在带 start= 的那条上**。一直传 0 的自检永远照不到它。 */
            case "player":
                Nav.Push(new PlayerPage(_core, arg, "自检片",
                    double.TryParse(Environment.GetEnvironmentVariable("LP_SELFCHECK_RESUME"),
                        out var rs) ? rs : 0));
                break;
        }
    }

    /// <summary>
    /// 自检:LP_SELFCHECK_SCROLL=像素 → 把当前页滚下去再截图。
    ///
    /// 长页(设置十来组)一屏只装得下前两组,**折线以下的控件从来没被看过一眼**。
    /// 「编译过了」和「它在页面上」之间差的就是这一段。
    /// 必须**延后**滚:页面内容是异步拉回来的,刚落页时高度还是 0,当场滚等于没滚。
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
    /// 自检:滚动扫描。每 140ms 拨一格滚轮,另起一路每帧采样 Offset。
    ///
    /// <para>这是「滑得顺不顺」唯一的客观判据:顺 = 两格之间有一串中间位置,
    /// 跳 = 一格一个值。帧率是满的、也没掉帧,但内容一格一格瞬移 ——
    /// 光看截图和帧率永远看不出这件事。采样是独立的一路,
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
    /// <para>不能直接调 <c>Smooth</c> 里的方法。那样发出去的这一格<b>绕过了事件路由</b>,
    /// 于是「平滑滚动到底有没有挂上去」「隧道阶段有没有把默认那套拦住」这两件事
    /// 一次都没被验过 —— 而 A/B 对比里关掉开关的那一边照样是平滑的,
    /// 对出来的两组数没有任何意义。我第一版就是这么错的。</para>
    /// </summary>
    private static void Wheel(ScrollViewer sv, double deltaY)
    {
        /* 必须发给 <b>ScrollContentPresenter</b>,不是 ScrollViewer 自己。
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
    /// <para>右键菜单改成<b>用时才建</b>之后,「菜单还出不出得来」这件事
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
            {
                if (card.ContextMenu is not { } m)
                {
                    Console.WriteLine("[右键自检] ✗ 右键之后仍然没有菜单");
                    return;
                }
                Console.WriteLine($"[右键自检] 菜单建出来了,{m.ItemCount} 项,打开={m.IsOpen}");

                /* 用户 2026-09-04:「右键菜单没有动效,没有小图标,看着生硬」。
                    「有没有图标」<b>截图判不出来</b>:菜单是另一个弹出窗口,
                    窗口截图抓不到它。所以只能逐项问控件自己。
                    判据是「**每一条**都有」,不是「有几条有」—— 漏掉的那一条
                    恰恰是最后加的那个,而它和别的排在一起时看着就是少了个图标。 */
                var mi = m.Items.OfType<MenuItem>().ToList();
                var noIcon = mi.Where(x => x.Icon is null).Select(x => x.Header as string).ToList();
                Console.WriteLine(noIcon.Count == 0
                    ? $"[右键自检] ✓ {mi.Count} 条菜单项每条都有小图标"
                    : $"[右键自检] ✗ 这几条没有图标:{string.Join(" / ", noIcon)}");

                /* 动效要<b>逐帧采</b>,不能只问一次。
                   第一版就是只问一次,而且问的时机排在「下一帧升到 1」那个 Post 之后 ——
                   于是一个**正在做动效**的实现被判成红的(假红,和真绿一样害人)。
                   判据和侧栏收放、OSD 渐隐那两条一样:**中间经过了别的值**。
                     只断言终值的话,一刀切也照样绿 —— 那正是改之前的行为。 */
                _ = Task.Run(async () =>
                {
                    var seen = new HashSet<double>();
                    for (var k = 0; k < 20; k++)
                    {
                        await Dispatcher.UIThread.InvokeAsync(() => seen.Add(Math.Round(m.Opacity, 2)));
                        await Task.Delay(16);
                    }
                    var mid = seen.Count(v => v > 0.001 && v < 0.999);
                    Console.WriteLine(mid > 0
                        ? $"[右键自检] ✓ 弹出时 Opacity 经过 {mid} 个中间值({string.Join(" ", seen.OrderBy(v => v))})—— 有入场动效"
                        : $"[右键自检] ✗ Opacity 只有 {string.Join(" ", seen)} —— 没有中间值,菜单是「啪」一下出来的");
                });

                // 字形表:字体里没这个码位时画出来是空心方框,编译绿、运行也不报错
                foreach (var (name, g) in CardActions.G.All)
                    if (g.Length != 1 || g[0] < 0xE000 || g[0] > 0xF8FF)
                        Console.WriteLine($"[右键自检] ✗ 图标「{name}」不是私用区码位:{(int)g[0]:X}");
                Console.WriteLine($"[右键自检] 图标表 {CardActions.G.All.Length} 个,码位都在 MDL2 私用区");
            }, DispatcherPriority.Background);
        }));
    }

    /// <summary>
    /// 自检:轻提示(用户 2026-09-04「所有操作都要有 toast 提示」)。
    ///
    /// <para>判据不能只是「调了 Toast.Show 不抛」—— 那种断言在
    /// <c>Toast.Host</c> 忘了挂的时候照样绿(Show 里第一句就是 <c>if (Host is null) return;</c>,
    /// 静默返回)。要验的是**屏幕上真的多了一块东西**,而且它自己会走。</para>
    /// </summary>
    private void SelfCheckToast()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_TOAST") != "1") return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(2200);
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                Console.WriteLine(Toast.Host is not null
                    ? "[轻提示] ✓ 宿主挂上了"
                    : "[轻提示] ✗ Toast.Host 是 null —— 之后每一次提示都会静默丢掉");
                Toast.Show("已添加到收藏");
                Toast.Error("收藏操作失败");
            });
            await Task.Delay(120);
            var n = 0;
            var op = 0.0;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                n = Toast.LiveCount;
                var cards = this.GetVisualDescendants().OfType<Border>()
                    .Where(b => b.Child is StackPanel sp && sp.Children.Count == 2 &&
                                sp.Children[1] is TextBlock t &&
                                (t.Text == "已添加到收藏" || t.Text == "收藏操作失败")).ToList();
                op = cards.Count > 0 ? cards[0].Opacity : -1;
                Console.WriteLine(cards.Count == 2
                    ? $"[轻提示] ✓ 屏幕上真的多了 2 块(不是只调了个函数);第一块 Opacity={op:0.00}"
                    : $"[轻提示] ✗ 只找到 {cards.Count} 块提示,应当有 2 块");
            });
            Console.WriteLine(n == 2 ? "[轻提示] ✓ 摞着 2 条" : $"[轻提示] ✗ 摞着 {n} 条");
            // 「会自己走」也要验:不走的话它会永远糊在画面上,而刚出来那一刻看着完全正常
            await Task.Delay(3000);
            await Dispatcher.UIThread.InvokeAsync(() => Console.WriteLine(
                Toast.LiveCount == 0
                    ? "[轻提示] ✓ 2.4 秒后自己走了"
                    : $"[轻提示] ✗ 3 秒后还剩 {Toast.LiveCount} 条 —— 它会一直糊在画面上"));
        });
    }

    /// <summary>
    /// 自检:全局快捷键(用户 2026-09-04「其他页面也需要快捷键设置,全局都需要」)。
    ///
    /// <para>判据是**喂进去一次按键、看它有没有被吃掉**,不是「表里有几条」——
    /// 表里写满了而一条都接不到,是这类功能最常见的坏法(挂错了路由阶段、
    /// 挂在了会被换掉的页面上)。</para>
    /// </summary>
    private void SelfCheckKeys()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_KEYS") != "1") return;
        _ = Task.Delay(2600).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            Console.WriteLine($"[快捷键] 全局 {Shortcuts.Count} 条:{string.Join(" / ", Shortcuts.Names)}");

            // ① 真接得到:Ctrl+L 应当跳到媒体库
            var took = Shortcuts.SelfCheckPress(this, Key.L, KeyModifiers.Control);
            var onLib = this.FindControl<RadioButton>("NavLibrary")!.IsChecked == true;
            Console.WriteLine(took && onLib
                ? "[快捷键] ✓ Ctrl+L 接到了,落到媒体库"
                : $"[快捷键] ✗ Ctrl+L 吃掉={took},落到媒体库={onLib}");

            // ② 帮助浮层:? 开,Esc 关
            Shortcuts.SelfCheckPress(this, Key.OemQuestion, KeyModifiers.Shift);
            var opened = Shortcuts.HelpOpen;
            Shortcuts.SelfCheckPress(this, Key.Escape, KeyModifiers.None);
            Console.WriteLine(opened && !Shortcuts.HelpOpen
                ? "[快捷键] ✓ ? 打开快捷键一览,Esc 关掉"
                : $"[快捷键] ✗ ? 打开={opened},Esc 之后还开着={Shortcuts.HelpOpen}");

            /* ③  <b>正在打字时一个都不许接</b>。
               不做这条的话搜索框里按 / 会跳去搜索页而不是打出一个斜杠,
               而用户只会认为「这个输入框坏了」。 */
            var box = new TextBox();
            var host = (Panel)this.FindControl<Border>("ErrorBar")!.Parent!;
            host.Children.Add(box);
            box.Focus();
            Dispatcher.UIThread.Post(() =>
            {
                var stolen = Shortcuts.SelfCheckPress(this, Key.OemQuestion, KeyModifiers.None);
                Console.WriteLine(!stolen
                    ? "[快捷键] ✓ 输入框有焦点时 / 不被抢走"
                    : "[快捷键] ✗ 输入框里按 / 被快捷键抢走了 —— 那个框就没法打斜杠了");
                host.Children.Remove(box);
            }, DispatcherPriority.Background);

            /* ④ 帮助表里的播放页那一栏,必须和 PlayerPage 真正接的键**对得上**。
               抄一份给人看是可以的,抄完不同步就是在骗人。 */
            Console.WriteLine($"[快捷键] 播放页一栏 {Shortcuts.PlayerKeys.Length} 条(行为在 PlayerPage.OnKey)");

            // 最后把那张表**留在屏幕上**,让它进截图 —— 「表里的内容排得对不对」
            // 只有看一眼才知道,日志里那一行字看不出版式。
            Dispatcher.UIThread.Post(() => Shortcuts.SelfCheckPress(this, Key.OemQuestion, KeyModifiers.Shift),
                DispatcherPriority.Background);
        }));
    }

    /// <summary>
    /// 自检:把首页 Hero 翻到第 N 张。
    ///
    /// <para>「轮播到底动没动」<b>截图判不出来</b> —— 一张静止的大图和一个
    /// 停住的轮播长得一模一样,而轮播停住恰恰是最容易发生的失败
    /// (循环挂在异常上、协程被取消、Attached 没再启动)。
    /// 所以这里让它<b>报出自己停在第几张、叫什么</b>,由日志对账。</para>
    /// </summary>
    private void SelfCheckHero()
    {
        var raw = Environment.GetEnvironmentVariable("LP_SELFCHECK_HERO");
        if (string.IsNullOrEmpty(raw) || !int.TryParse(raw, out var n)) return;
        // 等随机推荐那条命令回来 —— 立刻问的话它手里一张都还没有
        _ = Task.Delay(2600).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            if (Nav.Current is HomePage hp) hp.SelfCheckHero(n);
            else Console.WriteLine("[Hero 自检] 当前不是首页");
        }));
    }

    /// <summary>
    /// 自检:数一数<b>真的被实例化出来</b>的卡片有几张。
    ///
    /// <para>「加了虚拟化」这句话本身是验不了的 —— 代码写上了、编译过了、
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
    /// <para>码位写错的表现是一个<b>空心方框</b>(.notdef) —— 而它编译绿、
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
            // 加了新图标**必须**往这里加一行 —— 字体里没有那个码位时
            // Windows 画的是一个空心方框,而它编译绿、运行不报错。
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
    /// 自检:网格右边到底还剩多少空。
    ///
    /// <para>被用户点名两轮逼出来的。第一轮去掉了 <c>MaxWidth=1560</c> 那道封顶,
    /// 第二轮用户说「右边还是有留白」—— 真因是卡片宽度写死 158,
    /// 而 (可用宽 + 间距) 除不尽 (卡宽 + 间距),余数必然留在右边。这是算术题。
    /// 判据要量真卡片的右沿:算得对不等于画得对,本仓在这上面栽过。</para>
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
            // 2px 是取整的余量(列宽用了 Math.Floor)。再多就是真的没铺满。
            Console.WriteLine(gap <= 2.5 && left <= 0.5
                ? "[网格铺满] ✓ 卡片铺到了容器右沿 —— 没有留白"
                : $"[网格铺满] ✗ 右边空着 {gap:0.0}px(左边 {left:0.0}px)—— 那是除不尽的余数,不是设计");
        }));
    }

    /// <summary>
    /// 自检:侧栏收放的动效 + 折叠态的图标对齐。
    ///
    /// <para>「有没有动效」截图判不出来,所以按帧采样 <c>Sidebar.Width</c>:
    /// 中间读到过 72 和 212 以外的值 = 真的在插值。上一版就是这么漏的 ——
    /// 宽度写在 GridLength 上,而它压根没有动画器,得先挪到 <c>Border.Width</c>。
    /// 对齐那条量屏幕坐标:只看 HorizontalContentAlignment 是查不出来的。</para>
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
    /// 自检:分集轨道真的在虚拟化。
    ///
    /// <para>量的不是「排成了一行」—— 那是版式;用户要的是「上千集不卡死」,
    /// 那是造了几个控件,一行一千张卡照样卡死。判据是条目数 vs 真造出来的容器数。
    /// 配 <c>fakeemby -eps 1200</c> 用:12 集的夹具上这条必然绿,
    /// 夹具不真实的假绿本仓栽过。</para>
    /// </summary>
    private void SelfCheckRail()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_RAIL") != "1") return;
        _ = Task.Delay(3600).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var vsp = this.GetVisualDescendants().OfType<VirtualizingStackPanel>()
                .FirstOrDefault(v => v.Orientation == Orientation.Horizontal);
            if (vsp is null)
            {
                Console.WriteLine("[分集轨道] ✗ 一个横向虚拟化面板都没找到 —— 它不在轨道上");
                return;
            }
            // VirtualizingStackPanel 的<b>直接父级是 ItemsPresenter</b>,不是 ItemsControl ——
            // 直接 `Parent as ItemsControl` 恒为 null,量出来是 -1。
            var total = vsp.FindAncestorOfType<ItemsControl>()?.ItemCount ?? -1;
            var made = vsp.Children.Count;
            Console.WriteLine($"[分集轨道] 条目 {total} 条,真造出来的卡 {made} 张");
            if (total < 200)
                Console.WriteLine("[分集轨道] ⚠ 夹具只有这么几条,这条断言证明不了什么 —— 要 fakeemby -eps 1200");
            else if (made > 0 && made < total / 10)
                Console.WriteLine($"[分集轨道] ✓ 只造了 {made}/{total} —— 虚拟化生效,上千集不会卡死");
            else
                Console.WriteLine($"[分集轨道] ✗ 造了 {made}/{total} —— 全量实例化,上千集必卡");
        }));
    }

    /// <summary>
    /// 自检:服务器图标<b>在重建那一帧就在</b>,不会闪回默认图。
    ///
    /// <para>判据是「重建之后<b>同一个 tick</b> 里第一个子元素是不是图片」。
    /// 等一帧再看的话必然绿 —— 而用户看到的那个「闪」正好就是那一帧。
    /// 用户 2026-09-03:「切换服务器的时候服务器图标会闪现回到软件自己的默认图」。</para>
    /// </summary>
    private void SelfCheckServerIcon()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_SRVICON") != "1") return;
        _ = Task.Delay(3000).ContinueWith(async _ =>
        {
            var rows = await _core!.AccountListAccounts();
            Dispatcher.UIThread.Post(() =>
            {
                var list = this.FindControl<StackPanel>("ServerList")!;
                bool HasIcon() => list.Children.OfType<Button>().Skip(1).FirstOrDefault()
                    is { Content: StackPanel sp } && sp.Children.Count > 0 && sp.Children[0] is Border;
                Console.WriteLine($"[服务器图标] 重建之前:图标在位 {HasIcon()}");
                // 就是切服务器时走的那一句 —— 整列重建
                BuildServerList(rows.EnumerateArray().ToList());
                Console.WriteLine(HasIcon()
                    ? "[服务器图标] ✓ 重建后同一帧图标就在 —— 不会闪回默认图"
                    : "[服务器图标] ✗ 重建后这一帧是默认字形 —— 用户会看到闪一下");
            });
        });
    }

    /// <summary>
    /// 自检:侧栏项已经选中时再点一次,要回到这一大类的根。
    /// <para>判据是<b>栈深和当前页</b>,不是「有没有触发处理器」——
    /// 触发了但导航到了同一张详情页,用户感觉不到任何区别。</para>
    /// </summary>
    private void SelfCheckReclick()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_RECLICK") != "1") return;
        _ = Task.Delay(3200).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var home = this.FindControl<RadioButton>("NavHome")!;
            Console.WriteLine($"[侧栏回根] 点之前:栈深 {Nav.Depth} 当前页 {Nav.Current?.GetType().Name} " +
                              $"首页项选中 {home.IsChecked}");
            if (Nav.Depth <= 1) { Console.WriteLine("[侧栏回根] ⚠ 没钻进任何页,这条不算数"); return; }
            if (home.IsChecked != true) { Console.WriteLine("[侧栏回根] ⚠ 首页项没亮着,这条不算数"); return; }
            home.RaiseEvent(new RoutedEventArgs(Button.ClickEvent));
            Dispatcher.UIThread.Post(() =>
            {
                Console.WriteLine($"[侧栏回根] 点之后:栈深 {Nav.Depth} 当前页 {Nav.Current?.GetType().Name}");
                Console.WriteLine(Nav.Depth == 1 && Nav.Current is HomePage
                    ? "[侧栏回根] ✓ 回到了首页"
                    : "[侧栏回根] ✗ 点了没反应 —— 已经选中的侧栏项点不动");
            }, DispatcherPriority.Background);
        }));
    }

    /// <summary>
    /// 自检:播放页把外壳收掉了(用户点名「播放页不应该有侧边栏」)。
    /// <para>判据是<b>侧栏的可见性与宽度</b>,不是「有没有调过那个方法」——
    /// 调了但被别处覆盖回来,是本仓最常见的一类失效。</para>
    /// </summary>
    private void SelfCheckChrome()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_CHROME") != "1") return;
        _ = Task.Delay(4200).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var bar = this.FindControl<Border>("Sidebar")!;
            var tb = this.FindControl<Grid>("TitleBar")!;
            var onPlayer = Nav.Current is PlayerPage;
            Console.WriteLine($"[播放页外壳] 当前页 {Nav.Current?.GetType().Name}  " +
                              $"侧栏可见 {bar.IsVisible} 宽 {bar.Width:0}  标题栏可见 {tb.IsVisible}");
            if (!onPlayer) { Console.WriteLine("[播放页外壳] ⚠ 没落在播放页,这条不算数"); return; }
            Console.WriteLine(!bar.IsVisible && bar.Width <= 0.5 && !tb.IsVisible
                ? "[播放页外壳] ✓ 侧栏和标题栏都收掉了 —— 画面铺满"
                : "[播放页外壳] ✗ 播放页上还留着外壳");
        }));
    }

    /// <summary>
    /// 自检:把侧栏里第一台服务器的<b>右键菜单</b>弹出来。
    ///
    /// <para>这一版把服务器页那四组编辑动作全搬进了右键菜单 ——
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
            /* 弹之前要把置顶摘掉。
               自检模式下主窗是 Topmost(防止截到别的程序),而 Avalonia 在 Windows 上
               把右键菜单画在**另一个顶层窗口**里 —— 那个窗口不是 Topmost,
               于是它被主窗压在下面,**截图里什么都没有而日志报「已弹出」**。
               这一条本身就是个「自检说绿、屏幕上没有」的典型:
               第一次跑就是这么白拍了一张。 */
            Topmost = false;
            /* 还得把摆放方式从「跟着指针」改成「贴着这一行」。
               ContextMenu 默认 Placement=Pointer —— 自检里<b>鼠标在哪儿是不确定的</b>
               (多半根本不在窗口上),于是菜单弹在屏幕的某个角落,
               截窗口那块区域自然什么都截不到,而日志照样报「已弹出」。
               这是**自检专用**的改动:真用户是右键点出来的,指针位置天然就是对的。 */
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
    /// 收起 / 展开侧栏。折叠态只留图标,不是把整条藏掉 ——
    /// 藏掉就得先展开才能换页,那叫隐藏不叫折叠。
    ///
    /// <para>宽度写在 <c>Sidebar.Width</c> 而不是列宽:<c>GridLength</c> 没有动画器,
    /// 挂 Transition 无声不生效。折叠态下这个键的图标要和上面那列落在同一条竖线上,
    /// 而 <c>.icononly</c> 那条选择器是 RadioButton 的、选不中这个 Button,只能手动
    /// 同步同一组数 —— 只改对齐治不了,外面还有 Padding 和图标宽。</para>
    /// </summary>
    /// <summary>给全局快捷键用的入口。 和侧栏底下那个按钮走**同一句** ——
    /// 另写一套的下场是两条路的折叠状态会分叉。</summary>
    internal void ShortcutToggleSidebar() => ToggleSidebar();

    /// <summary>给全局快捷键用:窗口最大化 / 还原。</summary>
    internal void ShortcutToggleMaximize() => ToggleMaximize();

    /// <summary>给全局快捷键用:勾中侧栏某一项(等于用户点了它)。找不到 / 被藏起来就不动。</summary>
    internal bool ShortcutNav(string ctl)
    {
        var rb = this.FindControl<RadioButton>(ctl);
        if (rb is null || !rb.IsVisible) return false;
        rb.IsChecked = true;
        return true;
    }

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
    /// <para>单独抽出来是因为**服务器行是运行期建的** —— 建完之后
    /// 还得再按当前折叠态收一次,不然收着侧栏切服务器,新建的行是展开版式。</para>
    /// </summary>
    private void SyncCollapsed()
    {
        var icon = this.FindControl<TextBlock>("CollapseIcon")!;
        var box = this.FindControl<StackPanel>("CollapseBox")!;
        var btn = this.FindControl<Button>("BtnCollapse")!;
        this.FindControl<TextBlock>("CollapseText")!.IsVisible = !_collapsed;
        // 56 / Padding 0 —— 和 RadioButton.nav.icononly 那条样式里的数**必须一样**,
        // 差一个像素这一个图标就比上面那一列偏出去
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
    /// 自检:侧栏高亮退场会不会闪一下。这个 bug 只活在过渡的中间几帧。
    ///
    /// <para>根因是给 Background 挂 BrushTransition 插到 <c>Transparent</c>,
    /// 这条插值路径中途会经过又亮又透的颜色 —— 实测 35(悬停)→ 114(中途)→ 26。
    /// 判据不能是「我自己算一遍合成亮度」:那一版注入旧写法照样报 ✓,
    /// 我算的合成和渲染器对不上。直接断言机制:退场时只许 Opacity 在动。</para>
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

    /// <summary>
    /// 收起 / 放回外壳(标题栏 + 侧栏)。行高列宽一起归零,否则画面会被挤在偏右下的框里。
    ///
    /// <para>这里<b>不再动窗口状态</b> —— 全屏拆成了 <see cref="SetFullscreen"/>。
    /// 绑在一起时「播放页不要侧栏」只能靠强制全屏来实现,而那是另一件事。</para>
    /// </summary>
    private void SetImmersive(bool on)
    {
        var root = this.FindControl<Grid>("RootGrid")!;
        var body = this.FindControl<Grid>("BodyGrid")!;
        root.RowDefinitions[0].Height = on ? new GridLength(0) : new GridLength(36);
        // 退全屏要回到**当前的**侧栏宽度,不是写死的 212 ——
        // 否则收着侧栏去看片,回来侧栏自己展开了。
        // 列宽现在是 Auto,宽度在 Sidebar 自己身上(为了能做收放动效)
        _ = body;
        this.FindControl<Border>("Sidebar")!.Width = on ? 0 : SidebarWidth;
        this.FindControl<Grid>("TitleBar")!.IsVisible = !on;
        this.FindControl<Border>("Sidebar")!.IsVisible = !on;
    }

    /// <summary>
    /// 窗口全屏。退出时一律回 <c>Normal</c>。
    ///
    /// <para>原来退全屏回的是进来之前那个 WindowState,而那多半是 Maximized。
    /// 本窗口无边框,调用它的播放页又把标题栏和侧栏一起收了 —— 于是最大化和
    /// 全屏在屏幕上是同一张图,用户按了 F 什么都没变,只能判定「退不出去」。
    /// 丢掉的那点便利,换来的是「退出全屏」这件事在屏幕上看得见。</para>
    /// </summary>
    private void SetFullscreen(bool on) =>
        WindowState = on ? WindowState.FullScreen : WindowState.Normal;

    /// <summary>
    /// 打开服务器编辑器。
    ///
    /// <para>2026-09-04 起是弹窗,不再换页(用户:「编辑信息、线路、图标
    /// 直接做成一个弹窗即可」)。改个名字不该把用户正在浏览的那一页顶掉 ——
    /// 上一版是 <c>Nav.Root</c>,连页面栈都清了。<paramref name="focus"/> 为空
    /// (自检台那条路)时仍然走页面:弹窗是模态的,截图工具截不到。</para>
    /// </summary>
    private void GoServers(string? focus = null, string? drawer = null)
    {
        if (_core is null) return;
        if (!string.IsNullOrEmpty(focus))
        {
            new ServerEditWindow(_core, () => _ = OnServerSwitched(), focus, drawer).ShowDialog(this);
            return;
        }
        foreach (var n in new[] { "NavHome", "NavLibrary", "NavSearch", "NavFavorites",
                                  "NavAggregate", "NavHistory", "NavSettings" })
            this.FindControl<RadioButton>(n)!.IsChecked = false;
        Nav.Root(new ServersPage(_core, () => _ = OnServerSwitched(), focus, drawer));
    }

    /// <summary>
    /// 添加服务器。 侧栏「＋ 添加服务器」和首登闸口走的是同一页。
    ///
    /// <para>顺手把导航项的选中态摘掉(和 <see cref="GoServers"/> 同一条口径)——
    /// 不摘的话侧栏会同时亮着「首页」和「添加服务器」两处。</para>
    /// </summary>
    private void GoAddServer()
    {
        if (_core is null) return;
        foreach (var n in new[] { "NavHome", "NavLibrary", "NavSearch", "NavFavorites",
                                  "NavAggregate", "NavHistory", "NavBrowse", "NavCatalog",
                                  "NavDownload", "NavRanking", "NavCalendar", "NavPlugins",
                                  "NavSettings" })
            if (this.FindControl<RadioButton>(n) is { } rb) rb.IsChecked = false;
        Nav.Push(new AddServerPage(_core, () => _ = AfterServerChange()));
    }

    /// <summary>
    /// 侧栏项已经选中时再点一次,要回到这一大类的根。
    ///
    /// <para>从首页钻进详情页,侧栏「首页」仍然亮着;这时候点它,
    /// <c>RadioButton</c> 的 <c>Checked</c> 不会再发一次,表现是点侧栏毫无反应,
    /// 唯一的出路是详情页左上角那个返回。每个能往下钻的入口都有这一下。
    /// 挂 <c>Click</c> 而不改用它驱动导航:<c>Checked</c> 那条还有程序化调用者。</para>
    /// </summary>
    private void WireNavReclick()
    {
        // 侧栏是在 XAML 里摆好的,而这个方法在构造函数里跑 —— 那会儿控件还没长出来。
        // 所以挂到 Loaded 上;Loaded 可能不止发一次,拿一个集合去重。
        var wired = new HashSet<RadioButton>();
        Loaded += (_, _) =>
        {
            foreach (var n in new[] { "NavHome", "NavLibrary", "NavSearch", "NavFavorites",
                                      "NavAggregate", "NavBrowse", "NavCatalog", "NavHistory",
                                      "NavDownload", "NavRanking", "NavCalendar", "NavPlugins",
                                      "NavSettings" })
            {
                // 别拿 Tag 做「挂过了」的标记 —— 那一格装的是这一项的图标字形。
                if (this.FindControl<RadioButton>(n) is not { } rb || !wired.Add(rb)) continue;
                rb.Click += (_, _) =>
                {
                    // 只在「本来就选中 + 已经钻进去过」时才动。
                    // Depth <= 1 说明就在根上,再导航一次是白重建一页。
                    if (rb.IsChecked == true && Nav.Depth > 1) { rb.IsChecked = false; rb.IsChecked = true; }
                };
            }
        };
    }

    /// <summary>需要 Emby 会话的页面。没会话就落到防崩页,别让它自己去解引用 null。</summary>
    private void Emby(string name, Func<Control> make) =>
        Nav.Root(Nav.Session is null ? new NoSessionPage(name) : make());

    /// <summary>侧栏那条「＋ 添加服务器」。选中态跟着当前页走,见 <see cref="Show"/>。</summary>
    private Button? _addRow;

    /// <summary>侧栏里「使用中」那台服务器的那一行。同上,选中态跟着当前页走。</summary>
    private Button? _activeRow;

    /// <summary>
    /// 换页。侧栏服务器区的选中态只在这一处同步。
    ///
    /// <para>「点添加服务器时悬浮效果还停在已添加的服务器上」的根因是两个状态
    /// 被画成了同一个样子:「这台在用」和「你在这一页」共用 <c>.on</c>,平时重合,
    /// 一进添加页就分叉成两行一起亮。解法不是再造一种颜色(两种画法会让人
    /// 以为是两种功能),是让 <c>.on</c> 只表示当前所在。同步点只放这一处 ——
    /// 散在各个 Click 里,<c>Nav.Back()</c> 那条一定会漏。</para>
    /// </summary>
    private void Show(Control page)
    {
        if (Perf.On) Perf.Log($"换页 → {page.GetType().Name}");
        this.FindControl<ContentControl>("PageHost")!.Content = page;
        SyncServerSelection(page);
    }

    /// <summary>侧栏服务器区的选中态:要么落在「添加服务器」,要么落在使用中那台。</summary>
    private void SyncServerSelection(Control? page)
    {
        var onAdd = page is AddServerPage;
        _addRow?.Classes.Set("on", onAdd);
        _activeRow?.Classes.Set("on", !onAdd);
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
            /* 判「要不要进登录页」看的是**账号表是否为空**,不是 emby.currentSession ——
               只判后者的话网盘用户永远进不了门(他有账号,只是不是 Emby 的)。
               这条在 Rust 版害过一次。 */
            if (accounts.ValueKind != JsonValueKind.Array || accounts.GetArrayLength() == 0)
            {
                /* 首登时把导航整条藏掉。
                   之前是亮着的 —— 还没有服务器,「首页 / 媒体库 / 搜索」全能点,
                   点进去清一色「请先登录服务器」。**摆一堆必定失败的入口**
                   和摆一个必定失败的按钮是同一个毛病(详情页的外部播放器那条已经这么处理了)。
                   设置留着:代理配错了连不上服务器,那是首登时真的要改的东西。 */
                this.FindControl<StackPanel>("NavList")!.IsVisible = false;
                // 服务器区也要一起藏:一台都没有的时候它只剩一条分隔线和「服务器」两个字,
                // 看着像没加载出来。而这一屏本来就整页都是「添加服务器」。
                this.FindControl<StackPanel>("ServerSection")!.IsVisible = false;
                Show(new AddServerPage(_core, OnLoggedIn));
                return;
            }
            UpdateServerChip(accounts);
            // 会话拉一次存住:命令层迁移期还要显式传 server/token/user_id,
            // 每页各拉一次就是每页多一次往返。
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
    /// <para>**绝不直接添加**。链接可能来自任何网页或聊天窗口 ——
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
            var page = new BatchAddPage(_core, () => _ = AfterServerChange());
            Nav.Push(page);
            await page.LoadDeepLink(r.GetString() ?? "");
        }
        catch { /* 没有深链是常态,不是错误 */ }
    }

    /// <summary>
    /// 切了服务器 / 改了账号之后:会话和侧栏都要重来。
    ///
    /// <para>只刷侧栏不刷会话的话,整个应用还在拿旧 token 打新服务器 ——
    /// 表现是切完之后每一页都 401,而侧栏显示的是新服务器的名字。</para>
    /// </summary>
    /// <summary>
    /// 账号表变动之后的统一收尾:换会话 → 回首页。
    ///
    /// <para>用户 2026-09-03:「切换服务器的时候首页也应该跟着一起切换,
    /// 而不是等用户自己点击了首页再切换」。「添加完」「删除完」是同一件事的另外两个入口 ——
    /// 原来它们只是 <c>Nav.Back()</c>,退回去的是一张<b>上一台服务器</b>的页面。</para>
    /// </summary>
    private async Task AfterServerChange()
    {
        await OnServerSwitched();
        this.FindControl<RadioButton>("NavHome")!.IsChecked = true;
        Nav.Root(Home());
    }

    /// <summary>
    /// 切完服务器:刷侧栏 + 换掉全局会话。
    ///
    /// <para>原来是 <c>async void</c>,调用点等不了它:<c>AccountSetActiveServer</c>
    /// 发射后不管,立刻 <c>Nav.Root(Home())</c>,而 <see cref="Home"/> 读的
    /// <see cref="Nav.Session"/> 那会儿还是上一台的会话 —— 新首页确实建出来了,
    /// 只是拿旧服务器的凭据去拉的内容。改成 <c>Task</c> 不是风格问题。</para>
    /// </summary>
    private async Task OnServerSwitched()
    {
        try
        {
            UpdateServerChip(await _core!.AccountListAccounts());
            Nav.Session = Sess.From(await _core.EmbyCurrentSession());
        }
        catch { Nav.Session = null; /* 非 Emby 账号没有会话 —— 但也不能留着上一台的 */ }
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
            判据是 `source_kind != "emby"`,**线上一律小写**。
            前端曾整套写成首字母大写:每处比较恒 false、登录送错值,而两边都不报错。
            没有这个键 = 老配置 = Emby(这个键是后加的)。 */
        var kind = active.TryGetProperty("source_kind", out var sk) && sk.ValueKind == JsonValueKind.String
            ? sk.GetString() ?? "emby" : "emby";
        var isBrowse = kind.Length > 0 && kind != "emby";
        _sourceName = active.TryGetProperty("name", out var sn) ? sn.GetString() ?? "" : "";

        Dispatcher.UIThread.Post(() =>
        {
            BuildServerList(rows);

            /* 按账号类型显隐入口,而不是全都亮着。
               全亮的话:Emby 账号点「文件浏览」拿到「当前没有已登录的文件源」,
               网盘账号点「媒体库」拿到「请先登录服务器」—— 两个都是**专门用来报错的入口**。 */
            // 和功能开关**取与**:这里按账号类型算出来的「该亮」,
            // 碰上 Features 里关着的仍然不亮 —— 否则切个账号就把下线的入口放出来了。
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
    /// <para>用户 2026-09-03:「只需要鼠标往左边点点,就可以切换服务器了」——
    /// 所以<b>左键就是切换</b>,不是「打开一个能切换的页面」。
    /// 少一层跳转,这一条才成立。</para>
    ///
    /// <para>「＋ 添加服务器」在列表<b>上面</b>(用户点名的位置)。
    /// 放下面的话服务器越多它越往下跑,而它的位置应当是固定的。</para>
    /// </summary>
    private void BuildServerList(List<JsonElement> rows)
    {
        var list = this.FindControl<StackPanel>("ServerList")!;
        list.Children.Clear();

        var add = NavRow("\uE710", "添加服务器", null);
        add.Click += (_, _) => GoAddServer();
        _addRow = add;
        _activeRow = null;   // 这一列整个重建了,上一轮那个引用已经不在树上
        list.Children.Add(add);

        foreach (var a in rows)
        {
            var server = Str(a, "server");
            var name = Str(a, "name") is { Length: > 0 } n ? n : server;
            var on = a.TryGetProperty("active", out var v) && v.ValueKind == JsonValueKind.True;
            // \uE968 = 一台服务器的通用图标。真图标随后由 account.icon 换上去(见 FillServerIcon)
            /* <b>先查内存里那份</b>,查到就在建行的这一刻直接贴上去。
               用户 2026-09-03:「切换服务器的时候服务器图标会闪现回到软件自己的默认图,
               应该一直保持获取到的图标,做好持久化」——
               根因不是没缓存(核心层按 server_id 落盘缓存着呢),是**这一列每次都重建**,
               而换图那一步排在 await 后面:重建 → 画默认图标 → 一帧之后才换回真图标。
               那一帧就是用户看到的「闪回默认图」。 */
            var row = NavRow("\uE968", name, on ? "on" : null);
            if (_serverIcons.TryGetValue(server, out var known)) PaintIcon(row, known);
            ToolTip.SetTip(row, on ? $"{name}(使用中) —— 右键有编辑 / 线路 / 图标 / 重新登录"
                                   : $"切到 {name} —— 右键有编辑 / 线路 / 图标 / 重新登录");
            row.Click += async (_, _) =>
            {
                /* 已经在用的那台<b>不是「点了没反应」</b>(用户 2026-09-04:
                   「点回已添加的服务器就直接返回该服务器的首页」)。
                   原来这里是 `if (on) return;` —— 从添加服务器页或详情页点回来时
                   界面上毫无反应,而侧栏那一行明明亮着、看着就该能点。
                   会话没变,所以不必再打一次 setActiveServer,回首页就够了。 */
                if (on)
                {
                    this.FindControl<RadioButton>("NavHome")!.IsChecked = true;
                    Nav.Root(Home());
                    return;
                }
                try
                {
                    await _core!.AccountSetActiveServer(new { server_id = server });
                    // **必须等**:Home() 读的是 Nav.Session,而它是在这里面换的。
                    // 不等的话新首页拿旧服务器的凭据去拉内容(见 OnServerSwitched 的注释)。
                    await OnServerSwitched();
                    // 切完必须**换页**:留在原来那一页的话,页面上还是上一台服务器的内容,
                    // 而侧栏已经把新的那台标成使用中了 —— 那是界面在撒谎。
                    this.FindControl<RadioButton>("NavHome")!.IsChecked = true;
                    Nav.Root(Home());
                }
                catch (Exception e) { Console.WriteLine("[切服务器] " + e.Message); }
            };
            row.ContextMenu = ServerMenu(server, name);
            if (on) _activeRow = row;
            list.Children.Add(row);
            _ = FillServerIcon(row, server);
        }
        // 重建这一列时当前页可能就是添加页(比如刚添加完一台),选中态得跟着补回来
        SyncServerSelection(Nav.Current);
        SyncCollapsed();
    }

    /// <summary>
    /// 右键菜单:把原来服务器页上那四组编辑动作搬过来。
    ///
    /// <para>删除单独列在分隔线下面,并且**它自己再确认一次** ——
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
                // 删掉的可能正是当前那台 —— 会话跟着换了,页面也得跟着换
                await AfterServerChange();
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
                    // Tag 标成 name:折叠态要按这个把文字收掉(见 SyncCollapsed)
                    Tag = "name", Text = text, FontSize = 13,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        };
        var b = new Button
        {
            Classes = { "navbtn" }, Height = 38, Margin = new Thickness(10, 2),
            Padding = new Thickness(10, 0),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Left,
            Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            CornerRadius = new CornerRadius(6), Cursor = new Cursor(StandardCursorType.Hand),
            Content = sp,
        };
        if (extraClass is not null) b.Classes.Add(extraClass);
        return b;
    }

    /// <summary>
    /// 换上这台服务器的真图标。
    ///
    /// <para>两条路核心层早就都实现了(<c>account.icon</c>:登录时的用户头像,
    /// 没有就退回 <c>/web/touchicon.png</c>)—— 缺的只是 UI 从来没调过它,
    /// 又一条零调用命令。取不到就保持那个 MDL2 通用图标,不报错:
    /// 没设过头像、官方图标 404,都很常见。</para>
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
        catch { return; }   // 服务器图标拉不到就留默认的字母头像
        if (!uri.StartsWith("data:", StringComparison.Ordinal)) return;
        var at = uri.IndexOf("base64,", StringComparison.Ordinal);
        if (at < 0) return;
        byte[] bytes;
        try { bytes = Convert.FromBase64String(uri[(at + 7)..]); }
        catch { return; }   // 图标数据坏了同上,不值得为它弹提示

        Dispatcher.UIThread.Post(() =>
        {
            try
            {
                using var ms = new MemoryStream(bytes);
                var img = new Avalonia.Media.Imaging.Bitmap(ms);
                // 解好的位图**留住**:下次重建这一列时不必再走一遍 await(见 BuildServerList)
                _serverIcons[server] = img;
                PaintIcon(row, img);
            }
            // 图标解不开不该把整条侧栏拖红(某些服务器返回的是 SVG,Avalonia 解不了)
            catch (Exception e) { Console.WriteLine("[服务器图标] " + e.Message); }
        });
    }

    /// <summary>
    /// 已解好的服务器图标,按 server_id 记着。
    ///
    /// <para>这一层<b>不是</b>为了省下载 —— 核心层早就把图标落盘缓存了。
    /// 它省的是「解码 + 一次 await」,而那一次 await 就是用户看到的那一帧默认图标。</para>
    /// <para>不设上限:服务器是个位数,而且每张位图只有 18×18。</para>
    /// </summary>
    private readonly Dictionary<string, Avalonia.Media.Imaging.Bitmap> _serverIcons = new();

    /// <summary>把图标贴到一行上(替换掉那个 MDL2 通用字形)。</summary>
    private static void PaintIcon(Button row, Avalonia.Media.Imaging.Bitmap img)
    {
        if (row.Content is not StackPanel sp || sp.Children.Count == 0) return;
        sp.Children[0] = new Border
        {
            // 外框宽度**照抄被换掉的那一个**:折叠态下它是 56(撑成一整格才居中),展开态 18。
            // 写死 18 的话折叠时这一行的图标会往左偏,和上面那一列对不齐 ——
            // 而对齐这件事正是用户上一轮点名过的。
            Width = sp.Children[0].Width, Height = 18,
            VerticalAlignment = VerticalAlignment.Center,
            // 圆角裁切放在**内层** 18×18 上:裁在外框上的话折叠态那 56 宽会被一起圆掉
            Child = new Border
            {
                Width = 18, Height = 18,
                CornerRadius = new CornerRadius(6), ClipToBounds = true,
                HorizontalAlignment = HorizontalAlignment.Center,
                Child = new Image
                {
                    Source = img, Width = 18, Height = 18,
                    Stretch = Avalonia.Media.Stretch.UniformToFill,
                },
            },
        };
    }

    /// <summary>
    /// 窗口图标 + 标题栏左上角那一枚。
    ///
    /// <para>标题栏原来画的是一块纯色圆角方块 —— 那是占位,不是图标。
    /// 有真图标就该用真的:用户在任务栏上认的是这一枚。</para>
    /// <para>取不到就保持原样(那块纯色方块),不抛 —— 图标没有不该让程序起不来。</para>
    /// </summary>
    private void SetAppIcon()
    {
        try
        {
            using var s = Avalonia.Platform.AssetLoader.Open(
                new Uri("avares://LinPlayer/Assets/icon.ico"));
            var bmp = new Avalonia.Media.Imaging.Bitmap(s);
            Icon = new WindowIcon(bmp);
            if (this.FindControl<Border>("BrandDot") is { } dot)
            {
                dot.Background = null;
                dot.Child = new Image
                {
                    Source = bmp, Width = 16, Height = 16,
                    Stretch = Avalonia.Media.Stretch.Uniform,
                };
            }
        }
        catch (Exception e) { Console.WriteLine("[图标] " + e.Message); }
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}
