using System.Text.Json;
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
/// 聚合视界:每台服务器一张卡(规模统计 + 继续观看)。
///
/// <para>统计和继续观看是<b>各自吞错</b>的 —— 某台服的 <c>/Items/Counts</c> 在
/// 某些 fork 上根本不存在,那一格显示不出来不该把整页拖红。</para>
/// </summary>
public sealed class AggregatePage : PageBase
{
    public AggregatePage(CoreClient core)
    {
        var rows = new StackPanel { Spacing = 18, Children = { H1("聚合视界") } };
        var busy = Dim("加载中…");
        rows.Children.Add(busy);
        Content = Scrolled(rows);

        _ = Task.Run(async () =>
        {
            JsonElement r;
            try { r = await core.EmbyAggregateOverview(new { }); }
            catch (Exception e)
            {
                Dispatcher.UIThread.Post(() => busy.Text = $"加载失败:{LibraryPage.Advice(e)}");
                return;
            }
            var cards = r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().ToList() : [];
            Dispatcher.UIThread.Post(() =>
            {
                rows.Children.Remove(busy);
                if (cards.Count == 0) { rows.Children.Add(Dim("还没有添加服务器。")); return; }
                foreach (var c in cards) rows.Children.Add(CardOf(core, c));
            });
        });
    }

    private static Control CardOf(CoreClient core, JsonElement c)
    {
        var server = Str(c, "server_id");
        var name = Str(c, "server_name");
        var active = c.TryGetProperty("active", out var ac) && ac.ValueKind == JsonValueKind.True;
        var browse = c.TryGetProperty("is_file_browse", out var fb) && fb.ValueKind == JsonValueKind.True;

        var head = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children =
            {
                H2(name + (active ? "  ·  使用中" : "")),
            },
        };

        var body = new StackPanel { Spacing = 10, Children = { head } };

        if (browse)
        {
            // 浏览型源(网盘 / 局域网)没有统计,也没有继续观看 —— 说清楚,别留空白
            body.Children.Add(Dim("文件浏览型的源,没有规模统计和继续观看。"));
            return Wrap(body);
        }

        var counts = c.TryGetProperty("counts", out var k) ? k : default;
        var bits = new List<string>();
        if (Num(counts, "movie") > 0) bits.Add($"电影 {Num(counts, "movie"):0}");
        if (Num(counts, "series") > 0) bits.Add($"剧集 {Num(counts, "series"):0}");
        if (Num(counts, "episode") > 0) bits.Add($"分集 {Num(counts, "episode"):0}");
        if (Num(counts, "boxset") > 0) bits.Add($"合集 {Num(counts, "boxset"):0}");
        // 统计端点 404 时这里就是空的 —— 显示「统计不可用」而不是「0 部电影」
        body.Children.Add(Dim(bits.Count > 0 ? string.Join("  ·  ", bits) : "这台服务器没有提供规模统计。"));

        var resume = c.TryGetProperty("resume", out var rs) && rs.ValueKind == JsonValueKind.Array
            ? rs.EnumerateArray().Select(CardItem.From).ToList() : [];
        if (resume.Count > 0)
        {
            var strip = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            foreach (var it in resume.Take(12))
                strip.Children.Add(new Card(core, server, it, true, LibraryPage.OpenDetail(core, server)));
            body.Children.Add(new ScrollViewer
            {
                HorizontalScrollBarVisibility = ScrollBarVisibility.Auto,
                VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
                Content = strip,
            });
        }
        else
        {
            body.Children.Add(Dim("这台服务器上没有在看的内容。"));
        }
        return Wrap(body);
    }

    private static Control Wrap(Control body) => new Border
    {
        Classes = { "card" }, Padding = new Thickness(18), Child = body,
    };

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
}

/// <summary>
/// 观看历史。
///
/// <para>这份历史是<b>本地库</b>,不是服务器的播放记录 —— 跨服续播就靠它。
/// 所以「当前服务器」和「全部」是两种看法,都要有。</para>
/// </summary>
public sealed class HistoryPage : PageBase
{
    public HistoryPage(CoreClient core)
    {
        var only = new CheckBox { Content = "只看当前服务器", IsChecked = true };
        var list = new StackPanel { Spacing = 10 };
        var status = Dim("加载中…");
        var scanHint = Dim("");

        /* 扫描恢复:换服 / 重装之后把本地记录推回服务器。
            报告里的 errors 必须显示出来。这条链路最危险的 bug 是
             「不崩,只是悄悄少恢复了几条」—— 只报个成功数的话没人会发现。
            prompt_candidates 是**要用户拍板**的那一批(可能匹配但不确定):
             自动写下去的后果是把进度写到另一部片上,而且看起来一切正常。
             这一版先如实报个数,逐条确认的界面待做。 */
        var scan = new Button { Classes = { "ghost" }, Content = "扫描恢复到当前服务器" };
        scan.Click += async (_, _) =>
        {
            scan.IsEnabled = false;
            scanHint.Text = "扫描中…(逐条比对,可能要十几秒)";
            try
            {
                var r = await core.EmbyWatchHistoryScanRestore(new { });
                var errs = r.TryGetProperty("errors", out var e) && e.ValueKind == JsonValueKind.Array
                    ? e.EnumerateArray().Select(x => x.GetString() ?? "").ToList() : [];
                var prompts = r.TryGetProperty("prompt_candidates", out var pc) && pc.ValueKind == JsonValueKind.Array
                    ? pc.GetArrayLength() : 0;
                var msg = $"扫了 {Num(r, "scanned"):0} 条,自动恢复 {Num(r, "auto_restored"):0} 条";
                if (prompts > 0) msg += $",{prompts} 条拿不准(需要人工确认)";
                if (errs.Count > 0) msg += $"。{errs.Count} 条出错:{string.Join(";", errs.Take(3))}";
                scanHint.Text = msg;
            }
            catch (Exception ex) { scanHint.Text = LibraryPage.Advice(ex); }
            finally { scan.IsEnabled = true; }
        };

        Content = Scrolled(new StackPanel
        {
            Spacing = 14,
            Children =
            {
                H1("观看历史"),
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { only, scan },
                },
                scanHint, status, list,
            },
        });

        async Task Load()
        {
            status.Text = "加载中…";
            list.Children.Clear();
            JsonElement r;
            try { r = await core.EmbyWatchHistoryList(new { current_only = only.IsChecked == true }); }
            catch (Exception e) { status.Text = LibraryPage.Advice(e); return; }

            var recs = r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().ToList() : [];
            // 最近看的排前面。核心层不保证顺序,排序是展示层的事。
            recs.Sort((a, b) => Num(b, "last_played_at").CompareTo(Num(a, "last_played_at")));

            Dispatcher.UIThread.Post(() =>
            {
                status.Text = recs.Count == 0 ? "还没有观看记录。" : $"{recs.Count} 条";
                foreach (var rec in recs.Take(200)) list.Children.Add(RowOf(rec));
            });
        }

        only.IsCheckedChanged += (_, _) => _ = Load();
        _ = Load();
    }

    private static Control RowOf(JsonElement rec)
    {
        var title = Str(rec, "title");
        var series = Str(rec, "series_title");
        var head = string.IsNullOrEmpty(series) ? title : $"{series} · {title}";

        // ticks 是 100 纳秒单位 —— 除以 1e7 才是秒。写成 1e6 的话时长会大十倍且不报错。
        var pos = Num(rec, "last_position_ticks") / 1e7;
        var run = Num(rec, "run_time_ticks") / 1e7;
        var when = Num(rec, "last_played_at");

        var right = run > 0 ? $"{Clock(pos)} / {Clock(run)}" : Clock(pos);
        if (rec.TryGetProperty("played", out var p) && p.ValueKind == JsonValueKind.True) right = "已看完";

        return new Border
        {
            Classes = { "card" }, Padding = new Thickness(14, 10),
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 14,
                Children =
                {
                    new TextBlock { Text = head, Width = 460, TextTrimming = TextTrimming.CharacterEllipsis },
                    new TextBlock { Text = right, Classes = { "dim" }, Width = 150 },
                    new TextBlock
                    {
                        // last_played_at 是**毫秒**(core/history/store.go 的 nowMs)。
                        // 当秒读的话时间会跳到五万多年后 —— 不报错,只是日期离谱。
                        Text = when > 0
                            ? DateTimeOffset.FromUnixTimeMilliseconds((long)when).LocalDateTime.ToString("yyyy-MM-dd HH:mm")
                            : "",
                        Classes = { "dim" },
                    },
                },
            },
        };
    }

    private static string Clock(double s) =>
        s >= 3600 ? $"{(int)s / 3600}:{(int)s / 60 % 60:00}:{(int)s % 60:00}"
                  : $"{(int)s / 60}:{(int)s % 60:00}";

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
}
