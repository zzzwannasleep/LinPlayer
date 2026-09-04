// SPIKE S1.2 · Avalonia 侧接视频通道 B(SPEC §7.2)
//
// 这个程序回答三个问题,每个都要留下可核对的证据:
//   1. OpenGlControlBase 的 fb 交给核心层,窗口里出不出画面
//   2. 一个半透明 Avalonia 控件叠在视频上,可见不可见、闪不闪
//   3. 漏调 lp_gl_swapped 会不会掉帧(--no-swapped 做反向验证)
//
// 它不是交互程序:起窗口 -> 播 N 秒 -> 截若干张图并算像素指标 -> 打报告 -> 退出。
// 判据全部是数字,不靠"我看了一眼"。

using System;
using System.Collections.Generic;
using System.Diagnostics;
using SD = System.Drawing;
using SDI = System.Drawing.Imaging;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Threading;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.OpenGL;
using Avalonia.OpenGL.Controls;
using Avalonia.Threading;

namespace AvaloniaProbe;

// ----------------------------------------------------------------- 核心层 FFI
//
// ★ 这里只出现 SPEC §5.1 第 3 组的 5 个函数 + SPIKE 专用取数口子。
//   宿主侧**看不到任何 mpv 类型** —— 这正是 S1.2 要验的:那个窄接口够不够用。

internal static partial class Core
{
    private const string Lib = "lpcore";
    public const int HostAbi = 1;   // 宿主编译期的 LP_ABI(SPEC §5.0)

    // ★ 只有 SPEC §5.1 的 13 个。**没有任何 SPIKE 专用口子** ——
    //   UI 层拿不到 mpv,一切经由 lp_call + 事件队列,这就是真实架构。
    [LibraryImport(Lib)] internal static partial int lp_abi_version();
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)] internal static partial int lp_init(string configJson);
    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)] internal static partial int lp_call(long seq, string cmd, string argsJson);
    [LibraryImport(Lib)] internal static partial void lp_cancel(long seq);
    [LibraryImport(Lib)] internal static partial nint lp_next_event(int timeoutMs);
    [LibraryImport(Lib)] internal static partial void lp_free(nint p);
    [LibraryImport(Lib)] internal static partial void lp_shutdown();
    [LibraryImport(Lib)] internal static partial int lp_set_surface(int kind, long handle, int w, int h);
    [LibraryImport(Lib)] internal static partial int lp_gl_init(nint getProcAddress, nint ctx);
    [LibraryImport(Lib)] internal static partial int lp_gl_wants_redraw();
    [LibraryImport(Lib)] internal static partial int lp_gl_render(uint fbo, int w, int h, int flipY);
    [LibraryImport(Lib)] internal static partial void lp_gl_swapped();
    [LibraryImport(Lib)] internal static partial void lp_gl_uninit();

    public static void Preload(string coreDll)
    {
        var dir = Path.GetDirectoryName(Path.GetFullPath(coreDll));
        var mpv = Path.Combine(dir!, "libmpv-2.dll");
        if (File.Exists(mpv)) NativeLibrary.Load(mpv);
        var handle = NativeLibrary.Load(Path.GetFullPath(coreDll));
        NativeLibrary.SetDllImportResolver(typeof(Core).Assembly,
            (name, _, _) => name == Lib ? handle : nint.Zero);
    }

    // ---- 事件泵 · ★ 有且仅有一个线程调 lp_next_event(SPEC §5.11)----

    private static long _seq;
    private static readonly Dictionary<long, TaskCompletionSource<JsonElement>> Waiters = new();
    private static readonly object Lk = new();
    public static volatile bool SawEof;
    public static int LogCount;

    public static void StartPump()
    {
        new Thread(() =>
        {
            while (true)
            {
                var p = lp_next_event(-1);
                if (p == nint.Zero) continue;
                var json = Marshal.PtrToStringUTF8(p);
                lp_free(p);                       // ★ Go 分配,宿主释放(SPEC §5.3)
                if (json == null) continue;
                var e = JsonDocument.Parse(json).RootElement;
                var t = e.GetProperty("t").GetString();
                if (t == "eof") { SawEof = true; return; }
                if (t == "result")
                {
                    var sq = e.GetProperty("seq").GetInt64();
                    lock (Lk) if (Waiters.Remove(sq, out var tcs)) tcs.TrySetResult(e.Clone());
                }
                else if (t == "event" && e.TryGetProperty("name", out var n) && n.GetString() == "log")
                    Interlocked.Increment(ref LogCount);
            }
        }) { IsBackground = true, Name = "lp-events" }.Start();
    }

    /// <summary>同步语义由宿主自己包(SPEC §5.1:没有 lp_call_sync,那是 15 行的事)。</summary>
    public static JsonElement? Call(string cmd, string argsJson, int timeoutMs = 5000)
    {
        var sq = Interlocked.Increment(ref _seq);
        TaskCompletionSource<JsonElement> tcs;
        lock (Lk) { tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously); Waiters[sq] = tcs; }
        if (lp_call(sq, cmd, argsJson) != 0) return null;
        return tcs.Task.Wait(timeoutMs) ? tcs.Task.Result : null;
    }

    public static void CallAsync(string cmd, string argsJson)
        => lp_call(Interlocked.Increment(ref _seq), cmd, argsJson);

    /// <summary>读一个 mpv 属性 —— 经由 debug.mpvProp 命令,不是专用导出。</summary>
    public static string Prop(string name)
    {
        var r = Call("debug.mpvProp", "{\"name\":\"" + name + "\"}");
        if (r is not { } e || !e.GetProperty("ok").GetBoolean()) return null;
        return e.GetProperty("data").GetProperty("value").GetString();
    }

    public static double PropD(string name)
    {
        var s = Prop(name);
        return double.TryParse(s, NumberStyles.Float, CultureInfo.InvariantCulture, out var d) ? d : double.NaN;
    }

    public static void Counters(out ulong renders, out ulong swaps)
    {
        renders = swaps = 0;
        if (Call("debug.glCounters", "{}") is not { } e || !e.GetProperty("ok").GetBoolean()) return;
        var d = e.GetProperty("data");
        renders = (ulong)d.GetProperty("renderCalls").GetInt64();
        swaps = (ulong)d.GetProperty("swapCalls").GetInt64();
    }
}

// ----------------------------------------------------------------- 运行参数

internal sealed class Opts
{
    public string Clip;
    public string CoreDll = "../../../../../build/core/lpcore.dll";
    public string Hwdec = "auto";
    public string OutDir = "out";
    public string GlBackend = "default";   // default | wgl | angle
    public int Width = 1280, Height = 720;
    public double Seconds = 12.0;
    public int Shots = 6;
    /// <summary>反向验证开关:为 true 时**不调** lp_gl_swapped。</summary>
    public bool NoSwapped;
    public bool NoDecorations;
    public bool NoCore;      // 整条核心层都不碰:纯 Avalonia + 反复改尺寸,做崩溃归因的对照组
    public bool Resize;      // 反复改窗口尺寸,逼 Avalonia 不停重建它的 FBO
    public bool NoAnim;      // 关掉 UI 动画,隔离它对 CPU 的贡献
    public bool NoVideo;     // 只跑 Avalonia 合成、不调 lp_gl_render,量宿主底噪
    public int Danmaku;      // 弹幕条数,0 = 不开(SPIKE-5 的 A/B)
    public int DanmakuHz = 60;
    public int FpsFilter;   // >0 时插 vf append @danmaku:fps=fps=N(uosc_danmaku 的解法)
    public string Tag = "run";
    public string ClipFull;

    public static Opts Parse(string[] a)
    {
        var o = new Opts();
        for (var i = 0; i < a.Length; i++)
        {
            string Next() => a[++i];
            switch (a[i])
            {
                case "--clip": o.Clip = Next(); break;
                case "--core": o.CoreDll = Next(); break;
                case "--hwdec": o.Hwdec = Next(); break;
                case "--out": o.OutDir = Next(); break;
                case "--gl": o.GlBackend = Next(); break;
                case "--width": o.Width = int.Parse(Next()); break;
                case "--height": o.Height = int.Parse(Next()); break;
                case "--seconds": o.Seconds = double.Parse(Next(), CultureInfo.InvariantCulture); break;
                case "--shots": o.Shots = int.Parse(Next()); break;
                case "--no-swapped": o.NoSwapped = true; break;
                case "--no-decorations": o.NoDecorations = true; break;
                case "--no-anim": o.NoAnim = true; break;
                case "--resize": o.Resize = true; break;
                case "--no-core": o.NoCore = true; break;
                case "--no-video": o.NoVideo = true; break;
                case "--danmaku": o.Danmaku = int.Parse(Next()); break;
                case "--danmaku-hz": o.DanmakuHz = int.Parse(Next()); break;
                case "--fps-filter": o.FpsFilter = int.Parse(Next()); break;
                case "--tag": o.Tag = Next(); break;
                default: throw new ArgumentException("未知参数 " + a[i]);
            }
        }
        if (o.Clip == null) throw new ArgumentException("必须给 --clip");
        return o;
    }
}

// ----------------------------------------------------------------- GL 控件

internal sealed class MpvGlView : OpenGlControlBase
{
    private delegate IntPtr GetProcAddressFn(IntPtr ctx, IntPtr name);

    // 委托必须自己拿住,否则 GC 掉之后 mpv 回调进来就是野指针
    private GetProcAddressFn _gpaKeepAlive;
    private GlInterface _gl;

    public bool NoSwapped;
    public bool NoVideo;
    public bool NoCore;
    public string GlVendor = "?", GlRenderer = "?", GlVersionStr = "?";
    public string InitError;
    public int LastFbo, LastW, LastH;
    public long RenderCalls, SkipCalls;

    protected override void OnOpenGlInit(GlInterface gl)
    {
        _gl = gl;
        GlVendor = GetStr(gl, 0x1F00);
        GlRenderer = GetStr(gl, 0x1F01);
        GlVersionStr = GetStr(gl, 0x1F02);

        _gpaKeepAlive = (_, name) =>
        {
            var n = Marshal.PtrToStringAnsi(name);
            return n == null ? IntPtr.Zero : gl.GetProcAddress(n);
        };
        var fp = Marshal.GetFunctionPointerForDelegate(_gpaKeepAlive);

        if (NoCore) return;

        var r = Core.lp_gl_init(fp, IntPtr.Zero);
        if (r != 0) { InitError = "lp_gl_init 返回 " + r; return; }

        // ★ 起播必须排在 lp_gl_init 之后。反过来 vo=libmpv 会以
        //   「No render context set.」致命失败,而且不重试 —— 表现是全程黑屏、
        //   wants_redraw 恒 0,没有任何回调会告诉你出了事。2026-08-31 实测,见报告 §5.2。
        //   核心层自己也会挡(SPEC §7.2 约束 6),这里发出去就行,不等结果 ——
        //   等结果会把 Avalonia 的渲染线程堵住。
        Core.CallAsync("player.play", System.Text.Json.JsonSerializer.Serialize(new { path = App.O.ClipFull }));
    }

    protected override void OnOpenGlRender(GlInterface gl, int fb)
    {
        var scale = (VisualRoot as TopLevel)?.RenderScaling ?? 1.0;
        var w = Math.Max(1, (int)Math.Round(Bounds.Width * scale));
        var h = Math.Max(1, (int)Math.Round(Bounds.Height * scale));
        LastFbo = fb; LastW = w; LastH = h;

        // SPEC §7.2 通道 B 的三步。顺序不许换。
        if (!NoCore && Core.lp_gl_wants_redraw() != 0 && !NoVideo)
        {
            Core.lp_gl_render((uint)fb, w, h, 1);   // flip_y=1:GL 原点在左下,让核心层翻,宿主别再翻
            if (!NoSwapped) Core.lp_gl_swapped();   // ★ 漏了它帧率控制是瞎的,--no-swapped 就是拿它做反向验证
            RenderCalls++;
        }
        else
        {
            SkipCalls++;
        }

        // ponytail: 连续请求下一帧。生产版应当由 mpv 的 update 回调驱动 RequestNextFrameRendering,
        // 暂停时才真的能停下来;SPIKE 里连续请求反而是量帧率想要的口径。
        RequestNextFrameRendering();
    }

    protected override void OnOpenGlDeinit(GlInterface gl) { if (!NoCore) Core.lp_gl_uninit(); }

    private static string GetStr(GlInterface gl, int name)
    {
        var p = gl.GetProcAddress("glGetString");
        if (p == IntPtr.Zero) return "?";
        var fn = Marshal.GetDelegateForFunctionPointer<GetStringFn>(p);
        var s = fn(name);
        return s == IntPtr.Zero ? "?" : Marshal.PtrToStringAnsi(s);
    }

    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    private delegate IntPtr GetStringFn(int name);
}

// ----------------------------------------------------------------- 应用

internal sealed class App : Application
{
    public static Opts O;
    public static Report Rep;

    public override void Initialize() => Styles.Add(new Avalonia.Themes.Simple.SimpleTheme());

    public override void OnFrameworkInitializationCompleted()
    {
        var view = new MpvGlView { NoSwapped = O.NoSwapped, NoVideo = O.NoVideo || O.NoCore, NoCore = O.NoCore };

        var stats = new TextBlock
        {
            Foreground = Brushes.White, FontSize = 15, FontFamily = new FontFamily("Consolas"),
            Margin = new Thickness(14, 10, 0, 0), Text = "…",
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
        };

        // ★ 判据用的半透明控件:50% 品红。选品红是因为它在真实影像里几乎不出现,
        //   像素上一眼能把「叠上去了」和「视频本身就这个色」分开。
        var overlay = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(128, 255, 0, 255)),
            Height = OverlayHeight, VerticalAlignment = VerticalAlignment.Bottom,
            Child = stats,
        };

        // 一个在视频区里横向移动的小方块:证明 UI 动画能压在视频上跑,而且能看出闪不闪
        var mover = new Border
        {
            Width = 90, Height = 90, Background = new SolidColorBrush(Color.FromArgb(180, 0, 255, 128)),
            HorizontalAlignment = HorizontalAlignment.Left, VerticalAlignment = VerticalAlignment.Top,
            Margin = new Thickness(0, 40, 0, 0),
        };

        var root = new Grid();
        root.Children.Add(view);
        root.Children.Add(mover);
        root.Children.Add(overlay);

        var win = new Window
        {
            Title = "S1.2 路径 B 探针",
            Width = O.Width, Height = O.Height,
            SystemDecorations = O.NoDecorations ? SystemDecorations.None : SystemDecorations.Full,
            Background = Brushes.Black,
            Topmost = true,                       // 截屏取证要它不被遮住
            WindowStartupLocation = WindowStartupLocation.Manual,
            Position = new PixelPoint(0, 0),
            CanResize = false,
            Content = root,
        };

        Rep = new Report(O, view, win, stats, mover);
        win.Opened += (_, _) => Rep.Start();

        if (ApplicationLifetime is Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime d)
            d.MainWindow = win;

        base.OnFrameworkInitializationCompleted();
    }

    public const double OverlayHeight = 150;
}

// ----------------------------------------------------------------- 测量与取证

internal sealed class Report
{
    private readonly Opts _o;
    private readonly MpvGlView _view;
    private readonly Window _win;
    private readonly TextBlock _stats;
    private readonly Border _mover;
    private readonly List<Shot> _shots = new();
    private readonly StringBuilder _log = new();

    public Report(Opts o, MpvGlView v, Window w, TextBlock s, Border m)
    { _o = o; _view = v; _win = w; _stats = s; _mover = m; }

    private sealed class Shot
    {
        public double T;
        public double Vr, Vg, Vb;   // 视频区均值
        public double Or, Og, Ob;   // 叠加区均值
        public byte[] Vt, Ot;       // 64x36 灰度缩略图,用来算逐像素帧间差
        public double VWhite;       // 视频区近白像素占比(弹幕判据)
        public string File;
    }

    private const int TW = 64, TH = 36;

    /// 最近一次 Sample 的近白像素占比。弹幕是白字,A/B 靠它。
    private static double LastWhiteRatio;

    /// 逐像素平均绝对差。**不能用区域均值之差** —— 运动会在均值里互相抵消,
    /// t3 那轮判据 A 就是这么假红的(视频明明在动,均值恒 149,167,0)。
    private static double Mad(byte[] a, byte[] b)
    {
        if (a == null || b == null) return 0;
        double s = 0;
        for (var i = 0; i < a.Length; i++) s += Math.Abs(a[i] - b[i]);
        return s / a.Length;
    }

    public void Start() => new Thread(Run) { IsBackground = true }.Start();

    private void W(string s) { _log.AppendLine(s); Console.WriteLine(s); }

    private void Run()
    {
        Directory.CreateDirectory(_o.OutDir);
        var sw = Stopwatch.StartNew();

        // 等文件真加载(time-pos 出得来)。真服/大文件下这一步能要好几秒
        string loaded = _o.NoCore ? "skip" : null;
        while (sw.Elapsed.TotalSeconds < 20 && loaded == null)
        {
            Thread.Sleep(100);
            if (!double.IsNaN(Core.PropD("time-pos"))) loaded = "ok";
        }

        // UI 动画:让方块动起来(顺带证明 UI 线程在视频之上照常跑)
        var anim = _o.NoAnim ? null : new Timer(_ => Dispatcher.UIThread.Post(() =>
        {
            var t = sw.Elapsed.TotalSeconds;
            var span = Math.Max(50, _win.ClientSize.Width - 120);
            _mover.Margin = new Thickness((Math.Sin(t * 1.6) * 0.5 + 0.5) * span, 40, 0, 0);
        }), null, 0, 16);

        // ★ 把「偶发崩」变成「必现崩」:Avalonia 只在尺寸变化时重建自己的 FBO,
        //   而那正是 mpv 留下的脏 GL 状态发作的地方。不停改尺寸 = 每 400ms 逼它重建一次。
        Timer resizer = null;
        if (_o.Resize)
        {
            var toggle = false;
            resizer = new Timer(_ => Dispatcher.UIThread.Post(() =>
            {
                toggle = !toggle;
                _win.Width = _o.Width - (toggle ? 40 : 0);
                _win.Height = _o.Height - (toggle ? 24 : 0);
            }), null, 400, 400);
        }

        // SPIKE-5:起播之后再开弹幕
        if (_o.Danmaku > 0)
        {
            Core.Call("debug.danmakuLoad", "{\"count\":" + _o.Danmaku + ",\"span\":30}");
            Core.Call("debug.danmakuStart", "{\"hz\":" + _o.DanmakuHz + ",\"fpsFilter\":" + _o.FpsFilter + "}", 15000);
        }

        Thread.Sleep(1500);   // 预热,别把起播抖动算进去

        var t0 = sw.Elapsed.TotalSeconds;
        var cpu0 = Process.GetCurrentProcess().TotalProcessorTime;
        ulong r0 = 0, s0 = 0; if (!_o.NoCore) Core.Counters(out r0, out s0);
        var pos0 = _o.NoCore ? 0 : Core.PropD("time-pos");
        var drop0 = _o.NoCore ? 0 : Core.PropD("frame-drop-count");

        var shotEvery = _o.Seconds / Math.Max(1, _o.Shots);
        if (_o.Shots == 0) Thread.Sleep((int)(_o.Seconds * 1000));
        for (var i = 0; i < _o.Shots; i++)
        {
            Thread.Sleep((int)(shotEvery * 1000));
            var st = Capture(i, sw.Elapsed.TotalSeconds - t0);
            if (st != null) _shots.Add(st);
            var pos = _o.NoCore ? 0 : Core.PropD("time-pos");
            Dispatcher.UIThread.Post(() => _stats.Text =
                $"S1.2 路径 B 探针  tag={_o.Tag}\n" +
                $"swapped={( _o.NoSwapped ? "关(反向验证)" : "开")}   hwdec={Core.Prop("hwdec-current")}\n" +
                $"time-pos={pos:F2}  drop={(_o.NoCore ? "—" : Core.Prop("frame-drop-count"))}");
        }

        var wall = sw.Elapsed.TotalSeconds - t0;
        var cpu = (Process.GetCurrentProcess().TotalProcessorTime - cpu0).TotalSeconds;
        ulong r1 = 0, s1 = 0; if (!_o.NoCore) Core.Counters(out r1, out s1);
        var pos1 = _o.NoCore ? 0 : Core.PropD("time-pos");
        var drop1 = _o.NoCore ? 0 : Core.PropD("frame-drop-count");
        anim?.Dispose(); resizer?.Dispose();

        Emit(wall, cpu, r1 - r0, s1 - s0, pos1 - pos0, drop1 - drop0);

        // ★ 关停顺序:先 Shutdown(它会触发 OnOpenGlDeinit -> lp_gl_uninit),
        //   **之后**才关 mpv。反过来先关 mpv,render context 还活着 ->
        //   Avalonia 合成器当场抛异常(实测,见报告 §5.2)。lp_spike_close 挪到 Main 里。
        Dispatcher.UIThread.Post(() =>
            (Application.Current.ApplicationLifetime as
                Avalonia.Controls.ApplicationLifetimes.IClassicDesktopStyleApplicationLifetime)?.Shutdown());
    }

    // ---- 截屏 + 像素指标 -------------------------------------------------
    //
    // 判据是这样成立的:
    //   出画面        = 视频区在各帧之间**有变化**(静态黑屏不会变)
    //   叠加可见      = 叠加区相对视频区**向品红偏**(R、B 高于 G)
    //   叠加是半透明  = 叠加区在各帧之间**也有变化**(不透明的话它恒定)
    //   不闪          = **每一帧**的品红偏移都为正,不是平均为正

    private Shot Capture(int idx, double t)
    {
        PixelPoint origin = default;
        Size client = default;
        double scale = 1;
        using var done = new ManualResetEventSlim();
        Dispatcher.UIThread.Post(() =>
        {
            origin = _win.PointToScreen(new Point(0, 0));
            client = _win.ClientSize;
            scale = _win.RenderScaling;
            done.Set();
        });
        if (!done.Wait(3000)) return null;

        var w = (int)Math.Round(client.Width * scale);
        var h = (int)Math.Round(client.Height * scale);
        if (w < 32 || h < 32) return null;

        using var bmp = new SD.Bitmap(w, h, SDI.PixelFormat.Format32bppArgb);
        using (var g = SD.Graphics.FromImage(bmp))
            g.CopyFromScreen(origin.X, origin.Y, 0, 0, new SD.Size(w, h), SD.CopyPixelOperation.SourceCopy);

        var file = Path.Combine(_o.OutDir, $"{_o.Tag}-shot{idx}.png");
        bmp.Save(file, SDI.ImageFormat.Png);

        var overlayPx = App.OverlayHeight * scale;
        var (vr, vg, vb, vt) = Sample(bmp, 0.05, 0.10, 0.95, 0.60, h, w);
        var vWhite = LastWhiteRatio;
        // 叠加区:取品红带内、避开左边文字的右半部分
        var oTop = (h - overlayPx) / h + 0.15 * (overlayPx / h);
        var oBot = (h - overlayPx) / h + 0.85 * (overlayPx / h);
        var (or_, og, ob, ot) = Sample(bmp, 0.55, oTop, 0.95, oBot, h, w);

        return new Shot { T = t, Vr = vr, Vg = vg, Vb = vb, Or = or_, Og = og, Ob = ob,
                          Vt = vt, Ot = ot, VWhite = vWhite, File = file };
    }

    private static (double, double, double, byte[]) Sample(SD.Bitmap b, double x0, double y0, double x1, double y1,
                                                           int h, int w)
    {
        int X0 = (int)(x0 * w), X1 = (int)(x1 * w), Y0 = (int)(y0 * h), Y1 = (int)(y1 * h);
        var rect = new SD.Rectangle(X0, Y0, Math.Max(1, X1 - X0), Math.Max(1, Y1 - Y0));
        var data = b.LockBits(rect, SDI.ImageLockMode.ReadOnly, SDI.PixelFormat.Format32bppArgb);
        double sr = 0, sg = 0, sb = 0; long n = 0; long white = 0;
        var thumb = new byte[TW * TH];
        unsafe
        {
            for (var y = 0; y < rect.Height; y++)
            {
                var row = (byte*)data.Scan0 + y * data.Stride;
                for (var x = 0; x < rect.Width; x++)
                {
                    var bb = row[x * 4 + 0]; var gg = row[x * 4 + 1]; var rr = row[x * 4 + 2];
                    sb += bb; sg += gg; sr += rr; n++;
                    if (rr > 232 && gg > 232 && bb > 232) white++;   // 弹幕是白字,数它
                }
            }
            for (var ty = 0; ty < TH; ty++)
            {
                var sy = (int)((ty + 0.5) / TH * rect.Height);
                var row = (byte*)data.Scan0 + sy * data.Stride;
                for (var tx = 0; tx < TW; tx++)
                {
                    var sx = (int)((tx + 0.5) / TW * rect.Width);
                    thumb[ty * TW + tx] = (byte)((row[sx * 4 + 0] + row[sx * 4 + 1] + row[sx * 4 + 2]) / 3);
                }
            }
        }
        b.UnlockBits(data);
        LastWhiteRatio = (double)white / n;
        return (sr / n, sg / n, sb / n, thumb);
    }

    // ---- 报告 -------------------------------------------------------------

    private void Emit(double wall, double cpu, ulong renders, ulong swaps,
                      double posAdvance, double drops)
    {
        var fps = renders / wall;
        var ratio = posAdvance / wall;

        W("================ S1.2 路径 B · Avalonia 探针 ================");
        W($"tag              : {_o.Tag}");
        W($"片源             : {Path.GetFileName(_o.Clip)}");
        W($"窗口客户区       : {_o.Width}x{_o.Height}   GL 后端请求={_o.GlBackend}   动画={(_o.NoAnim ? "关" : "开")}  截屏={_o.Shots} 张  视频={(_o.NoVideo ? "关(只量宿主底噪)" : "开")}");
        W($"lp_gl_swapped    : {(_o.NoSwapped ? "★ 已关闭(反向验证)" : "开启")}");
        W($"block_for_target : {(Environment.GetEnvironmentVariable("LP_BLOCK_FOR_TARGET_TIME") == "0" ? "0(不阻塞渲染线程)" : "1(mpv 默认)")}");
        W($"反复改尺寸       : {(_o.Resize ? "开(逼 Avalonia 重建 FBO)" : "关")}");
        W($"GL_VENDOR        : {_view.GlVendor}");
        W($"GL_RENDERER      : {_view.GlRenderer}");
        W($"GL_VERSION       : {_view.GlVersionStr}");
        W($"lp_gl_init       : {(_view.InitError ?? "OK")}");
        W($"FBO(末次)       : fb={_view.LastFbo} {_view.LastW}x{_view.LastH}");
        W($"hwdec-current    : {(_o.NoCore ? "—(--no-core)" : Core.Prop("hwdec-current"))}");
        W($"video            : {(_o.NoCore ? "—" : Core.Prop("width") + "x" + Core.Prop("height") + "  container-fps=" + Core.Prop("container-fps"))}");
        W("");
        W($"测量窗口         : {wall:F2}s");
        W($"lp_gl_render     : {renders} 次  ->  {fps:F1} fps");
        W($"lp_gl_swapped    : {swaps} 次");
        W($"wants_redraw=0   : {_view.SkipCalls} 次(跳过重绘)");
        W($"播放推进         : {posAdvance:F2}s / {wall:F2}s = {ratio:F3}  {(ratio >= 0.98 ? "跟得上" : "!! 跟不上")}");
        W($"frame-drop-count : +{drops:F0}");
        W($"CPU              : {cpu / wall * 100:F0}% 单核  ({cpu:F2}s / {wall:F2}s)");
        W($"estimated-vf-fps : {(_o.NoCore ? "—" : Core.Prop("estimated-vf-fps"))}");
        // ★ report_swap 喂的就是 estimated-display-fps。漏调它,这一栏应该是空的 ——
        //   这比看帧率更直接:帧率没掉不代表那个调用没意义。
        W($"video-sync       : {(_o.NoCore ? "—" : Core.Prop("video-sync"))}");
        W($"display-fps      : {(_o.NoCore ? "—" : Core.Prop("display-fps"))}   estimated-display-fps={(_o.NoCore ? "—" : Core.Prop("estimated-display-fps") ?? "(空)")}");
        W("");

        W("---- 像素取证(每张截图) ----");
        W("  #   t(s)   视频区 RGB          叠加区 RGB          品红偏移");
        // 没截图就没有像素判据。这里必须打「未测」而不是打一个 double.MaxValue ——
        // 一个恒真的判据比没有判据更糟(AGENTS.md §4.1)。
        double minShift = double.MaxValue;
        foreach (var (s, i) in _shots.Select((s, i) => (s, i)))
        {
            var shift = ((s.Or - s.Og) + (s.Ob - s.Og)) - ((s.Vr - s.Vg) + (s.Vb - s.Vg));
            minShift = Math.Min(minShift, shift);
            W($"  {i}  {s.T,5:F1}   {s.Vr,5:F0},{s.Vg,5:F0},{s.Vb,5:F0}   {s.Or,5:F0},{s.Og,5:F0},{s.Ob,5:F0}   {shift,7:F1}");
        }

        double VideoDelta() => _shots.Count < 2 ? 0 : _shots.Zip(_shots.Skip(1), (a, b) => Mad(a.Vt, b.Vt)).Average();
        double OverlayDelta() => _shots.Count < 2 ? 0 : _shots.Zip(_shots.Skip(1), (a, b) => Mad(a.Ot, b.Ot)).Average();

        var vd = VideoDelta(); var od = OverlayDelta();
        W("");
        W("---- 判据 ----");
        if (_shots.Count < 2)
        {
            W("  A/B/C/D 像素判据      : 未测(本次 --shots < 2,只量性能)");
        }
        else
        {
            W($"  A 窗口里出画面        : 视频区逐像素帧间差 {vd:F2}  -> {(vd > 1.0 ? "通过" : "!! 不通过")}");
            W($"  B 半透明控件可见      : 最小品红偏移 {minShift:F1} -> {(minShift > 10 ? "通过" : "!! 不通过")}");
            W($"  C 控件确实是半透明    : 叠加区逐像素帧间差 {od:F2}  -> {(od > 0.5 ? "通过(视频透上来了)" : "!! 不通过")}");
            W($"  D 不闪(每帧都在)    : 最小值 > 0 即每帧都可见 -> {(minShift > 10 ? "通过" : "!! 不通过")}");
        }
        if (_o.Danmaku > 0)
        {
            W("");
            W("---- 弹幕(SPIKE-5)----");
            var st = Core.Call("debug.danmakuStats", "{}");
            if (st is { } e2 && e2.GetProperty("ok").GetBoolean())
            {
                var d2 = e2.GetProperty("data");
                var pushes = d2.GetProperty("pushes").GetInt64();
                var ticks = d2.GetProperty("ticks").GetInt64();
                var distinct = d2.GetProperty("distinct").GetInt64();
                W($"  循环拍数         : {ticks} -> {ticks / wall:F1} 拍/秒(目标 {_o.DanmakuHz} Hz)");
                W($"  ★ 位置真变次数   : {distinct} -> {distinct / wall:F1} 次/秒  ← **这才是弹幕的实际平滑度**");
                W($"  overlay 推送     : {pushes} 次(每拍 2 层)");
                W($"  fps 滤镜         : {(_o.FpsFilter > 0 ? "@danmaku:fps=fps=" + _o.FpsFilter : "未插")}");
                W($"  位置变化间隔均值 : {d2.GetProperty("meanDelta").GetDouble() * 1000:F2} ms");
                W($"  位置变化间隔标准差: {d2.GetProperty("stdDelta").GetDouble() * 1000:F2} ms");
                W($"  弹幕条数         : {d2.GetProperty("items").GetInt32()}");
            }
            Core.Call("debug.danmakuStop", "{}");
        }
        {
            // ★ 无论开不开弹幕都要打:--danmaku 0 那次是 A/B 的**基线**,
            //   不打基线,这条判据就没法比
            var wr = _shots.Count > 0 ? _shots.Average(x => x.VWhite) : 0;
            W($"视频区近白占比       : {wr * 100:F2}%  ← 弹幕是白字,和 --danmaku 0 比就是 A/B 判据");
        }
        W($"截图目录             : {Path.GetFullPath(_o.OutDir)}");
        W("============================================================");

        File.WriteAllText(Path.Combine(_o.OutDir, _o.Tag + "-report.txt"), _log.ToString());
    }
}

// ----------------------------------------------------------------- 入口

internal static class Program
{
    [DllImport("kernel32.dll")] private static extern bool AttachConsole(int pid);

    [STAThread]
    public static int Main(string[] args)
    {
        AttachConsole(-1);   // WinExe 没有控制台;附到父 shell 上,报告才看得见
        try
        {
            App.O = Opts.Parse(args);
            Core.Preload(App.O.CoreDll);

            App.O.ClipFull = Path.GetFullPath(App.O.Clip);
            if (!App.O.NoCore)
            {
                var abi = Core.lp_abi_version();
                if (abi != Core.HostAbi) { Console.WriteLine($"ABI 错配:核心 {abi} vs 宿主 {Core.HostAbi},拒绝启动"); return 3; }
                if (Core.lp_init("{\"platform\":\"windows\"}") != 0) { Console.WriteLine("lp_init 失败"); return 2; }
                Core.StartPump();
            }

            BuildApp(App.O).StartWithClassicDesktopLifetime(Array.Empty<string>());
            if (!App.O.NoCore) Core.lp_shutdown();   // 事件循环退出 = OnOpenGlDeinit 已经跑过 = render context 已释放
            return 0;
        }
        catch (Exception e)
        {
            Console.WriteLine("!! " + e);
            return 1;
        }
    }

    private static AppBuilder BuildApp(Opts o)
    {
        var b = AppBuilder.Configure<App>().UsePlatformDetect().LogToTrace();
        if (o.GlBackend == "wgl")
            b = b.With(new Win32PlatformOptions { RenderingMode = new[] { Win32RenderingMode.Wgl } });
        else if (o.GlBackend == "angle")
            b = b.With(new Win32PlatformOptions { RenderingMode = new[] { Win32RenderingMode.AngleEgl } });
        return b;
    }
}
