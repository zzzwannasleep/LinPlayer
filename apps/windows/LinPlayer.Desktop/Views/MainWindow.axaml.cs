using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Markup.Xaml;
using Avalonia.Threading;
using LinPlayer.Core;

namespace LinPlayer.Desktop.Views;

public partial class MainWindow : Window
{
    private readonly Desktop.Core.CoreClient? _core = Program.Core;

    public MainWindow()
    {
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

        this.FindControl<Button>("ServerChip")!.Click += (_, _) => GoServers();
        // ★ 需要 Emby 会话的页面统一走 Emby():账号是网盘 / 局域网源时 Nav.Session 是 null,
        //   页面里直接解引用会抛在 Task 里 —— 没提示、不崩、就是永远停在「加载中」。
        this.FindControl<RadioButton>("NavHome")!.Checked += (_, _) => Nav.Root(Home());
        /* ★★ 「文件浏览」只在当前账号是**浏览型源**时才出现。
           Emby 账号下亮着它,点进去只会拿到一句「当前没有已登录的文件源」——
           那不是功能,那是一个专门用来报错的入口。 */
        this.FindControl<RadioButton>("NavBrowse")!.Checked += (_, _) =>
            Nav.Root(new BrowsePage(_core!, _sourceName));
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
        this.FindControl<RadioButton>("NavSettings")!.Checked += (_, _) => Nav.Root(new SettingsPage(_core!));

        /* ★★ 自检模式下把窗口置顶。
           截图走的是 CopyFromScreen —— 抓的是**屏幕那块区域**,不是窗口自身内容。
           被别的程序压住时截出来的是压在上面那个窗口,而脚本照样报「成功」。
           2026-08-31 真栽过:截到了另一个程序的界面,差点当成 LinPlayer 的界面来读。
           SetForegroundWindow 在调用方不是前台进程时会被 Windows 拒掉,靠不住;
           由被截的窗口**自己置顶**才是稳的。只在自检时开,不影响产品行为。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK") == "1") Topmost = true;

        Opened += async (_, _) => await BootAsync();
    }

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

    private void SelfCheckJump(string? want)
    {
        // ★ 最大化必须单独验一遍:无边框窗口最大化时四周会溢出屏幕 8px,
        //   把自绘标题栏的按钮顶到屏幕外(Rust 版栽过,根治办法是 WM_GETMINMAXINFO 钉 rcWork)。
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_MAXIMIZE") == "1")
            WindowState = WindowState.Maximized;

        if (string.IsNullOrEmpty(want) || _core is null) return;
        var arg = want.Contains(':') ? want[(want.IndexOf(':') + 1)..] : "";
        var srv = Nav.Session?.server ?? "";
        switch (want.Split(':')[0])
        {
            case "library": this.FindControl<RadioButton>("NavLibrary")!.IsChecked = true; break;
            case "search": this.FindControl<RadioButton>("NavSearch")!.IsChecked = true; break;
            case "favorites": this.FindControl<RadioButton>("NavFavorites")!.IsChecked = true; break;
            case "settings": this.FindControl<RadioButton>("NavSettings")!.IsChecked = true; break;
            case "aggregate": this.FindControl<RadioButton>("NavAggregate")!.IsChecked = true; break;
            case "history": this.FindControl<RadioButton>("NavHistory")!.IsChecked = true; break;
            case "download": this.FindControl<RadioButton>("NavDownload")!.IsChecked = true; break;
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
            case "grid": Nav.Push(new LibraryGridPage(_core, srv, arg, "自检库")); break;
            case "detail": Nav.Push(new DetailPage(_core, srv, arg)); break;
            // 自检:进详情页 → 点「下载」 → 跳下载页。整条链一次走完
            case "dl":
                Nav.Push(new DetailPage(_core, srv, arg));
                _ = SelfCheckDownload();
                break;
            case "player": Nav.Push(new PlayerPage(_core, arg, "自检片", 0)); break;
        }
    }

    /// <summary>全屏/退出全屏。行高列宽一起归零,否则画面会被挤在偏右下的框里。</summary>
    private void SetImmersive(bool on)
    {
        var root = this.FindControl<Grid>("RootGrid")!;
        var body = this.FindControl<Grid>("BodyGrid")!;
        root.RowDefinitions[0].Height = on ? new GridLength(0) : new GridLength(36);
        body.ColumnDefinitions[0].Width = on ? new GridLength(0) : new GridLength(212);
        this.FindControl<Grid>("TitleBar")!.IsVisible = !on;
        this.FindControl<Border>("Sidebar")!.IsVisible = !on;
        WindowState = on ? WindowState.FullScreen : WindowState.Normal;
    }

    /// <summary>进服务器管理。★ 顺手把侧栏的选中态摘掉 —— 不摘的话
    /// 界面在说「你在首页」,而实际在服务器页,用户会以为点了没反应。</summary>
    private void GoServers()
    {
        if (_core is null) return;
        foreach (var n in new[] { "NavHome", "NavLibrary", "NavSearch", "NavFavorites",
                                  "NavAggregate", "NavHistory", "NavSettings" })
            this.FindControl<RadioButton>(n)!.IsChecked = false;
        Nav.Root(new ServersPage(_core, OnServerSwitched));
    }

    /// <summary>需要 Emby 会话的页面。没会话就落到防崩页,别让它自己去解引用 null。</summary>
    private void Emby(string name, Func<Control> make) =>
        Nav.Root(Nav.Session is null ? new NoSessionPage(name) : make());

    private void Show(Control page) => this.FindControl<ContentControl>("PageHost")!.Content = page;

    /// <summary>首页。点卡片进详情 —— 库卡进网格,条目卡进详情(判断在 OpenDetail 一处)。</summary>
    private Control Home() =>
        new HomePage(_core, Nav.Session is null ? null
            : LibraryPage.OpenDetail(_core!, Nav.Session.server));

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
                Show(new AddServerPage(_core, OnLoggedIn));
                return;
            }
            UpdateServerChip(accounts);
            // ★ 会话拉一次存住:命令层迁移期还要显式传 server/token/user_id,
            //   每页各拉一次就是每页多一次往返。
            try { Nav.Session = Sess.From(await _core.EmbyCurrentSession()); } catch { /* 非 Emby 账号没有会话 */ }
            Nav.Root(Home());
            SelfCheckJump();
        }
        catch (Exception e)
        {
            Show(new FatalPage($"读账号表失败:{e.Message}"));
        }
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
        this.FindControl<RadioButton>("NavHome")!.IsChecked = true;
        Nav.Root(Home());
        // 真机自检:登录成功之后再跳到指定页面(LP_SELFCHECK_PAGE 那会儿装的是 login:...)
        SelfCheckJump(Environment.GetEnvironmentVariable("LP_SELFCHECK_AFTER"));
    }

    /// <summary>当前源的显示名。文件浏览页的面包屑根节点用它。</summary>
    private string _sourceName = "";

    private void UpdateServerChip(JsonElement accounts)
    {
        if (accounts.ValueKind != JsonValueKind.Array) return;
        var active = accounts.EnumerateArray()
            .FirstOrDefault(a => a.TryGetProperty("active", out var v) && v.GetBoolean());
        if (active.ValueKind != JsonValueKind.Object)
            active = accounts.EnumerateArray().FirstOrDefault();
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
            this.FindControl<TextBlock>("ServerName")!.Text =
                active.TryGetProperty("name", out var n) ? n.GetString() : "服务器";
            this.FindControl<TextBlock>("ServerSub")!.Text =
                active.TryGetProperty("user_name", out var u) && !string.IsNullOrEmpty(u.GetString())
                    ? u.GetString() : "已连接";

            /* ★★ 按账号类型显隐入口,而不是全都亮着。
               全亮的话:Emby 账号点「文件浏览」拿到「当前没有已登录的文件源」,
               网盘账号点「媒体库」拿到「请先登录服务器」—— 两个都是**专门用来报错的入口**。 */
            this.FindControl<RadioButton>("NavBrowse")!.IsVisible = isBrowse;
            foreach (var name in new[] { "NavLibrary", "NavSearch", "NavFavorites" })
                this.FindControl<RadioButton>(name)!.IsVisible = !isBrowse;

            // 浏览型源进来时,首页那一套是空的 —— 直接落到文件浏览
            if (isBrowse && Nav.Current is HomePage)
                this.FindControl<RadioButton>("NavBrowse")!.IsChecked = true;
        });
    }
}
