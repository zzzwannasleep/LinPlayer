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
    private readonly MpvGlView _view = new();
    private readonly Slider _bar;
    private readonly Slider _vol;
    private readonly TextBlock _time = new() { Foreground = Brushes.White, FontSize = 12.5, VerticalAlignment = VerticalAlignment.Center };
    private readonly TextBlock _msg = new() { Foreground = Brushes.White, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
    private readonly Button _pause;
    private readonly Border _top, _bottom;
    private readonly ComboBox _audio = new() { Width = 170, MinHeight = 30 };
    private readonly ComboBox _subs = new() { Width = 170, MinHeight = 30 };
    private readonly DispatcherTimer _poll = new() { Interval = TimeSpan.FromMilliseconds(250) };

    private double _duration;
    private bool _dragging;
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

    public PlayerPage(CoreClient core, string itemId, string title, double resumeSecs)
    {
        _core = core;

        _bar = new Slider { Minimum = 0, Maximum = 1, Value = 0, IsEnabled = false };
        _vol = new Slider { Minimum = 0, Maximum = 100, Value = 100, Width = 110 };
        _pause = new Button { Classes = { "ghost" }, Content = "⏸" };

        var back = new Button { Classes = { "ghost" }, Content = "← 返回" };
        back.Click += (_, _) => Leave();

        var full = new Button { Classes = { "ghost" }, Content = "⛶" };
        full.Click += (_, _) => ToggleFullscreen();

        _pause.Click += (_, _) => _ = TogglePause();
        _vol.PropertyChanged += (_, e) =>
        {
            if (e.Property == Slider.ValueProperty) _ = Send("player.setVolume", new { volume = _vol.Value });
        };

        _audio.SelectionChanged += (_, _) => _ = PickTrack("audio", _audio);
        _subs.SelectionChanged += (_, _) => _ = PickTrack("sub", _subs);

        // ★ 拖拽的抬手事件挂在**外层**,不是 Slider 自己身上 ——
        //   挂在自己身上的话拖出控件再松手收不到,进度条会永久钉住(Rust 版栽过)。
        _bar.AddHandler(PointerPressedEvent, (_, _) => _dragging = true, RoutingStrategies.Tunnel);
        AddHandler(PointerReleasedEvent, async (_, _) =>
        {
            if (!_dragging) return;
            _dragging = false;
            await SeekTo(_bar.Value);
        }, RoutingStrategies.Tunnel);

        _bottom = new Border
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
                        Orientation = Orientation.Horizontal, Spacing = 10,
                        Children =
                        {
                            _pause, _time,
                            Label("音量"), _vol,
                            Label("音轨"), _audio,
                            Label("字幕"), _subs,
                            full,
                        },
                    },
                },
            },
        };

        _top = new Border
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
            Children = { _view, _top, _bottom },
        };

        // ★ 键盘要能收到,控件得先能拿焦点 —— 不设 Focusable 按空格毫无反应,
        //   而用户只会觉得「这播放器连暂停都没有」。
        Focusable = true;
        AttachedToVisualTree += (_, _) => Focus();
        KeyDown += OnKey;
        PointerMoved += (_, _) => { _lastMove = DateTime.UtcNow; ShowOsd(true); };

        // ★ 起播排在 GL 就绪之后。发出去就行,不等结果 —— 等结果会把渲染线程堵住。
        _view.OnReady = () => Dispatcher.UIThread.Post(() => _ = Start(itemId, resumeSecs));

        _poll.Tick += (_, _) => _ = Poll();
        _poll.Start();
        DetachedFromVisualTree += (_, _) => Stop();

        if (Environment.GetEnvironmentVariable("LP_SELFCHECK_PLAYER_DRILL") == "1") _ = Drill();
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
    }

    private static TextBlock Label(string t) => new()
    {
        Text = t, Foreground = Brushes.White, FontSize = 12,
        VerticalAlignment = VerticalAlignment.Center,
    };

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
            case Key.Up: SetVolume(_vol.Value + 5); break;
            case Key.Down: SetVolume(_vol.Value - 5); break;
            case Key.M: _muted = !_muted; _ = Send("player.setMute", new { mute = _muted }); break;
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
        try { await _core.PlayerSetPause(new { paused = (string?)_pause.Content != "▶" }); }
        catch { /* 状态轮询会纠正显示 */ }
    }

    private async Task SeekBy(double delta)
    {
        if (_duration <= 0) return;
        await SeekTo(Math.Clamp(_bar.Value + delta, 0, _duration));
    }

    // 只改滑块,命令由 PropertyChanged 统一发 —— 两处各发一次就会打架
    private void SetVolume(double v) => _vol.Value = Math.Clamp(v, 0, 100);

    private void ToggleFullscreen()
    {
        _full = !_full;
        Nav.Immersive?.Invoke(_full);
    }

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
        Cursor = new Cursor(on ? StandardCursorType.Arrow : StandardCursorType.None);
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
        if (!_tracksLoaded && dur > 0) { _tracksLoaded = true; _ = LoadTracks(); }

        if (DateTime.UtcNow - _lastMove > TimeSpan.FromSeconds(3) && !paused) ShowOsd(false);

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
}
