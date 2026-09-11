using System.Runtime.CompilerServices;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.VisualTree;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 平滑滚动。「卡」多半不是掉帧,是根本没有中间帧。
///
/// <para>Avalonia 的 ScrollViewer 收到滚轮就当场把 Offset 挪过去 —— 一格滚轮 =
/// 内容瞬移几十像素。每一帧都按时画了、帧率也是满的,但眼睛看到的是「跳、跳、跳」。
/// 用 <see cref="TopLevel.RequestAnimationFrame"/> 驱动而不是 DispatcherTimer:后者是
/// 自己定的 16ms 闹钟,和刷新率对不齐会周期性地一帧画两次、一帧不画。
/// 只接滚轮 —— 拖滚动条要一比一跟手,加缓动等于让滑块黏在手上。</para>
/// </summary>
public static class Smooth
{
    /// <summary>
    /// 每帧向目标靠拢的比例。
    ///
    /// <para>指数逼近而不是定长补间:连续滚轮时目标一直在往前挪,
    /// 定长补间每来一格就重启一次动画,速度会一顿一顿的;
    /// 指数逼近对「移动中的目标」是连续的,读起来就是匀速滑行。</para>
    /// <para>0.28 ≈ 8 帧走完 92%(约 130ms)。再小拖沓,再大就接近瞬移、白做。</para>
    /// </summary>
    private const double Approach = 0.28;

    /// <summary>小于半像素就收尾。留着会一直请求下一帧,白烧 GPU。</summary>
    private const double Snap = 0.5;

    private static readonly ConditionalWeakTable<ScrollViewer, Driver> Drivers = new();

    private sealed class Driver
    {
        public double TargetX, TargetY;
        public bool Running;
        /// <summary>这一轮动画的代次。换代 = 让上一轮的帧回调自己退场,见 <see cref="Run"/>。</summary>
        public int Gen;
        /// <summary>上一帧是什么时候跑的。用来认出「帧不再来了」。</summary>
        public DateTime LastFrame = DateTime.MinValue;
    }

    /// <summary>
    /// 多久没来帧就当这一轮动画已经死了。
    ///
    /// <para><see cref="TopLevel.RequestAnimationFrame"/> 挂在渲染循环上 ——
    /// 窗口最小化 / 被完全遮住时渲染循环会停,排进去的那一帧**永远不会来**。
    /// 250ms 是 15 帧,正常动画每帧都在刷新,不可能误判。</para>
    /// </summary>
    private static readonly TimeSpan FrameStall = TimeSpan.FromMilliseconds(250);

    /// <summary>
    /// 全应用装一次。用类级处理器,不是逐个 ScrollViewer 去 Attach。
    ///
    /// <para>逐个装的结果我当场就撞上了:全站有 6 处页面自己 <c>new ScrollViewer</c>,
    /// 于是媒体库网格(最需要顺滑的那一页)一格滚轮照样瞬移 50px,而首页是顺的 ——
    /// 「有的页面顺有的页面卡」比整页都卡更像坏了。类级处理器对所有 ScrollViewer
    /// 生效,包括以后新写的页面。隧道阶段先到:默认滚轮处理在子节点的冒泡阶段,
    /// 我们先把事件吃掉,它就不会再瞬移一次。</para>
    /// </summary>
    public static void Install()
    {
        InputElement.PointerWheelChangedEvent.AddClassHandler<ScrollViewer>(
            (sv, e) =>
            {
                if (e.Handled) return;
                // 见 Innermost:嵌套滚动区里,这一格是不是该归我
                if (!Innermost(sv, e.Source as Visual, e.Delta)) return;
                if (Wheel(sv, e.Delta.X, e.Delta.Y)) e.Handled = true;
            },
            RoutingStrategies.Tunnel);
    }

    /// <summary>
    /// 这一格滚轮该不该归 <paramref name="sv"/>。
    ///
    /// <para>隧道阶段是从外往里走的,而滚动的正确归属是从里往外 —— 鼠标停在内嵌
    /// 列表上,该滚的是那个列表不是整页。不判这一下的话,页面里但凡有一处内嵌
    /// 滚动区(日历、聚合、影视目录),它就永远滚不动了,而外层会代它滚。
    /// 判据是「从事件源往上找,第一个在这个方向上滚得动的 ScrollViewer」。</para>
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

        /* 一格滚轮走多远:按视口的 20% 算,不写死像素。
           写死 120px 的话,1080p 上一格走五分之一屏,4K 上只走十分之一 ——
           同一个手势在两台机器上是两种速度。 */
        var stepY = Math.Max(80, sv.Viewport.Height * 0.20);
        var stepX = Math.Max(80, sv.Viewport.Width * 0.20);

        var d = Drivers.GetValue(sv, _ => new Driver { TargetX = sv.Offset.X, TargetY = sv.Offset.Y });
        // 没在动画时以**当前实际位置**为基准:上一次滑完之后用户可能拖过滚动条 / 拖过轨道。
        // 判 StillAlive 不是判 Running,理由见 GlideX。
        var alive = StillAlive(d.Running, d.LastFrame);
        if (!alive) { d.TargetX = sv.Offset.X; d.TargetY = sv.Offset.Y; }

        /* 竖滚轮**只喂竖向**。
           首页那种横向轨道自己也是个 ScrollViewer(横能滚、竖不能),
           顺手把竖滚轮转成横滚看着很聪明 —— 实际后果是鼠标停在轨道上时
           整页就滚不动了,而用户只是想往下看下一条轨道。
           横向滚动交给触控板的横向手势 / 轨道两侧的翻页按钮。 */
        if (canY && dy != 0) d.TargetY -= dy * stepY;
        if (canX && dx != 0) d.TargetX -= dx * stepX;
        // 这一格什么都没喂进去(竖轨道收到横手势之类)→ 不拦,让它冒泡给外层
        if (!alive &&
            Math.Abs(d.TargetY - sv.Offset.Y) < 0.5 && Math.Abs(d.TargetX - sv.Offset.X) < 0.5) return false;

        Clamp(sv, d);
        Run(sv, d);
        return true;
    }

    /// <summary>滑到某个横向位置(轨道翻页按钮用)。和滚轮共用同一套手感。</summary>
    public static void GlideX(ScrollViewer sv, double deltaX)
    {
        var d = Drivers.GetValue(sv, _ => new Driver { TargetX = sv.Offset.X, TargetY = sv.Offset.Y });
        /* ☠ 判的是<b>还活着没有</b>,不是 <c>Running</c> 这个字段。
           只判字段的话:窗口最小化 / 页面被顶掉 → 帧不再来,而 Running 永远停在 true,
           于是这里不再对齐当前位置,目标一直叠在那个<b>永远到不了的旧值</b>上 ——
           表现就是用户报的「点左右按钮卡死」:按钮还亮着,点下去一动不动。 */
        if (!StillAlive(d.Running, d.LastFrame)) { d.TargetX = sv.Offset.X; d.TargetY = sv.Offset.Y; }
        d.TargetX += deltaX;
        Clamp(sv, d);
        Run(sv, d);
    }

    private static void Clamp(ScrollViewer sv, Driver d)
    {
        d.TargetX = Math.Clamp(d.TargetX, 0, Math.Max(0, sv.Extent.Width - sv.Viewport.Width));
        d.TargetY = Math.Clamp(d.TargetY, 0, Math.Max(0, sv.Extent.Height - sv.Viewport.Height));
    }

    /// <summary>
    /// 跑动画。<b>「点左右翻页按钮有概率卡死」的根因就在这里</b>:
    /// <c>Running</c> 原来是个只进不出的闩,卡住之后每次点按钮都当场 return。
    ///
    /// <para>三道闸缺一不可:每帧重夹目标、一步都没挪就收尾、帧停了就换代重启。
    /// 两条把它卡住的路(虚拟化轨道的 Extent 会缩、最小化时渲染循环停)
    /// 见 <c>docs/lessons/ui-desktop.md</c>。自检 <c>LP_SCROLLPROBE=1</c>。</para>
    /// </summary>
    private static void Run(ScrollViewer sv, Driver d)
    {
        // 还在正常跑就让它接着跑(它每帧会读最新的目标);帧停了就换代重启
        if (StillAlive(d.Running, d.LastFrame)) return;
        if (TopLevel.GetTopLevel(sv) is not { } top) { sv.Offset = new Vector(d.TargetX, d.TargetY); return; }

        d.Running = true;
        d.LastFrame = DateTime.UtcNow;
        var gen = ++d.Gen;
        void Frame(TimeSpan _)
        {
            // 上一轮的帧回调在这里退场 —— 不判的话换代之后会有两条循环同时改 Offset
            if (gen != d.Gen) return;
            d.LastFrame = DateTime.UtcNow;

            // 每帧重夹:虚拟化面板的 Extent 会变,点击那一刻夹过的值可能已经不合法了
            Clamp(sv, d);
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

            /* 要挪的距离 ≥ Snap,那这一步至少该挪 Snap×Approach。一点都没挪
               = ScrollViewer 把我们要去的位置拒了,再排下一帧也是同样的结果。 */
            if ((sv.Offset - cur).Length < 0.01)
            {
                d.TargetX = sv.Offset.X;
                d.TargetY = sv.Offset.Y;
                d.Running = false;
                return;
            }

            /* 每帧都要重新挂:RequestAnimationFrame 是**一次性**的。
               而且要重新取 TopLevel —— 页面换掉之后原来那个可能已经不在树上了,
               继续往一个卸载了的窗口上排帧是一条永远不会停的循环。 */
            if (TopLevel.GetTopLevel(sv) is { } t) t.RequestAnimationFrame(Frame);
            else d.Running = false;
        }
        top.RequestAnimationFrame(Frame);
    }

    /// <summary>
    /// 上一轮动画还活着吗。
    ///
    /// <para>抽出来是因为<b>自检要走这一句</b>,而不是走一份抄本 ——
    /// 抄本测的是抄本(本仓栽过两次)。判 <c>Running</c> 一个字段是不够的:
    /// 它在窗口最小化时会永远停在 true。</para>
    /// </summary>
    internal static bool StillAlive(bool running, DateTime lastFrame) =>
        running && DateTime.UtcNow - lastFrame < FrameStall;

    /// <summary>起拖阈值。手按在卡片上点一下,指针总会抖一两个像素 ——
    /// 不设阈值的话每一次点击都被判成拖拽,卡片就再也点不开了。</summary>
    private const double DragSlop = 6;

    /// <summary>
    /// 按住左键拖着滑(用户 2026-09-12:「长按鼠标左键 向左滑动 反之向右滑动」)。
    ///
    /// <para>☠ 越过阈值时必须<b>把指针抢过来</b>。轨道里每张卡自己就是个 Button,
    /// 它在按下那一刻已经抓走了指针;不抢的话松手会被它当成一次点击,
    /// 直接跳进详情页 —— 「想滑一下结果换了一页」比滑不动更糟。
    /// 抢过来之后 Button 收到 PointerCaptureLost,自己把按下态取消,Click 就不发了。</para>
    /// <para>拖的时候<b>不加缓动</b>,一比一跟手:加了等于内容黏在手上慢半拍。</para>
    /// </summary>
    public static void EnableDrag(ScrollViewer sv)
    {
        var fromX = 0.0;         // 按下那一刻的偏移
        var anchorX = 0.0;       // 按下那一刻的指针横坐标
        var armed = false;       // 左键按着,还没越过阈值
        var dragging = false;
        InputElement? pressed = null;   // 按在哪张卡上 —— 起拖时要去取消它的按下态

        sv.AddHandler(InputElement.PointerPressedEvent, (object? _, PointerPressedEventArgs e) =>
        {
            armed = dragging = false;
            pressed = e.Source as InputElement;
            if (!e.GetCurrentPoint(sv).Properties.IsLeftButtonPressed) return;
            // 滚不动就别接:横不动的轨道上按住不放会把整页的选择/点击都吃掉
            if (sv.Extent.Width - sv.Viewport.Width <= 1) return;
            anchorX = e.GetPosition(sv).X;
            fromX = sv.Offset.X;
            armed = true;
        }, RoutingStrategies.Tunnel);

        sv.AddHandler(InputElement.PointerMovedEvent, (object? _, PointerEventArgs e) =>
        {
            if (!armed) return;
            var dx = e.GetPosition(sv).X - anchorX;
            if (!dragging)
            {
                if (Math.Abs(dx) < DragSlop) return;
                dragging = true;
                /* ☠ 取消卡片按下态的正路是**给它发一次 PointerCaptureLost**,
                   不是把松手那一下吃掉。实测(LP_RAILPROBE)两条都会咬人:
                   · 只抢指针不发这一下 —— Avalonia 的 Button 按下时**并不抓指针**,
                     抢了等于没抢,松手照样跳进详情页;
                   · 改成吃掉松手 —— Button 的 IsPressed 就永远停在 true,
                     它的状态机没走完,**下一次点卡片被整个吞掉**。 */
                pressed?.RaiseEvent(new PointerCaptureLostEventArgs(pressed, e.Pointer));
                e.Pointer.Capture(sv);
            }
            StopAt(sv, fromX - dx);
            e.Handled = true;
        }, RoutingStrategies.Tunnel);

        sv.AddHandler(InputElement.PointerReleasedEvent, (object? _, PointerReleasedEventArgs e) =>
        {
            // 把抢来的指针还回去 —— 不还的话它一直记在轨道名下
            if (dragging) e.Pointer.Capture(null);
            armed = dragging = false;
            pressed = null;
        }, RoutingStrategies.Tunnel);

        // 指针被别人抢走(弹窗、切页)时得收手,不然下一次移动会从一个陈旧的锚点算起
        sv.PointerCaptureLost += (_, _) => armed = dragging = false;
    }

    /// <summary>
    /// 拖拽期间把驱动器摁在当前位置。
    /// <para>不摁的话手和上一轮缓动同时在改 Offset:松手后内容会自己往回飘一段。</para>
    /// </summary>
    internal static void StopAt(ScrollViewer sv, double x)
    {
        var d = Drivers.GetValue(sv, _ => new Driver());
        d.Running = false;
        d.Gen++;  // 让上一轮的帧回调下一帧自己退场
        d.TargetX = Math.Clamp(x, 0, Math.Max(0, sv.Extent.Width - sv.Viewport.Width));
        d.TargetY = sv.Offset.Y;
        sv.Offset = sv.Offset.WithX(d.TargetX);
    }

    /// <summary>
    /// 自检:把驱动器摆成「上一轮还挂着但帧早就不来了」。
    ///
    /// <para>这正是窗口最小化 / 页面被顶掉之后留下的形状。摆完之后由调用方去点
    /// <b>真的翻页按钮</b>,再看轨道动没动 —— 动不了就是用户报的那个
    /// 「按钮还亮着,点下去一动不动」。</para>
    /// </summary>
    internal static void SelfCheckArmWedge(ScrollViewer sv)
    {
        var d = Drivers.GetValue(sv, _ => new Driver());
        d.Running = true;
        d.LastFrame = DateTime.MinValue;
        d.TargetX = -99999;   // 一个永远到不了的旧目标
    }

    /// <summary>
    /// 自检:让驱动器进「目标去不了」的死角,再看它退不退得出来。
    ///
    /// <para>返回 <c>(卡住没有, 试了几帧)</c>。<c>LP_SCROLLPROBE=1</c> 走这一条,
    /// 见 <c>Program.cs</c> —— 不开窗口,所以能在 CI 里跑。</para>
    /// </summary>
    internal static (bool Stuck, int Frames) SelfCheckStuck(ScrollViewer sv, double impossibleTarget)
    {
        var d = Drivers.GetValue(sv, _ => new Driver());
        d.TargetX = impossibleTarget;
        d.TargetY = 0;
        d.Running = true;               // 装成「上一轮还在跑」
        d.LastFrame = DateTime.MinValue; // 而且它的帧早就不来了
        var gen = ++d.Gen;
        // 手动跑帧循环:自检环境里没有渲染循环,RequestAnimationFrame 永远不回调
        for (var i = 1; i <= 60; i++)
        {
            if (gen != d.Gen) return (false, i);
            Clamp(sv, d);
            var cur = sv.Offset;
            var dx = d.TargetX - cur.X;
            if (Math.Abs(dx) < Snap) return (false, i);
            sv.Offset = new Vector(cur.X + dx * Approach, cur.Y);
            if ((sv.Offset - cur).Length < 0.01) return (false, i);
        }
        return (true, 60);
    }
}
