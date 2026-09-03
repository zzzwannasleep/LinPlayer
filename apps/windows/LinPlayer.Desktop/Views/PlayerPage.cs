using System;
using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.OpenGL;
using Avalonia.OpenGL.Controls;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 视频画面(SPEC §7.2 通道 B):<b>UI 持有 GL 上下文,核心层往 UI 的 FBO 里渲染</b>。
///
/// <para>★★ 起播必须排在 <c>lp_gl_init</c> <b>之后</b>。反过来 vo=libmpv 会以
/// 「No render context set.」致命失败,而且**不重试** —— 表现是全程黑屏、
/// wants_redraw 恒 0,没有任何回调会告诉你出了事(S1.2 §5.2 实测)。</para>
/// </summary>
internal sealed class MpvGlView : OpenGlControlBase
{
    private delegate IntPtr GetProcAddressFn(IntPtr ctx, IntPtr name);

    // ★ 委托要自己拿住:GC 掉之后 mpv 回调进来就是野指针(崩在 mpv 线程里,栈毫无线索)
    private GetProcAddressFn? _gpaKeepAlive;
    private bool _ready;

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

            // 三步,顺序不许换。flip_y=1:GL 原点在左下,让核心层翻,宿主别再翻。
            if (Native.lp_gl_wants_redraw() != 0)
            {
                Native.lp_gl_render((uint)fb, w, h, 1);
                // ★ 漏了 swapped 帧率控制就是瞎的(核心层不知道这一帧已经出去了)
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
    /// <summary>进度条。★ 自绘,不是 Slider —— 理由见 <see cref="PlayerBar"/> 的注释。</summary>
    private readonly PlayerBar _bar = new();
    /// <summary>悬停/拖动时浮在进度条上方的时间气泡。</summary>
    private readonly Border _bubble;
    private readonly TextBlock _bubbleText = new()
    {
        Foreground = Brushes.White, FontSize = 12.5,
    };
    private readonly Slider _vol;
    /// <summary>音量滑块的外壳。★ 悬停才展开 —— 常驻的话它白占一条控制栏。</summary>
    private readonly Border _volBox;
    /// <summary>当前播放位置(秒)。原来是从 <c>_bar.Value</c> 读的,自绘之后要自己记。</summary>
    private double _position;
    private readonly TextBlock _time = new() { Foreground = Brushes.White, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center };
    /// <summary>总时长,画在进度条右端。★ 和已播时间**分列进度条两侧** ——
    /// 挤在一起写成 <c>12:30 / 1:45:00</c> 时,眼睛得先找到那个斜杠才知道读到哪儿了。</summary>
    private readonly TextBlock _total = new() { Foreground = Brushes.White, FontSize = 12.5, Opacity = 0.75, VerticalAlignment = VerticalAlignment.Center };
    /// <summary>音轨 / 字幕 / 画质那一盘。★ 平铺在控制条上的话底下一整行都是下拉框,
    /// 那是设置面板不是 OSD;而且它们**看片时基本不动**,不该长期占着画面。</summary>
    private readonly Border _settings;
    /// <summary>静音按钮。图标跟着 <c>_muted</c> 走,见 <see cref="SyncMute"/>。</summary>
    private readonly Button _mute;
    private readonly TextBlock _msg = new() { Foreground = Brushes.White, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _pause;
    private readonly Border _top, _bottom;
    /* ★ 三个下拉**同宽**。抽屉里竖排三行,宽度不一样右边缘就是锯齿状 ——
       这种参差在一块半透明面板上特别扎眼,而它只是三个数没对齐。 */
    private readonly ComboBox _audio = new() { Width = 210, MinHeight = 32 };
    private readonly ComboBox _subs = new() { Width = 210, MinHeight = 32 };
    private readonly ComboBox _quality = new() { Width = 210, MinHeight = 32 };
    /// <summary>画面比例。核心层 <c>player.setAspectRatio</c> 早就在,UI 一直没接。</summary>
    private readonly ComboBox _aspect = new() { Width = 210, MinHeight = 32 };
    /// <summary>章节。选一个就跳过去。★ 没有章节的片子整行不画,不摆一个空下拉。</summary>
    /// <summary>章节。★ 给占位文字 —— 没选中时空白一片会被当成「没加载出来」。</summary>
    private readonly ComboBox _chapters = new()
    {
        Width = 210, MinHeight = 32, PlaceholderText = "跳到章节…",
    };
    /// <summary>字幕 / 音频延迟(秒)。字幕对不上口型时唯一能自救的东西。</summary>
    private readonly Slider _subDelay = new() { Minimum = -10, Maximum = 10, Value = 0, Width = 150 };
    private readonly Slider _audDelay = new() { Minimum = -10, Maximum = 10, Value = 0, Width = 150 };
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

    private double _duration;
    /// <summary>鼠标是不是停在控制条上。停着就不收 OSD(见构造函数里那段)。</summary>
    private bool _osdHover;
    private bool _full;
    private bool _tracksLoaded;
    private bool _leaving;
    private bool _muted;
    private DateTime _lastMove = DateTime.UtcNow;

    /// <summary>
    /// seek 闩:发出 seek 之后,状态回报还会有一小段时间给旧位置。
    ///
    /// <para>★★ 闩必须和**目标**比,不能和「上一次读到的位置」比 ——
    /// 拿粘性值和目标比,一比就相等,闩当场自解除,进度条继续跳回旧位置。
    /// 本地文件永远看不出来(seek 立刻生效),只有真服务器上才现形。</para>
    /// </summary>
    private double _seekTarget = -1;

    /// <summary>这一条是不是文件浏览型源的条目(走 source.play)。</summary>
    private readonly bool _isSource;

    /// <summary>
    /// 源条目的原始数据,原样回传给核心层。
    ///
    /// <para>★★ 资源站(影视目录)的**可播地址就藏在 raw 里** —— 不带它的话
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
    /// <para>★ 两条起播路的差别只在这一句上,别的(OSD、快捷键、进度、轨道)全共用 ——
    /// 另开一个「源播放页」等于把这些再实现一遍,还得再维护一遍。</para>
    /// </summary>
    /// <param name="mediaSourceId">
    /// 指定播哪一个版本(MediaSource)。空 = 交给核心层按版本正则挑。
    /// <para>★ 详情页选了版本却不把它送下来的话,界面说在放 4K、实际在放 1080p ——
    /// 而且两边都不报错。这正是本仓「界面在撒谎:当前版本」那条教训的另一半。</para>
    /// </param>
    /// <param name="next">
    /// 下一集。给了就画「下一集」键。
    /// <para>★ 让<b>调用方</b>算下一集,不是播放页自己去拉一遍分集表 ——
    /// 详情页手里本来就有那张表,而且「接着看哪一集」的顺序它已经算过一次了
    /// (<c>NextEpisode</c>)。播放页再算一份迟早和它指到不同的集上。</para>
    /// </param>
    public PlayerPage(CoreClient core, string itemId, string title, double resumeSecs,
        bool isSource = false, object? sourceRaw = null, string mediaSourceId = "",
        CardItem? next = null)
    {
        _mediaSourceId = mediaSourceId;
        _core = core;
        _isSource = isSource;
        _sourceRaw = sourceRaw;
        _title = title;
        _itemId = itemId;
        _next = next;

        /* ★★ 进度条是<b>自绘</b>的(<see cref="PlayerBar"/>),不是 Slider。
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
            // ★ 气泡跟着指针走,但**不许跑出两端** —— 跑出去的话它会被 Panel 裁掉一半,
            //   而片头片尾正是最常拖的两个位置。
            var half = 34.0;
            var x = Math.Clamp(_bar.HoverX - half, 0, Math.Max(0, _bar.Bounds.Width - half * 2));
            _bubble.Margin = new Thickness(x, 0, 0, 0);
        };
        _bubble = new Border
        {
            IsVisible = false,
            Background = new SolidColorBrush(Color.Parse("#e6000000")),
            CornerRadius = new CornerRadius(6),
            Padding = new Thickness(8, 3),
            HorizontalAlignment = HorizontalAlignment.Left,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 0, 0),
            IsHitTestVisible = false,
            Child = _bubbleText,
        };
        _vol = new Slider { Minimum = 0, Maximum = 100, Value = 100, Width = 0, Opacity = 0 };
        /* ★★ 音量条<b>悬停才展开</b>(现代播放器的通行做法)。
           常驻 110px 的话它在控制栏左半边一直占着位置,而音量是个一次调好、
           之后几乎不动的东西。展开靠 Width + Opacity 两条过渡一起走 ——
           只动 Width 的话它会「从一条竖线长出来」,像被压扁了。 */
        foreach (var pr in new[] { Slider.WidthProperty, Slider.OpacityProperty })
            (_vol.Transitions ??= []).Add(new Avalonia.Animation.DoubleTransition
            {
                Property = pr, Duration = TimeSpan.FromMilliseconds(160),
                Easing = new Avalonia.Animation.Easings.CubicEaseOut(),
            });

        /* ★★ OSD 的图标全部换成 <b>Segoe MDL2 Assets</b>(样式 Button.osd 里设的字体)。
           原来混着用 Unicode 杂符号(⏸ ⟲ ⟳ 🕪 ⚙ ⛶):
             · 🕪 在 Windows 上走 Segoe UI Emoji,渲染成**彩色**图标,和旁边一排线条符号
               完全不是一套东西;
             · ⟲ / ⟳ 这些数学箭头字重比周围细一大截,看着像掉了一档。
           MDL2 是系统自带的图标字体,一整排同源同粗细。
           ★ 字形存不存在有自检兜着(LP_SELFCHECK_GLYPH),不然缺字形是一个个豆腐块,
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

        /* ★ 静音图标得**跟着状态变** —— 图标不变的话按下去除了没声音之外
           没有任何反馈,用户会以为按钮坏了。 */
        _mute = Glyph(Ico.Volume, "静音(M)");
        _mute.Click += (_, _) =>
        {
            _muted = !_muted;
            SyncMute();
            _ = Send("player.setMute", new { mute = _muted });
        };

        /* 倍速。★★ 按钮上**直接写数字**,不放一个图标:
           「现在是几倍速」是个有具体值的状态,图标表达不了它,
           而 1.5 倍速忘了调回来是很常见的事(声音听着不对但说不出哪里不对)。
           ★ 点一下轮转一档,右键回 1.0 —— 常用动作一次点击,不必开抽屉。 */
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

        // 截图。★ 核心层 player.screenshot 一直在,UI 从来没接 —— 又一条零调用命令。
        var shot = Glyph(Ico.Camera, "截图(S)");
        shot.Click += (_, _) => _ = Screenshot();

        // 下一集。★ 没有下一集就**整个不画**,不摆一个灰着的按钮
        var nextBtn = Glyph(Ico.Next, "下一集(N)");
        nextBtn.Click += (_, _) => GoNext();

        /* 音轨 / 字幕 / 画质 / 延迟 / 比例 / 章节 收进一个抽屉。
           ★★ 它们平铺在控制条上时,底下一整行都是下拉框和标签 —— 那是**设置面板**,
             不是 OSD。看片时这几样基本不动,不该长期压着画面。
           ★ 抽屉贴右下角弹,不是居中弹窗:它是就地调整,不是一次决策,
             居中弹窗会把整块画面遮掉。 */
        _subDelay.PropertyChanged += (_, e) =>
        {
            if (e.Property != Slider.ValueProperty) return;
            _subDelayText.Text = $"{_subDelay.Value:0.0}s";
            _ = Send("player.setSubDelay", new { secs = _subDelay.Value });
        };
        _audDelay.PropertyChanged += (_, e) =>
        {
            if (e.Property != Slider.ValueProperty) return;
            _audDelayText.Text = $"{_audDelay.Value:0.0}s";
            _ = Send("player.setAudioDelay", new { secs = _audDelay.Value });
        };
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
            BorderBrush = new SolidColorBrush(Color.Parse("#323b4a")),
            BorderThickness = new Thickness(1),
            CornerRadius = new CornerRadius(12),
            Padding = new Thickness(16),
            Margin = new Thickness(0, 0, 20, 116),
            IsVisible = false,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = new StackPanel
            {
                Spacing = 10,
                Children =
                {
                    Row("音轨", _audio), Row("字幕", _subs), Row("画质", _quality),
                    Row("比例", _aspect), chapterRow,
                    Row("字幕延迟", Pair(_subDelay, _subDelayText)),
                    Row("音频延迟", Pair(_audDelay, _audDelayText)),
                },
            },
        };
        var gear = Glyph(Ico.Setting, "音轨 / 字幕 / 画质 / 延迟(U)");
        gear.Click += (_, _) => _settings.IsVisible = !_settings.IsVisible;

        /* 跳过片头 / 片尾。
           ★★ 这是<b>核心层早就算好、UI 从来没用过</b>的东西:player.chapterInfo
             一次请求同时给章节表和 intro/outro 区间,而且开关关着时它自己返回 null ——
             调用方不必再判一次开关。
           ★ 按钮浮在右下角、只在区间里出现:常驻的话它在全片 95% 的时间里都是错的。 */
        _skip = new Button
        {
            Classes = { "primary" }, Content = "跳过片头", IsVisible = false,
            HorizontalAlignment = HorizontalAlignment.Right,
            VerticalAlignment = VerticalAlignment.Bottom,
            Margin = new Thickness(0, 0, 24, 132),
        };
        _skip.Click += (_, _) =>
        {
            if (_skipTo > 0) _ = SeekTo(_skipTo);
            _skip.IsVisible = false;
        };

        /* ★★ 版式换成<b>「整条进度条独占一行 + 底下一排按钮」</b>。
           原来是「已播时间 | 进度条 | 总时长」挤在一行里 ——
           那让进度条两端各缩进 60 多像素,而<b>片头和片尾恰好在那两端</b>,
           想拖到最开头就得先瞄准那个缩进后的起点。
           现代播放器(YouTube / Netflix / Bilibili / Plex)一律是整宽独占一行,
           时间读数挪到按钮那一排的左边。 */
        var barRow = new Panel
        {
            Height = PlayerBar.HitHeight + 26,
            Children = { _bubble, _bar },
        };
        _bar.VerticalAlignment = VerticalAlignment.Bottom;
        _bubble.Margin = new Thickness(0, 0, 0, PlayerBar.HitHeight + 2);

        _time.Margin = new Thickness(6, 0, 0, 0);
        _total.Margin = new Thickness(0, 0, 0, 0);
        var clock = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 4,
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
                Orientation = Orientation.Horizontal, Spacing = 4,
                VerticalAlignment = VerticalAlignment.Center,
                Children = { _mute, _vol },
            },
        };
        _volBox.PointerEntered += (_, _) => { _vol.Width = 92; _vol.Opacity = 1; };
        _volBox.PointerExited += (_, _) => { _vol.Width = 0; _vol.Opacity = 0; };

        var left = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 4,
            VerticalAlignment = VerticalAlignment.Center,
            Children = { _pause, back10, fwd10 },
        };
        if (_next is not null) left.Children.Add(nextBtn);
        left.Children.Add(_volBox);
        left.Children.Add(clock);
        var right = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 4,
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

        /* ★★ 上下两条都用**渐变蒙版**,不是一块实心黑条。
           实心条是一条硬边压在画面上,边缘那一行像素会突兀地断掉;
           渐变从画面里长出来,而字仍然压得住 —— 这是所有播放器都这么做的原因。 */
        _bottom = new Border
        {
            Background = Scrim(false),
            // ★ 左右 16:整条进度条要贴得住两端,内缩太多的话片头片尾又不好瞄了
            Padding = new Thickness(16, 40, 16, 10),
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = new StackPanel { Spacing = 0, Children = { progress, controls } },
        };

        _top = new Border
        {
            Background = Scrim(true),
            Padding = new Thickness(16, 12, 16, 30),
            VerticalAlignment = VerticalAlignment.Top,
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 12,
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

        Content = new Panel
        {
            Background = Brushes.Black,
            Children = { _view, _top, _bottom, _skip, _settings },
        };

        // ★ 键盘要能收到,控件得先能拿焦点 —— 不设 Focusable 按空格毫无反应,
        //   而用户只会觉得「这播放器连暂停都没有」。
        Focusable = true;
        AttachedToVisualTree += (_, _) => Focus();
        KeyDown += OnKey;
        PointerMoved += (_, _) => { _lastMove = DateTime.UtcNow; ShowOsd(true); };

        /* ★★ <b>鼠标停在控制条上就不收 OSD</b>。
           不判这一下的话:用户把鼠标移到音量条上停三秒调音量,整条 OSD 当场消失 ——
           而他的手还按在滑块上。所有现代播放器都有这一条。 */
        foreach (var b in new[] { _top, _bottom })
        {
            b.PointerEntered += (_, _) => _osdHover = true;
            b.PointerExited += (_, _) => _osdHover = false;
        }

        /* 滚轮调音量 —— 事实标准(YouTube / Bilibili / mpv / VLC 都是)。
           ★ 一格 5:一格 1 要滚二十下才从静音到满,一格 10 又太粗。 */
        PointerWheelChanged += (_, e) =>
        {
            SetVolume(_vol.Value + (e.Delta.Y > 0 ? 5 : -5));
            _lastMove = DateTime.UtcNow;
            ShowOsd(true);
            e.Handled = true;
        };
        /* 点画面 = 播放/暂停,双击 = 全屏。也是事实标准。
           ★ 挂在 <see cref="MpvGlView"/> 上而不是整页 —— 挂整页的话点控制条上的
             空白处也会暂停,而那儿用户的意图是「什么都不做」。 */
        _view.PointerPressed += (_, e) =>
        {
            if (e.GetCurrentPoint(_view).Properties.IsLeftButtonPressed && e.ClickCount == 1)
                _ = TogglePause();
        };
        _view.DoubleTapped += (_, _) => ToggleFullscreen();

        // ★ 起播排在 GL 就绪之后。发出去就行,不等结果 —— 等结果会把渲染线程堵住。
        _view.OnReady = () => Dispatcher.UIThread.Post(() => _ = Start(itemId, resumeSecs));

        _poll.Tick += (_, _) => _ = Poll();
        _poll.Start();
        DetachedFromVisualTree += (_, _) => Stop();

        // ★ 判「非空」而不是 == "1":LP_DRILL=2(拉开抽屉)也得先把 Drill 跑起来,
        //   只认 "1" 的话 =2 那次连 OSD 都不会钉住,截出来是一张干净画面 ——
        //   而它看着**很像**「抽屉没画出来」。这个坑当场踩了一次。
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("LP_SELFCHECK_PLAYER_DRILL")))
            _ = Drill();
        /* ★ 自检台驱动画质档位。选的是**真的下拉项**,走 SelectionChanged 那条真路 ——
           绕开 UI 直接调命令的自检只能证明核心层活着,证明不了这个面板接对了。 */
        var lvl = Environment.GetEnvironmentVariable("LP_SELFCHECK_SHADER");
        if (!string.IsNullOrEmpty(lvl)) _ = SelfCheckPickQuality(lvl);
        // 自检:LP_SELFCHECK_PLAYER_DRILL=3 把跳过条钉出来 —— 它平时只在片头那几十秒里出现,
        // 截图永远抓不到,而它是这一版新加的东西里最容易画错位置的一个。
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PLAYER_DRILL") == "3")
            _ = Task.Delay(7000).ContinueWith(_ => Dispatcher.UIThread.Post(() =>
            {
                /* ★★ 灌的是**区间**,不是直接把按钮设可见 ——
                   直接设可见的话下一次 Poll 里的 SyncSkip 会因为「不在任何区间里」
                   立刻把它收回去,自检拍到的永远是没有按钮的那一帧。
                   而且灌区间走的是真实那条路(SyncSkip 判定 → 显示 → 点了跳到 End),
                   直接设可见只证明「这个控件存在」。
                   ★ 核心层默认**关着**跳过片头(prefs.skip_intro=false,它会回 null),
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

    /// <summary>倍速档位。★ 0.5 以下没人用,2 以上听不清 —— 档位少一点选起来才快。</summary>
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
        // ★ 1 倍速写成「1×」不是「1.00×」—— 一排数字里多两位小数会显得没对齐
        _speed.Content = Math.Abs(v - 1.0) < 0.01 ? "1×" : $"{v:0.##}×";
        _speed.Classes.Set("on", Math.Abs(v - 1.0) > 0.01);
        await Send("player.setSpeed", new { speed = v });
    }

    /// <summary>
    /// 截图。★ <b>不传目录</b> —— 核心层会用设置页里选的那个,传了反而把设置项架空。
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
        // ★ 换成**替换**不是压栈:一路看下去会攒出一栈播放页,
        //   返回键要按十几下才回得到详情页。
        Nav.Replace(new PlayerPage(_core, _next.Id, _next.DisplayTitle, _next.ResumeSecs));
    }

    /// <summary>
    /// 拉章节 + 片头片尾区间。
    ///
    /// <para>★★ 一次请求喂两个功能(核心层就是这么设计的)。开关关着时它自己回 null,
    /// <b>调用方不必再判一次开关</b> —— 判两次早晚判岔,那就是「关了还在跳」。</para>
    /// <para>★ 拉不到不报错:没刮章节的库返回空表,两个功能静默不工作,那是正常情况。</para>
    /// </summary>
    private async Task LoadChapters()
    {
        if (_isSource || _itemId == "") return;
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
                // ★ 进度条上切缺口。现代播放器都有这一下 ——
                //   它把「这片子有几段」直接画在了用户要拖的那条线上。
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
    /// <para>★ 同一个区间只弹一次:用户按了「不跳」(等它自己过去)之后又弹回来,
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
    /// <para>★ 自检片有<b>烧录时间码</b> —— 截图上的时间码就是 seek 到底有没有真的
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
        /* ★ LP_DRILL=2 顺带把音轨/字幕/画质那个抽屉拉开。
           收起来的东西**截图里等于不存在** —— 抽屉里三行控件排没排齐、
           弹出位置有没有盖住控制条,不拉开一次就永远没人看过。 */
        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PLAYER_DRILL") == "2")
            Dispatcher.UIThread.Post(() => _settings.IsVisible = true);
    }

    private static TextBlock Label(string t) => new()
    {
        Text = t, Foreground = Brushes.White, FontSize = 12,
        VerticalAlignment = VerticalAlignment.Center,
    };

    /// <summary>
    /// OSD 用到的 MDL2 字形。
    ///
    /// <para>★★ 集中一处写,是为了<b>能被自检逐个查一遍</b>(LP_SELFCHECK_GLYPH):
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

    /// <summary>静音图标跟状态走。★ 轮询里也调一次 —— 键盘 M 和按钮是两条路。</summary>
    private void SyncMute()
    {
        _mute.Content = _muted ? Ico.Mute : Ico.Volume;
        _mute.Classes.Set("on", _muted);
    }

    /// <summary>滑块 + 读数。★ 光有滑块的话用户不知道自己调到了多少。</summary>
    private static Control Pair(Control slider, Control readout) => new StackPanel
    {
        Orientation = Orientation.Horizontal, Spacing = 8,
        Children = { slider, readout },
    };

    /// <summary>抽屉里的一行:标签 + 控件。标签宽度对齐,三行才排得整齐。</summary>
    private static StackPanel Row(string label, Control input) => new()
    {
        Orientation = Orientation.Horizontal, Spacing = 10,
        Children =
        {
            new TextBlock
            {
                // ★ 64 不是 40:最长的标签是「字幕延迟」四个字,40 只放得下两个 ——
                //   截断之后成了「字幕延」,看着像写错字(实测截图上抓到)
                Text = label, Width = 64, Foreground = Brushes.White, FontSize = 12.5,
                VerticalAlignment = VerticalAlignment.Center,
            },
            input,
        },
    };

    /// <summary>
    /// OSD 上的图标按钮。
    ///
    /// <para>★ 每个都要有 <c>ToolTip</c> 并把快捷键写进去 —— 一排符号按钮
    /// 光看图形猜不出是什么,而快捷键写在别处等于没人知道。</para>
    /// </summary>
    private static Button Glyph(string glyph, string tip)
    {
        var b = new Button
        {
            Classes = { "osd" }, Content = glyph,
            VerticalAlignment = VerticalAlignment.Center,
        };
        ToolTip.SetTip(b, tip);
        return b;
    }

    /// <summary>
    /// OSD 的渐变蒙版。
    ///
    /// <para>★★ 不用实心黑条:实心是一条硬边压在画面上,边缘那一行像素突兀地断掉。
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
            if (_isSource)
            {
                /* ★ 源播放**没有 Emby 会话**:网盘 / 局域网 / 本地源根本没有 server/token。
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
            // J / L = ±10 秒。★ YouTube 起的头,现在是事实标准 ——
            //   手不用离开 J/K/L 三个键就能倒、停、进。
            case Key.J: _ = SeekBy(-10); break;
            case Key.L: _ = SeekBy(10); break;
            // 数字键跳到百分之几。★ 也是事实标准(0=开头,5=一半)。
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
            // U:开抽屉再展开画质。★ 抽屉关着时直接展开下拉框,下拉列表会飘在
            //    一块看不见的面板上 —— 得先把面板拿出来。
            case Key.U:
                _settings.IsVisible = true;
                _quality.IsDropDownOpen = !_quality.IsDropDownOpen;
                break;
            // ★ 新加的功能都要有快捷键:OSD 三秒就收,而键盘永远在
            case Key.S: _ = Screenshot(); break;
            case Key.N: GoNext(); break;
            case Key.OemPeriod: _ = CycleSpeed(+1); break;   // > 加速
            case Key.OemComma: _ = CycleSpeed(-1); break;    // < 减速
            case Key.F or Key.Enter: ToggleFullscreen(); break;
            // ★ 全屏时 Esc 只退全屏,不退出播放 —— 看片时误按一下就把片关了很恼人
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

    private void ToggleFullscreen()
    {
        _full = !_full;
        Nav.Immersive?.Invoke(_full);
        // ★ 图标要跟着换:全屏之后按钮还画着「进入全屏」,用户会以为没生效
        if (_fullBtn is not null)
        {
            _fullBtn.Content = _full ? Ico.Windowed : Ico.Full;
            ToolTip.SetTip(_fullBtn, _full ? "退出全屏(F / Esc)" : "全屏(F)");
        }
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

    /// <summary>OSD 收放。三秒不动就收起来 —— 一直压着画面就不是看片了。</summary>
    private void ShowOsd(bool on)
    {
        if (_top.IsVisible == on) return;
        _top.IsVisible = _bottom.IsVisible = on;
        // ★ 抽屉要跟着收。留着的话 OSD 收了之后画面上孤零零飘着一块面板,
        //   而且它下面那条控制条已经没了,看着像画错了。
        if (!on) _settings.IsVisible = false;
        Cursor = new Cursor(on ? StandardCursorType.Arrow : StandardCursorType.None);
    }

    /// <summary>
    /// 画质档位(<c>UI_PC.md</c> §7 底部第七个面板,快捷键 <c>U</c>)。
    ///
    /// <para>★★ 档位表由<b>核心层</b>给(28 档,分 Anime4K / FSR / NVIDIA / 通用四族),
    /// UI 不自己写一份。写一份的下场是加档位要改两处,而漏改的那处不报错。</para>
    ///
    /// <para>★★ <b>档位故意不持久化</b>(2026-08-31 已定,别顺手加)——
    /// 它跟当前这一片的分辨率和窗口大小绑定,记住上一片的档位只会带来
    /// 「上次好好的这次不生效」。</para>
    /// </summary>
    /// <summary>
    /// 自检:<c>LP_SHADER=all</c> —— <b>把全部档位挨个挂一遍</b>,报出哪些编译不过。
    ///
    /// <para>★★ 存在的理由:着色器方言跟渲染后端走。换了后端(这里是
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

    private async Task LoadQualityLevels()
    {
        try
        {
            var r = await _core.PlayerShaderLevels();
            if (r.ValueKind != JsonValueKind.Array) return;
            var items = new List<ShaderLevel>();
            foreach (var l in r.EnumerateArray())
            {
                var id = Str(l, "id");
                var name = Str(l, "name");
                var group = Str(l, "group");
                items.Add(new ShaderLevel(id, group == "" ? name : group + " · " + name));
            }
            _quality.ItemsSource = items;
            _quality.SelectedIndex = 0; // off
        }
        catch (Exception e) { _msg.Text = $"画质档位读不到:{LibraryPage.Advice(e)}"; }
    }

    private bool _qualityMuted;

    private async Task PickQuality()
    {
        if (_qualityMuted) return;
        if (_quality.SelectedItem is not ShaderLevel lv) return;
        try
        {
            var r = await _core.PlayerSetShaderLevel(new { level = lv.Id });
            /* ★★ 这里必须把核心层的判断**原样透出来**。
               `count > 0` 只能证明 mpv 收下了 shader 路径,**证明不了它会跑** ——
               放大类每个 pass 都带 `//!WHEN 输出>源*1.2`,窗口没比源大就整条链空转,
               画面一点没变。旧版 UI 在这种情况下照样报「超分已生效 · 挂载 6 个 shader」,
               那是在撒谎,是本项目最贵的那类 bug。 */
            if (r.TryGetProperty("will_run", out var wr) && wr.ValueKind == JsonValueKind.False)
            {
                _msg.Text = Str(r, "note");
                /* ★★ 核心层自己退回关闭时,下拉框**必须跟着回到「关闭」**。
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
            _msg.Text = n == 0 ? "画质增强已关闭" : $"已启用:{lv.Name}";
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

    private async Task Poll()
    {
        JsonElement st;
        try { st = await _core.PlayerStatus(new { }); }
        catch { return; }

        var pos = Num(st, "position");
        var dur = Num(st, "duration");
        var paused = st.TryGetProperty("paused", out var p) && p.ValueKind == JsonValueKind.True;
        _muted = st.TryGetProperty("mute", out var mu) && mu.ValueKind == JsonValueKind.True;
        var eof = st.TryGetProperty("eof", out var f) && f.ValueKind == JsonValueKind.True;

        // ★★ keep-open=yes 之下 END_FILE **永远不发**(文件不卸载),
        //    判「播完了」只能读 eof-reached。这是「播完不同步进度」的根因。
        if (eof && !_leaving) { Leave(); return; }

        // 拿到时长才去问轨道表:loadfile 是异步的,早问回来的是空表,
        // 而空表会把两个下拉框永久固定成空的 —— 之后再没人重问。
        // ★ 章节同理:chapterInfo 要拿 runtime_secs 去算片头片尾,时长是 0 的时候算不出来。
        if (!_tracksLoaded && dur > 0)
        {
            _tracksLoaded = true;
            _duration = dur;
            _ = LoadTracks();
            _ = LoadChapters();
        }

        /* ★ 倍速可能被别处改(mpv.conf / 快捷键 / 上一次的粘连),
           以状态里的为准 —— 按钮上写着 1× 而实际在放 1.5× 是「界面在撒谎」。 */
        var sp = Num(st, "speed");
        if (sp > 0 && Math.Abs(sp - _speedValue) > 0.01)
        {
            _speedValue = sp;
            _speed.Content = Math.Abs(sp - 1.0) < 0.01 ? "1×" : $"{sp:0.##}×";
            _speed.Classes.Set("on", Math.Abs(sp - 1.0) > 0.01);
        }
        SyncSkip(pos);

        /* 3 秒不动就收。★ 两个例外,都是现代播放器的通行做法:
           ①<b>暂停时不收</b> —— 暂停就是「我要看清楚这一帧 / 我要操作」;
           ②<b>鼠标停在控制条上不收</b> —— 手还在滑块上,条却没了。 */
        if (DateTime.UtcNow - _lastMove > TimeSpan.FromSeconds(3) && !paused && !_osdHover)
            ShowOsd(false);

        // ★ 闩和**目标**比,不和上一次读到的位置比(见字段上的注释)
        if (_seekTarget >= 0)
        {
            if (Math.Abs(pos - _seekTarget) < 1.5) _seekTarget = -1;
            else return;
        }
        _duration = dur;
        _position = Math.Clamp(pos, 0, dur > 0 ? dur : 1);
        // buffered = 已缓冲到哪一秒(核心层读的是 mpv demuxer-cache-time,本地文件是 0)
        _bar.Sync(_position, dur, Num(st, "buffered"));
        SyncMute();
        // ★ 拖动中不要覆盖时间读数 —— 那会儿它显示的是**手指所在位置**,
        //   被轮询盖回当前播放位置的话,拖的时候数字纹丝不动
        if (!_bubble.IsVisible) _time.Text = dur > 0 ? Clock(pos) : "加载中…";
        _total.Text = dur > 0 ? Clock(dur) : "";
        _pause.Content = paused ? Ico.Play : Ico.Pause;
    }

    private async Task LoadTracks()
    {
        JsonElement tr;
        try { tr = await _core.PlayerTracks(new { }); }
        catch { return; }
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

        var curAudio = Selected(tr, "audio");
        var curSub = Selected(tr, "sub");
        Dispatcher.UIThread.Post(() =>
        {
            _audio.ItemsSource = audio;
            _subs.ItemsSource = subs;
            // 选中**当前在放的**那条,不是第一条 —— 显示和实际不一致比没有更糟
            _audio.SelectedItem = audio.FirstOrDefault(a => a.Id == curAudio) ?? audio.FirstOrDefault();
            _subs.SelectedItem = subs.FirstOrDefault(x => x.Id == curSub) ?? subs[0];
            /* ★ 一条音轨都没有时(纯画面的片子真的存在)下拉框是**空白**的,
               看着像没加载出来。禁用 + 写明「无音轨」才说得清是「没有」而不是「没拉到」。
               字幕不用这一手 —— 它永远至少有一项「关闭字幕」。 */
            _audio.IsEnabled = audio.Count > 0;
            _audio.PlaceholderText = "无音轨";
        });
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
        // ★ duration 还是 0 的时候量程会塌成 1 秒:点中间 = 跳到 0.5 秒,
        //   看起来「画面根本没动」。所以没拿到时长之前不许 seek。
        if (_duration <= 0) return;
        _seekTarget = secs;
        // ★ 参数名是 pos,不是 position —— 写错了核心层报「缺少 pos」,进度条纹丝不动
        try { await _core.PlayerSeek(new { pos = secs }); }
        catch (Exception e) { _msg.Text = $"跳转失败:{LibraryPage.Advice(e)}"; }
    }

    private void Stop()
    {
        _poll.Stop();
        try { _ = _core.PlayerStopPlayback(new { }); } catch { /* 退出路径不该因为停播失败卡住 */ }
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
