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
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 首页(UI_PC §7.1):继续观看 → 媒体库轨 → 各库最新。
///
/// <para>★★ <b>各块各自渲染,不设屏障</b>。「不秒加载」的根因从来不是动画,
/// 是加载结构:一个 <c>Promise.all</c> 屏障就能把最快的那块拖到最慢的那块之后
/// (实测 5.5 倍差距)。所以这里每条轨道**自己拉自己的**,谁先回来谁先出现。</para>
/// </summary>
public sealed class HomePage : PageBase
{
    private readonly CoreClient? _core;
    private readonly StackPanel _rows = new() { Spacing = 26 };

    public HomePage(CoreClient? core)
    {
        _core = core;
        Content = Scrolled(_rows);
        if (core is not null) _ = LoadAsync(core);
    }

    private async Task LoadAsync(CoreClient core)
    {
        // 会话:命令层现在还要显式传(迁移期形状),从活跃账号里取
        JsonElement session;
        try { session = await core.EmbyCurrentSession(); }
        catch (Exception e) { AddRow(Dim($"读会话失败:{e.Message}")); return; }

        if (session.ValueKind != JsonValueKind.Object)
        {
            AddRow(Dim("当前账号不是 Emby(网盘 / 局域网源的首页还没做)。"));
            return;
        }
        var s = new
        {
            server = Str(session, "server"),
            token = Str(session, "token"),
            user_id = Str(session, "user_id"),
            device_id = "linplayer-desktop",
        };

        // ★ 三块并发发出去,各自渲染 —— 谁先回来谁先出现,不互相等
        var resume = Track("继续观看", () => core.EmbyListResume(new { s.server, s.token, s.user_id, s.device_id, limit = 12 }), true);
        var views = Track("媒体库", () => core.EmbyViews(new { s.server, s.token, s.user_id, s.device_id }), true);
        var latest = Track("最新加入", () => core.EmbyListLatest(new { s.server, s.token, s.user_id, s.device_id, limit = 16 }), false);
        await Task.WhenAll(resume, views, latest);
    }

    private async Task Track(string title, Func<Task<JsonElement>> load, bool wide)
    {
        var host = new StackPanel { Spacing = 10 };
        var body = new TextBlock { Classes = { "dim" }, Text = "加载中…" };
        host.Children.Add(H2(title));
        host.Children.Add(body);
        AddRow(host);

        try
        {
            var data = await load();
            var items = data.ValueKind == JsonValueKind.Array ? data.EnumerateArray().ToList() : [];
            Dispatcher.UIThread.Post(() =>
            {
                host.Children.Remove(body);
                if (items.Count == 0)
                {
                    // ★ 空态要说清「为什么空」,不是干放一句「暂无数据」(§6.4)
                    host.Children.Add(Dim($"这台服务器上没有「{title}」的内容。"));
                    return;
                }
                host.Children.Add(Strip(items, wide));
            });
        }
        catch (CoreException e)
        {
            Dispatcher.UIThread.Post(() => body.Text = $"{title}加载失败:{e.Advice}");
        }
        catch (Exception e)
        {
            Dispatcher.UIThread.Post(() => body.Text = $"{title}加载失败:{e.Message}");
        }
    }

    /// <summary>横向轨道。宽卡 240×135(16:9),窄卡 150×225(2:3)—— UI_PC §3.2。</summary>
    private static Control Strip(List<JsonElement> items, bool wide)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        foreach (var it in items.Take(20)) panel.Children.Add(Card(it, wide));
        return new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = panel,
        };
    }

    private static Control Card(JsonElement it, bool wide)
    {
        var name = Str(it, "name");
        var series = Str(it, "series_name");
        // ★ 分集的 Name 只是「第 35 集」,单看无意义 —— 混排列表里必须靠剧名才说得清是哪部剧
        var title = string.IsNullOrEmpty(series) ? name : $"{series} · {name}";

        var w = wide ? 240 : 150;
        var h = wide ? 135 : 225;

        var art = new Border
        {
            Width = w, Height = h, CornerRadius = new CornerRadius(10),
            Background = new SolidColorBrush(Color.Parse("#1b212c")),
            Child = new TextBlock
            {
                Text = name,
                Classes = { "dim" },
                Margin = new Thickness(10),
                TextWrapping = TextWrapping.Wrap,
                VerticalAlignment = VerticalAlignment.Center,
                HorizontalAlignment = HorizontalAlignment.Center,
                TextAlignment = TextAlignment.Center,
            },
        };

        return new StackPanel
        {
            Width = w, Spacing = 6,
            Children =
            {
                art,
                new TextBlock
                {
                    Text = title, FontSize = 12.5, MaxLines = 2,
                    TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
                },
            },
        };
    }

    private void AddRow(Control c) => Dispatcher.UIThread.Post(() => _rows.Children.Add(c));

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}
