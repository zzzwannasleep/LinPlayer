using System;
using System.Linq;
using System.Reflection;
using System.IO;
using Avalonia;
using Avalonia.VisualTree;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop;

internal static class Program
{
    /// <summary>进程级的核心层句柄。UI 的一切数据都从它来。</summary>
    public static CoreClient? Core { get; private set; }

    /// <summary>核心层起不来时的原因(启动页要如实显示,不能白屏)。</summary>
    public static string? CoreError { get; private set; }

    /// <summary>本程序版本。
    ///
    /// **不许写死字面量。** 唯一权威是仓库根的 `VERSION`(见 docs/VERSIONING.md):
    /// CI 用 `dotnet publish -p:Version=&lt;版本&gt;` 注进程序集,这里回读。
    /// 2026-09-04 之前这里硬编码 `"0.1.0-go"`,而线上已经发到 `v1.0.0-build684` ——
    /// 照那样发布,更新检查会判定「已是最新」并**静默**卡死所有老用户。
    /// </summary>
    public static string Version =>
        System.Reflection.Assembly.GetExecutingAssembly()
            .GetCustomAttribute<System.Reflection.AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion
        ?? typeof(Program).Assembly.GetName().Version?.ToString()
        ?? "0.0.0-dev";

    [STAThread]
    public static void Main(string[] args)
    {
        /* 控制台按 UTF-8 输出。Windows 默认代码页是 GBK,日志里的中文会变成一串问号 ——
           而自检脚本正是靠 grep 中文关键字读这些日志的,乱码 = 整套日志形同不存在。 */
        try { Console.OutputEncoding = System.Text.Encoding.UTF8; } catch { /* 无控制台时会抛,忽略 */ }

        /* 界面字体自检:`LP_FONTPROBE=<字体文件> LinPlayer.exe` 打一行结果就退,不开窗口。
           ★ 它存在的理由和 core 那个 checkOptionNames 一样:界面字体走的是
             Avalonia 的 **internal** 接口(反射调),换版本时这一处会第一个坏,
             而坏了的样子是「设置里显示已换、界面一点没变」—— 光靠编译发现不了。
             升 Avalonia 之后跑一次这个。 */
        if (Environment.GetEnvironmentVariable("LP_FONTPROBE") is { } probeFont && probeFont.Length > 0)
        {
            AppBuilder.Configure<App>().UsePlatformDetect().SetupWithoutStarting();
            var ok = LinPlayer.Desktop.Core.UiFont.Apply(probeFont);
            Console.WriteLine($"PROBE 装上了={ok} 家族={LinPlayer.Desktop.Core.UiFont.Current?.Name ?? "(无)"}");
            return;
        }
        /* 响应式缩放自检:`LP_SCALEPROBE=1 LinPlayer.exe` 打几行就退。
           壳这一层没有单测工程,而缩放曲线是纯算术 —— 不给它一个能跑的门禁,
           改坏了只会在真机上表现成「窗口缩了里面没缩」,而编译全绿。 */
        if (Environment.GetEnvironmentVariable("LP_SCALEPROBE") is { Length: > 0 })
        {
            var bad = Views.Responsive.SelfCheck(Console.WriteLine);
            Console.WriteLine(bad == 0 ? "PROBE 缩放 全部通过" : $"PROBE 缩放 {bad} 条不过");
            Environment.ExitCode = bad == 0 ? 0 : 1;
            return;
        }
        /* 选集栏卡死自检:`LP_SCROLLPROBE=1 LinPlayer.exe` 打一行就退,不开窗口。
           判据是「目标去不了时,驱动器退不退得出来」—— 退不出来 = 之后每次点
           左右翻页按钮 Run() 都当场 return,按钮从此是死的(用户 2026-09-08 报的
           「有概率卡死」)。这类东西编译发现不了,只有把它逼进死角才看得见。 */
        if (Environment.GetEnvironmentVariable("LP_SCROLLPROBE") is { Length: > 0 })
        {
            AppBuilder.Configure<App>().UsePlatformDetect().SetupWithoutStarting();
            var sv = new Avalonia.Controls.ScrollViewer
            {
                Width = 200, Height = 100,
                Content = new Avalonia.Controls.Border { Width = 400, Height = 100 },
            };
            /* 量一遍,让 Extent/Viewport 有真值。
               ☠ **ApplyTemplate 不能省**:ScrollViewer 的 Extent 是它模板里那个
                 ScrollContentPresenter 报上来的,没套模板就永远是 0×0 ——
                 那样滚哪儿都一样,自检等于在一个滚不动的控件上跑,永远绿。 */
            sv.ApplyTemplate();
            sv.Measure(new Size(200, 100));
            sv.Arrange(new Rect(0, 0, 200, 100));
            sv.UpdateLayout();
            /* 没有可视根,Extent 会是 0 —— 这**正好**是我们要的形状:
               目标去不了、Offset 的 setter 把值压回原处。真机上造成同一个形状的是
               虚拟化轨道估变的 Extent。 */
            Console.WriteLine($"PROBE 滚动 · 量程 Extent={sv.Extent.Width:0.#}(0 = 目标去不了,正是要逼出来的死角)");
            // 目标 9999:远超 Extent-Viewport(=200),ScrollViewer 会把 Offset 压回 200
            var (stuck, frames) = Views.Smooth.SelfCheckStuck(sv, 9999);
            Console.WriteLine(stuck
                ? $"PROBE 滚动 ✗ 卡住了(跑满 {frames} 帧还没退出)—— 翻页按钮会变成死的"
                : $"PROBE 滚动 ✓ 第 {frames} 帧退出,偏移停在 {sv.Offset.X:0.#}");
            // ☠ 退出码以前一直是 0:probes-win.sh 按退出码判,这一组等于打了字没人听
            if (stuck) Environment.ExitCode = 1;
            /* 第二道闸:窗口最小化时渲染循环停了,排进去的那一帧永远不会来。
               只判 Running 一个字段的话它永远停在 true,之后每次点按钮都当场 return。 */
            var fresh = Views.Smooth.StillAlive(true, DateTime.UtcNow);
            var stale = Views.Smooth.StillAlive(true, DateTime.UtcNow.AddSeconds(-5));
            Console.WriteLine(fresh && !stale
                ? "PROBE 滚动 ✓ 帧停了 5 秒的那一轮会被判死并重启"
                : $"PROBE 滚动 ✗ 停帧判定坏了(刚跑过={fresh} 停了5秒={stale})—— 最小化再还原后按钮会是死的");
            if (!fresh || stale) Environment.ExitCode = 1;
            return;
        }

        /* 网速读数自检:`LP_NETPROBE=1 LinPlayer.exe` 打几行就退,不开窗口。
           读数坏掉的样子是「顶栏上那一格不见了」或者「永远 0 KB/s」——
           两种都不报错,而且看上去像网络问题,不像我们的问题。 */
        if (Environment.GetEnvironmentVariable("LP_NETPROBE") is { Length: > 0 })
        {
            Environment.ExitCode = NetProbe() ? 0 : 1;
            return;
        }

        /* mpv 键名自检:`LP_KEYPROBE=1 LinPlayer.exe` 打几行就退,不开窗口。
           纯映射,进得了 CI。 */
        if (Environment.GetEnvironmentVariable("LP_KEYPROBE") is { Length: > 0 })
        {
            Environment.ExitCode = KeyProbe() ? 0 : 1;
            return;
        }

        /* 选集轨道自检:`LP_RAILPROBE=1 LinPlayer.exe` 打几行就退,不开窗口。
           上一轮只钉住了驱动器本身,而用户 2026-09-12 报的还是「点左右按钮卡死」——
           说明该钉的是**整条轨道**:一千条数据 + 真的虚拟化面板 + 真的翻页按钮,
           从头点到尾再点回来。只测驱动器测不出「按钮自己消失了」这一类死法。 */
        if (Environment.GetEnvironmentVariable("LP_RAILPROBE") is { Length: > 0 })
        {
            AppBuilder.Configure<App>().UsePlatformDetect().SetupWithoutStarting();
            Environment.ExitCode = RailProbe() ? 0 : 1;
            return;
        }

        Perf.Log("Main 入口");
        var exeDir = AppContext.BaseDirectory;
        /* 数据全在 exe 同级的 userdata/(绿色包单一数据根)。
           用户明确要求过「不喜欢到处拉屎」—— 不要往 AppData 里写。
           这里只把根传给核心层,**路径的唯一出口在 core/paths**,UI 侧不自己拼。 */
        var dataDir = Path.Combine(exeDir, "userdata");
        var dll = Path.Combine(exeDir, "lpcore.dll");
        // 元数据缓存和核心层共用一个数据根。它必须在任何页面构造之前就绪 ——
        // 晚一步的话首屏那几条读命令全部落空,而「首屏」正是它唯一要救的那一屏。
        MetaCache.Init(dataDir);
        // 日志要早于一切页面 —— 它是用来抓「只在用户那台机器上出现」的现象的
        Log.Init(dataDir);

        try
        {
            Core = new CoreClient(dll, dataDir, Version);
        }
        catch (Exception e)
        {
            // 不弹框、不静默退出:进主窗口显示原因。白屏是本项目最讨厌的失败形态。
            CoreError = e.Message;
        }

        Perf.Log("核心层就绪");
        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);

        /* 退出时调 lp_shutdown(Dispose 里)。它**阻塞到落盘完成**:停 mpv、
           关本地数据通道、停命令总线。

            实测说明:进度上报那条**不靠它** —— 关窗口时播放页的
             DetachedFromVisualTree 已经发过 player.stopPlayback,
             注入「不调 Dispose」跑一遍,/Sessions/Playing/Stopped 照样上报。
             所以这一句守的是**关停顺序与落盘**,不是上报;
             别拿上报当它的验收判据(我第一版就是这么错的)。 */
        Perf.Summary();
        Core?.Dispose();
    }

    /// <summary>
    /// 网速读数自检。纯算术 + 一次真采样,不开窗口,进得了 CI。
    /// </summary>
    private static bool NetProbe()
    {
        var bad = 0;
        void Eq(string got, string want, string what)
        {
            if (got == want) { Console.WriteLine($"PROBE 网速 ✓ {what}"); return; }
            Console.WriteLine($"PROBE 网速 ✗ {what}:得到「{got}」,该是「{want}」");
            bad++;
        }
        Eq(Views.NetSpeed.Fmt(2L * 1024 * 1024, 1), "2.0 MB/s", "兆档一位小数");
        Eq(Views.NetSpeed.Fmt(512_000, 1), "500 KB/s", "千档不带小数");
        Eq(Views.NetSpeed.Fmt(100, 1), "0 KB/s", "太慢也给个 0,不给空");
        Eq(Views.NetSpeed.Fmt(1024, 0), "", "没走过时间不给数");
        Eq(Views.NetSpeed.Fmt(-1, 1), "", "字节倒退不给数");

        /* 计数器**只能往前**。倒退的话两次相减是负数,Fmt 返回空串 ——
           表现是顶栏上那一格时有时无,而不是报错。 */
        var a = Views.NetSpeed.TotalRx();
        var b = Views.NetSpeed.TotalRx();
        if (a < 0 && b < 0) Console.WriteLine("PROBE 网速 ✓ 这台机器问不到网卡统计,那一格本就不画");
        else if (b >= a && a >= 0) Console.WriteLine($"PROBE 网速 ✓ 整机计数只往前({a} → {b})");
        else { Console.WriteLine($"PROBE 网速 ✗ 整机计数倒退了({a} → {b})"); bad++; }

        Console.WriteLine(bad == 0 ? "PROBE 网速 全部通过" : $"PROBE 网速 {bad} 条不过");
        return bad == 0;
    }

    /// <summary>
    /// 按键翻成 mpv 键名。纯映射,不开窗口,进得了 CI。
    ///
    /// <para>它钉的是 <c>input.conf</c> 那条链的入口:名字翻错了,用户写的绑定
    /// 一条都对不上,而且<b>一句错都不报</b> —— 只是「按了没反应」。</para>
    /// </summary>
    private static bool KeyProbe()
    {
        var bad = 0;
        void Eq(string? got, string? want, string what)
        {
            if (got == want) { Console.WriteLine($"PROBE 键名 ✓ {what}"); return; }
            Console.WriteLine($"PROBE 键名 ✗ {what}:得到「{got ?? "(不转)"}」,该是「{want ?? "(不转)"}」");
            bad++;
        }
        const Avalonia.Input.KeyModifiers none = Avalonia.Input.KeyModifiers.None;
        const Avalonia.Input.KeyModifiers ctrl = Avalonia.Input.KeyModifiers.Control;
        const Avalonia.Input.KeyModifiers shift = Avalonia.Input.KeyModifiers.Shift;

        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.D, none), "d", "字母是小写");
        // 单字母 + Shift 在 mpv 那边就是大写字母本身。写成 Shift+d 的话
        //    用户 input.conf 里那条 `D` 永远匹配不上,而且不报错
        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.D, shift), "D", "Shift+字母折成大写");
        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.D, ctrl), "Ctrl+d", "Ctrl 加前缀");
        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.D, ctrl | shift), "Ctrl+Shift+d", "两个修饰键同时在");
        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.Space, none), "SPACE", "命名键大写");
        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.PageDown, none), "PGDWN", "翻页键是 PGDWN 不是 PGDOWN");
        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.F5, none), "F5", "功能键");
        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.D7, none), "7", "数字键只给数字");
        // 修饰键本身按下时也来一次 KeyDown。转过去等于每次组合键都先给 mpv 一个孤立的 Ctrl
        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.LeftCtrl, ctrl), null, "修饰键自己不转");
        Eq(Views.MpvKeys.Name(Avalonia.Input.Key.ImeConvert, none), null, "输入法键不转");

        Console.WriteLine(bad == 0 ? "PROBE 键名 全部通过" : $"PROBE 键名 {bad} 条不过");
        return bad == 0;
    }

    /// <summary>
    /// 选集轨道从头点到尾、再点回来,全程按钮都得点得动。
    ///
    /// <para>造的是**真的** <see cref="Views.Carousel.Rail"/>(虚拟化面板 + 两颗真按钮),
    /// 点的是按钮自己的 Click —— 抄一段 GlideX 出来测的话,测的是那份抄本。</para>
    ///
    /// <para>☠ <b>必须开一个真窗口。</b> 没有可视根时 ScrollViewer 的 Extent 恒为 0,
    /// 而 Extent 是 0 就意味着「滚哪儿都一样」—— 每一句断言都会白白变绿
    /// (第一版正是这么写的,四条假绿)。所以它不进 CI,跟 selfcheck 一起手跑。</para>
    /// </summary>
    private static bool RailProbe()
    {
        // 条数可从环境覆盖:上千集那一档要单独跑一遍(`LP_RAILPROBE_N=1000`)
        var n = int.TryParse(Environment.GetEnvironmentVariable("LP_RAILPROBE_N"), out var nn) ? nn : 200;
        const int cardW = 214;
        var items = Enumerable.Range(1, n).ToList();
        // 卡片用真 Button:轨道里的卡就是 Button,而「拖完松手会不会被当成点击」
        // 只有让真 Button 参与整条路由才测得出来
        var clicks = 0;
        var panel = (Avalonia.Controls.Panel)Views.Carousel.Rail(items, _ =>
        {
            var b = new Avalonia.Controls.Button { Width = cardW, Height = 120 };
            b.Click += (_, _) => clicks++;
            return b;
        }, 120, out var sv);

        var w = new Avalonia.Controls.Window
        {
            Width = 900, Height = 240, ShowInTaskbar = false,
            SystemDecorations = Avalonia.Controls.SystemDecorations.None,
            Content = panel,
        };
        w.Show();

        /// 把消息泵跑一阵,让布局、虚拟化和 RequestAnimationFrame 都走完
        void Pump(int ms)
        {
            var t0 = DateTime.UtcNow;
            while ((DateTime.UtcNow - t0).TotalMilliseconds < ms)
            {
                Avalonia.Threading.Dispatcher.UIThread.RunJobs();
                System.Threading.Thread.Sleep(4);
            }
        }
        Pump(400);

        var arrows = panel.Children.OfType<Avalonia.Controls.Button>().ToList();
        var bad = 0;
        void Want(bool ok, string what)
        {
            Console.WriteLine((ok ? "PROBE 轨道 ✓ " : "PROBE 轨道 ✗ ") + what);
            if (!ok) bad++;
        }
        if (arrows.Count != 2)
        {
            Console.WriteLine($"PROBE 轨道 ✗ 没找到两颗翻页按钮(找到 {arrows.Count} 颗)");
            w.Close();
            return false;
        }
        var (left, right) = (arrows[0], arrows[1]);

        var max = sv.Extent.Width - sv.Viewport.Width;
        Console.WriteLine($"PROBE 轨道 · {n} 条 量程 Extent={sv.Extent.Width:0} 视口={sv.Viewport.Width:0} 可滚={max:0}");
        // 这一条是**前置闸**:量程报不出来的话,后面每一句都是假绿
        Want(max > cardW * 10, "虚拟化面板报得出真量程(报不出来后面全是假绿)");

        // 点一下,再等它滑完(缓动是 8 帧,这里给足 300ms)
        void Click(Avalonia.Controls.Button b)
        {
            b.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Avalonia.Controls.Button.ClickEvent));
            Pump(180);   // 缓动 8 帧约 130ms
        }

        // ① 一路点到尽头。一次翻 80% 视口,一千张卡要点三百多下
        var steps = 0;
        var stalled = 0;
        for (; steps < 800 && sv.Offset.X < max - 1; steps++)
        {
            var before = sv.Offset.X;
            // 两颗按钮**不能同时没有** —— 那就是用户说的「卡死」的样子
            if (!left.IsVisible && !right.IsVisible) { Want(false, $"第 {steps} 步两颗按钮一起消失了"); break; }
            if (!right.IsVisible) { Want(false, $"第 {steps} 步「›」提前消失,才走到 {before:0}/{max:0}"); break; }
            Click(right);
            if (sv.Offset.X - before < 1) stalled++;
        }
        Want(sv.Offset.X >= max - 1, $"连点「›」{steps} 下走到尽头(停在 {sv.Offset.X:0}/{max:0})");
        Want(stalled == 0, $"中途没有一下是白点的(白点了 {stalled} 下)");
        Want(!right.IsVisible && left.IsVisible, "到尽头之后「›」收起、「‹」还在");

        // ② 再点回来
        var back = 0;
        for (; back < 800 && sv.Offset.X > 1; back++)
        {
            if (!left.IsVisible) { Want(false, $"回程第 {back} 步「‹」提前消失,还剩 {sv.Offset.X:0}"); break; }
            Click(left);
        }
        Want(sv.Offset.X <= 1, $"连点「‹」{back} 下回到开头(停在 {sv.Offset.X:0})");

        /* **连点不等它滑完。** 上面两段每点一下都等 180ms 滑完,而真人一秒点五下 ——
           那条路走的是「上一轮还活着」那个分支,和等滑完完全不是同一段代码。
           用户 2026-09-12:「点击了还是会卡死,稳定复现」。 */
        Views.Smooth.StopAt(sv, 0);
        Pump(150);
        for (var i = 0; i < 40; i++)
        {
            right.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Avalonia.Controls.Button.ClickEvent));
            Pump(20);   // 远小于一次缓动(约 130ms):下一下必定落在上一轮还在跑的时候
        }
        Pump(600);      // 手停了,让最后一轮滑完
        Want(sv.Offset.X > cardW * 4, $"连点 40 下(不等它滑完)确实走了(停在 {sv.Offset.X:0}/{max:0})");
        var stillMoves = sv.Offset.X;
        Click(right);
        Want(sv.Offset.X > stillMoves + 1 || stillMoves >= max - 1,
            $"连点之后再点一下还走得动(从 {stillMoves:0} 到 {sv.Offset.X:0})");

        /* 到尽头时**最后一张卡要贴着右边缘**(用户 2026-09-12:「自动把最后一集贴边」)。
           每一项都带 gap 的右外边距,包括最后一项 —— 于是量程里多出一个 gap,
           滑到底之后右边空着一条 16px 的缝,看着像「还没到底但不动了」。 */
        Views.Smooth.StopAt(sv, 1e9);
        Pump(200);
        var lastCard = sv.GetVisualDescendants().OfType<Avalonia.Controls.Button>()
            .OrderByDescending(b => b.TranslatePoint(new Point(b.Bounds.Width, 0), w)?.X ?? double.MinValue)
            .FirstOrDefault();
        var rightEdge = lastCard?.TranslatePoint(new Point(lastCard.Bounds.Width, 0), w)?.X ?? -1;
        Want(rightEdge > 0 && Math.Abs(rightEdge - sv.Viewport.Width) < 1.5,
            $"滑到底时最后一张卡贴着右边缘(卡右沿 {rightEdge:0.#} vs 视口 {sv.Viewport.Width:0})");
        // 复位:下一条从开头点起,不然它是在尽头点「›」,挪不动是应该的
        Views.Smooth.StopAt(sv, 0);
        Pump(150);

        /* ③ 驱动器挂着「还在跑」但帧早就不来了 —— 最小化 / 页面被顶掉之后就是这个形状。
              这一条红过:GlideX 原来只判 Running 字段,于是目标一直叠在一个
              永远到不了的旧值上,按钮还亮着但点下去一动不动。 */
        var at = sv.Offset.X;
        Views.Smooth.SelfCheckArmWedge(sv);
        Click(right);
        var moved = sv.Offset.X - at;
        Want(moved > 1, $"「上一轮还挂着但帧不来了」之后点一下仍然走得动(挪了 {moved:0.#}px)");

        /* ④⑤ 按住左键拖。合成真的指针事件,从**卡片自己**发出去 ——
              这样隧道阶段会经过轨道(我们的处理器在那儿),冒泡阶段会回到卡片
              (Button 的点击判定在那儿)。只调 StopAt 测不出这两件事里的任何一件。 */
        // 按下点要**贴着卡片自己算**:轨道一滚卡就挪位了,写死一个窗口坐标的话
        // 第二次按下早已落在卡外,Button 的命中测试不通过 —— 那是探针的错,不是代码的错
        Avalonia.Controls.Button? Card()
        {
            Pump(120);
            return sv.GetVisualDescendants().OfType<Avalonia.Controls.Button>().FirstOrDefault();
        }
        double MidX(Avalonia.Controls.Control c) =>
            c.TranslatePoint(new Point(c.Bounds.Width / 2, 0), w)?.X ?? 0;

        Views.Smooth.StopAt(sv, 0);
        if (Card() is not { } card) { Want(false, "轨道里一张卡都没造出来,拖拽没法测"); }
        else
        {
            double Gesture(double dx)
            {
                Views.Smooth.StopAt(sv, 0);
                Pump(120);
                clicks = 0;
                var x = MidX(card);
                Drag(w, card, x, x - dx);
                Pump(200);
                return sv.Offset.X;
            }

            // 拖多远走多远,一比一跟手;而且松手**不算**点了这张卡
            var went = Gesture(160);
            Want(Math.Abs(went - 160) < 2, $"拖多远走多远(走了 {went:0}px,该走 160)");
            Want(clicks == 0, $"拖完松手不算点击(卡片被点开了 {clicks} 次)");

            /* ☠ 拖完之后**下一次点击不许被吞**。这一条是本轮实测抓出来的:
               「把松手那一下吃掉」会让卡片的 IsPressed 永远停在 true,
               它的状态机没走完,下一次点卡片整个没反应。 */
            var after = Gesture(0);
            Want(Math.Abs(after) < 0.5 && clicks == 1,
                $"拖完之后卡片照样点得开(轨道没动={Math.Abs(after) < 0.5} 点开了 {clicks} 次)");

            // 手抖几个像素仍然算点击 —— 没有这道阈值的话卡片永远点不开
            var jitter = Gesture(DragSlopProbe - 1);
            Want(Math.Abs(jitter) < 0.5 && clicks == 1,
                $"手抖 {DragSlopProbe - 1:0} 像素仍然算点击(轨道没动={Math.Abs(jitter) < 0.5} 点开了 {clicks} 次)");
            // 越过阈值就是拖,不是点
            var past = Gesture(DragSlopProbe);
            Want(Math.Abs(past - DragSlopProbe) < 0.5 && clicks == 0,
                $"越过 {DragSlopProbe:0} 像素就转成拖拽(走了 {past:0} 点开了 {clicks} 次)");
        }

        w.Close();
        Console.WriteLine(bad == 0 ? "PROBE 轨道 全部通过" : $"PROBE 轨道 {bad} 条不过");
        return bad == 0;
    }

    /// <summary>
    /// 合成一次「按下 → 横移 → 松手」。<paramref name="from"/> / <paramref name="to"/>
    /// 是相对窗口的横坐标。
    /// <para>事件从 <paramref name="src"/>(一张卡)发出去,路由才会和真鼠标一样
    /// 先隧道经过轨道、再冒泡回到卡片。</para>
    /// </summary>
    /// <summary>起拖阈值,和 <see cref="Views.Smooth"/> 里那个必须一致 ——
    /// 探针写死一个自己的数,改了阈值它还是绿的。</summary>
    private const double DragSlopProbe = 6;

    private static readonly Avalonia.Input.Pointer MousePtr =
        new(1, Avalonia.Input.PointerType.Mouse, true);   // 真鼠标全程是同一个指针

    private static void Drag(Avalonia.Controls.Window w, Avalonia.Controls.Control src, double from, double to)
    {
        var ptr = MousePtr;
        var down = new Avalonia.Input.PointerPointProperties(
            Avalonia.Input.RawInputModifiers.LeftMouseButton,
            Avalonia.Input.PointerUpdateKind.LeftButtonPressed);
        var up = new Avalonia.Input.PointerPointProperties(
            Avalonia.Input.RawInputModifiers.None,
            Avalonia.Input.PointerUpdateKind.LeftButtonReleased);
        const double y = 60;

        src.RaiseEvent(new Avalonia.Input.PointerPressedEventArgs(
            src, ptr, w, new Point(from, y), 0, down, Avalonia.Input.KeyModifiers.None));
        // 分几步挪:真鼠标不会一步到位,而起拖阈值判的正是「这一步走了多远」
        for (var i = 1; i <= 4; i++)
        {
            var x = from + (to - from) * i / 4.0;
            src.RaiseEvent(new Avalonia.Input.PointerEventArgs(
                Avalonia.Input.InputElement.PointerMovedEvent, src, ptr, w,
                new Point(x, y), 0, down, Avalonia.Input.KeyModifiers.None));
        }
        src.RaiseEvent(new Avalonia.Input.PointerReleasedEventArgs(
            src, ptr, w, new Point(to, y), 0, up, Avalonia.Input.KeyModifiers.None,
            Avalonia.Input.MouseButton.Left));
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
