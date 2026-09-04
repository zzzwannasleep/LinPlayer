using System;
using System.Collections.Generic;
using Avalonia;
using Avalonia.Animation;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Transformation;
using Avalonia.Threading;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 轻提示。
///
/// <para>用户 2026-09-04:「所有操作都要有 toast 提示,我在首页添加收藏,我都不知道
/// 有没有加成功」。在这之前只有失败才看得见,成功是完全无声的 —— 而右键菜单点完
/// 就关掉了,于是「成功」和「什么都没发生」长得一模一样。不复用底部那条出错横幅:
/// 横幅是要用户处理的,这里要的是看一眼就够。宿主是外壳给的(<see cref="Host"/>),
/// 不是每页各挂一个 —— 挂在页上会「点了收藏 → 页面刷新 → 提示跟着被销毁」。</para>
/// </summary>
public static class Toast
{
    /// <summary>提示条要往哪个容器里放。外壳启动时挂一次。</summary>
    public static Panel? Host;

    /// <summary>
    /// 播放页把它打开:提示改到**顶部**。
    ///
    /// <para>播放页底部是控制条和进度条 —— 提示压在上面既挡住进度条,
    /// 又会被用户当成控制条的一部分去点。</para>
    /// </summary>
    public static bool AtTop;

    /// <summary>停留多久(毫秒)。 2.4 秒:短到不碍事,长到看得完一行中文。</summary>
    private const int HoldMs = 2400;

    /// <summary>同时最多摞几条。再多就把最老的挤掉 —— 连点五下不该糊住半个屏幕。</summary>
    private const int MaxStack = 3;

    private static StackPanel? _stack;
    private static readonly List<Border> Live = [];

    /// <summary>成功提示。</summary>
    public static void Show(string text) => Push(text, false);

    /// <summary>失败提示。 和成功用同一套版式,只有左边那条竖线变色 ——
    /// 换整套配色会让人以为是两种不同的东西。</summary>
    public static void Error(string text) => Push(text, true);

    /// <summary>
    /// 一句话报「这次操作成不成」。<b>动作类命令统一走它</b>,
    /// 免得每个调用点各写一遍 if,而漏掉的那个就是「这个操作没有提示」。
    /// </summary>
    public static void Result(bool ok, string okText, string failText)
    {
        if (ok) Show(okText); else Error(failText);
    }

    private static void Push(string text, bool bad)
    {
        if (string.IsNullOrWhiteSpace(text)) return;
        // 动作大多在后台线程里回来,不切回 UI 线程会当场抛。
        Dispatcher.UIThread.Post(() =>
        {
            if (Host is null) return;
            Mount();
            var card = Card(text, bad);
            _stack!.Children.Add(card);
            Live.Add(card);
            while (Live.Count > MaxStack) Kill(Live[0]);

            // 入场:下一帧再改值 —— 同一帧里设初值和终值,过渡读不到「变过」,一下就跳到位。
            Dispatcher.UIThread.Post(() =>
            {
                card.Opacity = 1;
                card.RenderTransform = TransformOperations.Parse("translateY(0px)");
            }, DispatcherPriority.Render);

            DispatcherTimer.RunOnce(() => Kill(card), TimeSpan.FromMilliseconds(HoldMs));
        });
    }

    /// <summary>把提示条栈挂进宿主。 每次挂之前先按当前位置摆好:
    /// 播放页进出会改 <see cref="AtTop"/>,而栈是一直留着的。</summary>
    /// <summary>底部弹时要让开播放页的控制条,不然提示压在进度条上。</summary>
    private const double BottomClearance = 64;

    private static void Mount()
    {
        _stack ??= new StackPanel { Spacing = 10, IsHitTestVisible = false };
        _stack.HorizontalAlignment = HorizontalAlignment.Center;
        _stack.VerticalAlignment = AtTop ? VerticalAlignment.Top : VerticalAlignment.Bottom;
        _stack.Margin = AtTop ? new Thickness(0, 26, 0, 0) : new Thickness(0, 0, 0, BottomClearance);
        if (!Host!.Children.Contains(_stack)) Host.Children.Add(_stack);
        else Host.Children.Move(Host.Children.IndexOf(_stack), Host.Children.Count - 1); // 永远在最上层
    }

    private static void Kill(Border card)
    {
        Live.Remove(card);
        card.Opacity = 0;
        card.RenderTransform = TransformOperations.Parse($"translateY({(AtTop ? -8 : 8)}px)");
        // 等淡出走完再摘,不然是「啪」一下没的
        DispatcherTimer.RunOnce(() => _stack?.Children.Remove(card), TimeSpan.FromMilliseconds(200));
    }

    private static Border Card(string text, bool bad) => new()
    {
        Padding = new Thickness(0),
        CornerRadius = new CornerRadius(10),
        Background = new SolidColorBrush(Color.FromArgb(0xF2, 0x22, 0x24, 0x2b)),
        BorderBrush = new SolidColorBrush(Color.FromArgb(0x66, 0xff, 0xff, 0xff)),
        BorderThickness = new Thickness(1),
        Opacity = 0,
        RenderTransform = TransformOperations.Parse($"translateY({(AtTop ? -8 : 8)}px)"),
        Transitions =
        [
            new DoubleTransition
            {
                Property = Visual.OpacityProperty,
                Duration = TimeSpan.FromMilliseconds(180),
                Easing = new Avalonia.Animation.Easings.CubicEaseOut(),
            },
            new TransformOperationsTransition
            {
                Property = Visual.RenderTransformProperty,
                Duration = TimeSpan.FromMilliseconds(180),
                Easing = new Avalonia.Animation.Easings.CubicEaseOut(),
            },
        ],
        Child = new StackPanel
        {
            Orientation = Orientation.Horizontal,
            Children =
            {
                // 左边那条竖线:成功=强调色,失败=红。整块只有这一处变色。
                new Border
                {
                    Width = 3, CornerRadius = new CornerRadius(9, 0, 0, 9),
                    Background = new SolidColorBrush(bad
                        ? Color.FromRgb(0xe0, 0x5a, 0x6e)
                        : Color.FromRgb(0x4c, 0x9a, 0xff)),
                },
                new TextBlock
                {
                    Text = text, Margin = new Thickness(14, 10, 14, 10),
                    MaxWidth = 460, TextWrapping = TextWrapping.Wrap,
                    FontSize = 12.5, Foreground = Brushes.White,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
        },
    };

    /// <summary>自检用:现在屏幕上摞着几条。</summary>
    internal static int LiveCount => Live.Count;
}
