using System.Collections.Generic;
using System.IO;
using System.Text.Json;
using Avalonia.Media.Imaging;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 进度条悬停缩略图的取数与缓存。
///
/// <para>帧不是这一层产生的 —— 它向核心层要(<c>player.thumbnail</c>),核心层用
/// 第二个 <c>vo=null</c> 的 mpv 实例、只读本地已缓存的字节(140×80,单张 9~12ms)。
/// 上一版是从我们自己渲染过的画面里留一份,那样只有放过的位置才有图,
/// 而用户要的是已缓存的进度 —— 缓存的恰恰是前面还没放到的那一段。
/// 「没缓存的不能用」这条规则不在这里判:判断和事实分两处,迟早会对不上。</para>
/// </summary>
public sealed class Thumbs(CoreClient core)
{
    /// <summary>时间轴分多少格。取图和缓存都按格走 —— 鼠标移动一个像素就发一次请求,
    /// 那是几十次解码;而相邻两像素上的画面根本是同一帧。</summary>
    public const int Slots = 300;

    /// <summary>缓存多少张。<b>整条时间轴全留</b> —— 用户 2026-09-03 的口径是
    /// 「缓存在内存里面」。140×80 解出来是 BGRA ≈ 45KB,300 格全满也就 13MB;
    /// 上一版 320×180 一张就 230KB,才不得不设 60 张的上限。
    ///
    /// <para>全留的意义不是省内存,是<b>划回去不用重解</b>:设了上限的话
    /// 用户来回拖两趟就把前面的挤掉了,每次都要重新等一趟解码。</para></summary>
    private const int Keep = Slots;

    private readonly Dictionary<int, Bitmap> _got = new();
    private readonly Queue<int> _order = new();

    /* <b>同一时刻只解一张,而且只解「手指现在停的那一格」。</b>
       用户 2026-09-04:「在我滑动缩略图的时候,视频会不断卡顿,画面不断抽搐」。

       上一版是「每一格各发各的,靠 _busy 去重」—— 听起来像限流,其实<b>一点流都没限</b>:
       去重的粒度是**格**,而拖一趟进度条会扫过几十上百格,于是几十上百个请求
       一起压到核心层那把 thumbs.mu 上排队。每张要 seek + 解码 + 落一次盘,
       整条队列要跑好几秒,而这几秒里:
         · 那台第二个 mpv 实例一直在满负荷解码(CPU 抢的是正片的解码线程);
         · 它在环形缓存文件上**满文件随机读**,而正片正在同一个文件上顺序读写。
       用户看到的就是「一滑进度条,画面开始一顿一顿」。

       关键是:<b>队列里除了最后一个,其余全都已经没人要了</b> ——
         鼠标早就划过去了,那些位置的图解出来也不会有人看。所以不是「限流」,
         是**丢掉过期请求**:排队位只留一个,新的直接顶掉旧的。
       手停下来之后,最后那一格照样会被解出来 —— 用户看到的图一张都不少。
       这一条在「本地自己解」这个架构下是**必须**的,不是优化:
         解一帧的代价是真 CPU + 真磁盘,而它抢的正是正片的解码线程。 */
    /// <summary>正在解的那一格(-1 = 空闲)。</summary>
    private int _inflight = -1;
    /// <summary>排队位。<b>只有一个</b> —— 新的顶掉旧的。</summary>
    private int _queued = -1;
    private double _queuedPos;

    /// <summary>真发出去过多少次 <c>player.thumbnail</c>。自检用。</summary>
    public int Asked { get; private set; }

    /* 失败**只记一小会儿,不永久记**。
       原来失败也往 _got 里塞一个 null,于是那一格从此再也不问了 ——
       而失败最常见的原因恰恰是**暂时性**的:那一段刚好还没缓存到本地、
       第一次开文件慢了一点。结果是用户早划了一下,那一格就永远没有图了,
       哪怕十秒后整段都在本地。2026-09-03 自检当场撞上(一次超时之后,
       后面每一次轮询都立刻返回 null,连请求都不再发)。
       又不能完全不记:不记的话鼠标停在一个真的取不到的位置上,
         每一帧都会去发一次必然失败的请求。所以记 5 秒。 */
    private readonly Dictionary<int, long> _failedAt = new();
    private const int RetryAfterMs = 5000;

    /// <summary>片长(秒)。0 = 还不知道,这时一律不取。</summary>
    public double Duration;

    /// <summary>本地已有字节的区间(占全片的比例)。核心层 <c>player.status.cached</c> 给的。</summary>
    public IReadOnlyList<(double A, double B)> Spans { get; private set; } = [];

    /// <summary>本地字节的来源:<c>proxy</c>(环形缓存)/ <c>file</c>(本地文件)/ <c>none</c>。</summary>
    public string Kind { get; private set; } = "none";

    /// <summary>图到了要重画气泡 —— 取数是异步的,回来时鼠标还停在那儿。</summary>
    public System.Action? Changed;

    /// <summary>最近一次取不到图的原因。自检和日志用,不给用户看。</summary>
    public string? LastWhy { get; private set; }

    /// <summary>已经拿到手的张数(自检用)。</summary>
    public int Have
    {
        get => _got.Count;
    }

    /// <summary>从 <c>player.status</c> 的 <c>cached</c> 字段更新区间。</summary>
    public void SetSpans(JsonElement st)
    {
        if (st.TryGetProperty("cached_kind", out var k) && k.GetString() is { } ks) Kind = ks;
        if (!st.TryGetProperty("cached", out var c) || c.ValueKind != JsonValueKind.Array)
        {
            if (Spans.Count > 0) Spans = [];
            return;
        }
        var list = new List<(double, double)>();
        foreach (var sp in c.EnumerateArray())
        {
            if (sp.ValueKind != JsonValueKind.Array || sp.GetArrayLength() < 2) continue;
            list.Add((sp[0].GetDouble(), sp[1].GetDouble()));
        }
        Spans = list;
    }

    /// <summary>这个时间点的字节在不在本地。进度条画「哪一段有缩略图」用它。</summary>
    public bool Cached(double pos)
    {
        if (Duration <= 0) return false;
        var f = pos / Duration;
        foreach (var (a, b) in Spans) if (f >= a && f < b) return true;
        return false;
    }

    public int SlotOf(double pos)
    {
        if (Duration <= 0) return -1;
        var i = (int)(pos / Duration * Slots);
        return i < 0 ? 0 : i >= Slots ? Slots - 1 : i;
    }

    /// <summary>
    /// 取这个位置的缩略图。<b>不阻塞</b>:手上有就给,没有就发一次请求,回来时叫 <see cref="Changed"/>。
    /// </summary>
    public Bitmap? At(double pos)
    {
        var slot = SlotOf(pos);
        if (slot < 0) return null;
        if (_got.TryGetValue(slot, out var b)) return b;
        // 没缓存的位置连问都不问:那一趟必然失败,而失败要走一遍 mpv 的 seek 超时。
        if (!Cached(pos)) return null;
        if (slot == _inflight) return null;   // 正在解它
        if (_failedAt.TryGetValue(slot, out var t) &&
            System.Environment.TickCount64 - t < RetryAfterMs) return null;
        // 顶掉排队位上那一格 —— 它是鼠标划过去时留下的,已经没人要了
        _queued = slot;
        _queuedPos = (slot + 0.5) / Slots * Duration;
        if (_inflight < 0) _ = Pump();
        return null;
    }

    /// <summary>一次解一张,解完看排队位上还有没有新的。空了就停。</summary>
    private async System.Threading.Tasks.Task Pump()
    {
        while (_queued >= 0)
        {
            var slot = _queued;
            var pos = _queuedPos;
            _queued = -1;
            _inflight = slot;
            try { await Fetch(slot, pos); }
            finally { _inflight = -1; }
        }
    }

    private async System.Threading.Tasks.Task Fetch(int slot, double pos)
    {
        Bitmap? bmp = null;
        try
        {
            Asked++;
            var r = await core.PlayerThumbnail(new { position = pos });
            if (r.TryGetProperty("available", out var av) && av.ValueKind == JsonValueKind.True &&
                r.TryGetProperty("jpeg", out var j) && j.GetString() is { Length: > 0 } b64)
            {
                using var ms = new MemoryStream(System.Convert.FromBase64String(b64));
                bmp = new Bitmap(ms);
            }
            else if (r.TryGetProperty("why", out var why))
            {
                LastWhy = why.GetString();
            }
        }
        catch (System.Exception e)
        {
            LastWhy = e.Message;
        }
        if (bmp is null)
        {
            _failedAt[slot] = System.Environment.TickCount64;
        }
        else
        {
            _failedAt.Remove(slot);
            _got[slot] = bmp;
            _order.Enqueue(slot);
            while (_order.Count > Keep)
            {
                var old = _order.Dequeue();
                if (old != slot) _got.Remove(old);
            }
        }
        Changed?.Invoke();
    }

    /// <summary>换片了:手上这些图和新片没关系。</summary>
    public void Reset()
    {
        _got.Clear();
        _order.Clear();
        _queued = -1;
        _failedAt.Clear();
        Spans = [];
        LastWhy = null;
    }
}
