using System;
using System.Collections.Generic;
using System.Globalization;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Immutable;

namespace LinPlayer.Desktop.Views;

/// <summary>一条排好版的弹幕。字段名照 <c>player.danmakuLayout</c> 的单字母键。</summary>
public sealed class DmItem
{
    public double T;
    public int Mode;
    public int Lane;
    /// <summary>核心层估的文本宽,单位是 1920×1080 画布的像素。</summary>
    public double W;
    public uint Color;
    public string Text = "";

    /// <summary>排好版的字形(正文 + 描边垫底)。**跨帧复用**,见 DanmakuLayer.Render。</summary>
    internal FormattedText? Fg, Sh;
    /// <summary>缓存是按哪一档字号排的。字号变了(换窗口大小 / 改设置)就得重排。</summary>
    internal int Gen = -1;
}

/// <summary>一整份排版结果 + 已经把缩放和速度折算进去的几何量。</summary>
public sealed class DmLayout
{
    public double ResX = 1920, ResY = 1080;
    public double LaneHeight = 54, RollSeconds = 8, FixSeconds = 5, FontSize = 40;
    public double Opacity = 1;
    public bool Bold;
    /// <summary>按时刻升序 —— 每帧靠二分找起点,不遍历全表。</summary>
    public List<DmItem> Items = [];

    public static DmLayout? Parse(JsonElement r)
    {
        if (r.ValueKind != JsonValueKind.Object) return null;
        double N(string k, double def) =>
            r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : def;
        var l = new DmLayout
        {
            ResX = N("res_x", 1920), ResY = N("res_y", 1080),
            LaneHeight = N("lane_height", 54), RollSeconds = N("roll_seconds", 8),
            FixSeconds = N("fix_seconds", 5), FontSize = N("font_size", 40),
            Opacity = N("opacity", 1),
            Bold = r.TryGetProperty("bold", out var b) && b.ValueKind == JsonValueKind.True,
        };
        if (!r.TryGetProperty("items", out var arr) || arr.ValueKind != JsonValueKind.Array) return l;
        foreach (var e in arr.EnumerateArray())
        {
            double G(string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
                ? v.GetDouble() : 0;
            var text = e.TryGetProperty("u", out var u) ? u.GetString() ?? "" : "";
            if (text.Length == 0) continue;
            l.Items.Add(new DmItem
            {
                T = G("t"), Mode = (int)G("m"), Lane = (int)G("l"), W = G("w"),
                Color = (uint)G("c"), Text = text,
            });
        }
        return l;
    }
}

/// <summary>
/// 弹幕绘制层。排版在核心层(<c>core/player/danmakustyle.go</c>),
/// 这里只按帧把 x 插出来、把字画上去。
///
/// <para>☠ 以前是交给 mpv 的 <c>osd-overlay</c> 画的。位置得从 <c>time-pos</c> 插,
/// 而它只在<b>视频帧边界</b>更新 —— 24fps 片源上弹幕跟着 24Hz 一顿一顿;
/// 每秒 120 条 overlay 命令还全压在 mpv 的核心线程上,而那条线程同时在解图形字幕。</para>
/// </summary>
public sealed class DanmakuLayer : Control
{
    private static readonly Typeface Face = new(FontFamily.Default);
    private static readonly Typeface FaceBold =
        new(FontFamily.Default, FontStyle.Normal, FontWeight.Bold);

    private DmLayout? _layout;
    private double _clock;
    private bool _paused;
    private double _speed = 1;
    private DateTime _synced = DateTime.UtcNow;
    /// <summary>正在逐帧重绘。只在有弹幕可画时才转 —— 一直转着的话没弹幕的片子也在烧 CPU。</summary>
    private bool _running;

    public DanmakuLayer()
    {
        IsHitTestVisible = false;
    }

    public DmLayout? Layout
    {
        get => _layout;
        set { _layout = value; _liveFrom = 0; Pace(); InvalidateVisual(); }
    }

    /// <summary>
    /// 对表。轮询每 250ms 来一拍,两拍之间自己按帧往前推 ——
    /// 直接拿轮询值画的表现是弹幕每秒只动 4 下,一格一格地跳。
    /// </summary>
    public void Sync(double position, bool paused, double speed)
    {
        _clock = position;
        _paused = paused;
        _speed = speed <= 0 ? 1 : speed;
        _synced = DateTime.UtcNow;
        Pace();
    }

    /// <summary>
    /// 该不该逐帧重绘。
    ///
    /// <para>这里原来是一个 <c>DispatcherTimer(16ms)</c> —— 那是**自己定的闹钟**,
    /// 和显示器刷新率对不齐,于是周期性地一帧画两次、一帧不画。帧率数字是满的,
    /// 眼睛看到的却是弹幕在抽帧(用户 2026-09-12:「弹幕滚动看起来还是抽帧一样」)。
    /// <see cref="TopLevel.RequestAnimationFrame"/> 挂在渲染循环上,天然对齐 ——
    /// 同一个坑滚动那边(<c>Smooth</c>)早就填了,这一层漏了。</para>
    /// </summary>
    private void Pace()
    {
        var want = IsVisible && _layout is { Items.Count: > 0 } && !_paused;
        if (!want || _running) return;
        if (TopLevel.GetTopLevel(this) is not { } top) return;
        _running = true;
        void Frame(TimeSpan _)
        {
            // 条件掉了就停下来,下一次 Pace() 再起。这一句就是原来的 _timer.Stop()
            if (!IsVisible || _layout is not { Items.Count: > 0 } || _paused) { _running = false; return; }
            InvalidateVisual();
            // 每帧都要重新取 TopLevel:页面被顶掉之后往一个卸载了的窗口排帧是条不会停的循环
            if (TopLevel.GetTopLevel(this) is { } t) t.RequestAnimationFrame(Frame);
            else _running = false;
        }
        top.RequestAnimationFrame(Frame);
    }

    /// <summary>
    /// 一条滚动弹幕在 <paramref name="age"/> 秒时的左边缘。
    ///
    /// <para>走的距离是 <c>width + w</c> 不是 <c>width</c> —— 少算这一截的表现是
    /// 长弹幕还没走完就在左边被瞬间抹掉。</para>
    /// </summary>
    public static double RollX(double width, double w, double age, double roll) =>
        width - age / roll * (width + w);

    /// <summary>二分找第一条 <c>T &gt;= from</c> 的下标。列表按 T 升序。</summary>
    public static int FirstAtOrAfter(List<DmItem> items, double from)
    {
        int lo = 0, hi = items.Count;
        while (lo < hi)
        {
            var mid = (lo + hi) / 2;
            if (items[mid].T < from) lo = mid + 1; else hi = mid;
        }
        return lo;
    }

    /// <summary>
    /// 字号 / 粗细 / 透明度这一档的编号。变一次就 +1,缓存里对不上号的字形全部重排。
    /// </summary>
    private int _gen;
    private double _genFont = -1;
    private bool _genBold;
    private byte _genAlpha;
    /// <summary>上一帧的起点。这一帧起点往前挪过的那一段,缓存就地丢掉。</summary>
    private int _liveFrom;
    /// <summary>颜色 → 画刷。弹幕里不重复的颜色通常不超过十几种。</summary>
    private readonly Dictionary<uint, IBrush> _brushes = [];
    private IBrush _shadow = Brushes.Black;

    /// <summary>
    /// 按帧画。
    ///
    /// <para>☠☠ <b>一帧里不许重新排版。</b> 上一版每条弹幕每帧都 <c>new FormattedText</c>
    /// 两次(正文 + 描边)—— 那是一次完整的文本整形,不是画一下。屏幕上 40 条
    /// × 2 × 60Hz = 每秒 4800 次整形,外加同样多的 <c>SolidColorBrush</c> 进 GC。
    /// 用户报的「弹幕移动起来很掉帧」就是这个。现在字形按「字号档」缓存在
    /// <see cref="DmItem"/> 上,每帧只是把同一组字形挪个位置。</para>
    /// </summary>
    public override void Render(DrawingContext ctx)
    {
        var l = _layout;
        if (l is null || l.Items.Count == 0) return;
        var w = Bounds.Width;
        var h = Bounds.Height;
        if (w <= 0 || h <= 0) return;

        var now = _clock;
        if (!_paused) now += (DateTime.UtcNow - _synced).TotalSeconds * _speed;

        // 按高度换算比例:行数和字号是相对画面高度定的,宽高各自缩会把字压扁
        var sy = h / l.ResY;
        var font = l.FontSize * sy;
        var laneH = l.LaneHeight * sy;
        var a = (byte)Math.Clamp(l.Opacity * 255, 0, 255);
        var face = l.Bold ? FaceBold : Face;
        if (Math.Abs(font - _genFont) > 0.5 || _genBold != l.Bold || _genAlpha != a)
        {
            _genFont = font; _genBold = l.Bold; _genAlpha = a; _gen++;
            _brushes.Clear();
            // 描边靠一层黑影垫底。四向描边要多画四遍,而弹幕本来就是薄薄一层
            _shadow = new ImmutableSolidColorBrush(Color.FromArgb((byte)(a * 3 / 4), 0, 0, 0));
        }
        var off = Math.Max(1.0, font * 0.05);

        var life = Math.Max(l.RollSeconds, l.FixSeconds);
        var from = FirstAtOrAfter(l.Items, now - life);
        // 已经滚出去的那些把字形丢掉 —— 不丢的话一部番看完攒着上万份排版结果
        for (var i = _liveFrom; i < from && i < l.Items.Count; i++)
        {
            l.Items[i].Fg = l.Items[i].Sh = null;
            l.Items[i].Gen = -1;
        }
        _liveFrom = from;

        for (var i = from; i < l.Items.Count; i++)
        {
            var d = l.Items[i];
            if (d.T > now) break;
            var age = now - d.T;
            var span = d.Mode == 1 ? l.RollSeconds : l.FixSeconds;
            if (age > span) continue;
            var wPx = d.W * sy;
            double x, top;
            if (d.Mode == 1)
            {
                // 按实际像素插:横向铺满整块画面,不经过 1920 画布那一道
                x = RollX(w, wPx, age, l.RollSeconds);
                top = 4 * sy + d.Lane * laneH;
            }
            else
            {
                x = (w - wPx) / 2;
                top = d.Mode == 5
                    ? 4 * sy + d.Lane * laneH
                    : h - 4 * sy - (d.Lane + 1) * laneH;
            }
            if (x > w || x + wPx < 0) continue;
            if (d.Gen != _gen || d.Fg is null || d.Sh is null)
            {
                if (!_brushes.TryGetValue(d.Color, out var brush))
                    _brushes[d.Color] = brush = new ImmutableSolidColorBrush(Color.FromArgb(
                        a, (byte)(d.Color >> 16), (byte)(d.Color >> 8), (byte)d.Color));
                d.Sh = new FormattedText(d.Text, CultureInfo.CurrentCulture,
                    FlowDirection.LeftToRight, face, font, _shadow);
                d.Fg = new FormattedText(d.Text, CultureInfo.CurrentCulture,
                    FlowDirection.LeftToRight, face, font, brush);
                d.Gen = _gen;
            }
            ctx.DrawText(d.Sh, new Point(x + off, top + off));
            ctx.DrawText(d.Fg, new Point(x, top));
        }
    }
}
