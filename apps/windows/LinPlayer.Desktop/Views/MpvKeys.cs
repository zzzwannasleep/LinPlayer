using Avalonia.Input;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 把一次按键翻成 mpv 的键名,好让用户那份 <c>input.conf</c> 真能生效。
///
/// <para>☠ <c>vo=libmpv</c> 下 mpv <b>收不到任何键盘事件</b> —— 它没有自己的窗口,
/// 键全被壳吃了。所以 <c>config-dir</c> 设了、<c>input.conf</c> 也读了,
/// 绑定却一条都不会触发(用户 2026-09-12:「可以部分生效但不是全部」——
/// 生效的那部分是 <c>mpv.conf</c> 里的选项,按键绑定一条都没生效)。
/// 补法是壳把<b>自己没用掉</b>的键原样 <c>keypress</c> 给 mpv。</para>
/// </summary>
internal static class MpvKeys
{
    /// <summary>
    /// 翻不出来回 <c>null</c>(= 这一下别转发)。
    ///
    /// <para>认不出的键名转过去,mpv 每按一下记一条 error;而修饰键本身
    /// (Ctrl/Shift/Alt)按下时也会来一次 KeyDown —— 转过去等于每次组合键
    /// 都先给 mpv 一个孤立的 <c>Ctrl</c>。</para>
    /// </summary>
    internal static string? Name(Key k, KeyModifiers m)
    {
        var body = Body(k);
        if (body == null) return null;

        var ctrl = m.HasFlag(KeyModifiers.Control);
        var alt = m.HasFlag(KeyModifiers.Alt);
        var shift = m.HasFlag(KeyModifiers.Shift);

        /* 单个字母 + Shift 在 mpv 那边就是**大写字母本身**,不是 `Shift+a`。
           写成 Shift+ 前缀的话 `input.conf` 里那条 `A` 永远匹配不上。
           带了别的修饰键就反过来:mpv 认的是 `Ctrl+Shift+a`。 */
        if (body.Length == 1 && body[0] is >= 'a' and <= 'z' && shift && !ctrl && !alt)
            return body.ToUpperInvariant();

        var pre = "";
        if (ctrl) pre += "Ctrl+";
        if (alt) pre += "Alt+";
        if (shift) pre += "Shift+";
        return pre + body;
    }

    private static string? Body(Key k) => k switch
    {
        >= Key.A and <= Key.Z => ((char)('a' + (k - Key.A))).ToString(),
        >= Key.D0 and <= Key.D9 => ((char)('0' + (k - Key.D0))).ToString(),
        >= Key.F1 and <= Key.F12 => "F" + (k - Key.F1 + 1),
        Key.Space => "SPACE",
        Key.Enter => "ENTER",
        Key.Escape => "ESC",
        Key.Tab => "TAB",
        Key.Back => "BS",
        Key.Delete => "DEL",
        Key.Insert => "INS",
        Key.Home => "HOME",
        Key.End => "END",
        Key.PageUp => "PGUP",
        Key.PageDown => "PGDWN",
        Key.Left => "LEFT",
        Key.Right => "RIGHT",
        Key.Up => "UP",
        Key.Down => "DOWN",
        Key.OemComma => ",",
        Key.OemPeriod => ".",
        Key.OemQuestion => "/",
        Key.OemSemicolon => ";",
        Key.OemQuotes => "'",
        Key.OemMinus => "-",
        Key.OemPlus => "=",
        Key.OemOpenBrackets => "[",
        Key.OemCloseBrackets => "]",
        Key.OemBackslash or Key.OemPipe => "\\",
        Key.OemTilde => "`",
        _ => null,   // 修饰键自己、输入法键、媒体键…… 一律不转
    };
}
