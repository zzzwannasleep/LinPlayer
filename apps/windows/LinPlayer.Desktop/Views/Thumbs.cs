using System;
using System.Runtime.InteropServices;
using Avalonia;
using Avalonia.Media.Imaging;
using Avalonia.OpenGL;
using Avalonia.Platform;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 进度条悬停缩略图的帧库。
///
/// <para>★★ 用户 2026-09-03:「做一个缩略图的功能,<b>缓存了的进度条能用,
/// 没缓存的不能用这个缩略图功能</b>」。这条约束不是妥协,它直接决定了帧从哪儿来 ——
/// 我们<b>没有</b>可以随便取任意时刻画面的东西:</para>
///
/// <list type="bullet">
/// <item>服务端 trickplay(BIF)只有新版 Emby 才有,而本仓要伺候一堆 fork;</item>
/// <item>让 mpv 跳过去截一张,会把正在放的画面拽走;</item>
/// <item>另起一个 mpv 实例解码,是把播放器的复杂度翻一倍去换一张小图。</item>
/// </list>
///
/// <para>所以帧来自<b>我们自己已经渲染过的那些</b>:每渲染一段就顺手把当前这一帧
/// 缩成 160×90 收进来。于是「有缩略图的位置」= 「已经放过的位置」,
/// 这正好就是用户说的那条规则,而且它是**真的**,不是我们承诺出来的。</para>
///
/// <para>★ 时间轴切成 <see cref="Slots"/> 格,按格存 —— 不按秒:
/// 一部两小时的片子按秒存是 7200 张。格数固定之后,长片的格子粗、短片的细,
/// 而内存占用是个常数(300 × 160×90×4 ≈ 17 MB)。</para>
///
/// <para>ponytail: 一次 glReadPixels 读的是整块 FBO(窗口大小,不是视频分辨率),
/// 4K 窗口下单次约 33 MB —— 但它每格才发生一次(两小时的片子 ≈ 每 24 秒一次)。
/// 真嫌重的话下一步是 BlitFramebuffer 先缩到 160×90 再读,那要求 GLES3。</para>
/// </summary>
public sealed class Thumbs
{
    /// <summary>时间轴切几格。</summary>
    public const int Slots = 300;

    /// <summary>缩略图尺寸。★ 16:9 —— 视频不是这个比例时按短边裁,不拉伸。</summary>
    private const int TW = 160, TH = 90;

    /// <summary>两次抓帧至少隔多久。★ 拖动进度条时会连续跨好几格,不限一下会连着读好几次。</summary>
    private static readonly TimeSpan MinGap = TimeSpan.FromMilliseconds(400);

    private delegate void ReadPixelsFn(int x, int y, int w, int h, int fmt, int type, IntPtr data);

    private const int GL_RGBA = 0x1908, GL_UNSIGNED_BYTE = 0x1401;
    private const int GL_FRAMEBUFFER = 0x8D40;

    private readonly Bitmap?[] _frames = new Bitmap?[Slots];
    private ReadPixelsFn? _read;
    private bool _probed;
    private DateTime _last = DateTime.MinValue;
    private byte[] _scratch = [];

    /// <summary>最近一次抓帧的亮度均值。<b>0 = 读到的是全黑</b>,见 <see cref="Capture"/> 里那段 ☠。</summary>
    public double LastMean { get; private set; }

    /// <summary>总时长。0 = 还不知道,这时候不抓(没有时长就分不出格)。</summary>
    public double Duration { get; set; }

    /// <summary>当前播放位置,由轮询喂进来。</summary>
    public double Position { get; set; }

    /// <summary>换片要清空 —— 不清的话新片的进度条上会飘出上一部片的画面。</summary>
    public void Reset()
    {
        lock (_frames) Array.Clear(_frames);
        Duration = 0;
        Position = 0;
    }

    /// <summary>这一格有没有帧。<see cref="PlayerBar"/> 画覆盖带用。</summary>
    public bool Has(int slot) => slot >= 0 && slot < Slots && _frames[slot] is not null;

    /// <summary>某个时间点的缩略图。没有就返回 null —— <b>调用方要能画出「只有时间」那一版</b>。</summary>
    public Bitmap? At(double pos)
    {
        var i = SlotOf(pos);
        return i < 0 ? null : _frames[i];
    }

    public int SlotOf(double pos)
    {
        if (Duration <= 0) return -1;
        var i = (int)(pos / Duration * Slots);
        return i < 0 ? 0 : i >= Slots ? Slots - 1 : i;
    }

    /// <summary>
    /// 渲染完一帧之后调。<b>只在「这一格还空着」时才真读</b>。
    ///
    /// <para>★ 必须在 GL 线程上、并且在这一帧画完之后调 —— 早了读到的是上一帧,
    /// 而上一帧和进度条上那个位置对不上。</para>
    /// </summary>
    public void Capture(GlInterface gl, int fb, int w, int h)
    {
        if (Duration <= 0 || w < 16 || h < 16) return;
        var slot = SlotOf(Position);
        if (slot < 0 || _frames[slot] is not null) return;
        var now = DateTime.UtcNow;
        if (now - _last < MinGap) return;
        _last = now;

        if (!_probed)
        {
            _probed = true;
            var p = gl.GetProcAddress("glReadPixels");
            // ★ 取不到就<b>整个功能安静地不存在</b>:缩略图是锦上添花,
            //   为它把播放页拖红是本末倒置。气泡那边本来就有「没有图只显示时间」那一版。
            if (p != IntPtr.Zero) _read = Marshal.GetDelegateForFunctionPointer<ReadPixelsFn>(p);
            else Console.WriteLine("[缩略图] 这套 GL 上拿不到 glReadPixels —— 只显示时间");
        }
        if (_read is null) return;

        var need = w * h * 4;
        if (_scratch.Length < need) _scratch = new byte[need];
        try
        {
            /* ☠☠ <b>读之前必须自己把目标 FBO 绑回来</b>。
               这个回调进来时 Avalonia 确实绑的是 fb,但中间 mpv 的 render 跑过了 ——
               它内部会绑自己的 FBO,而**不保证还原**。不绑的话 glReadPixels
               读的是另一块缓冲区,拿回来一片全黑:不报错、不崩,
               只是每张缩略图都是黑的(第一版就是这么出来的)。 */
            gl.BindFramebuffer(GL_FRAMEBUFFER, fb);
            var pin = GCHandle.Alloc(_scratch, GCHandleType.Pinned);
            try { _read(0, 0, w, h, GL_RGBA, GL_UNSIGNED_BYTE, pin.AddrOfPinnedObject()); }
            finally { pin.Free(); }
            _frames[slot] = Shrink(_scratch, w, h);
            /* ★★ 顺手记一个**亮度均值**,给自检当判据。
               ☠ 这不是锦上添花:第一版忘了把目标 FBO 绑回来(mpv 的 render 会绑走它、
                 而且不还原),读回来是<b>整片全黑</b> —— 缩略图张张都有、尺寸也对、
                 一个错都不报,只是全黑。「有没有图」这个判据照样绿。
               ★ 隔 37 个像素采一个:够用,而且和图的内容无关(全黑就是 0)。 */
            long sum = 0;
            var n = 0;
            for (var i = 0; i < need; i += 4 * 37) { sum += _scratch[i] + _scratch[i + 1] + _scratch[i + 2]; n += 3; }
            LastMean = n > 0 ? sum / (double)n : 0;
        }
        catch (Exception e) { Console.WriteLine("[缩略图] 抓帧失败: " + e.Message); _read = null; }
    }

    /// <summary>
    /// 把整块像素缩成 160×90。
    ///
    /// <para>★ <b>行序要翻</b>:glReadPixels 的原点在左下,而位图的第一行是画面最上面那一行。
    /// 不翻的结果是每张缩略图都上下颠倒,而它<b>不报错</b> —— 看着只是「这片子怎么倒着的」。</para>
    /// <para>★ <b>通道要换</b>:读回来是 RGBA,而 Avalonia 的 Bgra8888 要的是 B,G,R,A。
    /// 不换的话红蓝互调,人脸会变成蓝色。</para>
    /// <para>★ 盒式取样(每个目标像素取源区域中心那一点)。做双线性对一张 160×90 的
    /// 预览图没有可感知的收益,而它要多写三十行。</para>
    /// </summary>
    private static Bitmap Shrink(byte[] src, int w, int h)
    {
        var bmp = new WriteableBitmap(new PixelSize(TW, TH), new Vector(96, 96),
            PixelFormat.Bgra8888, AlphaFormat.Opaque);
        using var fb = bmp.Lock();
        unsafe
        {
            var dst = (byte*)fb.Address;
            for (var y = 0; y < TH; y++)
            {
                // ★ 翻行:目标第 0 行对应源最上面那一行 = glReadPixels 的最后一行
                var sy = h - 1 - (int)((y + 0.5) / TH * h);
                if (sy < 0) sy = 0;
                if (sy >= h) sy = h - 1;
                var row = dst + y * fb.RowBytes;
                for (var x = 0; x < TW; x++)
                {
                    var sx = (int)((x + 0.5) / TW * w);
                    if (sx >= w) sx = w - 1;
                    var i = (sy * w + sx) * 4;
                    row[x * 4 + 0] = src[i + 2];   // B
                    row[x * 4 + 1] = src[i + 1];   // G
                    row[x * 4 + 2] = src[i + 0];   // R
                    row[x * 4 + 3] = 255;
                }
            }
        }
        return bmp;
    }
}
