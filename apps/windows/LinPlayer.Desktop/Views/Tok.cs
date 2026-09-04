using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 按当前主题取一支画刷。
///
/// 写死色号在深色下勉强能看,浅色主题下就是错的 —— 而且不报错。
/// 唯一允许写死的是**带 alpha 的叠加色**:那底下是画面不是背景色。
///
/// 别拿它初始化 static readonly 字段:类型初始化可能早于 Application.Current。
/// </summary>
public static class Tok
{
    public static IBrush Of(string key)
    {
        if (Application.Current is { } app
            && app.TryFindResource(key, app.ActualThemeVariant, out var v) && v is IBrush b)
            return b;
        return Brushes.Transparent;
    }
}
