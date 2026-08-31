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
/// </summary>
public static class Images
{
    private static readonly HttpClient Http = new() { Timeout = TimeSpan.FromSeconds(30) };
    private static readonly ConcurrentDictionary<string, Task<Bitmap?>> Inflight = new();

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
        // 同一张图并发请求合流:一屏几十张卡里同一部剧可能出现好几次
        return Inflight.GetOrAdd(url, u => Fetch(core, u));
    }

    private static async Task<Bitmap?> Fetch(CoreClient core, string url)
    {
        try
        {
            using var req = new HttpRequestMessage(HttpMethod.Get, url);
            // ★ 图片通道走请求头鉴权(给 mpv 吃的那几条路才把 token 放 URL 里)
            req.Headers.Add("X-LP-Token", core.LocalToken);
            using var resp = await Http.SendAsync(req);
            if (!resp.IsSuccessStatusCode) return null;
            await using var s = await resp.Content.ReadAsStreamAsync();
            var ms = new MemoryStream();
            await s.CopyToAsync(ms);
            ms.Position = 0;
            return new Bitmap(ms);
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
}
