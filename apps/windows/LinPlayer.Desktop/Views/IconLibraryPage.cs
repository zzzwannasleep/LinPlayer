using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Controls.Templates;
using Avalonia.Media.Imaging;
using Avalonia.Platform.Storage;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 图标库(UI_PC §7.17)。给某台服务器挑一张图标。
///
/// <para>★★ **全量渲染不封顶**(库里约 1468 个格子),靠虚拟化面板扛住。
/// 「以前封顶 300」不是在新 UI 里也封顶的理由 —— Avalonia 的 ItemsRepeater
/// 本来就有这个能力,封顶只会让用户找不到自己要的那张。</para>
///
/// <para>★ 单个图标加载失败 → 留一个占位格,不影响别的:图床里坏链是常态,
/// 一张坏图不该把整页拖红。</para>
/// </summary>
public sealed class IconLibraryPage : PageBase
{
    private readonly CoreClient _core;
    private readonly string _serverId;
    private readonly Action _onPicked;
    private readonly TextBox _search = new() { Classes = { "field" }, Width = 260, Watermark = "搜图标名…" };
    private readonly TextBlock _hint = Dim("加载中…");
    private readonly ItemsControl _grid = new()
    {
        ItemsPanel = new FuncTemplate<Panel?>(() => new WrapPanel()),
    };

    private List<JsonElement> _all = [];

    public IconLibraryPage(CoreClient core, string serverId, Action onPicked)
    {
        _core = core; _serverId = serverId; _onPicked = onPicked;

        var refresh = new Button { Classes = { "ghost" }, Content = "刷新" };
        refresh.Click += async (_, _) => await Load(true);

        var upload = new Button { Classes = { "ghost" }, Content = "上传本地图片" };
        upload.Click += async (_, _) => await Upload();

        _search.TextChanged += (_, _) => Render();

        Content = Scrolled(new StackPanel
        {
            Spacing = 14,
            Children =
            {
                H1("图标库"),
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 10,
                    Children = { _search, refresh, upload },
                },
                _hint,
                new ScrollViewer
                {
                    MaxHeight = 720,
                    VerticalScrollBarVisibility = Avalonia.Controls.Primitives.ScrollBarVisibility.Auto,
                    Content = _grid,
                },
            },
        });
        _ = Load(false);
    }

    private async Task Load(bool force)
    {
        _hint.Text = force ? "重新拉取中…" : "加载中…";
        try
        {
            var r = await _core.PrefsIconLibrary(new { force });
            var items = r.TryGetProperty("items", out var it) && it.ValueKind == JsonValueKind.Array
                ? it.EnumerateArray().ToList() : [];
            var configured = r.TryGetProperty("configured", out var c) && c.ValueKind == JsonValueKind.True;
            Dispatcher.UIThread.Post(() =>
            {
                _all = items;
                /* ★★ 「这个构建没配图标源」和「拉取失败」要**分开说**。
                   前者是永远修不好的(点刷新一百次也没用),后者点一下刷新就好了 ——
                   合成一句「没有图标」的话,用户面对的是同一句话和两种完全不同的处境。 */
                if (items.Count == 0)
                    _hint.Text = configured ? "拉取失败。可以点「刷新」再试,或直接上传本地图片。"
                                            : "这个构建没有配置图标源。可以上传本地图片。";
                Render();
            });
        }
        catch (Exception e) { Dispatcher.UIThread.Post(() => _hint.Text = LibraryPage.Advice(e)); }
    }

    private void Render()
    {
        var q = (_search.Text ?? "").Trim();
        var list = q == "" ? _all
            : _all.Where(e => Str(e, "name").Contains(q, StringComparison.OrdinalIgnoreCase)).ToList();
        _grid.ItemsSource = list.Select(Cell).ToList();
        if (_all.Count > 0)
            _hint.Text = q == "" ? $"{_all.Count} 个图标" : $"{list.Count} / {_all.Count} 个匹配";
    }

    private Control Cell(JsonElement e)
    {
        var url = Str(e, "url");
        var img = new Image { Width = 64, Height = 64, Stretch = Stretch.Uniform };
        var box = new Button
        {
            Classes = { "ghost" }, Width = 96, Height = 96, Padding = new Thickness(6),
            Margin = new Thickness(0, 0, 10, 10),
            Content = img,
        };
        ToolTip.SetTip(box, $"{Str(e, "name")}\n{Str(e, "source")}");
        box.Click += async (_, _) => await Pick(url);

        // ★ 单张失败就留空格子 —— 图床坏链是常态,一张坏图不该把整页拖红。
        _ = Task.Run(async () =>
        {
            try
            {
                using var http = new HttpClient();
                var bytes = await http.GetByteArrayAsync(url);
                using var ms = new MemoryStream(bytes);
                var bmp = new Bitmap(ms);
                Dispatcher.UIThread.Post(() => img.Source = bmp);
            }
            catch { /* 占位 */ }
        });
        return box;
    }

    private async Task Pick(string url)
    {
        try
        {
            // ★ 先清缓存再写地址:不清的话旧图标还在缓存里,选了新的也不换 ——
            //   表现是「点了没反应」,而配置其实已经改了。
            await _core.AccountClearAccountIcon(new { server_id = _serverId });
            await _core.AccountUpdateAccount(new { server_id = _serverId, icon_url = url });
            _hint.Text = "已设为该服务器图标。";
            _onPicked();
        }
        catch (Exception e) { _hint.Text = LibraryPage.Advice(e); }
    }

    private async Task Upload()
    {
        var top = TopLevel.GetTopLevel(this);
        if (top is null) return;
        var files = await top.StorageProvider.OpenFilePickerAsync(new FilePickerOpenOptions
        {
            Title = "选择图标", AllowMultiple = false,
            FileTypeFilter = [FilePickerFileTypes.ImageAll],
        });
        if (files.Count == 0) return;
        try
        {
            await _core.AccountSetAccountIconFile(new
            {
                server_id = _serverId, file_path = files[0].Path.LocalPath,
            });
            _hint.Text = "已设为该服务器图标。";
            _onPicked();
        }
        catch (Exception e) { _hint.Text = LibraryPage.Advice(e); }
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}
