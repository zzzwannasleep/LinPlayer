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
/// <para>一张表既是行为也是帮助(<see cref="Table"/>):分两处写的必然结果是帮助表
/// 在撒谎,而用户按了没反应只会认为「快捷键是坏的」。挂在隧道阶段 —— 冒泡阶段
/// 先到的是当前有焦点的那个控件,而 Avalonia 的 Button 会把 Space / Enter 当成
/// 「按我」吃掉(播放页那条「空格变成打开设置面板」就是这么来的)。</para>
/// </summary>
internal static class Shortcuts
{
    /// <summary>一条快捷键。<paramref name="Run"/> 返回 false = 这一下没吃掉,交给别人。</summary>
    private sealed record Key1(string Keys, string What, Func<MainWindow, bool> Run);

    /// <summary>
    /// 全表。<b>加键就加在这儿,帮助浮层会自己跟着变</b>。
    ///
    /// <para>分组靠 <see cref="Group"/> 里的顺序,不在这里存组名 ——
    /// 表本身要保持「一行一个键」的形状,好逐行核对。</para>
    /// </summary>
    private static readonly Key1[] Table =
    [
        new("Ctrl+H",     "首页",        w => w.ShortcutNav("NavHome")),
        new("Ctrl+L",     "媒体库",      w => w.ShortcutNav("NavLibrary")),
        new("/ 或 Ctrl+F", "搜索",        w => w.ShortcutNav("NavSearch")),
        new("Ctrl+I",     "收藏",        w => w.ShortcutNav("NavFavorites")),
        new("Ctrl+J",     "下载",        w => w.ShortcutNav("NavDownload")),
        new("Ctrl+,",     "设置",        w => w.ShortcutNav("NavSettings")),

        new("Alt+← 或 退格", "返回上一页",  _ => { if (!Nav.CanBack) return false; Nav.Back(); return true; }),
        new("Ctrl+B",     "收起 / 展开侧栏", w => { w.ShortcutToggleSidebar(); return true; }),
        new("F11",        "窗口最大化 / 还原", w => { w.ShortcutToggleMaximize(); return true; }),
        new("?",          "这张表",      w => { ToggleHelp(w); return true; }),
        new("Esc",        "关掉这张表 / 返回", w => Escape(w)),
    ];

    /// <summary>帮助浮层里的分组:标题 + 这一组占表里的前几行。</summary>
    private static readonly (string Title, int From, int To)[] Group =
    [
        ("去哪儿", 0, 6),
        ("窗口", 6, 11),
    ];

    public static void Attach(MainWindow w) =>
        w.AddHandler(InputElement.KeyDownEvent, (_, e) =>
        {
            if (Match(w, e)) e.Handled = true;
        }, RoutingStrategies.Tunnel);

    private static bool Match(MainWindow w, KeyEventArgs e)
    {
        /* <b>正在打字就一个都不接</b>。搜索框里按 / 要打出一个斜杠,
           按退格要删一个字 —— 抢过来的话搜索框直接没法用,而且用户第一反应是
           「这个输入框坏了」,不会想到是快捷键。
           带 Ctrl 的仍然接:Ctrl+F 在输入框里也该跳去搜索。 */
        var typing = w.FocusManager?.GetFocusedElement() is TextBox or AutoCompleteBox;
        var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        if (typing && !ctrl && e.Key != Avalonia.Input.Key.Escape) return false;

        /* 播放页自己有一整套键(空格 / JKL / 数字跳转…),<b>这里一律让开</b>。
           不让的话 Ctrl 之外的键会被两边同时解释,而播放页那套才是用户当下要的。
           Esc 也让开:播放页的 Esc 是「退全屏 / 退出播放」,语义比这里更具体。 */
        if (Nav.Current is PlayerPage) return false;

        var name = Name(e);
        foreach (var k in Table)
            if (k.Keys.Split(" 或 ").Any(one => one == name))
                return k.Run(w);
        return false;
    }

    /// <summary>把一次按键翻成表里那种写法。<b>翻译只此一处</b> —— 表里写什么就得能翻出什么。</summary>
    private static string Name(KeyEventArgs e)
    {
        var ctrl = e.KeyModifiers.HasFlag(KeyModifiers.Control);
        var alt = e.KeyModifiers.HasFlag(KeyModifiers.Alt);
        var shift = e.KeyModifiers.HasFlag(KeyModifiers.Shift);
        return e.Key switch
        {
            Avalonia.Input.Key.Escape => "Esc",
            Avalonia.Input.Key.F11 => "F11",
            Avalonia.Input.Key.Back when !ctrl && !alt => "退格",
            Avalonia.Input.Key.Left when alt => "Alt+←",
            // 「?」在主键盘上是 Shift+/,Avalonia 报的键是 OemQuestion(或 Divide)
            Avalonia.Input.Key.OemQuestion when shift => "?",
            Avalonia.Input.Key.OemQuestion when !ctrl => "/",
            Avalonia.Input.Key.OemComma when ctrl => "Ctrl+,",
            _ when ctrl && e.Key is >= Avalonia.Input.Key.A and <= Avalonia.Input.Key.Z =>
                "Ctrl+" + (char)('A' + (e.Key - Avalonia.Input.Key.A)),
            _ => "",
        };
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
        foreach (var (title, from, to) in Group)
        {
            var col = new StackPanel { Spacing = 6, MinWidth = 210 };
            col.Children.Add(new TextBlock
            {
                Text = title, FontSize = 11.5, FontWeight = FontWeight.SemiBold,
                Foreground = new SolidColorBrush(Color.FromRgb(0x8a, 0x92, 0xa6)),
                Margin = new Thickness(0, 0, 0, 2),
            });
            for (var i = from; i < to && i < Table.Length; i++) col.Children.Add(Line(Table[i]));
            cols.Children.Add(col);
        }
        // 播放页那一套单独列一栏:用户在播放页按不出这张表(那边 Esc 是退出),
        // 所以这里就是他唯一能看到它们的地方。
        var pc = new StackPanel { Spacing = 6, MinWidth = 210 };
        pc.Children.Add(new TextBlock
        {
            Text = "播放页", FontSize = 11.5, FontWeight = FontWeight.SemiBold,
            Foreground = new SolidColorBrush(Color.FromRgb(0x8a, 0x92, 0xa6)),
            Margin = new Thickness(0, 0, 0, 2),
        });
        foreach (var (k, what) in PlayerKeys) pc.Children.Add(Line(new Key1(k, what, _ => false)));
        cols.Children.Add(pc);

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
                            Text = "键盘快捷键", FontSize = 15, FontWeight = FontWeight.SemiBold,
                            Foreground = Brushes.White,
                        },
                        cols,
                        new TextBlock
                        {
                            Text = "按 ? 或 Esc 关掉", FontSize = 11.5,
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

    /// <summary>播放页那套键。 这里只是**抄一份给人看**,行为在 PlayerPage.OnKey 里;
    /// 改了那边记得同步这里 —— 自检(LP_SELFCHECK_KEYS)会逐条核对两边对不对得上。</summary>
    internal static readonly (string Keys, string What)[] PlayerKeys =
    [
        ("空格 / K", "播放 / 暂停"),
        ("← →", "后退 / 前进 10 秒"),
        ("↑ ↓", "音量 ±5"),
        ("0-9", "跳到百分之几"),
        ("F / 回车", "全屏"),
        ("M", "静音"),
        ("U", "音轨 / 字幕 / 画质"),
        ("S", "截图"),
        ("N", "下一集"),
        ("< >", "减速 / 加速"),
        ("Esc", "退全屏 / 退出播放"),
    ];

    private static Control Line(Key1 k) => new Grid
    {
        ColumnDefinitions = new ColumnDefinitions("108,*"),
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

    /// <summary>自检用:表里一共几条、帮助浮层开着没有。</summary>
    internal static int Count => Table.Length;

    internal static bool HelpOpen => _help is not null;

    /// <summary>自检用:把这一下按键喂进来,回「吃掉了没有」。</summary>
    internal static bool SelfCheckPress(MainWindow w, Avalonia.Input.Key key, KeyModifiers mods) =>
        Match(w, new KeyEventArgs { Key = key, KeyModifiers = mods, RoutedEvent = InputElement.KeyDownEvent });

    /// <summary>自检用:表里那些键名。</summary>
    internal static IEnumerable<string> Names => Table.Select(k => k.Keys);
}
