using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 下载页(<c>UI_PC.md</c> §7.9)。
///
/// <para>★★ 两个正相反的语义,<b>不许合并</b>:</para>
/// <list type="bullet">
/// <item><b>「清除已完成」只清记录,不删文件</b> —— 用户点它是想收拾列表。</item>
/// <item><b>每条右边的 ✕ 是删文件</b> —— 那是不可逆的,所以要二次确认。</item>
/// </list>
///
/// <para>★ 并发数<b>归核心层持久化,UI 只读不灌</b>。旧架构要在挂载时把值回灌引擎,
/// 否则「pill 显示 3、引擎实际跑 2」双重撒谎。现在核心层自己存(下载索引里),
/// 本页挂载时<b>读回来</b>而不是猜一个再灌下去。</para>
/// </summary>
public sealed class DownloadPage : PageBase
{
    private readonly CoreClient _core;
    private readonly StackPanel _rows = new() { Spacing = 8 };
    private readonly TextBlock _status = Dim("");
    private readonly ComboBox _threads = new() { Width = 130, MinHeight = 34 };
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(1) };

    private bool _building;

    public DownloadPage(CoreClient core)
    {
        _core = core;

        foreach (var n in new[] { 1, 2, 3, 4 })
            _threads.Items.Add(new ComboBoxItem { Content = $"{n} 线程", Tag = n });
        _threads.SelectionChanged += (_, _) =>
        {
            if (_building) return;
            if (_threads.SelectedItem is ComboBoxItem { Tag: int n }) _ = SetThreads(n);
        };

        var clear = new Button { Content = "清除已完成", Classes = { "ghost" }, MinHeight = 34 };
        clear.Click += (_, _) => _ = ClearCompleted();

        Content = Scrolled(new StackPanel
        {
            Spacing = 14,
            Children =
            {
                H1("下载"),
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { _threads, clear },
                },
                _status,
                _rows,
            },
        });

        // ★ 并发数**从核心层读回来**,不是 UI 猜一个再灌下去。
        //   猜的话就是「pill 显示 3、引擎实际跑 2」双重撒谎(UI_PC §7.9)。
        _ = LoadThreads();

        // ★ 进度**不是推送的**,轮询。一个活跃下载不值得为它开一条事件流。
        _poll.Tick += (_, _) => _ = Refresh();
        AttachedToVisualTree += (_, _) => _poll.Start();
        DetachedFromVisualTree += (_, _) => _poll.Stop();
        _ = Refresh();
    }

    /// <summary>读回核心层当前的并发数。不传 threads = 只读(见核心层那条命令的注释)。</summary>
    private async Task LoadThreads()
    {
        try
        {
            var r = await _core.DownloadSetThreads(new { });
            if (r.ValueKind == JsonValueKind.Object && r.TryGetProperty("threads", out var got))
                SelectThreads(got.GetInt32());
        }
        catch { /* 读不到就让下拉空着,总比显示一个错的数强 */ }
    }

    private async Task SetThreads(int n)
    {
        try
        {
            var r = await _core.DownloadSetThreads(new { threads = n });
            // ★ 回读**实际生效**的档位。核心层会把它钳在 1~4;
            //   不回读的话,用户设了个越界值、界面显示成功、引擎跑的是另一个数。
            if (r.ValueKind == JsonValueKind.Object && r.TryGetProperty("threads", out var got))
                SelectThreads(got.GetInt32());
        }
        catch (Exception e) { _status.Text = LibraryPage.Advice(e); }
    }

    private void SelectThreads(int n)
    {
        _building = true;
        for (var i = 0; i < _threads.ItemCount; i++)
            if (_threads.Items[i] is ComboBoxItem { Tag: int v } && v == n)
                _threads.SelectedIndex = i;
        _building = false;
    }

    private async Task ClearCompleted()
    {
        try
        {
            var r = await _core.DownloadClearCompleted();
            var n = r.ValueKind == JsonValueKind.Number ? r.GetInt32() : 0;
            _status.Text = n > 0 ? $"清掉了 {n} 条记录(文件还在)。" : "没有已完成的任务。";
            await Refresh();
        }
        catch (Exception e) { _status.Text = LibraryPage.Advice(e); }
    }

    private async Task Refresh()
    {
        JsonElement arr;
        try { arr = await _core.DownloadList(); }
        catch (Exception e) { _status.Text = LibraryPage.Advice(e); return; }

        var items = arr.ValueKind == JsonValueKind.Array ? arr.EnumerateArray().ToList() : [];
        Dispatcher.UIThread.Post(() =>
        {
            _rows.Children.Clear();
            if (items.Count == 0)
            {
                _status.Text = "还没有下载任务。在详情页点「下载」加进来。";
                return;
            }
            if (!_status.Text!.StartsWith("清掉了")) _status.Text = "";
            foreach (var it in items) _rows.Children.Add(Row(it));
        });
    }

    private Control Row(JsonElement it)
    {
        var id = Str(it, "id");
        var status = Str(it, "status");
        var got = Num(it, "received_bytes");
        var total = Num(it, "total_bytes");
        var progress = it.TryGetProperty("progress", out var p) && p.ValueKind == JsonValueKind.Number
            ? p.GetDouble() : 0;

        var bar = new ProgressBar
        {
            Minimum = 0, Maximum = 1, Value = progress, Height = 4,
            // ★ 未知大小时进度条要**不确定态**,不是停在 0 ——
            //   停在 0 看起来像卡住了,而它其实在下
            IsIndeterminate = total <= 0 && status == "downloading",
        };

        var line2 = new TextBlock
        {
            FontSize = 12, Opacity = 0.6,
            Text = StatusText(status, got, total, Str(it, "error")),
        };

        var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (status is "downloading" or "queued")
        {
            var pause = new Button { Content = "暂停", Classes = { "ghost" } };
            pause.Click += (_, _) => _ = Act(() => _core.DownloadPause(new { id }));
            actions.Children.Add(pause);
        }
        else if (status is "paused" or "failed")
        {
            var resume = new Button { Content = "继续", Classes = { "ghost" } };
            resume.Click += (_, _) => _ = Act(() => _core.DownloadResume(new { id }));
            actions.Children.Add(resume);
        }

        // ★★ 删除是**不可逆**的(连文件一起删),所以要二次确认。
        //    设置页全页零二次确认是有意的,而这里是那条规则的例外 —— 同「删除服务器」。
        var del = new Button { Content = "✕", Classes = { "ghost" } };
        del.Click += (_, _) =>
        {
            if (del.Content as string == "✕")
            {
                del.Content = "确认删除?";
                return;
            }
            _ = Act(() => _core.DownloadRemove(new { id }));
        };
        actions.Children.Add(del);

        return new Border
        {
            Classes = { "card" },
            Padding = new Thickness(14, 12),
            Child = new StackPanel
            {
                Spacing = 8,
                Children =
                {
                    new Grid
                    {
                        ColumnDefinitions = new ColumnDefinitions("*,Auto"),
                        Children =
                        {
                            new TextBlock
                            {
                                Text = Title(it), FontSize = 13.5,
                                TextTrimming = TextTrimming.CharacterEllipsis,
                                VerticalAlignment = VerticalAlignment.Center,
                            },
                            new ContentControl { Content = actions, [Grid.ColumnProperty] = 1 },
                        },
                    },
                    bar,
                    line2,
                },
            },
        };
    }

    /// <summary>
    /// 标题:剧集用「剧名 SxEy 集名」,电影用整条标题。
    ///
    /// <para>★ 分集只写「第 3 集」的话,下载列表里十条都长一样。</para>
    /// </summary>
    private static string Title(JsonElement it)
    {
        var title = Str(it, "title");
        var series = Str(it, "series_name");
        if (series.Length == 0) return title;
        var s = it.TryGetProperty("season_number", out var sv) && sv.ValueKind == JsonValueKind.Number
            ? sv.GetInt64() : 0;
        var e = it.TryGetProperty("episode_number", out var ev) && ev.ValueKind == JsonValueKind.Number
            ? ev.GetInt64() : 0;
        var code = s > 0 || e > 0 ? $" S{s:00}E{e:00}" : "";
        return $"{series}{code} · {title}";
    }

    private static string StatusText(string status, long got, long total, string error)
    {
        var size = total > 0 ? $"{Human(got)} / {Human(total)}" : Human(got);
        return status switch
        {
            "downloading" => $"下载中  {size}",
            "queued" => "排队中",
            "paused" => $"已暂停  {size}",
            "completed" => $"已完成  {Human(total > 0 ? total : got)}",
            "failed" => "失败:" + (error.Length > 0 ? error : "未知原因"),
            "canceled" => "已取消",
            _ => status,
        };
    }

    private static string Human(long n)
    {
        if (n <= 0) return "0 B";
        string[] u = ["B", "KB", "MB", "GB", "TB"];
        double v = n;
        var i = 0;
        while (v >= 1024 && i < u.Length - 1) { v /= 1024; i++; }
        return i == 0 ? $"{n} B" : $"{v:0.#} {u[i]}";
    }

    private async Task Act(Func<Task<JsonElement>> f)
    {
        try { await f(); }
        catch (Exception e) { _status.Text = LibraryPage.Advice(e); }
        await Refresh();
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static long Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetInt64() : 0;
}
