using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.LogicalTree;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.OpenGL;
using Avalonia.OpenGL.Controls;
using Avalonia.Threading;
using Avalonia.VisualTree;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 视频画面(SPEC §7.2 通道 B):<b>UI 持有 GL 上下文,核心层往 UI 的 FBO 里渲染</b>。
///
/// <para>起播必须排在 <c>lp_gl_init</c> <b>之后</b>。反过来 vo=libmpv 会以
/// 「No render context set.」致命失败,而且**不重试** —— 表现是全程黑屏、
/// wants_redraw 恒 0,没有任何回调会告诉你出了事(S1.2 §5.2 实测)。</para>
/// </summary>
internal sealed class MpvGlView : OpenGlControlBase
{
    private delegate IntPtr GetProcAddressFn(IntPtr ctx, IntPtr name);

    // 委托要自己拿住:GC 掉之后 mpv 回调进来就是野指针(崩在 mpv 线程里,栈毫无线索)
    private GetProcAddressFn? _gpaKeepAlive;
    private bool _ready;

    /// <summary>宿主这边数到的合成帧数。核心层的 render 次数必须和它相等 ——
    /// 差多少,就是有多少个合成帧把黑的推上了屏。见 SelfCheckStutter 的断言。</summary>
    internal static long GlFrames;

    /// <summary>A/B 用:回到「没有新帧就不画」的旧行为。见 OnOpenGlRender。</summary>
    private static readonly bool SkipRedraw =
        Environment.GetEnvironmentVariable("LP_SKIP_REDRAW") == "1";

    /// <summary>GL 就绪后调一次。起播动作放这里,顺序才是对的。</summary>
    public Action? OnReady;

    public string? InitError { get; private set; }

    protected override void OnOpenGlInit(GlInterface gl)
    {
        _gpaKeepAlive = (_, name) =>
        {
            var n = Marshal.PtrToStringAnsi(name);
            return n == null ? IntPtr.Zero : gl.GetProcAddress(n);
        };
        var r = Native.lp_gl_init(Marshal.GetFunctionPointerForDelegate(_gpaKeepAlive), IntPtr.Zero);
        if (r != 0) { InitError = $"lp_gl_init 返回 {r}"; return; }
        _ready = true;
        OnReady?.Invoke();
    }

    protected override void OnOpenGlRender(GlInterface gl, int fb)
    {
        if (_ready)
        {
            var scale = (VisualRoot as TopLevel)?.RenderScaling ?? 1.0;
            var w = Math.Max(1, (int)Math.Round(Bounds.Width * scale));
            var h = Math.Max(1, (int)Math.Round(Bounds.Height * scale));

            /* <b>每一个合成帧都渲</b>,不按「有没有新帧」跳过。

               跳过的前提是「不画的话 FBO 里还是上一帧」—— 这个前提<b>从来没验证过</b>,
               而 2026-09-05 量出来的相关性说它是错的:抽搐的严重程度和**跳过的比例**
               完全同步(正常播放跳 0% = 不抽;慢放跳 90% = 用户报慢放闪烁;
               改成自己排程之后正常播放跳 70% = 用户报正常播放也抽了)。

               mpv 的 render.h 明确支持这么调:没有新帧时它重画当前那一帧。
               代价是 GPU 多画几遍(85Hz 的合成对 24fps 的片子 ≈ 3.5 倍),
               而这正是任何一个 vo 本来就在做的事。
               LP_SKIP_REDRAW=1 回到旧的跳过行为,用来 A/B。 */
            GlFrames++;
            if (!SkipRedraw || Native.lp_gl_wants_redraw() != 0)
            {
                Native.lp_gl_render((uint)fb, w, h, 1);
                // 漏了 swapped 帧率控制就是瞎的(核心层不知道这一帧已经出去了)
                Native.lp_gl_swapped();
            }
        }
        RequestNextFrameRendering();
    }

    protected override void OnOpenGlDeinit(GlInterface gl)
    {
        _ready = false;
        Native.lp_gl_uninit();
    }
}

/// <summary>播放页。画面铺满,控制条压在底部,三秒不动自己收起来。</summary>
public sealed class PlayerPage : UserControl
{
    private readonly CoreClient _core;
    /// <summary>要播的版本(MediaSource id)。空 = 核心层按正则挑。</summary>
    private readonly string _mediaSourceId = "";
    private readonly MpvGlView _view = new();
    /// <summary>进度条。 自绘,不是 Slider —— 理由见 <see cref="PlayerBar"/> 的注释。</summary>
    private readonly PlayerBar _bar = new();
    /// <summary>悬停/拖动时浮在进度条上方的时间气泡。</summary>
    private readonly Border _bubble;
    private readonly TextBlock _bubbleText = new()
    {
        Foreground = Brushes.White, FontSize = 12.5,
        HorizontalAlignment = HorizontalAlignment.Center,
        Margin = new Thickness(6, 0, 6, 2),
    };
    /// <summary>气泡里那张缩略图。</summary>
    private readonly Image _thumb = new() { Stretch = Stretch.UniformToFill };
    /// <summary>缩略图框的尺寸。 和 <see cref="Thumbs"/> 存的 160×90 同比。</summary>
    private const double ThumbW = 160, ThumbH = 90;

    /// <summary>
    /// 底部控制条占掉的高度。浮在画面上的东西(设置抽屉、跳过片头)都从它往上让。
    ///
    /// <para>写死 116 / 132 两个数的时候,改了控制条的内边距就得同时想起来改这两处 ——
    /// 而想不起来的表现是面板压在进度条上,或者中间空一条。</para>
    /// </summary>
    private const double OsdClearance = 116;
    /// <summary>这一场播放采到的帧。换片要 Reset。</summary>
    private readonly Thumbs _frames;
    /// <summary>页面顶层容器。气泡要按进度条的真实坐标挂在它上面。</summary>
    private Panel? _root;
    private readonly Slider _vol;
    /// <summary>音量滑块的外壳。 悬停才展开 —— 常驻的话它白占一条控制栏。</summary>
    private readonly Border _volBox;
    /// <summary>当前播放位置(秒)。原来是从 <c>_bar.Value</c> 读的,自绘之后要自己记。</summary>
    private double _position;
    private readonly TextBlock _time = new() { Foreground = Brushes.White, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center };
    /// <summary>总时长,画在进度条右端。 和已播时间**分列进度条两侧** ——
    /// 挤在一起写成 <c>12:30 / 1:45:00</c> 时,眼睛得先找到那个斜杠才知道读到哪儿了。</summary>
    private readonly TextBlock _total = new() { Foreground = Brushes.White, FontSize = 12.5, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center };
    /// <summary>音轨 / 字幕 / 画质那一盘。 平铺在控制条上的话底下一整行都是下拉框,
    /// 那是设置面板不是 OSD;而且它们**看片时基本不动**,不该长期占着画面。</summary>
    private readonly Border _settings;
    /// <summary>静音按钮。图标跟着 <c>_muted</c> 走,见 <see cref="SyncMute"/>。</summary>
    private readonly Button _mute;
    private readonly TextBlock _msg = new() { Foreground = Brushes.White, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _pause;
    private readonly Border _top, _bottom;
    /* 三个下拉**同宽**。抽屉里竖排三行,宽度不一样右边缘就是锯齿状 ——
       这种参差在一块半透明面板上特别扎眼,而它只是三个数没对齐。 */
    private readonly ComboBox _audio = new() { Width = 210, MinHeight = 32 };
    private readonly ComboBox _subs = new() { Width = 210, MinHeight = 32 };
    private readonly ComboBox _quality = new() { Width = 210, MinHeight = 32 };
    /// <summary>画面比例。核心层 <c>player.setAspectRatio</c> 早就在,UI 一直没接。</summary>
    private readonly ComboBox _aspect = new() { Width = 210, MinHeight = 32 };
    /// <summary>章节。选一个就跳过去。 没有章节的片子整行不画,不摆一个空下拉。</summary>
    /// <summary>章节。 给占位文字 —— 没选中时空白一片会被当成「没加载出来」。</summary>
    private readonly ComboBox _chapters = new()
    {
        Width = 210, MinHeight = 32, PlaceholderText = "跳到章节…",
    };
    /// <summary>
    /// 字幕 / 音频延迟(秒)。2026-09-04 从 Slider 换成步进器
    /// (用户:「太像网页播放器,样式很丑」)。
    ///
    /// <para>滑块在这件事上本来就是错的控件:±10 秒摊在 150px 上 = 一像素 133 毫秒,
    /// 而对轴要的是 0.1 秒;它也没有「回到 0」这个最常用的动作。
    /// 值存在这儿而不是控件里 —— 步进器是三个按钮,没有 Value 属性可读。</para>
    /// </summary>
    private double _subDelaySecs, _audDelaySecs;
    private readonly TextBlock _subDelayText = Label("0.0s");
    private readonly TextBlock _audDelayText = Label("0.0s");
    /// <summary>倍速。按钮上直接写当前值 —— 一个图标说不出「现在是几倍速」。</summary>
    private readonly Button _speed;
    private double _speedValue = 1.0;
    /// <summary>片头 / 片尾的跳过条。落在区间里才出现。</summary>
    private readonly Button _skip;
    private (double Start, double End)? _intro, _outro;
    /// <summary>这一次已经跳过的那个区间,别反复弹。</summary>
    private string _skipped = "";
    private readonly string _itemId;
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromMilliseconds(250) };
    /// <summary>下一集。有就画「下一集」键,没有就不画(电影 / 最后一集)。</summary>
    private readonly CardItem? _next;

    /// <summary>详情页选好的音轨 / 字幕(Emby 流下标)。见构造函数的参数注释。</summary>
    private readonly int _wantAudioIndex = -1;
    private readonly int _wantSubIndex = -1;

    private double _duration;
    /// <summary>
    /// 最近一次指针在本页坐标系里的位置。
    ///
    /// <para>替掉了原来由 PointerEntered/Exited 维护的 <c>_osdHover</c> 布尔 ——
    /// 那是个环:<c>ShowOsd(false)</c> 把控制条从指针底下撤走 → Avalonia 发 Exited
    /// → 抹掉悬停标志 → 指针一抖又 <c>ShowOsd(true)</c>(用户 2026-09-04:「鼠标停在
    /// 音量键上会不断闪烁」)。按坐标算和命中测试无关,环就断了。</para>
    /// </summary>
    private Point _ptr = new(-1, -1);
    private bool _full;
    private bool _tracksLoaded;
    private bool _leaving;
    private bool _muted;
    private DateTime _lastMove = DateTime.UtcNow;

    /// <summary>
    /// seek 闩:发出 seek 之后,状态回报还会有一小段时间给旧位置。
    ///
    /// <para>闩必须和**目标**比,不能和「上一次读到的位置」比 ——
    /// 拿粘性值和目标比,一比就相等,闩当场自解除,进度条继续跳回旧位置。
    /// 本地文件永远看不出来(seek 立刻生效),只有真服务器上才现形。</para>
    /// </summary>
    private double _seekTarget = -1;

    /// <summary>这一条是不是文件浏览型源的条目(走 source.play)。</summary>
    private readonly bool _isSource;

    /// <summary>
    /// 播的是<b>已经下载到本地的文件</b>(下载页点进来的),走 <c>player.playLocal</c>。
    ///
    /// <para><c>player.playLocal</c> 核心层早就注册着,<b>全仓零调用</b> ——
    /// 下载完的片子在下载页里点不开,只能自己去文件夹里找。
    /// 这是本仓第八次撞上「后端领先前端」(用户 2026-09-04:
    /// 「下载完了之后不能直接在下载页里面直接点击观看」)。</para>
    /// </summary>
    private readonly bool _isLocal;

    /// <summary>这一场播放<b>没有 Emby 会话</b>(源播放 / 本地文件)。
    /// 章节、进度上报、停播上报这些要 server/token 的事全靠它挡。</summary>
    private bool NoEmby => _isSource || _isLocal;

    /// <summary>
    /// 源条目的原始数据,原样回传给核心层。
    ///
    /// <para>资源站(影视目录)的**可播地址就藏在 raw 里** —— 不带它的话
    /// 后端只拿到一个 id,解析不出流。表现是「点了集数没反应」。</para>
    /// </summary>
    private readonly object? _sourceRaw;
    private readonly string _title = "";

    /// <summary>
    /// 播放页。
    ///
    /// <para><paramref name="isSource"/> = true 表示这是**文件浏览型源**的条目
    /// (网盘 / 局域网 / 本地),走 <c>source.play</c> 而不是 <c>player.play</c>。</para>
    ///
    /// <para>两条起播路的差别只在这一句上,别的(OSD、快捷键、进度、轨道)全共用 ——
    /// 另开一个「源播放页」等于把这些再实现一遍,还得再维护一遍。</para>
    /// </summary>
    /// <param name="mediaSourceId">
    /// 指定播哪一个版本(MediaSource)。空 = 交给核心层按版本正则挑。
    /// <para>详情页选了版本却不把它送下来的话,界面说在放 4K、实际在放 1080p ——
    /// 而且两边都不报错。这正是本仓「界面在撒谎:当前版本」那条教训的另一半。</para>
    /// </param>
    /// <param name="next">
    /// 下一集。给了就画「下一集」键。
    /// <para>让<b>调用方</b>算下一集,不是播放页自己去拉一遍分集表 ——
    /// 详情页手里本来就有那张表,而且「接着看哪一集」的顺序它已经算过一次了
    /// (<c>NextEpisode</c>)。播放页再算一份迟早和它指到不同的集上。</para>
    /// </param>
    /// <param name="audioIndex">
    /// 详情页选好的音轨,值是 <b>Emby 的流下标</b>(= 容器里的流序号)。-1 = 不指定。
    /// </param>
    /// <param name="subIndex">
    /// 详情页选好的字幕流下标。-1 = 不指定,-2 = 明确不要字幕。
    /// <para>传下标而不是 mpv 的 track id:详情页那会儿 mpv 还没起,
    /// 没有 track-list 可读。对号在 <see cref="ApplyPreferredTracks"/> 里按
    /// <c>ff_index</c> 做 —— mpv 的 id 是按类型各自从 1 重编的,拿它当流序号用
    /// 的表现是「选了第 2 条日语,放出来是英语」,而且两边都不报错。</para>
    /// </param>
    /// <param name="isLocal">
    /// 播已下载到本地的那个文件。<paramref name="itemId"/> 这时候是**下载任务的 id**,
    /// 不是 Emby 的条目 id。
    /// </param>
    public PlayerPage(CoreClient core, string itemId, string title, double resumeSecs,
        bool isSource = false, object? sourceRaw = null, string mediaSourceId = "",
        CardItem? next = null, int audioIndex = -1, int subIndex = -1, bool isLocal = false)
    {
        _isLocal = isLocal;
        _wantAudioIndex = audioIndex;
        _wantSubIndex = subIndex;
        _mediaSourceId = mediaSourceId;
        _core = core;
        _isSource = isSource;
        _sourceRaw = sourceRaw;
        _title = title;
        _itemId = itemId;
        _next = next;
        _frames = new Thumbs(core);
        /* 图是<b>异步</b>回来的:回来那一刻鼠标多半还停在原处,
           得再跑一次预览回调把它摆上去 —— 不然用户看到的是「划过去只有时间,
           动一下才出图」,而那一下动作纯属多余。 */
        _frames.Changed = () => { if (_bar.HoverTime is { } t) _bar.Preview?.Invoke(t); };

        /* 进度条是<b>自绘</b>的(<see cref="PlayerBar"/>),不是 Slider。
           上一版把 Slider 的 MinHeight 拉到 28 来解决「不好点击」——
           那只是把**同一个控件**加高,画出来的仍然是一条粗线加一个常驻圆点。
           现代播放器是「静止 4px 细线 / 悬停 7px + 圆头 / 底下 24px 透明热区」,
           外加已缓冲段、章节缺口、时间气泡 —— 这些 Slider 一个都给不了。 */
        _bar.Seek = to => _ = SeekTo(to);
        _bar.Preview = at =>
        {
            _bubble.IsVisible = at is not null && _duration > 0;
            if (at is null) return;
            _bubbleText.Text = Clock(at.Value);

            /* 有图就把缩略图摆上去,没有就只留时间那一行。
               这一条<b>不是降级</b>,是用户点名的规则:
               「缓存了的进度条能用,没缓存的不能用这个缩略图功能」。
               At() <b>不阻塞</b> —— 手上没有的话它去要,回来再叫我们重画一次。 */
            var pic = _frames.At(at.Value);
            _thumb.Source = pic;
            if (_bubble.Child is Panel bs && bs.Children.Count > 0)
                bs.Children[0].IsVisible = pic is not null;
            if (pic is null) NoteThumbUnavailable();

            /* 气泡跟着指针走,但**不许跑出进度条两端** —— 跑出去会被裁掉一半,
               而片头片尾正是最常拖的两个位置。
                宽高都跟着「这会儿有没有图」走:只有时间的时候气泡窄得多、也矮得多。
                坐标<b>问进度条自己要</b>,不写死 —— 控制条的行高会随按钮尺寸变,
                写死的偏移量今天对、下次调按钮就错,而且错了不报错。 */
            var w = pic is not null ? ThumbW + 2 : 60.0;
            var h = pic is not null ? ThumbH + 2 : 27.0;
            var barAt = _bar.TranslatePoint(default, _root!) ?? default;
            var x = Math.Clamp(_bar.HoverX - w / 2, 0, Math.Max(0, _bar.Bounds.Width - w));
            _bubble.Margin = new Thickness(barAt.X + x, barAt.Y - h - 6, 0, 0);
        };
        /* 悬停气泡 = <b>一整块</b>:缩略图铺满整张卡,时间压在它的下沿。

            用户 2026-09-04:「缩略图下面的时间有时候会变成一个黑色矩形挡住一点点缩略图,
             感觉是因为时间和缩略图不是一块做出来的导致的」—— <b>他说对了,就是这个原因</b>。
             上一版是「图框 3px 间距 一行字」竖着摞在一张黑卡上,于是:
               · 图的四周留一圈 4px 黑边(卡片的 Padding);
               · 图下面再多一条纯黑的字条(时间那一行的背景就是卡片本身)。
             这两块黑连成一片,看着就是一个黑矩形贴在图的下边缘上 ——
             而且只有<b>有图的时候</b>才看得出来(没图时整块本来就是个小黑药丸),
             所以用户说的是「有时候」。

            现在图**铺满卡片**(Padding=0 + ClipToBounds,圆角直接裁在图上),
             时间画在图<b>上面</b>,底下垫一层从透明到黑的渐变。
             这是所有播放器的做法,也是唯一能让「图和时间是一块」的做法 ——
             留白多少、间距几像素都调不好,因为问题不在数值上,在结构上。
            没有缩略图的位置只剩那条渐变条,它自己缩成一个时间小药丸。 */
        var timeStrip = new Border
        {
            VerticalAlignment = VerticalAlignment.Bottom,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Padding = new Thickness(2, 6, 2, 2),
            Background = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
                EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops =
                {
                    new GradientStop(Color.Parse("#00000000"), 0),
                    new GradientStop(Color.Parse("#b3000000"), 0.5),
                    new GradientStop(Color.Parse("#e6000000"), 1),
                },
            },
            Child = _bubbleText,
        };
        _bubble = new Border
        {
            IsVisible = false,
            Background = new SolidColorBrush(Color.Parse("#e6000000")),
            CornerRadius = new CornerRadius(10),
            // Padding 必须是 0 —— 那 4px 就是「黑边」的来源
            Padding = new Thickness(0),
            ClipToBounds = true,
            BorderBrush = new SolidColorBrush(Color.Parse("#33ffffff")),
            BorderThickness = new Thickness(1),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 0),
            IsHitTestVisible = false,
            // Panel 不是 StackPanel:时间要**叠在**图上,不是排在图下面
            Child = new Panel
            {
                Children =
                {
                    // 缩略图框。 尺寸钉死 —— 有图没图气泡的宽度都一样,
                    // 否则鼠标横着划过去的时候气泡会一格一格地胖瘦变化。
                    new Border
                    {
                        Name = "thumbBox", Width = ThumbW, Height = ThumbH,
                        IsVisible = false,
                        Background = Tok.Of("PanelAlt"),
                        Child = _thumb,
                    },
                    timeStrip,
                },
            },
        };
        _vol = new Slider { Minimum = 0, Maximum = 100, Value = 100, Width = 0, Opacity = 0 };
        /* 音量条<b>悬停才展开</b>(现代播放器的通行做法)。
           常驻 110px 的话它在控制栏左半边一直占着位置,而音量是个一次调好、
           之后几乎不动的东西。展开靠 Width + Opacity 两条过渡一起走 ——
           只动 Width 的话它会「从一条竖线长出来」,像被压扁了。 */
        foreach (var pr in new[] { Slider.WidthProperty, Slider.OpacityProperty })
            (_vol.Transitions ??= []).Add(new Avalonia.Animation.DoubleTransition
            {
                Property = pr, Duration = TimeSpan.FromMilliseconds(160),
                Easing = new Avalonia.Animation.Easings.CubicEaseOut(),
            });

        /* OSD 的图标全部换成 <b>Segoe MDL2 Assets</b>(样式 Button.osd 里设的字体)。
           原来混着用 Unicode 杂符号(⏸ ⟲ ⟳ 🕪 ⚙ ⛶):
             · 🕪 在 Windows 上走 Segoe UI Emoji,渲染成**彩色**图标,和旁边一排线条符号
               完全不是一套东西;
             · ⟲ / ⟳ 这些数学箭头字重比周围细一大截,看着像掉了一档。
           MDL2 是系统自带的图标字体,一整排同源同粗细。
            字形存不存在有自检兜着(LP_SELFCHECK_GLYPH),不然缺字形是一个个豆腐块,
             而它编译绿、运行也不报错。 */
        _pause = new Button { Classes = { "osd", "main" }, Content = Ico.Pause };
        ToolTip.SetTip(_pause, "播放 / 暂停(空格)");

        // 返回是**唯一**带字的按钮:它离开这一页,和旁边那排「就地调整」不是一类动作。
        var back = new Button
        {
            Classes = { "ghost" }, Content = "← 返回", Foreground = Brushes.White,
        };
        back.Click += (_, _) => Leave();

        var full = Glyph(Ico.Full, "全屏(F)");
        full.Click += (_, _) => ToggleFullscreen();
        _fullBtn = full;

        _pause.Click += (_, _) => _ = TogglePause();
        _vol.PropertyChanged += (_, e) =>
        {
            if (e.Property == Slider.ValueProperty) _ = Send("player.setVolume", new { volume = _vol.Value });
        };

        _audio.SelectionChanged += (_, _) => _ = PickTrack("audio", _audio);
        _subs.SelectionChanged += (_, _) => _ = PickTrack("sub", _subs);
        _quality.SelectionChanged += (_, _) => _ = PickQuality();
        _ = LoadQualityLevels();

        var back10 = Glyph(Ico.Back, "后退 10 秒(←)");
        back10.Click += (_, _) => _ = SeekBy(-10);
        var fwd10 = Glyph(Ico.Fwd, "前进 10 秒(→)");
        fwd10.Click += (_, _) => _ = SeekBy(10);

        /* 静音图标得**跟着状态变** —— 图标不变的话按下去除了没声音之外
           没有任何反馈,用户会以为按钮坏了。 */
        _mute = Glyph(Ico.Volume, "静音(M)");
        _mute.Click += (_, _) =>
        {
            _muted = !_muted;
            SyncMute();
            _ = Send("player.setMute", new { mute = _muted });
        };

        /* 倍速。 按钮上**直接写数字**,不放一个图标:
           「现在是几倍速」是个有具体值的状态,图标表达不了它,
           而 1.5 倍速忘了调回来是很常见的事(声音听着不对但说不出哪里不对)。
           点一下轮转一档,右键回 1.0 —— 常用动作一次点击,不必开抽屉。 */
        _speed = new Button
        {
            Classes = { "osd" }, Content = "1×", FontFamily = FontFamily.Default, FontSize = 13,
            Width = 48,
        };
        ToolTip.SetTip(_speed, "倍速(点一下换一档,右键回 1×)");
        _speed.Click += (_, _) => _ = CycleSpeed(+1);
        _speed.AddHandler(PointerReleasedEvent, (_, e) =>
        {
            if (e.InitialPressMouseButton == MouseButton.Right) _ = SetSpeed(1.0);
        }, RoutingStrategies.Tunnel);

        // 截图。 核心层 player.screenshot 一直在,UI 从来没接 —— 又一条零调用命令。
        var shot = Glyph(Ico.Camera, "截图(S)");
        shot.Click += (_, _) => _ = Screenshot();

        // 下一集。 没有下一集就**整个不画**,不摆一个灰着的按钮
        var nextBtn = Glyph(Ico.Next, "下一集(N)");
        nextBtn.Click += (_, _) => GoNext();

        /* 音轨 / 字幕 / 画质 / 延迟 / 比例 / 章节 收进一个抽屉。
            它们平铺在控制条上时,底下一整行都是下拉框和标签 —— 那是**设置面板**,
            不是 OSD。看片时这几样基本不动,不该长期压着画面。
            抽屉贴右下角弹,不是居中弹窗:它是就地调整,不是一次决策,
            居中弹窗会把整块画面遮掉。 */
        var subDelayRow = Stepper(_subDelayText,
            d => SetDelay(ref _subDelaySecs, d, _subDelayText, "player.setSubDelay"));
        var audDelayRow = Stepper(_audDelayText,
            d => SetDelay(ref _audDelaySecs, d, _audDelayText, "player.setAudioDelay"));
        _aspect.ItemsSource = Aspects.Select(a => a.Label).ToList();
        _aspect.SelectedIndex = 0;
        _aspect.SelectionChanged += (_, _) =>
            _ = Send("player.setAspectRatio", new { ratio = Aspects[Math.Max(0, _aspect.SelectedIndex)].Value });
        _chapters.SelectionChanged += (_, _) =>
        {
            if (_chapters.SelectedItem is ChapterOption c) _ = SeekTo(c.At);
        };

        var chapterRow = Row("章节", _chapters);
        chapterRow.IsVisible = false;   // 有章节才画,见 LoadChapters
        _chapterRow = chapterRow;

        _settings = new Border
        {
            Background = new SolidColorBrush(Color.Parse("#f0161b24")),
            BorderBrush = Tok.Of("LineStrong"),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(10),
            Padding = new Thickness(18),
            Margin = new Thickness(0, 0, 18, OsdClearance),
            IsVisible = false,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    // 「画质」改叫「超分」(用户 2026-09-04 点名)—— 这一格里全是
                    // Anime4K 超分档位,叫「画质」会让人以为它管的是码率 / 清晰度档
                    Row("音轨", _audio), Row("字幕", _subs), Row("超分", _quality),
                    Row("比例", _aspect), chapterRow,
                    Row("字幕延迟", subDelayRow),
                    Row("音频延迟", audDelayRow),
                },
            },
        };
        var gear = Glyph(Ico.Setting, "音轨 / 字幕 / 超分 / 延迟(U)");
        gear.Click += (_, _) => ShowSettings(!_settings.IsVisible);
        _gear = gear;

        /* 跳过片头 / 片尾。
            这是<b>核心层早就算好、UI 从来没用过</b>的东西:player.chapterInfo
            一次请求同时给章节表和 intro/outro 区间,而且开关关着时它自己返回 null ——
            调用方不必再判一次开关。
            按钮浮在右下角、只在区间里出现:常驻的话它在全片 95% 的时间里都是错的。 */
        _skip = new Button
        {
            Classes = { "primary" }, Content = "跳过片头", IsVisible = false,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 26, OsdClearance + 14),
        };
        _skip.Click += (_, _) =>
        {
            if (_skipTo > 0) _ = SeekTo(_skipTo);
            _skip.IsVisible = false;
        };

        /* 版式换成<b>「整条进度条独占一行 + 底下一排按钮」</b>。
           原来是「已播时间 | 进度条 | 总时长」挤在一行里 ——
           那让进度条两端各缩进 60 多像素,而<b>片头和片尾恰好在那两端</b>,
           想拖到最开头就得先瞄准那个缩进后的起点。
           现代播放器(YouTube / Netflix / Bilibili / Plex)一律是整宽独占一行,
           时间读数挪到按钮那一排的左边。 */
        // 帧库交给 GL 视图 —— 采帧只能在 GL 线程上、渲染之后做

        /* 气泡<b>不能挂在这一格里</b>。这一格高 50,而带缩略图的气泡要 117 ——
           实测它被箍成了 50(`气泡 171x50`),于是缩略图溢出去、时间那一行掉到按钮下面。
           所以气泡挂到**页面顶层**,位置按进度条的真实屏幕坐标算(见 Preview)。
           别改成「把这一格加高 120」:那 120px 是从画面上切走的,而气泡一秒钟都不出现的时候
             它也一直占着。 */
        var barRow = new Panel
        {
            Height = PlayerBar.HitHeight + 26,
            Children = { _bar },
        };
        _bar.VerticalAlignment = VerticalAlignment.Bottom;
        _bubble.HorizontalAlignment = HorizontalAlignment.Left;
        _bubble.VerticalAlignment = VerticalAlignment.Top;

        _time.Margin = new Thickness(6, 0, 0, 0);
        _total.Margin = new Thickness(0, 0, 0, 0);
        var clock = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
            Children =
            {
                _time,
                new TextBlock
                {
                    Text = "/", Foreground = Brushes.White, Opacity = 0.45, FontSize = 12.5,
                    VerticalAlignment = VerticalAlignment.Center,
                },
                _total,
            },
        };

        // 音量:图标 + 悬停才展开的滑块。整组一起接悬停,不然从图标滑到滑块的路上它会收回去。
        _volBox = new Border
        {
            Background = Brushes.Transparent,
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 6,
                VerticalAlignment = VerticalAlignment.Center,
                Children = { _mute, _vol },
            },
        };
        _volBox.PointerEntered += (_, _) => { _vol.Width = 92; _vol.Opacity = 1; };
        _volBox.PointerExited += (_, _) => { _vol.Width = 0; _vol.Opacity = 0; };

        var left = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { _pause, back10, fwd10 },
        };
        if (_next is not null) left.Children.Add(nextBtn);
        left.Children.Add(_volBox);
        left.Children.Add(clock);
        var right = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { _speed, shot, gear, full },
        };
        var controls = new Grid { ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto") };
        Grid.SetColumn(left, 0);
        Grid.SetColumn(right, 2);
        controls.Children.Add(left);
        controls.Children.Add(right);
        var progress = barRow;

        /* 上下两条都用**渐变蒙版**,不是一块实心黑条。
           实心条是一条硬边压在画面上,边缘那一行像素会突兀地断掉;
           渐变从画面里长出来,而字仍然压得住 —— 这是所有播放器都这么做的原因。 */
        _bottom = new Border
        {
            Background = Scrim(false),
            // 左右 16:整条进度条要贴得住两端,内缩太多的话片头片尾又不好瞄了
            Padding = new Thickness(18, 42, 18, 10),
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = new StackPanel { Spacing = 0, Children = { progress, controls } },
        };

        _top = new Border
        {
            Background = Scrim(true),
            Padding = new Thickness(18, 14, 18, 34),
            VerticalAlignment = VerticalAlignment.Top,
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 10,
                Children =
                {
                    back,
                    new TextBlock
                    {
                        Text = title, Foreground = Brushes.White, FontSize = 16,
                        FontWeight = FontWeight.SemiBold,
                        TextTrimming = TextTrimming.CharacterEllipsis, MaxWidth = 900,
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                    _msg,
                },
            },
        };

        /* 上下两条的淡入淡出。用户 2026-09-03 提过一次,2026-09-04 又说
           「上下栏**还是**不会渐显渐隐」—— 所以上一版做得不够。
            上一版只有一条 200ms 的 Opacity 过渡,出场退场同一个数。
             200ms 的纯淡出在一块本来就半透明的渐变蒙版上几乎读不出来,
             看着仍然像「啪一下没了」。而且那段注释自己写着「出场 160 / 退场 260」,
             代码里却是同一个 200 —— <b>注释在撒谎</b>。
            这一版两件事一起做:①出场 170 / 退场 420(退场慢一倍多才读得出「让开」);
             ②各自**滑出画面**(上栏往上 14px、下栏往下 14px)。
             位移是「离开」最直白的语言,而且它<b>不依赖蒙版的透明度</b> ——
             纯 Opacity 在亮场景里本来就难看出来。
            出场/退场两套时长靠**换 Transitions 对象**实现:Avalonia 的过渡是
             一条属性一套参数,同一个 Transitions 没法两个方向不同。见 ShowOsd。
            过渡挂在控件上而不是样式表里:这两条是这一页独有的,
             进样式表就得起个类名,而那个类名只会有一个使用者。 */
        _top.RenderTransformOrigin = RelativePoint.Center;
        _bottom.RenderTransformOrigin = RelativePoint.Center;
        _top.Transitions = Fade(OsdInMs);
        _bottom.Transitions = Fade(OsdInMs);

        var root = new Panel
        {
            Background = Brushes.Black,
            // 气泡排在 _bottom <b>之后</b> —— 它要画在控制条上面,而不是被压在下面
            Children = { _view, _top, _bottom, _skip, _settings, _bubble },
        };
        _root = root;
        Content = root;

        /* <b>点面板以外的任何地方 = 关掉这块面板</b>(用户 2026-09-04:
           「播放页的选项不能点击屏幕任意位置就退出」)。
           上一版关掉它只有两条路:再点一次齿轮,或者三秒不动等 OSD 整个收走。
           而这块面板是压在画面上的一大块,用户的第一反应就是「点旁边关掉」——
           所有弹出层都是这么用的。点了没反应(反而把片子暂停了)只会让人以为卡住。

           挂在**隧道**阶段:冒泡阶段先到的是画面那层的
             PointerPressed(它会 TogglePause)。要的是「这一下只关面板」,
             所以在它之前把事件吃掉。
           齿轮自己要排除掉:不排的话这一下先关面板、齿轮的 Click 再开一次,
             面板永远关不掉,而且看不出为什么。
           面板<b>里面</b>点当然不关 —— 那是在用它。

           ☠ 「里面」必须按<b>逻辑树</b>判,不能按可视树。下拉框展开之后,选项住在
             另一棵可视树里(Popup 自己的根),往上走一步就到头了,走不回 _settings ——
             于是「点选项」被判成「点面板以外」,这一下把面板关掉并且 Handled=true,
             ComboBox 根本收不到。用户看到的就是:点开字幕,点一个,面板没了,什么也没变。
             <b>「字幕 / 超分 / 比例 全都不生效」是这一行,不是那三条命令。</b>
             逻辑树上选项仍然是 ComboBox 的子节点,不管它被画到哪儿。 */
        AddHandler(PointerPressedEvent, (_, e) =>
        {
            if (!_settings.IsVisible) return;
            if (e.Source is StyledElement el &&
                el.GetSelfAndLogicalAncestors().Any(a => ReferenceEquals(a, _settings) ||
                                                         ReferenceEquals(a, _gear))) return;
            _settings.IsVisible = false;
            e.Handled = true;
        }, RoutingStrategies.Tunnel);

        // 键盘要能收到,控件得先能拿焦点 —— 不设 Focusable 按空格毫无反应,
        // 而用户只会觉得「这播放器连暂停都没有」。
        Focusable = true;
        AttachedToVisualTree += (_, _) =>
        {
            Focus();
            /* 用户 2026-09-03:「播放页不应该有侧边栏,还是有了」。
               原来只有按 F 进全屏才收 —— 不全屏看片时左边一直杵着导航栏,
               而那上面每一个入口点下去都会把正在放的片子扔掉。 */
            Nav.Immersive?.Invoke(true);
            // 播放页底下是控制条和进度条,轻提示压在上面既挡进度条又会被人去点
            Toast.AtTop = true;
        };
        // 离场必须放回来。只在 Leave() 里放的话,用 Alt+← / 侧栏返回等别的路
        // 退出播放页时外壳再也不出现 —— 那就是「软件的导航没了」。
        DetachedFromVisualTree += (_, _) =>
        {
            if (_full) { _full = false; Nav.Fullscreen?.Invoke(false); }
            Nav.Immersive?.Invoke(false);
            Toast.AtTop = false;
        };
        /* <b>隧道阶段接键盘,不是冒泡</b>。用户 2026-09-04:
           「为什么我点击空格不是播放/暂停,而是打开设置面板的?」

           根因是**焦点**:用鼠标点过齿轮之后,焦点就落在那个 Button 上,
           而 Avalonia 的 Button 把 Space / Enter 当成「按我」——
           它在冒泡阶段先把这一下吃掉并 Click 一次(=再开一次设置面板),
           挂在页面上的 OnKey 根本轮不到。
           播放器的键盘必须**压过控件的默认键**:看片时空格永远是播放/暂停,
             不管刚才点过哪个按钮。所以走隧道 —— 它比任何子控件都先到。
           另一半在 Glyph():OSD 上那排图标按钮一律 Focusable=false。
             两件都要做:隧道解决「按下去做什么」,不可聚焦解决「焦点框画在哪」——
             一个播放器的按钮上挂着虚线焦点框本身就是错的。 */
        AddHandler(KeyDownEvent, OnKey, RoutingStrategies.Tunnel);
        PointerMoved += (_, e) =>
        {
            _ptr = e.GetPosition(this);
            _lastMove = DateTime.UtcNow;
            ShowOsd(true);
        };

        /* 滚轮调音量 —— 事实标准(YouTube / Bilibili / mpv / VLC 都是)。
            一格 5:一格 1 要滚二十下才从静音到满,一格 10 又太粗。 */
        PointerWheelChanged += (_, e) =>
        {
            SetVolume(_vol.Value + (e.Delta.Y > 0 ? 5 : -5));
            _lastMove = DateTime.UtcNow;
            ShowOsd(true);
            e.Handled = true;
        };
        /* 点画面 = 播放/暂停,双击 = 全屏。也是事实标准。
            挂在 <see cref="MpvGlView"/> 上而不是整页 —— 挂整页的话点控制条上的
            空白处也会暂停,而那儿用户的意图是「什么都不做」。 */
        _view.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(_view).Properties.IsLeftButtonPressed && e.ClickCount == 1)
                _ = TogglePause();
        };
        _view.DoubleTapped += (_, _) => ToggleFullscreen();

        // 起播排在 GL 就绪之后。发出去就行,不等结果 —— 等结果会把渲染线程堵住。
        _view.OnReady = () => Dispatcher.UIThread.Post(() => _ = Start(itemId, resumeSecs));

        _poll.Tick += (_, _) => _ = Poll();
        _poll.Start();
        DetachedFromVisualTree += (_, _) => Stop();

        // 判「非空」而不是 == "1":LP_DRILL=2(拉开抽屉)也得先把 Drill 跑起来,
        // 只认 "1" 的话 =2 那次连 OSD 都不会钉住,截出来是一张干净画面 ——
        // 而它看着**很像**「抽屉没画出来」。这个坑当场踩了一次。
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("LP_SELFCHECK_PLAYER_DRILL")))
            _ = Drill();
        /* 自检台驱动画质档位。选的是**真的下拉项**,走 SelectionChanged 那条真路 ——
           绕开 UI 直接调命令的自检只能证明核心层活着,证明不了这个面板接对了。 */
        var lvl = Environment.GetEnvironmentVariable("LP_SELFCHECK_SHADER");
        if (!string.IsNullOrEmpty(lvl)) _ = SelfCheckPickQuality(lvl);
        SelfCheckOsdFade();
        SelfCheckThumb();
        SelfCheckAvSync();
        SelfCheckStutter();
        SelfCheckPick();
        /* 自检:LP_SELFCHECK_PAUSE=秒 —— 到点就暂停,让外面的连拍落在暂停态上。
           暂停时画面本该一动不动,连拍还在变就是「暂停了还在抽搐」,
           而这是这件事**唯一**能被客观拍下来的形态。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PAUSE") is { Length: > 0 } ps
            && double.TryParse(ps, out var psec))
            _ = Task.Delay(TimeSpan.FromSeconds(psec))
                .ContinueWith(_ => _core.PlayerSetPause(new { paused = true }));
        SelfCheckPanel();
        SelfCheckWatched();
        // 自检:LP_SELFCHECK_PLAYER_DRILL=3 把跳过条钉出来 —— 它平时只在片头那几十秒里出现,
        // 截图永远抓不到,而它是这一版新加的东西里最容易画错位置的一个。
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PLAYER_DRILL") == "3")
            _ = Task.Delay(7000).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
            {
                /* 灌的是**区间**,不是直接把按钮设可见 ——
                   直接设可见的话下一次 Poll 里的 SyncSkip 会因为「不在任何区间里」
                   立刻把它收回去,自检拍到的永远是没有按钮的那一帧。
                   而且灌区间走的是真实那条路(SyncSkip 判定 → 显示 → 点了跳到 End),
                   直接设可见只证明「这个控件存在」。
                   核心层默认**关着**跳过片头(prefs.skip_intro=false,它会回 null),
                     所以真机上这一块要用户开了开关才出现 —— 那是对的,不是 bug。 */
                _intro = (0, 90);
                _lastMove = DateTime.UtcNow.AddYears(1);
                ShowOsd(true);
            }));
    }

    /// <summary>抽屉里「章节」那一行。没有章节的片子整行不画。</summary>
    private readonly Control _chapterRow;

    /// <summary>跳过条按下去要跳到哪儿。</summary>
    private double _skipTo;

    /// <summary>画面比例档位。空串 = 交还给 mpv 自己判(-1)。</summary>
    private static readonly (string Label, string Value)[] Aspects =
    [
        ("自动(跟随源)", "-1"),
        ("16:9", "16:9"),
        ("4:3", "4:3"),
        ("21:9", "2.35"),
        ("拉伸填满", "-2"),
    ];

    /// <summary>倍速档位。 0.5 以下没人用,2 以上听不清 —— 档位少一点选起来才快。</summary>
    private static readonly double[] Speeds = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0];

    private Task CycleSpeed(int step)
    {
        var at = Array.FindIndex(Speeds, x => Math.Abs(x - _speedValue) < 0.01);
        if (at < 0) at = 2;
        return SetSpeed(Speeds[((at + step) % Speeds.Length + Speeds.Length) % Speeds.Length]);
    }

    private async Task SetSpeed(double v)
    {
        _speedValue = v;
        // 1 倍速写成「1×」不是「1.00×」—— 一排数字里多两位小数会显得没对齐
        _speed.Content = Math.Abs(v - 1.0) < 0.01 ? "1×" : $"{v:0.##}×";
        _speed.Classes.Set("on", Math.Abs(v - 1.0) > 0.01);
        await Send("player.setSpeed", new { speed = v });
    }

    /// <summary>
    /// 截图。 <b>不传目录</b> —— 核心层会用设置页里选的那个,传了反而把设置项架空。
    /// </summary>
    private async Task Screenshot()
    {
        try
        {
            var r = await _core.PlayerScreenshot(new { });
            _msg.Text = "截图已存到 " + Str(r, "path");
        }
        catch (Exception e) { _msg.Text = "截图失败:" + LibraryPage.Advice(e); }
    }

    private void GoNext()
    {
        if (_next is null) return;
        Stop();
        _leaving = true;
        // 换成**替换**不是压栈:一路看下去会攒出一栈播放页,
        // 返回键要按十几下才回得到详情页。
        Nav.Replace(new PlayerPage(_core, _next.Id, _next.DisplayTitle, _next.ResumeSecs));
    }

    /// <summary>
    /// 拉章节 + 片头片尾区间。
    ///
    /// <para>一次请求喂两个功能(核心层就是这么设计的)。开关关着时它自己回 null,
    /// <b>调用方不必再判一次开关</b> —— 判两次早晚判岔,那就是「关了还在跳」。</para>
    /// <para>拉不到不报错:没刮章节的库返回空表,两个功能静默不工作,那是正常情况。</para>
    /// </summary>
    private async Task LoadChapters()
    {
        if (NoEmby || _itemId == "") return;
        try
        {
            var s = Nav.Session!;
            var r = await _core.PlayerChapterInfo(new
            {
                s.server, s.token, s.user_id, s.device_id,
                item_id = _itemId, runtime_secs = _duration,
            });
            var list = r.TryGetProperty("chapters", out var cs) && cs.ValueKind == JsonValueKind.Array
                ? cs.EnumerateArray()
                    .Select(c => new ChapterOption(Num(c, "start_secs"),
                        Str(c, "name") is { Length: > 0 } n ? $"{Clock(Num(c, "start_secs"))}  {n}"
                                                           : Clock(Num(c, "start_secs"))))
                    .ToList()
                : [];
            _intro = RangeOf(r, "intro");
            _outro = RangeOf(r, "outro");
            Dispatcher.UIThread.Post(() =>
            {
                if (list.Count == 0) return;
                _chapters.ItemsSource = list;
                _chapterRow.IsVisible = true;
                // 进度条上切缺口。现代播放器都有这一下 ——
                // 它把「这片子有几段」直接画在了用户要拖的那条线上。
                _bar.Chapters = list.Select(c => c.At).ToList();
            });
        }
        catch { /* 没有章节是常态,不是错误 */ }
    }

    private static (double, double)? RangeOf(JsonElement r, string k) =>
        r.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Object
            ? (Num(v, "start"), Num(v, "end")) : null;

    /// <summary>
    /// 位置落进片头 / 片尾区间时把跳过条弹出来。
    ///
    /// <para>同一个区间只弹一次:用户按了「不跳」(等它自己过去)之后又弹回来,
    /// 那就成了骚扰。<c>_skipped</c> 记的就是这个。</para>
    /// </summary>
    private void SyncSkip(double pos)
    {
        (double Start, double End)? hit = null;
        var which = "";
        if (_intro is { } a && pos >= a.Start && pos < a.End) { hit = a; which = "intro"; }
        else if (_outro is { } b && pos >= b.Start && pos < b.End) { hit = b; which = "outro"; }

        if (hit is null || _skipped == which)
        {
            if (_skip.IsVisible && hit is null) _skip.IsVisible = false;
            return;
        }
        _skipTo = hit.Value.End;
        _skip.Content = which == "intro" ? "跳过片头" : "跳过片尾";
        _skip.IsVisible = true;
    }

    /// <summary>
    /// 真机自检:起播 6 秒后跳到第 3 秒,并把 OSD 钉住不收。
    ///
    /// <para>自检片有<b>烧录时间码</b> —— 截图上的时间码就是 seek 到底有没有真的
    /// 落位的判据。看进度条没用:进度条是我们自己画的,它「显示对了」和
    /// 「画面真的跳过去了」是两件事(本仓库栽过)。</para>
    /// </summary>
    private async Task Drill()
    {
        await Task.Delay(6000);
        await SeekTo(3);
        // 钉住 OSD:收起来之后截图看不到控制条,分不清「自动收了」和「压根没画」
        _lastMove = DateTime.UtcNow.AddYears(1);
        ShowOsd(true);
        /* LP_DRILL=2 顺带把音轨/字幕/画质那个抽屉拉开。
           收起来的东西**截图里等于不存在** —— 抽屉里三行控件排没排齐、
           弹出位置有没有盖住控制条,不拉开一次就永远没人看过。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PLAYER_DRILL") == "2")
            Dispatcher.UIThread.Post(() => ShowSettings(true));

        /* LP_DRILL=4:<b>拉开抽屉,然后在画面上真按一下</b>,看它关不关。
            这条是用户 2026-09-04 那句「播放页的选项不能点击屏幕任意位置就退出」的判据。
            截图验不了 —— 截图点不了鼠标,而它坏掉的样子恰恰是「点了没反应」。
            事件要发在 _view 上(画面那一层),走的正是用户点画面那条真路:
            隧道阶段我们先接住关面板,冒泡阶段那个 TogglePause 就不该再跑到。
            顺带验「点面板自己不关」—— 只验前半条的话,一个「按下就无脑关」
            的实现也照样绿,而那种实现下用户根本没法用这块面板。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PLAYER_DRILL") == "4")
        {
            await Dispatcher.UIThread.InvokeAsync(() => ShowSettings(true));
            await Task.Delay(300);
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                Poke(_settings);
                Console.WriteLine(_settings.IsVisible
                    ? "[抽屉] ✓ 点面板自己不关"
                    : "[抽屉] ✗ 点面板自己也关掉了 —— 那就没法用它了");
                Poke(_view);
                Console.WriteLine(!_settings.IsVisible
                    ? "[抽屉] ✓ 点画面(面板以外)关掉了面板"
                    : "[抽屉] ✗ 点画面没关掉面板 —— 用户只能再去找那个齿轮");
            });
        }

        /* <b>点过齿轮之后,空格还得是播放/暂停</b>。
           用户 2026-09-04:「为什么我点击空格不是播放/暂停,而是打开设置面板的?」

            判据必须**先把焦点放到齿轮上**再按空格 —— 这正是坏掉的那个条件。
             不先聚焦的话,坏的实现和好的实现表现一模一样(焦点在页面上,
             OnKey 本来就收得到),于是一条本该红的判据永远绿。
            两件事一起验:①暂停状态真的翻了;②设置面板**没有**被打开。
             只验①的话,一个「既暂停又开面板」的实现也算过。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PLAYER_DRILL") == "5")
        {
            /* 面板要**开着**:里面那个下拉框是我们要聚焦的控件,
               而看不见的控件拿不到焦点(第一版就是关着的,于是 Focus() 静默失败、
               焦点留在页面上 —— 那种情况下坏的实现和好的实现表现一模一样)。 */
            await Dispatcher.UIThread.InvokeAsync(() => ShowSettings(true));
            await Task.Delay(300);
            var was = false;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                /* ①「OSD 按钮不可聚焦」这一半直接问控件。 它同时也解释了为什么
                   下面要拿别的控件去聚焦:齿轮已经拿不到焦点了。 */
                Console.WriteLine(_gear?.Focusable == false
                    ? "[空格] ✓ 齿轮按钮不可聚焦(Focusable=false)—— 空格不会被它当成「按我」"
                    : "[空格] ✗ 齿轮按钮仍然可聚焦 —— 点过它之后空格就归它了");

                /* ②「隧道阶段接键盘」这一半要拿一个**真的会抢空格的控件**来验。
                   抽屉里的下拉框是真输入控件,它必须保持可聚焦 ——
                   所以它正是那个「焦点在别的控件上时,播放器的键还灵不灵」的场子。 */
                _quality.Focus();
                was = (string?)_pause.Content == Ico.Play; // true = 现在是暂停态
                Console.WriteLine($"[空格] 焦点在 {(_quality.IsFocused ? "画质下拉框(可聚焦控件)" : "别处")};" +
                                  $"按之前 暂停={was}");
                /* 事件要发在**有焦点的那个控件**身上,不是页面上。
                   在页面上发的话路由从页面开始 —— 下拉框根本不在路径里,
                   于是页面的冒泡处理器立刻就收到了,**冒泡和隧道表现一模一样**。
                   第一版就是这么写的:反向注入(退回 KeyDown += OnKey)之后照样绿。
                   真键盘是发给焦点控件的,自检也得这么发。
                   同一条坑在 Poke() 上已经踩过一次(RaiseEvent 会改写 Source)。 */
                _quality.RaiseEvent(new KeyEventArgs
                {
                    RoutedEvent = KeyDownEvent, Key = Key.Space, KeyModifiers = KeyModifiers.None,
                });
            });
            await Task.Delay(700); // 等 setPause 往返 + 状态轮询把按钮图标改回来
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                var now = (string?)_pause.Content == Ico.Play;
                Console.WriteLine(now != was
                    ? $"[空格] ✓ 空格切换了播放/暂停(暂停 {was} → {now})"
                    : $"[空格] ✗ 空格没切换播放/暂停(暂停一直是 {was})");
                Console.WriteLine(!_quality.IsDropDownOpen
                    ? "[空格] ✓ 下拉框也没被空格展开 —— 播放器的键压过了控件的默认键"
                    : "[空格] ✗ 空格把下拉框展开了 —— 键盘还挂在冒泡阶段");
            });
        }
    }

    /// <summary>
    /// 自检:在某个控件上真发一次「鼠标左键按下」。走的是真事件路由,不是直接调方法。
    ///
    /// <para>必须在 <b>target 自己</b>身上 RaiseEvent,不能在页面上发、
    /// 靠构造参数里那个 source 指过去 —— Avalonia 会把 <c>Source</c> 换成
    /// <b>实际 RaiseEvent 的那个元素</b>。第一版就是这么写的,于是每一次
    /// 「点」的事件源都是 PlayerPage,自检当场把一个正确的实现判成红的。</para>
    /// </summary>
    /// <summary>
    /// 一次<b>完整的点击</b>:按下 + 松开。
    ///
    /// <para>只发按下测不出下拉框:ComboBox 的选项是**松手**那一下才提交的,
    /// 于是「点了没选中」既可能是这一页的 bug,也可能是自检自己少发了半个事件 ——
    /// 分不清的断言等于没有断言。</para>
    /// </summary>
    private void PokeClick(Control target)
    {
        var at = target.TranslatePoint(new Point(4, 4), this) ?? new Point(4, 4);
        var ptr = new Pointer(0, PointerType.Mouse, true);
        target.RaiseEvent(new PointerPressedEventArgs(
            target, ptr, this, at, 0,
            new PointerPointProperties(RawInputModifiers.LeftMouseButton,
                PointerUpdateKind.LeftButtonPressed), KeyModifiers.None));
        target.RaiseEvent(new PointerReleasedEventArgs(
            target, ptr, this, at, 0,
            new PointerPointProperties(RawInputModifiers.None,
                PointerUpdateKind.LeftButtonReleased), KeyModifiers.None, MouseButton.Left));
    }

    private void Poke(Control target)
    {
        var at = target.TranslatePoint(new Point(4, 4), this) ?? new Point(4, 4);
        target.RaiseEvent(new PointerPressedEventArgs(
            target, new Pointer(0, PointerType.Mouse, true), this, at,
            0, new PointerPointProperties(RawInputModifiers.LeftMouseButton,
                PointerUpdateKind.LeftButtonPressed), KeyModifiers.None));
    }

    private static TextBlock Label(string t) => new()
    {
        Text = t, Foreground = Brushes.White, FontSize = 12,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>
    /// OSD 用到的 MDL2 字形。
    ///
    /// <para>集中一处写,是为了<b>能被自检逐个查一遍</b>(LP_SELFCHECK_GLYPH):
    /// 字体里没有这个码位时 Windows 画的是一个空心方框,而它<b>编译绿、运行也不报错</b> ——
    /// 只有真渲染 + 真看一眼才发现得了。散在各处写就没法查。</para>
    /// </summary>
    internal static class Ico
    {
        public const string Play = "\uE768";
        public const string Pause = "\uE769";
        public const string Back = "\uE72B";       // 后退 10 秒
        public const string Fwd = "\uE72A";        // 前进 10 秒
        public const string Next = "\uE893";       // 下一集
        public const string Volume = "\uE767";
        public const string Mute = "\uE74F";
        public const string Camera = "\uE722";     // 截图
        public const string Setting = "\uE713";
        public const string Full = "\uE740";
        public const string Windowed = "\uE73F";

        /// <summary>自检用:全表。加了新图标要往这里加一行,不然它查不到。</summary>
        public static readonly (string Name, string Glyph)[] All =
        [
            ("播放", Play), ("暂停", Pause), ("后退", Back), ("前进", Fwd), ("下一集", Next),
            ("音量", Volume), ("静音", Mute), ("截图", Camera), ("设置", Setting),
            ("全屏", Full), ("退出全屏", Windowed),
        ];
    }

    /// <summary>静音图标跟状态走。 轮询里也调一次 —— 键盘 M 和按钮是两条路。</summary>
    private void SyncMute()
    {
        _mute.Content = _muted ? Ico.Mute : Ico.Volume;
        _mute.Classes.Set("on", _muted);
    }

    /// <summary>滑块 + 读数。 光有滑块的话用户不知道自己调到了多少。</summary>
    /// <summary>抽屉里的一行:标签 + 控件。标签宽度对齐,三行才排得整齐。</summary>
    private static StackPanel Row(string label, Control input) => new()
    {
        Orientation = Orientation.Horizontal, Spacing = 10,
        Children =
        {
            new TextBlock
            {
                // 64 不是 40:最长的标签是「字幕延迟」四个字,40 只放得下两个 ——
                // 截断之后成了「字幕延」,看着像写错字(实测截图上抓到)
                Text = label, Width = 64, Foreground = Brushes.White, FontSize = 12.5,
                VerticalAlignment = VerticalAlignment.Center,
            },
            input,
        },
    };

    /// <summary>
    /// OSD 上的图标按钮。
    ///
    /// <para>每个都要有 <c>ToolTip</c> 并把快捷键写进去 —— 一排符号按钮
    /// 光看图形猜不出是什么,而快捷键写在别处等于没人知道。</para>
    /// </summary>
    private static Button Glyph(string glyph, string tip)
    {
        var b = new Button
        {
            Classes = { "osd" }, Content = glyph,
            VerticalAlignment = VerticalAlignment.Center,
            // 见构造函数里那段:不可聚焦,空格才不会被它当成「按我」。
            Focusable = false,
        };
        ToolTip.SetTip(b, tip);
        return b;
    }

    /// <summary>
    /// OSD 的渐变蒙版。
    ///
    /// <para>不用实心黑条:实心是一条硬边压在画面上,边缘那一行像素突兀地断掉。
    /// 渐变从画面里长出来,字仍然压得住。</para>
    /// </summary>
    private static IBrush Scrim(bool fromTop) => new LinearGradientBrush
    {
        StartPoint = new RelativePoint(0, fromTop ? 0 : 1, RelativeUnit.Relative),
        EndPoint = new RelativePoint(0, fromTop ? 1 : 0, RelativeUnit.Relative),
        GradientStops =
        {
            new GradientStop(Color.Parse("#d9000000"), 0),
            new GradientStop(Color.Parse("#73000000"), 0.55),
            new GradientStop(Color.Parse("#00000000"), 1),
        },
    };

    private async Task Start(string itemId, double resumeSecs)
    {
        if (_view.InitError is not null) { _msg.Text = _view.InitError; return; }
        try
        {
            if (_isLocal)
            {
                /* 本地文件那条路:核心层自己按下载任务 id 找到落盘路径,
                   还会再 stat 一次确认文件真的在(用户可能手动删了 / 挪走了)。
                   不走代理、不走预取 —— 它已经在本地了。 */
                await _core.CallAsync("player.playLocal",
                    new { id = itemId, resume_secs = resumeSecs });
            }
            else if (_isSource)
            {
                /* 源播放**没有 Emby 会话**:网盘 / 局域网 / 本地源根本没有 server/token。
                   硬塞 Nav.Session 的话,网盘用户那边 Session 是 null,
                   这里会抛在 Task 里 —— 没提示、不崩、就是永远停在黑屏。 */
                await _core.SourcePlay(new
                {
                    entry_id = itemId, entry_name = _title, resume_secs = resumeSecs,
                    raw = _sourceRaw,
                });
            }
            else
            {
                var s = Nav.Session!;
                await _core.PlayerPlay(new
                {
                    s.server, s.token, s.user_id, s.device_id,
                    item_id = itemId, resume_secs = resumeSecs,
                    media_source_id = _mediaSourceId,
                });
            }
        }
        catch (Exception e) { _msg.Text = $"起播失败:{LibraryPage.Advice(e)}"; }
    }

    // ---------------------------------------------------------------- 交互

    private void OnKey(object? sender, KeyEventArgs e)
    {
        _lastMove = DateTime.UtcNow;
        ShowOsd(true);
        switch (e.Key)
        {
            case Key.Space or Key.K: _ = TogglePause(); break;
            case Key.Left: _ = SeekBy(-10); break;
            case Key.Right: _ = SeekBy(10); break;
            // J / L = ±10 秒。 YouTube 起的头,现在是事实标准 ——
            // 手不用离开 J/K/L 三个键就能倒、停、进。
            case Key.J: _ = SeekBy(-10); break;
            case Key.L: _ = SeekBy(10); break;
            // 数字键跳到百分之几。 也是事实标准(0=开头,5=一半)。
            case >= Key.D0 and <= Key.D9 when _duration > 0:
                _ = SeekTo(_duration * (e.Key - Key.D0) / 10.0);
                break;
            case Key.Up: SetVolume(_vol.Value + 5); break;
            case Key.Down: SetVolume(_vol.Value - 5); break;
            case Key.M:
                _muted = !_muted;
                SyncMute();
                _ = Send("player.setMute", new { mute = _muted });
                break;
            // U:开抽屉再展开画质。 抽屉关着时直接展开下拉框,下拉列表会飘在
            // 一块看不见的面板上 —— 得先把面板拿出来。
            case Key.U:
                ShowSettings(true);
                _quality.IsDropDownOpen = !_quality.IsDropDownOpen;
                break;
            // 新加的功能都要有快捷键:OSD 三秒就收,而键盘永远在
            case Key.S: _ = Screenshot(); break;
            case Key.N: GoNext(); break;
            case Key.OemPeriod: _ = CycleSpeed(+1); break;   // > 加速
            case Key.OemComma: _ = CycleSpeed(-1); break;    // < 减速
            case Key.F or Key.Enter: ToggleFullscreen(); break;
            // 全屏时 Esc 只退全屏,不退出播放 —— 看片时误按一下就把片关了很恼人
            case Key.Escape when _full: ToggleFullscreen(); break;
            case Key.Escape: Leave(); break;
            default: return;
        }
        e.Handled = true;
    }

    private async Task TogglePause()
    {
        try { await _core.PlayerSetPause(new { paused = (string?)_pause.Content != Ico.Play }); }
        catch { /* 状态轮询会纠正显示 */ }
    }

    private async Task SeekBy(double delta)
    {
        if (_duration <= 0) return;
        await SeekTo(Math.Clamp(_position + delta, 0, _duration));
    }

    // 只改滑块,命令由 PropertyChanged 统一发 —— 两处各发一次就会打架
    private void SetVolume(double v) => _vol.Value = Math.Clamp(v, 0, 100);

    /// <summary>
    /// 进 / 出全屏。
    ///
    /// <para>「退出全屏后依然是全屏」的根因不在这里翻的布尔,在外壳的
    /// <c>SetFullscreen</c>:它退出时回的是进来之前那个 WindowState,而那多半是
    /// Maximized —— 本窗口无边框,播放页又收了标题栏和侧栏,于是最大化和全屏
    /// 长得一模一样。修在外壳:播放页退全屏一律回 Normal。</para>
    /// </summary>
    private void ToggleFullscreen()
    {
        _full = !_full;
        // 侧栏已经在进页时收掉了(见构造函数),这里只管窗口状态
        Nav.Fullscreen?.Invoke(_full);
        // 图标要跟着换:全屏之后按钮还画着「进入全屏」,用户会以为没生效
        if (_fullBtn is not null)
        {
            _fullBtn.Content = _full ? Ico.Windowed : Ico.Full;
            ToolTip.SetTip(_fullBtn, _full ? "退出全屏(F / Esc)" : "全屏(F)");
        }
        /* 画面区变了 → 能跑的超分档也变了,列表要重拉。
           放大那几族的门槛是「画面区 > 源的 1.2 倍」——窗口下一档都不跑、
           全屏下才跑起来。不重拉的话:全屏之后列表里还是只有锐化去噪那几档,
           而用户全屏正是为了用放大档。
           等一会儿再拉:osd-dimensions 要等窗口真的变完才是新值。 */
        _ = Task.Delay(400).ContinueWith(_ => Dispatcher.UIThread.Post(() => _ = LoadQualityLevels()));
    }

    private Button? _fullBtn;

    private void Leave()
    {
        if (_leaving) return;
        _leaving = true;
        if (_full) ToggleFullscreen();
        Stop();
        Nav.Back();
    }

    /// <summary>
    /// 自检:画面有没有在抽搐。这件事截图一个像素都看不出来 ——
    /// 抽搐是帧和帧之间的关系,而截图只有一帧。
    ///
    /// <para>这一行只出数不下判据 —— avsync 和帧间隔抖动<b>两版判据都被反向注入打掉过</b>
    /// (见 docs/lessons/player-mpv.md)。真正的判据在 <c>[黑帧]</c> 那一条:
    /// 每个合成帧都必须画到,漏一帧就是往屏上推一帧黑。</para>
    /// </summary>
    private void SelfCheckAvSync()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_AVSYNC") != "1") return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(8000); // 起播头几秒本来就在追同步,别拿那一段当数
            double worst = 0, drops = 0;
            var n = 0;
            for (var k = 0; k < 24; k++)
            {
                await Task.Delay(250);
                double v = 0;
                await Dispatcher.UIThread.InvokeAsync(() => { v = _avsync; drops = _drops; });
                if (v <= -1) continue;          // 没数
                worst = Math.Max(worst, Math.Abs(v));
                n++;
            }
            double gap = 0, jit = 0, delayed = 0, vj = 0;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                gap = _gapMs; jit = _jitterMs; delayed = _voDelayed; vj = _vsyncJitter;
            });
            Console.WriteLine($"[出帧节奏] 平均间隔 {gap:0.0}ms(≈{(gap > 0 ? 1000 / gap : 0):0.0} 帧/秒)," +
                              $"抖动 {jit:0.0}ms;音画差最大 {worst * 1000:0.0}ms(采到 {n} 次),丢帧 {drops:0}");
            /* 间隔抖动只作背景数,不当判据 —— 它分不出好坏(见方法上的注释)。
               现在合成心跳(~85Hz)和视频帧率(24)不是整数倍,3 个心跳还是 4 个
               本身就带 ±半个心跳的量化,那部分谁也去不掉。 */
        });
    }

    /// <summary>
    /// 自检:<c>LP_SELFCHECK_PICK=1</c> —— <b>照用户的手顺走一遍</b>:
    /// 点齿轮 → 展开「字幕」下拉 → 在弹出层里点第 2 项。
    ///
    /// <para>存在的理由:原来那条(<c>LP_PANEL</c>)是直接写 <c>SelectedIndex</c> 的,
    /// 它证明的是「命令接对了」,而用户说的「点了不生效」发生在<b>那之前</b> ——
    /// 弹出层是另一棵可视树,点它的那一下会不会被别的处理器吃掉,写 SelectedIndex
    /// 一辈子测不出来。</para>
    /// </summary>
    private void SelfCheckPick()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PICK") != "1") return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(9000);
            /* 齿轮走它自己的 Click(Poke 只发 Pressed,Button 是 Released 才 Click ——
               拿 Poke 去点齿轮测的是自检自己,不是这一页)。 */
            await Dispatcher.UIThread.InvokeAsync(() => ShowSettings(true));
            await Task.Delay(400);
            var openedPanel = false;
            await Dispatcher.UIThread.InvokeAsync(() => openedPanel = _settings.IsVisible);
            Console.WriteLine(openedPanel ? "[点选] ✓ 面板开着" : "[点选] ✗ 面板没开");

            /* 拿「比例」下拉当靶子,不拿「字幕」:比例的 5 个档位是写死在代码里的,
               任何片子都有;字幕轨要看片源,自检用的样片一条都没有,取第 2 项永远是空 ——
               那会测成「功能坏了」,而坏的是夹具。 */
            await Dispatcher.UIThread.InvokeAsync(() => _aspect.IsDropDownOpen = true);
            await Task.Delay(600);
            bool dropOpen = false, panelAlive = false;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                dropOpen = _aspect.IsDropDownOpen; panelAlive = _settings.IsVisible;
            });
            Console.WriteLine(dropOpen ? "[点选] ✓ 下拉展开了" : "[点选] ✗ 下拉没展开");
            Console.WriteLine(panelAlive
                ? "[点选] ✓ 展开下拉之后面板还在"
                : "[点选] ✗ 展开下拉那一下把面板关掉了");

            var before = _aspect.SelectedIndex;
            Control? item = null;
            await Dispatcher.UIThread.InvokeAsync(() => item = _aspect.ContainerFromIndex(1));
            if (item is null) { Console.WriteLine("[点选] ✗ 弹出层里取不到第 2 项"); return; }
            await Dispatcher.UIThread.InvokeAsync(() => PokeClick(item!));
            await Task.Delay(800);
            int after = -1; var alive2 = false;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                after = _aspect.SelectedIndex; alive2 = _settings.IsVisible;
            });
            Console.WriteLine(after == 1
                ? $"[点选] ✓ 点弹出层里的第 2 项选中了它({before} → {after})"
                : $"[点选] ✗ 点了第 2 项没选中(还停在 {after})—— 这就是「点了不生效」");
            Console.WriteLine(alive2 ? "[点选] ✓ 选完面板还在" : "[点选] ✗ 选完面板被关掉了");
            /* 判到**核心层**为止。下拉框自己变了不算数 —— 「界面在撒谎」是本仓
               最贵的那类 bug:控件显示 16:9 而 mpv 根本没收到,长得一模一样。 */
            try
            {
                var st = await _core.PlayerStatus(new { });
                var ar = Num(st, "aspect_override");
                Console.WriteLine(Math.Abs(ar - 16.0 / 9) < 0.001
                    ? $"[点选] ✓ mpv 真收到了 video-aspect-override={ar:0.000000}"
                    : $"[点选] ✗ mpv 那边还是 {ar:0.000000} —— 控件动了命令没到");
            }
            catch (Exception e) { Console.WriteLine($"[点选] ✗ 读不到核心层状态:{e.Message}"); }
        });
    }

    /// <summary>
    /// 自检:<c>LP_SELFCHECK_STUTTER=1</c> —— 量「合成线程被堵多久」。
    ///
    /// <para>2026-09-04 那次动 <c>block_for_target_time</c> 的理由是「合成线程被堵
    /// 83ms」,而那个数从头到尾没量过 —— 拿一个猜测换掉 mpv 的默认值,代价是正常
    /// 播放坏掉。这一条把它变成数:正常速 / 0.25 倍慢放 / 暂停各采一段。</para>
    /// </summary>
    private void SelfCheckStutter()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_STUTTER") != "1") return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(8000);
            await Sample("正常速 1.0×");
            await Dispatcher.UIThread.InvokeAsync(() => _ = SetSpeed(0.25));
            await Sample("慢放 0.25×");
            await Dispatcher.UIThread.InvokeAsync(() => _ = SetSpeed(1.0));
            await _core.PlayerSetPause(new { paused = true });
            await Sample("暂停");
            await _core.PlayerSetPause(new { paused = false });
        });

        // 核心层给的是累计量,这一段的数自己前后各读一次做差
        async Task<(double Sum, double Slow, double Rc, double Wc)> Read()
        {
            double a = 0, b = 0, c = 0, d = 0;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                a = _renderSum; b = _renderSlow; c = _renderCalls; d = _advanceCalls;
            });
            return (a, b, c, d);
        }

        async Task Sample(string what)
        {
            var from = await Read();
            var g0 = MpvGlView.GlFrames;
            var t0 = DateTime.UtcNow;
            await Task.Delay(5000);
            var to = await Read();
            var gl = MpvGlView.GlFrames - g0;
            var secs = (DateTime.UtcNow - t0).TotalSeconds;
            var rc = to.Rc - from.Rc;
            var wc = to.Wc - from.Wc;
            /* ★★ 这一条是这一整轮的核心判据。2026-09-05 实测(LP_FBOTEST=1):
               <b>不画的那一个合成帧,宿主 FBO 里读回来是黑的</b>(涂红 → 隔两帧 → (0,0,0))。
               所以「没有新帧就不渲」这个优化每跳一帧就往屏幕上推一帧黑 ——
               慢放跳 90%、开面板时合成变密,看起来就是画面一直在抽。
               反向注入:LP_SKIP_REDRAW=1 起一次,这条当场红。 */
            /* 阈值 90% 而不是 100%:两个计数器不在同一瞬间读(一个走 Dispatcher 一趟,
               一个是宿主线程的字段),差十来帧是采样错位。真出问题时差的是**数量级** ——
               反向注入实测慢放 10%、暂停 0.4%,离阈值有九倍。 */
            var drew = gl > 0 ? rc / gl : 0;
            Console.WriteLine(drew >= 0.90
                ? $"[黑帧] ✓ {what,-10} 合成 {gl:0} 帧,画到 {drew * 100:0}%"
                : $"[黑帧] ✗ {what,-10} 合成 {gl:0} 帧只画了 {rc:0} 帧({drew * 100:0}%)—— 其余推的是黑的");
            Console.WriteLine($"[卡顿] {what,-12} render 均 {(rc > 0 ? (to.Sum - from.Sum) / rc : 0):0.0}ms;" +
                              $">16ms {to.Slow - from.Slow:0} 次;" +
                              $"合成 {rc / secs:0} fps,其中推进新帧 {wc:0} 次");
        }
    }

    /// <summary>
    /// 自检:看完的片再点播放要从头开始(<c>LP_SELFCHECK_WATCHED=阈值%</c>)。
    ///
    /// <para>夹具:假服务器给 mv-1 的续播位置 1200 秒 / 全长 1800 秒 = 66.7%,
    /// 阈值设 60 于是落在阈值之上。判据是 mpv 真实的播放位置,不是我们传下去的数 ——
    /// 「传了 0 但 mpv 停在 1200」和「传了 1200」在界面上长得一模一样。</para>
    /// </summary>
    private void SelfCheckWatched()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_WATCHED") is not { Length: > 0 } th) return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(9000);
            double pos = 0, dur = 0;
            await Dispatcher.UIThread.InvokeAsync(() => { pos = _position; dur = _duration; });
            if (dur <= 0) { Console.WriteLine("[观看阈值] ⚠ 还没拿到时长,这条不算数"); return; }
            /* 起播之后正片一直在走,所以不能断言「等于 0」。
               给 120 秒的窗口:自检等了 9 秒 + 起播那几秒,离 1200 秒差着一个数量级。 */
            Console.WriteLine(pos < 120
                ? $"[观看阈值] ✓ 阈值 {th}%,续播位置 1200s(66.7%)越线 —— 从 {pos:0.0}s 开始放,没接着片尾"
                : $"[观看阈值] ✗ 停在 {pos:0.0}s / {dur:0.0}s —— 越过阈值了还在续播,下一步就是起播即 EOF");

            /* 阈值的**另一半**:看到这儿就得告诉服务器「已观看」。
               这一半只能在服务器那边验(假 Emby 的请求日志里有没有 PlayedItems),
               所以这里只负责把播放位置推过阈值,然后让退出流程去跑 Stop()。
               不能只验「从头放」那一半:那一半靠的是**读**阈值,
                 这一半靠的是**写**给服务器 —— 两条路完全不同,
                 只验读的话「设了阈值但从来不标已看完」会一路绿。 */
            await SeekTo(dur * 0.97);
            Console.WriteLine($"[观看阈值] 已跳到 {dur * 0.97:0.0}s(97%),退出时该向服务器标「已观看」");
        });
    }

    /// <summary>
    /// 自检:进度条缩略图。要同时钉住两半,少一半都是假绿 —— 放过的位置有图
    /// (否则功能压根没工作),没放过的位置没有图、气泡只剩时间(这才是用户定的
    /// 「缓存了的能用,没缓存的不能用」)。只验第一半的话,一个「随便给张图」的
    /// 实现也照样绿。顺便把气泡钉在屏幕上 —— 收起来的东西在截图里等于不存在。
    /// </summary>
    private void SelfCheckThumb()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_THUMB") != "1") return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(9000); // 等起播 + 核心层把缩略图实例开起来(它自己延迟 4s)
            double dur = 0, inside = -1, outside = -1, cov0 = 0;
            var kind = "none";
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                dur = _duration;
                foreach (var (a, b) in _frames.Spans)
                    if (b - a > 0.02) { inside = (a + b) / 2 * dur; break; }
                // 找一个**不在**任何区间里的位置 —— 「没缓存不能用」那一半的对照组
                for (var f = 0.99; f > 0; f -= 0.01)
                    if (!_frames.Cached(f * dur)) { outside = f * dur; break; }
                foreach (var (a, b) in _frames.Spans) cov0 += b - a;
                kind = _frames.Kind;
                Console.WriteLine($"[缩略图] 时长 {dur:0.0}s;来源 {kind};本地已有 {_frames.Spans.Count} 段 " +
                                  $"({string.Join(" ", _frames.Spans.Select(x => $"{x.A:0.00}-{x.B:0.00}"))})");
            });
            if (dur <= 0) { Console.WriteLine("[缩略图] ⚠ 还没拿到时长,这条不算数"); return; }
            if (inside < 0)
            {
                Console.WriteLine("[缩略图] ✗ 一段本地缓存都没有 —— 这条流没走本地代理,缩略图整个用不了");
                return;
            }

            /* 取数是异步的:问一次拿 null 是正常的(它这才去要),
               所以这里轮询等它回来,而不是问一次就下结论。 */
            /* 第一张要等的是**开文件**那一趟(loadfile + 等 PLAYBACK_RESTART),
               不是解一帧的 10ms。实例现在是用到才开的,所以这里的窗口要给够 ——
               给窄了会把「开得有点慢」误判成「取不到图」。 */
            Bitmap? pic = null;
            for (var k = 0; k < 90 && pic is null; k++)
            {
                await Dispatcher.UIThread.InvokeAsync(() => pic = _frames.At(inside));
                if (pic is null) await Task.Delay(150);
            }
            if (pic is null)
            {
                /* 取不到图时**必须说清是哪一种取不到**,不能只回一句空的 why:
                     · 核心层拒了(有 why)—— 那是功能问题
                     · UI 自己没发请求(位置已经不在缓存区间里了)—— 那是环境变了
                   两者的现象一模一样,而结论完全相反。上一轮就在这儿卡过。 */
                var stillCached = false;
                await Dispatcher.UIThread.InvokeAsync(() => stillCached = _frames.Cached(inside));
                Console.WriteLine($"[缩略图] ✗ 已缓存的位置({inside:0.0}s)取不到图 —— " +
                                  $"核心层说「{_frames.LastWhy ?? "(没说话)"}」;这个位置现在还算缓存着吗:{stillCached}");
            }
            else
            {
                Console.WriteLine($"[缩略图] ✓ 已缓存的位置({inside:0.0}s)有图 {pic.PixelSize.Width}x{pic.PixelSize.Height}");
            }
            /* 尺寸要**钉住**。用户 2026-09-03 点的是 140×80 ——
               核心层那个 `vf=scale=140:-2` 改错了(或者被 mpv.conf 顶掉了)的话,
               上面那条「有图」照样绿,只是每张图从 2KB 变回 8KB、内存占用翻五倍,
               而屏幕上**一点都看不出来**(气泡本来就把图缩着画)。
               只钉宽:高是按片子比例算的,钉死会把 2.35:1 的片子判成红的。 */
            if (pic is not null)
            {
                Console.WriteLine(pic.PixelSize.Width == 140
                    ? "[缩略图] ✓ 宽度是 140(用户点名的规格)"
                    : $"[缩略图] ✗ 宽度是 {pic.PixelSize.Width},不是 140 —— 一张图的体积会差好几倍");
            }

            /* 「有图」不等于「图是对的」。上一版每张都是全黑(GL 那条路忘了绑回目标 FBO),
               而「有图 + 尺寸对」两条断言照样绿。所以必须量**亮度**。 */
            if (pic is not null)
            {
                var mean = MeanLuma(pic);
                Console.WriteLine(mean > 4
                    ? $"[缩略图] ✓ 不是全黑(亮度均值 {mean:0.0})"
                    : $"[缩略图] ✗ 全黑(亮度均值 {mean:0.0}) —— 解出来了但内容不对");
            }

            /* 对照组**直接问核心层**,不走 Thumbs.At()。
               At() 自己会先看区间、没缓存就不发请求 —— 那是省一趟必然失败的往返,
               但用它做判据的话,验的只是「UI 那个 if」,而真正的保证在传输层
               (只读端点对没缓存的区间回 416)。判据要卡在保证上,不是卡在优化上。 */
            if (outside >= 0)
            {
                var r = await _core.PlayerThumbnail(new { position = outside });
                var ok = r.TryGetProperty("available", out var av2) && av2.ValueKind == JsonValueKind.True;
                /* **问完要再看一眼那个位置现在缓存了没有**。
                   正片一直在放,预取一直在填 —— 挑对照组和真去问它之间隔着几秒,
                   那几秒里它完全可能已经被缓存进来了。不复查的话,
                   一个**完全正确**的实现会被判成「竟然出了图」(实测撞过一次)。
                   这不是把断言放水:变没变是可以查清的事实,查清了再下结论
                     才叫判据;查不清就报红,那是拿环境噪音当 bug。 */
                var still = false;
                await Dispatcher.UIThread.InvokeAsync(() => still = !_frames.Cached(outside));
                Console.WriteLine((ok, still) switch
                {
                    (false, _) => $"[缩略图] ✓ 没缓存的位置({outside:0.0}s)核心层也给不出 —— 「没缓存不能用」是传输层保证的",
                    (true, false) => $"[缩略图] · 对照组({outside:0.0}s)在这几秒里被预取填上了,这一条这次不算数",
                    _ => $"[缩略图] ✗ 没缓存的位置({outside:0.0}s)竟然出了图 —— 那是从网上现拉的",
                });
            }
            else
            {
                Console.WriteLine($"[缩略图] · 整条时间轴都在本地(来源 {kind}),没有对照组");
            }

            /* 「每张都有图」也可能全是**同一张**:seek 静默失败的话,
               每次截的都是当前播放位置那一帧,而尺寸、亮度、非空全都对。 */
            if (pic is not null)
            {
                var other = -1.0;
                await Dispatcher.UIThread.InvokeAsync(() =>
                {
                    foreach (var (a, b) in _frames.Spans)
                        if (b - a > 0.02) { other = (a * 0.75 + b * 0.25) * dur; break; }
                });
                Bitmap? pic2 = null;
                for (var k = 0; k < 40 && pic2 is null; k++)
                {
                    await Dispatcher.UIThread.InvokeAsync(() => pic2 = _frames.At(other));
                    if (pic2 is null) await Task.Delay(150);
                }
                if (pic2 is null) Console.WriteLine($"[缩略图] ✗ 第二个位置({other:0.0}s)取不到图 —— {_frames.LastWhy}");
                else
                {
                    /* 比**逐像素**,不比亮度均值。自检片是彩条,两帧之间只有角上
                       一小块时间码在变 —— 拿整帧均值去比,差值是 0.0,
                       于是一条本来正确的实现被判成红的(判据选错了语料)。 */
                    var d2 = DiffPct(pic, pic2);
                    Console.WriteLine(d2 > 0.05
                        ? $"[缩略图] ✓ 两个位置的图不一样(差异像素 {d2:0.00}%)—— seek 真的生效了"
                        : $"[缩略图] ✗ 两个位置的图一模一样(差异像素 {d2:0.00}%)—— seek 没生效");
                }
            }

            /* **取缩略图不许把本地缓存撑大**。
               这是「没缓存的不能用」真正的分量所在:一旦缩略图走的是普通端点,
               它会替用户**把整部片子下下来** —— 实测注入一次,本地区间当场
               从「2 段」变成「整片 1 段」,而所有其它断言照样全绿
               (每个位置都有图了嘛)。所以判据要卡在**缓存有没有变大**上。
               这一条能成立的前提是**环形缓存装不下整片**(自检把它钉在下限
                 64MB,片子 83MB)。装得下的话跑够久就是 100%,基线和终值都顶格,
                 这条判据什么也证明不了 —— 而且**不报错**,只是永远绿。
               真正把「只读端点不碰上游」钉死的是核心层那条单测
                 (TestC26_只读缓存端点不碰上游,注入验过红);这里是端到端的复核。 */
            var cov1 = 0.0;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                foreach (var (a, b) in _frames.Spans) cov1 += b - a;
            });
            /* 基线本身也要判。第一版只比了「前后差值」,而注入验红时发现
               **下载发生在采基线之前**(实例装载那一下就把整片拉完了),
               于是 100% → 100%,差值为 0,一条本该红的判据绿了。 */
            if (kind == "proxy" && cov0 > 0.98)
                Console.WriteLine($"[缩略图] ✗ 才放了十几秒,整片({cov0 * 100:0.0}%)就都在本地了 —— 取图这条路在替用户下载");
            else
                Console.WriteLine(cov1 - cov0 < 0.2
                    ? $"[缩略图] ✓ 取图没把本地缓存撑大(覆盖率 {cov0 * 100:0.0}% → {cov1 * 100:0.0}%)"
                    : $"[缩略图] ✗ 取图把本地缓存撑大了({cov0 * 100:0.0}% → {cov1 * 100:0.0}%)—— 它在替用户下载");

            /* <b>扫一趟进度条,数数真发了几次请求</b>。
               用户 2026-09-04:「滑动缩略图的时候视频会不断卡顿,画面不断抽搐」——
               根因是每扫过一格就排一个解码任务,几十上百个一起压到核心层那把锁上。
               判据是**请求数**,不是「有没有图」:两种实现都有图,
                 差别在扫过去的那一路上有没有把 CPU 和磁盘占满。
               反向注入:把 Thumbs.At 改回「每格各发各的」,这个数会逼近扫过的格数。 */
            var asked0 = _frames.Asked;
            var swept = 0;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                foreach (var (a, b2) in _frames.Spans)
                    for (var f = a; f < b2; f += 1.0 / Thumbs.Slots) { _frames.At(f * dur); swept++; }
            });
            await Task.Delay(1500);
            var askedN = _frames.Asked - asked0;
            Console.WriteLine(swept > 0 && askedN <= Math.Max(3, swept / 8)
                ? $"[缩略图] ✓ 扫过 {swept} 格只真发了 {askedN} 次请求 —— 过期的那些被丢掉了"
                : $"[缩略图] ✗ 扫过 {swept} 格发了 {askedN} 次请求 —— 拖一趟进度条就是这么多次解码");

            // 把气泡钉出来给截图看:悬停事件在自检里发不出去
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                ShowOsd(true); // 不显式打开的话控制条早淡出了,带子就进不了截图
                _bar.SelfCheckHover(_bar.Bounds.Width * inside / dur);
                _bar.Preview?.Invoke(inside);
                _bubble.IsVisible = true;
                Console.WriteLine($"[缩略图] 进度条带子 {_bar.CachedSpans.Count} 段(悬停态已钉住,进截图)");
            });
            await Task.Delay(400);
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                var box = _bubble.Child as Panel;
                Console.WriteLine($"[缩略图] 气泡 {_bubble.Bounds.Width:0}x{_bubble.Bounds.Height:0} " +
                                  $"@ ({_bubble.Bounds.X:0},{_bubble.Bounds.Y:0});" +
                                  $"图框可见 {box?.Children[0].IsVisible} {box?.Children[0].Bounds.Height:0};" +
                                  $"文字 {_bubbleText.Text}");

                /* 「时间和缩略图是一块」的判据 = <b>时间条压在图上</b>。
                   用户 2026-09-04:「缩略图下面的时间有时候会变成一个黑色矩形挡住一点点缩略图,
                   感觉是因为时间和缩略图不是一块做出来的」。
                   判「有没有重叠」,不是判「差几像素」—— 摞着排(StackPanel)时
                     两块永远是**相邻**的,重叠恒等于 0;叠着排时时间条整条都在图的范围内。
                     所以这条断言对旧写法必红,对新写法必绿,中间没有可调的数。
                   反向注入:把那个 Panel 换回 StackPanel,这一条当场红。 */
                if (box is { } bx && bx.Children.Count >= 2)
                {
                    var img = bx.Children[0].Bounds;
                    var strip = bx.Children[1].Bounds;
                    var over = Math.Min(img.Bottom, strip.Bottom) - Math.Max(img.Top, strip.Top);
                    Console.WriteLine(bx.Children[0].IsVisible && over > 4
                        ? $"[缩略图] ✓ 时间压在图上(重叠 {over:0}px)—— 图和时间是一块,不是底下另贴一条黑边"
                        : $"[缩略图] ✗ 时间条和图只是摞着(重叠 {over:0}px)—— 那条黑边就是用户看到的黑矩形");
                    Console.WriteLine(Math.Abs(_bubble.Bounds.Height - (ThumbH + 2)) < 3
                        ? $"[缩略图] ✓ 卡片就是图的大小({_bubble.Bounds.Height:0}px),四周没有黑留白"
                        : $"[缩略图] ✗ 卡片 {_bubble.Bounds.Height:0}px 比图({ThumbH})高出一截 —— 多出来的就是黑边");
                }
            });
        });
    }

    /// <summary>
    /// 两张图有多少比例的像素不一样(0~100)。
    ///
    /// <para>判「这两帧是不是同一帧」只能逐像素。均值/直方图这类整体量在
    /// 静态画面上分辨不出来 —— 而缩略图最常见的错法正是**每张都是同一帧**。</para>
    /// </summary>
    private static double DiffPct(Bitmap a, Bitmap b)
    {
        if (a.PixelSize != b.PixelSize) return 100;
        var pa = Pixels(a);
        var pb = Pixels(b);
        var diff = 0;
        for (var i = 0; i < pa.Length; i += 4)
            if (pa[i] != pb[i] || pa[i + 1] != pb[i + 1] || pa[i + 2] != pb[i + 2]) diff++;
        return diff * 400.0 / pa.Length;
    }

    private static byte[] Pixels(Bitmap b)
    {
        var w = b.PixelSize.Width;
        var h = b.PixelSize.Height;
        var stride = w * 4;
        var buf = new byte[stride * h];
        var gc = System.Runtime.InteropServices.GCHandle.Alloc(buf,
            System.Runtime.InteropServices.GCHandleType.Pinned);
        try { b.CopyPixels(new PixelRect(0, 0, w, h), gc.AddrOfPinnedObject(), buf.Length, stride); }
        finally { gc.Free(); }
        return buf;
    }

    /// <summary>一张图的平均亮度。判「解出来了但内容不对」用 —— 全黑图的尺寸和对象都是对的。</summary>
    private static double MeanLuma(Bitmap b)
    {
        var buf = Pixels(b);
        long sum = 0;
        var n = 0;
        for (var i = 0; i + 2 < buf.Length; i += 4 * 37) { sum += buf[i] + buf[i + 1] + buf[i + 2]; n += 3; }
        return n > 0 ? sum / (double)n : 0;
    }

    /// <summary>
    /// 自检:<c>LP_PANEL=1</c> —— 抽屉开着的时候,OSD 不许把它收走。
    ///
    /// <para>用户说「字幕 超分 比例 全都不生效」,那三条命令其实都接对了,坏的是
    /// 三秒不动 → <c>ShowOsd(false)</c> → 最后一句 <c>_settings.IsVisible = false</c>。
    /// 判据必须真的等够 4.5 秒,中途一次鼠标事件都不发 —— 发了就刷新了
    /// <c>_lastMove</c>,这条断言会变成永远绿。</para>
    /// </summary>
    private void SelfCheckPanel()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PANEL") != "1") return;
        _ = Task.Run(async () =>
        {
            await Task.Delay(7000);
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                ShowSettings(true);
                // 把「最后一次动鼠标」摆回现在,好让这 4.5 秒是干干净净的静止
                _lastMove = DateTime.UtcNow;
            });
            await Task.Delay(4500);
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                Console.WriteLine(_settings.IsVisible
                    ? "[设置面板] ✓ 静止 4.5 秒之后面板还在 —— 读选项的时候它不会被抽走"
                    : "[设置面板] ✗ 静止 4.5 秒面板自己没了 —— 面板里的每一项都等于点不着");
                Console.WriteLine(_osdOn
                    ? "[设置面板] ✓ 控制条也跟着留着(面板底下是空的话它看着像画错了)"
                    : "[设置面板] ✗ 控制条收了而面板留着");
                // 关掉之后 OSD 该收还是收 —— 不验这一条的话,一个「永不自动收」的
                // 实现也照样绿,而那会让控制条一直压着画面。
                ShowSettings(false);
                _lastMove = DateTime.UtcNow;
            });
            /* 这一条要**轮询等**,不能死等 4.5 秒就断言。
               窗口刚起来时系统会补一次 PointerMoved(鼠标本来就停在窗口范围里),
               那一下把 _lastMove 刷了,3 秒的计时就重头再来 —— 实测两次跑一红一绿,
               代码一行没改。等到 12 秒还不收,才是真的「永不自动收」。 */
            var hid = false;
            for (var i = 0; i < 24 && !hid; i++)
            {
                await Task.Delay(500);
                await Dispatcher.UIThread.InvokeAsync(() => hid = !_osdOn);
            }
            Console.WriteLine(hid
                ? "[设置面板] ✓ 关掉面板之后 OSD 照常自动收"
                : "[设置面板] ✗ 面板关了 OSD 还赖着 —— 变成永不自动收了");
            await SelfCheckPanelApplies();
        });
    }

    /// <summary>
    /// 自检(接着 <see cref="SelfCheckPanel"/> 跑):面板里选一项,mpv 上真的变了。
    ///
    /// <para>判据是 <c>player.mpvGet</c> 回读的属性值,不是命令的返回码 ——
    /// mpv 认不出的值是静默无视的,「拉伸填满」那一档就这么坏了几个月。
    /// 选项一律走 <c>SelectedIndex</c> 让 SelectionChanged 跑一遍;直接调
    /// <c>Send(...)</c> 的话,接线断了这条断言也照样绿。</para>
    /// </summary>
    private async Task SelfCheckPanelApplies()
    {
        async Task<string> Get(string name)
        {
            try
            {
                var r = await _core.CallAsync("player.mpvGet", new { name });
                return r.TryGetProperty("value", out var v) && v.ValueKind == JsonValueKind.String
                    ? v.GetString() ?? "" : "";
            }
            catch (Exception e) { return "读不到:" + e.Message; }
        }

        // ---- 比例:16:9 ----
        await Dispatcher.UIThread.InvokeAsync(() => _aspect.SelectedIndex = 1);
        await Task.Delay(600);
        var ar = await Get("video-aspect-override");
        var keep = await Get("keepaspect");
        Console.WriteLine(ar.StartsWith("1.77") && keep == "yes"
            ? $"[比例] ✓ 选 16:9 之后 mpv 的 video-aspect-override={ar}"
            : $"[比例] ✗ 选了 16:9,mpv 那边 video-aspect-override={ar} keepaspect={keep}");

        // ---- 比例:拉伸填满(这一档原来是死的)----
        await Dispatcher.UIThread.InvokeAsync(() => _aspect.SelectedIndex = 4);
        await Task.Delay(600);
        keep = await Get("keepaspect");
        Console.WriteLine(keep == "no"
            ? "[比例] ✓ 「拉伸填满」真的关掉了保持宽高比(keepaspect=no)"
            : $"[比例] ✗ 「拉伸填满」没生效(keepaspect={keep})—— 那不是一个宽高比,是 keepaspect");

        // ---- 比例:切回自动,keepaspect 要放回去 ----
        await Dispatcher.UIThread.InvokeAsync(() => _aspect.SelectedIndex = 0);
        await Task.Delay(600);
        keep = await Get("keepaspect");
        Console.WriteLine(keep == "yes"
            ? "[比例] ✓ 切回「自动」之后 keepaspect 放回来了"
            : $"[比例] ✗ 拉伸过一次就回不去了(keepaspect={keep})");

        /* ---- 字幕:选一条真轨,读 mpv 的 sid ----
            自检片本身**没有字幕轨**,所以先挂一条外挂字幕上去(LP_SELFCHECK_SRT
             指着自检脚本写出来的那个 .srt)。没有这一步的话,下拉里只有「关闭字幕」
             一项,选它等于什么都没选 —— 那条断言就成了永远绿的摆设。 */
        var srt = Environment.GetEnvironmentVariable("LP_SELFCHECK_SRT") ?? "";
        if (srt.Length > 0)
        {
            try { await _core.CallAsync("player.addSubtitle", new { url = srt, title = "自检字幕" }); }
            catch (Exception e) { Console.WriteLine($"[字幕] · 挂不上外挂字幕:{e.Message}"); }
            await Task.Delay(1200);
            await Dispatcher.UIThread.InvokeAsync(() => _ = LoadTracks());
            await Task.Delay(1200);
        }

        var subCount = 0;
        await Dispatcher.UIThread.InvokeAsync(() =>
        {
            subCount = _subs.ItemCount;
            if (subCount > 1) _subs.SelectedIndex = subCount - 1;
        });
        if (subCount > 1)
        {
            await Task.Delay(800);
            var want = "";
            await Dispatcher.UIThread.InvokeAsync(() =>
                want = (_subs.SelectedItem as TrackOption)?.Id ?? "");
            var sid = await Get("sid");
            Console.WriteLine(want.Length > 0 && sid == want
                ? $"[字幕] ✓ 在面板里选第 {subCount} 条,mpv 的 sid={sid} —— 对上了"
                : $"[字幕] ✗ 面板里选的是 {want},mpv 的 sid={sid}");

            // 反方向也要验:「关闭字幕」必须真的关掉(sid=no),
            // 不然这一项点了看着像没反应,而它正是最常用的那一项。
            await Dispatcher.UIThread.InvokeAsync(() => _subs.SelectedIndex = 0);
            await Task.Delay(800);
            var off = await Get("sid");
            Console.WriteLine(off is "no" or ""
                ? "[字幕] ✓ 「关闭字幕」真的关掉了(sid=no)"
                : $"[字幕] ✗ 选了「关闭字幕」,mpv 的 sid 还是 {off}");
        }
        else Console.WriteLine($"[字幕] · 这条片子只有 {subCount} 个字幕选项,没得选");
    }

    /// <summary>
    /// 自检:上下两条<b>是渐隐的,不是一刀切</b>(用户 2026-09-03 点名)。
    ///
    /// <para>判据必须是<b>逐帧采到的 Opacity</b>。
    /// 只断言「收起后 Opacity==0」的话,一刀切也照样绿 —— 那正是改之前的行为。
    /// 要证明的是「中间经过了别的值」,和侧栏动效那条同一个道理。</para>
    /// </summary>
    private void SelfCheckOsdFade()
    {
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_OSDFADE") != "1") return;
        _ = Task.Delay(3000).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
        {
            var seen = new List<double>();
            var slid = new List<double>();
            var n = 0;
            ShowOsd(false);
            double Slide() => _bottom.RenderTransform is Avalonia.Media.Transformation.TransformOperations t
                ? Math.Round(t.Value.M32, 1) : 0;
            void Sample(TimeSpan _)
            {
                seen.Add(Math.Round(_bottom.Opacity, 2));
                slid.Add(Slide());
                if (++n < 24) TopLevel.GetTopLevel(this)!.RequestAnimationFrame(Sample);
                else
                {
                    var mid = seen.Where(v => v is > 0.02 and < 0.98).ToList();
                    Console.WriteLine($"[OSD 渐隐] 采到 {string.Join(" ", seen.Distinct())}");
                    Console.WriteLine(mid.Count > 0
                        ? $"[OSD 渐隐] ✓ 中间经过了 {mid.Count} 个过渡值 —— 是淡出,不是瞬间消失"
                        : "[OSD 渐隐] ✗ 只有 1 和 0 两个值 —— 一刀切,没有渐隐");
                    /* 2026-09-04 加:<b>位移也要采</b>。用户说「上下栏**还是**不会渐显渐隐」——
                       只有 Opacity 的淡出在一块本来就半透明的渐变蒙版上几乎读不出来。
                       这一版让上下栏各自滑出画面,而位移是不是真在动,
                       和透明度一样只能逐帧采。 */
                    var moved = slid.Distinct().Count();
                    Console.WriteLine($"[OSD 渐隐] 位移采到 {string.Join(" ", slid.Distinct())}");
                    Console.WriteLine(moved > 2
                        ? $"[OSD 渐隐] ✓ 位移经过了 {moved} 个中间值 —— 下栏是滑下去的"
                        : "[OSD 渐隐] ✗ 位移没有中间值 —— 只有淡出,没有滑出");
                    Console.WriteLine(_bottom.IsHitTestVisible
                        ? "[OSD 渐隐] ✗ 收起后还在吃鼠标事件 —— 画面上下两头会点不动"
                        : "[OSD 渐隐] ✓ 收起后不吃鼠标事件了");
                }
            }
            TopLevel.GetTopLevel(this)!.RequestAnimationFrame(Sample);
        }));
    }

    /// <summary>出场时长:跟手就行,用户刚动了鼠标,他在等界面。</summary>
    private const int OsdInMs = 170;

    /// <summary>退场时长。<b>比出场慢一倍多</b> —— 那是「让开」,不是「消失」。</summary>
    private const int OsdOutMs = 420;

    /// <summary>上下栏收起时各自滑出去多少像素。</summary>
    private const double OsdSlide = 14;

    /// <summary>OSD 那两条的过渡。<b>时长是参数</b> —— 出场退场用两套。</summary>
    private static Transitions Fade(int ms) =>
    [
        new DoubleTransition
        {
            Property = OpacityProperty,
            Duration = TimeSpan.FromMilliseconds(ms),
            Easing = new Avalonia.Animation.Easings.CubicEaseOut(),
        },
        new Avalonia.Animation.TransformOperationsTransition
        {
            Property = RenderTransformProperty,
            Duration = TimeSpan.FromMilliseconds(ms),
            Easing = new Avalonia.Animation.Easings.CubicEaseOut(),
        },
    ];

    /// <summary>
    /// OSD 收放。三秒不动就收起来 —— 一直压着画面就不是看片了。
    ///
    /// <para>淡入淡出,不是翻 <c>IsVisible</c>:一条黑渐变条凭空出现 / 凭空消失,
    /// 在暗场景里尤其突兀。<c>IsHitTestVisible</c> 必须跟着一起翻 ——
    /// 透明的控件照样吃鼠标事件,表现是「上下两头点了没反应」。
    /// 收起时不置 <c>IsVisible=false</c>:过渡没跑完就被摘掉等于没有动画。</para>
    /// </summary>
    /// <summary>
    /// 开 / 关设置抽屉。
    ///
    /// <para><b>打开时必须把 OSD 一起点亮</b>。抽屉底下没有控制条的时候,
    /// 它是一块孤零零飘在画面上的面板 —— 而且它下面那条进度条已经不见了,
    /// 看着就像画错了地方(ShowOsd 里那句「抽屉要跟着收」讲的是反方向的同一件事)。</para>
    /// <para>顺手把 <c>_lastMove</c> 摆回现在:打开抽屉本身就是一次「人在操作」。</para>
    /// </summary>
    private void ShowSettings(bool on)
    {
        if (on)
        {
            _lastMove = DateTime.UtcNow;
            ShowOsd(true);
        }
        _settings.IsVisible = on;
    }

    private void ShowOsd(bool on)
    {
        if (_osdOn == on) return;
        _osdOn = on;
        foreach (var (b, dir) in new[] { (_top, -1.0), (_bottom, 1.0) })
        {
            // 先换过渡再改值:Transitions 是读到「属性变了」那一刻才生效的,
            // 顺序反过来的话这一次仍然按上一次那套时长跑。
            b.Transitions = Fade(on ? OsdInMs : OsdOutMs);
            b.Opacity = on ? 1 : 0;
            b.RenderTransform = Avalonia.Media.Transformation.TransformOperations.Parse(
                on ? "translateY(0px)" : $"translateY({dir * OsdSlide}px)");
            b.IsHitTestVisible = on;
        }
        // 抽屉要跟着收。留着的话 OSD 收了之后画面上孤零零飘着一块面板,
        // 而且它下面那条控制条已经没了,看着像画错了。
        if (!on) _settings.IsVisible = false;
        Cursor = new Cursor(on ? StandardCursorType.Arrow : StandardCursorType.None);
    }

    /// <summary>OSD 当前是不是亮着。 不能再拿 <c>_top.IsVisible</c> 当判据 —— 它恒真了。</summary>
    private bool _osdOn = true;

    /// <summary>最近一次读到的音画差(秒)。-1 = 没数。自检用,见 SelfCheckAvSync。</summary>
    private double _avsync = -1;

    /// <summary>解码器丢帧数。和授时分得开:一个是机器扛不住,一个是帧上错了时候。</summary>
    private double _drops;

    /// <summary>mpv 自己数的「晚于目标时刻上屏」的帧数,和它估的 vsync 抖动。
    /// 画面稳不稳看这个 —— 输入是我们 report_swap 报上去的真实上屏时刻。</summary>
    private double _voDelayed, _vsyncJitter;

    /// <summary>相邻两帧上屏的平均间隔 / 间隔抖动(毫秒)。核心层 noteCadence 算的。</summary>
    private double _gapMs, _jitterMs;

    /// <summary>lp_gl_render 累计堵了多久(毫秒)、堵超 16ms 的次数、调用次数。
    /// 都是**累计量**,要某一段的数自己做差。它跑在合成线程上 ——
    /// 堵多久,整个界面就多久画不了新东西。</summary>
    private double _renderSum, _renderSlow, _renderCalls, _advanceCalls;

    /// <summary>齿轮按钮。「点别处关面板」那一条要把它排除掉,见构造函数。</summary>
    private Control? _gear;

    /// <summary>「为什么没有缩略图」这句话说过了没有。一场播放只说一次。</summary>
    private bool _thumbNoted;

    /// <summary>
    /// 缩略图取不到时,把原因说出来。
    ///
    /// <para>帧只从本地字节里解,而本地字节只有两种来源:这条流走了预取代理
    /// (= 那台服务器开了「多线程加载」,默认关),或者本地文件。所以对绝大多数
    /// 用户,这个功能从上线起一次都没工作过,而界面上没有任何东西说明为什么。
    /// 这里不改那条规矩,只把沉默的失败变成一句能照着做的话。一场播放只说一次。</para>
    /// </summary>
    private void NoteThumbUnavailable()
    {
        if (_thumbNoted || _frames.Kind != "none") return;
        _thumbNoted = true;
        _msg.Text = "进度条缩略图要用本地缓存的字节 —— 在「设置 → 多线程加载」里给这台服务器打开才有。";
    }

    /// <summary>
    /// 指针是不是停在上下两条 OSD 上。
    ///
    /// <para><b>按坐标算,不问命中测试</b> —— 理由见 <see cref="_ptr"/>。
    /// 「鼠标停在控制条上就不收 OSD」这条规矩本身没变(所有现代播放器都有),
    /// 变的只是它怎么判。</para>
    /// </summary>
    private bool PointerOnOsd()
    {
        if (_ptr.X < 0) return false;   // 还没收到过指针事件
        return In(_top) || In(_bottom);

        bool In(Control c)
        {
            if (c.Bounds.Width <= 0) return false;
            var at = c.TranslatePoint(default, this);
            return at is { } o && new Rect(o, c.Bounds.Size).Contains(_ptr);
        }
    }

    /// <summary>
    /// 一格延迟步进器:<c>− 0.0s + 归零</c>。
    ///
    /// <para>步长 0.1 秒 —— 字幕对轴的实际分辨率就是这个量级;
    /// 按住不放会连发(Avalonia 的 Button 自带 <c>ClickMode</c> 不连发,
    /// 但对轴本来就是「点几下看一眼」的操作,连发反而容易过头)。</para>
    /// <para>「归零」单独一个键:这是这一格最常用的动作,
    /// 让用户按十几下 − 回到 0 是没道理的。</para>
    /// </summary>
    private static Control Stepper(TextBlock readout, Action<double> apply)
    {
        Button Key(string text, double delta)
        {
            var b = new Button
            {
                Content = text, Classes = { "osdstep" },
                Width = delta == 0 ? 40 : 28, Height = 28,
                HorizontalContentAlignment = HorizontalAlignment.Center,
                VerticalContentAlignment = VerticalAlignment.Center,
            };
            b.Click += (_, _) => apply(delta);
            return b;
        }

        readout.Width = 46;
        readout.TextAlignment = TextAlignment.Center;
        return new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 6,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { Key("−", -0.1), readout, Key("+", +0.1), Key("归零", 0) },
        };
    }

    /// <summary>步进器按下之后:改值 → 刷读数 → 送给核心层。<paramref name="delta"/> 为 0 = 归零。</summary>
    private void SetDelay(ref double slot, double delta, TextBlock readout, string cmd)
    {
        slot = delta == 0 ? 0 : Math.Clamp(Math.Round((slot + delta) * 10) / 10, -10, 10);
        readout.Text = $"{slot:0.0}s";
        _ = Send(cmd, new { secs = slot });
    }

    /// <summary>
    /// 画质档位(<c>UI_PC.md</c> §7 底部第七个面板,快捷键 <c>U</c>)。
    ///
    /// <para>档位表由<b>核心层</b>给(28 档,分 Anime4K / FSR / NVIDIA / 通用四族),
    /// UI 不自己写一份。写一份的下场是加档位要改两处,而漏改的那处不报错。</para>
    ///
    /// <para><b>档位故意不持久化</b>(2026-08-31 已定,别顺手加)——
    /// 它跟当前这一片的分辨率和窗口大小绑定,记住上一片的档位只会带来
    /// 「上次好好的这次不生效」。</para>
    /// </summary>
    /// <summary>
    /// 自检:<c>LP_SHADER=all</c> —— <b>把全部档位挨个挂一遍</b>,报出哪些编译不过。
    ///
    /// <para>存在的理由:着色器方言跟渲染后端走。换了后端(这里是
    /// libplacebo → gl_video + ANGLE),<b>每一档都得重新验</b> ——
    /// 而这类失败编译绿、单测绿、返回码也绿,只有真渲染才现形。
    /// 一档一档手点要跑 28 轮,没人会跑;一轮跑完才有人跑。</para>
    /// </summary>
    private async Task SelfCheckSweepQuality()
    {
        await Task.Delay(7000);
        if (_quality.ItemsSource is not IEnumerable<ShaderLevel> items) return;
        Console.WriteLine("[shader-sweep] 开始");
        foreach (var lv in items)
        {
            if (lv.Id == "off") continue;
            try
            {
                var r = await _core.PlayerSetShaderLevel(new { level = lv.Id });
                var reverted = r.TryGetProperty("reverted", out var rv) && rv.ValueKind == JsonValueKind.True;
                Console.WriteLine(reverted
                    ? $"[shader-sweep] BAD  {lv.Id}  {Str(r, "note")}"
                    : $"[shader-sweep] ok   {lv.Id}");
            }
            catch (Exception e) { Console.WriteLine($"[shader-sweep] ERR  {lv.Id}  {e.Message}"); }
            await _core.PlayerSetShaderLevel(new { level = "off" }); // 每档之间清干净
        }
        Console.WriteLine("[shader-sweep] 结束");
    }

    /// <summary>自检:等起播和档位表就位之后选一档,并把 OSD 钉住不收。</summary>
    private async Task SelfCheckPickQuality(string id)
    {
        if (id == "all") { await SelfCheckSweepQuality(); return; }
        await Task.Delay(7000);
        if (_quality.ItemsSource is IEnumerable<ShaderLevel> items)
        {
            var hit = items.FirstOrDefault(x => x.Id == id);
            if (hit is null) { _msg.Text = $"自检:档位表里没有 {id}"; return; }
            _quality.SelectedItem = hit;
        }
        _lastMove = DateTime.UtcNow.AddYears(1);
        ShowOsd(true);
    }

    /// <summary>
    /// 拉超分档位表。
    ///
    /// <para>不会生效的档位不进列表(用户:「不生效的选项直接删掉」)。核心层每档
    /// 带 <c>will_run</c>,和真正挂载时用同一份判据。放大那几档要求画面区 &gt; 源的
    /// 1.2 倍,窗口模式下一档都不满足。没有这个键 = 还没起播,那就全都留着。
    /// 全屏切换之后要重拉:画面区变了,能跑的档也变了。</para>
    /// </summary>
    private async Task LoadQualityLevels()
    {
        try
        {
            var r = await _core.PlayerShaderLevels();
            if (r.ValueKind != JsonValueKind.Array) return;
            var items = new List<ShaderLevel>();
            var dropped = 0;
            foreach (var l in r.EnumerateArray())
            {
                var id = Str(l, "id");
                // off 永远留着 —— 它是「关掉」,不是一档效果
                if (id != "off" && l.TryGetProperty("will_run", out var wr)
                                && wr.ValueKind == JsonValueKind.False)
                {
                    dropped++;
                    continue;
                }
                var name = Str(l, "name");
                var group = Str(l, "group");
                items.Add(new ShaderLevel(id, group == "" ? name : group + " · " + name));
            }
            var keep = _quality.SelectedItem as ShaderLevel;
            _qualityMuted = true;          // 重建列表不该触发一次挂载
            _quality.ItemsSource = items;
            // 重拉之后尽量停在原来那一档(全屏切换会重拉);它被滤掉了就回「关闭」
            var at = keep is null ? 0 : items.FindIndex(x => x.Id == keep.Id);
            _quality.SelectedIndex = at < 0 ? 0 : at;
            _qualityMuted = false;
            if (dropped > 0)
                Console.WriteLine($"[超分] 当前画面尺寸下有 {dropped} 档不会生效,已从列表里去掉");
        }
        catch (Exception e) { _msg.Text = $"超分档位读不到:{LibraryPage.Advice(e)}"; }
    }

    private bool _qualityMuted;

    private async Task PickQuality()
    {
        if (_qualityMuted) return;
        if (_quality.SelectedItem is not ShaderLevel lv) return;
        try
        {
            var r = await _core.PlayerSetShaderLevel(new { level = lv.Id });
            /* 这里必须把核心层的判断**原样透出来**。
               `count > 0` 只能证明 mpv 收下了 shader 路径,**证明不了它会跑** ——
               放大类每个 pass 都带 `//!WHEN 输出>源*1.2`,窗口没比源大就整条链空转,
               画面一点没变。旧版 UI 在这种情况下照样报「超分已生效 · 挂载 6 个 shader」,
               那是在撒谎,是本项目最贵的那类 bug。 */
            if (r.TryGetProperty("will_run", out var wr) && wr.ValueKind == JsonValueKind.False)
            {
                _msg.Text = Str(r, "note");
                /* 核心层自己退回关闭时,下拉框**必须跟着回到「关闭」**。
                   不回的话界面显示「Anime4K · 锐化+去噪」而实际是关的 ——
                   那是同一类谎,只是换了个地方说(2026-09-02 截图上抓到)。 */
                if (r.TryGetProperty("reverted", out var rv) && rv.ValueKind == JsonValueKind.True)
                {
                    _qualityMuted = true;          // 回位不该再触发一次请求
                    _quality.SelectedIndex = 0;
                    _qualityMuted = false;
                }
                return;
            }
            var n = r.TryGetProperty("count", out var c) && c.TryGetInt32(out var ci) ? ci : 0;
            _msg.Text = n == 0 ? "超分已关闭" : $"已启用:{lv.Name}";
        }
        catch (Exception e) { _msg.Text = LibraryPage.Advice(e); }
    }

    private sealed record ShaderLevel(string Id, string Name)
    {
        public override string ToString() => Name;
    }

    private async Task PickTrack(string kind, ComboBox box)
    {
        if (box.SelectedItem is not TrackOption t) return;
        try { await _core.PlayerSetTrack(new { kind, id = t.Id }); }
        catch (Exception e) { _msg.Text = LibraryPage.Advice(e); }
    }

    private async Task Send(string cmd, object args)
    {
        try { await _core.CallAsync(cmd, args); }
        catch { /* 音量/静音这类失败不值得打断看片 */ }
    }

    // ---------------------------------------------------------------- 轮询

    private double _reportedAt = -1;

    /// <summary>
    /// 播放中定时向服务器上报进度(每 10 秒)。
    ///
    /// <para><c>emby.reportProgress</c> 原来全仓零调用,后果是服务器上的续播位置
    /// 整场播放一次都不更新 —— 本仓第七次「后端领先前端」。10 秒是照核心层的
    /// 节流来的,更密只是白打服务器。暂停也要报一次(Emby 靠 <c>IsPaused</c>
    /// 决定「正在播放」那一栏),所以判据是位置或暂停态变了。源播放不报。</para>
    /// </summary>
    private void ReportProgress(double pos, bool paused)
    {
        if (NoEmby || _leaving || Nav.Session is not { } s) return;
        if (_reportedAt >= 0 && Math.Abs(pos - _reportedAt) < 10 && paused == _reportedPaused) return;
        _reportedAt = pos;
        _reportedPaused = paused;
        // 不 await:上报是记账,播放是主线。失败了核心层自己写 warn 日志,
        // 往用户脸上弹红字的话每 10 秒一次就是刷屏。
        try { _ = _core.EmbyReportProgress(new { s.server, s.token, s.user_id, s.device_id, pos, paused }); }
        catch { /* 同上 */ }
    }

    private bool _reportedPaused;

    private async Task Poll()
    {
        JsonElement st;
        try { st = await _core.PlayerStatus(new { }); }
        catch { return; }   // 每 250ms 一拍,弹提示会刷屏;下一拍自然补上

        var pos = Num(st, "position");
        var dur = Num(st, "duration");
        var paused = st.TryGetProperty("paused", out var p) && p.ValueKind == JsonValueKind.True;
        _muted = st.TryGetProperty("mute", out var mu) && mu.ValueKind == JsonValueKind.True;
        var eof = st.TryGetProperty("eof", out var f) && f.ValueKind == JsonValueKind.True;

        // keep-open=yes 之下 END_FILE **永远不发**(文件不卸载),
        // 判「播完了」只能读 eof-reached。这是「播完不同步进度」的根因。
        if (eof && !_leaving) { Leave(); return; }

        ReportProgress(pos, paused);

        // 拿到时长才去问轨道表:loadfile 是异步的,早问回来的是空表,
        // 而空表会把两个下拉框永久固定成空的 —— 之后再没人重问。
        // 章节同理:chapterInfo 要拿 runtime_secs 去算片头片尾,时长是 0 的时候算不出来。
        if (!_tracksLoaded && dur > 0)
        {
            _tracksLoaded = true;
            _duration = dur;
            _ = LoadTracks();
            _ = LoadChapters();
            /* 超分档位表也要在**这里**重拉一次。
               构造函数里那次拉的时候 mpv 还没解出画面尺寸(video-params/w = 0),
               核心层就不给 will_run —— 于是「只留会生效的档」这条**一次都没生效过**。
               自检当场逮到:1080p 源放在 1920 窗口里(放大档一档都不会跑),
               列表里那五档照样全在,日志里一行「已去掉 N 档」都没有。
               这正是本仓说的那类假绿:代码写了、编译过了、就是从没跑到过。 */
            _ = LoadQualityLevels();
        }

        /* 倍速可能被别处改(mpv.conf / 快捷键 / 上一次的粘连),
           以状态里的为准 —— 按钮上写着 1× 而实际在放 1.5× 是「界面在撒谎」。 */
        var sp = Num(st, "speed");
        if (sp > 0 && Math.Abs(sp - _speedValue) > 0.01)
        {
            _speedValue = sp;
            _speed.Content = Math.Abs(sp - 1.0) < 0.01 ? "1×" : $"{sp:0.##}×";
            _speed.Classes.Set("on", Math.Abs(sp - 1.0) > 0.01);
        }
        SyncSkip(pos);

        /* 3 秒不动就收。 两个例外,都是现代播放器的通行做法:
           ①<b>暂停时不收</b> —— 暂停就是「我要看清楚这一帧 / 我要操作」;
           ②<b>鼠标停在控制条上不收</b> —— 手还在滑块上,条却没了。 */
        /* <b>抽屉开着的时候一秒都不许收</b>(用户 2026-09-04:
           「播放页的控制面板 字幕 超分 比例 这些全都不生效,
           我估计这个设置面板里面的所有都不生效了」)。

           根因不在那几条命令上 —— 它们都接对了。是这一行把面板<b>从用户手底下抽走</b>:
             · ShowOsd(false) 的最后一句是 `_settings.IsVisible = false`;
             · 而判「人还在操作」只看了 _top / _bottom 两条(PointerOnOsd),
               <b>抽屉不在里面</b> —— 它挂在画面正中偏下,离那两条十万八千里;
             · 更要命的是**下拉框展开的时候**:弹出层是另一个顶层窗口,
               鼠标在它上面移动,这一页收不到任何 PointerMoved,_lastMove 就此冻住。
           于是:点开「字幕」,读三秒选项,面板连同展开的下拉一起消失,那一下选择当场作废。
           三样东西一起不生效,不是三个 bug,是这一个。

           为什么不是「把 _settings 也加进 PointerOnOsd」:那只挡得住「鼠标停在面板上」,
             挡不住「鼠标停在弹出层上」—— 而后者恰恰是最常见的那三秒。
           面板一关(点别处 / 再点齿轮),这一行立刻恢复作用,OSD 该收还是收。 */
        if (DateTime.UtcNow - _lastMove > TimeSpan.FromSeconds(3) && !paused
            && !PointerOnOsd() && !_settings.IsVisible)
            ShowOsd(false);

        // 闩和**目标**比,不和上一次读到的位置比(见字段上的注释)
        if (_seekTarget >= 0)
        {
            if (Math.Abs(pos - _seekTarget) < 1.5) _seekTarget = -1;
            else return;
        }
        _duration = dur;
        _position = Math.Clamp(pos, 0, dur > 0 ? dur : 1);
        // buffered = 已缓冲到哪一秒(核心层读的是 mpv demuxer-cache-time,本地文件是 0)
        _bar.Sync(_position, dur, Num(st, "buffered"));
        /* 帧库要知道「现在放到哪、一共多长」才能分格 —— 采帧那一侧在 GL 线程上,
           它不该自己去打命令(那是每一帧一次往返)。这里顺手喂,轮询本来就在跑。 */
        _frames.Duration = dur;
        /* 音画差:轮询里顺手记一份,自检拿它判「画面抽不抽搐」。见 SelfCheckAvSync。
            核心层拿不到时给 -1(0 是合法值,不能拿它当「没数」)。 */
        _avsync = Num(st, "avsync");
        _drops = Num(st, "drops");
        _voDelayed = Num(st, "vo_delayed");
        _vsyncJitter = Num(st, "vsync_jitter");
        _gapMs = Num(st, "frame_gap_ms");
        _jitterMs = Num(st, "frame_jitter_ms");
        _renderSum = Num(st, "render_ms_sum");
        _renderSlow = Num(st, "render_slow16");
        _renderCalls = Num(st, "render_calls");
        _advanceCalls = Num(st, "advance_calls");
        _frames.SetSpans(st);
        _bar.CachedSpans = _frames.Spans;
        SyncMute();
        // 拖动中不要覆盖时间读数 —— 那会儿它显示的是**手指所在位置**,
        // 被轮询盖回当前播放位置的话,拖的时候数字纹丝不动
        if (!_bubble.IsVisible) _time.Text = dur > 0 ? Clock(pos) : "加载中…";
        _total.Text = dur > 0 ? Clock(dur) : "";
        _pause.Content = paused ? Ico.Play : Ico.Pause;
    }

    private async Task LoadTracks()
    {
        JsonElement tr;
        try { tr = await _core.PlayerTracks(new { }); }
        catch { return; }   // 轨道拉不到就不画那两个下拉,放片本身不受影响
        if (tr.ValueKind != JsonValueKind.Array) return;

        var audio = new List<TrackOption>();
        var subs = new List<TrackOption> { new("no", "关闭字幕") };
        foreach (var t in tr.EnumerateArray())
        {
            var opt = new TrackOption(Str(t, "id"), TrackLabel(t));
            switch (Str(t, "kind"))
            {
                case "audio": audio.Add(opt); break;
                case "sub": subs.Add(opt); break;
            }
        }

        /* 详情页选好的那两条<b>先落实</b>,再去读「现在选中的是哪条」——
           顺序反了的话下拉框会先停在 mpv 默认那条,一瞬后才跳到用户选的那条,
           而用户看到的是「我选的没生效,过一会儿才对」。 */
        var wantAudio = MatchByFFIndex(tr, "audio", _wantAudioIndex);
        var wantSub = _wantSubIndex == -2 ? "no" : MatchByFFIndex(tr, "sub", _wantSubIndex);
        if (wantAudio != "") await Apply("audio", wantAudio);
        if (wantSub != "") await Apply("sub", wantSub);

        var curAudio = wantAudio != "" ? wantAudio : Selected(tr, "audio");
        var curSub = wantSub != "" ? wantSub : Selected(tr, "sub");
        Dispatcher.UIThread.Post(() =>
        {
            _audio.ItemsSource = audio;
            _subs.ItemsSource = subs;
            // 选中**当前在放的**那条,不是第一条 —— 显示和实际不一致比没有更糟
            _audio.SelectedItem = audio.FirstOrDefault(a => a.Id == curAudio) ?? audio.FirstOrDefault();
            _subs.SelectedItem = subs.FirstOrDefault(x => x.Id == curSub) ?? subs[0];
            /* 一条音轨都没有时(纯画面的片子真的存在)下拉框是**空白**的,
               看着像没加载出来。禁用 + 写明「无音轨」才说得清是「没有」而不是「没拉到」。
               字幕不用这一手 —— 它永远至少有一项「关闭字幕」。 */
            _audio.IsEnabled = audio.Count > 0;
            _audio.PlaceholderText = "无音轨";
        });
    }

    /// <summary>
    /// 按 <b>容器流序号</b> 在 mpv 的轨道表里找那一条,返回它的 mpv track id。
    ///
    /// <para>详情页给的是 Emby 的 <c>MediaStream.Index</c>,而 mpv 的 <c>id</c>
    /// 是**按类型各自从 1 重编**的 —— 两套编号。唯一能对上的是 <c>ff-index</c>,
    /// 那是核心层 2026-09-04 新透出来的字段。对不上就返回空串,
    /// 意思是「按核心层的选轨正则来」,而不是硬塞一条错的。</para>
    /// </summary>
    private static string MatchByFFIndex(JsonElement tracks, string kind, int index)
    {
        if (index < 0 || tracks.ValueKind != JsonValueKind.Array) return "";
        foreach (var t in tracks.EnumerateArray())
        {
            if (Str(t, "kind") != kind) continue;
            if (t.TryGetProperty("ff_index", out var f) && f.ValueKind == JsonValueKind.Number
                && f.GetInt64() == index)
                return Str(t, "id");
        }
        return "";
    }

    /// <summary>切一条轨。 失败不弹红字 —— 起播那一刻切轨失败,片子照样能看。</summary>
    private async Task Apply(string kind, string id)
    {
        try { await _core.PlayerSetTrack(new { kind, id }); }
        catch { /* 选轨失败就用默认那条,别拦住看片 */ }
    }

    private static string Selected(JsonElement tracks, string kind) =>
        tracks.EnumerateArray()
            .Where(t => Str(t, "kind") == kind &&
                        t.TryGetProperty("selected", out var v) && v.ValueKind == JsonValueKind.True)
            .Select(t => Str(t, "id")).FirstOrDefault() ?? "";

    private static string TrackLabel(JsonElement t)
    {
        var bits = new List<string>();
        // 核心层的 Track 只有 id/kind/title/lang/default/selected/external —— 没有 codec
        foreach (var k in new[] { "lang", "title" })
            if (Str(t, k) != "") bits.Add(Str(t, k));
        if (t.TryGetProperty("external", out var ex) && ex.ValueKind == JsonValueKind.True) bits.Add("外挂");
        return bits.Count > 0 ? string.Join(" · ", bits) : $"轨道 {Str(t, "id")}";
    }

    private async Task SeekTo(double secs)
    {
        // duration 还是 0 的时候量程会塌成 1 秒:点中间 = 跳到 0.5 秒,
        // 看起来「画面根本没动」。所以没拿到时长之前不许 seek。
        if (_duration <= 0) return;
        _seekTarget = secs;
        // 参数名是 pos,不是 position —— 写错了核心层报「缺少 pos」,进度条纹丝不动
        try { await _core.PlayerSeek(new { pos = secs }); }
        catch (Exception e) { _msg.Text = $"跳转失败:{LibraryPage.Advice(e)}"; }
    }

    /// <summary>
    /// 离页 / 退出时停播。会话和位置都必须带上。
    ///
    /// <para>原来发的是 <c>new { }</c>,核心层拿不到会话就只调一句 mpv <c>stop</c>:
    /// 不发 ReportStopped(服务器进度停在最后一次定时上报)、不 force 落本地记录、
    /// 不按阈值标已观看 —— 全是静默的。这是「看一半退出续播不落地」的第三次现形,
    /// 这次是壳这边把参数丢了。源播放没有 Emby 会话,只停不报。</para>
    /// </summary>
    private void Stop()
    {
        _poll.Stop();
        try
        {
            object arg = new { };
            if (!NoEmby && Nav.Session is { } s)
                arg = new { s.server, s.token, s.user_id, s.device_id, pos = _position };
            _ = _core.PlayerStopPlayback(arg);
        }
        catch { /* 退出路径不该因为停播失败卡住 */ }
    }

    private static string Clock(double s) =>
        s >= 3600 ? $"{(int)s / 3600}:{(int)s / 60 % 60:00}:{(int)s % 60:00}"
                  : $"{(int)s / 60}:{(int)s % 60:00}";

    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";

    private sealed record TrackOption(string Id, string Label)
    {
        public override string ToString() => Label;
    }

    private sealed record ChapterOption(double At, string Label)
    {
        public override string ToString() => Label;
    }
}
