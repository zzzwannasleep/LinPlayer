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
/// <para>★★ <b>帧不是这一层产生的</b> —— 它向核心层要(<c>player.thumbnail</c>),
/// 核心层用第二个 <c>vo=null</c> 的 mpv 实例、<b>只读本地已缓存的字节</b>解出来。
/// 上一版是从我们自己渲染过的画面里留一份,那样只有<b>放过的</b>位置才有图;
/// 而用户要的是「已缓存的进度」—— 缓存的恰恰是<b>前面还没放到</b>的那一段。</para>
///
/// <para>★ 「没缓存的不能用」这条规则<b>不在这里判</b>:核心层那条只读端点
/// 对没缓存的区间直接回 416,取不到数就是取不到图。判断和事实分两处写,
/// 迟早会对不上。</para>
/// </summary>
public sealed class Thumbs(CoreClient core)
{
    /// <summary>时间轴分多少格。取图和缓存都按格走 —— 鼠标移动一个像素就发一次请求,
    /// 那是几十次解码;而相邻两像素上的画面根本是同一帧。</summary>
    public const int Slots = 300;

    /// <summary>缓存多少张。320×180 解出来是 BGRA ≈ 230KB,不设上限的话
    /// 一部长片划一圈就是 60MB 常驻。</summary>
    private const int Keep = 60;

    private readonly Dictionary<int, Bitmap?> _got = new(); // null = 问过了,那儿没有
    private readonly Queue<int> _order = new();
    private readonly HashSet<int> _busy = [];

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
        get { var n = 0; foreach (var v in _got.Values) if (v is not null) n++; return n; }
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
        // ★ 没缓存的位置连问都不问:那一趟必然失败,而失败要走一遍 mpv 的 seek 超时。
        if (!Cached(pos) || !_busy.Add(slot)) return null;
        _ = Fetch(slot, (slot + 0.5) / Slots * Duration);
        return null;
    }

    private async System.Threading.Tasks.Task Fetch(int slot, double pos)
    {
        Bitmap? bmp = null;
        try
        {
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
        _got[slot] = bmp;
        _order.Enqueue(slot);
        while (_order.Count > Keep)
        {
            var old = _order.Dequeue();
            if (old != slot) _got.Remove(old);
        }
        _busy.Remove(slot);
        Changed?.Invoke();
    }

    /// <summary>换片了:手上这些图和新片没关系。</summary>
    public void Reset()
    {
        _got.Clear();
        _order.Clear();
        _busy.Clear();
        Spans = [];
        LastWhy = null;
    }
}
