using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace LinPlayer.Desktop.Core;

/// <summary>
/// 元数据缓存(命令返回的 JSON)。
///
/// <para>★★ 用户 2026-09-03:「从其他页面待久一点回到首页,首页要加载四五秒。
/// 有缓存直接就零点几秒就打开了」。这一条的真因不在动画也不在图片 ——
/// <b>每次进首页都是一个全新的 HomePage 实例,五条轨道各打一次远端 Emby</b>。
/// 封面那层早就有内存缓存了(<see cref="Images"/>),元数据这层一直没有。</para>
///
/// <para>★★ 口径是 <b>stale-while-revalidate</b>:命中就<b>先把旧的画出来</b>
/// (零往返,当场出现),同时照常发请求,回来再画一次。
/// 只读缓存不刷新的话「看完一集回首页,继续观看还是旧的」——
/// 那比慢更糟,因为它是**错的**。</para>
///
/// <para>★ 落盘是为了冷启动那一次。内存那份进程一关就没了,
/// 而「打开软件第一眼」正是最需要秒开的那一眼。</para>
///
/// <para>☠ <b>只能缓存读命令</b>。写命令(登录 / 改设置 / 上报进度)进了缓存
/// 就是「点了没反应」——所以这里<b>不做横切拦截</b>,由调用点显式给键。</para>
/// </summary>
public static class MetaCache
{
    /// <summary>
    /// 缓存多久算新鲜。过期的<b>照样先画出来</b>,只是必定会被刷新覆盖一次。
    ///
    /// <para>★ 这个值不控制「画不画」,只控制「要不要顺带清掉」——
    /// 一条一周前的缓存也比一片骨架强,反正紧跟着就会被真数据替换。</para>
    /// </summary>
    private static readonly TimeSpan Keep = TimeSpan.FromDays(7);

    /// <summary>盘上最多留几条。★ 按条数,不按字节:每条都是一小段 JSON,量级已知。</summary>
    private const int MaxFiles = 600;

    private static readonly object Lock = new();
    private static readonly Dictionary<string, string> Mem = new();
    private static string _dir = "";
    private static bool _pruned;

    /// <summary>启动时告诉它数据根在哪(<c>userdata/cache/meta</c>)。</summary>
    public static void Init(string dataDir)
    {
        lock (Lock)
        {
            _dir = Path.Combine(dataDir, "cache", "meta");
            try { Directory.CreateDirectory(_dir); } catch { _dir = ""; }
        }
    }

    /// <summary>
    /// 键:命令名 + 参数。
    ///
    /// <para>★★ 参数里<b>有 token</b>(会话四件套是每页显式传的)。token 一变
    /// 整盘缓存就作废了 —— 所以这里把 <c>token</c> 和 <c>device_id</c> 抠掉。
    /// 不抠的话每次重登都等于清空缓存,而重登恰恰是最需要它的时候。</para>
    /// </summary>
    public static string Key(string command, object? args)
    {
        var json = args is null ? "" : JsonSerializer.Serialize(args);
        using var sha = SHA1.Create();
        var raw = command + "|" + Strip(json);
        return command.Replace('.', '_') + "-"
             + Convert.ToHexString(sha.ComputeHash(Encoding.UTF8.GetBytes(raw)))[..16];
    }

    /// <summary>把 token / device_id 从键里抠掉。★ 用最笨的字符串办法,不解析 —— 键只要稳定。</summary>
    private static string Strip(string json)
    {
        foreach (var k in new[] { "token", "device_id" })
        {
            var at = json.IndexOf($"\"{k}\":\"", StringComparison.Ordinal);
            while (at >= 0)
            {
                var start = at + k.Length + 4;
                var end = json.IndexOf('"', start);
                if (end < 0) break;
                json = json[..start] + json[end..];
                at = json.IndexOf($"\"{k}\":\"", start + 1, StringComparison.Ordinal);
            }
        }
        return json;
    }

    /// <summary>
    /// 取一份旧的。没有就返回 null(<c>ValueKind == Undefined</c> 也当没有)。
    ///
    /// <para>★ 内存没有就读盘,读到了顺手回填内存 —— 同一次会话里第二次进这一页
    /// 就不必再碰磁盘。</para>
    /// </summary>
    public static JsonElement? Peek(string key)
    {
        string? json;
        lock (Lock)
        {
            if (!Mem.TryGetValue(key, out json))
            {
                if (_dir == "") return null;
                try { json = File.ReadAllText(Path.Combine(_dir, key + ".json")); }
                catch { return null; }
                Mem[key] = json;
            }
        }
        try
        {
            using var doc = JsonDocument.Parse(json);
            return doc.RootElement.Clone();
        }
        catch { return null; }
    }

    /// <summary>
    /// 存一份。
    ///
    /// <para>★ 写盘扔到线程池上:它挂在「数据回来了」那一刻,而那一刻 UI 线程
    /// 正要拿这批数据去铺一屏卡片 —— 同步写盘就是在最忙的那一帧上插一次磁盘 IO。</para>
    /// </summary>
    public static void Put(string key, JsonElement value)
    {
        // Undefined / Null 不存:存了之后 Peek 会返回一个「有」但画不出东西的值
        if (value.ValueKind is JsonValueKind.Undefined or JsonValueKind.Null) return;
        var json = value.GetRawText();
        lock (Lock) { Mem[key] = json; }
        if (_dir == "") return;
        _ = Task.Run(() =>
        {
            try
            {
                File.WriteAllText(Path.Combine(_dir, key + ".json"), json);
                Prune();
            }
            catch { /* 缓存写不进去不该影响用 */ }
        });
    }

    /// <summary>
    /// 超量就把最旧的删一批。
    /// <para>★ 一次删四分之一,不是刚好删到上限:卡着上限的话之后<b>每写一条都要扫一遍目录</b>。</para>
    /// <para>★ 一次会话只扫一次 —— 剩下的靠这一次删出来的余量顶着。</para>
    /// </summary>
    private static void Prune()
    {
        lock (Lock) { if (_pruned) return; _pruned = true; }
        try
        {
            var files = new DirectoryInfo(_dir).GetFiles("*.json");
            var old = DateTime.UtcNow - Keep;
            foreach (var f in files.Where(f => f.LastWriteTimeUtc < old)) f.Delete();
            files = new DirectoryInfo(_dir).GetFiles("*.json");
            if (files.Length <= MaxFiles) return;
            foreach (var f in files.OrderBy(f => f.LastWriteTimeUtc).Take(files.Length - MaxFiles * 3 / 4))
                f.Delete();
        }
        catch { /* 同上 */ }
    }

    /// <summary>
    /// 数组版的 <see cref="Peek"/>。页面拿到的多半是「一批条目」,直接给 List 省一次展开。
    /// </summary>
    public static List<JsonElement>? PeekList(string key) =>
        Peek(key) is { ValueKind: JsonValueKind.Array } a ? a.EnumerateArray().ToList() : null;

    /// <summary>数组版的 <see cref="Put"/>。★ 空表也存 —— 「这个库确实没内容」也是结论。</summary>
    public static void PutList(string key, List<JsonElement> items)
    {
        try
        {
            using var doc = JsonDocument.Parse(JsonSerializer.Serialize(items));
            Put(key, doc.RootElement);
        }
        catch { /* 存不进去不该影响用 */ }
    }

    /// <summary>
    /// 读一条命令,<b>命中先给旧的、回来再给新的</b>。
    ///
    /// <para><paramref name="render"/> 会被调 <b>1 到 2 次</b>:命中缓存时先调一次
    /// (参数 <c>fresh=false</c>),真数据回来再调一次(<c>fresh=true</c>)。
    /// 没命中就只调后面那一次。</para>
    ///
    /// <para>★★ 第二次<b>必须也调</b>,哪怕内容没变 —— 判「变没变」要比整段 JSON,
    /// 而那比重画一次还贵;而漏掉第二次就成了「缓存里的东西永远刷不掉」。</para>
    /// </summary>
    public static async Task Swr(CoreClient core, string command, object? args,
        Action<JsonElement, bool> render)
    {
        var key = Key(command, args);
        if (Peek(key) is { } old)
        {
            try { render(old, false); }
            catch (Exception e) { Console.WriteLine($"[缓存] 画旧数据出错({command}): {e.Message}"); }
        }
        var fresh = await core.CallAsync(command, args).ConfigureAwait(false);
        Put(key, fresh);
        render(fresh, true);
    }
}
