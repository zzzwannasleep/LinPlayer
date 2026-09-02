using System.Collections.Concurrent;
using System.Diagnostics;
using Avalonia.Threading;

namespace LinPlayer.Desktop.Core;

/// <summary>
/// 性能仪表。<c>LP_PERF=1</c> 打开,平时一行代码都不跑。
///
/// <para>★★ 建这个是因为「软件响应慢」和「动效卡」这两句话<b>指不到具体位置</b>。
/// 慢在网络、慢在解码、还是慢在 UI 线程被占住,改法完全不同 ——
/// 而这三种在用户那边看起来一模一样。</para>
///
/// <para>★ <b>卡顿必须单独量</b>。命令耗时长不代表卡:那是在后台等。
/// 真正让人觉得卡的是 <b>UI 线程被占住的那几十毫秒</b> ——
/// 那期间动画不推进、鼠标点了没反应。所以这里有一个专门的掉帧探针。</para>
/// </summary>
public static class Perf
{
    public static readonly bool On = Environment.GetEnvironmentVariable("LP_PERF") == "1";

    private static readonly Stopwatch Clock = Stopwatch.StartNew();
    private static readonly ConcurrentQueue<string> Lines = new();

    /// <summary>进程启动以来的毫秒数。所有时间戳都以它为准,便于把几条线对齐读。</summary>
    public static double Ms => Clock.Elapsed.TotalMilliseconds;

    public static void Log(string line)
    {
        if (!On) return;
        var s = $"[perf {Ms,8:0} ms] {line}";
        Lines.Enqueue(s);
        Console.WriteLine(s);
    }

    /// <summary>计一段耗时。<c>using var _ = Perf.Span("...")</c>。</summary>
    public static Span Measure(string what) => new(what);

    public readonly struct Span(string what) : IDisposable
    {
        private readonly double _t0 = On ? Ms : 0;
        public void Dispose()
        {
            if (On) Log($"{what} 用了 {Ms - _t0:0.0} ms");
        }
    }

    /// <summary>
    /// 掉帧探针:每 16ms 排一个空活儿到 UI 线程,记录它<b>实际</b>什么时候被执行。
    ///
    /// <para>★ 差值就是 UI 线程被占住的时长。超过 <paramref name="thresholdMs"/> 才记 ——
    /// 全记的话日志里全是 16、17、16,真正的那几次 300ms 会淹掉。</para>
    ///
    /// <para>★ 用 <see cref="DispatcherPriority.Background"/>:它排在渲染和输入<b>后面</b>,
    /// 所以它被拖延 = 前面真的有活儿堵着,而不是探针自己插队插不进去。</para>
    /// </summary>
    private static int _jankCount;
    private static double _jankWorst, _jankTotal;

    /// <param name="thresholdMs">
    /// ★★ <b>不能设成 32</b>。Windows 的默认定时器分辨率是 15.6ms,
    /// 一个 16ms 的 DispatcherTimer 只能落在 15.6 的整数倍上 —— 要么 15.6 要么 31.2。
    /// 设 32 的话,应用**完全空闲**时也会每隔几十毫秒报一次「被占住 33ms」:
    /// 一次运行报出 85 次,其中 80 次是探针在量自己。
    /// 噪音不是无害的,它会把那几次真的 400ms 淹掉,而且让人以为已经很糟了。
    /// 50ms(≈3 帧)以上才是肉眼分得出来的停顿。
    /// </param>
    public static void WatchJank(double thresholdMs = 50)
    {
        if (!On) return;
        var last = Ms;
        var timer = new DispatcherTimer(TimeSpan.FromMilliseconds(16), DispatcherPriority.Background, (_, _) =>
        {
            var now = Ms;
            var gap = now - last;
            last = now;
            if (gap < thresholdMs) return;
            _jankCount++;
            _jankTotal += gap;
            if (gap > _jankWorst) _jankWorst = gap;
            Log($"⚠ UI 线程被占住 {gap:0} ms");
        });
        timer.Start();
    }

    /// <summary>
    /// 退出前的汇总。<b>这三个数就是「顺不顺」的判据</b> ——
    /// 次数(打了多少个嗝)、最长(最难受的那一下)、合计(总共有多久是死的)。
    /// 「感觉流畅多了」不是判据。
    /// </summary>
    public static void Summary()
    {
        if (!On) return;
        Console.WriteLine($"[perf汇总] 卡顿 {_jankCount} 次,最长 {_jankWorst:0} ms,合计 {_jankTotal:0} ms" +
                          $"(阈值 50ms,运行 {Ms:0} ms)");
    }
}
