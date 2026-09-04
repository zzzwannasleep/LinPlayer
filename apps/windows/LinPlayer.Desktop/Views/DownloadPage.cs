using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 下载页(<c>UI_PC.md</c> §7.9)。
///
/// <para>两个正相反的语义不许合并:「清除已完成」只清记录,每条右边的 ✕ 才删文件
/// (不可逆,要二次确认)。并发数归核心层持久化,本页只读回来、不灌下去。</para>
///
/// <para>2026-09-04 重做(用户:「只有下载完的,下载完了不能直接点击观看,样式
/// 不好看也不好交互」):整张卡可点(<c>player.playLocal</c> 原来全仓零调用)、
/// 进行中 / 已完成分组、海报 + 速度 + 剩余时间。</para>
/// </summary>
public sealed class DownloadPage : PageBase
{
    private readonly CoreClient _core;
    /* 列表**不许铺满整个窗口**。一条下载记录的内容只有「海报 标题 一行状态」,
       在 1600px 宽的窗口里摊开就是标题和按钮各占一头、中间一大片空 ——
       用户说的「样式不好看」有一半是这个。920 是四五十个汉字的宽度,够长标题不截断。 */
    private readonly StackPanel _rows = new()
    {
        Spacing = 10, MaxWidth = 920, HorizontalAlignment = HorizontalAlignment.Left,
    };
    private readonly TextBlock _status = Dim("");
    private readonly ComboBox _threads = new() { Width = 130, MinHeight = 34 };
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromSeconds(1) };

    private bool _building;

    /// <summary>每条任务上一次读到的字节数和时刻,用来算速度。换页不清 —— 页面本身就重建了。</summary>
    private readonly Dictionary<string, (long Bytes, DateTime At, double Bps)> _speed = new();

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

        // 并发数**从核心层读回来**,不是 UI 猜一个再灌下去。
        // 猜的话就是「pill 显示 3、引擎实际跑 2」双重撒谎(UI_PC §7.9)。
        _ = LoadThreads();

        // 进度**不是推送的**,轮询。一个活跃下载不值得为它开一条事件流。
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
            // 回读**实际生效**的档位。核心层会把它钳在 1~4;
            // 不回读的话,用户设了个越界值、界面显示成功、引擎跑的是另一个数。
            if (r.ValueKind == JsonValueKind.Object && r.TryGetProperty("threads", out var got))
            {
                var real = got.GetInt32();
                SelectThreads(real);
                Toast.Show($"下载并发改成 {real} 线程");
            }
        }
        catch (Exception e) { Toast.Error(LibraryPage.Advice(e)); }
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
            // 「文件还在」这五个字必须说 —— 不说的话用户会以为片子被删了
            Toast.Show(n > 0 ? $"清掉了 {n} 条记录(文件还在)" : "没有已完成的任务");
            await Refresh();
        }
        catch (Exception e) { Toast.Error(LibraryPage.Advice(e)); }
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
            _status.Text = "";

            /* 分两组。原来是一条按加入时间倒序的长列表 ——
               下了十几集之后,正在下的那条会被后来的挤到中间去,
               而「现在到底在下什么」是这一页唯一实时的信息。 */
            var live = items.Where(x => Str(x, "status") is "downloading" or "queued"
                                                         or "paused" or "failed").ToList();
            var done = items.Where(x => Str(x, "status") is "completed").ToList();
            var rest = items.Where(x => !live.Contains(x) && !done.Contains(x)).ToList();

            if (live.Count > 0)
            {
                _rows.Children.Add(Section($"进行中 · {live.Count}"));
                foreach (var it in live) _rows.Children.Add(Row(it));
            }
            if (done.Count > 0)
            {
                _rows.Children.Add(Section($"已完成 · {done.Count} —— 点一下就能看"));
                foreach (var it in done) _rows.Children.Add(Row(it));
            }
            foreach (var it in rest) _rows.Children.Add(Row(it));
        });
    }

    private static TextBlock Section(string t) => new()
    {
        Text = t, FontSize = 12.5, Opacity = 0.55, Margin = new Thickness(2, 10, 0, 0),
    };

    /// <summary>
    /// 下载速度(字节/秒)。核心层不给,这里按两次轮询之间的字节差算。
    ///
    /// <para>要做<b>指数平滑</b>:分段下载的字节是一段一段落下来的,
    /// 生算差值时读数会在「0 B/s」和「40 MB/s」之间来回跳,看着像坏了。</para>
    /// </summary>
    private double Speed(string id, long got, string status)
    {
        var now = DateTime.UtcNow;
        if (!_speed.TryGetValue(id, out var last))
        {
            _speed[id] = (got, now, 0);
            return 0;
        }
        var dt = (now - last.At).TotalSeconds;
        if (dt < 0.3) return last.Bps;
        var inst = Math.Max(0, got - last.Bytes) / dt;
        // 暂停/失败时直接归零,别让上一秒的速度一直挂着
        var bps = status == "downloading" ? last.Bps * 0.6 + inst * 0.4 : 0;
        _speed[id] = (got, now, bps);
        return bps;
    }

    private Control Row(JsonElement it)
    {
        var id = Str(it, "id");
        var itemId = Str(it, "item_id");
        var status = Str(it, "status");
        var got = Num(it, "received_bytes");
        var total = Num(it, "total_bytes");
        var progress = it.TryGetProperty("progress", out var p) && p.ValueKind == JsonValueKind.Number
            ? p.GetDouble() : 0;
        var done = status == "completed";
        var title = Title(it);

        var bar = new ProgressBar
        {
            Minimum = 0, Maximum = 1, Value = done ? 1 : progress, Height = 4,
            // 未知大小时进度条要**不确定态**,不是停在 0 ——
            // 停在 0 看起来像卡住了,而它其实在下
            IsIndeterminate = total <= 0 && status == "downloading",
        };
        // 已完成的那条不画进度条:一条 100% 的条子只是噪音,它已经说完了
        bar.IsVisible = !done;

        var line2 = new TextBlock
        {
            FontSize = 12, Opacity = 0.6,
            Text = StatusText(status, got, total, Str(it, "error"),
                              Speed(id, got, status), progress),
        };

        var actions = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
        };

        /* 已完成的第一动作是<b>看</b>,不是删。
           播放走 player.playLocal(核心层现成的),不另起一条起播路径。 */
        if (done)
        {
            var play = new Button { Content = "播放", Classes = { "primary" } };
            play.Click += (_, e) => { e.Handled = true; Play(id, itemId, title); };
            actions.Children.Add(play);
        }
        else if (status is "downloading" or "queued")
        {
            var pause = new Button { Content = "暂停", Classes = { "ghost" } };
            pause.Click += (_, _) => _ = Act(() => _core.DownloadPause(new { id }), "已暂停");
            actions.Children.Add(pause);
        }
        else if (status is "paused" or "failed")
        {
            var resume = new Button { Content = "继续", Classes = { "ghost" } };
            resume.Click += (_, _) => _ = Act(() => _core.DownloadResume(new { id }), "继续下载");
            actions.Children.Add(resume);
        }

        // 删除是**不可逆**的(连文件一起删),所以要二次确认。
        // 设置页全页零二次确认是有意的,而这里是那条规则的例外 —— 同「删除服务器」。
        var del = new Button { Content = "✕", Classes = { "ghost" } };
        del.Click += (_, e) =>
        {
            e.Handled = true;               // 别让这一下顺着卡片冒泡上去起播
            if (del.Content as string == "✕")
            {
                del.Content = "确认删除?";
                del.Classes.Add("danger");
                Toast.Show("再点一次就连文件一起删掉");
                return;
            }
            _ = Act(() => _core.DownloadRemove(new { id }), "已删除(文件也删了)");
        };
        actions.Children.Add(del);

        var text = new StackPanel
        {
            Spacing = 6, VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                new TextBlock
                {
                    Text = title, FontSize = 13.5,
                    TextTrimming = TextTrimming.CharacterEllipsis,
                },
                bar,
                line2,
            },
        };

        var grid = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        var art = Poster(it, done);
        Grid.SetColumn(art, 0);
        Grid.SetColumn(text, 1);
        Grid.SetColumn(actions, 2);
        text.Margin = new Thickness(14, 0, 14, 0);
        grid.Children.Add(art);
        grid.Children.Add(text);
        grid.Children.Add(actions);

        var card = new Border
        {
            Classes = { "card" },
            Padding = new Thickness(14, 10),
            Child = grid,
        };

        /* 整张卡可点 = 播放。只给一个「播放」小按钮是不够的 ——
           一条已完成的记录,用户的第一反应就是点它本身。
           按钮那几下已经 Handled 了,不会走到这里来。 */
        if (done)
        {
            card.Classes.Add("tap");
            card.Cursor = new Cursor(StandardCursorType.Hand);
            card.PointerPressed += (_, e) =>
            {
                if (e.GetCurrentPoint(card).Properties.IsLeftButtonPressed) Play(id, itemId, title);
            };
        }
        return card;
    }

    /// <summary>
    /// 起播本地文件。
    ///
    /// <para>先送任务 id,核心层两种 id 都收(见 <c>player.playLocal</c>);
    /// 这里把 item_id 也带上只是为了在任务 id 认不出来时还有第二条路。</para>
    /// <para>文件被手动删掉时核心层会报 ENotFound —— 那条错必须弹出来,
    /// 不然点了没反应就是「这个功能坏了」。</para>
    /// </summary>
    private void Play(string id, string itemId, string title)
    {
        Nav.Push(new PlayerPage(_core, id.Length > 0 ? id : itemId, title, 0, isLocal: true));
    }

    /// <summary>
    /// 海报。没有海报(源下载 / 老记录)就画一个占位方块。
    ///
    /// <para>40×60 是 2:3 —— Emby 的 Primary 就是这个比例,别按 16:9 摆。</para>
    /// </summary>
    private Control Poster(JsonElement it, bool done)
    {
        var box = new Border
        {
            Width = 40, Height = 60, CornerRadius = new CornerRadius(6), ClipToBounds = true,
            Background = Tok.Of("PanelAlt"),
            VerticalAlignment = VerticalAlignment.Center,
            Child = new TextBlock
            {
                // 占位:一个胶片图标,比一块纯色好认
                Text = "", FontFamily = new FontFamily("Segoe MDL2 Assets"),
                FontSize = 15, Opacity = 0.35,
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
            },
        };
        // 没下完的那些压暗一点 —— 一眼分得出哪几条还在路上
        box.Opacity = done ? 1 : 0.7;

        var url = Str(it, "poster_url");
        if (url.Length == 0) return box;
        _ = LoadPoster(url, box);
        return box;
    }

    private async Task LoadPoster(string url, Border box)
    {
        try
        {
            var bmp = await Images.LoadAsync(_core, url, 120);
            if (bmp is null) return;
            Dispatcher.UIThread.Post(() =>
                box.Child = new Image { Source = bmp, Stretch = Stretch.UniformToFill });
        }
        catch { /* 拉不到就留着占位方块,不该为一张小图报错 */ }
    }

    /// <summary>
    /// 标题:剧集用「剧名 SxEy 集名」,电影用整条标题。
    ///
    /// <para>分集只写「第 3 集」的话,下载列表里十条都长一样。</para>
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

    private static string StatusText(string status, long got, long total, string error,
                                     double bps, double progress)
    {
        var size = total > 0 ? $"{Human(got)} / {Human(total)}" : Human(got);
        var pct = total > 0 ? $"{progress * 100:0}%  " : "";
        return status switch
        {
            // 速度和剩余时间是这一页最有用的两个数 —— 「下载中 300MB/1GB」说明不了它在不在动
            "downloading" => $"{pct}{size}{Rate(bps)}{Eta(got, total, bps)}",
            "queued" => "排队中",
            "paused" => $"已暂停  {pct}{size}",
            "completed" => $"已完成  {Human(total > 0 ? total : got)}",
            "failed" => "失败:" + (error.Length > 0 ? error : "未知原因"),
            "canceled" => "已取消",
            _ => status,
        };
    }

    private static string Rate(double bps) => bps > 1 ? $"  ·  {Human((long)bps)}/s" : "";

    private static string Eta(long got, long total, double bps)
    {
        if (total <= got || bps < 1024) return "";
        var secs = (total - got) / bps;
        if (secs > 86400) return "";                 // 一天以上的估算没有参考价值,不如不写
        var t = TimeSpan.FromSeconds(secs);
        return "  ·  剩 " + (t.TotalHours >= 1
            ? $"{(int)t.TotalHours} 小时 {t.Minutes} 分"
            : t.TotalMinutes >= 1 ? $"{(int)t.TotalMinutes} 分钟" : $"{t.Seconds} 秒");
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

    private async Task Act(Func<Task<JsonElement>> f, string ok)
    {
        try
        {
            await f();
            Toast.Show(ok);
        }
        catch (Exception e) { Toast.Error(LibraryPage.Advice(e)); }
        await Refresh();
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static long Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetInt64() : 0;

    // ---------------------------------------------------------------- 自检

    /// <summary>
    /// 自检:<c>LP_DL=1</c> —— 下载页三条断言。
    ///
    /// <para>判据是<b>真的点下去</b>(RaiseEvent 发在卡片上,走的正是用户那条路),
    /// 不是「有没有这个按钮」。本仓栽过「按钮画着但事件挂在别的元素上」那一类。</para>
    /// </summary>
    internal void SelfCheck()
    {
        var mode = Environment.GetEnvironmentVariable("LP_SELFCHECK_DOWNLOAD") ?? "";
        if (mode == "") return;
        _ = Task.Delay(2500).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var cards = _rows.Children.OfType<Border>().ToList();
            var taps = cards.Where(c => c.Classes.Contains("tap")).ToList();
            var heads = _rows.Children.OfType<TextBlock>().Select(t => t.Text ?? "").ToList();
            Console.WriteLine(heads.Any(h => h.StartsWith("已完成"))
                ? $"[下载页] ✓ 分了组:{string.Join(" / ", heads)}"
                : $"[下载页] ✗ 没有「已完成」分组,共 {heads.Count} 个组标题");
            Console.WriteLine(taps.Count > 0
                ? $"[下载页] ✓ {taps.Count}/{cards.Count} 张卡是可点播放的"
                : $"[下载页] ✗ {cards.Count} 张卡没有一张能点开 —— 下载完了看不了");
            // LP_DL=2 只断言不点 —— 点了就跳走了,截图里看到的是播放页而不是这一页
            if (taps.Count == 0 || mode != "1") return;

            var before = Nav.Current;
            /* 必须在**卡片自己**身上 RaiseEvent。在页面上发、靠构造参数里那个 source
               指过去是不行的 —— Avalonia 会把 Source 换成实际 RaiseEvent 的元素,
               于是走的根本不是用户那条路(播放页那条自检栽过一模一样的坑)。 */
            taps[0].RaiseEvent(new PointerPressedEventArgs(
                taps[0], new Pointer(0, PointerType.Mouse, true), taps[0], new Point(4, 4),
                0, new PointerPointProperties(RawInputModifiers.LeftMouseButton,
                    PointerUpdateKind.LeftButtonPressed), KeyModifiers.None));
            Dispatcher.UIThread.Post(() => Console.WriteLine(
                !ReferenceEquals(Nav.Current, before) && Nav.Current is PlayerPage
                    ? "[下载页] ✓ 点卡片真的进了播放页"
                    : "[下载页] ✗ 点了卡片没进播放页 —— 「点击观看」没接上"),
                DispatcherPriority.Background);
        }));
    }
}
