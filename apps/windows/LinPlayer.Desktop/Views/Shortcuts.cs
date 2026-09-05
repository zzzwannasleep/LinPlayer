using System;
using System.Collections.Generic;
using System.Linq;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Input;
using Avalonia.Interactivity;
using Avalonia.Layout;
using Avalonia.Media;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 全局快捷键。用户 2026-09-04:「不仅仅是播放页,其他页面也需要快捷键」——
/// 在这之前只有播放页有键盘,其余每一页都必须用鼠标。
///
/// <para>键位表搬进 <see cref="Actions"/>(2026-09-06):这里只留「动作 id → 干什么」。
/// 原先键位、行为、帮助文案三处各写一遍,帮助表迟早在撒谎,而用户按了没反应
/// 只会认为「快捷键是坏的」。挂在隧道阶段 —— 冒泡阶段先到的是当前有焦点的那个控件,
/// 而 Avalonia 的 Button 会把 Space / Enter 当成「按我」吃掉。</para>
/// </summary>
internal static class Shortcuts
{
    /// <summary>一行帮助:键位 + 说明。</summary>
    private sealed record Key1(string Keys, string What);

    /// <summary>
    /// 动作 id → 干什么。返回 false = 这一下没吃掉,交给别人。
    ///
    /// <para><b>加快捷键先加到 <see cref="Actions.All"/></b>,再在这里补一条实现 ——
    /// 只加这里的话设置页和帮助浮层都看不见它。</para>
    /// </summary>
    private static readonly Dictionary<string, Func<MainWindow, bool>> Run = new()
    {
        ["nav.home"] = w => w.ShortcutNav("NavHome"),
        ["nav.library"] = w => w.ShortcutNav("NavLibrary"),
        ["nav.search"] = w => w.ShortcutNav("NavSearch"),
        ["nav.favorites"] = w => w.ShortcutNav("NavFavorites"),
        ["nav.download"] = w => w.ShortcutNav("NavDownload"),
        ["nav.settings"] = w => w.ShortcutNav("NavSettings"),

        ["win.back"] = _ => { if (!Nav.CanBack) return false; Nav.Back(); return true; },
        ["win.sidebar"] = w => { w.ShortcutToggleSidebar(); return true; },
        ["win.maximize"] = w => { w.ShortcutToggleMaximize(); return true; },
        ["win.help"] = w => { ToggleHelp(w); return true; },
        ["win.escape"] = Escape,
    };

    public static void Attach(MainWindow w)
    {
        w.AddHandler(InputElement.KeyDownEvent, (_, e) =>
        {
            if (Match(w, e)) e.Handled = true;
        }, RoutingStrategies.Tunnel);

        /* 鼠标侧键也走这张表(用户 2026-09-06 要「所有功能都能用快捷键」——
           而鼠标键就是键)。左右键**不在全局收**:那两个键在列表、卡片、
           输入框上各自有意义,全局抢走的话整个界面都点不动了。 */
        w.AddHandler(InputElement.PointerPressedEvent, (_, e) =>
        {
            var p = e.GetCurrentPoint(w).Properties;
            if (!p.IsXButton1Pressed && !p.IsXButton2Pressed) return;
            if (Nav.Current is PlayerPage) return;
            if (Fire(w, Actions.Hit(Actions.Global, Actions.Spec(p)))) e.Handled = true;
        }, RoutingStrategies.Tunnel);
    }

    private static bool Fire(MainWindow w, string? id) =>
        id is not null && Run.TryGetValue(id, out var go) && go(w);

    private static bool Match(MainWindow w, KeyEventArgs e)
    {
        /* <b>正在打字就一个都不接</b>。搜索框里按 / 要打出一个斜杠,
           按退格要删一个字 —— 抢过来的话搜索框直接没法用,而且用户第一反应是
           「这个输入框坏了」,不会想到是快捷键。
           带 Ctrl 的仍然接:Ctrl+F 在输入框里也该跳去搜索。 */
        var typing = w.FocusManager?.GetFocusedElement() is TextBox or AutoCompleteBox;
        var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        if (typing && !ctrl && e.Key != Key.Escape) return false;

        /* 播放页自己有一整套键(空格 / JKL / 数字跳转…),<b>这里一律让开</b>。
           不让的话 Ctrl 之外的键会被两边同时解释,而播放页那套才是用户当下要的。
           Esc 也让开:播放页的 Esc 是「退全屏 / 退出播放」,语义比这里更具体。 */
        if (Nav.Current is PlayerPage) return false;

        return Fire(w, Actions.Hit(Actions.Global, Actions.Spec(e)));
    }

    // ---------------------------------------------------------------- 帮助浮层

    private static Control? _help;

    /// <summary>Esc:先关帮助,没帮助再返回。 两件事都没得做时**不吃掉这一下**,
    /// 免得别的控件(下拉框、弹出层)的 Esc 也被这里吞了。</summary>
    private static bool Escape(MainWindow w)
    {
        if (_help is not null) { ToggleHelp(w); return true; }
        if (!Nav.CanBack) return false;
        Nav.Back();
        return true;
    }

    /// <summary>
    /// 这张表。<b>逐列从 <see cref="Actions.All"/> 现算</b>,包括用户改过的键位 ——
    /// 照着默认值画的话,改完键的人看到的帮助是错的。
    /// </summary>
    private static void ToggleHelp(MainWindow w)
    {
        if (Toast.Host is not { } host) return;
        if (_help is not null)
        {
            host.Children.Remove(_help);
            _help = null;
            return;
        }
        var cols = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 26 };
        // 播放页那一栏也在这儿:用户在播放页按不出这张表(那边 Esc 是退出播放),
        // 所以这里是他唯一看得到播放页键位的地方。
        foreach (var g in Actions.All.GroupBy(a => a.Group))
        {
            var col = new StackPanel { Spacing = 6, MinWidth = 210 };
            col.Children.Add(new TextBlock
            {
                Text = g.Key, FontSize = 11.5, FontWeight = FontWeight.SemiBold,
                Foreground = new SolidColorBrush(Color.FromRgb(0x8a, 0x92, 0xa6)),
                Margin = new Thickness(0, 0, 0, 2),
            });
            foreach (var a in g)
                col.Children.Add(Line(new Key1(Actions.KeysOf(a.Id), a.Name)));
            if (g.Key == "播放") col.Children.Add(Line(new Key1("0-9", "跳到百分之几")));
            cols.Children.Add(col);
        }

        _help = new Border
        {
            Background = new SolidColorBrush(Color.FromArgb(0xB8, 0x0d, 0x0f, 0x14)),
            Child = new Border
            {
                HorizontalAlignment = HorizontalAlignment.Center,
                VerticalAlignment = VerticalAlignment.Center,
                Padding = new Thickness(26, 26),
                CornerRadius = new CornerRadius(10),
                Background = new SolidColorBrush(Color.FromRgb(0x1a, 0x1c, 0x22)),
                BorderBrush = new SolidColorBrush(Color.FromArgb(0x55, 0xff, 0xff, 0xff)),
                BorderThickness = new Thickness(1),
                Child = new StackPanel
                {
                    Spacing = 18,
                    Children =
                    {
                        new TextBlock
                        {
                            Text = "快捷键", FontSize = 15, FontWeight = FontWeight.SemiBold,
                            Foreground = Brushes.White,
                        },
                        cols,
                        new TextBlock
                        {
                            Text = "设置 → 快捷键 里可以改;按 ? 或 Esc 关掉", FontSize = 11.5,
                            Foreground = new SolidColorBrush(Color.FromRgb(0x6d, 0x74, 0x86)),
                        },
                    },
                },
            },
        };
        // 点背板也关:弹出层不能只有一种关法,而键盘那一种恰恰是用户此刻不熟的那个。
        _help.PointerPressed += (_, _) => ToggleHelp(w);
        host.Children.Add(_help);
    }

    private static Control Line(Key1 k) => new Grid
    {
        ColumnDefinitions = new ColumnDefinitions("148,*"),
        Children =
        {
            new Border
            {
                [Grid.ColumnProperty] = 0,
                HorizontalAlignment = HorizontalAlignment.Left,
                Padding = new Thickness(6, 2), CornerRadius = new CornerRadius(6),
                Background = new SolidColorBrush(Color.FromRgb(0x2a, 0x2d, 0x36)),
                Child = new TextBlock
                {
                    Text = k.Keys, FontSize = 11.5, FontFamily = new FontFamily("Consolas, monospace"),
                    Foreground = new SolidColorBrush(Color.FromRgb(0xd6, 0xdb, 0xe6)),
                    TextWrapping = TextWrapping.Wrap,
                },
            },
            new TextBlock
            {
                [Grid.ColumnProperty] = 1,
                Text = k.What, FontSize = 12.5, Margin = new Thickness(14, 0, 0, 0),
                Foreground = new SolidColorBrush(Color.FromRgb(0xb9, 0xc0, 0xcf)),
                VerticalAlignment = VerticalAlignment.Center,
            },
        },
    };

    // ---------------------------------------------------------------- 自检

    /// <summary>自检用:播放页那一栏。<b>现在是从同一张表算出来的</b>,
    /// 不再是抄一份 —— 两边对不上这种事从此不可能发生。</summary>
    internal static (string Keys, string What)[] PlayerKeys =>
        Actions.All.Where(a => a.Scope == Actions.Player)
                   .Select(a => (Actions.KeysOf(a.Id), a.Name)).ToArray();

    internal static int Count => Run.Count;

    internal static bool HelpOpen => _help is not null;

    /// <summary>自检用:把这一下按键喂进来,回「吃掉了没有」。</summary>
    internal static bool SelfCheckPress(MainWindow w, Key key, KeyModifiers mods) =>
        Match(w, new KeyEventArgs { Key = key, KeyModifiers = mods, RoutedEvent = InputElement.KeyDownEvent });

    /// <summary>自检用:全局那些键位。</summary>
    internal static IEnumerable<string> Names =>
        Actions.All.Where(a => a.Scope == Actions.Global).Select(a => Actions.KeysOf(a.Id));
}
