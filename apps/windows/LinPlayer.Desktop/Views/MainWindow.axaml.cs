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

        this.FindControl<RadioButton>("NavHome")!.Checked += (_, _) => Show(new HomePage(_core));
        this.FindControl<RadioButton>("NavLibrary")!.Checked += (_, _) => Show(new PlaceholderPage("媒体库"));
        this.FindControl<RadioButton>("NavSearch")!.Checked += (_, _) => Show(new PlaceholderPage("搜索"));
        this.FindControl<RadioButton>("NavFavorites")!.Checked += (_, _) => Show(new PlaceholderPage("收藏"));
        this.FindControl<RadioButton>("NavSettings")!.Checked += (_, _) => Show(new PlaceholderPage("设置"));

        Opened += async (_, _) => await BootAsync();
    }

    private void InitializeComponent() => AvaloniaXamlLoader.Load(this);

    private void ToggleMaximize() =>
        WindowState = WindowState == WindowState.Maximized ? WindowState.Normal : WindowState.Maximized;

    private void Show(Control page) => this.FindControl<ContentControl>("PageHost")!.Content = page;

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
            Show(new HomePage(_core));
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
        this.FindControl<RadioButton>("NavHome")!.IsChecked = true;
        Show(new HomePage(_core));
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
