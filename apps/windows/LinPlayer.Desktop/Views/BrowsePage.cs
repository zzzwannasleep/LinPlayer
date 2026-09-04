using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Input;
using Avalonia.Layout;
using Avalonia.Media;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 文件浏览页(<c>UI_PC.md</c> §7.7)。网盘 / SMB / WebDAV / FTP / 本地共用这一页。
///
/// <para>三条契约,每条都对应一次真事故:</para>
/// <list type="number">
/// <item><b>空目录就说空目录</b>,不要说「加载失败」—— 两者的下一步动作完全不同。</item>
/// <item><b>凭据失效走 E_AUTH</b> → 引导重新登录,不是提示「检查网络」。</item>
/// <item><b>起播必须走宿主的起播入口</b>(先把播放页拉起来),本页不许自己 invoke。
/// 曾经绕开独立播放窗自己起播,结果「有声音、没画面、还关不掉」。</item>
/// </list>
/// </summary>
public sealed class BrowsePage : PageBase
{
    private readonly CoreClient _core;
    private readonly StackPanel _crumbs = new() { Orientation = Orientation.Horizontal, Spacing = 6 };
    private readonly StackPanel _rows = new() { Spacing = 2 };
    private readonly TextBlock _status = Dim("");
    private readonly TextBox _filter = new() { Watermark = "在当前目录里过滤", Width = 220, Classes = { "field" } };

    /// <summary>面包屑:(目录 id, 显示名)。第一项永远是根。</summary>
    private readonly List<(string Id, string Name)> _path = [];

    private List<JsonElement> _entries = [];
    private string _loadingDir = "";

    public BrowsePage(CoreClient core, string sourceName)
    {
        _core = core;
        _path.Add(("", sourceName.Length > 0 ? sourceName : "根目录"));

        _filter.TextChanged += (_, _) => Render();

        Content = Scrolled(new StackPanel
        {
            Spacing = 10,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { _crumbs, _filter },
                },
                _status,
                _rows,
            },
        });

        _ = Load("");
    }

    private async Task Load(string dirId)
    {
        _loadingDir = dirId;
        _rows.Children.Clear();
        _status.Text = "加载中…";
        RenderCrumbs();

        JsonElement arr;
        try
        {
            arr = await _core.SourceListDir(new { dir_id = dirId });
        }
        catch (Exception e)
        {
            // 凭据失效要引导**重新登录**,不是「检查网络」。
            // CoreException.Advice 已经按 code 分好了,原样显示即可。
            _status.Text = LibraryPage.Advice(e);
            if (e is CoreException { Code: "E_AUTH" })
            {
                var go = new Button { Content = "重新登录这个源", Classes = { "primary" }, Margin = new Thickness(0, 10, 0, 0) };
                go.Click += (_, _) => Nav.Root(new ServersPage(_core, () => { }));
                _rows.Children.Add(go);
            }
            return;
        }

        // 慢协议下用户可能已经点进别的目录了,别把旧结果画上去
        if (_loadingDir != dirId) return;

        _entries = arr.ValueKind == JsonValueKind.Array ? arr.EnumerateArray().ToList() : [];
        Render();
    }

    private void Render()
    {
        _rows.Children.Clear();
        var kw = _filter.Text?.Trim() ?? "";
        var shown = _entries
            .Where(e => kw.Length == 0 || Str(e, "name").Contains(kw, StringComparison.OrdinalIgnoreCase))
            .ToList();

        if (_entries.Count == 0)
        {
            // **空目录就说空目录**。说成「加载失败」的话,用户会去重试、去查网络、
            // 去怀疑密码 —— 而实际上这里本来就没有东西。
            _status.Text = "这个文件夹是空的。";
            return;
        }
        _status.Text = shown.Count == 0
            ? $"这个文件夹里没有匹配「{kw}」的内容。"
            : $"{shown.Count} 项" + (shown.Count != _entries.Count ? $"(共 {_entries.Count} 项)" : "");

        foreach (var e in shown) _rows.Children.Add(Row(e));
    }

    private Control Row(JsonElement e)
    {
        var name = Str(e, "name");
        var isDir = Bool(e, "is_dir");
        var isVideo = Bool(e, "is_video");
        var size = e.TryGetProperty("size", out var sv) && sv.ValueKind == JsonValueKind.Number ? sv.GetInt64() : 0;

        var icon = new TextBlock
        {
            Text = isDir ? "▸" : isVideo ? "▶" : "·",
            FontSize = 13, Width = 18,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = new SolidColorBrush(Color.Parse(isDir ? "#5b8def" : isVideo ? "#e8ebf1" : "#6b7688")),
        };

        var b = new Button
        {
            Background = Brushes.Transparent,
            BorderThickness = new Thickness(0),
            Padding = new Thickness(10, 10),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            HorizontalContentAlignment = HorizontalAlignment.Stretch,
            Cursor = new Cursor(StandardCursorType.Hand),
            Content = new Grid
            {
                ColumnDefinitions = new ColumnDefinitions("Auto,*,Auto"),
                Children =
                {
                    icon,
                    new TextBlock
                    {
                        Text = name, FontSize = 13,
                        TextTrimming = TextTrimming.CharacterEllipsis,
                        VerticalAlignment = VerticalAlignment.Center,
                        [Grid.ColumnProperty] = 1,
                    },
                    new TextBlock
                    {
                        Text = isDir ? "" : HumanSize(size),
                        FontSize = 12, Opacity = 0.55,
                        VerticalAlignment = VerticalAlignment.Center,
                        [Grid.ColumnProperty] = 2,
                    },
                },
            },
        };

        var id = Str(e, "id");
        b.Click += (_, _) =>
        {
            if (isDir)
            {
                _path.Add((id, name));
                _ = Load(id);
            }
            else if (isVideo)
            {
                // 起播走**宿主的起播入口** —— 它负责把播放页拉起来。
                // 本页自己 invoke source.play 的话,核心层是开始放了,
                // 但没有任何页面接管画面:「有声音、没画面、还关不掉」。
                Nav.Push(new PlayerPage(_core, id, name, 0, isSource: true));
            }
            // 非视频文件:点了不动。不弹提示 —— 用户看得见那是张封面图
        };
        return b;
    }

    /// <summary>自检用:按名字点进一个子目录。列表是异步来的,所以要等。</summary>
    internal void SelfCheckEnter(string name) => _ = EnterWhenReady(name);

    private async Task EnterWhenReady(string name)
    {
        for (var i = 0; i < 40 && _entries.Count == 0; i++) await Task.Delay(100);
        foreach (var e in _entries)
        {
            if (Str(e, "name") == name && Bool(e, "is_dir"))
            {
                _path.Add((Str(e, "id"), name));
                await Load(Str(e, "id"));
                return;
            }
        }
    }

    private void RenderCrumbs()
    {
        _crumbs.Children.Clear();
        for (var i = 0; i < _path.Count; i++)
        {
            if (i > 0) _crumbs.Children.Add(new TextBlock { Text = "/", Opacity = 0.4, VerticalAlignment = VerticalAlignment.Center });
            var idx = i;
            var last = i == _path.Count - 1;
            var b = new Button
            {
                Content = _path[i].Name,
                Classes = { "ghost" },
                Padding = new Thickness(10, 6),
                IsEnabled = !last, // 当前这层点了也没用
            };
            b.Click += (_, _) =>
            {
                var target = _path[idx];
                _path.RemoveRange(idx + 1, _path.Count - idx - 1);
                _ = Load(target.Id);
            };
            _crumbs.Children.Add(b);
        }
    }

    /// <summary>人类看得懂的大小。0 表示源没给大小(很多网盘的目录就不给)。</summary>
    private static string HumanSize(long n)
    {
        if (n <= 0) return "";
        string[] u = ["B", "KB", "MB", "GB", "TB"];
        double v = n;
        var i = 0;
        while (v >= 1024 && i < u.Length - 1) { v /= 1024; i++; }
        return i == 0 ? $"{n} B" : $"{v:0.#} {u[i]}";
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
}
