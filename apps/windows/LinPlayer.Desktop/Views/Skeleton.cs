using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 骨架屏。
///
/// <para>它替掉的不是「加载中…」这三个字,而是那三个字不占位:内容回来的一瞬间
/// 一行的高度从 20px 跳到 280px,页面往下一顶,用户已经在看的那一段被推走了。
/// 所以骨架的尺寸必须和真卡一致 —— 一半的价值是「有反馈」,另一半是不跳版。
/// 尺寸跟着 <see cref="Card"/> 走,哪天卡片改尺寸这里要一起改。
/// 呼吸动画在样式表的 <c>Border.skel</c> 上,这里只摆形状。</para>
/// </summary>
public static class Skeleton
{
    private const double TitleHeight = 34;

    private static Control Block(double w, double h, double radius = 10) => new Border
    {
        Classes = { "skel" }, Width = w, Height = h,
        CornerRadius = new CornerRadius(radius),
        HorizontalAlignment = HorizontalAlignment.Left,
    };

    /// <summary>一张卡的骨架:图块 + 两行标题位。</summary>
    private static Control CardShape(bool wide, double? width = null)
    {
        var w = width ?? (wide ? 256.0 : 158.0);
        var h = wide ? w * 9 / 16 : w * 3 / 2;
        return new StackPanel
        {
            Width = w, Spacing = 6,
            Children = { Block(w, h), Block(w * 0.72, 12, 6), Block(w * 0.45, 12, 6) },
            Margin = new Thickness(0, 0, 0, TitleHeight - 30),
        };
    }

    /// <summary>首页那种横向轨道的骨架。</summary>
    public static Control Strip(bool wide, int count = 6, double? width = null)
    {
        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        for (var i = 0; i < count; i++) row.Children.Add(CardShape(wide, width));
        return row;
    }

    /// <summary>网格页(媒体库 / 搜索结果)的骨架。</summary>
    public static Control Grid(bool wide, int count = 12, double? width = null)
    {
        var wrap = new WrapPanel();
        for (var i = 0; i < count; i++)
        {
            var c = CardShape(wide, width);
            c.Margin = new Thickness(0, 0, 14, 18);
            wrap.Children.Add(c);
        }
        return wrap;
    }

    /// <summary>详情页头部的骨架:海报 + 标题 + 几行元信息。</summary>
    public static Control Detail() => new StackPanel
    {
        Orientation = Orientation.Horizontal, Spacing = 18,
        Children =
        {
            Block(220, 330, 12),
            new StackPanel
            {
                Spacing = 10, VerticalAlignment = VerticalAlignment.Top,
                Children =
                {
                    Block(420, 30, 8), Block(300, 14, 6), Block(180, 38, 8),
                    Block(660, 12, 6), Block(640, 12, 6), Block(520, 12, 6),
                },
            },
        },
    };
}
