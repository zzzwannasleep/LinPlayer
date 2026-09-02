using System.Runtime.CompilerServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 平滑滚动。
///
/// <para>★★ <b>「卡」多半不是掉帧,是根本没有中间帧。</b>
/// Avalonia 的 ScrollViewer 收到滚轮就<b>当场把 Offset 挪过去</b> ——
/// 一格滚轮 = 内容瞬移几十像素。每一帧都按时画了,帧率也是满的,
/// 但眼睛看到的是「跳、跳、跳」,大脑把它读成卡顿。
/// 别人的软件滑起来顺,不是因为他们渲染得快,是因为他们**把这一跳摊成了十几帧**。</para>
///
/// <para>★ 用 <see cref="TopLevel.RequestAnimationFrame"/> 驱动,不用 DispatcherTimer:
/// 前者跟着合成器的帧走,后者是自己定的 16ms 闹钟 —— 和刷新率对不齐,
/// 会周期性地一帧画两次、一帧不画,那才是真的会看出抖。</para>
///
/// <para>★ 只接<b>滚轮</b>。拖滚动条要一比一跟手,给它加缓动等于让滑块和内容脱节。</para>
/// </summary>
public static class Smooth
{
    /// <summary>
    /// 每帧向目标靠拢的比例。
    ///
    /// <para>★ 指数逼近而不是定长补间:连续滚轮时目标一直在往前挪,
    /// 定长补间每来一格就重启一次动画,速度会一顿一顿的;
    /// 指数逼近对「移动中的目标」是连续的,读起来就是匀速滑行。</para>
    /// <para>★ 0.28 ≈ 8 帧走完 92%(约 130ms)。再小拖沓,再大就接近瞬移、白做。</para>
    /// </summary>
    private const double Approach = 0.28;

    /// <summary>小于半像素就收尾。留着会一直请求下一帧,白烧 GPU。</summary>
    private const double Snap = 0.5;

    private static readonly ConditionalWeakTable<ScrollViewer, Driver> Drivers = new();

    private sealed class Driver
    {
        public double TargetX, TargetY;
        public bool Running;
    }

    /// <summary>
    /// 全应用装一次。
    ///
    /// <para>★★ 用<b>类级处理器</b>,不是逐个 ScrollViewer 去 Attach。
    /// 逐个装的结果我当场就撞上了:全站有 6 处页面自己 <c>new ScrollViewer</c>,
    /// 不走公共的那条路 —— 于是「媒体库网格」这一页(最需要顺滑的那一页)
    /// 一格滚轮照样瞬移 50px,而首页是顺的。
    /// <b>「有的页面顺有的页面卡」比整页都卡更像坏了</b>,而且没人会想到去查是漏装了。
    /// 类级处理器对**所有** ScrollViewer 生效,包括以后新写的页面。</para>
    ///
    /// <para>★ 隧道阶段先到:ScrollViewer 的默认滚轮处理在
    /// <c>ScrollContentPresenter</c>(它是子节点)的冒泡阶段。
    /// 我们在隧道阶段把事件吃掉,它就不会再瞬移一次。</para>
    /// </summary>
    public static void Install()
    {
        InputElement.PointerWheelChangedEvent.AddClassHandler<ScrollViewer>(
            (sv, e) =>
            {
                if (e.Handled) return;
                // ★ 见 Innermost:嵌套滚动区里,这一格是不是该归我
                if (!Innermost(sv, e.Source as Visual, e.Delta)) return;
                if (Wheel(sv, e.Delta.X, e.Delta.Y)) e.Handled = true;
            },
            RoutingStrategies.Tunnel);
    }

    /// <summary>
    /// 这一格滚轮该不该归 <paramref name="sv"/>。
    ///
    /// <para>★★ 隧道阶段是<b>从外往里</b>走的,而滚动的正确归属是<b>从里往外</b> ——
    /// 鼠标停在一个内嵌的列表上,该滚的是那个列表,不是整页。
    /// 不判这一下的话,页面里但凡有一处内嵌滚动区(日历、聚合、影视目录都有),
    /// 它就<b>永远滚不动了</b>,而外层页面会代它滚 —— 看着像那块内容卡住了。</para>
    ///
    /// <para>★ 判据是「从事件源往上找,第一个在这个方向上滚得动的 ScrollViewer 是不是我」。
    /// 内层滚到头之后应不应该把滚轮交给外层,是另一件事,这里不做 ——
    /// 交出去会让「滚到列表底部就突然整页开始动」,那种连带感更让人意外。</para>
    /// </summary>
    private static bool Innermost(ScrollViewer sv, Visual? source, Vector delta)
    {
        for (var v = source; v is not null; v = v.GetVisualParent())
        {
            if (v is not ScrollViewer cand) continue;
            var canY = cand.Extent.Height - cand.Viewport.Height > 1;
            var canX = cand.Extent.Width - cand.Viewport.Width > 1;
            if (!(delta.Y != 0 && canY) && !(delta.X != 0 && canX)) continue;
            return ReferenceEquals(cand, sv);
        }
        return true; // 一个滚得动的都没找到 —— 那就当是我的
    }

    /// <summary>
    /// 自检:模拟拨一格滚轮。走的是<b>和真滚轮完全同一段逻辑</b> ——
    /// 抄一份出来测的话,测的是那份副本(本仓栽过两次)。
    /// </summary>
    internal static void SelfCheckWheel(ScrollViewer sv, double notches) => Wheel(sv, 0, notches);

    /// <summary>滚轮的实际逻辑。返回 false = 这一格我们没吃,让它冒泡给外层。</summary>
    private static bool Wheel(ScrollViewer sv, double dx, double dy)
    {

        var canY = sv.Extent.Height - sv.Viewport.Height > 1;
        var canX = sv.Extent.Width - sv.Viewport.Width > 1;
        if (!canY && !canX) return false; // 滚不动就别拦,让它冒泡给外层

        /* ★ 一格滚轮走多远:按视口的 20% 算,不写死像素。
           写死 120px 的话,1080p 上一格走五分之一屏,4K 上只走十分之一 ——
           同一个手势在两台机器上是两种速度。 */
        var stepY = Math.Max(80, sv.Viewport.Height * 0.20);
        var stepX = Math.Max(80, sv.Viewport.Width * 0.20);

        var d = Drivers.GetValue(sv, _ => new Driver { TargetX = sv.Offset.X, TargetY = sv.Offset.Y });
        // 没在动画时以**当前实际位置**为基准:上一次滑完之后用户可能拖过滚动条
        if (!d.Running) { d.TargetX = sv.Offset.X; d.TargetY = sv.Offset.Y; }

        /* ★★ 竖滚轮**只喂竖向**。
           首页那种横向轨道自己也是个 ScrollViewer(横能滚、竖不能),
           顺手把竖滚轮转成横滚看着很聪明 —— 实际后果是鼠标停在轨道上时
           整页就滚不动了,而用户只是想往下看下一条轨道。
           横向滚动交给触控板的横向手势 / 轨道两侧的翻页按钮。 */
        if (canY && dy != 0) d.TargetY -= dy * stepY;
        if (canX && dx != 0) d.TargetX -= dx * stepX;
        // 这一格什么都没喂进去(竖轨道收到横手势之类)→ 不拦,让它冒泡给外层
        if (!d.Running &&
            Math.Abs(d.TargetY - sv.Offset.Y) < 0.5 && Math.Abs(d.TargetX - sv.Offset.X) < 0.5) return false;

        Clamp(sv, d);
        Run(sv, d);
        return true;
    }

    /// <summary>滑到某个横向位置(轨道翻页按钮用)。和滚轮共用同一套手感。</summary>
    public static void GlideX(ScrollViewer sv, double deltaX)
    {
        var d = Drivers.GetValue(sv, _ => new Driver { TargetX = sv.Offset.X, TargetY = sv.Offset.Y });
        if (!d.Running) { d.TargetX = sv.Offset.X; d.TargetY = sv.Offset.Y; }
        d.TargetX += deltaX;
        Clamp(sv, d);
        Run(sv, d);
    }

    private static void Clamp(ScrollViewer sv, Driver d)
    {
        d.TargetX = Math.Clamp(d.TargetX, 0, Math.Max(0, sv.Extent.Width - sv.Viewport.Width));
        d.TargetY = Math.Clamp(d.TargetY, 0, Math.Max(0, sv.Extent.Height - sv.Viewport.Height));
    }

    private static void Run(ScrollViewer sv, Driver d)
    {
        if (d.Running) return; // 已经在跑了,它每帧会读最新的目标
        if (TopLevel.GetTopLevel(sv) is not { } top) { sv.Offset = new Vector(d.TargetX, d.TargetY); return; }

        d.Running = true;
        void Frame(TimeSpan _)
        {
            var cur = sv.Offset;
            var dx = d.TargetX - cur.X;
            var dy = d.TargetY - cur.Y;

            if (Math.Abs(dx) < Snap && Math.Abs(dy) < Snap)
            {
                sv.Offset = new Vector(d.TargetX, d.TargetY);
                d.Running = false;
                return;
            }
            sv.Offset = new Vector(cur.X + dx * Approach, cur.Y + dy * Approach);

            /* ★ 每帧都要重新挂:RequestAnimationFrame 是**一次性**的。
               而且要重新取 TopLevel —— 页面换掉之后原来那个可能已经不在树上了,
               继续往一个卸载了的窗口上排帧是一条永远不会停的循环。 */
            if (TopLevel.GetTopLevel(sv) is { } t) t.RequestAnimationFrame(Frame);
            else d.Running = false;
        }
        top.RequestAnimationFrame(Frame);
    }
}
