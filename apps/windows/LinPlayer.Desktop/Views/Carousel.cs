using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Templates;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 首页那种横向轨道:一排卡片 + 两侧的翻页按钮。
///
/// <para><b>光有滚轮是不够的</b>。一条轨道能放 20 张卡,而屏幕上一次只看得到五六张 ——
/// 后面那十几张<b>没有任何东西告诉用户它们存在</b>。鼠标滚轮在横向滚动区上的行为
/// 还依赖设备(有的鼠标只发纵向),触控板用户和滚轮用户看到的是两个不同的应用。</para>
///
/// <para>按钮<b>按能不能滚来显隐</b>,不是常驻。到头了还亮着一个点不动的按钮,
/// 用户会以为卡住了。</para>
/// </summary>
public static class Carousel
{
    /// <summary>翻页按钮的直径。</summary>
    private const double ButtonSize = 40;

    /// <summary>
    /// 一次翻多少:视口的 80%。
    ///
    /// <para>不翻满一屏是故意的 —— 留一张卡在视野里,用户才知道自己是<b>接着</b>看
    /// 而不是跳到了另一段。整屏翻页会丢掉位置感。</para>
    /// </summary>
    private const double PageFactor = 0.8;

    /// <summary>
    /// 包一层。<paramref name="artHeight"/> 是卡片图区的高度 ——
    /// 按钮要对齐**图的中线**,不是整张卡的中线(卡片下面还有两行标题,
    /// 按整张卡居中的话按钮会偏低,看着像没对准)。
    /// </summary>
    public static Control Wrap(Control row, double artHeight) => Wrap(row, artHeight, out _);

    public static Control Wrap(Control row, double artHeight, out ScrollViewer scroller)
    {
        var sv = new ScrollViewer
        {
            // 滚动条藏起来:轨道下面横着一条滚动条会把卡片标题挤开,
            // 而翻页按钮已经把「还能往右」这件事说清楚了。
            HorizontalScrollBarVisibility = ScrollBarVisibility.Hidden,
            VerticalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = row,
        };

        /* 按住左键拖着滑。翻页按钮一次只走 80%,而「从第 3 集拖到第 300 集」
           点按钮要点四十下 —— 用户 2026-09-12 要的就是这个。 */
        Smooth.EnableDrag(sv);

        var left = Arrow("‹", HorizontalAlignment.Left);
        var right = Arrow("›", HorizontalAlignment.Right);
        /* 翻页键也要跟着缩。窗口拉窄之后卡只剩 104 宽,而两颗 40px 的按钮
           左右各占一块 —— 加起来把一整张卡盖掉了。 */
        Responsive.Watch(sv, avail =>
        {
            var d = Responsive.S(avail, ButtonSize, 26);
            foreach (var b in new[] { left, right })
            {
                b.Width = b.Height = d;
                b.CornerRadius = new CornerRadius(d / 2);
                b.FontSize = Responsive.Font(avail, 20, 14);
                b.Margin = new Thickness(
                    b.HorizontalAlignment == HorizontalAlignment.Left ? -4 : 0,
                    artHeight / 2 - d / 2, b.HorizontalAlignment == HorizontalAlignment.Left ? 0 : -4, 0);
            }
        });
        // 对齐**图区中线**,不是整张卡的中线(卡下面还有两行标题,按整张卡居中会偏低);
        // 左右各压进去 4px,压在最边上那张卡的边缘上。
        foreach (var (b, side) in new[] { (left, HorizontalAlignment.Left), (right, HorizontalAlignment.Right) })
        {
            b.VerticalAlignment = VerticalAlignment.Top;
            b.Margin = side == HorizontalAlignment.Left
                ? new Thickness(-4, artHeight / 2 - ButtonSize / 2, 0, 0)
                : new Thickness(0, artHeight / 2 - ButtonSize / 2, -4, 0);
            b.IsVisible = false;
        }

        void Sync()
        {
            var max = sv.Extent.Width - sv.Viewport.Width;
            // 1px 容差:浮点算出来的 max 常常差个零点几,严格比较会让按钮在到头时闪
            left.IsVisible = sv.Offset.X > 1;
            right.IsVisible = sv.Offset.X < max - 1;
        }

        /* 翻页和滚轮**共用同一套缓动**(Smooth)。
           这里原本有一份自己写的 12 帧 DispatcherTimer 补间 —— 手感和别处对不上,
           而且 16ms 闹钟和刷新率对不齐,滑到一半会顿一下。
           一个应用里有两套滚动手感,比只有一套糙的更糟。 */
        left.Click += (_, _) => Smooth.GlideX(sv, -sv.Viewport.Width * PageFactor);
        right.Click += (_, _) => Smooth.GlideX(sv, sv.Viewport.Width * PageFactor);
        // 触控板的横向手势不用在这儿接:Smooth 是类级处理器,对所有 ScrollViewer 都生效。
        sv.ScrollChanged += (_, _) => Sync();

        /* 首次要等布局算完再判:构造时 Viewport/Extent 都是 0,当场判等于两个按钮都不出现。
            量到了就把这个处理器摘掉 —— LayoutUpdated 在这一页活着的时候会**一直发**,
            而之后的变化 ScrollChanged 已经盯着了。留着是白烧 CPU。 */
        void First(object? _, EventArgs __)
        {
            if (sv.Viewport.Width <= 0) return;
            Sync();
            sv.LayoutUpdated -= First;
        }
        sv.LayoutUpdated += First;

        scroller = sv;
        return new Panel { Children = { sv, left, right } };
    }

    /// <summary>
    /// 轨道里卡与卡之间留多宽。
    ///
    /// <para>2026-09-04 之前是 0 —— <see cref="VirtualizingStackPanel"/> 没有 Spacing,
    /// 而 <see cref="Card"/> 自己不带外边距(首页那种轨道是靠 StackPanel.Spacing 撑开的),
    /// 于是所有走 Rail 的地方卡片一张贴着一张(用户:「季封面之间的间距太小」)。
    /// 取 16 而不是抄首页那个 12:分集卡有剧照 + 两行字,贴太近看着像糊在一起。
    /// 「跳到第 N 集」算滚动位置也要用这个数,所以它是 public。</para>
    /// </summary>
    public const double RailGap = 16;

    /// <summary>
    /// 会虚拟化的横向轨道:一排卡 + 两侧翻页按钮。
    ///
    /// <para>用户 2026-09-03:「集数和演职人员不要一口气全显示出来,遇到上千集的
    /// 不一下子卡死了,做成一行的,点左右按钮滑动」。「做成一行」本身解决不了卡死
    /// —— 一行一千张卡还是一千张卡。真正省下来的是 <see cref="VirtualizingStackPanel"/>:
    /// 屏幕上放得下几张就只造几张。<paramref name="scroller"/> 传给「跳到第 N 集」用。</para>
    /// </summary>
    /// <param name="gap">卡与卡之间留多宽。默认 <see cref="RailGap"/>;首页那种轨道传 12,
    /// 因为它历史上就是 12,改了用户当场看得出来 —— 而这一轮没人要求改首页的间距。</param>
    public static Control Rail<T>(IReadOnlyList<T> items, Func<T, Control> make,
        double artHeight, out ScrollViewer scroller, double gap = RailGap)
        => Wrap(Virtualized(items, make, Orientation.Horizontal, gap), artHeight, out scroller);

    /// <summary>
    /// 竖着的那一版:一列会虚拟化的行,自己带滚动条并封顶在 <paramref name="maxHeight"/>。
    ///
    /// <para><b>必须封顶。</b> 详情页整页本来就在一个竖向 ScrollViewer 里,
    /// 不封顶的话外层用无限高去量它,虚拟化面板会把上千行<b>全部造出来</b>
    /// —— 那正是横排轨道当初要躲开的东西。</para>
    /// </summary>
    public static Control Column<T>(IReadOnlyList<T> items, Func<T, Control> make,
        double maxHeight, out ScrollViewer scroller, double gap = 10)
    {
        var sv = new ScrollViewer
        {
            MaxHeight = maxHeight,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = Virtualized(items, make, Orientation.Vertical, gap),
        };
        scroller = sv;
        return sv;
    }

    /// <summary>
    /// 会虚拟化的一维列表。横排和竖排共用这一份 ——
    /// 下面那条 null 守卫是拿一次真崩换来的,不该有第二份实现。
    /// </summary>
    private static ItemsControl Virtualized<T>(IReadOnlyList<T> items, Func<T, Control> make,
        Orientation dir, double gap)
    {
        var pad = dir == Orientation.Horizontal
            ? new Thickness(0, 0, gap, 0) : new Thickness(0, 0, 0, gap);
        return new ItemsControl
        {
            // 这一行就是虚拟化的开关。不设的话默认 StackPanel,全量实例化。
            ItemsPanel = new FuncTemplate<Panel?>(() =>
                new VirtualizingStackPanel { Orientation = dir }),
            // 间距只能加在**每一项自己**身上:虚拟化面板没有 Spacing,
            // 而外面那层 ItemsControl 的 Spacing 对虚拟化面板不生效。
            /* 第三个参数(supportsRecycling)<b>必须是 false</b>。
               它 2026-09-04 之前是 true —— 而这个模板是**照着数据现造控件**的
               (`make(it)` 里读的是那一条的 id、标题、海报地址)。
               ContentPresenter 一看见 true,换内容时就不再走一遍模板,
               只把旧控件的 DataContext 换掉;我们的卡片一个绑定都没有,
               于是它原样留在那儿 —— 表现是滑几屏之后卡片重复/错位,而且不报错。 */
            ItemTemplate = new FuncDataTemplate<T>((it, _) =>
            {
                /* ☠ <b>这一条可能是 null。</b> 卡片滑出视野时虚拟化面板会回收容器,
                   而回收的第一步是把 ContentPresenter 的内容置空 ——
                   置空同样触发一次模板构建,入参就是 null。ItemTemplate 是显式给的,
                   不走 Match,拦不住。make 读的是这一条的字段,于是当场 NRE,
                   并且抛在**布局过程里**:这一趟测量整个作废,后面的卡再也造不出来,
                   下一帧重来一遍又抛一次 —— 用户 2026-09-12 看到的
                   「只显示前 7 集、一直往右就卡死」就是这个,不是加载慢。 */
                if (it is null) return new Control();
                var c = make(it);
                c.Margin = pad;
                return c;
            }, false),
            ItemsSource = items,
            /* ☠ 把最后一项那道尾间距**从量程里减掉**。
               间距只能加在每一项自己身上,于是最后一项后面也挂着一个 gap ——
               滑到底之后边上空着一条缝,最后一集贴不上边,看着像「还没到底但不动了」
               (用户 2026-09-12:「划到底之后…自动把最后一集贴边即可」)。
               负外边距是唯一不用逐项判「是不是最后一个」的改法:虚拟化面板
               手里根本没有全表,而 FuncDataTemplate 拿不到序号。 */
            Margin = dir == Orientation.Horizontal
                ? new Thickness(0, 0, -gap, 0) : new Thickness(0, 0, 0, -gap),
        };
    }

    /// <summary>
    /// 圆形翻页按钮。默认垂直居中、贴边 —— 轨道那边要对齐图区中线,自己再改。
    ///
    /// <para>首页 Hero 共用这一个:一个应用里两处「左右翻页」长得不一样,
    /// 用户会以为它们是两种不同的东西。</para>
    /// </summary>
    internal static Button Arrow(string glyph, HorizontalAlignment side)
    {
        var b = new Button
        {
            Content = glyph,
            Width = ButtonSize, Height = ButtonSize,
            CornerRadius = new CornerRadius(ButtonSize / 2),
            Background = new SolidColorBrush(Color.Parse("#cc11161f")),
            BorderBrush = Tok.Of("LineStrong"),
            BorderThickness = new Thickness(1),
            Foreground = Brushes.White,
            FontSize = 20, Padding = new Thickness(0, 0, 0, 2),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            VerticalContentAlignment = VerticalAlignment.Center,
            HorizontalAlignment = side,
            VerticalAlignment = VerticalAlignment.Center,
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
        };
        return b;
    }
}
