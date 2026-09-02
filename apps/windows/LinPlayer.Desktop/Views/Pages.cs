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
using Avalonia.Platform.Storage;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>页面的公共底子:统一的水槽与封顶宽(UI_PC §3.1)。</summary>
public abstract class PageBase : UserControl
{
    /// <summary>
    /// 页面正文的滚动容器。
    ///
    /// <para>★ 平滑滚动<b>不在这里装</b> —— 装在 <see cref="Smooth.Install"/>(类级处理器,
    /// 全应用一次)。装在这儿的话,自己 new ScrollViewer 的那 6 处页面就漏了。</para>
    /// </summary>
    protected static ScrollViewer Scrolled(Control content) => new()
    {
        HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
        VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
        Content = new Border
        {
            // ★ 正文封顶 1560 居中 + 左右水槽 18(§3.1)。
            //   不封顶的话 4K 屏上一行能塞十几张卡,眼睛要横扫整块屏。
            // ★ Stretch **不是** Center:Center 会让容器缩到内容宽,
            //   内容窄的页(详情、设置)就整块飘到屏幕中间,和侧栏对不齐。
            //   Stretch + MaxWidth 才是「撑满、但封顶 1560 后居中」。
            MaxWidth = 1560,
            HorizontalAlignment = HorizontalAlignment.Stretch,
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

/// <summary>
/// 当前账号不是 Emby 时的落地页。
///
/// <para>★★ 这不是「懒得做」的占位页。这些页面全都直接用 <c>Nav.Session</c> 取会话;
/// 账号是网盘 / 局域网源时它是 null,解引用就是空引用异常。
/// **实测**(注入摘掉这个守卫跑一遍):页面自己的 catch 会接住,但显示的是
/// 「加载失败:Object reference not set to an instance of an object.」——
/// 一句用户看不懂、也不知道该干什么的英文。守卫换来的是一句能照着做的中文。</para>
///
/// <para>这条路真实存在:从旧版升上来的用户,活跃账号本来就可能不是 Emby。</para>
/// </summary>
public sealed class NoSessionPage : PageBase
{
    public NoSessionPage(string what)
    {
        Content = Scrolled(new StackPanel
        {
            Spacing = 10,
            Children =
            {
                H1(what),
                Dim("当前账号不是 Emby 服务器,这一页还没有对应的实现。"),
                Dim("点左上角的服务器信息可以切换到 Emby 账号。"),
            },
        });
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
                var info = await core.AccountTestConnection(new { server = WithScheme(server.Text ?? "") });
                hint.Text = $"连上了:{Get(info, "name")} · 版本 {Get(info, "version")}";
            }
            catch (CoreException e) { hint.Text = e.Advice; }
            catch (Exception e) { hint.Text = e.Message; }
            finally { Busy(false); }
        };

        /* 源类型选择(UI_PC §7.6:一份表单定义 + 三种版式)。
           ★★ **不能只有 Emby**:核心层已经接了本地文件夹 / WebDAV / Ani-RSS 三个
             文件浏览型源,而界面上没有入口的话它们等于不存在 —— 而且这种「后端有、
             前端没接」正是本仓最常见的一类静默缺口。
           ★ 新增一种源只改这张表一处:分散在各处的话,漏掉的那处就是
             「某个入口加不了这种源」。 */
        var kinds = new[]
        {
            ("Emby", "emby", "填服务器地址和账号即可。先点「测试连接」可以确认地址对不对。"),
            ("本地文件夹", "local", "选一个本机目录当作源。没有地址也没有账号密码。"),
            ("WebDAV", "webdav", "填 WebDAV 地址和账号密码。账号密码可留空(匿名)。"),
            ("Ani-RSS", "anirss", "填 Ani-RSS 服务地址和账号密码。只对接播放,不含管理台。"),
        }
        /* ★★ 文件浏览型源跟着「文件浏览」入口一起下线。
           留着的后果是**登进去就是死路**:登录成功 → 侧栏没有文件浏览 → 什么都点不到。
           2026-09-02 砍功能时现场抓到的:砍入口不砍源类型,等于给用户挖了个坑。
           开关表在 Features.cs,那边放开 nav.browse 时这里自动跟着回来。 */
        .Where(k => k.Item2 == "emby" || Features.On("nav.browse")).ToArray();
        // ★ 用 WrapPanel:四个芯片在固定宽的卡里一行放不下,
        //   用 StackPanel 的话最后一个会被卡的边缘裁掉(而且**一点提示都没有**)。
        /* ★★ 只剩一种源类型时**整条不画**。
           一个只有一个选项的选择器是纯噪音 —— 用户会盯着它想「还能选什么」,
           而答案是没有。(同一条规矩用在详情页的季选择条上。)
           2026-09-02 砍功能之后这里就只剩 Emby 了,芯片却还孤零零摆着。 */
        var kindBar = new WrapPanel { IsVisible = kinds.Length > 1 };
        var kindDesc = Dim(kinds[0].Item3);
        var kindIndex = 0;
        var serverRow = new StackPanel { Spacing = 8, Children = { Label("服务器地址"), server } };
        var userRow = new StackPanel { Spacing = 8, Children = { Label("用户名"), user } };
        var passRow = new StackPanel { Spacing = 8, Children = { Label("密码"), pass } };
        var pickDir = new Button { Classes = { "ghost" }, Content = "选择文件夹…" };
        var pickedDir = Dim("");
        var dirRow = new StackPanel
        {
            Spacing = 8, IsVisible = false,
            Children = { Label("本机目录"), pickDir, pickedDir },
        };

        void ApplyKind()
        {
            var k = kinds[kindIndex].Item2;
            kindDesc.Text = kinds[kindIndex].Item3;
            // ★ 本地源的表单**只有一个「选择文件夹」按钮** —— 没有地址框也没有账号密码。
            var isLocal = k == "local";
            serverRow.IsVisible = userRow.IsVisible = passRow.IsVisible = !isLocal;
            dirRow.IsVisible = isLocal;
            test.IsVisible = k == "emby";
            // ★ 局域网 / Ani-RSS 各给各的占位符 —— 在 WebDAV 的框里摆个 Emby 的
            //   示例地址只会把人带沟里。
            server.Watermark = k switch
            {
                "webdav" => "https://你的 WebDAV 地址/dav",
                "anirss" => "http://你的 Ani-RSS 地址:7789",
                _ => "https://你的服务器地址",
            };
            for (var i = 0; i < kindBar.Children.Count; i++)
                ((Button)kindBar.Children[i]).Classes.Set("primary", i == kindIndex);
        }

        for (var i = 0; i < kinds.Length; i++)
        {
            var idx = i;
            var chip = new Button
            {
                Classes = { "ghost" }, Content = kinds[i].Item1,
                Margin = new Thickness(0, 0, 8, 8),
            };
            chip.Click += (_, _) => { kindIndex = idx; ApplyKind(); };
            kindBar.Children.Add(chip);
        }

        pickDir.Click += async (_, _) =>
        {
            var top = TopLevel.GetTopLevel(pickDir);
            if (top is null) return;
            var dirs = await top.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
            {
                Title = "选择要当作源的文件夹", AllowMultiple = false,
            });
            if (dirs.Count > 0) pickedDir.Text = dirs[0].Path.LocalPath;
        };

        var form = new StackPanel
        {
            Spacing = 12,
            Children =
            {
                H1("连接到你的媒体服务器"),
                kindBar, kindDesc,
                serverRow, userRow, passRow, dirRow,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Margin = new Thickness(0, 6, 0, 0),
                    Children = { login, test },
                },
                hint,
            },
        };
        ApplyKind();

        login.Click += async (_, _) =>
        {
            Busy(true, "正在登录…");
            try
            {
                var kind = kinds[kindIndex].Item2;
                if (kind == "emby")
                {
                    await core.EmbyLogin(new
                    {
                        server = WithScheme(server.Text ?? ""),
                        username = user.Text ?? "",
                        password = pass.Text ?? "",
                        // ★ 设备 id 必须**持久**:每次换一个会把服务器的设备列表刷满,
                        //   续播会话也对不上。核心层的 config 里有一个,这里先用机器名兜底。
                        device_id = DeviceId(),
                    });
                }
                else
                {
                    // ★ 文件浏览型源走 source.login:它会先探一次再落盘,
                    //   探不通就不入库 —— 免得列表里躺着一台永远打不开的源。
                    await core.SourceLogin(new
                    {
                        kind,
                        base_url = kind == "local" ? (pickedDir.Text ?? "") : WithScheme(server.Text ?? ""),
                        username = user.Text ?? "",
                        password = pass.Text ?? "",
                    });
                }
                onDone();
            }
            catch (CoreException e) { hint.Text = e.Advice; Busy(false); }
            catch (Exception e) { hint.Text = e.Message; Busy(false); }
        };


        // 真机自检:LP_SELFCHECK_SOURCE=<源 kind> 直接切到那一种源的版式,
        // 用来验「本地源只有一个选择文件夹按钮」这类**只有真渲染才看得见**的判据。
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_SOURCE") is { Length: > 0 } wantKind)
        {
            var at = Array.FindIndex(kinds, k => k.Item2 == wantKind);
            if (at >= 0) { kindIndex = at; ApplyKind(); }
        }

        // 真机自检:LP_SELFCHECK_PAGE=login:<地址>|<用户名>|<密码> 直接填好并点登录。
        // ★ 不能靠 SendKeys —— 焦点落在哪儿不确定,实测一个字符都没进去。
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PAGE") is { } sc && sc.StartsWith("login:"))
        {
            var parts = sc["login:".Length..].Split('|');
            server.Text = parts.ElementAtOrDefault(0) ?? "";
            user.Text = parts.ElementAtOrDefault(1) ?? "";
            pass.Text = parts.ElementAtOrDefault(2) ?? "";
            AttachedToVisualTree += (_, _) => Dispatcher.UIThread.Post(() =>
                login.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent)));
        }

        /* ★ 打开就把光标放进第一个要填的框。首登闸口只有一件事可做,
           还要用户先点一下输入框,那一下点击是白让人做的(和搜索页同一条规矩)。
           ★ 必须等挂上可视树 —— 构造函数里 Focus() 是对着还没上屏的控件调,静默无效。 */
        AttachedToVisualTree += (_, _) => Dispatcher.UIThread.Post(() =>
        {
            if (serverRow.IsVisible) server.Focus();
        });

        Content = new Border
        {
            Padding = new Thickness(24),
            Child = new Border
            {
                Classes = { "card" },
                Width = 520,
                Padding = new Thickness(28),
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Child = form,
            },
        };
    }

    /// <summary>
    /// 地址补全:用户没写 <c>http://</c> 时补一个。
    ///
    /// <para>★★ 不补的表现是 Go 的 URL 解析直接报
    /// 「first path segment in URL cannot contain colon」—— 一句纯英文技术话,
    /// 而且它以前还被盖成「网络不通」。而 <c>192.168.1.10:8096</c> 是**最常见的输入**。</para>
    ///
    /// <para>★ 补在 UI 侧,<b>不动核心层的 NormServer</b> —— 那是黄金实现里
    /// 逐字移植过来的(Rust 版的 norm 也只 trim),动了会破坏差分对账基准。</para>
    ///
    /// <para>★ 默认补 <c>http://</c> 不是 https:内网 IP 和裸主机名绝大多数是 http;
    /// 补错了协议只会连不上,而补 https 到一台只有 http 的服务器上,
    /// 报的是看不懂的 TLS 错。</para>
    /// </summary>
    internal static string WithScheme(string raw)
    {
        var t = (raw ?? "").Trim();
        if (t.Length == 0) return t;
        if (t.StartsWith("http://", StringComparison.OrdinalIgnoreCase) ||
            t.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) return t;
        return "http://" + t;
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
