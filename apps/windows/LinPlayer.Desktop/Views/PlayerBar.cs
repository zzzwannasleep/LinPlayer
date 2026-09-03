using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 播放页的进度条。
///
/// <para>★★ <b>没用 <see cref="Slider"/></b>。用户 2026-09-03:「播放页的 UI
/// 不是现代的播放器的 UI,没有现代播放器的那种交互」。而 Slider 缺的恰恰是
/// 现代播放器进度条的全部特征,而且这些**都不是能靠改样式补上的**:</para>
/// <list type="bullet">
/// <item>静止时是一条 <b>4px 的细线</b>,悬停才涨到 7px 并冒出圆头 —— Slider 的
/// Thumb 是常驻的,而常驻的圆点会一直在画面上戳着</item>
/// <item><b>已缓冲</b>那一段(浅色)—— Slider 只有「已播 / 未播」两段</item>
/// <item><b>章节分段</b> —— 在章节起点处切一道 2px 的缺口</item>
/// <item>悬停时在指针上方浮一个<b>时间气泡</b> —— 现代播放器全都有,
/// 它回答的是「我松手会跳到哪儿」,而这正是拖进度条时唯一想知道的事</item>
/// </list>
///
/// <para>★★ <b>热区 24px,视觉 4px</b>。这两个数是分开的 ——
/// 用户说的「一点都不好点击」就是把它们绑在一起的结果:
/// 想好点就得画粗,画粗就压画面。分开之后,细线上下各 10px 的透明区照样接得住鼠标。</para>
///
/// <para>★ <b>松手才 seek</b>,拖动过程只动画面上的位置和气泡。
/// 拖一次实时 seek 几十下,在网络流上是几十次 HTTP Range 重连;
/// 而且本仓栽过「seek 闩拿粘性值和目标比,一比就相等当场自解除」那一条
/// (见 pc-shortcuts-and-mpvconf),这条路上多一个并发源就多一次那种 bug 的机会。</para>
/// </summary>
public sealed class PlayerBar : Control
{
    /// <summary>整条的高度 = 热区。视觉只有中间那几像素。</summary>
    public const double HitHeight = 24;

    private const double TrackIdle = 4;
    private const double TrackHover = 7;
    private const double ThumbR = 7;

    private static readonly IBrush TrackBrush = new SolidColorBrush(Color.Parse("#4dffffff"));
    private static readonly IBrush BufferBrush = new SolidColorBrush(Color.Parse("#80ffffff"));
    private static readonly IBrush PlayedBrush = new SolidColorBrush(Color.Parse("#5b8def"));
    private static readonly IBrush ThumbBrush = Brushes.White;
    /// <summary>章节缺口的颜色 = 画面本身(黑),所以看着像被切了一刀。</summary>
    private static readonly IBrush NotchBrush = new SolidColorBrush(Color.Parse("#cc000000"));

    private double _duration;
    private double _position;
    private double _buffered;
    private bool _hover;
    private bool _dragging;
    private double _hoverX = -1;

    /// <summary>章节起点(秒)。空 = 不画缺口。</summary>
    public IReadOnlyList<double> Chapters { get; set; } = [];

    /// <summary>松手时触发,参数是目标秒数。</summary>
    public Action<double>? Seek;

    /// <summary>拖动/悬停时的预览位置(秒)。null = 没在预览。播放页拿它更新时间读数。</summary>
    public Action<double?>? Preview;

    public PlayerBar()
    {
        Height = HitHeight;
        HorizontalAlignment = HorizontalAlignment.Stretch;
        Cursor = new Cursor(StandardCursorType.Hand);
    }

    protected override void OnPointerEntered(PointerEventArgs e)
    {
        _hover = true;
        InvalidateVisual();
    }

    protected override void OnPointerExited(PointerEventArgs e)
    {
        _hover = false;
        _hoverX = -1;
        if (!_dragging) Preview?.Invoke(null);
        InvalidateVisual();
    }

    protected override void OnPointerMoved(PointerEventArgs e)
    {
        _hoverX = e.GetPosition(this).X;
        if (_dragging)
        {
            _position = At(_hoverX);
            Preview?.Invoke(_position);
        }
        else if (_hover) Preview?.Invoke(At(_hoverX));
        InvalidateVisual();
    }

    protected override void OnPointerPressed(PointerPressedEventArgs e)
    {
        if (!e.GetCurrentPoint(this).Properties.IsLeftButtonPressed) return;
        _dragging = true;
        e.Pointer.Capture(this);
        _hoverX = e.GetPosition(this).X;
        _position = At(_hoverX);
        Preview?.Invoke(_position);
        InvalidateVisual();
        e.Handled = true;
    }

    /// <summary>
    /// 松手 = 提交。
    /// <para>★★ 指针被 <see cref="IPointer.Capture"/> 抓住了,所以<b>拖出控件再松手</b>
    /// 照样收得到这个事件。挂在别处(或者不抓指针)的话,拖出边界松手
    /// 就永远收不到抬手 —— 进度条会被永久钉住,而这个 bug 本仓栽过一次。</para>
    /// </summary>
    protected override void OnPointerReleased(PointerReleasedEventArgs e)
    {
        if (!_dragging) return;
        _dragging = false;
        e.Pointer.Capture(null);
        var to = At(e.GetPosition(this).X);
        Preview?.Invoke(null);
        Seek?.Invoke(to);
        InvalidateVisual();
        e.Handled = true;
    }

    /// <summary>轮询喂进来的真实状态。★ 拖动中<b>不接受</b> —— 否则手指还在拖,
    /// 条自己跳回旧位置(轮询里的位置还是 seek 之前的)。</summary>
    public void Sync(double position, double duration, double buffered)
    {
        _duration = duration;
        _buffered = buffered;
        if (!_dragging) _position = position;
        InvalidateVisual();
    }

    /// <summary>x 坐标 → 秒。</summary>
    private double At(double x) =>
        _duration <= 0 ? 0 : Math.Clamp(x / Math.Max(1, Bounds.Width), 0, 1) * _duration;

    /// <summary>预览气泡该画在哪个 x(播放页要拿它定位)。-1 = 不画。</summary>
    public double HoverX => _hover || _dragging ? _hoverX : -1;

    /// <summary>
    /// 第 i 格有没有缩略图。null = 这一场不采帧(缩略图功能不可用),那就整条带子都不画。
    /// <para>★ 传的是<b>函数</b>不是一份快照:帧是边播边采的,快照发过来就已经旧了。</para>
    /// </summary>
    public Func<int, bool>? HasThumb;

    /// <summary>和 <see cref="Thumbs.Slots"/> 同一个数。分两处写的下场是带子和实际有图的位置错开。</summary>
    private const int ThumbSlots = Thumbs.Slots;

    private static readonly IBrush ThumbBandBrush = new SolidColorBrush(Color.Parse("#7a5b8def"));

    public override void Render(DrawingContext ctx)
    {
        var w = Bounds.Width;
        if (w <= 1) return;
        /* ★★ 先铺一层<b>透明</b>矩形。
           命中测试看的是**画出来的东西**,不是 Bounds —— 什么都不画的 Control
           鼠标穿过去当它不存在,那 24px 的热区就等于没有,
           又回到「只有中间 4px 那条线能点」,也就是用户说的「一点都不好点击」。
           Panel.Background="Transparent" 是同一个把戏,只是那条路上 Render 被 sealed 了。 */
        ctx.FillRectangle(Brushes.Transparent, new Rect(0, 0, w, HitHeight));
        var big = _hover || _dragging;
        var th = big ? TrackHover : TrackIdle;
        var y = (HitHeight - th) / 2;
        var r = th / 2;

        void Bar(double from, double to, IBrush b)
        {
            if (to <= from) return;
            ctx.DrawRectangle(b, null,
                new RoundedRect(new Rect(from, y, to - from, th), r));
        }

        Bar(0, w, TrackBrush);
        if (_duration > 0)
        {
            // 已缓冲。★ 画在「已播」下面 —— 缓冲前沿总是在播放头右边,
            //   顺序反了的话已播那段会被浅色盖掉。
            Bar(0, w * Math.Clamp(_buffered / _duration, 0, 1), BufferBrush);
            var px = w * Math.Clamp(_position / _duration, 0, 1);
            Bar(0, px, PlayedBrush);

            /* 章节缺口。★ 用「画一小段底色」而不是「画一条线」——
               线要选颜色,而进度条左右两半颜色不同(已播是蓝、未播是灰),
               一条固定颜色的线在其中一半上必然看不见。 */
            foreach (var c in Chapters)
            {
                if (c <= 0 || c >= _duration) continue;
                var cx = w * (c / _duration);
                ctx.DrawRectangle(NotchBrush, null, new Rect(cx - 1, y, 2, th));
            }

            /* ★★ <b>哪一段能看缩略图</b>,画一条细带说清楚。
               用户 2026-09-03 定的规则是「缓存了的能用,没缓存的不能用」——
               既然是规则,就不能让用户靠试:划过去没图的时候,他分不清是
               「这儿没有」还是「这功能坏了」。一条 2px 的带子就说明白了。
               ★ 只在悬停时画:平时它是噪音,而平时也没人要用缩略图。 */
            if (big && HasThumb is not null)
            {
                var band = new Rect(0, y + th + 3, 0, 2);
                for (var i = 0; i < ThumbSlots; i++)
                {
                    if (!HasThumb(i)) continue;
                    var x0 = w * i / ThumbSlots;
                    ctx.FillRectangle(ThumbBandBrush,
                        band.WithX(x0).WithWidth(Math.Max(1, w / ThumbSlots)));
                }
            }

            // 圆头只在悬停/拖动时出现。★ 常驻的话它会一直在画面上戳着,
            //   而进度条 95% 的时间只需要「看一眼到哪儿了」。
            if (big)
                ctx.DrawEllipse(ThumbBrush, null,
                    new Point(px, HitHeight / 2), ThumbR, ThumbR);
        }
    }
}
