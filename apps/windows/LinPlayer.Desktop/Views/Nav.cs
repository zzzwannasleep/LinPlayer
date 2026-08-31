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
    /// 沉浸模式:收起标题栏和侧栏,窗口进全屏。播放页用。
    ///
    /// <para>★ 收起不能只 IsVisible=false —— 那样 36px 的行和 212px 的列还在,
    /// 画面会被挤在一个偏右下的框里。行高列宽要一起归零。</para>
    /// </summary>
    public static Action<bool>? Immersive;

    /// <summary>换根:侧栏切页用。清栈 —— 换了大类之后「返回」回到上一大类是错的。</summary>
    public static void Root(Control page)
    {
        Stack.Clear();
        Stack.Push(page);
        Host?.Invoke(page);
    }

    public static void Push(Control page)
    {
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
