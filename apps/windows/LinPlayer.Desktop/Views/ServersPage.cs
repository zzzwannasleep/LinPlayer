using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 服务器管理(UI_PC §7.16)。切换 / 改名 / 备用线路 / 删除 / 再加一台。
///
/// <para>★ 身份键是 <c>server</c>(归一化后不带尾斜杠),三端既有的
/// <c>server_id</c> 参数就是它 —— <b>别换</b>。</para>
/// </summary>
public sealed class ServersPage : PageBase
{
    private readonly CoreClient _core;
    private readonly StackPanel _list = new() { Spacing = 12 };
    private readonly TextBlock _hint = new() { Classes = { "dim" }, TextWrapping = TextWrapping.Wrap };

    /// <summary>切服务器之后要让外壳重拉会话和侧栏 —— 不然整个应用还在用旧 token。</summary>
    private readonly Action _onSwitched;

    public ServersPage(CoreClient core, Action onSwitched)
    {
        _core = core; _onSwitched = onSwitched;

        var add = new Button { Classes = { "primary" }, Content = "＋ 添加服务器" };
        add.Click += (_, _) => Nav.Push(new AddServerPage(core, () =>
        {
            _onSwitched();
            Nav.Back();
        }));

        // 批量添加:贴一段开通信息 / 一条 linplayer:// 链接。
        var batch = new Button { Classes = { "ghost" }, Content = "批量添加 / 深链" };
        batch.Click += (_, _) => Nav.Push(new BatchAddPage(core, () =>
        {
            _onSwitched();
            Nav.Back();
        }));

        Content = Scrolled(new StackPanel
        {
            Spacing = 16,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 14,
                    Children = { H1("服务器"), add, batch },
                },
                _hint, _list,
            },
        });
        _ = Reload();
    }

    private async Task Reload()
    {
        JsonElement accounts;
        try { accounts = await _core.AccountListAccounts(); }
        catch (Exception e) { _hint.Text = LibraryPage.Advice(e); return; }

        var rows = accounts.ValueKind == JsonValueKind.Array ? accounts.EnumerateArray().ToList() : [];
        Dispatcher.UIThread.Post(() =>
        {
            _list.Children.Clear();
            if (rows.Count == 0) { _hint.Text = "还没有添加服务器。"; return; }
            _hint.Text = "";
            foreach (var a in rows) _list.Children.Add(Row(a));
            // 真机自检:自动点一下「测线路」—— 这条链路不点就永远没被跑过
            if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PAGE") == "servers:probe")
                _autoProbe?.Invoke();
        });
    }

    private Action? _autoProbe;

    private Control Row(JsonElement a)
    {
        var server = Str(a, "server");
        var active = a.TryGetProperty("active", out var ac) && ac.ValueKind == JsonValueKind.True;

        var name = new TextBox { Classes = { "field" }, Width = 260, Text = Str(a, "name") };
        var msg = new TextBlock { Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center };

        var use = new Button
        {
            Classes = { active ? "ghost" : "primary" },
            Content = active ? "使用中" : "切到这台",
            IsEnabled = !active,
        };
        use.Click += async (_, _) =>
        {
            try
            {
                await _core.AccountSetActiveServer(new { server_id = server });
                _onSwitched();
                await Reload();
            }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
        };

        var save = new Button { Classes = { "ghost" }, Content = "保存名称" };
        save.Click += async (_, _) =>
        {
            try
            {
                await _core.AccountUpdateAccount(new { server_id = server, name = name.Text ?? "" });
                msg.Text = "已保存。";
                _onSwitched();
            }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
        };

        // ★ 「允许自签名」必须有个入口。核心层的白名单已经接好了(net/tlspolicy),
        //   但界面上没开关的话用户根本用不上 —— 自建 Emby 用自签名证书很常见,
        //   而报出来的是一句看不懂的 x509 英文。
        var insecure = new CheckBox
        {
            Content = "允许这台服务器的自签名证书",
            IsChecked = a.TryGetProperty("allow_insecure_tls", out var ai) && ai.ValueKind == JsonValueKind.True,
            VerticalAlignment = VerticalAlignment.Center,
        };
        insecure.IsCheckedChanged += async (_, _) =>
        {
            try
            {
                await _core.AccountUpdateAccount(new
                {
                    server_id = server, allow_insecure_tls = insecure.IsChecked == true,
                });
                msg.Text = insecure.IsChecked == true
                    ? "已允许自签名证书(只对这台生效)。" : "已恢复严格校验。";
            }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
        };

        var probe = new Button { Classes = { "ghost" }, Content = "测线路" };
        _autoProbe ??= () => probe.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        probe.Click += async (_, _) =>
        {
            msg.Text = "测速中…";
            try
            {
                var r = await _core.AccountProbeLines(new { server_id = server });
                msg.Text = Describe(r);
            }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
        };

        // 换图标 —— 进图标库(§7.17),挑一张网络图标或上传本地图片。
        var icon = new Button { Classes = { "ghost" }, Content = "换图标" };
        icon.Click += (_, _) => Nav.Push(new IconLibraryPage(_core, server, () =>
        {
            _onSwitched();
            _ = Reload();
        }));

        // ★ 删除要二次确认。设置页整体是「零二次确认」的,但**删账号是不可逆的**,
        //   这一条是例外 —— 误点一下要重新登录一台服务器。
        var del = new Button { Classes = { "ghost" }, Content = "删除" };
        del.Click += async (_, _) =>
        {
            if ((string?)del.Content == "删除") { del.Content = "确认删除?"; return; }
            try
            {
                await _core.AccountRemoveAccount(new { server_id = server });
                _onSwitched();
                await Reload();
            }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); del.Content = "删除"; }
        };

        var lines = Arr(a, "lines");
        var lineText = lines.Count == 0
            ? "只用主地址"
            : $"{lines.Count} 条备用线路,当前第 {Num(a, "active_line") + 1} 条";

        return new Border
        {
            Classes = { "card" }, Padding = new Thickness(16), MaxWidth = 900,
            HorizontalAlignment = HorizontalAlignment.Left,
            Child = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal, Spacing = 10,
                        Children =
                        {
                            name,
                            new TextBlock
                            {
                                // ★ 用户名要显出来:同一台服务器上两个账号,只看服务器名分不清
                                Text = Str(a, "user_name"), Classes = { "dim" },
                                VerticalAlignment = VerticalAlignment.Center,
                            },
                        },
                    },
                    new TextBlock
                    {
                        // 地址本身要显示 —— 用户加错地址时,这是唯一能自己看出来的地方
                        Text = Str(a, "line_url") is { Length: > 0 } l ? l : server,
                        Classes = { "dim" }, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                    },
                    new TextBlock { Text = lineText, Classes = { "dim" }, FontSize = 12 },
                    insecure,
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal, Spacing = 10,
                        Children = { use, save, icon, probe, del, msg },
                    },
                },
            },
        };
    }

    /// <summary>
    /// 把测线路的结果说成人话。
    ///
    /// <para>★ 判「通不通」看的是 <c>ms</c> 是不是 <b>null</b>,不是有没有 ok 字段 ——
    /// 核心层就是拿 null 表示不通的(写成 0 的话「秒回」和「不通」长得一样)。</para>
    /// </summary>
    private static string Describe(JsonElement r)
    {
        if (r.ValueKind != JsonValueKind.Array) return "测完了。";
        var bits = r.EnumerateArray().Select(x =>
        {
            var url = Str(x, "url");
            var up = x.TryGetProperty("ms", out var m) && m.ValueKind == JsonValueKind.Number;
            return up ? $"{url} {m.GetDouble():0} ms" : $"{url} 不通";
        });
        return string.Join(" · ", bits);
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
    private static List<JsonElement> Arr(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().ToList() : [];
}
