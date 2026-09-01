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
/// 追剧日历(<c>UI_PC.md</c> §7.12)。本周看板:一屏并排若干天、每列自己滚。
///
/// <para>★★ 几条被真事故定死的规矩:</para>
/// <list type="bullet">
/// <item><b>今天要居中,不是靠边</b>【用户定】。周一 / 周日是今天时自然靠边,
///   那是没得居中,不是 bug。</item>
/// <item><b>标题不许截成「…」</b> —— 截了就是显示不全。放开完整换行 + 大封面
///   <c>Uniform</c> 不裁(源站给的是 2:3 竖版,硬裁成方图会切掉大半)。</item>
/// <item><b>列不能上背景模糊</b> —— 叠着内滚会有残影。</item>
/// <item><b>判「今天是周几」按上游时区(JST)</b>(<c>SPEC.md</c> §14.4)。
///   按本地时区判的话,国内用户在每天 23:00~01:00 之间看到的「今天」是错的。</item>
/// </list>
/// </summary>
public sealed class CalendarPage : PageBase
{
    private readonly CoreClient _core;
    private readonly StackPanel _board = new() { Orientation = Orientation.Horizontal, Spacing = 14 };
    private readonly TextBlock _status = Dim("");
    private readonly ComboBox _source = new() { Width = 176, MinHeight = 34 };
    private readonly CheckBox _onlyMine = new() { Content = "只看我追的", MinHeight = 34 };

    private static readonly string[] WeekNames = ["", "周一", "周二", "周三", "周四", "周五", "周六", "周日"];

    public CalendarPage(CoreClient core)
    {
        _core = core;

        foreach (var (k, label) in new[] { ("bangumi", "番剧(Bangumi)"), ("trakt", "剧集(Trakt)") })
            _source.Items.Add(new ComboBoxItem { Content = label, Tag = k });
        _source.SelectedIndex = 0; // 解锁后默认 Bangumi(公开放送表免登录就能返回整张表)
        // ★ 先设默认值再挂事件 —— 反过来的话 SelectedIndex=0 会自己触发一次 Load,
        //   页面一进来就打两次上游。
        _source.SelectionChanged += (_, _) => _ = Load();
        _onlyMine.IsCheckedChanged += (_, _) => _ = Load();

        Content = Scrolled(new StackPanel
        {
            Spacing = 14,
            Children =
            {
                H1("追剧日历"),
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 12,
                    Children = { _source, _onlyMine },
                },
                _status,
                // ★ 看板本身横向滚:并排四列放不下一周,剩下的靠横滚够得着
                new ScrollViewer
                {
                    HorizontalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
                    VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Disabled,
                    Content = _board,
                },
            },
        });

        _ = Load();
    }

    private string Source => _source.SelectedItem is ComboBoxItem { Tag: string k } ? k : "bangumi";

    private async Task Load()
    {
        _board.Children.Clear();
        _status.Text = "加载中…";
        var onlyMine = _onlyMine.IsChecked == true;

        JsonElement arr;
        try
        {
            arr = Source == "trakt"
                ? await _core.SyncTraktCalendar(new { only_mine = onlyMine })
                : await _core.SyncBangumiCalendar(new { only_mine = onlyMine });
        }
        catch (Exception e)
        {
            // ★ 「还没连接」是**可操作**的失败:说清楚要去哪儿连,别只说一句失败
            _status.Text = LibraryPage.Advice(e);
            return;
        }

        var items = arr.ValueKind == JsonValueKind.Array ? arr.EnumerateArray().ToList() : [];
        Dispatcher.UIThread.Post(() => Render(items));
    }

    private void Render(List<JsonElement> items)
    {
        _board.Children.Clear();
        if (items.Count == 0)
        {
            _status.Text = _onlyMine.IsChecked == true
                ? "你追的番里,这一季没有正在放送的。"
                : "放送表是空的(上游没有返回条目)。";
            return;
        }
        _status.Text = "";

        var today = TodayWeekdayJst();
        // ★★ **今天居中**:从「今天往前一格」开始排。周一 / 周日是今天时自然靠边。
        var start = today - 1;
        var order = new List<int>();
        for (var i = 0; i < 7; i++) order.Add(((start - 1 + i + 7) % 7) + 1);

        /* ★ 七列全画,一屏放得下三四列,剩下的靠**横滚**够得着。
           只画四列的话,周末那几天要换个筛选才看得到 —— 而日历本来就是拿来
           一眼扫全周的。列宽固定 320:靠列宽不靠列多,塞七列每列都窄到看不清封面。 */
        foreach (var wd in order)
        {
            var ofDay = items.Where(e => Weekday(e) == wd).ToList();
            _board.Children.Add(DayColumn(wd, wd == today, ofDay));
        }
    }

    private Control DayColumn(int weekday, bool isToday, List<JsonElement> items)
    {
        var head = new TextBlock
        {
            Text = WeekNames[weekday] + (isToday ? "  ·  今天" : ""),
            FontSize = 14,
            FontWeight = isToday ? FontWeight.Bold : FontWeight.Normal,
            Foreground = new SolidColorBrush(Color.Parse(isToday ? "#5b8def" : "#9aa4b4")),
            Margin = new Thickness(2, 0, 0, 8),
        };

        var list = new StackPanel { Spacing = 12 };
        foreach (var e in items) list.Children.Add(EntryRow(e));
        if (items.Count == 0) list.Children.Add(Dim("这天没有更新"));

        return new Border
        {
            // ★ **不上背景模糊**:叠着内滚会有残影
            Background = new SolidColorBrush(Color.Parse(isToday ? "#141922" : "#0f131a")),
            BorderBrush = new SolidColorBrush(Color.Parse(isToday ? "#295b8def" : "#252c38")),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(12),
            Width = 320, // 靠列宽不靠列多
            Child = new StackPanel
            {
                Children =
                {
                    head,
                    new ScrollViewer
                    {
                        MaxHeight = 620, // 每列自己滚
                        VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
                        Content = list,
                    },
                },
            },
        };
    }

    private Control EntryRow(JsonElement e)
    {
        var title = Str(e, "title");
        var img = new Image { Stretch = Stretch.Uniform, Width = 80 };
        var cover = new Border
        {
            Width = 80, Height = 120, CornerRadius = new CornerRadius(6), ClipToBounds = true,
            Background = new SolidColorBrush(Color.Parse("#1b212c")),
            Child = img,
            VerticalAlignment = VerticalAlignment.Top,
        };
        if (Str(e, "image_url") is { Length: > 0 } url) _ = Fill(img, url);

        var bits = new List<string>();
        if (Time(e) is { Length: > 0 } t) bits.Add(t);
        if (e.TryGetProperty("rating", out var r) && r.ValueKind == JsonValueKind.Number)
            bits.Add(r.GetDouble().ToString("0.0") + " 分");
        if (Str(e, "subtitle") is { Length: > 0 } sub) bits.Add(sub);

        return new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children =
            {
                cover,
                new StackPanel
                {
                    Width = 190, Spacing = 5,
                    Children =
                    {
                        // ★★ 标题**不许截成「…」** —— 截了就是显示不全。完整换行。
                        new TextBlock { Text = title, FontSize = 13, TextWrapping = TextWrapping.Wrap },
                        new TextBlock
                        {
                            Text = string.Join("  ·  ", bits), FontSize = 11.5, Opacity = 0.6,
                            TextWrapping = TextWrapping.Wrap,
                            IsVisible = bits.Count > 0,
                        },
                    },
                },
            },
        };
    }

    private async Task Fill(Image target, string url)
    {
        var bmp = await Images.LoadAsync(_core, url, 240);
        if (bmp is null) return;
        Dispatcher.UIThread.Post(() => target.Source = bmp);
    }

    /// <summary>
    /// 一条的放送时刻,换算成**本地** HH:MM。取不到就空串(不编时间)。
    ///
    /// <para>★ 两个来源两个字段:Trakt 给精确的 <c>air_date</c>,
    /// Bangumi 给每周固定的 <c>broadcast_at</c>。</para>
    /// </summary>
    private static string Time(JsonElement e)
    {
        var iso = Str(e, "air_date");
        if (iso.Length == 0) iso = Str(e, "broadcast_at");
        if (iso.Length == 0) return "";
        return DateTimeOffset.TryParse(iso, out var dt) ? dt.ToLocalTime().ToString("HH:mm") : "";
    }

    private static int Weekday(JsonElement e)
    {
        if (e.TryGetProperty("weekday", out var w) && w.ValueKind == JsonValueKind.Number)
            return w.GetInt32();
        // Trakt 那边没有 weekday,从 air_date 现算
        var iso = Str(e, "air_date");
        if (iso.Length > 0 && DateTimeOffset.TryParse(iso, out var dt))
            return ((int)dt.ToLocalTime().DayOfWeek + 6) % 7 + 1; // 周日=7
        return 0;
    }

    /// <summary>
    /// 今天是周几(1=周一…7=周日),**按上游时区 JST**。
    ///
    /// <para>★★ 按本地时区判的话,国内用户在每天 23:00~01:00 之间看到的「今天」是错的
    /// —— 番剧放送表是按日本时间排的(<c>SPEC.md</c> §14.4)。</para>
    /// </summary>
    private static int TodayWeekdayJst()
    {
        var jst = DateTimeOffset.UtcNow.ToOffset(TimeSpan.FromHours(9));
        return ((int)jst.DayOfWeek + 6) % 7 + 1;
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}
