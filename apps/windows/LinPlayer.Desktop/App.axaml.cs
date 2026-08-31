using Avalonia;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Markup.Xaml;
using LinPlayer.Desktop.Views;

namespace LinPlayer.Desktop;

public partial class App : Application
{
    public override void Initialize() => AvaloniaXamlLoader.Load(this);

    public override void OnFrameworkInitializationCompleted()
    {
        if (ApplicationLifetime is IClassicDesktopStyleApplicationLifetime desktop)
        {
            desktop.MainWindow = new MainWindow();
            // ★ 退出时必须把核心层关干净:不关的话事件线程还在,进程退不掉
            //   —— Rust 版栽过同款(播放窗藏起来不销毁,窗口系统永远等不到「最后一个窗口关闭」)。
            desktop.ShutdownRequested += (_, _) => Program.Core?.Dispose();
        }
        base.OnFrameworkInitializationCompleted();
    }
}
