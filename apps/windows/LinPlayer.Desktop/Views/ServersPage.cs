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
/// 服务器管理(UI_PC §7.16)。
///
/// <para>★ 身份键是 <c>server</c>(归一化后不带尾斜杠),三端既有的
/// <c>server_id</c> 参数就是它 —— <b>别换</b>。</para>
///
/// <para>★★ 一张卡 = <b>一台服务器的全部</b>:概览(名字 / 用户 / 地址 / 版本 / 线路数)
/// 摊在外面,四组编辑动作(信息 / 线路 / 图标 / 重新登录)收进抽屉,一次只开一个。
/// 全平铺的话一台服务器十几个控件,三台就是四十几个 —— 那不是管理页,那是控件墙;
/// 而这一页 90% 的来访只是为了「切到另一台」。</para>
/// </summary>
public sealed class ServersPage : PageBase
{
    private readonly CoreClient _core;
    private readonly StackPanel _list = new() { Spacing = 12 };
    private readonly TextBlock _hint = new() { Classes = { "dim" }, TextWrapping = TextWrapping.Wrap };

    /// <summary>切服务器之后要让外壳重拉会话和侧栏 —— 不然整个应用还在用旧 token。</summary>
    private readonly Action _onSwitched;

    /// <summary>只显示这一台(右键菜单进来的)。空 = 全表。</summary>
    private readonly string? _focus;

    /// <summary>进来就把这个抽屉拉开(edit / lines / icon / relogin / probe)。</summary>
    private readonly string? _drawer;

    /// <param name="focus">
    /// 只编辑这一台。
    /// <para>★★ 2026-09-03 之后<b>这一页不再是导航目的地</b> —— 服务器已经排在侧栏里,
    /// 编辑动作从右键菜单进来,而右键点的是**某一台**。
    /// 这时候再列出全表,用户还得在里面重新找一遍自己刚点的那台。</para>
    /// </param>
    /// <param name="drawer">进来就拉开哪个抽屉。右键菜单点的是哪一项就是哪一个。</param>
    public ServersPage(CoreClient core, Action onSwitched, string? focus = null, string? drawer = null)
    {
        _core = core; _onSwitched = onSwitched;
        _focus = string.IsNullOrEmpty(focus) ? null : focus;
        _drawer = string.IsNullOrEmpty(drawer) ? null : drawer;

        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 14 };
        if (_focus is null)
        {
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
            head.Children.Add(H1("服务器"));
            head.Children.Add(add);
            head.Children.Add(batch);
        }
        else
        {
            // 定点编辑:标题写「编辑服务器」,并给一个回首页的出口 ——
            // ★ 这一页现在是从右键菜单进来的,Nav.Root 清了栈,没有返回键就出不去了。
            var back = new Button { Classes = { "ghost" }, Content = "← 完成" };
            back.Click += (_, _) => Nav.Root(new HomePage(core,
                Nav.Session is null ? null : LibraryPage.OpenDetail(core, Nav.Session.server)));
            head.Children.Add(H1("编辑服务器"));
            head.Children.Add(back);
        }

        Content = Scrolled(new StackPanel
        {
            Spacing = 16,
            Children = { head, _hint, _list },
        });
        _ = Reload();
    }

    private async Task Reload()
    {
        JsonElement accounts;
        try { accounts = await _core.AccountListAccounts(); }
        catch (Exception e) { _hint.Text = LibraryPage.Advice(e); return; }

        var rows = accounts.ValueKind == JsonValueKind.Array ? accounts.EnumerateArray().ToList() : [];
        if (_focus is not null) rows = rows.Where(a => Str(a, "server") == _focus).ToList();
        Dispatcher.UIThread.Post(() =>
        {
            _list.Children.Clear();
            _openDrawer.Clear();
            _autoProbe = null;
            if (rows.Count == 0)
            {
                _hint.Text = _focus is null ? "还没有添加服务器。" : "这台服务器已经不在账号表里了。";
                return;
            }
            _hint.Text = "";
            foreach (var a in rows) _list.Children.Add(Row(a));

            /* 进来就拉开指定的抽屉。两个来源:
               ①右键菜单点的那一项(<see cref="_drawer"/>);
               ②真机自检 LP_SELFCHECK_PAGE=servers:lines 之类。
               ★ 收起来的东西**截图里等于不存在** —— 四组编辑排没排齐、
                 线路表那一行四个控件会不会挤成一团,不拉开一次就永远没人看过。 */
            var want = _drawer;
            if (want is null)
            {
                var env = Environment.GetEnvironmentVariable("LP_SELFCHECK_PAGE") ?? "";
                if (env.StartsWith("servers:")) want = env["servers:".Length..];
            }
            if (want == "probe") _autoProbe?.Invoke();
            else if (want is not null && _openDrawer.TryGetValue(want, out var open)) open();
        });
    }

    private Action? _autoProbe;

    /// <summary>自检用:抽屉名 → 把它拉开。只记第一台服务器的。</summary>
    private readonly Dictionary<string, Action> _openDrawer = new();

    private Control Row(JsonElement a)
    {
        var server = Str(a, "server");
        var active = a.TryGetProperty("active", out var ac) && ac.ValueKind == JsonValueKind.True;
        var lines = Arr(a, "lines");
        var msg = new TextBlock { Classes = { "dim" }, TextWrapping = TextWrapping.Wrap };

        // ══════════ ① 信息卡:这台服务器是什么、还活着吗 ══════════
        /* ★★ 「服务器信息卡」原来是没有的 —— 卡上只有一个改名框和一串地址。
           用户在这一页要回答的第一个问题是「这台是哪台、还连得上吗」,
           而版本 / 在线状态一个都没写。这里补上,**用 testConnection 现探**:
           它不要 token,所以**token 已经失效的账号也探得出来** ——
           而那恰恰是最需要看到状态的时候。 */
        var vitals = new TextBlock { Classes = { "dim" }, FontSize = 12, Text = "正在探测…" };
        _ = Probe(server, vitals);

        var title = new TextBlock
        {
            Text = Str(a, "name"), FontSize = 16, FontWeight = FontWeight.SemiBold,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var who = new TextBlock
        {
            // ★ 用户名在**这里**写(侧栏那份 2026-09-02 按用户要求去掉了)——
            //   同一台服务器上两个账号,只看服务器名分不清,而这一页正是分辨它们的地方。
            Text = Str(a, "user_name"), Classes = { "dim" }, FontSize = 12.5,
            VerticalAlignment = VerticalAlignment.Center,
        };
        var badge = new Border
        {
            IsVisible = active, Padding = new Thickness(8, 2), CornerRadius = new CornerRadius(999),
            Background = new SolidColorBrush(Color.Parse("#295b8def")),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                Text = "使用中", FontSize = 11.5,
                Foreground = new SolidColorBrush(Color.Parse("#5b8def")),
            },
        };
        var remark = Str(a, "remark");
        var addr = new TextBlock
        {
            // 地址本身要显示 —— 用户加错地址时,这是唯一能自己看出来的地方
            Text = Str(a, "line_url") is { Length: > 0 } l ? l : server,
            Classes = { "dim" }, FontSize = 12, TextWrapping = TextWrapping.Wrap,
        };

        // ══════════ ② 抽屉:四组编辑,一次只开一个 ══════════
        var drawer = new ContentControl { IsVisible = false, Margin = new Thickness(0, 6, 0, 0) };
        var openName = "";
        var tabs = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };

        void SyncTabs()
        {
            foreach (var c in tabs.Children)
                if (c is Button b) b.Classes.Set("on", (string?)b.Tag == openName);
        }
        void Toggle(string name, Func<Control> make)
        {
            /* ★ 同一个按钮再点一次就收起来。没有这一下的话抽屉打开之后
               唯一的关法是切到另一个抽屉 —— 用户会一直找那个不存在的关闭键。 */
            if (openName == name) { openName = ""; drawer.IsVisible = false; SyncTabs(); return; }
            openName = name;
            drawer.Content = make();
            drawer.IsVisible = true;
            SyncTabs();
        }
        Button Tab(string name, string label, Func<Control> make)
        {
            var b = new Button { Classes = { "chip" }, Content = label, Tag = name };
            b.Click += (_, _) => Toggle(name, make);
            _openDrawer.TryAdd(name, () => Toggle(name, make));
            return b;
        }

        // ══════════ ③ 顶上那排动作 ══════════
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

        var probe = new Button { Classes = { "ghost" }, Content = "测线路" };
        _autoProbe ??= () => probe.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));
        probe.Click += async (_, _) =>
        {
            msg.Text = "测速中…";
            try { msg.Text = Describe(await _core.AccountProbeLines(new { server_id = server })); }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
        };

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

        tabs.Children.Add(Tab("edit", "编辑信息", () => EditInfo(a, server, title, msg)));
        tabs.Children.Add(Tab("lines", "编辑线路", () => EditLines(a, server, msg)));
        tabs.Children.Add(Tab("icon", "编辑图标", () => EditIcon(server)));
        tabs.Children.Add(Tab("relogin", "重新登录", () => Relogin(a, server, msg)));

        var body = new StackPanel { Spacing = 10 };
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children = { title, badge, who },
        });
        // ★ 没写备注就整行不画 —— 留一行空的等于每张卡都高一行,而且看着像没加载出来
        if (remark != "")
            body.Children.Add(new TextBlock { Text = remark, Classes = { "dim" }, FontSize = 12.5 });
        body.Children.Add(addr);
        body.Children.Add(vitals);
        body.Children.Add(new TextBlock
        {
            Text = lines.Count == 0
                ? "只用主地址"
                : $"{lines.Count} 条备用线路,当前第 {Num(a, "active_line") + 1} 条",
            Classes = { "dim" }, FontSize = 12,
        });
        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Margin = new Thickness(0, 2, 0, 0),
            Children = { use, probe, del },
        });
        body.Children.Add(tabs);
        body.Children.Add(drawer);
        body.Children.Add(msg);

        return new Border
        {
            Classes = { "card" }, Padding = new Thickness(16),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Child = body,
        };
    }

    /// <summary>
    /// 探一次这台服务器:在线状态 + 服务器自报名 + 版本。
    ///
    /// <para>★ 失败就写「连不上」并把原因写出来,不留空:一行空白说不清是
    /// 「还没探」还是「探失败了」。</para>
    /// </summary>
    private async Task Probe(string server, TextBlock target)
    {
        try
        {
            var info = await _core.AccountTestConnection(new { server });
            var bits = new List<string> { "在线" };
            if (Str(info, "name") is { Length: > 0 } n) bits.Add(n);
            if (Str(info, "version") is { Length: > 0 } v) bits.Add("版本 " + v);
            Dispatcher.UIThread.Post(() => target.Text = string.Join("  ·  ", bits));
        }
        catch (Exception e)
        {
            var why = LibraryPage.Advice(e);
            Dispatcher.UIThread.Post(() => target.Text = "连不上 —— " + why);
        }
    }

    // ───────────────────────────────────────────────── 抽屉:编辑信息

    /// <summary>
    /// 改显示名和备注。
    /// <para>★ 备注是核心层早就存着的字段(<c>Account.Remark</c>,<c>account.updateAccount</c>
    /// 也早就收这个键),之前 UI 一直没接 —— 这正是本仓最常见的那类缺口:
    /// 后端有、前端没接,而且两边都不报错。</para>
    /// </summary>
    private Control EditInfo(JsonElement a, string server, TextBlock title, TextBlock msg)
    {
        var name = new TextBox { Classes = { "field" }, Text = Str(a, "name"), Watermark = "显示名" };
        var remark = new TextBox
        {
            Classes = { "field" }, Text = Str(a, "remark"),
            Watermark = "备注(只给自己看,比如「朋友的服务器 / 只放动画」)",
        };
        // ★ 「允许自签名」必须有个入口。核心层的白名单已经接好了(net/tlspolicy),
        //   但界面上没开关的话用户根本用不上 —— 自建 Emby 用自签名证书很常见,
        //   而报出来的是一句看不懂的 x509 英文。
        var insecure = new CheckBox
        {
            Content = "允许这台服务器的自签名证书",
            IsChecked = a.TryGetProperty("allow_insecure_tls", out var ai) && ai.ValueKind == JsonValueKind.True,
        };
        var save = new Button
        {
            Classes = { "primary" }, Content = "保存",
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        save.Click += async (_, _) =>
        {
            try
            {
                await _core.AccountUpdateAccount(new
                {
                    server_id = server, name = name.Text ?? "", remark = remark.Text ?? "",
                    allow_insecure_tls = insecure.IsChecked == true,
                });
                title.Text = name.Text ?? "";
                msg.Text = "已保存。";
                _onSwitched();
            }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
        };
        return Drawer("编辑信息", name, remark, insecure, save);
    }

    // ───────────────────────────────────────────────── 抽屉:编辑线路

    /// <summary>
    /// 线路表编辑:改名 / 改地址 / 删 / 加 / 切到某条 / 从服务器同步。
    ///
    /// <para>★★ 核心层的 <c>account.setLines</c> 是<b>整表替换</b>,所以这里也整表提交 ——
    /// 逐条增删改的话,某一条提交失败就会留下一个「界面上有、配置里没有」的线路。</para>
    ///
    /// <para>★ 「切到这条」单独走 <c>setActiveLine</c>,不混在保存里:
    /// 改地址和换线路是两件事,合成一次提交的话会出现「改到一半就被切走了」。</para>
    ///
    /// <para>★ 同步回来 <c>added=0</c> 是**正常结果**,不是失败 ——
    /// 绝大多数服务器没部署那个端点。这里如实说,不弹红字。</para>
    /// </summary>
    private Control EditLines(JsonElement a, string server, TextBlock msg)
    {
        var rows = new StackPanel { Spacing = 8 };
        var activeLine = (int)Num(a, "active_line");
        var items = Arr(a, "lines");

        void AddRow(string nm, string url, bool isActive)
        {
            var n = new TextBox { Classes = { "field" }, Width = 150, Text = nm, Watermark = "线路名" };
            var u = new TextBox
            {
                Classes = { "field" }, Text = url, Watermark = "http://线路地址",
                Margin = new Thickness(8, 0, 8, 0),
                HorizontalAlignment = HorizontalAlignment.Stretch,
            };
            var pick = new Button
            {
                Classes = { isActive ? "primary" : "ghost" },
                Content = isActive ? "使用中" : "切到这条", IsEnabled = !isActive,
            };
            var rm = new Button
            {
                Classes = { "ghost" }, Content = "✕", Margin = new Thickness(8, 0, 0, 0),
            };
            var row = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto,Auto") };
            Grid.SetColumn(n, 0); Grid.SetColumn(u, 1); Grid.SetColumn(pick, 2); Grid.SetColumn(rm, 3);
            row.Children.Add(n); row.Children.Add(u); row.Children.Add(pick); row.Children.Add(rm);
            rm.Click += (_, _) => rows.Children.Remove(row);
            pick.Click += async (_, _) =>
            {
                // ★ 下标按**当前列表里的位置**算,不是建这一行时的位置 ——
                //   中间删过一条的话两者就不一样了,而切错线路是静默的。
                var at = rows.Children.IndexOf(row);
                try
                {
                    await _core.AccountSetActiveLine(new { server_id = server, index = at });
                    _onSwitched();
                    await Reload();
                }
                catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
            };
            rows.Children.Add(row);
        }

        for (var i = 0; i < items.Count; i++)
            AddRow(Str(items[i], "name"), Str(items[i], "url"), i == activeLine);
        if (items.Count == 0)
            rows.Children.Add(new TextBlock
            {
                Classes = { "dim" }, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                Text = "还没有备用线路。加一条之后,主地址连不上时可以手动切过去。",
            });

        var addLine = new Button { Classes = { "ghost" }, Content = "＋ 加一条" };
        addLine.Click += (_, _) =>
        {
            // 第一次加时要把那句空态提示撤掉,否则它会一直顶在列表最上面
            if (rows.Children.Count == 1 && rows.Children[0] is TextBlock) rows.Children.Clear();
            AddRow("", "", false);
        };

        var sync = new Button { Classes = { "ghost" }, Content = "从服务器同步" };
        sync.Click += async (_, _) =>
        {
            msg.Text = "正在同步…";
            try
            {
                var r = await _core.AccountSyncLines(new { server_id = server });
                var n = r.TryGetProperty("added", out var v) && v.ValueKind == JsonValueKind.Number
                    ? v.GetInt32() : 0;
                msg.Text = n > 0 ? $"同步到 {n} 条新线路。" : "这台服务器没有提供线路表。";
                if (n > 0) await Reload();
            }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
        };

        var save = new Button { Classes = { "primary" }, Content = "保存线路表" };
        save.Click += async (_, _) =>
        {
            var payload = rows.Children.OfType<Grid>()
                .Select(g => new
                {
                    name = ((TextBox)g.Children[0]).Text ?? "",
                    url = ((TextBox)g.Children[1]).Text ?? "",
                })
                .Where(x => x.url.Trim() != "")
                .ToArray();
            try
            {
                await _core.AccountSetLines(new { server_id = server, lines = payload });
                msg.Text = $"已保存 {payload.Length} 条线路。";
                _onSwitched();
                await Reload();
            }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
        };

        return Drawer("编辑线路", rows, new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children = { save, addLine, sync },
        });
    }

    // ───────────────────────────────────────────────── 抽屉:图标 / 重新登录

    private Control EditIcon(string server)
    {
        var go = new Button
        {
            Classes = { "primary" }, Content = "打开图标库…",
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        go.Click += (_, _) => Nav.Push(new IconLibraryPage(_core, server, () =>
        {
            _onSwitched();
            _ = Reload();
        }));
        return Drawer("编辑图标",
            new TextBlock
            {
                Classes = { "dim" }, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                Text = "从图标库里挑一张,或者上传本机图片。图标只影响这一页和侧栏的显示。",
            },
            go);
    }

    /// <summary>
    /// 重新登录:token 过期时**定点换凭据**。
    ///
    /// <para>★★ 走 <c>emby.relogin</c> 而<b>不是</b> <c>emby.login</c>。
    /// 后者是 Upsert 语义,会把这台当成「新登录的」处理 ——
    /// 用户改过的服务器名 / 备注 / 图标 / 线路表全被冲回原样。
    /// 核心层为此专门单列了一条命令,而 UI 一直没接(30 条零调用命令里的一条)。</para>
    ///
    /// <para>★ 用户名预填成当前这个:绝大多数情况是同一个账号 token 过期,
    /// 让人重新打一遍用户名是白让人做的。</para>
    /// </summary>
    private Control Relogin(JsonElement a, string server, TextBlock msg)
    {
        var user = new TextBox { Classes = { "field" }, Text = Str(a, "user_name"), Watermark = "用户名" };
        var pass = new TextBox { Classes = { "field" }, Watermark = "密码", PasswordChar = '●' };
        var go = new Button
        {
            Classes = { "primary" }, Content = "重新登录",
            HorizontalAlignment = HorizontalAlignment.Left,
        };
        go.Click += async (_, _) =>
        {
            go.IsEnabled = false;
            msg.Text = "正在登录…";
            try
            {
                var r = await _core.EmbyRelogin(new
                {
                    server_id = server, username = user.Text ?? "", password = pass.Text ?? "",
                });
                msg.Text = $"已换成新的登录凭据({Str(r, "user_name")})。";
                _onSwitched();
                await Reload();
            }
            catch (Exception e) { msg.Text = LibraryPage.Advice(e); }
            finally { go.IsEnabled = true; }
        };
        return Drawer("重新登录",
            new TextBlock
            {
                Classes = { "dim" }, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                Text = "服务器提示未授权 / 登录失效时用这个。它只换凭据 —— "
                     + "你改过的名称、备注、图标和线路表都保留。",
            },
            user, pass, go);
    }

    /// <summary>抽屉的外壳:一块浅一层的面板 + 小标题。</summary>
    private static Control Drawer(string title, params Control[] body)
    {
        var sp = new StackPanel { Spacing = 10 };
        sp.Children.Add(new TextBlock
        {
            Text = title, FontSize = 13, FontWeight = FontWeight.SemiBold,
        });
        foreach (var c in body) sp.Children.Add(c);
        return new Border
        {
            Background = new SolidColorBrush(Color.Parse("#1b212c")),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(14),
            Child = sp,
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
