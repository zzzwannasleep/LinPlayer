using System.Text.Json;
using System.Text.Json.Serialization;
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
    double RuntimeSecs, double ResumeSecs,
    int SeasonNo, int EpisodeNo)
{
    public static CardItem From(JsonElement e) => new(
        Str(e, "id"), Str(e, "name"), Str(e, "type_"), Str(e, "series_name"),
        Bool(e, "has_primary"), Bool(e, "played"), Num(e, "unplayed_item_count"),
        Dbl(e, "runtime_secs"), Dbl(e, "resume_secs"),
        (int)Num(e, "season_no"), (int)Num(e, "episode_no"));

    /// <summary>
    /// 列表里显示的标题。
    ///
    /// <para>分集的 Name 只是「第 35 集」,单看无意义 —— 继续观看 / 收藏 / 搜索
    /// 这些混排列表**必须靠剧名**才说得清是哪部剧。</para>
    /// </summary>
    public string DisplayTitle =>
        string.IsNullOrEmpty(SeriesName) ? Name : $"{SeriesName} · {Name}";

    /// <summary>
    /// 季集号,<c>S01E01</c> 这种写法。没有季集号(电影 / 特别篇)就是空串。
    ///
    /// <para>用户 2026-09-05:「不要显示剧集名称+标题,遇到长的那点长度根本看不到
    /// 具体的集数,直接显示 S01E01 这样子得了」。<b>选集列表要的是定位,不是介绍</b> ——
    /// 「某某剧 · 第三十五集 什么什么的什么什么」在 380 宽的浮层里会被截成省略号,
    /// 而截掉的恰恰是集号。</para>
    /// <para>补零到两位:不补的话 S1E9 和 S1E10 在一列里对不齐,扫一眼找不着。</para>
    /// </summary>
    public string EpisodeCode => EpisodeNo <= 0 ? ""
        : SeasonNo > 0 ? $"S{SeasonNo:00}E{EpisodeNo:00}" : $"E{EpisodeNo:00}";

    /// <summary>选集列表里的一行。有集号就只写集号,没有才回落到名字(特别篇 / 电影)。</summary>
    public string PickerLabel => EpisodeCode is { Length: > 0 } c ? c : Name;

    /// <summary>看到哪儿了(0~1)。没有进度就是 0。</summary>
    public double Progress =>
        RuntimeSecs > 0 && ResumeSecs > 0 ? Math.Clamp(ResumeSecs / RuntimeSecs, 0, 1) : 0;

    /// <summary>时长的人话。不足一分钟就是空串 —— <b>「0 分钟」比不写更糟</b>。</summary>
    public string RuntimeLabel => RuntimeSecs < 60 ? "" : $"{(int)(RuntimeSecs / 60)} 分钟";

    /// <summary>
    /// 转回 JSON,给 <see cref="Core.MetaCache"/> 存。
    ///
    /// <para>字段名<b>必须和核心层的输出一模一样</b> —— 存进去的东西
    /// 之后要用 <see cref="From"/> 读回来,名字对不上就是「缓存命中但全是空的」,
    /// 而它不报错。</para>
    /// </summary>
    public static JsonElement ToJson(CardItem c)
    {
        using var doc = JsonDocument.Parse(JsonSerializer.Serialize(new
        {
            id = c.Id, name = c.Name, type_ = c.Type, series_name = c.SeriesName,
            has_primary = c.HasPrimary, played = c.Played,
            unplayed_item_count = c.UnplayedCount,
            runtime_secs = c.RuntimeSecs, resume_secs = c.ResumeSecs,
            season_no = c.SeasonNo, episode_no = c.EpisodeNo,
        }));
        return doc.RootElement.Clone();
    }

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
/// 媒体卡(UI_PC §4.3)。海报 2:3 · 横版 16:9。
///
/// <para><b>标题区高度是钉死的</b>(两行)。不钉的话一行标题的卡比两行的矮 17px,
/// 网格里下一行就整体上移 —— 表现是「卡片参差不齐」,而看上去像是间距没调好。
/// 真因是内容高度不一致,调间距永远调不好。</para>
///
/// <para>悬停抬起 / 描边 / 封面淡入全在样式表里(<c>Button.media</c> / <c>Border.art</c>),
/// 不在这儿写代码 —— 写在代码里的话每种卡各抖各的。</para>
/// </summary>
public sealed class Card : Button
{
    /// <summary>
    /// 一共造过多少张卡。<b>只给自检看</b>。
    ///
    /// <para>「虚拟化生效了没有」这件事在界面上<b>看不出来</b> ——
    /// 虚拟化的和不虚拟化的长得一模一样,差别只在造了多少个控件、
    /// 发了多少次图片请求。所以判据只能是这个数。</para>
    /// </summary>
    internal static int Made;

    /// <summary>标题行高。12.5px 字配 17px 行高。</summary>
    private const double LineHeight = 17;

    /* 手型光标和这几支画刷**全站共用一份**。
       每张卡各 new 一个的话:Cursor 是个平台资源(每次都去问一次系统),
       画刷则是每张卡多 6 次 Color.Parse —— 单看都不贵,乘以 140 张就是白烧的毫秒。
       它们从头到尾都是同一个值,没有任何理由存在 140 份。 */
    private static readonly Avalonia.Input.Cursor HandCursor =
        new(Avalonia.Input.StandardCursorType.Hand);
    private static IBrush ArtBackdrop => Tok.Of("PanelAlt");
    private static IBrush PlaceholderInk => Tok.Of("Ink3");
    private static readonly IBrush BadgeScrim = new SolidColorBrush(Color.Parse("#b0000000"));
    private static IBrush WatchedGreen => Tok.Of("Ok");
    private static IBrush AccentBlue => Tok.Of("Accent");
    private static readonly IBrush TrackScrim = new SolidColorBrush(Color.Parse("#40000000"));

    /// <param name="titleLines">
    /// 标题区固定几行。
    /// <para>默认 2:网格里长短标题混排,不钉死行数下一行就会参差不齐。</para>
    /// <para>一行就够的场合(媒体库那种「电影 / 剧集 / 番剧」)要传 1 ——
    /// 否则副标题会被顶到第二行的下面,和标题之间空出一整行,看着像两个不相干的东西。</para>
    /// </param>
    public Card(CoreClient core, string server, CardItem item, bool wide, Action<CardItem>? onOpen = null,
        double? width = null, string? subtitle = null, string? title = null, int titleLines = 2)
    {
        Made++;
        var w = width ?? (wide ? 256.0 : 158.0);
        var h = wide ? w * 9 / 16 : w * 3 / 2;

        var img = new Image { Stretch = Stretch.UniformToFill, Opacity = 0, Classes = { "art" } };
        // 没有封面时才显示的占位文字(而不是一块空砖)
        var ph = new TextBlock
        {
            Text = title ?? item.Name, FontSize = 12, Margin = new Thickness(10),
            Foreground = PlaceholderInk,
            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            HorizontalAlignment = HorizontalAlignment.Center,
            IsVisible = !item.HasPrimary,
        };
        /* <b>每张卡自己有骨架</b>(用户 2026-09-02:「所有卡片都没有做提前加载,
           先加载一个骨架再加载出来图片比较好」)。
           原来图没到的时候卡面是一块**静止的深色砖** —— 它和「这条目就是没有封面」
           长得一模一样,用户分不清是在加载还是加载完了。会呼吸的骨架说的是
           「还在路上」,而那正是这一秒里唯一要传达的事。
           只在**确实有封面**时才铺:没有封面的条目铺骨架就成了永远在加载。
           尺寸就是卡面本身,所以不存在换上真图时跳版。 */
        var skel = new Border
        {
            Classes = { "skel" }, CornerRadius = new CornerRadius(10),
            IsVisible = item.HasPrimary,
        };
        var art = new Border
        {
            Width = w, Height = h,
            CornerRadius = new CornerRadius(10),
            ClipToBounds = true,
            Classes = { "art" },
            Background = ArtBackdrop,
            Child = new Panel { Children = { skel, ph, img, Badges(item, w) } },
        };

        var caption = new StackPanel { Spacing = 2 };
        caption.Children.Add(new TextBlock
        {
            Text = title ?? item.DisplayTitle, FontSize = 12.5, MaxLines = titleLines,
            LineHeight = LineHeight, Height = LineHeight * titleLines,
            VerticalAlignment = VerticalAlignment.Top,
            TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
        });
        // 副标题(时长 / 项目数)。 没值就整行不画 —— 留一行空的等于每张卡都高半行。
        if (!string.IsNullOrEmpty(subtitle))
        {
            caption.Children.Add(new TextBlock
            {
                Text = subtitle, FontSize = 11.5, MaxLines = 1,
                TextTrimming = TextTrimming.CharacterEllipsis,
                Foreground = PlaceholderInk,
            });
        }

        Content = new StackPanel { Width = w, Spacing = 6, Children = { art, caption } };
        Classes.Add("media");
        Background = Brushes.Transparent;
        BorderThickness = new Thickness(0);
        Padding = new Thickness(0);
        Cursor = HandCursor;
        if (onOpen is not null) Click += (_, _) => onOpen(item);

        if (item.HasPrimary) StartArt(core, server, item, img, (int)(h * 2), skel, ph);

        // 右键动作:标记已看 / 收藏 / 屏蔽。**一处实现,所有卡片共用**(见 CardActions)
        CardActions.Attach(this, core, item);
    }

    /// <summary>
    /// 开始取封面。已经解好的位图要在这一刻就贴上去,一个 await 都不能排。
    ///
    /// <para>用户 2026-09-03:「收起/展开侧边栏时图片都要重新加载或者闪一下」。
    /// 收放侧栏会让网格列数变化 → 卡片重建,而原来这条路无论缓存命中与否都要走
    /// 一次 <c>Dispatcher.Post</c>,于是每张卡都必然有一帧是「骨架 + 透明的图」。
    /// 命中时连淡入都不做:那张图上一帧还在屏幕上,给它做入场动画本身就是错的。</para>
    /// </summary>
    private static void StartArt(CoreClient core, string server, CardItem item, Image target,
        int maxH, Control skel, Control placeholder)
    {
        var url = Images.EmbyImageUrl(server, item.Id, "Primary");
        var t = Images.LoadAsync(core, url, maxH);
        // 缓存命中时 LoadAsync 返回的是一个**已完成**的 Task(它自己就是同步查表的)
        if (t.IsCompletedSuccessfully && t.Result is { } cached)
        {
            skel.IsVisible = false;
            target.Source = cached;
            target.Opacity = 1;
            return;
        }
        _ = LoadArt(t, target, skel, placeholder);
    }

    private static async Task LoadArt(Task<Bitmap?> pending, Image target,
        Control skel, Control placeholder)
    {
        var bmp = await pending;
        /* 不管成没成,<b>骨架都要收</b>。
           只在成功那条路上收的话,取不到封面的条目会**永远呼吸下去** ——
           而它其实早就失败了。这正是本仓最讨厌的那种失败:不报错、不崩、
           只是一直在「加载中」。 */
        Dispatcher.UIThread.Post(() =>
        {
            skel.IsVisible = false;
            if (bmp is null) { placeholder.IsVisible = true; return; }
            // 图到了再淡入(过渡挂在 Image.art 的样式上)。直接塞上去会「啪」地跳一下,
            // 一屏几十张同时跳就是闪屏。
            target.Source = bmp;
            target.Opacity = 1;
        });
    }

    /// <summary>
    /// 角标:集号 / 看完打勾 / 未看集数 / 播放进度条。
    ///
    /// <para>右上角那个是「有勾优先,否则显数字」—— played=true 时未看数必为 0,
    /// 两个都画会自相矛盾。</para>
    /// <para>集号放**左上角**,和右上角的看完标记分开 —— 挤在同一角会互相盖。</para>
    /// </summary>
    private static Control Badges(CardItem item, double w)
    {
        var panel = new Panel();

        if (item.EpisodeNo > 0)
        {
            panel.Children.Add(new Border
            {
                Height = 20, CornerRadius = new CornerRadius(6),
                Padding = new Thickness(6, 0), Margin = new Thickness(6, 6, 0, 0),
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Top,
                Background = BadgeScrim,
                Child = new TextBlock
                {
                    Text = item.SeasonNo > 0 ? $"S{item.SeasonNo}E{item.EpisodeNo}" : $"E{item.EpisodeNo}",
                    FontSize = 11, Foreground = Brushes.White,
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            });
        }

        if (item.Played)
        {
            panel.Children.Add(new Border
            {
                Width = 22, Height = 22, CornerRadius = new CornerRadius(999),
                Margin = new Thickness(0, 6, 6, 0),
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Top,
                Background = WatchedGreen,
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
                Background = AccentBlue,
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
                Background = TrackScrim,
                Child = new Border
                {
                    Height = 3, Width = w * item.Progress,
                    HorizontalAlignment = HorizontalAlignment.Left,
                    Background = AccentBlue,
                },
            });
        }
        return panel;
    }
}
