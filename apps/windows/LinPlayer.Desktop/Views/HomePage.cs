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

    /// <param name="title">页头。给当前服务器名 —— 见下面那段注释。</param>
    public HomePage(CoreClient? core, Action<CardItem>? onOpen = null, string title = "首页")
    {
        _core = core;
        _onOpen = onOpen;
        /* ★ 首页也要有页头:媒体库 / 搜索都有 H1,唯独首页没有,三页来回切的时候
           首页会显得「上面缺了一块」。
           ★ 写**服务器名**而不是干写「首页」:这是个多服务器播放器,
             「我现在在看哪台」是真信息;「首页」两个字侧栏已经说过一遍了。
           ★ 名字由外面传进来,不在这儿再拉一次账号表 —— 壳里已经拉过了
             (UpdateServerChip),再拉一次就是每次进首页多一次往返。 */
        _rows.Children.Add(H1(title));
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
        /* ★★ 占位用**骨架**,不是「加载中…」。
           三个字只有 20px 高,内容一回来这一行从 20px 撑到 280px,
           下面几条轨道全被顶下去 —— 用户正看着的东西会跳走。
           骨架和真卡同尺寸,换上去是「填色」而不是「撑开」。 */
        var host = new StackPanel { Spacing = 10 };
        Control body = Skeleton.Strip(wide);
        host.Children.Add(H2(title));
        host.Children.Add(body);
        AddRow(host);

        void Swap(Control with) => Dispatcher.UIThread.Post(() =>
        {
            var at = host.Children.IndexOf(body);
            if (at < 0) return;
            host.Children[at] = with;
            body = with;
        });

        try
        {
            var items = await load();
            // ★ 空态要说清「为什么空」,不是干放一句「暂无数据」(§6.4)
            Swap(items.Count == 0 ? Dim($"这台服务器上没有「{title}」的内容。") : Strip(items, wide));
        }
        catch (CoreException e) { Swap(Dim($"{title}加载失败:{e.Advice}")); }
        catch (Exception e) { Swap(Dim($"{title}加载失败:{e.Message}")); }
    }

    /// <summary>
    /// 横向轨道。宽卡 256×144(16:9),窄卡 158×237(2:3)。
    ///
    /// <para>★ 交给 <see cref="Carousel"/> 包一层翻页按钮 —— <b>光有滚轮不够</b>:
    /// 一条轨道 20 张卡,屏幕上只看得到五六张,后面十几张没有任何东西
    /// 告诉用户它们存在。</para>
    /// </summary>
    private Control Strip(List<JsonElement> items, bool wide)
    {
        using var _ = Core.Perf.Measure($"造 {Math.Min(items.Count, 20)} 张卡");
        var panel = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
        foreach (var it in items.Take(20))
            panel.Children.Add(new Card(_core!, _server, CardItem.From(it), wide, _onOpen));
        // 图区高度:翻页按钮要对齐图的中线,不是整张卡的中线(卡下面还有两行标题)
        var w = wide ? 256.0 : 158.0;
        return Carousel.Wrap(panel, wide ? w * 9 / 16 : w * 3 / 2);
    }

    private void AddRow(Control c) => Dispatcher.UIThread.Post(() => _rows.Children.Add(c));

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}
