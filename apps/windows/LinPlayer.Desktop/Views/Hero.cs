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
/// 首页顶部的大图轮播(Hero)。全宽出血,所以挂在 <see cref="PageBase.Scrolled"/>
/// 外面 —— 封进 1560 的水槽里就成了「一张居中的插图」。
///
/// <para>交叉淡入,不横向滑动:整屏大图横滑要在一帧里画两张全尺寸图,观感上
/// 还会和下面轨道的横滚打架。慢推 9 秒 1.00→1.07 是这块唯一的持续动效。
/// 动效一律走 <see cref="Transitions"/>,一条 <see cref="Animation"/> 都不许有 ——
/// 理由和三次翻车的症状见 <c>docs/lessons/ui-desktop.md</c>。</para>
/// </summary>
public sealed class Hero : Border
{
    /// <summary>一张停留多久。 再短会让人来不及读完标题就翻走了。</summary>
    private static readonly TimeSpan Dwell = TimeSpan.FromSeconds(7);

    /// <summary>交叉淡入时长。</summary>
    private static readonly TimeSpan Fade = TimeSpan.FromMilliseconds(620);

    /// <summary>艺术字 / 标题那一格的固定高度。见 <see cref="RenderBody"/> 里那段。</summary>
    private const double TitleSlot = 92;

    private readonly CoreClient _core;
    private readonly Action<CardItem>? _onOpen;
    /// <summary>图片地址的上游根。会话回来才知道,所以由 <see cref="Show"/> 带进来。</summary>
    private string _server = "";

    private readonly Panel _art = new();
    private readonly Border _layerA, _layerB;
    /* 每一层<b>一张图 + 一支画刷</b>:
        <c>_sharp*</c> 是一个真的 <see cref="Image"/> 控件,<b>整张剧照一个像素都不裁</b>。
         <b>别用 ImageBrush</b>:实测 <c>ImageBrush{Stretch=Uniform}</c> 当 Border 的
         Background <b>什么都画不出来</b> —— 而且诊断打出来一切正常
         (Source 1280×720、遮罩 0.467→0.648、层透明度 1.00),截图上就是一片空。
         UniformToFill 那支(氛围底)倒是好好的,所以不是画刷本身的问题。
         Image 控件走的是另一条渲染路,不吃这一下。
         原来只有一支 UniformToFill:16:9 的剧照铺进 3.7:1 的槽里,上下**各切掉四分之一** ——
         那就是用户说的「封面不全」。剧照是刮削器给的成品构图,裁掉一半是我们自己的损失。
        <c>_wash*</c> 是同一张图的**极小尺寸**(h=64)拉满整块当氛围底。
         放大九倍之后它本身就是一片糊的色块 —— 等于免费的高斯模糊,
         而真上 BlurEffect 是每帧对整块 1560×420 重新做一次卷积。
        完整图<b>居中</b>,两条边各做一段羽化(见 SyncFeather)—— 2026-09-03 用户点名。 */
    private readonly Image _sharpA = NewSharp(), _sharpB = NewSharp();
    private readonly ImageBrush _washA = NewWash(), _washB = NewWash();
    /// <summary>两层各自的慢推方向。见 <see cref="GoCore"/> 里那段。</summary>
    private bool _zoomA, _zoomB;
    /// <summary>装清晰图的盒子。 自检要读它有没有被缩放(判「一个像素都没裁」)。</summary>
    private Border? _boxA, _boxB;
    /// <summary>
    /// 羽化层:压在清晰图<b>左右两条边</b>上的一叠竖条,每条画的都是同一张糊底、
    /// 透明度由外到内从 1 走到 0。见 <see cref="SyncFeather"/>。
    /// </summary>
    private readonly Panel _featherA = new(), _featherB = new();
    /// <summary>糊底那张位图。羽化条的画刷要用它,所以得留一份句柄。</summary>
    private Bitmap? _washBmpA, _washBmpB;
    /// <summary>底边化开那一层。颜色跟主题走,见 <see cref="SyncBleed"/>。</summary>
    private readonly Border _bleed = null!;
    /// <summary>慢推挂在这一层(糊底)上,<b>不是整层</b>。见 <see cref="NewLayer"/>。</summary>
    private Border? _washBoxA, _washBoxB;
    /// <summary>两层各自的图片宽高比(宽/高)。0 = 还没有图。</summary>
    private double _arA, _arB;
    private Border _front;              // 当前正显示的那一层
    private readonly Border _skel;
    /// <summary>
    /// 文字列:艺术字 + 标签行。
    ///
    /// <para><c>Spacing = 6</c>(原来 12)。用户 2026-09-03:「艺术字和标签之间的空隙比较大,
    /// 缩小」。艺术字那一格是**底对齐**的(见 <see cref="RenderBody"/>),
    /// 所以这个数就是两行之间肉眼看到的全部距离。</para>
    /// </summary>
    private readonly StackPanel _body = new() { Spacing = 6 };
    private readonly StackPanel _dots = new()
    {
        Orientation = Orientation.Horizontal, Spacing = 6,
        HorizontalAlignment = HorizontalAlignment.Right,
        VerticalAlignment = VerticalAlignment.Center,
    };
    private readonly Button _prev, _next;

    private readonly List<JsonElement> _items = [];
    private Task<Bitmap?>[] _bg = [], _wash = [], _logo = [];
    private int _idx = -1;

    private bool _hover;
    private bool _alive;
    private bool _cycling;
    /// <summary>自检钉住:停止自动翻页,让截图和日志说的是同一张。</summary>
    private bool _pinned;
    private CancellationTokenSource? _tick;

    public Hero(CoreClient core, Action<CardItem>? onOpen)
    {
        _core = core; _onOpen = onOpen;

        BuildStrips(_featherA);
        BuildStrips(_featherB);
        _layerA = NewLayer(_washA, _sharpA, _featherA, out _boxA, out _washBoxA);
        _layerB = NewLayer(_washB, _sharpB, _featherB, out _boxB, out _washBoxB);
        _front = _layerB;   // 第一次 Go() 会切到 A

        _skel = new Border { Classes = { "skel" }, CornerRadius = new CornerRadius(0) };

        /* 左侧那道压暗是给文字用的:剧照的画面重点通常在中右,压左边不吃掉它。
            它必须压在图**上面**(所以是 _art 的后一个孩子),
            压在下面等于没压 —— 而这条只有真渲染看得出来。 */
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
        /* 底边的化开从<b>遮罩</b>改成<b>渐变到页面底色</b>(2026-09-02)。
           不是审美选择:这一版整块里<b>一个 OpacityMask 都不留</b>(见 NewLayer 里那段 ),
           所以底边化开只能靠盖色。
           代价是这一层要**知道页面底色**,而本仓有深浅两套皮 ——
             所以底色从主题资源里现取,换皮时重算(见 SyncBleed)。 */
        _bleed = new Border { VerticalAlignment = VerticalAlignment.Stretch };

        _art.Children.Add(_skel);
        _art.Children.Add(_layerA);
        _art.Children.Add(_layerB);
        _art.Children.Add(scrimLeft);
        _art.Children.Add(_bleed);

        // 文字列:按 1560 对齐,和下面几条轨道排成一条竖线
        var content = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(18, 0, 18, 0),
            VerticalAlignment = VerticalAlignment.Bottom,
            /* 离底 40(原来 64)。用户 2026-09-03:「艺术字和标签往下放一点,现在放的太高」。
               下限由圆点那一行定:它在 26,高 14 —— 40 正好压在它上沿,再低就叠上去了。 */
            Margin = new Thickness(0, 0, 0, 42),
            Child = _body,
        };
        var dotsHost = new Border
        {
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(18, 0, 18, 0),
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 26),
            Height = 14,
            Child = _dots,
        };

        _prev = Carousel.Arrow("‹", HorizontalAlignment.Left);
        _next = Carousel.Arrow("›", HorizontalAlignment.Right);
        _prev.Margin = new Thickness(18, 0, 0, 0);
        _next.Margin = new Thickness(0, 0, 18, 0);
        _prev.Click += (_, _) => Jump(_idx - 1);
        _next.Click += (_, _) => Jump(_idx + 1);
        foreach (var b in new[] { _prev, _next })
        {
            /* 常驻两个箭头会一直压在画面上;悬停才出。
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
        /* 底色必须是 <b>Transparent</b>,不能写一个色号。
           这一层在遮罩<b>外面</b>:图的下沿被遮罩化开之后,透出来的是这里的底色。
           写死 #11161f 的话深色主题下是一条几乎看不出的暗带(页面底色 #0c0f14),
           而<b>浅色主题下就是一条黑边</b> —— 米黄底的页面顶着一块深色砖。
           Transparent 让页面自己的底色透上来,换皮不用改这里。
           用 Transparent 不是 null:null 的 Border 不参与命中测试,
             整块可点和悬停暂停会一起失灵。 */
        Background = Brushes.Transparent;
        Cursor = new Cursor(StandardCursorType.Hand);
        /* <b>顶上留一条间隔</b>(用户 2026-09-02:「我说无边框,不代表要顶着顶部放」)。
           「无边框」说的是<b>左右出血、不描边</b>;紧贴标题栏是另一回事 ——
           那会让整块图看上去是从窗口的边缘长出来的,压迫感很强。
           只留上边:左右一留就有边框了,下边和轨道之间靠遮罩化开。 */
        Margin = new Thickness(0, 18, 0, 0);
        Height = 340;   // 数据没到之前也要占住位置,否则内容一来整页往下跳
        IsVisible = false;

        SizeChanged += (_, _) => Resize();

        PointerEntered += (_, _) => { _hover = true; Hover(true); _tick?.Cancel(); };
        PointerExited += (_, _) => { _hover = false; Hover(false); };
        /* 整块可点 → 进详情。不摆「播放 / 详情」两个按钮是想清楚的取舍:
           剧集的「播放」要先知道接着看第几集(又一次往返),
           而进了详情页那个按钮本来就在,而且带着集号。 */
        PointerReleased += (_, e) =>
        {
            if (e.InitialPressMouseButton != MouseButton.Left) return;
            if (_idx >= 0 && _idx < _items.Count) _onOpen?.Invoke(CardItem.From(_items[_idx]));
        };

        /* 生命周期挂在**视觉树**上,不是构造函数。
           Nav.Back() 回到首页时**复用的是同一个 HomePage 实例** ——
           把轮播永久停掉的话,从详情页退回来 Hero 就再也不动了,而且不报错。
           挂 Attached / Detached 才能一停一起。 */
        SyncBleed();
        // 换皮时要重算:不重算的话浅色主题下底边是一条黑带(而且不报错)
        ActualThemeVariantChanged += (_, _) => SyncBleed();
        AttachedToVisualTree += (_, _) => { _alive = true; SyncBleed(); if (_items.Count > 0) Start(); };
        DetachedFromVisualTree += (_, _) => { _alive = false; _tick?.Cancel(); };
    }

    /// <summary>
    /// 底边化开:从透明渐变到<b>页面底色</b>,最后一段完全等于底色 ——
    /// 于是图和页面之间那条硬横线就不存在了(「无边框」要的就是这个)。
    ///
    /// <para>底色<b>从主题资源里现取</b>,不写死色号。写死的话深色下勉强能看,
    /// <b>浅色主题下就是头顶一条黑带</b>。取不到就退回深色那一档 ——
    /// 退回一个具体值总比画一块纯黑强。</para>
    /// </summary>
    private void SyncBleed()
    {
        var bg = Color.Parse("#0c0f14");
        if (this.TryFindResource("Bg", ActualThemeVariant, out var v) && v is ISolidColorBrush sb)
            bg = sb.Color;
        _bleed.Background = new LinearGradientBrush
        {
            StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
            EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
            GradientStops =
            {
                new GradientStop(Color.FromArgb(0, bg.R, bg.G, bg.B), 0.55),
                new GradientStop(Color.FromArgb(120, bg.R, bg.G, bg.B), 0.84),
                new GradientStop(bg, 1),
            },
        };
    }

    /// <summary>
    /// 羽化:让「清晰」和「模糊」之间没有那条线。
    ///
    /// <para>清晰图居中、糊底铺满整块 —— 同一个 x 上两者内容一致,只差清晰度。
    /// 所以在图的两条边内侧各铺一叠画着糊底的竖条,透明度由外到内 1 → 0。
    /// 每条竖条的 <c>DestinationRect</c> 必须用绝对坐标往左推 x,不推的话每条都是
    /// 一张被压扁的完整剧照。带宽取图宽 12%,夹在 [48,160]。
    /// 不能用 OpacityMask 做这件事 —— 见 <c>docs/lessons/ui-desktop.md</c>。</para>
    /// </summary>
    private void SyncFeather()
    {
        var w = Bounds.Width;
        var h = Height;
        if (w <= 1 || h <= 1) return;
        Apply(_arA, _featherA, _washBmpA, _washA);
        Apply(_arB, _featherB, _washBmpB, _washB);

        void Apply(double ar, Panel host, Bitmap? bmp, ImageBrush wash)
        {
            if (host.Children.Count < Strips * 2) return;
            // 还没有图 → 整叠收起来(那会儿只有糊底,本来就没有边要化)
            if (ar <= 0 || bmp is null)
            {
                foreach (var c in host.Children) c.IsVisible = false;
                return;
            }
            var imgW = Math.Min(h * ar, w);
            var left = (w - imgW) / 2;
            _ = wash;   // 糊底铺满整块,不需要按几何摆(理由见 NewWash 里那段实测)
            var right = left + imgW;
            var band = Math.Clamp(imgW * 0.12, 48, 160);
            var step = band / Strips;

            for (var i = 0; i < Strips; i++)
            {
                // 左边那叠:最外那条几乎全糊(透明度 ~1),最里那条几乎全透
                Put(host.Children[i], left + i * step, 1 - (i + 0.5) / Strips);
                // 右边那叠反过来
                Put(host.Children[Strips + i], right - band + i * step, (i + 0.5) / Strips);
            }

            void Put(Control c, double x, double op)
            {
                c.IsVisible = true;
                c.Opacity = op;
                c.Margin = new Thickness(x, 0, 0, 0);
                c.Width = step + 1;   // +1:相邻两条要**压着**,留缝的话缝里透出清晰图,成了细竖线
                if (c is Border b && b.Background is ImageBrush ib)
                {
                    ib.Source = bmp;
                    /* 目标矩形 = <b>整块糊底往左推 x</b>(和 washBox 用同一套几何:
                       满宽满高、UniformToFill)。推的是「整块的位置」,
                       不是「把整张图塞进这条 6px 的缝」—— 后者画出来是一排
                       被压扁的完整剧照,像彩色噪声。
                       这样这一条显示的正是它盖住的那一小片糊底,和背景严丝合缝,
                       而它和<b>清晰图</b>之间的差别就是这 12 条要抹掉的东西。 */
                    ib.DestinationRect = new RelativeRect(-x, 0, w, h, RelativeUnit.Absolute);
                }
            }
        }
    }

    /// <summary>
    /// 高度按宽度算。
    /// <para>0.27:1560 的内容宽上约 420px —— 和用户 2026-07-16 定的 26/7 基本同高。
    /// 封顶 420 是为了 4K:不封的话 3840 宽会算出一屏都装不下的一块。</para>
    /// </summary>
    private void Resize()
    {
        /* 0.30 而不是 0.27:完整剧照是按<b>高度</b>去 fit 的(槽比 16:9 宽得多),
           高一点右边那张图就大一圈,而这一块的主角就是那张图。 */
        var h = Math.Clamp(Bounds.Width * 0.30, 280, 460);
        if (Math.Abs(h - Height) > 0.5) Height = h;
        SyncFeather();
    }

    /// <summary>
    /// 完整剧照:<b>Uniform 不裁</b>,<b>居中</b>摆。
    /// <para>2026-09-03 从靠右改成居中(用户点名)。靠右的版本只有一条边要处理,
    /// 居中之后左右各一条 —— 但两条对称的软边看着是「一张照片浮在模糊的底上」,
    /// 而一条硬边看着是「两张图拼在一起」。</para>
    /// </summary>
    private static Image NewSharp() => new()
    {
        Stretch = Stretch.Uniform,
        HorizontalAlignment = HorizontalAlignment.Center,
        VerticalAlignment = VerticalAlignment.Stretch,
    };

    /// <summary>
    /// 糊底:老老实实铺满整块,不要「对齐清晰图 + FlipX 镜像」。
    ///
    /// <para>我推理过一版镜像方案,实测把缝做坏了:Avalonia 这里没有真的翻转,
    /// 行为等同平铺,于是「镜像连续」这个前提整个不成立,反而制造了一道 30 级的
    /// 硬边(剖面数据在 <c>docs/lessons/ui-desktop.md</c>)。教训不是镜像不好,
    /// 是我又一次拿推理当了结论。用 h=64 的小图:拉大九倍本身就是糊的,
    /// 不用 BlurEffect 每帧对 1560×420 卷积一遍。</para>
    /// </summary>
    private static ImageBrush NewWash() => new()
    {
        Stretch = Stretch.UniformToFill,
    };

    /// <summary>缩放量。<paramref name="v"/> = 1 就是原样。</summary>
    private static ITransform Zoom(double v) => TransformOperations.Parse($"scale({v})");

    /// <summary>
    /// 一层:糊底 + 完整剧照(居中) + 两条边的羽化。外面这层管透明度和慢推。
    ///
    /// <para>2026-09-03 改成居中 + 双边羽化(用户:「不要有模糊和清晰的界限,
    /// 看着有点割裂」)。上一版是清晰图靠右 + 糊底往左镜像延伸,颜色接得上、
    /// 清晰度接不上,那条竖直分界线就是他说的割裂。解法不是把颜色调得更像,
    /// 是在那条线上做真正的过渡,见 <see cref="SyncFeather"/>。</para>
    /// </summary>
    private static Border NewLayer(ImageBrush wash, Image sharp, Panel feather,
        out Border box, out Border washBox)
    {
        box = new Border { Child = sharp };
        /* 慢推(Ken Burns)只推<b>糊底这一层</b>,<b>不推清晰图</b>。
           这是被实测逼出来的:整层一起推的话,1.07 倍会把图的边缘顶出裁剪框 ——
           右边少 14px、上边少 4px。而这一块的全部意义就是「一个像素都不裁」,
           为了动效再裁回去,等于把刚修好的问题原样搬了个地方。
           糊底本来就是被 UniformToFill 裁过的氛围色块,推它不损失任何信息。
           羽化条画的是**没被推过的**糊底,所以慢推**只能**挂在 washBox 上;
             挂到整层上的话糊底在动、羽化条不动,缝会随着慢推一起呼吸。 */
        washBox = new Border
        {
            Background = wash,
            RenderTransform = Zoom(1),
            RenderTransformOrigin = RelativePoint.Center,
            Transitions =
            [
                new TransformOperationsTransition
                {
                    Property = RenderTransformProperty,
                    Duration = TimeSpan.FromSeconds(9), Easing = new LinearEasing(),
                },
            ],
        };
        return new Border
        {
            Opacity = 0,
            Child = new Panel { Children = { washBox, box, feather } },
            Transitions =
            [
                new DoubleTransition { Property = OpacityProperty, Duration = Fade, Easing = new CubicEaseInOut() },
            ],
        };
    }

    /// <summary>羽化用多少条。 条数就是过渡的台阶数 —— 少了会看出一格一格的带。</summary>
    private const int Strips = 12;

    /// <summary>
    /// 把羽化条先建出来(空的)。位置 / 画刷 / 透明度由 <see cref="SyncFeather"/> 每次填。
    ///
    /// <para><b>建一次,之后只改属性</b>。拖窗口时 SizeChanged 每帧都发,
    /// 每帧 new 24 个 Border + 24 支画刷就是每帧一次垃圾风暴。</para>
    /// </summary>
    private static void BuildStrips(Panel host)
    {
        for (var i = 0; i < Strips * 2; i++)
            host.Children.Add(new Border
            {
                HorizontalAlignment = HorizontalAlignment.Left,
                VerticalAlignment = VerticalAlignment.Stretch,
                IsHitTestVisible = false,
                Background = new ImageBrush { Stretch = Stretch.UniformToFill },
            });
    }

    /// <summary>
    /// 先把位置占住(骨架)。
    ///
    /// <para>Hero 在**页面最顶上**,它一出现下面<b>整页</b>都会被顶下去 ——
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
        /* 换了一批数据必须<b>复位下标</b>。
           不复位的话 <see cref="Start"/> 里那句 <c>if (_idx &lt; 0)</c> 不成立,
           它就<b>不会去画第一张</b> —— 而 <c>_items</c> 已经换成新的了。
           表现:屏幕上还是上一批里的那张图,圆点却按新的一批画。
           2026-09-03 加「缓存先画一批、真数据回来再画一批」之后当场会踩到。 */
        _idx = -1;

        /* 几张图<b>一起预取</b>。翻页时才去拉的话,每翻一张都要等一次网络 ——
           交叉淡入淡到一半发现下一张还没到,就成了「淡出到一片空白再淡回来」。
           Images 那层解好的位图是留着的,所以第二轮翻回来是零成本。 */
        _bg = _items.Select(it => Images.LoadAsync(_core,
            Images.EmbyImageUrl(_server, Id(it), "Backdrop"), 720)).ToArray();
        // 氛围底只要 64px 高:它会被拉大九倍当糊底用,拉大图纯属白解码
        _wash = _items.Select(it => Images.LoadAsync(_core,
            Images.EmbyImageUrl(_server, Id(it), "Backdrop"), 64)).ToArray();
        /* 艺术字(Logo)。<b>Item 上没有 has_logo 这个字段</b>,取不到只能靠拉 ——
           但 2026-09-06 起 <c>emby.listRandom</c> 已经在核心层只挑有艺术字的条目了
           (RandomPicks 过取再筛),所以这里回落成文字标题应当是极少数
           (取图本身失败,或者那台库一张 Logo 都没刮)。回落链一个字没改。 */
        _logo = _items.Select(it => Images.LoadAsync(_core,
            Images.EmbyImageUrl(_server, Id(it), "Logo"), 184)).ToArray();

        BuildDots();
        _prev.IsVisible = _next.IsVisible = _items.Count > 1;
        if (_alive) Start();
    }

    private void Start()
    {
        if (_idx < 0) _ = Go(0);
        // 只跑一路循环。Attached 会在「详情页返回首页」时再发一次,
        // 不守这一下就会每回来一次多一条,翻页速度成倍加快。
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
    /// <para><b>没有定时器</b> —— 计时的就是小圆点里那条进度动画本身。
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
            /* <b>图没到就不翻</b>(用户 2026-09-02:「切换之后没有显示还要等一会」)。
               预取是在 Show() 里一起发的,但慢链路上第二张可能还在路上 ——
               照翻的话交叉淡入淡到一半发现没东西可淡,那一下就是「切过去了但是空的」。
               封顶 5 秒:一直等下去等于轮播被一张取不到的图卡死。 */
            if (_pinned) { await Task.Delay(500); continue; }
            var nxt = (_idx + 1) % _items.Count;
            await Ready(nxt);
            Jump(nxt);
        }
    }

    /// <summary>等第 <paramref name="i"/> 张的位图到位,最多等 5 秒。</summary>
    private async Task Ready(int i)
    {
        if (i < 0 || i >= _bg.Length || _bg[i].IsCompleted) return;
        await Task.WhenAny(_bg[i], Task.Delay(5000));
    }

    /// <summary>
    /// 停留一轮:小圆点里那条进度条走满 <see cref="Dwell"/>。返回 true = 正常走完。
    ///
    /// <para>计时用 <c>Task.Delay</c>、画面用过渡,两者<b>同一句话里起步、同一个时长</b>。
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
    /// <para>复位必须瞬时:带着 7 秒过渡去「归零」的话,进度条会用 7 秒慢慢退回去,
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
    /// <para>这个方法全程是 <c>_ = Go(...)</c> 发出去的,<b>里面抛的异常没人接</b> ——
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
        var toA = ReferenceEquals(back, _layerA);
        var sharp = toA ? _sharpA : _sharpB;
        var wash = toA ? _washA : _washB;

        var bmp = await _bg[i];
        // 翻得比图快:等这张图的时候用户已经翻走了,别把它硬塞上去
        if (_idx != i) return;
        if (bmp is null)
        {
            Console.WriteLine($"[Hero] 第 {i + 1} 张没有剧照,回退海报");
            /* listRandom 只挑有剧照的条目(ImageTypes=Backdrop),但取图仍然可能失败。
               退回海报 —— 现在是 Uniform 不裁,2:3 的海报只会窄一点,不会被裁烂。 */
            bmp = await Images.LoadAsync(_core, Images.EmbyImageUrl(_server, Id(_items[i]), "Primary"), 720);
            if (bmp is null) Console.WriteLine($"[Hero] 第 {i + 1} 张连海报也取不到(server={_server})");
            if (_idx != i || bmp is null) return;
        }
        // 氛围底取不到就拿大图顶上(它只是被拉糊当底色,清晰与否看不出来)
        var washBmp = i < _wash.Length ? await _wash[i] : null;
        if (_idx != i) return;
        wash.Source = washBmp ?? bmp;
        // 羽化条要拿同一张糊图去画。少了这一句羽化层是空的 ——
        // 不报错,只是那条缝又回来了。
        if (toA) _washBmpA = washBmp ?? bmp; else _washBmpB = washBmp ?? bmp;

        sharp.Source = bmp;
        /* 记下这一张的宽高比,遮罩要按它对齐。
            **不能假定 16:9**:取不到剧照时会回落海报(2:3),
            按 16:9 算出来的左沿在海报上差着几百像素,那道缝会更明显。 */
        var ar = bmp.PixelSize.Height > 0 ? (double)bmp.PixelSize.Width / bmp.PixelSize.Height : 16.0 / 9;
        if (toA) _arA = ar; else _arB = ar;
        SyncFeather();
        _skel.IsVisible = false;
        back.Opacity = 1;
        _front.Opacity = 0;
        _front = back;

        /* 慢推。 <b>两层各自来回推,不复位</b> —— 这一层这次 1.00→1.07,
           下次轮到它就 1.07→1.00。每次都归零的话要先关掉过渡、设值、再打开,
           而关掉过渡的那一瞬间交叉淡入也在同一个 Transitions 里,会一起被掐掉。
           来回推还更好看:连着两张不会都往同一个方向涨。 */
        var kb = toA ? _washBoxA : _washBoxB;
        if (toA) _zoomA = !_zoomA; else _zoomB = !_zoomB;
        if (kb is not null) kb.RenderTransform = Zoom((toA ? _zoomA : _zoomB) ? 1.10 : 1.0);
    }

    /// <summary>
    /// 文字列:艺术字(或标题)+ 标签行。
    ///
    /// <para>入场是<b>上浮 + 淡入</b>,而且艺术字和标签行<b>错开 90ms</b>。
    /// 同时出现的话两行读起来是「一块贴图」;错开之后眼睛会先落在片名再落到标签,
    /// 这就是版式的阅读顺序。90ms 是能感觉到先后、又不显得拖沓的下限。</para>
    /// </summary>
    private void RenderBody(JsonElement it, Task<Bitmap?> logo)
    {
        _body.Children.Clear();

        /* 艺术字这一格<b>高度是钉死的</b>,内容底对齐。
           不钉的表现就是用户说的那句「艺术字和标签之间会有间隔,有些有有些没有」——
           这一格的内容有三种高度:一行标题 42、两行标题 84、艺术字按原比例 40~88,
           而 StackPanel 的 Spacing 是**加在内容下沿之后**的。内容一高一矮,
           标签行的落点就跟着上下跳,看起来就成了「间隔时有时无」。
           钉死之后标签行永远在同一条线上,而多出来的空白全在**上方**(看不见)。 */
        var title = new ContentControl
        {
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
        };
        var titleSlot = new Border
        {
            Height = TitleSlot, HorizontalAlignment = HorizontalAlignment.Left, Child = title,
        };
        // 先摆文字标题;艺术字取到了再换上去(取不到就一直是文字,不留空)
        title.Content = TitleText(ItemName(it));
        _ = SwapLogo(title, logo, Id(it));

        var tags = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        var year = (int)Num(it, "year");
        if (year > 0) tags.Children.Add(Pill(year.ToString(), false));
        var rating = Num(it, "rating");
        if (rating > 0) tags.Children.Add(Pill($"★ {rating:0.0}", true));
        /* <b>不显示「电影 / 剧集」</b>(用户 2026-09-02 点名)。
           它对每一条都成立、而且看海报就知道 —— 一个恒真的标签占的是
           一个真标签的位置。腾出来的位置给类型标签(多显示一个)。 */
        foreach (var g in Genres(it).Take(4)) tags.Children.Add(Pill(g, false));

        _body.Children.Add(titleSlot);
        if (tags.Children.Count > 0) _body.Children.Add(tags);

        Enter(titleSlot, 0);
        if (tags.Children.Count > 0) Enter(tags, 90);
    }

    /// <summary>
    /// 入场:上浮 + 淡入。
    /// <para><see cref="Animation"/> 没有 delay 这个属性,错开是靠<b>前一段保持不动的关键帧</b>
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
        /* 目标值要<b>下一轮才设</b>。过渡是靠「属性变了」触发的 ——
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
        // 翻页比取图快时,别把上一张的艺术字贴到这一张上
        if (_idx < 0 || _idx >= _items.Count || Id(_items[_idx]) != id) return;
        Dispatcher.UIThread.Post(() => host.Content = new Image
        {
            Source = bmp,
            Stretch = Stretch.Uniform,
            MaxHeight = TitleSlot - 4, MaxWidth = 460,
            HorizontalAlignment = HorizontalAlignment.Left,
            Effect = Shadow(),
        });
    }

    /// <summary>
    /// 回落的文字标题。
    /// <para>字号字重要压得住一张照片,而且照样得配投影:36px Bold 落在剧照的高光上
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
    /// <para>压在照片上的胶囊要自带半透明底 + 一圈浅描边 —— 光靠文字颜色的话,
    /// 底下是亮画面时整行就没了。评分单独用暖色:它是这一行里唯一「有高低」的值。</para>
    /// </summary>
    private static Control Pill(string text, bool warm) => new Border
    {
        Padding = new Thickness(10, 6),
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
    /// <para>它同时说了两件事:现在是第几张、<b>还有多久翻页</b>。
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
                Background = Tok.Of("Accent"),
                CornerRadius = new CornerRadius(999),
                HorizontalAlignment = HorizontalAlignment.Stretch,
                // 进度用 RenderTransform 缩放,不动 Width —— 动 Width 是每帧一次布局
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
            // 非当前那几颗要把进度**清零**:不清的话翻回来时是满的,一眼就穿帮
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
    /// 自检。<paramref name="n"/> &gt; 0 = 翻到第 n 张并采样动效曲线;
    /// n = 0 = 什么都不碰,隔 8 秒看它自己有没有翻过去。
    ///
    /// <para>轮播「在不在动」靠截图判不出来:静止的大图和停住的轮播长得一模一样,
    /// 而停住恰恰是最容易发生的失败。这一版做的过程里三次都是这个症状,
    /// 三次的截图都「看着挺正常」。所以把数采出来 —— 数在动 = 动效在跑。</para>
    /// </summary>
    internal void SelfCheckJump(int n)
    {
        if (n <= 0) { _ = Watch(); return; }
        /* 采样式自检要<b>把轮播停住</b>。
           不停的话诊断打在第 3.5 秒、截图拍在第 10 秒,中间它已经自己翻过一页 ——
           于是「日志说的是第 1 张、截图上是第 2 张」,两边对不上账,
           而这种对不上会让人把好的当成坏的查半天(2026-09-02 真栽了一轮)。 */
        _pinned = true;
        Dispatcher.UIThread.Post(async () =>
        {
            Jump(n - 1);
            await Task.Delay(900);
            string Brush(object? src) => src is Bitmap bm
                ? $"{bm.PixelSize.Width}x{bm.PixelSize.Height}" : "(空)";
            // 羽化条报「几条在画 / 带宽多少」——空的话那条缝还在,而截图上很难一眼看出
            static string Feather(Panel p)
            {
                var on = p.Children.Count(c => c.IsVisible && c.Opacity > 0.01);
                if (on == 0) return "(无)";
                var xs = p.Children.Where(c => c.IsVisible).Select(c => c.Margin.Left).ToList();
                return $"{on}条 {xs.Min():0}~{xs.Max():0}px";
            }
            Console.WriteLine($"[Hero 诊断] 块 {Bounds.Width:0}x{Height:0}  " +
                              $"A层 透明度{_layerA.Opacity:0.00} 清晰图{Brush(_sharpA.Source)}@{_sharpA.Bounds.Width:0}x{_sharpA.Bounds.Height:0} 底图{Brush(_washA.Source)} " +
                              $"比例{_arA:0.00} 羽化{Feather(_featherA)} | " +
                              $"B层 透明度{_layerB.Opacity:0.00} 清晰图{Brush(_sharpB.Source)}@{_sharpB.Bounds.Width:0}x{_sharpB.Bounds.Height:0} 底图{Brush(_washB.Source)} " +
                              $"比例{_arB:0.00} 羽化{Feather(_featherB)}");
            /* 「整张剧照一个像素都没裁」的判据:
               清晰图那一层<b>不许带缩放</b>,而且它的高度必须正好等于块高
               (Uniform 之后按高度 fit,矮一点就是没铺满、被裁过或者比例算错了)。
               这一条是被真事逼出来的:慢推挂在整层上时,1.07 倍把图的右边顶出去 14px ——
               而截图上**完全看不出来**,渐变图少一条边和不少长得一模一样。 */
            // RenderTransform 为 null = 压根没有变换 = 1 倍,不是 0 倍。
            // 写成 Scale()==1 的话这条断言永远报「被裁了」——那是**假红**,和假绿一样坏。
            static bool NoZoom(Visual? v) =>
                v?.RenderTransform is null || Math.Abs(v.RenderTransform.Value.M11 - 1) < 0.001;
            var kept = NoZoom(_boxA) && NoZoom(_boxB) && Math.Abs(_sharpA.Bounds.Height - Height) < 2;
            Console.WriteLine(kept
                ? $"[Hero 完整度] ✓ 清晰图没有缩放,高 {_sharpA.Bounds.Height:0} ≈ 块高 {Height:0} —— 一个像素都没裁"
                : $"[Hero 完整度] ✗ 被裁了:A无缩放={NoZoom(_boxA)} B无缩放={NoZoom(_boxB)} " +
                  $"图高{_sharpA.Bounds.Height:0} 块高{Height:0}");
            /* 羽化到底有没有画出来,<b>截图上极难判</b> ——
               没有羽化时是一条竖直的清晰/模糊分界,而在一张渐变测试图上
               那条线本来就不显眼。所以这里量三件事:
               条数、透明度是不是从 ~1 单调走到 ~0、以及它们盖住的那一段
               是不是正好落在清晰图的两条边上。 */
            var fa = _featherA.Children.Where(c => c.IsVisible).ToList();
            if (fa.Count == 0)
            {
                Console.WriteLine("[Hero 羽化] ✗ 一条羽化都没画 —— 清晰图和糊底之间是一条硬边");
            }
            else
            {
                var ops = fa.Take(Strips).Select(c => Math.Round(c.Opacity, 2)).ToList();
                var mono = ops.Zip(ops.Skip(1), (x, y) => x > y).All(x => x);
                var imgW = Math.Min(Height * _arA, Bounds.Width);
                var expectLeft = (Bounds.Width - imgW) / 2;
                var gotLeft = fa.Take(Strips).Min(c => c.Margin.Left);
                Console.WriteLine($"[Hero 羽化] 左侧 {ops.Count} 条 透明度 {string.Join(" ", ops)};" +
                                  $" 起点 {gotLeft:0} 应在 {expectLeft:0}");
                Console.WriteLine(mono && Math.Abs(gotLeft - expectLeft) < 2
                    ? "[Hero 羽化] ✓ 由外到内单调化开,而且正压在清晰图的左沿上"
                    : $"[Hero 羽化] ✗ 单调={mono} 起点偏了 {Math.Abs(gotLeft - expectLeft):0.0}px");
            }
            Console.WriteLine($"[Hero 自检] 共 {_items.Count} 张,现在第 {_idx + 1} 张:{Cur()};" +
                              $"高 {Height:0}px,圆点 {_dots.Children.Count} 颗,骨架可见={_skel.IsVisible}");
            foreach (var at in new[] { 0, 220, 500, 1000, 2000 })
            {
                if (at > 0) await Task.Delay(at - Prev(at));
                Console.WriteLine($"[Hero 动效] +{at,4}ms  A 透明度 {_layerA.Opacity:0.00} 慢推 {Scale(_washBoxA):0.000}" +
                                  $" | B 透明度 {_layerB.Opacity:0.00} 慢推 {Scale(_washBoxB):0.000}" +
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
    private static double Scale(Visual? v) => v?.RenderTransform?.Value.M11 ?? 0;

    /// <summary>读出当前那颗圆点的进度(0~1)。</summary>
    private double Fill() =>
        _idx >= 0 && _idx < _dots.Children.Count && _dots.Children[_idx] is Border { Child: Border f }
            ? Scale(f) : -1;
}
