using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 设置页的「快捷键」分组。数据源是 <see cref="Actions.All"/>,这里一条键位都不写死 ——
/// 写死的那一份迟早和真正生效的那一份分家。
/// </summary>
public static class SettingsKeys
{
    public static Control Section(CoreClient core)
    {
        var body = new StackPanel { Spacing = 10 };
        var hint = new TextBlock
        {
            Classes = { "dim" }, TextWrapping = TextWrapping.Wrap,
            Text = "点键位改。同一个键被两条动作抢时,后设的那条赢,原来那条自动让出来。",
        };

        void Reload()
        {
            body.Children.Clear();
            foreach (var g in Actions.All.GroupBy(a => a.Group))
            {
                body.Children.Add(new TextBlock
                {
                    Text = g.Key, FontSize = 12, FontWeight = FontWeight.SemiBold,
                    Foreground = Tok.Of("Ink3"), Margin = new Thickness(0, 6, 0, 0),
                });
                foreach (var a in g) body.Children.Add(RowOf(core, a, Reload));
            }
            body.Children.Add(new TextBlock
            {
                Text = Actions.FixedNote, FontSize = 12, TextWrapping = TextWrapping.Wrap,
                Foreground = Tok.Of("Ink3"), Margin = new Thickness(0, 10, 0, 0),
            });
        }
        Reload();

        return new Border
        {
            Classes = { "card" }, Padding = new Thickness(18, 18),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            Child = new StackPanel
            {
                Spacing = 10,
                Children = { new TextBlock { Text = "快捷键", Classes = { "h2" } }, hint, body },
            },
        };
    }

    /// <summary>一行:动作名 + 一个能点开的键位按钮。</summary>
    private static Control RowOf(CoreClient core, ActionDef a, Action reload)
    {
        var keys = Actions.KeysOf(a.Id);
        var btn = new Button
        {
            Classes = { "ghost" }, MinWidth = 210,
            Content = keys.Length > 0 ? keys : Actions.None,
        };
        btn.Click += (_, _) => Menu(core, a, btn, reload);

        return new Grid
        {
            ColumnDefinitions = new ColumnDefinitions("*,Auto"),
            Children =
            {
                new TextBlock
                {
                    [Grid.ColumnProperty] = 0, Text = a.Name,
                    VerticalAlignment = VerticalAlignment.Center,
                    Foreground = Actions.Changed(a.Id) ? Tok.Of("Accent") : Tok.Of("Ink"),
                },
                new Border { [Grid.ColumnProperty] = 1, Child = btn },
            },
        };
    }

    /// <summary>
    /// 改键的菜单。<b>鼠标键从菜单里挑,不用「点哪个算哪个」</b> ——
    /// 后者会把「点菜单本身」也当成一次绑定,而用户根本没法退出这个状态。
    /// </summary>
    private static void Menu(CoreClient core, ActionDef a, Button anchor, Action reload)
    {
        var items = new List<(string, Action?)>
        {
            ("按一下键盘上的键…", () => Capture(core, a, anchor, reload)),
            ("鼠标左键", () => Bind(core, a, "鼠标左键", reload)),
            ("鼠标右键", () => Bind(core, a, "鼠标右键", reload)),
            ("鼠标中键", () => Bind(core, a, "鼠标中键", reload)),
            ("侧键1", () => Bind(core, a, "侧键1", reload)),
            ("侧键2", () => Bind(core, a, "侧键2", reload)),
            ("滚轮上", () => Bind(core, a, "滚轮上", reload)),
            ("滚轮下", () => Bind(core, a, "滚轮下", reload)),
            ("解绑", () => Bind(core, a, Actions.None, reload)),
            ($"改回默认({a.Keys})", async () => { await Actions.ResetAsync(core, a.Id); reload(); }),
        };
        DetailPage.Flyout(anchor, items!);
    }

    private static async void Bind(CoreClient core, ActionDef a, string spec, Action reload)
    {
        await Actions.BindAsync(core, a.Id, spec);
        reload();
        Toast.Show($"「{a.Name}」改成 {spec}");
    }

    /// <summary>
    /// 捕获下一次按键。挂在 <b>TopLevel 的隧道阶段</b>并且一次就摘 ——
    /// 不摘的话用户后面每按一个键都在改这一条,而界面上看不出自己还在捕获态。
    ///
    /// <para>Esc 退出捕获,不当成键位:退不出去的模式比设不上键更糟。</para>
    /// </summary>
    private static void Capture(CoreClient core, ActionDef a, Button anchor, Action reload)
    {
        if (TopLevel.GetTopLevel(anchor) is not { } top) return;
        anchor.Content = "按一下…";
        EventHandler<KeyEventArgs>? h = null;
        h = (_, e) =>
        {
            e.Handled = true;
            top.RemoveHandler(InputElement.KeyDownEvent, h!);
            if (e.Key is Key.Escape) { reload(); return; }
            // 单按修饰键不算:Ctrl 自己不是一个键位,而按 Ctrl+H 时 Ctrl 会先到
            if (e.Key is Key.LeftCtrl or Key.RightCtrl or Key.LeftAlt or Key.RightAlt
                      or Key.LeftShift or Key.RightShift or Key.LWin or Key.RWin)
            {
                Capture(core, a, anchor, reload);
                return;
            }
            var spec = Actions.Spec(e);
            if (spec.Length == 0) { Toast.Show("这个键认不出来,换一个"); reload(); return; }
            Bind(core, a, spec, reload);
        };
        top.AddHandler(InputElement.KeyDownEvent, h, RoutingStrategies.Tunnel);
    }
}
