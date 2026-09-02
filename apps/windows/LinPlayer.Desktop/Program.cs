using System;
using System.IO;
using Avalonia;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop;

internal static class Program
{
    /// <summary>进程级的核心层句柄。UI 的一切数据都从它来。</summary>
    public static CoreClient? Core { get; private set; }

    /// <summary>核心层起不来时的原因(启动页要如实显示,不能白屏)。</summary>
    public static string? CoreError { get; private set; }

    public static string Version => "0.1.0-go";

    [STAThread]
    public static void Main(string[] args)
    {
        /* ★ 控制台按 UTF-8 输出。Windows 默认代码页是 GBK,日志里的中文会变成一串问号 ——
           而自检脚本正是靠 grep 中文关键字读这些日志的,乱码 = 整套日志形同不存在。 */
        try { Console.OutputEncoding = System.Text.Encoding.UTF8; } catch { /* 无控制台时会抛,忽略 */ }

        var exeDir = AppContext.BaseDirectory;
        /* ★★ 数据全在 exe 同级的 userdata/(绿色包单一数据根)。
           用户明确要求过「不喜欢到处拉屎」—— 不要往 AppData 里写。
           这里只把根传给核心层,**路径的唯一出口在 core/paths**,UI 侧不自己拼。 */
        var dataDir = Path.Combine(exeDir, "userdata");
        var dll = Path.Combine(exeDir, "lpcore.dll");

        try
        {
            Core = new CoreClient(dll, dataDir, Version);
        }
        catch (Exception e)
        {
            // 不弹框、不静默退出:进主窗口显示原因。白屏是本项目最讨厌的失败形态。
            CoreError = e.Message;
        }

        BuildAvaloniaApp().StartWithClassicDesktopLifetime(args);

        /* 退出时调 lp_shutdown(Dispose 里)。它**阻塞到落盘完成**:停 mpv、
           关本地数据通道、停命令总线。

           ★ 实测说明:进度上报那条**不靠它** —— 关窗口时播放页的
             DetachedFromVisualTree 已经发过 player.stopPlayback,
             注入「不调 Dispose」跑一遍,/Sessions/Playing/Stopped 照样上报。
             所以这一句守的是**关停顺序与落盘**,不是上报;
             别拿上报当它的验收判据(我第一版就是这么错的)。 */
        Perf.Summary();
        Core?.Dispose();
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
