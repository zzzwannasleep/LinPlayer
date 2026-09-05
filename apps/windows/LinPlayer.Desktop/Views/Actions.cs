using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia.Input;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>一个能绑键的动作。<c>Keys</c> 里用 " 或 " 分隔多个键位。</summary>
internal sealed record ActionDef(string Id, string Scope, string Group, string Name, string Keys);

/// <summary>
/// 可绑键动作表 + 键谱翻译。
///
/// <para><b>一张表同时是行为、帮助和设置页的数据源。</b>原先是三处各写一遍
/// (全局表 / 播放页的 switch / 帮助浮层),必然的结果是帮助在撒谎,
/// 而用户按了没反应只会认为「快捷键是坏的」。</para>
/// <para>键谱翻译<b>只此一处</b> —— 表里写得出什么,就得翻得出什么。</para>
/// </summary>
internal static class Actions
{
    public const string Global = "global";
    public const string Player = "player";

    /// <summary>解绑。不用空串:空串分不清「没设过」和「特意取消」。</summary>
    public const string None = "无";

    private static readonly string[] Sep = [" 或 "];

    public static readonly ActionDef[] All =
    [
        new("nav.home",       Global, "去哪儿", "首页",              "Ctrl+H"),
        new("nav.library",    Global, "去哪儿", "媒体库",            "Ctrl+L"),
        new("nav.search",     Global, "去哪儿", "搜索",              "/ 或 Ctrl+F"),
        new("nav.favorites",  Global, "去哪儿", "收藏",              "Ctrl+I"),
        new("nav.download",   Global, "去哪儿", "下载",              "Ctrl+J"),
        new("nav.settings",   Global, "去哪儿", "设置",              "Ctrl+,"),

        new("win.back",       Global, "窗口",   "返回上一页",        "Alt+← 或 退格 或 侧键1"),
        new("win.sidebar",    Global, "窗口",   "收起 / 展开侧栏",   "Ctrl+B"),
        new("win.maximize",   Global, "窗口",   "窗口最大化 / 还原", "F11"),
        new("win.help",       Global, "窗口",   "这张表",            "?"),
        new("win.escape",     Global, "窗口",   "关掉这张表 / 返回", "Esc"),

        /* 鼠标左右键默认都绑暂停:用户 2026-09-06 点名「鼠标左右键暂停视频和播放」。
           左键本来就是这个行为(点画面 = 暂停),右键是这次补的 ——
           播放页没有右键菜单,这个键位空着。和别的键位一样可以在设置里改掉。 */
        new("player.pause",      Player, "播放", "播放 / 暂停",     "空格 或 K 或 鼠标左键 或 鼠标右键"),
        new("player.back10",     Player, "播放", "后退 10 秒",      "← 或 J"),
        new("player.forward10",  Player, "播放", "前进 10 秒",      "→ 或 L"),
        new("player.volumeUp",   Player, "播放", "音量 +",          "↑ 或 滚轮上"),
        new("player.volumeDown", Player, "播放", "音量 −",          "↓ 或 滚轮下"),
        new("player.mute",       Player, "播放", "静音",            "M"),
        new("player.speedUp",    Player, "播放", "加速",            "."),
        new("player.speedDown",  Player, "播放", "减速",            ","),
        new("player.fullscreen", Player, "播放", "全屏 / 退出全屏", "F 或 回车"),
        new("player.next",       Player, "播放", "下一集",          "N"),
        new("player.episodes",   Player, "播放", "选集",            "E"),
        new("player.quality",    Player, "播放", "画质档位",        "U"),
        new("player.screenshot", Player, "播放", "截图",            "S"),
        new("player.skip",       Player, "播放", "跳过片头 / 片尾", "侧键2"),
        new("player.leave",      Player, "播放", "退出播放",        "Esc"),
    ];

    /// <summary>数字键 0~9 跳到片长的百分之几。<b>不进表</b> ——
    /// 十个键一个语义,拆成十条只会把设置页撑满,而它们又不该分开改。</summary>
    public const string FixedNote = "数字键 0~9 = 跳到片长的 0% ~ 90%(固定,不可改)";

    // 只记用户改过的那几条:全量存下来的话,以后调整默认键位对老用户一条都不生效
    private static Dictionary<string, string> _custom = new(StringComparer.Ordinal);

    public static string KeysOf(string id) =>
        _custom.TryGetValue(id, out var k) ? k : All.FirstOrDefault(a => a.Id == id)?.Keys ?? "";

    public static bool Changed(string id) => _custom.ContainsKey(id);

    private static string[] Split(string keys) =>
        keys.Split(Sep, StringSplitOptions.RemoveEmptyEntries);

    /// <summary>键谱 → 动作 id。没绑到返回 null。</summary>
    public static string? Hit(string scope, string spec)
    {
        if (spec.Length == 0 || spec == None) return null;
        foreach (var a in All)
        {
            if (a.Scope != scope) continue;
            foreach (var one in Split(KeysOf(a.Id)))
                if (one == spec) return a.Id;
        }
        return null;
    }

    // ---------------------------------------------------------------- 键谱翻译

    /// <summary>
    /// 一次按键翻成键谱。翻不出来返回空串(= 这一下不归快捷键管)。
    ///
    /// <para>Shift 只加在「按住它字符不变」的键上:<c>Shift+/</c> 打出来的是
    /// <c>?</c>,写成 <c>Shift+/</c> 的话用户按出来永远对不上表里那一条。</para>
    /// </summary>
    public static string Spec(KeyEventArgs e)
    {
        var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        var alt = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        var shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);

        // 按住 Shift 才打得出的符号先认掉,认掉的不再加 Shift+ 前缀
        var sym = shift
            ? e.Key switch
            {
                Key.OemQuestion => "?",
                Key.OemComma => "<",
                Key.OemPeriod => ">",
                _ => "",
            }
            : "";

        var body = sym.Length > 0 ? sym : e.Key switch
        {
            Key.Escape => "Esc",
            Key.Space => "空格",
            Key.Enter => "回车",
            Key.Back => "退格",
            Key.Tab => "Tab",
            Key.Delete => "Delete",
            Key.Left => "←",
            Key.Right => "→",
            Key.Up => "↑",
            Key.Down => "↓",
            Key.OemComma => ",",
            Key.OemPeriod => ".",
            Key.OemQuestion => "/",
            Key.OemMinus => "-",
            Key.OemPlus => "=",
            Key.OemOpenBrackets => "[",
            Key.OemCloseBrackets => "]",
            Key.OemSemicolon => ";",
            Key.OemQuotes => "'",
            Key.OemTilde => "`",
            Key.OemBackslash or Key.OemPipe => "\\",
            >= Key.F1 and <= Key.F12 => "F" + (e.Key - Key.F1 + 1),
            >= Key.A and <= Key.Z => ((char)('A' + (e.Key - Key.A))).ToString(),
            >= Key.D0 and <= Key.D9 => ((char)('0' + (e.Key - Key.D0))).ToString(),
            _ => "",
        };
        if (body.Length == 0) return "";

        var mod = (ctrl ? "Ctrl+" : "") + (alt ? "Alt+" : "");
        // 符号键的 Shift 已经体现在字符里,再加前缀就成了同一个键的两种写法
        var symbolic = body.Length == 1 && !char.IsLetterOrDigit(body[0]);
        if (shift && sym.Length == 0 && !symbolic) mod += "Shift+";
        return mod + body;
    }

    /// <summary>鼠标按键翻成键谱。不是这五个键就返回空串。</summary>
    public static string Spec(PointerPointProperties p) =>
        p.IsLeftButtonPressed ? "鼠标左键"
        : p.IsRightButtonPressed ? "鼠标右键"
        : p.IsMiddleButtonPressed ? "鼠标中键"
        : p.IsXButton1Pressed ? "侧键1"
        : p.IsXButton2Pressed ? "侧键2"
        : "";

    public static string WheelSpec(double deltaY) => deltaY > 0 ? "滚轮上" : "滚轮下";

    // ---------------------------------------------------------------- 持久化

    /// <summary>
    /// 从核心层读回改过的键位。起动时读一次就够 —— 改键那条路自己会更新内存里这份。
    ///
    /// <para>读不到就沿用默认键位:偏好坏了不该让快捷键整个不工作。</para>
    /// </summary>
    public static async Task LoadAsync(CoreClient? core)
    {
        if (core is null) return;
        try
        {
            var p = await core.PlayerGetPlaybackPrefs();
            if (!p.TryGetProperty("shortcuts", out var m) || m.ValueKind != JsonValueKind.Object) return;
            var d = new Dictionary<string, string>(StringComparer.Ordinal);
            foreach (var kv in m.EnumerateObject())
                if (kv.Value.ValueKind == JsonValueKind.String && kv.Value.GetString() is { Length: > 0 } v)
                    d[kv.Name] = v;
            _custom = d;
        }
        catch (Exception e) { Log.D("快捷键", "读键位失败,沿用默认:" + e.Message); }
    }

    /// <summary>
    /// 把一个动作改绑到某个键谱上,并**抢掉**同作用域里原来占着它的那一条。
    ///
    /// <para>不抢的话两条动作绑同一个键,先命中的赢 —— 而设置页上两行都写着这个键,
    /// 只有一行有反应,用户查不出为什么。</para>
    /// </summary>
    public static async Task BindAsync(CoreClient? core, string id, string spec)
    {
        var scope = All.FirstOrDefault(a => a.Id == id)?.Scope ?? Global;
        foreach (var other in All.Where(a => a.Scope == scope && a.Id != id))
        {
            var had = Split(KeysOf(other.Id));
            var kept = had.Where(k => k != spec).ToArray();
            if (kept.Length != had.Length)
                _custom[other.Id] = kept.Length > 0 ? string.Join(" 或 ", kept) : None;
        }
        _custom[id] = spec;
        await SaveAsync(core);
    }

    /// <summary>改回默认键位。</summary>
    public static async Task ResetAsync(CoreClient? core, string id)
    {
        _custom.Remove(id);
        await SaveAsync(core);
    }

    private static async Task SaveAsync(CoreClient? core)
    {
        if (core is null) return;
        try { await core.PlayerSetPlaybackPrefs(new { settings = new { shortcuts = _custom } }); }
        catch (Exception e) { Log.D("快捷键", "存键位失败:" + e.Message); }
    }
}
