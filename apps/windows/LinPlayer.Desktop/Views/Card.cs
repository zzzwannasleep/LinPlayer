using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>一张卡片要用到的字段(核心层 emby.Item 的子集)。</summary>
public sealed record CardItem(
    string Id, string Name, string Type, string SeriesName,
    bool HasPrimary, bool Played, long UnplayedCount,
    double RuntimeSecs, double ResumeSecs)
{
    public static CardItem From(JsonElement e) => new(
        Str(e, "id"), Str(e, "name"), Str(e, "type_"), Str(e, "series_name"),
        Bool(e, "has_primary"), Bool(e, "played"), Num(e, "unplayed_item_count"),
        Dbl(e, "runtime_secs"), Dbl(e, "resume_secs"));

    /// <summary>
    /// 列表里显示的标题。
    ///
    /// <para>★ 分集的 Name 只是「第 35 集」,单看无意义 —— 继续观看 / 收藏 / 搜索
    /// 这些混排列表**必须靠剧名**才说得清是哪部剧。</para>
    /// </summary>
    public string DisplayTitle =>
        string.IsNullOrEmpty(SeriesName) ? Name : $"{SeriesName} · {Name}";

    /// <summary>看到哪儿了(0~1)。没有进度就是 0。</summary>
    public double Progress =>
        RuntimeSecs > 0 && ResumeSecs > 0 ? Math.Clamp(ResumeSecs / RuntimeSecs, 0, 1) : 0;

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
    private static long Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetInt64() : 0;
    private static double Dbl(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
}

/// <summary>
/// 媒体卡(UI_PC §4.3)。海报 2:3 最小 150px / 横版 16:9 最小 240px。
/// </summary>
public sealed class Card : Button
{
    public Card(CoreClient core, string server, CardItem item, bool wide, Action<CardItem>? onOpen = null)
    {
        var w = wide ? 240.0 : 150.0;
        var h = wide ? w * 9 / 16 : w * 3 / 2;

        var img = new Image { Stretch = Stretch.UniformToFill, Opacity = 0 };
        var art = new Border
        {
            Width = w, Height = h,
            CornerRadius = new CornerRadius(10),
            ClipToBounds = true,
            Background = new SolidColorBrush(Color.Parse("#1b212c")),
            Child = new Panel
            {
                Children =
                {
                    // 占位:没有封面时也要看得出这是什么(而不是一块空砖)
                    new TextBlock
                    {
                        Text = item.Name, FontSize = 12, Margin = new Thickness(10),
                        Foreground = new SolidColorBrush(Color.Parse("#6b7688")),
                        TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center,
                        VerticalAlignment = VerticalAlignment.Center,
                        HorizontalAlignment = HorizontalAlignment.Center,
                    },
                    img,
                    Badges(item, w),
                },
            },
        };

        Content = new StackPanel
        {
            Width = w, Spacing = 6,
            Children =
            {
                art,
                new TextBlock
                {
                    Text = item.DisplayTitle, FontSize = 12.5, MaxLines = 2,
                    TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
                },
            },
        };
        Background = Brushes.Transparent;
        BorderThickness = new Thickness(0);
        Padding = new Thickness(0);
        Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand);
        if (onOpen is not null) Click += (_, _) => onOpen(item);

        if (item.HasPrimary) _ = LoadArt(core, server, item, img, (int)(h * 2));

        // 右键动作:标记已看 / 收藏 / 屏蔽。**一处实现,所有卡片共用**(见 CardActions)
        CardActions.Attach(this, core, item);
    }

    private static async Task LoadArt(CoreClient core, string server, CardItem item, Image target, int maxH)
    {
        var url = Images.EmbyImageUrl(server, item.Id, "Primary");
        var bmp = await Images.LoadAsync(core, url, maxH);
        if (bmp is null) return;
        // ★ 图到了再淡入。直接塞上去会「啪」地跳一下 —— 一屏几十张同时跳就是闪屏。
        Dispatcher.UIThread.Post(() =>
        {
            target.Source = bmp;
            target.Opacity = 1;
        });
    }

    /// <summary>
    /// 角标:看完打勾 / 未看集数 / 播放进度条。
    ///
    /// <para>★ 优先级是「有勾优先,否则显数字」—— played=true 时未看数必为 0,
    /// 两个都画会自相矛盾。</para>
    /// </summary>
    private static Control Badges(CardItem item, double w)
    {
        var panel = new Panel();

        if (item.Played)
        {
            panel.Children.Add(new Border
            {
                Width = 22, Height = 22, CornerRadius = new CornerRadius(11),
                Margin = new Thickness(0, 6, 6, 0),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Background = new SolidColorBrush(Color.Parse("#4caf7d")),
                Child = new TextBlock
                {
                    Text = "✓", FontSize = 12, Foreground = Brushes.White,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            });
        }
        else if (item.UnplayedCount > 0)
        {
            panel.Children.Add(new Border
            {
                Height = 20, MinWidth = 20, CornerRadius = new CornerRadius(10),
                Padding = new Thickness(6, 0), Margin = new Thickness(0, 6, 6, 0),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Background = new SolidColorBrush(Color.Parse("#5b8def")),
                Child = new TextBlock
                {
                    Text = item.UnplayedCount.ToString(), FontSize = 11.5,
                    Foreground = Brushes.White,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            });
        }

        if (item.Progress > 0)
        {
            panel.Children.Add(new Border
            {
                Height = 3, VerticalAlignment = VerticalAlignment.Bottom,
                Background = new SolidColorBrush(Color.Parse("#40000000")),
                Child = new Border
                {
                    Height = 3, Width = w * item.Progress,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Background = new SolidColorBrush(Color.Parse("#5b8def")),
                },
            });
        }
        return panel;
    }
}
