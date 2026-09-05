using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 居中确认弹窗。**全站只此一份**。
///
/// <para>原来是「点一下变成『确认删除?』,再点一次才真删」。放在右键菜单里时这一招
/// 直接不成立:第一下点完菜单就关了,用户得**再右键一次**才能点到第二下 ——
/// 用户 2026-09-06 原话「要重新右键服务器才能删除,麻烦」。</para>
/// <para>设置页整体是零二次确认的,弹窗只留给**不可逆**的那几件事:
/// 删服务器 / 删下载(连文件) / 卸载插件。</para>
/// </summary>
internal static class Dialogs
{
    /// <summary>一句话的确认框。<paramref name="danger"/> = 把确定键画成危险色。</summary>
    public static Task<bool> Confirm(Visual anchor, string title, string detail,
        string okText = "确定", bool danger = true) =>
        Show(anchor, title, new TextBlock
        {
            Text = detail, Classes = { "dim" }, TextWrapping = TextWrapping.Wrap, MaxWidth = 380,
        }, okText, "取消", danger);

    public static async Task<bool> Show(Visual anchor, string title, Control body,
        string okText, string? cancelText, bool danger = false)
    {
        if (TopLevel.GetTopLevel(anchor) is not Window owner) return false;

        var tcs = new TaskCompletionSource<bool>();
        var buttons = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            HorizontalAlignment = HorizontalAlignment.Right,
        };
        var dlg = new Window
        {
            Title = title, SizeToContent = SizeToContent.WidthAndHeight,
            CanResize = false, WindowStartupLocation = WindowStartupLocation.CenterOwner,
        };
        if (cancelText is not null)
        {
            var cancel = new Button { Classes = { "ghost" }, Content = cancelText, MinHeight = 32 };
            cancel.Click += (_, _) => { tcs.TrySetResult(false); dlg.Close(); };
            buttons.Children.Add(cancel);
        }
        var ok = new Button { Content = okText, MinHeight = 32 };
        // 主题里只有 Button.ghost.danger 这一条选择器,单加 danger 等于没加样式
        if (danger) { ok.Classes.Add("ghost"); ok.Classes.Add("danger"); }
        ok.Click += (_, _) => { tcs.TrySetResult(true); dlg.Close(); };
        buttons.Children.Add(ok);

        dlg.Content = new Border
        {
            Padding = new Thickness(18), MinWidth = 380,
            Child = new StackPanel
            {
                Spacing = 14,
                Children = { new TextBlock { Text = title, Classes = { "h2" } }, body, buttons },
            },
        };
        // 用户直接关窗口 = 取消。不设的话 await 会永远挂着。
        dlg.Closed += (_, _) => tcs.TrySetResult(false);
        await dlg.ShowDialog(owner);
        return await tcs.Task;
    }
}
