using System.Text.Json;
using Avalonia.Controls;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// Emby 会话。命令层现在还要显式传这四个值(迁移期形状),
/// 每页各拉一次就是每页多一次往返,所以**登录后拉一次存住**。
/// </summary>
/// <para>★★ 属性名<b>就是线上字段名</b>(小写下划线),不是 C# 惯例的 PascalCase ——
/// 匿名对象 <c>new { s.server, … }</c> 的成员名是从属性名推出来的,
/// 写成 <c>Server</c> 发出去就是 <c>"Server"</c>,核心层当作没传,报「缺少 server」。
/// 两边都不报编译错,只在运行时现形。</para>
#pragma warning disable IDE1006 // 命名:这几个是线上字段名,故意不按 C# 惯例
public sealed record Sess(string server, string token, string user_id, string device_id)
{
    public static Sess? From(JsonElement e)
    {
        if (e.ValueKind != JsonValueKind.Object) return null;
        string S(string k) => e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
        var srv = S("server");
        return srv == "" ? null : new Sess(srv, S("token"), S("user_id"), "linplayer-desktop");
    }
}
#pragma warning restore IDE1006

/// <summary>
/// 页面栈。详情页要能回到来处,而「来处」可能是首页、媒体库、搜索三者之一 ——
/// 各自记一份 back 目标就是三份会走岔的状态,所以只留一个栈。
/// </summary>
public static class Nav
{
    private static readonly Stack<Control> Stack = new();
    public static Action<Control>? Host;

    public static Sess? Session;

    /// <summary>
    /// 收起外壳:标题栏 + 侧栏。<b>播放页一进去就调</b>。
    ///
    /// <para>★★ 用户 2026-09-03:「整个软件的交互是有问题的,比如播放页不应该有侧边栏,
    /// 还是有了」。原来只有<b>按 F 进全屏</b>才收侧栏 —— 也就是说不全屏看片时,
    /// 左边一直杵着一条导航栏,而那上面每一个入口点下去都会把正在放的片子扔掉。</para>
    ///
    /// <para>★ 收起不能只 IsVisible=false —— 那样 36px 的行和 212px 的列还在,
    /// 画面会被挤在一个偏右下的框里。行高列宽要一起归零。</para>
    /// </summary>
    public static Action<bool>? Immersive;

    /// <summary>
    /// 真·全屏(窗口状态)。
    ///
    /// <para>★★ 和 <see cref="Immersive"/> <b>拆开</b>:这两件事原来绑在一起,
    /// 于是「播放页不要侧栏」这个诉求没法单独满足 —— 一收侧栏就把窗口也拽进全屏了。</para>
    /// </summary>
    public static Action<bool>? Fullscreen;

    /// <summary>栈里压了几层。1 = 就在这一大类的根上,&gt;1 = 从根上又点进去过。</summary>
    public static int Depth => Stack.Count;

    /// <summary>换根:侧栏切页用。清栈 —— 换了大类之后「返回」回到上一大类是错的。</summary>
    public static void Root(Control page)
    {
        Stack.Clear();
        Stack.Push(page);
        Host?.Invoke(page);
    }

    /// <summary>栈顶那一页。自检要在跳过去之后对那一页再下指令时用得上。</summary>
    public static Control? Current => Stack.Count > 0 ? Stack.Peek() : null;

    public static void Push(Control page)
    {
        Stack.Push(page);
        Host?.Invoke(page);
    }

    /// <summary>
    /// 顶替栈顶那一页。「下一集」用。
    ///
    /// <para>★★ 不能用 <see cref="Push"/>:一路看下去会攒出一栈播放页,
    /// 返回键要按十几下才回得到详情页 —— 而用户按返回的意图从来都是「回到剧」。</para>
    /// </summary>
    public static void Replace(Control page)
    {
        if (Stack.Count > 0) Stack.Pop();
        Stack.Push(page);
        Host?.Invoke(page);
    }

    public static bool CanBack => Stack.Count > 1;

    public static void Back()
    {
        if (!CanBack) return;
        Stack.Pop();
        Host?.Invoke(Stack.Peek());
    }
}
