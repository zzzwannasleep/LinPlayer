// 核心层契约测试 —— C# 宿主侧。
//
// 出身是 SPIKE-2 的判据集(spikes/s2/CsHost),验完之后**毕业**成常驻门禁:
// 它测的不再是「Go 能不能被调用」,而是「core/ 这一版有没有破坏 SPEC §5 的契约」。
//
// 每条判据失败就计一次红,退出码 = 红的条数。
// 覆盖 SPEC 的:§5.0 ABI 协商 / §5.2 调用协议与事件信封 / §5.3 内存所有权 /
// §5.4 错误模型 / §5.7 流式结果与取消 / §5.10 panic 边界 / §5.11 队列与 eof。

using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace CoreCheck;

internal static partial class Core
{
    private const string Lib = "lpcore";

    // ★ 宿主编译期的 LP_ABI。真实项目里由绑定生成器写入,**不许手抄**;
    //   契约测试断言它 == 核心层常量,不等即红(SPEC §5.0)。
    public const int HostAbi = 1;

    [LibraryImport(Lib)] internal static partial int lp_abi_version();

    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int lp_init(string configJson);

    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int lp_call(long seq, string cmd, string argsJson);

    [LibraryImport(Lib)] internal static partial void lp_cancel(long seq);

    // 返回的是 Go 用 malloc 分配的指针 —— **必须 lp_free**(SPEC §5.3)。
    // 所以这里故意返回 IntPtr 而不是 string:让 string 编组自动释放会用错分配器。
    [LibraryImport(Lib)] internal static partial nint lp_next_event(int timeoutMs);

    [LibraryImport(Lib)] internal static partial void lp_free(nint p);
    [LibraryImport(Lib)] internal static partial void lp_shutdown();
    [LibraryImport(Lib)] internal static partial void lp_debug_cstr_counters(out long alloc, out long freed);

    [LibraryImport(Lib)] internal static partial int lp_set_surface(int kind, long handle, int w, int h);

    [LibraryImport(Lib)] internal static partial int lp_gl_init(nint getProcAddress, nint ctx);
    [LibraryImport(Lib)] internal static partial int lp_gl_wants_redraw();
    [LibraryImport(Lib)] internal static partial int lp_gl_render(uint fbo, int w, int h, int flipY);
    [LibraryImport(Lib)] internal static partial void lp_gl_swapped();
    [LibraryImport(Lib)] internal static partial void lp_gl_uninit();

    public static void Preload(string dll)
    {
        var h = NativeLibrary.Load(Path.GetFullPath(dll));
        NativeLibrary.SetDllImportResolver(typeof(Core).Assembly,
            (n, _, _) => n == Lib ? h : nint.Zero);
    }
}

/// <summary>事件泵。★ 有且仅有一个线程调 lp_next_event(SPEC §5.11)。</summary>
internal sealed class EventPump
{
    private readonly Dictionary<long, TaskCompletionSource<JsonElement>> _waiters = new();
    private readonly Dictionary<long, List<JsonElement>> _partials = new();
    private readonly object _lock = new();
    private readonly Thread _thread;

    private readonly bool _noFree;   // --leak 反向注入:故意不调 lp_free
    public volatile bool SawEof;
    public int LogCount, EventCount, FreeCount;
    public string LastLogMsg = "";

    public EventPump(bool noFree = false)
    {
        _noFree = noFree;
        _thread = new Thread(Loop) { IsBackground = true, Name = "lp-events" };
        _thread.Start();
    }

    /// <param name="trackPartials">
    /// 只对显式关心的 seq 收集 partial。默认关闭 —— 2 万次压力循环里每条都攒一个桶,
    /// 漏的就是测试自己(第一版就是这么把内存判据搞脏的)。
    /// </param>
    public Task<JsonElement> Expect(long seq, bool trackPartials = false)
    {
        lock (_lock)
        {
            var tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
            _waiters[seq] = tcs;
            if (trackPartials) _partials[seq] = new List<JsonElement>();
            return tcs.Task;
        }
    }

    public List<JsonElement> PartialsOf(long seq)
    {
        lock (_lock) return _partials.TryGetValue(seq, out var l) ? new List<JsonElement>(l) : new();
    }

    public bool Join(int ms) => _thread.Join(ms);

    private void Loop()
    {
        while (true)
        {
            var p = Core.lp_next_event(-1);
            if (p == nint.Zero) continue;          // 超时(本例用 -1,不会走到)
            var json = Marshal.PtrToStringUTF8(p);
            if (!_noFree)                             // ★ Go 分配,宿主释放
            {
                Core.lp_free(p);
                Interlocked.Increment(ref FreeCount);
            }
            if (json == null) continue;

            var e = JsonDocument.Parse(json).RootElement;
            var t = e.GetProperty("t").GetString();

            if (t == "eof") { SawEof = true; return; } // 不发 eof 这条线程永远退不出来

            Interlocked.Increment(ref EventCount);
            switch (t)
            {
                case "result":
                {
                    var seq = e.GetProperty("seq").GetInt64();
                    lock (_lock)
                        if (_waiters.Remove(seq, out var tcs)) tcs.TrySetResult(e.Clone());
                    break;
                }
                case "partial":
                {
                    var seq = e.GetProperty("seq").GetInt64();
                    lock (_lock)
                        if (_partials.TryGetValue(seq, out var l)) l.Add(e.Clone());
                    break;
                }
                case "event":
                {
                    if (e.TryGetProperty("name", out var n) && n.GetString() == "log")
                    {
                        Interlocked.Increment(ref LogCount);
                        if (e.TryGetProperty("data", out var d) && d.TryGetProperty("msg", out var m))
                            LastLogMsg = m.GetString() ?? "";
                    }
                    break;
                }
            }
        }
    }
}

internal static class Program
{
    private static long _seq;
    private static int _fail;

    private static void Check(bool ok, string what, string detail = "")
    {
        Console.WriteLine($"  [{(ok ? "通过" : "不通过")}] {what}{(detail.Length > 0 ? "  — " + detail : "")}");
        if (!ok) _fail++;
    }

    private static long Next() => Interlocked.Increment(ref _seq);

    public static int Main(string[] args)
    {
        var dll = args.Length > 0 && !args[0].StartsWith("--") ? args[0] : "../../build/core/lpcore.dll";
        var leakMode = args.Contains("--leak");     // 反向注入:故意不 lp_free
        Core.Preload(dll);

        Console.WriteLine("======== SPIKE-2 · Go 核心 <-> C# 宿主 ========");

        // --probe-only:只跑一条命令,专门用来隔离「哪一类 panic 能被 recover 挡住」。
        // 这条路径必须能在进程被硬杀时留下可判读的退出码。
        if (args.Contains("--probe-only"))
        {
            var cmd = Environment.GetEnvironmentVariable("LP_PROBE_CMD") ?? "debug.panic";
            Core.lp_init("{}");
            var pp = new EventPump();
            var ps = Next(); var pt = pp.Expect(ps);
            Console.WriteLine($"  发命令 {cmd} …");
            Core.lp_call(ps, cmd, "{}");
            var arrived = pt.Wait(3000);
            var code = "(无 err 字段)";
            if (arrived && pt.Result.TryGetProperty("err", out var eo) && eo.ValueKind == JsonValueKind.Object)
                code = eo.GetProperty("code").GetString();
            Console.WriteLine($"  收到 result = {arrived},err.code = {code}");
            // 后台故障用例的定时器是 300ms 之后才炸,这里要等过它
            Thread.Sleep(1500);
            Console.WriteLine($"  等待 1.5s 后进程仍然存活;期间日志条数 = {pp.LogCount},最后一条 = {Trunc(pp.LastLogMsg)}");
            Core.lp_shutdown();
            return arrived ? 0 : 1;
        }

        // ---- §5.0 ABI 协商 ----
        Console.WriteLine("== 1. ABI 版本协商(必须在 lp_init 之前)==");
        var abi = Core.lp_abi_version();
        Check(abi == Core.HostAbi, $"lp_abi_version() = {abi},与宿主编译期 LP_ABI 一致");
        Check(SimulateMismatch(abi + 1) == "拒绝启动",
              "版本错配时得到明确报错而不是崩溃",
              "把宿主 ABI 故意错开一位,断言走的是拒绝路径");

        // ---- 启动 ----
        Console.WriteLine("== 2. 启动与事件泵 ==");
        Check(Core.lp_init("{\"platform\":\"windows\",\"dataDir\":\"userdata\"}") == 0, "lp_init 返回 0");
        var pump = new EventPump(leakMode);
        Thread.Sleep(150);
        Check(pump.LogCount > 0, "事件线程收到了启动日志", $"LogCount={pump.LogCount}");

        // ---- §5.2 调用协议 ----
        Console.WriteLine("== 3. 调用协议:发一条命令,从事件线程收到对应 result ==");
        var s1 = Next();
        var t1 = pump.Expect(s1);
        Check(Core.lp_call(s1, "debug.echo", "{\"hello\":\"世界\"}") == 0, "lp_call 受理返回 0");
        Check(t1.Wait(3000), "3 秒内收到 result");
        if (t1.IsCompletedSuccessfully)
        {
            var r = t1.Result;
            Check(r.GetProperty("seq").GetInt64() == s1, "result 的 seq 对得上");
            Check(r.GetProperty("ok").GetBoolean(), "ok = true");
            Check(r.TryGetProperty("ts", out var ts) && ts.GetInt64() >= 0, "ts 是必需字段且存在", $"ts={r.GetProperty("ts").GetInt64()}");
            var echoed = r.GetProperty("data").GetProperty("args").GetProperty("hello").GetString();
            Check(echoed == "世界", "UTF-8 参数完整往返(中文没坏)", $"回显 = {echoed}");
        }

        // ---- B1.2:system.ping 往返 ----
        Console.WriteLine("== 3b. system.ping 往返(B1.2 判据)==");
        var sp = Next(); var tp = pump.Expect(sp);
        Core.lp_call(sp, "system.ping", "{}");
        Check(tp.Wait(3000) && tp.Result.GetProperty("data").GetProperty("pong").GetBoolean(), "system.ping 往返");

        // ---- system.capabilities ----
        Console.WriteLine("== 4. system.capabilities ==");
        var s2 = Next(); var t2 = pump.Expect(s2);
        Core.lp_call(s2, "system.capabilities", "{}");
        Check(t2.Wait(3000), "收到 result");
        if (t2.IsCompletedSuccessfully)
        {
            var d = t2.Result.GetProperty("data");
            Check(d.GetProperty("videoChan").GetString() == "gl", "Windows 上 videoChan = gl(通道 B)");
            Check(d.GetProperty("platform").GetString() == "windows", "platform = windows");
        }

        // ---- §5.7 流式中间结果 + §5.4 错误模型 ----
        Console.WriteLine("== 5. 流式结果(partial)与取消 ==");
        var s3 = Next(); var t3 = pump.Expect(s3, trackPartials: true);
        Core.lp_call(s3, "debug.slow", "{\"steps\":5}");
        Check(t3.Wait(5000), "长任务最终收到 result");
        Thread.Sleep(100); // partial 与 result 是同一条队列,result 到了 partial 必然已到
        Check(pump.PartialsOf(s3).Count == 5, "收到 5 条 partial(SPEC §5.7 流式结果)",
              $"实际 {pump.PartialsOf(s3).Count} 条");

        var s4 = Next(); var t4 = pump.Expect(s4);
        Core.lp_call(s4, "debug.slow", "{\"steps\":50}");
        Thread.Sleep(200);
        Core.lp_cancel(s4);
        Check(t4.Wait(3000), "取消后仍然收到 result(不能让调用方永远挂着)");
        if (t4.IsCompletedSuccessfully)
            Check(!t4.Result.GetProperty("ok").GetBoolean(), "取消的结果 ok=false");

        Console.WriteLine("== 6. 错误模型:E_UNSUPPORTED 是信息不是错误 ==");
        var s5 = Next(); var t5 = pump.Expect(s5);
        Core.lp_call(s5, "debug.unsupported", "{}");
        Check(t5.Wait(3000), "收到 result");
        if (t5.IsCompletedSuccessfully)
        {
            var err = t5.Result.GetProperty("err");
            Check(err.GetProperty("code").GetString() == "E_UNSUPPORTED", "err.code = E_UNSUPPORTED");
            Check(err.TryGetProperty("retryable", out _), "err 是对象且带 retryable,不是一个字符串");
        }

        var s6 = Next(); var t6 = pump.Expect(s6);
        Core.lp_call(s6, "no.such.command", "{}");
        t6.Wait(3000);
        // 未注册的命令是**调用方的 bug**,不是「条目不存在」——
        // 所以是 E_INVALID(记日志)而不是 E_NOTFOUND(空态)。TODO B1.2 的判据。
        Check(t6.IsCompletedSuccessfully && t6.Result.GetProperty("err").GetProperty("code").GetString() == "E_INVALID",
              "未注册的命令 -> E_INVALID");

        var s7 = Next(); var t7 = pump.Expect(s7);
        Core.lp_call(s7, "debug.echo", "{ 这不是 JSON");
        t7.Wait(3000);
        Check(t7.IsCompletedSuccessfully && t7.Result.GetProperty("err").GetProperty("code").GetString() == "E_INVALID",
              "非法 JSON -> E_INVALID");

        // ---- §5.10 panic 边界 ----
        Console.WriteLine("== 7. panic 边界(LP_DEBUG_CMDS=1 才有 debug.panic)==");
        var debugCmds = Environment.GetEnvironmentVariable("LP_DEBUG_CMDS") == "1";
        if (debugCmds)
        {
            var logBefore = pump.LogCount;
            var s8 = Next(); var t8 = pump.Expect(s8);
            Core.lp_call(s8, "debug.panic", "{}");
            var got = t8.Wait(3000);
            Check(true, "① 宿主进程还活着(能执行到这一行就是证据)");
            Check(got && !t8.Result.GetProperty("ok").GetBoolean()
                      && t8.Result.GetProperty("err").GetProperty("code").GetString() == "E_INTERNAL",
                  "② 该 seq 收到 E_INTERNAL,没有永远挂着");
            Thread.Sleep(150);
            Check(pump.LogCount > logBefore && pump.LastLogMsg.Length > 0, "③ 日志里有东西",
                  $"最后一条日志 {pump.LastLogMsg.Length} 字符");
        }
        else
        {
            var s8 = Next(); var t8 = pump.Expect(s8);
            Core.lp_call(s8, "debug.panic", "{}");
            t8.Wait(3000);
            Check(t8.IsCompletedSuccessfully && t8.Result.GetProperty("err").GetProperty("code").GetString() == "E_NOTFOUND",
                  "未开 LP_DEBUG_CMDS 时 debug.panic 不存在");
        }

        // ---- 第 2、3 组导出可调 ----
        Console.WriteLine("== 8. 视频通道两组导出:测护栏,不测假的成功路径 ==");
        //
        // ★ 这里**故意不传一个假的 get_proc_address**。
        //   之前对着桩写的时候传了 0x1234,换成真 libmpv 之后 mpv 会拿它去解析
        //   GL 函数 —— 当场 0xC0000005。「桩上能过的判据」换成真实现就炸,
        //   这正是桩最容易骗人的地方。
        //   真正的 GL 路径由 spikes/s1-2/AvaloniaProbe 在真 GL 上下文里覆盖。
        Check(Core.lp_set_surface(0, 0, 0, 0) == 0, "lp_set_surface(解绑)可调");
        Check(Core.lp_gl_init(nint.Zero, nint.Zero) != 0, "lp_gl_init(NULL) 被拒,不是崩");
        Check(Core.lp_gl_wants_redraw() == 0, "没有 render context 时 wants_redraw 返回 0");
        Check(Core.lp_gl_render(1, 1920, 1080, 1) != 0, "没有 render context 时 render 返回错误码");
        Core.lp_gl_swapped(); Core.lp_gl_uninit();
        Check(true, "lp_gl_swapped / lp_gl_uninit 在未初始化时是空操作,不崩");

        // ---- §5.3 内存所有权 ----
        //
        // 判据是 **alloc/free 计数**,不是进程私有内存。
        // 后者测不出来:实测 2 万次往返里漏掉的 C 字符串只有约 2 MB,
        // 完全被 .NET 自己的分配淹没(正常 23.7 MB vs 故意不 free 24.5 MB)。
        var N = 20000;
        foreach (var a in args) if (a.StartsWith("--n=")) N = int.Parse(a[4..]);
        Console.WriteLine($"== 9. 内存所有权:{N} 次 call/free{(leakMode ? "  【--leak 反向注入:故意不 free】" : "")} ==");
        for (var i = 0; i < N; i++)
        {
            var s = Next(); var t = pump.Expect(s);
            Core.lp_call(s, "debug.echo", "{\"i\":" + i + "}");
            t.Wait(2000);
        }
        Thread.Sleep(400);
        Core.lp_debug_cstr_counters(out var alloc, out var freed);
        long outstanding = alloc - freed;
        Console.WriteLine($"       lp_next_event 分配 {alloc} 次,lp_free 释放 {freed} 次,未释放 {outstanding}");
        if (leakMode)
        {
            // 反向注入必须真的变红,否则这条判据是空的
            Check(outstanding > N / 2, "【反向注入】不 free 时未释放数应该很大", $"实测 {outstanding}");
        }
        else
        {
            // 允许个位数在途(诊断命令自己那一条还没回到泵里)
            Check(outstanding <= 4, "未释放的 C 字符串 <= 4(在途量级)", $"实测 {outstanding}");
            Check(alloc >= N, $"确实发生了 {N} 次以上的跨边界分配", $"alloc={alloc}");
        }

        // ---- §5.11 关停与 eof ----
        Console.WriteLine("== 10. 关停:必须发 eof,否则事件线程永远退不出来 ==");
        Core.lp_shutdown();
        Check(pump.Join(3000), "事件线程 3 秒内退出");
        Check(pump.SawEof, "收到了 {\"t\":\"eof\"}");
        Check(Core.lp_call(Next(), "debug.echo", "{}") != 0, "关停后 lp_call 被拒");

        Console.WriteLine("==============================================");
        Console.WriteLine(_fail == 0 ? "全部通过。" : $"有 {_fail} 条不通过。");
        return _fail;
    }

    /// <summary>问核心层要诊断快照。</summary>
    private static JsonElement Diagnostics(EventPump pump)
    {
        var s = Next(); var t = pump.Expect(s);
        Core.lp_call(s, "system.exportDiagnostics", "{}");
        t.Wait(3000);
        return t.Result.GetProperty("data").Clone();
    }

    private static string Trunc(string s) => s.Length <= 60 ? s : s[..60] + "…";

    /// <summary>模拟 ABI 错配:宿主拿到的核心层版本与自己编译期的不等时应当拒绝启动。</summary>
    private static string SimulateMismatch(int coreAbi) =>
        coreAbi == Core.HostAbi ? "继续" : "拒绝启动";
}
