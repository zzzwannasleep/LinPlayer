using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using LinPlayer.Core;

namespace LinPlayer.Desktop.Core;

/// <summary>
/// 核心层的 13 个 C ABI 导出。**这是 UI 与业务之间唯一的边界**(SPEC §5.1)。
/// </summary>
internal static partial class Native
{
    private const string Lib = "lpcore";

    [LibraryImport(Lib)] internal static partial int lp_abi_version();

    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int lp_init(string configJson);

    [LibraryImport(Lib, StringMarshalling = StringMarshalling.Utf8)]
    internal static partial int lp_call(long seq, string cmd, string argsJson);

    [LibraryImport(Lib)] internal static partial void lp_cancel(long seq);

    // ★ 返回的是核心层用 malloc 分配的指针 —— **必须 lp_free**(SPEC §5.3)。
    //   所以这里故意返回 nint 而不是 string:让 string 编组自动释放会用错分配器,
    //   表现是随机崩溃,而且崩在与它无关的地方。
    [LibraryImport(Lib)] internal static partial nint lp_next_event(int timeoutMs);

    [LibraryImport(Lib)] internal static partial void lp_free(nint p);
    [LibraryImport(Lib)] internal static partial void lp_shutdown();

    [LibraryImport(Lib)] internal static partial int lp_set_surface(int kind, long handle, int w, int h);

    [LibraryImport(Lib)] internal static partial int lp_gl_init(nint getProcAddress, nint ctx);
    [LibraryImport(Lib)] internal static partial int lp_gl_wants_redraw();
    [LibraryImport(Lib)] internal static partial int lp_gl_render(uint fbo, int w, int h, int flipY);
    [LibraryImport(Lib)] internal static partial void lp_gl_swapped();
    [LibraryImport(Lib)] internal static partial void lp_gl_uninit();

    /// <summary>把 lpcore.dll 从指定路径预载,之后所有 P/Invoke 都命中它。</summary>
    public static void Preload(string dll)
    {
        var h = NativeLibrary.Load(dll);
        NativeLibrary.SetDllImportResolver(typeof(Native).Assembly,
            (n, _, _) => n == Lib ? h : nint.Zero);
    }
}

/// <summary>核心层抛回来的错误(SPEC §5.4:错误是对象不是字符串)。</summary>
public sealed class CoreException(string code, string message, bool retryable) : Exception(message)
{
    public string Code { get; } = code;
    public bool Retryable { get; } = retryable;

    /// <summary>UI 该怎么处理这个错误(UI_PC §6.3 的映射)。</summary>
    public string Advice => Code switch
    {
        "E_AUTH" => "登录状态失效,请重新登录",
        "E_NETWORK" => "网络不通,可以重试",
        "E_UNSUPPORTED" => "这台服务器或这个平台不支持这项功能",
        "E_NOTFOUND" => "找不到这个内容",
        "E_PERMISSION" => "当前账号没有权限",
        _ => Message,
    };
}

/// <summary>
/// 命令通道 + 事件泵。
///
/// <para>★★ <c>lp_next_event</c> <b>有且仅有一个消费者线程</b>(SPEC §5.6)。
/// 两个线程同时调不是崩溃 —— 是事件被<b>随机分给两个线程</b>,
/// 表现为「有时候收得到有时候收不到」。所以它被封在这里,外面拿不到。</para>
/// </summary>
public sealed class CoreClient : ILinPlayerCommands, IDisposable
{
    private long _seq;
    private readonly ConcurrentDictionary<long, TaskCompletionSource<JsonElement>> _pending = new();
    private readonly Thread _pump;
    private volatile bool _stop;

    /// <summary>主动事件(player.status / log / localserve.ready …)。在事件线程上触发。</summary>
    public event Action<string, JsonElement>? OnEvent;

    /// <summary>本地数据通道的基址与 token(核心层起完服务后由首个事件送来)。</summary>
    public string LocalBaseUrl { get; private set; } = "";
    public string LocalToken { get; private set; } = "";

    public CoreClient(string coreDll, string dataDir, string version)
    {
        Native.Preload(coreDll);

        // ★ ABI 先协商再 init(SPEC §5.0)。旧库里没有这个符号 —— **那件事本身就是信号**。
        var abi = Native.lp_abi_version();
        if (abi != LinPlayerAbi.Version)
            throw new InvalidOperationException(
                $"核心层 ABI 是 {abi},本程序按 {LinPlayerAbi.Version} 编译 —— 版本对不上,不能继续");

        var cfg = JsonSerializer.Serialize(new { dataDir, platform = "windows", version });
        if (Native.lp_init(cfg) != 0)
            throw new InvalidOperationException("核心层初始化失败");

        _pump = new Thread(Pump) { IsBackground = true, Name = "lp-events" };
        _pump.Start();
    }

    /// <summary>发一条命令,等它的 result 事件。</summary>
    public Task<JsonElement> CallAsync(string command, object? args, CancellationToken ct = default)
    {
        var seq = Interlocked.Increment(ref _seq);
        var tcs = new TaskCompletionSource<JsonElement>(TaskCreationOptions.RunContinuationsAsynchronously);
        _pending[seq] = tcs;

        var json = args is null ? "{}" : JsonSerializer.Serialize(args);
        var rc = Native.lp_call(seq, command, json);
        if (rc != 0)
        {
            _pending.TryRemove(seq, out _);
            throw new CoreException("E_INTERNAL", $"命令没发出去({command},rc={rc})", false);
        }
        // ★ 取消要**同时**通知核心层:只丢掉本地的 TCS 的话,核心层那边还在跑,
        //   而它的结果没人收 —— 事件队列会一直堆着。
        if (ct.CanBeCanceled)
            ct.Register(() => { Native.lp_cancel(seq); _pending.TryRemove(seq, out _); tcs.TrySetCanceled(); });
        return tcs.Task;
    }

    private void Pump()
    {
        while (!_stop)
        {
            var p = Native.lp_next_event(200);
            if (p == nint.Zero) continue;
            string json;
            try { json = Marshal.PtrToStringUTF8(p) ?? ""; }
            finally { Native.lp_free(p); } // ★ 一条都不能漏,漏了是稳定增长的内存泄漏
            if (json.Length == 0) continue;

            try { Dispatch(json); }
            catch (Exception e) { Debug.WriteLine($"[事件线程] 处理事件出错(已吞): {e}"); }
        }
    }

    private void Dispatch(string json)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var t = root.TryGetProperty("t", out var tv) ? tv.GetString() : null;

        switch (t)
        {
            case "result":
                {
                    var seq = root.GetProperty("seq").GetInt64();
                    if (!_pending.TryRemove(seq, out var tcs)) return; // 已取消
                    if (root.TryGetProperty("ok", out var ok) && ok.GetBoolean())
                    {
                        tcs.TrySetResult(root.TryGetProperty("data", out var d) ? d.Clone() : default);
                    }
                    else
                    {
                        var err = root.TryGetProperty("err", out var e) ? e : default;
                        tcs.TrySetException(new CoreException(
                            Str(err, "code") ?? "E_INTERNAL",
                            Str(err, "msg") ?? "核心层报错",
                            err.ValueKind == JsonValueKind.Object
                                && err.TryGetProperty("retryable", out var r) && r.GetBoolean()));
                    }
                    return;
                }
            case "event":
                {
                    var name = root.TryGetProperty("name", out var n) ? n.GetString() ?? "" : "";
                    var data = root.TryGetProperty("data", out var d) ? d.Clone() : default;
                    if (name == "localserve.ready")
                    {
                        LocalBaseUrl = Str(data, "baseUrl") ?? "";
                        LocalToken = Str(data, "token") ?? "";
                    }
                    OnEvent?.Invoke(name, data);
                    return;
                }
            case "eof":
                // ★ 队列发 EOF 表示核心层要关了 —— 不退出循环的话进程退不干净
                _stop = true;
                return;
        }
    }

    private static string? Str(JsonElement e, string key) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(key, out var v) ? v.GetString() : null;

    public void Dispose()
    {
        _stop = true;
        Native.lp_shutdown();
        _pump.Join(TimeSpan.FromSeconds(3));
    }
}
