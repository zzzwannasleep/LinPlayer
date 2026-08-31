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
    private readonly StackPanel _rows = new() { Spacing = 26 };
    private readonly Action<CardItem>? _onOpen;
    private CoreClient? _core;
    private string _server = "";

    public HomePage(CoreClient? core, Action<CardItem>? onOpen = null)
    {
        _core = core;
        _onOpen = onOpen;
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
        _server = Str(session, "server");
        var s = new
        {
            server = _server,
            token = Str(session, "token"),
            user_id = Str(session, "user_id"),
            device_id = "linplayer-desktop",
        };

        // ★ 各块并发发出去,各自渲染 —— 谁先回来谁先出现,不互相等
        var resume = Track("继续观看", () => ResumeAndNextUp(core, s), true);
        var views = Track("媒体库", () => Arr(core.EmbyViews(new { s.server, s.token, s.user_id, s.device_id })), true);
        var latest = Track("最新加入", () => Arr(core.EmbyListLatest(new { s.server, s.token, s.user_id, s.device_id, limit = 16 })), false);
        var random = Track("随便看看", () => Arr(core.EmbyListRandom(new { s.server, s.token, s.user_id, s.device_id, limit = 8 })), false);
        await Task.WhenAll(resume, views, latest, random);
    }

    /// <summary>
    /// 「继续观看」= <b>看了一半的</b> + <b>接着看下一集</b>,合并成一条轨道。
    ///
    /// <para>★★ 按剧去重,<b>看了一半的优先</b>。同一部剧不该出现两张卡 ——
    /// 「第 3 集看了一半」和「下一集是第 4 集」是同一件事的两种说法,
    /// 而用户继续看一部剧只有一个正确入口。不去重的话追一部剧会看到两张卡,
    /// 点哪张都对不上自己的预期。</para>
    ///
    /// <para>★ 去重键优先用 <c>series_id</c>(分集),没有就用条目自己的 id(电影)。
    /// 只按 id 去重是不够的:同一部剧的第 3 集和第 4 集 id 不同,照样会出两张。</para>
    ///
    /// <para>★ 这里的 <c>WhenAll</c> 是**这一条轨道内部**的屏障 —— 去重要求两份数据
    /// 都到齐,这是数据本身的要求。其它几条轨道照旧各自渲染,不受它拖累。</para>
    ///
    /// <para>★ 两条各自吞错:NextUp 在某些 fork 上没有,不能因此把「看了一半」也弄没。</para>
    /// </summary>
    private static async Task<List<JsonElement>> ResumeAndNextUp(CoreClient core, object s)
    {
        var a = Arr(core.EmbyListResume(With(s, new { limit = 12 })));
        var b = Arr(core.EmbyListNextUp(With(s, new { limit = 12 })));
        var resume = await Safe(a);
        var nextUp = await Safe(b);

        var seen = new HashSet<string>();
        var outp = new List<JsonElement>();
        foreach (var it in resume.Concat(nextUp))
        {
            var key = Str(it, "series_id") is { Length: > 0 } sid ? "s:" + sid : "i:" + Str(it, "id");
            if (seen.Add(key)) outp.Add(it);
        }
        return outp;
    }

    /// <summary>失败当空表 —— 合并的两条里挂了一条,不该把另一条也弄没。</summary>
    private static async Task<List<JsonElement>> Safe(Task<List<JsonElement>> t)
    {
        try { return await t; }
        catch { return []; }
    }

    private static async Task<List<JsonElement>> Arr(Task<JsonElement> t)
    {
        var d = await t;
        return d.ValueKind == JsonValueKind.Array ? d.EnumerateArray().ToList() : [];
    }

    /// <summary>把会话四件套和额外参数并成一个字典(匿名类型合不了)。</summary>
    private static Dictionary<string, object?> With(object sess, object extra)
    {
        var d = new Dictionary<string, object?>();
        foreach (var p in sess.GetType().GetProperties()) d[p.Name] = p.GetValue(sess);
        foreach (var p in extra.GetType().GetProperties()) d[p.Name] = p.GetValue(extra);
        return d;
    }

    private async Task Track(string title, Func<Task<List<JsonElement>>> load, bool wide)
    {
        var host = new StackPanel { Spacing = 10 };
        var body = new TextBlock { Classes = { "dim" }, Text = "加载中…" };
        host.Children.Add(H2(title));
        host.Children.Add(body);
        AddRow(host);

        try
        {
            var items = await load();
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
    private Control Strip(List<JsonElement> items, bool wide)
    {
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        foreach (var it in items.Take(20))
            panel.Children.Add(new Card(_core!, _server, CardItem.From(it), wide, _onOpen));
        return new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = panel,
        };
    }

    private void AddRow(Control c) => Dispatcher.UIThread.Post(() => _rows.Children.Add(c));

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}
