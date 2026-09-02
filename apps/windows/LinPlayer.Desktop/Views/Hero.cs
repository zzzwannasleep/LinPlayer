using System.Text.Json;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Animation.Easings;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Media.Transformation;
using Avalonia.Styling;
using Avalonia.Threading;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 首页顶部的大图轮播(Hero)。
///
/// <para>★★ <b>它必须全宽出血</b>。正文封在 1560 的水槽里,而这一块封进去就成了
/// 「一张居中的插图」—— 1920 的窗口上左右各留一条底色边,顶上还压着一道圆角描边。
/// 所以它挂在 <see cref="PageBase.Scrolled"/> 的<b>外面</b>(和详情页头图同一个结构),
/// 只有里面的文字按 1560 对齐,和下面几条轨道排成一条竖线。</para>
///
/// <para>★★ 轮播的正确做法是<b>交叉淡入</b>,不是横向滑动。整屏的大图做位移
/// 要在一帧里画两张全尺寸的图并且各挪各的,是这一页开销最大的动作;
/// 而观感上「滑」还会和下面轨道的横向滚动打架 —— 用户分不清哪一层在动。
/// 交叉淡入只改两个 Opacity,合成器自己就能做完。</para>
///
/// <para>★★ 慢推(Ken Burns)是这块<b>唯一的持续动效</b>:一张静止的大图挂在那儿
/// 七秒,人眼会读成「卡住了」。9 秒 1.00→1.07 的缓慢放大慢到看不出在动,
/// 但一眼就能看出这一块是活的。这是流媒体客户端的通行做法。</para>
///
/// <para>★★ <b>所有动效都走 <see cref="Transitions"/>,一条 <see cref="Animation"/> 都没有。</b>
/// 不是风格选择:Avalonia 11 的 Animation <b>动不了 RenderTransform</b>
/// (没注册 ITransform 的动画器),而 <c>RunAsync</c> 又只收 Visual ——
/// 拿 Transform 对象当目标会当场 InvalidCastException。
/// 两条都实测撞过,而且都是从 <c>_ = Go(...)</c> 里抛的、<b>没人接</b>:
/// 症状是「轮播一张图都不出、骨架一直闪」,日志里一个字都没有。见 <see cref="Go"/>。</para>
///
/// <para>★ 停留计时和小圆点里的进度条<b>同一句话里一起起步</b>、时长相同 ——
/// 各起各的才会漂,漂出来的症状(进度满了不翻 / 没满就翻)看着像随机的。</para>
/// </summary>
public sealed class Hero : Border
{
    /// <summary>一张停留多久。★ 再短会让人来不及读完标题就翻走了。</summary>
    private static readonly TimeSpan Dwell = TimeSpan.FromSeconds(7);

    /// <summary>交叉淡入时长。</summary>
    private static readonly TimeSpan Fade = TimeSpan.FromMilliseconds(620);

    /// <summary>正文封顶宽,和 <see cref="PageBase.Scrolled"/> 那一档对齐。</summary>
    private const double BodyMax = 1560;

    private readonly CoreClient _core;
    private readonly Action<CardItem>? _onOpen;
    /// <summary>图片地址的上游根。会话回来才知道,所以由 <see cref="Show"/> 带进来。</summary>
    private string _server = "";

    private readonly Panel _art = new();
    private readonly Border _layerA, _layerB;
    private readonly ImageBrush _brushA = NewBrush(), _brushB = NewBrush();
    /// <summary>两层各自的慢推方向。见 <see cref="GoCore"/> 里那段。</summary>
    private bool _zoomA, _zoomB;
    private Border _front;              // 当前正显示的那一层
    private readonly Border _skel;
    private readonly StackPanel _body = new() { Spacing = 12 };
    private readonly StackPanel _dots = new()
    {
        Orientation = Orientation.Horizontal, Spacing = 7,
        HorizontalAlignment = HorizontalAlignment.Right,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Button _prev, _next;

    private readonly List<JsonElement> _items = [];
    private Task<Bitmap?>[] _bg = [], _logo = [];
    private int _idx = -1;

    private bool _hover;
    private bool _alive;
    private bool _cycling;
    private CancellationTokenSource? _tick;

    public Hero(CoreClient core, Action<CardItem>? onOpen)
    {
        _core = core; _onOpen = onOpen;

        _layerA = NewLayer(_brushA);
        _layerB = NewLayer(_brushB);
        _front = _layerB;   // 第一次 Go() 会切到 A

        _skel = new Border { Classes = { "skel" }, CornerRadius = new CornerRadius(0) };

        /* ★★ 两道压暗都在<b>遮罩层里面</b>,不是盖在整块上。
           左侧那道是给文字用的:剧照的画面重点通常在中右,压左边不吃掉它。
           底部那道是给「无边框」用的 —— 全宽出血如果直接切断,
           图和页面之间会留一条硬横线,那正是「有边框」的观感。 */
        var scrimLeft = new Border
        {
            Background = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
                EndPoint = new RelativePoint(1, 0, RelativeUnit.Relative),
                GradientStops =
                {
                    new GradientStop(Color.Parse("#a6000000"), 0),
                    new GradientStop(Color.Parse("#3d000000"), 0.32),
                    new GradientStop(Color.Parse("#00000000"), 0.62),
                },
            },
        };
        var scrimBottom = new Border
        {
            Background = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
                EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops =
                {
                    new GradientStop(Color.Parse("#00000000"), 0.42),
                    new GradientStop(Color.Parse("#66000000"), 0.82),
                    new GradientStop(Color.Parse("#99000000"), 1),
                },
            },
        };

        _art.Children.Add(_skel);
        _art.Children.Add(_layerA);
        _art.Children.Add(_layerB);
        _art.Children.Add(scrimLeft);
        _art.Children.Add(scrimBottom);
        /* ★ 底边<b>用遮罩化开</b>,不是盖一层页面底色的渐变 ——
           盖色要知道当前主题的底色,而本仓有深浅两套皮,写死色号等于浅色主题下
           头顶一道黑边。遮罩让页面底色自己透上来,换皮不用改这里。
           ★ 只化开最后 12%:化太多的话文字会落到已经透明的那一段上,
             浅色主题下白字压在米黄底上直接读不出来。 */
        _art.OpacityMask = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(Colors.White, 0),
                new GradientStop(Colors.White, 0.88),
                new GradientStop(Color.FromArgb(0, 255, 255, 255), 1),
            },
        };

        // 文字列:按 1560 对齐,和下面几条轨道排成一条竖线
        var content = new Border
        {
            MaxWidth = BodyMax, HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(18, 0, 18, 0),
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 64),
            Child = _body,
        };
        var dotsHost = new Border
        {
            MaxWidth = BodyMax, HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(18, 0, 18, 0),
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 26),
            Height = 14,
            Child = _dots,
        };

        _prev = Carousel.Arrow("‹", HorizontalAlignment.Left);
        _next = Carousel.Arrow("›", HorizontalAlignment.Right);
        _prev.Margin = new Thickness(16, 0, 0, 0);
        _next.Margin = new Thickness(0, 0, 16, 0);
        _prev.Click += (_, _) => Jump(_idx - 1);
        _next.Click += (_, _) => Jump(_idx + 1);
        foreach (var b in new[] { _prev, _next })
        {
            /* ★ 常驻两个箭头会一直压在画面上;悬停才出。
               不悬停时**同时**关掉命中测试 —— 只把 Opacity 归零的话它照样吃掉点击,
               而用户点的是整块 Hero(进详情),表现是「左右两边点了没反应」。 */
            b.IsVisible = true;
            b.Opacity = 0;
            b.IsHitTestVisible = false;
            b.Transitions =
            [
                new DoubleTransition
                {
                    Property = OpacityProperty,
                    Duration = TimeSpan.FromMilliseconds(160),
                    Easing = new CubicEaseOut(),
                },
            ];
        }

        Child = new Panel { Children = { _art, content, dotsHost, _prev, _next } };
        ClipToBounds = true;
        /* ★★ 底色必须是 <b>Transparent</b>,不能写一个色号。
           这一层在遮罩<b>外面</b>:图的下沿被遮罩化开之后,透出来的是这里的底色。
           写死 #11161f 的话深色主题下是一条几乎看不出的暗带(页面底色 #0c0f14),
           而<b>浅色主题下就是一条黑边</b> —— 米黄底的页面顶着一块深色砖。
           Transparent 让页面自己的底色透上来,换皮不用改这里。
           ★ 用 Transparent 不是 null:null 的 Border 不参与命中测试,
             整块可点和悬停暂停会一起失灵。 */
        Background = Brushes.Transparent;
        Cursor = new Cursor(StandardCursorType.Hand);
        Height = 340;   // 数据没到之前也要占住位置,否则内容一来整页往下跳
        IsVisible = false;

        SizeChanged += (_, _) => Resize();

        PointerEntered += (_, _) => { _hover = true; Hover(true); _tick?.Cancel(); };
        PointerExited += (_, _) => { _hover = false; Hover(false); };
        /* ★ 整块可点 → 进详情。不摆「播放 / 详情」两个按钮是想清楚的取舍:
           剧集的「播放」要先知道接着看第几集(又一次往返),
           而进了详情页那个按钮本来就在,而且带着集号。 */
        PointerReleased += (_, e) =>
        {
            if (e.InitialPressMouseButton != MouseButton.Left) return;
            if (_idx >= 0 && _idx < _items.Count) _onOpen?.Invoke(CardItem.From(_items[_idx]));
        };

        /* ★★ 生命周期挂在**视觉树**上,不是构造函数。
           Nav.Back() 回到首页时**复用的是同一个 HomePage 实例** ——
           把轮播永久停掉的话,从详情页退回来 Hero 就再也不动了,而且不报错。
           挂 Attached / Detached 才能一停一起。 */
        AttachedToVisualTree += (_, _) => { _alive = true; if (_items.Count > 0) Start(); };
        DetachedFromVisualTree += (_, _) => { _alive = false; _tick?.Cancel(); };
    }

    /// <summary>
    /// 高度按宽度算。
    /// <para>★ 0.27:1560 的内容宽上约 420px —— 和用户 2026-07-16 定的 26/7 基本同高。
    /// 封顶 420 是为了 4K:不封的话 3840 宽会算出一屏都装不下的一块。</para>
    /// </summary>
    private void Resize()
    {
        var h = Math.Clamp(Bounds.Width * 0.27, 260, 420);
        if (Math.Abs(h - Height) > 0.5) Height = h;
    }

    private static ImageBrush NewBrush() => new()
    {
        Stretch = Stretch.UniformToFill,
        AlignmentY = AlignmentY.Center,
    };

    /// <summary>缩放量。<paramref name="v"/> = 1 就是原样。</summary>
    private static ITransform Zoom(double v) => TransformOperations.Parse($"scale({v})");

    private static Border NewLayer(ImageBrush brush) => new()
    {
        Background = brush,
        Opacity = 0,
        // ★ 起手就给一个 scale(1):从 null 变过去不会走过渡,第一张会「啪」地跳一下
        RenderTransform = Zoom(1),
        RenderTransformOrigin = RelativePoint.Center,
        Transitions =
        [
            new DoubleTransition { Property = OpacityProperty, Duration = Fade, Easing = new CubicEaseInOut() },
            /* 慢推:9 秒推 7%。★ 时长比停留时间(7s)长一截 ——
               正好推完的话末尾会停住,而停住的那一下反而看得出来。
               ★ 线性:缓动会让「起步一下、末尾一下」被看出来,而慢推的全部意义是看不出来。 */
            new TransformOperationsTransition
            {
                Property = RenderTransformProperty,
                Duration = TimeSpan.FromSeconds(9), Easing = new LinearEasing(),
            },
        ],
    };

    /// <summary>
    /// 先把位置占住(骨架)。
    ///
    /// <para>★★ Hero 在**页面最顶上**,它一出现下面<b>整页</b>都会被顶下去 ——
    /// 用户正看着的轨道会当场跳走。所以一确认这是 Emby 会话就先占位,
    /// 别等图回来。这一页别处的轨道早就是这么做的,漏了最该做的这一块。</para>
    /// </summary>
    public void Reserve() => Dispatcher.UIThread.Post(() => IsVisible = true);

    /// <summary>拿不到随机推荐:整块收掉。</summary>
    public void Hide() => Dispatcher.UIThread.Post(() => IsVisible = false);

    /// <summary>数据到了。<paramref name="items"/> 空 = 整块不画(不留空高度)。</summary>
    public void Show(string server, List<JsonElement> items)
    {
        if (!Dispatcher.UIThread.CheckAccess())
        {
            Dispatcher.UIThread.Post(() => Show(server, items));
            return;
        }
        _server = server;
        _items.Clear();
        _items.AddRange(items);
        if (_items.Count == 0) { IsVisible = false; return; }
        IsVisible = true;

        /* ★★ 几张图<b>一起预取</b>。翻页时才去拉的话,每翻一张都要等一次网络 ——
           交叉淡入淡到一半发现下一张还没到,就成了「淡出到一片空白再淡回来」。
           Images 那层解好的位图是留着的,所以第二轮翻回来是零成本。 */
        _bg = _items.Select(it => Images.LoadAsync(_core,
            Images.EmbyImageUrl(_server, Id(it), "Backdrop"), 720)).ToArray();
        /* ★ 艺术字(Logo)<b>没有 has_logo 这个字段可判</b>,只能拉了才知道有没有。
           拉不到返回 null → 回落成文字标题。旧 React 版也是这么做的(onError)。 */
        _logo = _items.Select(it => Images.LoadAsync(_core,
            Images.EmbyImageUrl(_server, Id(it), "Logo"), 184)).ToArray();

        BuildDots();
        _prev.IsVisible = _next.IsVisible = _items.Count > 1;
        if (_alive) Start();
    }

    private void Start()
    {
        if (_idx < 0) _ = Go(0);
        // ★ 只跑一路循环。Attached 会在「详情页返回首页」时再发一次,
        //   不守这一下就会每回来一次多一条,翻页速度成倍加快。
        if (_cycling) return;
        _cycling = true;
        _ = Cycle();
    }

    /// <summary>手动翻页:打断当前这一轮,立刻换过去。</summary>
    private void Jump(int to)
    {
        if (_items.Count == 0) return;
        var i = ((to % _items.Count) + _items.Count) % _items.Count;
        _tick?.Cancel();
        _ = Go(i);
    }

    /// <summary>
    /// 自动翻页。
    ///
    /// <para>★★ <b>没有定时器</b> —— 计时的就是小圆点里那条进度动画本身。
    /// 它跑完 = 该翻页了,被取消 = 用户悬停或手动翻了页。
    /// 两套时钟必然会漂,而漂出来的症状(进度满了不翻 / 没满就翻)
    /// 看起来像随机的,查起来最费劲。</para>
    /// </summary>
    private async Task Cycle()
    {
        if (_items.Count < 2) { _cycling = false; return; }
        while (true)
        {
            // 页面不在屏上(进了详情页)就停下等,别在后台空转翻页
            while (!_alive) await Task.Delay(240);

            var cts = new CancellationTokenSource();
            _tick = cts;
            var done = await Progress(cts.Token);
            if (!done)
            {
                // 被打断:等用户把鼠标挪开再重新计时(从头计,不接着上一次的进度)
                while (_hover && _alive) await Task.Delay(160);
                continue;
            }
            Jump(_idx + 1);
        }
    }

    /// <summary>
    /// 停留一轮:小圆点里那条进度条走满 <see cref="Dwell"/>。返回 true = 正常走完。
    ///
    /// <para>★ 计时用 <c>Task.Delay</c>、画面用过渡,两者<b>同一句话里起步、同一个时长</b>。
    /// 各起各的时钟才会漂。</para>
    /// </summary>
    private async Task<bool> Progress(CancellationToken token)
    {
        if (_idx < 0 || _idx >= _dots.Children.Count
            || _dots.Children[_idx] is not Border pill || pill.Child is not Border fill)
        {
            await Task.Delay(240, CancellationToken.None);
            return false;
        }
        Snap(fill, Wide(0));
        Dispatcher.UIThread.Post(() => fill.RenderTransform = Wide(1), DispatcherPriority.Background);
        try { await Task.Delay(Dwell, token); }
        catch (OperationCanceledException) { }
        if (!token.IsCancellationRequested) return true;
        Snap(fill, Wide(0));   // 被打断:进度条要退回去,不能停在半截上
        return false;
    }

    /// <summary>横向拉伸(进度条填充用)。</summary>
    private static ITransform Wide(double v) => TransformOperations.Parse($"scaleX({v})");

    /// <summary>
    /// <b>不走过渡</b>地把变换设上去。
    /// <para>★ 复位必须瞬时:带着 7 秒过渡去「归零」的话,进度条会用 7 秒慢慢退回去,
    /// 而那 7 秒里它正在为下一张往前走 —— 两边打架,看着就是随机乱抖。</para>
    /// </summary>
    private static void Snap(Animatable a, ITransform v)
    {
        var t = a.Transitions;
        a.Transitions = null;
        a.SetValue(Visual.RenderTransformProperty, v);
        a.Transitions = t;
    }

    /// <summary>
    /// 切到第 <paramref name="i"/> 张。
    ///
    /// <para>★★ 这个方法全程是 <c>_ = Go(...)</c> 发出去的,<b>里面抛的异常没人接</b> ——
    /// 它会被吞进那个没人 await 的 Task 里,表现是「轮播就是不动」:
    /// 不报错、不崩、骨架一直闪。所以整个身子包一层,抛了就说出来。</para>
    /// </summary>
    private async Task Go(int i)
    {
        try { await GoCore(i); }
        catch (Exception e) { Console.WriteLine("[Hero] 切图失败: " + e); }
    }

    private async Task GoCore(int i)
    {
        if (i < 0 || i >= _items.Count) return;
        _idx = i;
        SyncDots();
        RenderBody(_items[i], _logo[i]);

        var back = ReferenceEquals(_front, _layerA) ? _layerB : _layerA;
        var brush = ReferenceEquals(back, _layerA) ? _brushA : _brushB;

        var bmp = await _bg[i];
        // 翻得比图快:等这张图的时候用户已经翻走了,别把它硬塞上去
        if (_idx != i) return;
        if (bmp is null)
        {
            Console.WriteLine($"[Hero] 第 {i + 1} 张没有剧照,回退海报");
            /* ★ listRandom 只挑有剧照的条目(ImageTypes=Backdrop),但取图仍然可能失败。
               退回海报 —— 比例不对(2:3 铺进 26:7)会裁得很凶,但总比一块空底强。 */
            bmp = await Images.LoadAsync(_core, Images.EmbyImageUrl(_server, Id(_items[i]), "Primary"), 720);
            if (bmp is null) Console.WriteLine($"[Hero] 第 {i + 1} 张连海报也取不到(server={_server})");
            if (_idx != i || bmp is null) return;
        }

        brush.Source = bmp;
        _skel.IsVisible = false;
        back.Opacity = 1;
        _front.Opacity = 0;
        _front = back;

        /* 慢推。★★ <b>两层各自来回推,不复位</b> —— 这一层这次 1.00→1.07,
           下次轮到它就 1.07→1.00。每次都归零的话要先关掉过渡、设值、再打开,
           而关掉过渡的那一瞬间交叉淡入也在同一个 Transitions 里,会一起被掐掉。
           来回推还更好看:连着两张不会都往同一个方向涨。 */
        if (ReferenceEquals(back, _layerA)) { _zoomA = !_zoomA; back.RenderTransform = Zoom(_zoomA ? 1.07 : 1.0); }
        else { _zoomB = !_zoomB; back.RenderTransform = Zoom(_zoomB ? 1.07 : 1.0); }
    }

    /// <summary>
    /// 文字列:艺术字(或标题)+ 标签行。
    ///
    /// <para>★★ 入场是<b>上浮 + 淡入</b>,而且艺术字和标签行<b>错开 90ms</b>。
    /// 同时出现的话两行读起来是「一块贴图」;错开之后眼睛会先落在片名再落到标签,
    /// 这就是版式的阅读顺序。90ms 是能感觉到先后、又不显得拖沓的下限。</para>
    /// </summary>
    private void RenderBody(JsonElement it, Task<Bitmap?> logo)
    {
        _body.Children.Clear();

        var title = new ContentControl { HorizontalAlignment = HorizontalAlignment.Left };
        // 先摆文字标题;艺术字取到了再换上去(取不到就一直是文字,不留空)
        title.Content = TitleText(ItemName(it));
        _ = SwapLogo(title, logo, Id(it));

        var tags = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        var year = (int)Num(it, "year");
        if (year > 0) tags.Children.Add(Pill(year.ToString(), false));
        if (TypeName(Str(it, "type_")) is { Length: > 0 } tn) tags.Children.Add(Pill(tn, false));
        var rating = Num(it, "rating");
        if (rating > 0) tags.Children.Add(Pill($"★ {rating:0.0}", true));
        foreach (var g in Genres(it).Take(3)) tags.Children.Add(Pill(g, false));

        _body.Children.Add(title);
        if (tags.Children.Count > 0) _body.Children.Add(tags);

        Enter(title, 0);
        if (tags.Children.Count > 0) Enter(tags, 90);
    }

    /// <summary>
    /// 入场:上浮 + 淡入。
    /// <para>★ <see cref="Animation"/> 没有 delay 这个属性,错开是靠<b>前一段保持不动的关键帧</b>
    /// 做出来的 —— 用 <c>Task.Delay</c> 排的话动画起点会落在任意一帧上,
    /// 两行的错开量每次都不一样。</para>
    /// </summary>
    private static void Enter(Control target, int delayMs)
    {
        target.Opacity = 0;
        target.RenderTransform = TransformOperations.Parse("translateY(18px)");
        target.Transitions =
        [
            new DoubleTransition
            {
                Property = OpacityProperty, Duration = TimeSpan.FromMilliseconds(420),
                Delay = TimeSpan.FromMilliseconds(delayMs), Easing = new CubicEaseOut(),
            },
            new TransformOperationsTransition
            {
                Property = RenderTransformProperty, Duration = TimeSpan.FromMilliseconds(420),
                Delay = TimeSpan.FromMilliseconds(delayMs), Easing = new CubicEaseOut(),
            },
        ];
        /* ★★ 目标值要<b>下一轮才设</b>。过渡是靠「属性变了」触发的 ——
           同一轮里先设 0 再设 1,布局系统只会看到最终值 1,过渡一次都不会跑,
           表现是「入场动效没有」而不是报错。 */
        Dispatcher.UIThread.Post(() =>
        {
            target.Opacity = 1;
            target.RenderTransform = TransformOperations.Parse("translateY(0px)");
        }, DispatcherPriority.Background);
    }

    /// <summary>艺术字到了就换掉文字标题。取不到(不少库只给电影刮 Logo)就保持文字。</summary>
    private async Task SwapLogo(ContentControl host, Task<Bitmap?> logo, string id)
    {
        var bmp = await logo;
        if (bmp is null) return;
        // ★ 翻页比取图快时,别把上一张的艺术字贴到这一张上
        if (_idx < 0 || _idx >= _items.Count || Id(_items[_idx]) != id) return;
        Dispatcher.UIThread.Post(() => host.Content = new Image
        {
            Source = bmp,
            Stretch = Stretch.Uniform,
            MaxHeight = 96, MaxWidth = 460,
            HorizontalAlignment = HorizontalAlignment.Left,
            Effect = Shadow(),
        });
    }

    /// <summary>
    /// 回落的文字标题。
    /// <para>★ 字号字重要压得住一张照片,而且照样得配投影:36px Bold 落在剧照的高光上
    /// 一样会糊掉。艺术字那条路共用同一道投影。</para>
    /// </summary>
    private static Control TitleText(string name) => new TextBlock
    {
        Text = name, FontSize = 36, FontWeight = FontWeight.Bold,
        LetterSpacing = -0.6, LineHeight = 42,
        MaxWidth = 720, MaxLines = 2, TextWrapping = TextWrapping.Wrap,
        TextTrimming = TextTrimming.CharacterEllipsis,
        Foreground = Brushes.White,
        Effect = Shadow(),
    };

    private static IEffect Shadow() => new DropShadowEffect
    {
        BlurRadius = 16, OffsetX = 0, OffsetY = 2,
        Color = Colors.Black, Opacity = 0.85,
    };

    /// <summary>
    /// 标签胶囊。
    /// <para>★ 压在照片上的胶囊要自带半透明底 + 一圈浅描边 —— 光靠文字颜色的话,
    /// 底下是亮画面时整行就没了。评分单独用暖色:它是这一行里唯一「有高低」的值。</para>
    /// </summary>
    private static Control Pill(string text, bool warm) => new Border
    {
        Padding = new Thickness(10, 4),
        CornerRadius = new CornerRadius(999),
        Background = new SolidColorBrush(Color.Parse("#59000000")),
        BorderBrush = new SolidColorBrush(Color.Parse("#40ffffff")),
        BorderThickness = new Thickness(1),
        Child = new TextBlock
        {
            Text = text, FontSize = 12,
            Foreground = new SolidColorBrush(Color.Parse(warm ? "#e0a95b" : "#e8ebf1")),
        },
    };

    /// <summary>
    /// 小圆点。当前那颗是一条 <b>28px 的进度胶囊</b>,不是一个变大的点。
    ///
    /// <para>★★ 它同时说了两件事:现在是第几张、<b>还有多久翻页</b>。
    /// 只做「当前点变亮」的话,画面自己动起来的那一刻用户是没有预期的 ——
    /// 正在读标题时突然换了一张,那种被打断的感觉就是「动效做错了」。</para>
    /// </summary>
    private void BuildDots()
    {
        _dots.Children.Clear();
        if (_items.Count < 2) return;
        for (var i = 0; i < _items.Count; i++)
        {
            var idx = i;
            var fill = new Border
            {
                Background = new SolidColorBrush(Color.Parse("#5b8def")),
                CornerRadius = new CornerRadius(999),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                // ★ 进度用 RenderTransform 缩放,不动 Width —— 动 Width 是每帧一次布局
                RenderTransformOrigin = new RelativePoint(0, 0.5, RelativeUnit.Relative),
                RenderTransform = Wide(0),
                // 进度条本身的过渡:线性走满 Dwell(计时那半在 Progress 里)
                Transitions =
                [
                    new TransformOperationsTransition
                    {
                        Property = RenderTransformProperty, Duration = Dwell, Easing = new LinearEasing(),
                    },
                ],
            };
            var pill = new Border
            {
                Height = 6, Width = 7,
                CornerRadius = new CornerRadius(999),
                Background = new SolidColorBrush(Color.Parse("#66ffffff")),
                ClipToBounds = true,
                Cursor = new Cursor(StandardCursorType.Hand),
                VerticalAlignment = VerticalAlignment.Center,
                Child = fill,
                Transitions =
                [
                    new DoubleTransition
                    {
                        Property = WidthProperty,
                        Duration = TimeSpan.FromMilliseconds(240),
                        Easing = new CubicEaseOut(),
                    },
                ],
            };
            pill.PointerReleased += (_, e) => { e.Handled = true; Jump(idx); };
            _dots.Children.Add(pill);
        }
    }

    private void SyncDots()
    {
        for (var i = 0; i < _dots.Children.Count; i++)
        {
            if (_dots.Children[i] is not Border pill) continue;
            pill.Width = i == _idx ? 28 : 7;
            // ★ 非当前那几颗要把进度**清零**:不清的话翻回来时是满的,一眼就穿帮
            if (i != _idx && pill.Child is Border fill) Snap(fill, Wide(0));
        }
    }

    private void Hover(bool on)
    {
        if (_items.Count < 2) return;
        foreach (var b in new[] { _prev, _next })
        {
            b.Opacity = on ? 1 : 0;
            b.IsHitTestVisible = on;
        }
    }

    private static string TypeName(string t) => t switch
    {
        "Movie" => "电影",
        "Series" => "剧集",
        "Season" => "季",
        "Episode" => "剧集",
        _ => "",
    };

    private static string Id(JsonElement e) => Str(e, "id");
    private static string ItemName(JsonElement e) => Str(e, "name");

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
    private static List<string> Genres(JsonElement e) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty("genres", out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x != "").ToList() : [];

    /// <summary>
    /// 自检。<paramref name="n"/> &gt; 0 = 翻到第 n 张并<b>采样动效曲线</b>;
    /// n = 0 = 什么都不碰,隔 8 秒看它自己有没有翻过去。
    ///
    /// <para>★★ <b>轮播「在不在动」靠截图是判不出来的</b> —— 一张静止的大图和一个
    /// 停住的轮播长得一模一样,而停住恰恰是最容易发生的失败:
    /// 循环挂在异常上、协程被取消、过渡没触发。这一版做的过程里
    /// <b>三次</b>都是这个症状(Animation 动不了 RenderTransform / RunAsync 只收 Visual /
    /// 同一轮里设了初值又设终值),而三次的截图都「看着挺正常」。
    /// 所以这里<b>把数采出来</b>:透明度、慢推的缩放、进度条的填充,隔几百毫秒读一遍。
    /// 数在动 = 动效在跑;数不动 = 静止的一张图。</para>
    /// </summary>
    internal void SelfCheckJump(int n)
    {
        if (n <= 0) { _ = Watch(); return; }
        Dispatcher.UIThread.Post(async () =>
        {
            Jump(n - 1);
            Console.WriteLine($"[Hero 自检] 共 {_items.Count} 张,现在第 {_idx + 1} 张:{Cur()};" +
                              $"高 {Height:0}px,圆点 {_dots.Children.Count} 颗,骨架可见={_skel.IsVisible}");
            foreach (var at in new[] { 0, 220, 500, 1000, 2000 })
            {
                if (at > 0) await Task.Delay(at - Prev(at));
                Console.WriteLine($"[Hero 动效] +{at,4}ms  A 透明度 {_layerA.Opacity:0.00} 慢推 {Scale(_layerA):0.000}" +
                                  $" | B 透明度 {_layerB.Opacity:0.00} 慢推 {Scale(_layerB):0.000}" +
                                  $" | 进度条 {Fill():0.00}");
            }
        });

        static int Prev(int at) => at switch { 220 => 0, 500 => 220, 1000 => 500, _ => 1000 };
    }

    /// <summary>不干预,隔 8 秒(&gt; 停留 7 秒)看它自己翻过去没有。</summary>
    private async Task Watch()
    {
        await Task.Delay(2500);
        var a = _idx; var an = Cur();
        Console.WriteLine($"[Hero 自动翻页] 第 1 次看:第 {a + 1} 张 {an}");
        await Task.Delay(8000);
        Console.WriteLine($"[Hero 自动翻页] 第 2 次看(8 秒后):第 {_idx + 1} 张 {Cur()} —— " +
                          (_idx == a ? "✗ 没动,轮播是停的" : "✓ 自己翻过去了"));
    }

    private string Cur() => _idx >= 0 && _idx < _items.Count ? ItemName(_items[_idx]) : "(空)";

    /// <summary>读出当前的慢推倍率。TransformOperations 折成矩阵,M11 就是横向缩放。</summary>
    private static double Scale(Visual v) => v.RenderTransform?.Value.M11 ?? 0;

    /// <summary>读出当前那颗圆点的进度(0~1)。</summary>
    private double Fill() =>
        _idx >= 0 && _idx < _dots.Children.Count && _dots.Children[_idx] is Border { Child: Border f }
            ? Scale(f) : -1;
}
