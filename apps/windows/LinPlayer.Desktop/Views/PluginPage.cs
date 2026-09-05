using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 插件(<c>UI_PC.md</c> §7.11)。一页三个 tab:市场 / 已装 / 源订阅 ——
/// 做成顶部 tab 而不是三个侧栏入口:「已装」经常是空的,空 tab 比空页面便宜。
///
/// <para>授权清单在装 / 启用之前弹,一行一条人话,而那些人话由核心层透出
/// (<c>plugin.permissionCatalog</c>),UI 这边不许抄一份 —— 抄了就会漏新权限,
/// 弹窗里显示成一个光秃秃的 <c>sources</c> 字符串。单个源拉不到只标那个源:
/// 一个挂掉的第三方源不该把整个市场变成一张报错页。</para>
/// </summary>
public sealed class PluginPage : PageBase
{
    private readonly CoreClient _core;

    private readonly StackPanel _marketBody = new() { Spacing = 10 };
    private readonly StackPanel _installedBody = new() { Spacing = 10 };
    private readonly StackPanel _sourcesBody = new() { Spacing = 10 };
    private readonly TextBlock _msg = Dim("");

    private List<JsonElement> _permCatalog = [];
    private readonly TabControl _tabs;

    /// <summary>自检用:重拉「已装」列表。</summary>
    public Task SelfCheckReload() => LoadInstalled();

    /// <summary>自检用:直接落到某个 tab(0 市场 / 1 已装 / 2 源订阅)。</summary>
    public void SelectTab(int i)
    {
        if (i >= 0 && i < _tabs.Items.Count) _tabs.SelectedIndex = i;
    }

    public PluginPage(CoreClient core)
    {
        _core = core;

        var tabs = new TabControl
        {
            Items =
            {
                new TabItem { Header = "市场", Content = Scrolled(_marketBody) },
                new TabItem { Header = "已装", Content = Scrolled(_installedBody) },
                new TabItem { Header = "源订阅", Content = Scrolled(_sourcesBody) },
            },
        };

        _tabs = tabs;

        Content = new DockPanel
        {
            LastChildFill = true,
            Children =
            {
                new StackPanel
                {
                    [DockPanel.DockProperty] = Dock.Top,
                    Margin = new Thickness(18, 18, 18, 0), Spacing = 10,
                    Children = { H1("插件"), _msg },
                },
                tabs,
            },
        };

        _ = LoadAll(false);
    }

    private async Task LoadAll(bool refresh)
    {
        // 权限词表先拿:授权弹窗要靠它把 id 翻成人话。
        try
        {
            var cat = await _core.PluginPermissionCatalog();
            if (cat.ValueKind == JsonValueKind.Array) _permCatalog = cat.EnumerateArray().ToList();
        }
        catch { /* 拿不到就退回显示原始 id,总比整页不出来强 */ }

        await LoadInstalled();
        await LoadSources();
        await LoadMarket(refresh);
    }

    // ---------------------------------------------------------------- 市场

    private async Task LoadMarket(bool refresh)
    {
        _marketBody.Children.Clear();
        _marketBody.Children.Add(Dim(refresh ? "重新拉取中…" : "加载中…"));
        JsonElement r;
        try { r = await _core.PluginMarketList(new { refresh }); }
        catch (Exception e)
        {
            Dispatcher.UIThread.Post(() =>
            {
                _marketBody.Children.Clear();
                _marketBody.Children.Add(Dim(LibraryPage.Advice(e)));
            });
            return;
        }

        var plugins = Arr(r, "plugins");
        var errors = Arr(r, "errors");

        Dispatcher.UIThread.Post(() =>
        {
            _marketBody.Children.Clear();

            var refreshBtn = new Button { Classes = { "ghost" }, Content = "刷新" };
            refreshBtn.Click += async (_, _) => await LoadMarket(true);
            _marketBody.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 10,
                Children = { refreshBtn, Dim($"共 {plugins.Count} 个插件") },
            });

            /* 单个源失败只标那个源。而且**警告条要和列表一起缓存** ——
               黄金实现第一版只缓存插件列表,切走再切回来(命中缓存)警告条就没了,
               剩下一个光秃秃的「没有找到插件」:用户第二次看到的是更没线索的页面。 */
            foreach (var e in errors)
            {
                // 「这个源挂了」和「这个源里有几条坏的」是两回事,措辞不能一样 ——
                // 后者其实拉成功了,写「拉取失败」的同时又画出卡片只会更糊涂。
                var skipped = Str(e, "kind") == "skipped";
                _marketBody.Children.Add(new Border
                {
                    Background = skipped
                        ? new SolidColorBrush(Color.FromArgb(34, 200, 180, 80))
                        : new SolidColorBrush(Color.FromArgb(40, 220, 120, 60)),
                    CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 10),
                    Child = Dim(skipped
                        ? $"源「{Str(e, "source")}」{Str(e, "error")}"
                        : $"源「{Str(e, "source")}」拉取失败:{Str(e, "error")}"),
                });
            }

            if (plugins.Count == 0)
            {
                _marketBody.Children.Add(Dim(errors.Count > 0
                    ? "启用的源都没能拉到内容。"
                    : "这些源里没有插件。可以到「源订阅」里加一个第三方源。"));
                return;
            }

            var grid = new ItemsControl { ItemsPanel = new FuncTemplate<Panel?>(() => new WrapPanel()) };
            grid.ItemsSource = plugins.Select(MarketCard).ToList();
            _marketBody.Children.Add(grid);
        });
    }

    private Control MarketCard(JsonElement p)
    {
        var id = Str(p, "id");
        var body = new StackPanel { Spacing = 6 };

        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        // 没图标就**别占位**:留一个 40px 的空白会让标题整体右移,
        // 同一排里有图标和没图标的卡片对不齐,看着像布局坏了。
        var icon = new Image { Width = 40, Height = 40, Stretch = Stretch.Uniform };
        LoadIcon(icon, Str(p, "icon"));
        if (icon.Source is not null) head.Children.Add(icon);
        var titles = new StackPanel { Spacing = 2 };
        titles.Children.Add(new TextBlock { Text = Str(p, "name"), FontWeight = FontWeight.SemiBold });
        titles.Children.Add(Dim(Str(p, "author")));
        head.Children.Add(titles);
        body.Children.Add(head);

        body.Children.Add(Dim(Str(p, "description")));

        // 第三方源要有**信任标记** —— 装第三方的包和装官方的包不是一回事。
        if (!Bool(p, "from_builtin"))
        {
            body.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(38, 200, 160, 60)),
                CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 2),
                HorizontalAlignment = HorizontalAlignment.Left,
                Child = new TextBlock { Text = $"第三方源:{Str(p, "source_name")}", FontSize = 11 },
            });
        }

        // 可装版本取**版本号最大值**,不是数组第一个 —— 上游返回顺序不可依赖。
        // 这一步在核心层做(plugin.marketInstall 不传 version 时自己挑),
        // 这里只显示;显示也得跟着挑,否则卡片写 1.2.0、装下去是 1.10.0。
        var best = BestVersion(p);
        body.Children.Add(Dim(best is null ? "没有当前版本能装的版本" : $"最新 {best.Value.Ver}"));

        var perms = Arr(p, "permissions").Select(x => x.GetString() ?? "").Where(s => s != "").ToList();
        var install = new Button { Content = "安装", MinHeight = 32, IsEnabled = best is not null };
        install.Click += async (_, _) =>
        {
            if (!await ConfirmPermissions(Str(p, "name"), perms, !Bool(p, "from_builtin"))) return;
            install.IsEnabled = false;
            install.Content = "安装中…";
            try
            {
                await _core.PluginMarketInstall(new { id });
                _msg.Text = $"「{Str(p, "name")}」已安装。到「已装」里启用它。";
                await LoadInstalled();
            }
            catch (Exception ex) { _msg.Text = LibraryPage.Advice(ex); }
            finally { install.IsEnabled = true; install.Content = "安装"; }
        };
        body.Children.Add(install);

        return new Border
        {
            Width = 280, Margin = new Thickness(0, 0, 14, 14), Padding = new Thickness(14),
            CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(Color.FromArgb(20, 255, 255, 255)),
            Child = body,
        };
    }

    // ---------------------------------------------------------------- 已装

    /// <summary>贡献了设置面板的插件 id。空 = 那个插件不出现「插件设置」按钮。</summary>
    private HashSet<string> _hasSettingsPanel = [];

    private async Task LoadInstalled()
    {
        List<JsonElement> list;
        try
        {
            var r = await _core.PluginList();
            list = r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().ToList() : [];
            /* 「有没有设置面板」要**问运行时注册表**,不能看 manifest 里的贡献点计数:
               panels 是一个笼统的计数,里面可能一个 settings 槽都没有 ——
               照计数画按钮的话,点进去是一片空白。 */
            _hasSettingsPanel = (await SettingsPanelsAsync())
                .Select(x => Str(x, "pluginId")).Where(s => s != "").ToHashSet();
        }
        catch (Exception e)
        {
            Dispatcher.UIThread.Post(() =>
            {
                _installedBody.Children.Clear();
                _installedBody.Children.Add(Dim(LibraryPage.Advice(e)));
            });
            return;
        }

        Dispatcher.UIThread.Post(() =>
        {
            _installedBody.Children.Clear();

            var fromFile = new Button { Classes = { "ghost" }, Content = "从文件安装 .ipk" };
            fromFile.Click += async (_, _) => await InstallFromFile();
            var devDir = new Button { Classes = { "ghost" }, Content = "挂一个开发目录" };
            devDir.Click += async (_, _) => await MountDevDir();
            _installedBody.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 10,
                Children = { fromFile, devDir },
            });

            if (list.Count == 0)
            {
                _installedBody.Children.Add(Dim("还没装插件。到「市场」看看。"));
                return;
            }
            foreach (var p in list) _installedBody.Children.Add(InstalledCard(p));
        });
    }

    private Control InstalledCard(JsonElement p)
    {
        var id = Str(p, "id");
        var enabled = Bool(p, "enabled");
        var body = new StackPanel { Spacing = 6 };

        var title = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        title.Children.Add(new TextBlock { Text = Str(p, "name"), FontWeight = FontWeight.SemiBold });
        title.Children.Add(Dim($"v{Str(p, "version")} · {Str(p, "author")}"));
        if (Bool(p, "dev")) title.Children.Add(Dim("[开发模式]"));
        body.Children.Add(title);

        if (Str(p, "description") != "") body.Children.Add(Dim(Str(p, "description")));

        /* 出错要**看得见**。onEnable 里踩到权限拒绝 / 写错一行,插件会注册到一半
           就中断,而卡片上如果只写「已启用」,用户看到的是面板永远空白、
           数据源少一半,没有任何线索。核心层已经把这句话挂在记录上了,照显。 */
        var err = Str(p, "error");
        if (err != "")
        {
            body.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(40, 220, 90, 90)),
                CornerRadius = new CornerRadius(10), Padding = new Thickness(14, 10),
                Child = Dim(err),
            });
        }

        // 启用后按贡献点给一句**「去哪用」** —— 否则用户启用完不知道发生了什么。
        if (enabled)
        {
            var where = WhereToUse(p);
            if (where != "") body.Children.Add(Dim(where));
        }

        var perms = Arr(p, "permissions").Select(x => x.GetString() ?? "").Where(s => s != "").ToList();

        var toggle = new Button { Content = enabled ? "禁用" : "启用", MinHeight = 32 };
        toggle.Click += async (_, _) =>
        {
            try
            {
                if (enabled) await _core.PluginDisable(new { id });
                else
                {
                    // 授权弹窗在**启用之前**,不是安装之后随便什么时候。
                    if (!await ConfirmPermissions(Str(p, "name"), perms, false)) return;
                    await _core.PluginEnable(new { id });
                }
                await LoadInstalled();
            }
            catch (Exception ex) { _msg.Text = LibraryPage.Advice(ex); }
        };

        var reload = new Button { Classes = { "ghost" }, Content = "重载", MinHeight = 32 };
        reload.Click += async (_, _) =>
        {
            try { await _core.PluginReload(new { id }); await LoadInstalled(); }
            catch (Exception ex) { _msg.Text = LibraryPage.Advice(ex); }
        };

        var uninstall = new Button { Classes = { "ghost" }, Content = "卸载", MinHeight = 32 };
        uninstall.Click += async (_, _) =>
        {
            // 卸载是不可逆的,必须二次确认(设置页那种「全页零二次确认」在这里不适用)。
            if (!await Confirm($"卸载「{Str(p, "name")}」?",
                    "插件文件和它保存的数据都会删掉。开发模式挂上的目录不会被删。")) return;
            try { await _core.PluginUninstall(new { id }); await LoadInstalled(); }
            catch (Exception ex) { _msg.Text = LibraryPage.Advice(ex); }
        };

        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children = { toggle, reload, uninstall },
        });

        // 插件自己贡献的设置面板放在**插件自己这里**,不是设置页的二级标签。
        // 没贡献设置面板时整块不出现。
        if (enabled && _hasSettingsPanel.Contains(id))
        {
            var open = new Button { Classes = { "ghost" }, Content = "插件设置", MinHeight = 32 };
            open.Click += async (_, _) => await OpenPluginSettings(id);
            ((StackPanel)body.Children[^1]).Children.Add(open);
        }

        return new Border
        {
            Padding = new Thickness(14), CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(Color.FromArgb(20, 255, 255, 255)),
            Child = body,
        };
    }

    /// <summary>启用后一句「去哪用」。按贡献点数量说,不猜。</summary>
    private static string WhereToUse(JsonElement p)
    {
        if (!p.TryGetProperty("contributes", out var c) || c.ValueKind != JsonValueKind.Object) return "";
        int N(string k) => c.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetInt32() : 0;
        var parts = new List<string>();
        if (N("dataSources") > 0) parts.Add($"在「添加服务器」里能看到它提供的 {N("dataSources")} 个源");
        if (N("panels") > 0) parts.Add($"贡献了 {N("panels")} 块界面");
        if (N("actions") > 0) parts.Add($"贡献了 {N("actions")} 个操作项");
        if (N("sandboxViews") > 0) parts.Add($"贡献了 {N("sandboxViews")} 个自定义界面");
        return parts.Count == 0 ? "" : string.Join(";", parts) + "。";
    }

    private async Task<List<JsonElement>> SettingsPanelsAsync()
    {
        try
        {
            var r = await _core.PluginPanels(new { slot = "settings" });
            return r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().ToList() : [];
        }
        catch { return []; }   // 插件没提供设置面板 = 空表,不是错误
    }

    private async Task OpenPluginSettings(string pluginId)
    {
        var panels = (await SettingsPanelsAsync())
            .Where(x => Str(x, "pluginId") == pluginId).ToList();
        if (panels.Count == 0) { _msg.Text = "这个插件没有贡献设置面板。"; return; }

        var body = new StackPanel { Spacing = 10 };
        foreach (var panel in panels)
        {
            var data = panel.TryGetProperty("data", out var d) ? d : default;
            var extId = Str(panel, "id");
            body.Children.Add(new TextBlock
            {
                Text = Str(data, "title") == "" ? extId : Str(data, "title"),
                FontWeight = FontWeight.SemiBold,
            });
            var result = Dim("");
            var run = new Button { Content = "打开", MinHeight = 32 };
            run.Click += async (_, _) =>
            {
                try
                {
                    var r = await _core.PluginInvokeField(new
                    {
                        plugin_id = pluginId, type_id = "panels", ext_id = extId, field = "load",
                    });
                    result.Text = r.ValueKind == JsonValueKind.Undefined || r.ValueKind == JsonValueKind.Null
                        ? "这个面板没有 load 处理函数。"
                        : r.ToString();
                }
                catch (Exception ex) { result.Text = LibraryPage.Advice(ex); }
            };
            body.Children.Add(run);
            body.Children.Add(result);
        }
        await ShowDialog($"插件设置", body, "关闭", null);
    }

    private async Task InstallFromFile()
    {
        var top = TopLevel.GetTopLevel(this);
        if (top is null) return;
        var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "选择插件包", AllowMultiple = false,
            FileTypeFilter = [new FilePickerFileType("LinPlayer 插件") { Patterns = ["*.ipk", "*.zip"] }],
        });
        if (files.Count == 0) return;
        try
        {
            // 选择器归 UI 层:核心层是个 DLL 弹不了对话框,所以路径由这边传进去
            // (和 system.pickFile 一个口径)。
            await _core.PluginPickInstall(new { path = files[0].Path.LocalPath });
            _msg.Text = "已安装。到「已装」里授权并启用。";
            await LoadInstalled();
        }
        catch (Exception e) { _msg.Text = LibraryPage.Advice(e); }
    }

    private async Task MountDevDir()
    {
        var top = TopLevel.GetTopLevel(this);
        if (top is null) return;
        var dirs = await top.StorageProvider.OpenFolderPickerAsync(new FolderPickerOpenOptions
        {
            Title = "选择插件源码目录", AllowMultiple = false,
        });
        if (dirs.Count == 0) return;
        try
        {
            await _core.PluginPickDevDir(new { path = dirs[0].Path.LocalPath });
            _msg.Text = "已挂上。改完源码存盘即可点「重载」。";
            await LoadInstalled();
        }
        catch (Exception e) { _msg.Text = LibraryPage.Advice(e); }
    }

    // ---------------------------------------------------------------- 源订阅

    private async Task LoadSources()
    {
        List<JsonElement> list;
        try
        {
            var r = await _core.PluginMarketSources();
            list = r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().ToList() : [];
        }
        catch (Exception e)
        {
            Dispatcher.UIThread.Post(() =>
            {
                _sourcesBody.Children.Clear();
                _sourcesBody.Children.Add(Dim(LibraryPage.Advice(e)));
            });
            return;
        }

        Dispatcher.UIThread.Post(() =>
        {
            _sourcesBody.Children.Clear();

            var name = new TextBox { Classes = { "field" }, Width = 180, Watermark = "名字(可留空)" };
            var url = new TextBox { Classes = { "field" }, Width = 380, Watermark = "registry.json 地址(https)" };
            var add = new Button { Content = "添加源", MinHeight = 34 };
            add.Click += async (_, _) =>
            {
                try
                {
                    await _core.PluginMarketAddSource(new { name = name.Text ?? "", url = url.Text ?? "" });
                    url.Text = ""; name.Text = "";
                    await LoadSources();
                    await LoadMarket(true);
                }
                catch (Exception ex) { _msg.Text = LibraryPage.Advice(ex); }
            };
            _sourcesBody.Children.Add(new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 10,
                Children = { name, url, add },
            });
            _sourcesBody.Children.Add(Dim(
                "插件源必须是 https(明文 http 只对本机开放)—— registry 决定装哪个包," +
                "被中途改一行就等于任意插件安装。"));

            foreach (var s in list) _sourcesBody.Children.Add(SourceRow(s));
        });
    }

    private Control SourceRow(JsonElement s)
    {
        var id = Str(s, "id");
        var builtin = Bool(s, "builtin");
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };

        var toggle = new CheckBox { IsChecked = Bool(s, "enabled"), MinWidth = 30 };
        toggle.IsCheckedChanged += async (_, _) =>
        {
            try
            {
                await _core.PluginMarketToggleSource(new { id, enabled = toggle.IsChecked == true });
                await LoadMarket(true);
            }
            catch (Exception ex) { _msg.Text = LibraryPage.Advice(ex); }
        };
        row.Children.Add(toggle);

        var texts = new StackPanel { Spacing = 2, Width = 520 };
        var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        head.Children.Add(new TextBlock { Text = Str(s, "name"), FontWeight = FontWeight.SemiBold });
        if (builtin) head.Children.Add(Dim("官方源"));
        texts.Children.Add(head);
        texts.Children.Add(Dim(Str(s, "url")));
        row.Children.Add(texts);

        // 官方源**可禁不可删** —— 删掉之后新用户开箱即空,再想找回来只能手打 URL。
        var del = new Button
        {
            Classes = { "ghost" }, Content = "删除", MinHeight = 32, IsEnabled = !builtin,
        };
        if (builtin) ToolTip.SetTip(del, "官方源不能删除,只能停用");
        del.Click += async (_, _) =>
        {
            try { await _core.PluginMarketRemoveSource(new { id }); await LoadSources(); await LoadMarket(true); }
            catch (Exception ex) { _msg.Text = LibraryPage.Advice(ex); }
        };
        row.Children.Add(del);

        return new Border { Padding = new Thickness(6, 6), Child = row };
    }

    // ---------------------------------------------------------------- 授权弹窗

    /// <summary>
    /// 授权清单。**一行一条人话**,文案来自核心层的权限词表。
    /// </summary>
    private async Task<bool> ConfirmPermissions(string pluginName, List<string> perms, bool thirdParty)
    {
        var body = new StackPanel { Spacing = 10, MaxWidth = 460 };
        body.Children.Add(Dim($"「{pluginName}」需要以下权限:"));

        if (thirdParty)
        {
            body.Children.Add(new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(38, 200, 160, 60)),
                CornerRadius = new CornerRadius(6), Padding = new Thickness(10, 6),
                Child = Dim("这个插件来自第三方源,不是官方源。装上之后它会以你的身份运行。"),
            });
        }

        if (perms.Count == 0)
            body.Children.Add(Dim("它没有申请任何权限。"));

        foreach (var pid in perms)
        {
            var def = _permCatalog.FirstOrDefault(x => Str(x, "id") == pid);
            var title = Str(def, "title");
            var desc = Str(def, "description");
            var dangerous = Bool(def, "dangerous");

            var line = new StackPanel { Spacing = 2 };
            line.Children.Add(new TextBlock
            {
                // 词表里没有这一条时退回显示原始 id —— 不能什么都不显示。
                Text = title == "" ? pid : (dangerous ? "⚠ " + title : title),
                FontWeight = FontWeight.SemiBold,
                Foreground = dangerous ? new SolidColorBrush(Color.FromRgb(230, 160, 70)) : null,
            });
            line.Children.Add(Dim(desc == "" ? $"(核心层没有给出 {pid} 的说明)" : desc));
            body.Children.Add(line);
        }

        return await ShowDialog("确认授权", body, "同意并继续", "取消");
    }

    private async Task<bool> Confirm(string title, string detail) =>
        await ShowDialog(title, Dim(detail), "确定", "取消");

    /// <summary>轻量模态框。Avalonia 没有内置的,自己搭一个 Window。</summary>
    /// <summary>弹窗搬进 <see cref="Dialogs"/> 了 —— 删服务器、删下载也要用同一个。</summary>
    private Task<bool> ShowDialog(string title, Control body, string okText, string? cancelText) =>
        Dialogs.Show(this, title, body, okText, cancelText);

    // ---------------------------------------------------------------- 小工具

    private static void LoadIcon(Image img, string icon)
    {
        if (icon == "") return;
        // registry 里的图标是**构建期内联的 data URI**(见核心层注释),
        // 所以这里不出网也不会碎图。
        const string prefix = "base64,";
        var i = icon.IndexOf(prefix, StringComparison.Ordinal);
        if (i < 0) return;
        try
        {
            var bytes = Convert.FromBase64String(icon[(i + prefix.Length)..]);
            using var ms = new MemoryStream(bytes);
            img.Source = new Bitmap(ms);
        }
        catch { /* 坏图标不影响卡片 */ }
    }

    private readonly record struct VerInfo(string Ver);

    private static VerInfo? BestVersion(JsonElement p)
    {
        VerInfo? best = null;
        string bestRaw = "";
        foreach (var v in Arr(p, "versions"))
        {
            var api = v.TryGetProperty("api_version", out var a) && a.ValueKind == JsonValueKind.Number
                ? a.GetInt32() : 0;
            if (api != 0 && api > 2) continue;   // 宿主 apiVersion = 2
            var ver = Str(v, "version");
            if (best is null || CompareSemver(ver, bestRaw) > 0) { best = new VerInfo(ver); bestRaw = ver; }
        }
        return best;
    }

    /// <summary>
    /// 语义化版本比较。**必须自己取最大,不能信数组顺序** ——
    /// 本仓库在 GitHub Releases 上栽过同一个跟头(三个键的返回顺序全是反的)。
    /// </summary>
    private static int CompareSemver(string a, string b)
    {
        static long[] Parse(string s)
        {
            var head = s.Split('-', '+')[0];
            return head.Split('.').Select(x => long.TryParse(x, out var n) ? n : 0).ToArray();
        }
        var (va, vb) = (Parse(a), Parse(b));
        for (var i = 0; i < Math.Max(va.Length, vb.Length); i++)
        {
            var x = i < va.Length ? va[i] : 0;
            var y = i < vb.Length ? vb[i] : 0;
            if (x != y) return x > y ? 1 : -1;
        }
        return 0;
    }

    private static List<JsonElement> Arr(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().ToList() : [];

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";

    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
}
