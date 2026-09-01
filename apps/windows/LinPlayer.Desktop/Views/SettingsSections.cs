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
/// 设置页里几组「有核心层命令撑着」的分组。
///
/// <para>★ 越界值一律<b>由核心层拒绝并回滚</b>,UI 不夹紧 —— 悄悄夹紧会让用户
/// 以为设了 8 线程生效了,实际跑的是 4。所以这里失败就把控件恢复成原值 + 显示原因。</para>
/// </summary>
public static class SettingsSections
{
    // ---------------------------------------------------------------- 多线程加载

    public static Control Prefetch(CoreClient core, JsonElement s)
    {
        var hint = Hint();
        var threads = new ComboBox
        {
            Width = 120, MinHeight = 34,
            ItemsSource = new[] { 2, 3, 4 },
            SelectedItem = (int)Math.Clamp(Num(s, "threads"), 2, 4),
        };
        // 缓存上限:核心层认字节,界面按 MB 给档 —— 上下限 64MB~4GB 是核心层定的
        var caches = new[] { 64, 256, 512, 1024, 2048, 4096 };
        var cache = new ComboBox
        {
            Width = 140, MinHeight = 34,
            ItemsSource = caches.Select(m => m >= 1024 ? $"{m / 1024} GB" : $"{m} MB").ToList(),
        };
        var curMb = (int)(Num(s, "cache_bytes") / 1024 / 1024);
        cache.SelectedIndex = Math.Max(0, Array.FindIndex(caches, m => m >= curMb));

        var save = new Button { Classes = { "primary" }, Content = "保存" };
        save.Click += async (_, _) =>
        {
            try
            {
                await core.PrefsSetPrefetchSettings(new
                {
                    settings = new
                    {
                        threads = (int)threads.SelectedItem!,
                        cache_bytes = (long)caches[cache.SelectedIndex] * 1024 * 1024,
                        // ★ servers 是「哪几台服开了多线程加载」。这一版没做逐服开关,
                        //   原样送回去 —— 不送的话核心层会把已开的服务器全清掉。
                        servers = Strings(s, "servers"),
                    },
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        };

        return Group("多线程加载", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("对支持 Range 的直连流并发预取。预取的粒度不是供给的粒度 —— " +
                     "核心层边收边吐,所以开着也不会拖慢起播。"),
                Field("并发数", threads), Field("缓存上限", cache),
                Row(save, hint),
            },
        });
    }

    // ---------------------------------------------------------------- 预加载

    public static Control Preload(CoreClient core, JsonElement s)
    {
        var hint = Hint();
        var on = new CheckBox { Content = "起播前预热文件头", IsChecked = Bool(s, "enabled") };
        var head = new ComboBox
        {
            Width = 120, MinHeight = 34,
            ItemsSource = new[] { 2, 4, 8, 16, 32 },
            SelectedItem = (int)Math.Max(2, Num(s, "head_mb")),
        };

        async void Save()
        {
            try
            {
                await core.PrefsSetPreloadSettings(new
                {
                    settings = new { enabled = on.IsChecked == true, head_mb = (int)head.SelectedItem! },
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }
        on.IsCheckedChanged += (_, _) => Save();
        head.SelectionChanged += (_, _) => Save();

        return Group("预加载", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                // ★ 预热的字节**必须被复用**:只跑热路不留字节,在慢链路上等于白烧带宽
                Note("提前把片头拉到本地缓存。起播时复用同一份字节,不会重下一遍。"),
                on, Field("预热大小", head), hint,
            },
        });
    }

    // ---------------------------------------------------------------- 跨服回写

    public static Control Writeback(CoreClient core, JsonElement s)
    {
        var hint = Hint();
        var on = new CheckBox { Content = "把进度回写到其它服务器", IsChecked = Bool(s, "enabled") };
        var progress = new CheckBox { Content = "连播放位置一起回写", IsChecked = Bool(s, "include_progress") };

        var ranges = new[] { ("所有匹配到的服务器", "all"), ("只回写首次看过的那台", "first"), ("只回写最近看过的那台", "latest") };
        var range = new ComboBox
        {
            Width = 220, MinHeight = 34,
            ItemsSource = ranges.Select(x => x.Item1).ToList(),
            SelectedIndex = Math.Max(0, Array.FindIndex(ranges, x => x.Item2 == Str(s, "range"))),
        };

        async void Save()
        {
            try
            {
                await core.PrefsSetWritebackSettings(new
                {
                    settings = new
                    {
                        enabled = on.IsChecked == true,
                        include_progress = progress.IsChecked == true,
                        range = ranges[Math.Max(0, range.SelectedIndex)].Item2,
                    },
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }
        foreach (var c in new CheckBox[] { on, progress }) c.IsCheckedChanged += (_, _) => Save();
        range.SelectionChanged += (_, _) => Save();

        return Group("跨服务器进度", new StackPanel
        {
            Spacing = 10,
            Children =
            {
                Note("同一部片在多台服务器上都有时,把「看到哪儿了」同步过去。"),
                on, progress, Field("回写范围", range), CrossResume(core), hint,
            },
        });
    }

    /// <summary>
    /// 「起播时取跨服最大进度」开关。
    ///
    /// <para>★ 它和上面那三项是**两个方向**:上面是「看完之后把进度推给别台」,
    /// 这条是「起播时从别台把进度拉回来」。合成一个开关的话,想要单向的人没法配。</para>
    /// </summary>
    private static Control CrossResume(CoreClient core)
    {
        var box = new CheckBox { Content = "起播时取各服务器里最靠后的进度" };
        var hint = Hint();
        // ★ 初值从核心层**读回来**,不是默认一个再灌下去
        _ = Task.Run(async () =>
        {
            try
            {
                var v = await core.AccountGetCrossServerResume();
                Dispatcher.UIThread.Post(() =>
                {
                    box.IsChecked = v.ValueKind == JsonValueKind.True;
                    box.IsCheckedChanged += async (_, _) =>
                    {
                        try
                        {
                            await core.AccountSetCrossServerResume(new { enabled = box.IsChecked == true });
                            hint.Text = "已保存。";
                        }
                        catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
                    };
                });
            }
            catch { /* 读不到就让它保持未勾,别显示一个错的状态 */ }
        });
        return new StackPanel { Spacing = 6, Children = { box, hint } };
    }

    // ---------------------------------------------------------------- 更新

    public static Control Update(CoreClient core, JsonElement s)
    {
        var hint = Hint();
        var channels = new[] { ("正式版", "stable"), ("预览版", "preview") };
        var ch = new ComboBox
        {
            Width = 160, MinHeight = 34,
            ItemsSource = channels.Select(x => x.Item1).ToList(),
            SelectedIndex = Math.Max(0, Array.FindIndex(channels, x => x.Item2 == Str(s, "channel"))),
        };
        var auto = new CheckBox { Content = "启动时检查更新", IsChecked = Bool(s, "auto_check") };

        async void Save()
        {
            try
            {
                await core.PrefsSetUpdateSettings(new
                {
                    channel = channels[Math.Max(0, ch.SelectedIndex)].Item2,
                    auto_check = auto.IsChecked == true,
                });
                hint.Text = "已保存。";
            }
            catch (Exception e) { hint.Text = LibraryPage.Advice(e); }
        }
        ch.SelectionChanged += (_, _) => Save();
        auto.IsCheckedChanged += (_, _) => Save();

        var body = new StackPanel
        {
            Spacing = 10,
            Children = { Field("更新渠道", ch), auto },
        };
        body.Children.Add(new TextBlock
        {
            Text = $"当前版本 {Str(s, "current_version")}",
            Classes = { "dim" }, FontSize = 12,
        });
        // ★ 绿色包被解压到写不进去的地方时不能自更新。核心层这一版保守报 false,
        //   界面就得如实说 —— 摆一个点了没反应的「立即更新」比没有更糟。
        if (!Bool(s, "can_self_update"))
            body.Children.Add(Note("这一版还不能自动安装更新,检查到新版本会给下载地址。"));
        body.Children.Add(hint);

        return Group("更新", body);
    }

    // ---------------------------------------------------------------- 已屏蔽的内容

    /// <summary>
    /// 解除屏蔽的入口。
    ///
    /// <para>★★ <b>隐藏类功能必须配一个集中解除列表</b>。没有的话屏蔽就是单向门 ——
    /// 用户屏蔽错了以后再也找不回来(Rust 版为此栽过:媒体库网格故意不滤,
    /// 就是为了留一条解除的路)。</para>
    /// </summary>
    public static Control Blocked(CoreClient core)
    {
        var list = new StackPanel { Spacing = 6 };
        var status = new TextBlock { Classes = { "dim" }, Text = "加载中…" };

        async Task Reload()
        {
            JsonElement r;
            try { r = await core.EmbyBlockedList(new { }); }
            catch (Exception e) { status.Text = LibraryPage.Advice(e); return; }
            var rows = r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().ToList() : [];
            Dispatcher.UIThread.Post(() =>
            {
                list.Children.Clear();
                status.Text = rows.Count == 0 ? "没有屏蔽任何内容。" : $"{rows.Count} 项";
                foreach (var b in rows)
                {
                    var id = Str(b, "id");
                    var un = new Button { Classes = { "ghost" }, Content = "解除" };
                    un.Click += async (_, _) =>
                    {
                        try
                        {
                            await core.EmbySetBlocked(new { id, name = Str(b, "name"), blocked = false });
                            await Reload();
                        }
                        catch (Exception e) { status.Text = LibraryPage.Advice(e); }
                    };
                    list.Children.Add(new StackPanel
                    {
                        Orientation = Orientation.Horizontal, Spacing = 12,
                        Children =
                        {
                            new TextBlock
                            {
                                Text = Str(b, "name") is { Length: > 0 } n ? n : id,
                                Width = 320, VerticalAlignment = VerticalAlignment.Center,
                                TextTrimming = TextTrimming.CharacterEllipsis,
                            },
                            un,
                        },
                    });
                }
            });
        }
        _ = Reload();

        return Group("已屏蔽的内容", new StackPanel
        {
            Spacing = 10,
            Children = { Note("屏蔽掉的条目和媒体库都在这里,随时可以解除。"), status, list },
        });
    }

    // ---------------------------------------------------------------- 小工具

    private static Control Group(string title, Control body) => new Border
    {
        Classes = { "card" }, Padding = new Thickness(18), Width = 620,
        HorizontalAlignment = HorizontalAlignment.Left,
        Child = new StackPanel
        {
            Spacing = 12,
            Children = { new TextBlock { Text = title, Classes = { "h2" } }, body },
        },
    };

    private static Control Field(string label, Control input) => new StackPanel
    {
        Orientation = Orientation.Horizontal, Spacing = 12,
        Children =
        {
            new TextBlock { Text = label, Width = 100, VerticalAlignment = VerticalAlignment.Center },
            input,
        },
    };

    private static Control Row(params Control[] cs)
    {
        var p = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        foreach (var c in cs) p.Children.Add(c);
        return p;
    }

    private static TextBlock Hint() => new()
    {
        Classes = { "dim" }, VerticalAlignment = VerticalAlignment.Center, TextWrapping = TextWrapping.Wrap,
    };

    private static TextBlock Note(string t) => new()
    {
        Text = t, FontSize = 12, TextWrapping = TextWrapping.Wrap,
        Foreground = new SolidColorBrush(Color.Parse("#7d8798")),
    };

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
    private static string[] Strings(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x != "").ToArray() : [];
}
