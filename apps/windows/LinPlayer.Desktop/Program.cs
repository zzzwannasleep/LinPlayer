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
    }

    public static AppBuilder BuildAvaloniaApp() =>
        AppBuilder.Configure<App>()
            .UsePlatformDetect()
            .WithInterFont()
            .LogToTrace();
}
