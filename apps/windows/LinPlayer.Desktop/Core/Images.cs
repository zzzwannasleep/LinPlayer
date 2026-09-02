using System.Collections.Concurrent;
using Avalonia.Media.Imaging;
using Avalonia.Threading;

namespace LinPlayer.Desktop.Core;

/// <summary>
/// 封面加载。
///
/// <para>★★ 图片<b>不过 FFI、也不过命令队列</b> —— 走核心层的本地 HTTP 数据通道
/// (<c>/img?src=…</c>,SPEC §6)。一屏几十张封面如果走命令队列,
/// 就等于把几十 MB 的字节塞进事件队列里排队,把命令通道整个堵死。</para>
///
/// <para>★ 上游地址由这里拼,但<b>凭据不进 URL</b>:核心层按 origin 查白名单,
/// 取图时自己带 <c>X-Emby-Token</c>。所以缓存键里没有 token ——
/// 重登一次 token 变了,整盘缓存不会作废。</para>
///
/// <para>★★ <b>三条规矩,少一条就会「响应慢」而且查不出来</b>:
/// ①每个 await 都 <c>ConfigureAwait(false)</c>;②按显示高度解码;③解好的位图留住。
/// 见下面各自的注释。</para>
/// </summary>
public static class Images
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private static readonly ConcurrentDictionary<string, Task<Bitmap?>> Inflight = new();

    /// <summary>
    /// 解好的位图留一份。
    ///
    /// <para>★★ 核心层那两层缓存存的是<b>压缩字节</b>,省的是回源;
    /// 而每次翻回首页仍然要重走一遍「本地 HTTP + 解码」。解码是 UI 侧的成本,
    /// 核心层再快也省不掉 —— 这一层省的就是它。</para>
    ///
    /// <para>★ 按<b>张数</b>封顶而不是字节数:位图尺寸是我们自己按显示高度定的
    /// (下面 DecodeToHeight),每张的量级已知,数张数就够,不必为了精确
    /// 去追每张的实际占用。400 张 ≈ 60 MB,够铺满好几页网格。</para>
    /// </summary>
    private const int CacheMax = 400;

    private static readonly object CacheLock = new();
    private static readonly Dictionary<string, (Bitmap Bmp, long Used)> Cache = new();
    private static long _tick;

    /// <summary>
    /// 拼一条 Emby 图片地址。<paramref name="kind"/> 只认 Primary / Backdrop / Logo。
    /// </summary>
    /// <summary>★ 尺寸交给 /img 的 h=,别写进 src —— 写进去等于每种尺寸一个缓存键。</summary>
    public static string EmbyImageUrl(string server, string itemId, string kind)
    {
        // ★ Backdrop 要带序号,Primary/Logo 不带 —— 不带的话某些 fork 直接 404
        var seg = kind == "Backdrop" ? "Backdrop/0" : kind;
        return $"{server.TrimEnd('/')}/Items/{itemId}/Images/{seg}?quality=90";
    }

    /// <summary>经由本地数据通道取一张图。取不到返回 null —— <b>调用方要能画出「没有图」那一版</b>。</summary>
    public static Task<Bitmap?> LoadAsync(CoreClient core, string upstreamUrl, int maxHeight)
    {
        if (string.IsNullOrEmpty(core.LocalBaseUrl) || string.IsNullOrEmpty(upstreamUrl))
            return Task.FromResult<Bitmap?>(null);

        var url = $"{core.LocalBaseUrl}/img?src={Uri.EscapeDataString(upstreamUrl)}&h={maxHeight}";

        // ★ 命中已解码的:**同步返回**,一次 await 都不排。翻回上一页时整屏封面当场就在。
        lock (CacheLock)
        {
            if (Cache.TryGetValue(url, out var hit))
            {
                Cache[url] = (hit.Bmp, ++_tick);
                return Task.FromResult<Bitmap?>(hit.Bmp);
            }
        }

        // 同一张图并发请求合流:一屏几十张卡里同一部剧可能出现好几次
        return Inflight.GetOrAdd(url, u => Fetch(core, u, maxHeight));
    }

    private static async Task<Bitmap?> Fetch(CoreClient core, string url, int maxHeight)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            // ★ 图片通道走请求头鉴权(给 mpv 吃的那几条路才把 token 放 URL 里)
            req.Headers.Add("X-LP-Token", core.LocalToken);

            var t0 = Perf.Ms;
            /* ★★ 每个 await 都必须 ConfigureAwait(false)。
               这个方法是被**卡片构造函数**发起的,而卡片在 UI 线程上构造 ——
               不写的话每个 await 的续体都回到 UI 线程,于是:
                 · 解码在 UI 线程上做(一屏几十张 = UI 线程连续被占几百毫秒)
                 · 动画在这期间**不推进**,鼠标点了没反应 —— 这就是「卡顿不跟手」
                 · 连测出来的耗时都是假的:实测 localhost 上一张 0KB 的图「取了 103ms」,
                   那 103ms 全是在排队等 UI 线程,不是网络
               它不报错、不崩,只是整个应用变慢。 */
            using var resp = await Http.SendAsync(req).ConfigureAwait(false);
            if (!resp.IsSuccessStatusCode) return null;
            await using var s = await resp.Content.ReadAsStreamAsync().ConfigureAwait(false);
            var ms = new MemoryStream();
            await s.CopyToAsync(ms).ConfigureAwait(false);
            ms.Position = 0;

            var t1 = Perf.Ms;
            /* ★★ 按**显示高度**解码,不要全尺寸解。
               `new Bitmap(stream)` 解出来的是原图分辨率 —— 一张 1000×1500 的海报
               画在 158×237 的槽里,白解了 40 倍的像素,还占着 6 MB 内存。
               而 maxHeight 是给上游的**建议**:实测某 fork 完全无视 maxWidth,
               所以「服务器会帮我们缩」这件事**不能当前提**,自己这一刀必须落。 */
            var bmp = DecodeToHeight(ms, maxHeight);
            if (Perf.On)
                Perf.Log($"图 取{t1 - t0:0}ms 解码{Perf.Ms - t1:0}ms {ms.Length / 1024}KB " +
                         $"→{bmp.PixelSize.Width}x{bmp.PixelSize.Height} " +
                         $"线程={(Dispatcher.UIThread.CheckAccess() ? "★UI★" : "后台")}");

            Remember(url, bmp);
            return bmp;
        }
        catch
        {
            // 取不到图**不是错误** —— 没刮削封面的库很常见,画占位就行
            return null;
        }
        finally
        {
            Inflight.TryRemove(url, out _);
        }
    }

    /// <summary>
    /// 解码到目标高度。图本来就比目标矮就原样解 ——
    /// <b>放大不是缩放器的活</b>,那只会解出一张更糊也更大的图。
    /// </summary>
    private static Bitmap DecodeToHeight(MemoryStream ms, int maxHeight)
    {
        if (maxHeight <= 0) return new Bitmap(ms);
        try
        {
            var bmp = Bitmap.DecodeToHeight(ms, maxHeight, BitmapInterpolationMode.HighQuality);
            return bmp;
        }
        catch
        {
            // 某些格式解码器不支持指定高度。回落成原样解 —— 慢一点总比不显示强。
            ms.Position = 0;
            return new Bitmap(ms);
        }
    }

    /// <summary>放进缓存,超了就把最久没用的挤掉。</summary>
    private static void Remember(string url, Bitmap bmp)
    {
        lock (CacheLock)
        {
            Cache[url] = (bmp, ++_tick);
            if (Cache.Count <= CacheMax) return;
            /* ★ 一次挤掉 1/4 而不是刚好一张:卡着上限的话之后**每存一张都要扫一遍**,
               扫描成本摊到每一次写入上。挤一批,下次扫描要等很久才来。
               ★ 挤掉的位图**不 Dispose** —— 屏幕上可能还有 Image 正指着它,
                 Dispose 掉就是当场少一张图(而且不报错)。交给 GC。 */
            foreach (var k in Cache.OrderBy(kv => kv.Value.Used).Take(CacheMax / 4).Select(kv => kv.Key).ToList())
                Cache.Remove(k);
        }
    }
}
