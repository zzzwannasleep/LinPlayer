using System.Runtime.InteropServices;
using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
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

/// <summary>播放页。画面铺满,控制条压在底部。</summary>
public sealed class PlayerPage : UserControl
{
    private readonly CoreClient _core;
    private readonly MpvGlView _view = new();
    private readonly Slider _bar;
    private readonly TextBlock _time = new() { Foreground = Brushes.White, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _msg = new() { Foreground = Brushes.White, FontSize = 13 };
    private readonly Button _pause;
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromMilliseconds(250) };

    private double _duration;
    private bool _dragging;

    /// <summary>
    /// seek 闩:发出 seek 之后,状态回报还会有一小段时间给旧位置。
    ///
    /// <para>★★ 闩必须和**目标**比,不能和「上一次读到的位置」比 ——
    /// 拿粘性值和目标比,一比就相等,闩当场自解除,进度条继续跳回旧位置。
    /// 本地文件永远看不出来(seek 立刻生效),只有真服务器上才现形。</para>
    /// </summary>
    private double _seekTarget = -1;

    public PlayerPage(CoreClient core, string itemId, string title, double resumeSecs)
    {
        _core = core;

        _bar = new Slider { Minimum = 0, Maximum = 1, Value = 0, IsEnabled = false };
        _pause = new Button { Classes = { "ghost" }, Content = "⏸" };

        var back = new Button { Classes = { "ghost" }, Content = "← 返回" };
        back.Click += (_, _) => { Stop(); Nav.Back(); };

        _pause.Click += async (_, _) =>
        {
            try
            {
                var paused = (string?)_pause.Content == "▶";
                await _core.PlayerSetPause(new { paused = !paused });
            }
            catch { /* 状态轮询会纠正显示 */ }
        };

        // ★ 拖拽的抬手事件挂在**外层**,不是 Slider 自己身上 ——
        //   挂在自己身上的话拖出控件再松手收不到,进度条会永久钉住(Rust 版栽过)。
        _bar.AddHandler(PointerPressedEvent, (_, _) => _dragging = true, Avalonia.Interactivity.RoutingStrategies.Tunnel);
        AddHandler(PointerReleasedEvent, async (_, _) =>
        {
            if (!_dragging) return;
            _dragging = false;
            await SeekTo(_bar.Value);
        }, Avalonia.Interactivity.RoutingStrategies.Tunnel);

        var bottom = new Border
        {
            Background = new SolidColorBrush(Color.Parse("#cc000000")),
            Padding = new Thickness(16, 10),
            VerticalAlignment = VerticalAlignment.Bottom,
            Child = new StackPanel
            {
                Spacing = 6,
                Children =
                {
                    _bar,
                    new StackPanel
                    {
                        Orientation = Orientation.Horizontal, Spacing = 12,
                        Children = { _pause, _time },
                    },
                },
            },
        };

        var top = new Border
        {
            Background = new SolidColorBrush(Color.Parse("#99000000")),
            Padding = new Thickness(14, 10),
            VerticalAlignment = VerticalAlignment.Top,
            Child = new StackPanel
            {
                Orientation = Orientation.Horizontal, Spacing = 12,
                Children =
                {
                    back,
                    new TextBlock
                    {
                        Text = title, Foreground = Brushes.White, FontSize = 15,
                        VerticalAlignment = VerticalAlignment.Center,
                    },
                    _msg,
                },
            },
        };

        Content = new Panel
        {
            Background = Brushes.Black,
            Children = { _view, top, bottom },
        };

        // ★ 起播排在 GL 就绪之后。发出去就行,不等结果 —— 等结果会把渲染线程堵住。
        _view.OnReady = () => Dispatcher.UIThread.Post(() => _ = Start(itemId, resumeSecs));

        _poll.Tick += (_, _) => _ = Poll();
        _poll.Start();
        DetachedFromVisualTree += (_, _) => Stop();
    }

    private async Task Start(string itemId, double resumeSecs)
    {
        if (_view.InitError is not null) { _msg.Text = _view.InitError; return; }
        try
        {
            var s = Nav.Session!;
            await _core.PlayerPlay(new
            {
                s.server, s.token, s.user_id, s.device_id,
                item_id = itemId, resume_secs = resumeSecs,
            });
        }
        catch (Exception e) { _msg.Text = $"起播失败:{LibraryPage.Advice(e)}"; }
    }

    private async Task SeekTo(double secs)
    {
        // ★ duration 还是 0 的时候量程会塌成 1 秒:点中间 = 跳到 0.5 秒,
        //   看起来「画面根本没动」。所以没拿到时长之前不许 seek。
        if (_duration <= 0) return;
        _seekTarget = secs;
        try { await _core.PlayerSeek(new { position = secs }); }
        catch (Exception e) { _msg.Text = $"跳转失败:{LibraryPage.Advice(e)}"; }
    }

    private async Task Poll()
    {
        JsonElement st;
        try { st = await _core.PlayerStatus(new { }); }
        catch { return; }

        var pos = Num(st, "position");
        var dur = Num(st, "duration");
        var paused = st.TryGetProperty("paused", out var p) && p.ValueKind == JsonValueKind.True;

        // ★ 闩和**目标**比,不和上一次读到的位置比(见字段上的注释)
        if (_seekTarget >= 0)
        {
            if (Math.Abs(pos - _seekTarget) < 1.5) _seekTarget = -1;
            else return;
        }
        if (_dragging) return;

        _duration = dur;
        _bar.IsEnabled = dur > 0;
        _bar.Maximum = dur > 0 ? dur : 1;
        _bar.Value = Math.Clamp(pos, 0, _bar.Maximum);
        _time.Text = dur > 0 ? $"{Clock(pos)} / {Clock(dur)}" : "加载中…";
        _pause.Content = paused ? "▶" : "⏸";
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
}
