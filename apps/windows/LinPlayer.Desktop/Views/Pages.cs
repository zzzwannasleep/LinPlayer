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
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>页面的公共底子:统一的水槽与封顶宽(UI_PC §3.1)。</summary>
public abstract class PageBase : UserControl
{
    protected static ScrollViewer Scrolled(Control content) => new()
    {
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Content = new Border
        {
            // ★ 正文封顶 1560 居中 + 左右水槽 18(§3.1)。
            //   不封顶的话 4K 屏上一行能塞十几张卡,眼睛要横扫整块屏。
            MaxWidth = 1560,
            HorizontalAlignment = HorizontalAlignment.Center,
            Padding = new Thickness(18, 18, 18, 28),
            Child = content,
        },
    };

    protected static TextBlock H1(string t) => new() { Text = t, Classes = { "h1" } };
    protected static TextBlock H2(string t) => new() { Text = t, Classes = { "h2" } };
    protected static TextBlock Dim(string t) => new() { Text = t, Classes = { "dim" }, TextWrapping = TextWrapping.Wrap };
}

/// <summary>核心层没起来时的页面。**不能白屏** —— 要如实说出原因。</summary>
public sealed class FatalPage : PageBase
{
    public FatalPage(string reason)
    {
        Content = new Border
        {
            Padding = new Thickness(40),
            Child = new StackPanel
            {
                Spacing = 12,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                Children =
                {
                    H1("核心层没能启动"),
                    Dim(reason),
                    Dim("常见原因:lpcore.dll 或 libmpv-2.dll 不在 exe 同级目录。"),
                },
            },
        };
    }
}

public sealed class PlaceholderPage : PageBase
{
    public PlaceholderPage(string name)
    {
        Content = Scrolled(new StackPanel
        {
            Spacing = 10,
            Children = { H1(name), Dim("这一页还没做。") },
        });
    }
}

/// <summary>
/// 首登闸口 / 添加服务器(UI_PC §7.6)。
///
/// <para>★ 它和「添加服务器」是**同一个页面的两种版式**,不是两套代码 ——
/// 两套的话新增一种源类型就要改两处,而漏掉的那处就是「某个入口加不了这种源」。</para>
/// </summary>
public sealed class AddServerPage : PageBase
{
    public AddServerPage(CoreClient core, Action onDone)
    {
        var server = new TextBox { Classes = { "field" }, Watermark = "https://你的服务器地址" };
        var user = new TextBox { Classes = { "field" }, Watermark = "用户名" };
        var pass = new TextBox { Classes = { "field" }, Watermark = "密码", PasswordChar = '●' };
        var hint = new TextBlock { Classes = { "dim" }, TextWrapping = TextWrapping.Wrap };
        var test = new Button { Classes = { "ghost" }, Content = "测试连接" };
        var login = new Button { Classes = { "primary" }, Content = "登录" };

        void Busy(bool on, string? msg = null)
        {
            test.IsEnabled = login.IsEnabled = !on;
            if (msg is not null) hint.Text = msg;
        }

        test.Click += async (_, _) =>
        {
            Busy(true, "正在连接…");
            try
            {
                var info = await core.AccountTestConnection(new { server = server.Text ?? "" });
                hint.Text = $"连上了:{Get(info, "name")} · 版本 {Get(info, "version")}";
            }
            catch (CoreException e) { hint.Text = e.Advice; }
            catch (Exception e) { hint.Text = e.Message; }
            finally { Busy(false); }
        };

        login.Click += async (_, _) =>
        {
            Busy(true, "正在登录…");
            try
            {
                await core.EmbyLogin(new
                {
                    server = server.Text ?? "",
                    username = user.Text ?? "",
                    password = pass.Text ?? "",
                    // ★ 设备 id 必须**持久**:每次换一个会把服务器的设备列表刷满,
                    //   续播会话也对不上。核心层的 config 里有一个,这里先用机器名兜底。
                    device_id = DeviceId(),
                });
                onDone();
            }
            catch (CoreException e) { hint.Text = e.Advice; Busy(false); }
            catch (Exception e) { hint.Text = e.Message; Busy(false); }
        };

        var form = new StackPanel
        {
            Spacing = 12,
            Children =
            {
                H1("连接到你的媒体服务器"),
                Dim("支持 Emby。填服务器地址和账号即可;先「测试连接」可以确认地址对不对。"),
                new StackPanel { Spacing = 8, Children = { Label("服务器地址"), server } },
                new StackPanel { Spacing = 8, Children = { Label("用户名"), user } },
                new StackPanel { Spacing = 8, Children = { Label("密码"), pass } },
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Margin = new Thickness(0, 6, 0, 0),
                    Children = { login, test },
                },
                hint,
            },
        };

        Content = new Border
        {
            Padding = new Thickness(24),
            Child = new Border
            {
                Classes = { "card" },
                Width = 460,
                Padding = new Thickness(28),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Child = form,
            },
        };
    }

    private static TextBlock Label(string t) => new()
    {
        Text = t, FontSize = 12.5, Foreground = Brushes.Gray,
    };

    private static string DeviceId() =>
        "linplayer-" + Environment.MachineName.GetHashCode().ToString("x8");

    private static string Get(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) ? v.GetString() ?? "" : "";
}
