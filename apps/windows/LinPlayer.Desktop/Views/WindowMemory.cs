using System;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia.Controls;
using Avalonia.Threading;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 记住用户把窗口拉成了多大。
///
/// <para>用户 2026-09-12:「窗口大小无法记忆,第二次打开也不会按照尺寸自动缩放」。
/// 原先尺寸写死在 <c>MainWindow.axaml</c> 的 <c>Width="1280" Height="800"</c> 上,
/// 谁也没读过、没存过 —— 习惯小窗口的人每次开机第一件事是重新拉一遍。</para>
///
/// <para>落在核心层偏好里(<c>window_w/h/max</c>),不另开文件:
/// 绿色包的数据根只有一个,多一个文件就多一处要跟着备份和迁移的东西。</para>
/// </summary>
internal static class WindowMemory
{
    /// <summary>防抖。拖窗口时 SizeChanged 每帧都发,不防抖就是每帧写一次盘。</summary>
    private static readonly TimeSpan Debounce = TimeSpan.FromMilliseconds(700);

    /// <summary>
    /// 起手把尺寸摆好。**必须在窗口显示之前** —— 晚一步用户会看见窗口先弹出
    /// 一个默认大小再跳一下。
    ///
    /// <para>★ 最多等 1.5 秒(和界面字体同一个口径):核心层要是卡住了,
    /// 宁可按默认尺寸开,也不能卡在这儿不出窗口。</para>
    /// </summary>
    public static void Restore(Window w, CoreClient? core)
    {
        if (core is null) return;
        try
        {
            var t = Task.Run(() => core.CallAsync("prefs.getPrefs", new { }));
            if (!t.Wait(1500)) return;
            var p = t.Result;
            double W = Num(p, "window_w"), H = Num(p, "window_h");
            if (W >= w.MinWidth && H >= w.MinHeight)
            {
                var (maxW, maxH) = WorkArea(w);
                // 换了显示器 / 拔了外接屏之后,存下来的尺寸可能比现在这块屏还大。
                // 不夹的话窗口有一半在屏幕外,而标题栏可能正好落在看不见的那一半。
                w.Width = Math.Min(W, maxW);
                w.Height = Math.Min(H, maxH);
            }
            if (Flag(p, "window_max")) w.WindowState = WindowState.Maximized;
        }
        catch (Exception e) { Log.W("窗口", $"没读到上次的窗口尺寸,按默认开:{e.Message}"); }
    }

    /// <summary>盯住之后的变化,防抖落库。</summary>
    public static void Track(Window w, CoreClient? core)
    {
        if (core is null) return;
        var timer = new DispatcherTimer { Interval = Debounce };
        timer.Tick += (_, _) => { timer.Stop(); Save(w, core); };
        void Poke()
        {
            timer.Stop();
            timer.Start();
        }
        w.SizeChanged += (_, _) => Poke();
        w.PropertyChanged += (_, e) =>
        {
            if (e.Property == Window.WindowStateProperty) Poke();
        };
        /* 关窗口时再补一刀。防抖器多半已经写过了,这一下是保险:
           最后一次拖动离关窗不到 700ms 时,定时器还没响进程就没了。
           不 await —— 关窗路径上 await 一条命令就是让窗口多挂一会儿。 */
        w.Closing += (_, _) => Save(w, core);
    }

    private static void Save(Window w, CoreClient core)
    {
        /* 只记**普通窗口**的尺寸。最大化 / 全屏时量到的是整块屏幕,
           记下来就等于「退出最大化之后窗口和屏幕一样大」,那不是用户拉的那个尺寸。
           最小化时某些窗口管理器报 0,更不能记。 */
        object args = w.WindowState switch
        {
            WindowState.Normal => new
            {
                window_w = (int)Math.Round(w.ClientSize.Width),
                window_h = (int)Math.Round(w.ClientSize.Height),
                window_max = false,
            },
            WindowState.Maximized => new { window_max = true },
            _ => new { },   // 最小化 / 全屏:什么都别动
        };
        try { _ = core.CallAsync("prefs.setPrefs", args); }
        catch (Exception e) { Log.W("窗口", $"窗口尺寸没记住:{e.Message}"); }
    }

    /// <summary>当前屏幕的可用区域(已换算成 DIP)。问不到就给一个不设限的值。</summary>
    private static (double W, double H) WorkArea(Window w)
    {
        try
        {
            if (w.Screens.Primary is { } s && s.Scaling > 0)
                return (s.WorkingArea.Width / s.Scaling, s.WorkingArea.Height / s.Scaling);
        }
        catch { /* 有些平台在窗口显示之前问不到屏幕,那就不夹 —— 不夹只是窗口偏大 */ }
        return (double.MaxValue, double.MaxValue);
    }

    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v)
        && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : 0;

    private static bool Flag(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v)
        && v.ValueKind == JsonValueKind.True;
}
