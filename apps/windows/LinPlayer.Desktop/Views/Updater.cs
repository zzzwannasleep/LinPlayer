using System;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.ApplicationLifetimes;
using Avalonia.Layout;
using Avalonia.Controls.Primitives;
using Avalonia.Media;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 应用内一条龙更新的界面那一半:一个弹窗从头走到尾。
///
/// <para>抽出来是因为有**两个入口**:设置页的「检查更新」和启动时的自动检查。
/// 两边只差一句开场白,流程一模一样 —— 各写一遍必然有一边先烂掉。</para>
/// </summary>
internal static class Updater
{
    /// <summary>把字节数说成人话。</summary>
    private static string MB(long n) => (n / 1024.0 / 1024).ToString("0.0") + " MB";

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) &&
        v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";

    private static long Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) &&
        v.ValueKind == JsonValueKind.Number ? v.GetInt64() : 0;

    private static bool Flag(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) &&
        v.ValueKind is JsonValueKind.True or JsonValueKind.False && v.GetBoolean();

    /// <summary>
    /// 查一次。<paramref name="quiet"/> = 没有新版就一声不吭(启动自检用它)。
    /// </summary>
    public static async Task Check(Visual anchor, CoreClient core, bool quiet)
    {
        JsonElement r;
        try { r = await core.SystemCheckUpdate(new { }); }
        catch (Exception e)
        {
            // 「查不动」和「已是最新」是两件事。静默模式下前者也不该弹,但要留日志
            if (quiet) { Log.W("update", "检查更新失败: " + e.Message); return; }
            await Dialogs.Tell(anchor, "检查更新", LibraryPage.Advice(e));
            return;
        }
        if (!Flag(r, "has_update") || !r.TryGetProperty("update", out var u))
        {
            if (!quiet) await Dialogs.Tell(anchor, "检查更新", "已经是最新版本了。");
            return;
        }
        await Offer(anchor, core, u, Flag(r, "can_self_update"));
    }

    /// <summary>
    /// 更新说明那一块。**可滚动,不截断。**
    ///
    /// <para>原来是 <c>notes[..600]</c> 一刀切。而发布说明前面那段「下载在哪、
    /// 数据目录在哪」是每次都一样的固定文案 —— 六百个字正好全给了它,真正改了
    /// 什么被切在后面(用户 2026-09-12:「更新 md 一直是固定的,牛头不对马嘴」)。
    /// 文案顺序已经在 publish.yml 里掉过来了,这里把剩下的那一半放开。</para>
    /// </summary>
    private static Control Notes(string text, string tail)
    {
        var body = new StackPanel
        {
            Spacing = 10,
            Children = { new TextBlock { Text = text, Classes = { "dim" }, TextWrapping = TextWrapping.Wrap } },
        };
        if (tail.Length > 0)
            body.Children.Add(new TextBlock { Text = tail, TextWrapping = TextWrapping.Wrap });
        return new ScrollViewer
        {
            // 封顶 360:再长就是一个比屏幕还高的弹窗,确定键会被顶到看不见的地方
            MaxHeight = 360, MaxWidth = 460,
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            Content = body,
        };
    }

    /// <summary>问一句要不要装,然后一条龙走完。</summary>
    private static async Task Offer(Visual anchor, CoreClient core, JsonElement u, bool canSelfUpdate)
    {
        var notes = Str(u, "notes");
        var title = "新版本 " + Str(u, "version");

        if (!canSelfUpdate)
        {
            /* 写不进安装目录(多半解压在 Program Files)。这里**不给「立即更新」** ——
               摆一个点了必然失败的按钮比没有更糟。 */
            await Dialogs.Show(anchor, title, Notes(notes,
                    "程序所在的文件夹写不进去,没法自动覆盖。\n" +
                    "把整个文件夹挪到个人目录下再试,或者去这里手动下载:\n" + Str(u, "html_url")),
                "知道了", null);
            return;
        }

        var size = Num(u, "asset_size");
        var tail = size > 0 ? "安装包 " + MB(size) + ",下载完会自动重启装上。" : "";
        if (!await Dialogs.Show(anchor, title, Notes(notes, tail), "下载并安装", "取消")) return;

        await RunInstall(anchor, core);
    }

    /// <summary>下载 → 进度 → 装上 → 退出。全程一个弹窗,中途能取消。</summary>
    private static async Task RunInstall(Visual anchor, CoreClient core)
    {
        if (TopLevel.GetTopLevel(anchor) is not Window owner) return;

        var bar = new ProgressBar { Minimum = 0, Maximum = 100, Height = 6, Width = 320 };
        var text = new TextBlock { Text = "正在下载…", Classes = { "dim" } };
        var cancel = new Button { Classes = { "ghost" }, Content = "取消", MinHeight = 32 };
        var dlg = new Window
        {
            Title = "更新", SizeToContent = SizeToContent.WidthAndHeight, CanResize = false,
            WindowStartupLocation = WindowStartupLocation.CenterOwner,
            Content = new Border
            {
                Padding = new Thickness(18),
                Child = new StackPanel
                {
                    Spacing = 14,
                    Children =
                    {
                        new TextBlock { Text = "正在更新", FontSize = 16, FontWeight = FontWeight.SemiBold },
                        bar, text,
                        new StackPanel
                        {
                            Orientation = Orientation.Horizontal, Spacing = 10,
                            HorizontalAlignment = HorizontalAlignment.Right,
                            Children = { cancel },
                        },
                    },
                },
            },
        };

        var stopped = false;
        cancel.Click += async (_, _) =>
        {
            stopped = true;
            try { await core.SystemCancelUpdate(new { }); } catch { /* 掐不掉也要关窗,不能把用户困在这儿 */ }
            dlg.Close();
        };
        dlg.Closed += (_, _) => stopped = true;

        try { await core.SystemDownloadUpdate(new { }); }
        catch (Exception e) { await Dialogs.Tell(anchor, "更新", LibraryPage.Advice(e)); return; }

        _ = dlg.ShowDialog(owner);

        // 轮询,不订阅事件 —— 和下载管理器同一个口径:一个活跃任务不值得开一条事件流
        while (!stopped)
        {
            await Task.Delay(400);
            JsonElement p;
            try { p = await core.SystemUpdateProgress(new { }); }
            catch (Exception e) { text.Text = LibraryPage.Advice(e); continue; }

            var got = Num(p, "downloaded");
            var total = Num(p, "total");
            var phase = Str(p, "phase");
            if (total > 0) bar.Value = Math.Clamp(got * 100.0 / total, 0, 100);
            else bar.IsIndeterminate = true;

            if (phase == "downloading")
            {
                text.Text = total > 0 ? $"正在下载 {MB(got)} / {MB(total)}" : "正在下载 " + MB(got);
                continue;
            }
            if (phase == "failed")
            {
                dlg.Close();
                await Dialogs.Tell(anchor, "更新失败", Str(p, "error"));
                return;
            }
            if (phase != "ready") continue;

            bar.Value = 100;
            text.Text = "下载完成,正在准备安装…";
            JsonElement r;
            try { r = await core.SystemInstallUpdate(new { }); }
            catch (Exception e)
            {
                dlg.Close();
                await Dialogs.Tell(anchor, "更新失败", LibraryPage.Advice(e));
                return;
            }
            dlg.Close();
            /* 覆盖脚本已经在等这个进程退出了。**必须真的退出** ——
               不退的话它等满 120 秒超时后照样覆盖,而那时 exe 还锁着,
               用户看到的是「更新完什么都没变」。 */
            if (Str(r, "action") == "restart")
            {
                await Dialogs.Tell(anchor, "更新", "已经准备好了,点确定后程序会关掉并自动装上新版本。");
                Dispatcher.UIThread.Post(() =>
                    (Application.Current?.ApplicationLifetime as IClassicDesktopStyleApplicationLifetime)
                        ?.Shutdown());
            }
            return;
        }
    }
}
