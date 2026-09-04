using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 批量添加服务器(UI_PC §7.6 的第四种入口)。贴一段机场 / Emby 发的开通信息 →
/// 解析成若干账号块 → 用户确认 → 逐块逐线路试登录。
///
/// <para>解析和添加分两步是故意的:一步到底的话,一段贴错的文本会直接往配置里
/// 塞几台服务器。深链(<c>linplayer://add-server</c>)也落在这一页 —— 它可能来自
/// 任何网页或聊天窗口,必须先让用户看清地址和用户名:解得开不等于可以加。</para>
/// </summary>
public sealed class BatchAddPage : PageBase
{
    private readonly CoreClient _core;
    private readonly TextBox _text = new()
    {
        Classes = { "field" }, AcceptsReturn = true, Height = 240,
        TextWrapping = TextWrapping.Wrap,
        Watermark = "把开通信息整段贴进来(用户名 / 密码 / 各条线路),或粘贴一条 linplayer:// 链接",
    };
    private readonly TextBox _user = new() { Classes = { "field" }, Width = 200, Watermark = "统一用户名(可选)" };
    private readonly TextBox _pass = new() { Classes = { "field" }, Width = 200, Watermark = "统一密码(可选)", PasswordChar = '●' };
    private readonly StackPanel _preview = new() { Spacing = 10 };
    private readonly TextBlock _hint = Dim("");
    private readonly Button _add;

    /// <summary>解析出来的块,原样交回核心层 —— 前端不重建这个结构。</summary>
    private JsonElement? _blocks;
    private string _deepLinkName = "";

    public BatchAddPage(CoreClient core, Action onDone)
    {
        _core = core;
        var parse = new Button { Classes = { "ghost" }, Content = "解析" };
        _add = new Button { Classes = { "primary" }, Content = "确认添加", IsEnabled = false };

        parse.Click += async (_, _) => await Parse();
        _add.Click += async (_, _) => await Add(onDone);

        Content = Scrolled(new StackPanel
        {
            Spacing = 14,
            Children =
            {
                H1("批量添加服务器"),
                Dim("解析只在本地做,不会把文本发到任何地方。核对无误再点「确认添加」。"),
                _text,
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { _user, _pass },
                },
                Dim("文本里没带用户名 / 密码的块,会套用上面这两栏。"),
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { parse, _add },
                },
                _hint, _preview,
            },
        });
    }

    /// <summary>外部传进来一条深链(启动参数 / 用户粘贴)。</summary>
    public async Task LoadDeepLink(string url)
    {
        _text.Text = url;
        await Parse();
    }

    private async Task Parse()
    {
        var raw = (_text.Text ?? "").Trim();
        _preview.Children.Clear();
        _blocks = null;
        _add.IsEnabled = false;
        _deepLinkName = "";
        if (raw.Length == 0) { _hint.Text = "先贴点东西进来。"; return; }

        try
        {
            JsonElement blocks;
            if (raw.StartsWith("linplayer://", StringComparison.OrdinalIgnoreCase))
            {
                var d = await _core.AccountParseDeepLink(new { url = raw });
                if (d.ValueKind != JsonValueKind.Object)
                {
                    _hint.Text = "这条链接解不出可用的服务器。";
                    return;
                }
                _deepLinkName = Str(d, "name");
                // 深链只有一个块,包成数组交给同一条添加路径 —— 两条路径会分家。
                blocks = JsonDocument.Parse("[" + d.GetProperty("block").GetRawText() + "]").RootElement;
            }
            else
            {
                blocks = await _core.AccountBatchParse(new { text = raw });
            }

            var arr = blocks.ValueKind == JsonValueKind.Array ? blocks.EnumerateArray().ToList() : [];
            if (arr.Count == 0) { _hint.Text = "没解出任何服务器线路。"; return; }

            _blocks = blocks;
            _add.IsEnabled = true;
            _hint.Text = $"解出 {arr.Count} 个账号块,核对无误后点「确认添加」。";
            foreach (var b in arr) _preview.Children.Add(BlockCard(b));
        }
        catch (Exception e) { _hint.Text = LibraryPage.Advice(e); }
    }

    /// <summary>
    /// 一个账号块的核对卡。
    ///
    /// <para>明文 http 要**显眼地警告**:批量添加的文本常常来自陌生渠道,
    /// 而 http 意味着账号密码在路上是裸的。</para>
    /// </summary>
    private static Control BlockCard(JsonElement b)
    {
        var body = new StackPanel { Spacing = 6 };
        var user = Str(b, "username");
        body.Children.Add(new TextBlock
        {
            Text = user == "" ? "用户名:(文本里没有,将套用上面填的)" : $"用户名:{user}",
            FontWeight = user == "" ? FontWeight.Normal : FontWeight.SemiBold,
        });
        body.Children.Add(Dim(Str(b, "password") == "" ? "密码:(文本里没有)" : "密码:已解出"));

        var plain = false;
        void AddLines(string key, string title)
        {
            if (!b.TryGetProperty(key, out var ls) || ls.ValueKind != JsonValueKind.Array) return;
            var items = ls.EnumerateArray().ToList();
            if (items.Count == 0) return;
            body.Children.Add(new TextBlock { Text = title, Classes = { "dim" }, Margin = new Thickness(0, 6, 0, 0) });
            foreach (var l in items)
            {
                var url = Str(l, "url");
                if (url.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) plain = true;
                body.Children.Add(new TextBlock
                {
                    Text = $"· {Str(l, "name")} — {url}",
                    TextWrapping = TextWrapping.Wrap, FontSize = 12.5,
                });
            }
        }
        AddLines("lines", "服务器线路(按顺序试,第一条通的即生效)");
        AddLines("danmaku_lines", "弹幕线路(会并进全局弹幕源)");

        if (plain)
        {
            body.Children.Add(new TextBlock
            {
                Text = "⚠ 其中有明文 http 地址 —— 账号密码在路上是不加密的。确认来源可信再添加。",
                TextWrapping = TextWrapping.Wrap, FontSize = 12.5,
                Foreground = new SolidColorBrush(Color.FromRgb(0xE5, 0xA5, 0x50)),
                Margin = new Thickness(0, 6, 0, 0),
            });
        }
        return new Border { Classes = { "card" }, Padding = new Thickness(18), Child = body };
    }

    private async Task Add(Action onDone)
    {
        if (_blocks is not { } blocks) return;
        _add.IsEnabled = false;
        _hint.Text = "逐条线路试登录中…";
        try
        {
            var res = await _core.AccountBatchAddServers(new
            {
                blocks = JsonSerializer.Deserialize<JsonElement>(blocks.GetRawText()),
                fallback_username = (_user.Text ?? "").Trim(),
                fallback_password = _pass.Text ?? "",
                fallback_name = _deepLinkName,
            });
            var rows = res.ValueKind == JsonValueKind.Array ? res.EnumerateArray().ToList() : [];
            var ok = rows.Count(r => r.TryGetProperty("server_id", out var s) && s.ValueKind == JsonValueKind.String);
            _preview.Children.Clear();
            foreach (var r in rows)
            {
                var err = Str(r, "error");
                _preview.Children.Add(new TextBlock
                {
                    Text = err == "" ? $"✓ {Str(r, "name")} 已添加" : $"✗ {Str(r, "name")}:{err}",
                    TextWrapping = TextWrapping.Wrap,
                });
            }
            // 部分成功要**如实说**:全成功才跳走,不然用户以为都加上了。
            _hint.Text = $"{ok} / {rows.Count} 台添加成功。";
            if (ok > 0 && ok == rows.Count) Dispatcher.UIThread.Post(onDone);
            else _add.IsEnabled = true;
        }
        catch (Exception e) { _hint.Text = LibraryPage.Advice(e); _add.IsEnabled = true; }
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}
