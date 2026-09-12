using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 详情页那排小片。
///
/// <para>做成一排片而不是用「·」连起来的一句话:连成句<b>不换行</b>,类型一多就被挤出
/// 可视区,而且年份、评分、分级、类型是四种不同的东西,同一个分隔符串起来等于
/// 告诉眼睛「它们是一类」。</para>
/// </summary>
internal static class Chips
{
    private static readonly Thickness Gap = new(0, 0, 10, 10);
    private static readonly Thickness Pad = new(10, 6);

    /// <summary>不能点的那种:年份、评分、分级、时长。</summary>
    internal static Control Plain(string text) => new Border
    {
        Margin = Gap, Padding = Pad,
        CornerRadius = new CornerRadius(6),
        Background = Tok.Of("PanelAlt"),
        BorderBrush = Tok.Of("LineStrong"),
        BorderThickness = new Thickness(1),
        IsVisible = text != "",
        Child = new TextBlock { Text = text, FontSize = 12.5, Foreground = Tok.Of("Ink") },
    };

    /// <summary>
    /// 能点的那种:类型 / 标签 / 工作室。
    ///
    /// <para>和不能点的<b>长得不一样</b>(描边用强调色、鼠标变手型)——
    /// 一排片里有的能点有的不能点,而外观一致的话用户只能靠试。</para>
    /// </summary>
    internal static Control Clickable(string text, Action onClick)
    {
        var b = new Button
        {
            Margin = Gap, Padding = Pad,
            CornerRadius = new CornerRadius(6),
            Background = Tok.Of("PanelAlt"),
            BorderBrush = Tok.Of("Accent"),
            BorderThickness = new Thickness(1),
            HorizontalContentAlignment = HorizontalAlignment.Center,
            Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
            Content = new TextBlock { Text = text, FontSize = 12.5, Foreground = Tok.Of("Ink") },
        };
        ToolTip.SetTip(b, $"看看还有哪些「{text}」");
        b.Click += (_, _) => onClick();
        return b;
    }
}
