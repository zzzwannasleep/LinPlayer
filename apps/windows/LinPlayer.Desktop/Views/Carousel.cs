using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 首页那种横向轨道:一排卡片 + 两侧的翻页按钮。
///
/// <para>★★ <b>光有滚轮是不够的</b>。一条轨道能放 20 张卡,而屏幕上一次只看得到五六张 ——
/// 后面那十几张<b>没有任何东西告诉用户它们存在</b>。鼠标滚轮在横向滚动区上的行为
/// 还依赖设备(有的鼠标只发纵向),触控板用户和滚轮用户看到的是两个不同的应用。</para>
///
/// <para>★ 按钮<b>按能不能滚来显隐</b>,不是常驻。到头了还亮着一个点不动的按钮,
/// 用户会以为卡住了。</para>
/// </summary>
public static class Carousel
{
    /// <summary>翻页按钮的直径。</summary>
    private const double ButtonSize = 40;

    /// <summary>
    /// 一次翻多少:视口的 80%。
    ///
    /// <para>★ 不翻满一屏是故意的 —— 留一张卡在视野里,用户才知道自己是<b>接着</b>看
    /// 而不是跳到了另一段。整屏翻页会丢掉位置感。</para>
    /// </summary>
    private const double PageFactor = 0.8;

    /// <summary>
    /// 包一层。<paramref name="artHeight"/> 是卡片图区的高度 ——
    /// 按钮要对齐**图的中线**,不是整张卡的中线(卡片下面还有两行标题,
    /// 按整张卡居中的话按钮会偏低,看着像没对准)。
    /// </summary>
    public static Control Wrap(Control row, double artHeight)
    {
        var sv = new ScrollViewer
        {
            // ★ 滚动条藏起来:轨道下面横着一条滚动条会把卡片标题挤开,
            //   而翻页按钮已经把「还能往右」这件事说清楚了。
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = row,
        };

        var left = Arrow("‹", HorizontalAlignment.Left, artHeight);
        var right = Arrow("›", HorizontalAlignment.Right, artHeight);

        void Sync()
        {
            var max = sv.Extent.Width - sv.Viewport.Width;
            // 1px 容差:浮点算出来的 max 常常差个零点几,严格比较会让按钮在到头时闪
            left.IsVisible = sv.Offset.X > 1;
            right.IsVisible = sv.Offset.X < max - 1;
        }

        /* ★★ 翻页和滚轮**共用同一套缓动**(Smooth)。
           这里原本有一份自己写的 12 帧 DispatcherTimer 补间 —— 手感和别处对不上,
           而且 16ms 闹钟和刷新率对不齐,滑到一半会顿一下。
           一个应用里有两套滚动手感,比只有一套糙的更糟。 */
        left.Click += (_, _) => Smooth.GlideX(sv, -sv.Viewport.Width * PageFactor);
        right.Click += (_, _) => Smooth.GlideX(sv, sv.Viewport.Width * PageFactor);
        // 触控板的横向手势不用在这儿接:Smooth 是类级处理器,对所有 ScrollViewer 都生效。
        sv.ScrollChanged += (_, _) => Sync();

        /* ★ 首次要等布局算完再判:构造时 Viewport/Extent 都是 0,当场判等于两个按钮都不出现。
           ★ 量到了就把这个处理器摘掉 —— LayoutUpdated 在这一页活着的时候会**一直发**,
             而之后的变化 ScrollChanged 已经盯着了。留着是白烧 CPU。 */
        void First(object? _, EventArgs __)
        {
            if (sv.Viewport.Width <= 0) return;
            Sync();
            sv.LayoutUpdated -= First;
        }
        sv.LayoutUpdated += First;

        return new Panel { Children = { sv, left, right } };
    }

    private static Button Arrow(string glyph, HorizontalAlignment side, double artHeight)
    {
        var b = new Button
        {
            Content = glyph,
            Width = ButtonSize, Height = ButtonSize,
            CornerRadius = new CornerRadius(ButtonSize / 2),
            Background = new SolidColorBrush(Color.Parse("#cc11161f")),
            BorderBrush = new SolidColorBrush(Color.Parse("#323b4a")),
            BorderThickness = new Thickness(1),
            Foreground = Brushes.White,
            FontSize = 20, Padding = new Thickness(0, 0, 0, 3),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            HorizontalAlignment = side,
            VerticalAlignment = VerticalAlignment.Top,
            // 对齐图区中线;左右各压进去 4px,压在最边上那张卡的边缘上
            Margin = side == HorizontalAlignment.Left
                ? new Thickness(-4, artHeight / 2 - ButtonSize / 2, 0, 0)
                : new Thickness(0, artHeight / 2 - ButtonSize / 2, -4, 0),
            IsVisible = false,
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
        };
        return b;
    }
}
