using System;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia.Controls;
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
        this.FindControl<RadioButton>("NavHome")!.Checked += (_, _) => Nav.Root(Home());
        this.FindControl<RadioButton>("NavLibrary")!.Checked += (_, _) => Nav.Root(new LibraryPage(_core!));
        this.FindControl<RadioButton>("NavSearch")!.Checked += (_, _) => Nav.Root(new SearchPage(_core!));
        this.FindControl<RadioButton>("NavFavorites")!.Checked += (_, _) => Nav.Root(new FavoritesPage(_core!));
        this.FindControl<RadioButton>("NavSettings")!.Checked += (_, _) => Nav.Root(new SettingsPage(_core!));

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
    private void SelfCheckJump()
    {
        var want = Environment.GetEnvironmentVariable("LP_SELFCHECK_PAGE");
        if (string.IsNullOrEmpty(want) || _core is null) return;
        var arg = want.Contains(':') ? want[(want.IndexOf(':') + 1)..] : "";
        var srv = Nav.Session?.server ?? "";
        switch (want.Split(':')[0])
        {
            case "library": this.FindControl<RadioButton>("NavLibrary")!.IsChecked = true; break;
            case "search": this.FindControl<RadioButton>("NavSearch")!.IsChecked = true; break;
            case "favorites": this.FindControl<RadioButton>("NavFavorites")!.IsChecked = true; break;
            case "settings": this.FindControl<RadioButton>("NavSettings")!.IsChecked = true; break;
            case "grid": Nav.Push(new LibraryGridPage(_core, srv, arg, "自检库")); break;
            case "detail": Nav.Push(new DetailPage(_core, srv, arg)); break;
            case "player": Nav.Push(new PlayerPage(_core, arg, "自检片", 0)); break;
        }
    }

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
    }

    private void UpdateServerChip(JsonElement accounts)
    {
        if (accounts.ValueKind != JsonValueKind.Array) return;
        var active = accounts.EnumerateArray()
            .FirstOrDefault(a => a.TryGetProperty("active", out var v) && v.GetBoolean());
        if (active.ValueKind != JsonValueKind.Object)
            active = accounts.EnumerateArray().FirstOrDefault();
        if (active.ValueKind != JsonValueKind.Object) return;

        Dispatcher.UIThread.Post(() =>
        {
            this.FindControl<TextBlock>("ServerName")!.Text =
                active.TryGetProperty("name", out var n) ? n.GetString() : "服务器";
            this.FindControl<TextBlock>("ServerSub")!.Text =
                active.TryGetProperty("user_name", out var u) && !string.IsNullOrEmpty(u.GetString())
                    ? u.GetString() : "已连接";
        });
    }
}
