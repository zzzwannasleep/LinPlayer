using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Layout;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>媒体库总览:一屏列出所有库,点进去是网格。</summary>
public sealed class LibraryPage : PageBase
{
    public LibraryPage(CoreClient core)
    {
        var rows = new StackPanel { Spacing = 14 };
        rows.Children.Add(H1("媒体库"));
        var busy = Dim("加载中…");
        rows.Children.Add(busy);
        Content = Scrolled(rows);

        _ = Task.Run(async () =>
        {
            try
            {
                // ★ include_blocked=true:媒体库页是**唯一**能把被屏蔽的库找回来的地方,
                //   这里也滤掉的话屏蔽就成了单向门(Rust 版栽过)。
                var s = Nav.Session!;
                var views = await core.EmbyViews(new
                {
                    s.server, s.token, s.user_id, s.device_id, include_blocked = true,
                });
                var items = views.ValueKind == JsonValueKind.Array
                    ? views.EnumerateArray().Select(CardItem.From).ToList() : [];
                Dispatcher.UIThread.Post(() =>
                {
                    rows.Children.Remove(busy);
                    if (items.Count == 0) { rows.Children.Add(Dim("这台服务器上没有媒体库。")); return; }
                    rows.Children.Add(Grid(core, s.server, items, true));
                });
            }
            catch (Exception e)
            {
                Dispatcher.UIThread.Post(() => busy.Text = $"加载失败:{Advice(e)}");
            }
        });
    }

    internal static string Advice(Exception e) => e is CoreException c ? c.Advice : e.Message;

    /// <summary>自动铺满的网格。<b>卡自己有固定宽</b>,所以用 WrapPanel 就够,不必算列数。</summary>
    internal static Control Grid(CoreClient core, string server, List<CardItem> items, bool wide,
        Action<CardItem>? onOpen = null)
    {
        var wrap = new WrapPanel { Orientation = Orientation.Horizontal };
        foreach (var it in items)
            wrap.Children.Add(new Card(core, server, it, wide, onOpen ?? OpenDetail(core, server))
            {
                Margin = new Thickness(0, 0, 14, 16),
            });
        return wrap;
    }

    internal static Action<CardItem> OpenDetail(CoreClient core, string server) => item =>
    {
        // 库本身不是「详情」,点进去是网格
        if (item.Type is "CollectionFolder" or "UserView" or "Folder")
            Nav.Push(new LibraryGridPage(core, server, item.Id, item.Name));
        else
            Nav.Push(new DetailPage(core, server, item.Id));
    };
}

/// <summary>一个库里的条目网格。分页拉,滚到底再拉下一页。</summary>
public sealed class LibraryGridPage : PageBase
{
    private const int PageSize = 60;

    private readonly CoreClient _core;
    private readonly string _server, _parentId;
    private readonly WrapPanel _wrap = new();
    private readonly TextBlock _status = new() { Classes = { "dim" } };
    private int _loaded;
    private int _total = -1;
    private bool _busy;

    public LibraryGridPage(CoreClient core, string server, string parentId, string title)
    {
        _core = core; _server = server; _parentId = parentId;

        var head = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children = { Back(), H1(title) },
        };
        var body = new StackPanel { Spacing = 14, Children = { head, _wrap, _status } };

        var sv = new ScrollViewer
        {
            HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
            Content = new Border
            {
                MaxWidth = 1560, HorizontalAlignment = HorizontalAlignment.Stretch,
                Padding = new Thickness(18, 18, 18, 28), Child = body,
            },
        };
        // 滚到底再拉下一页。★ 没有这个的表现是「这个库只有 60 部」——
        // 不报错、不空白,纯粹少一半内容。
        sv.ScrollChanged += (_, _) =>
        {
            if (sv.Offset.Y + sv.Viewport.Height >= sv.Extent.Height - 600) _ = LoadMore();
        };
        Content = sv;
        _ = LoadMore();
    }

    private Control Back()
    {
        var b = new Button { Classes = { "ghost" }, Content = "← 返回" };
        b.Click += (_, _) => Nav.Back();
        return b;
    }

    private async Task LoadMore()
    {
        if (_busy || (_total >= 0 && _loaded >= _total)) return;
        _busy = true;
        Dispatcher.UIThread.Post(() => _status.Text = "加载中…");
        try
        {
            var s = Nav.Session!;
            var page = await _core.EmbyListItemsPage(new
            {
                s.server, s.token, s.user_id, s.device_id,
                parent_id = _parentId,
                query = new { limit = PageSize, start_index = _loaded },
            });
            var items = page.TryGetProperty("items", out var arr) && arr.ValueKind == JsonValueKind.Array
                ? arr.EnumerateArray().Select(CardItem.From).ToList() : [];
            _total = page.TryGetProperty("total", out var t) && t.ValueKind == JsonValueKind.Number
                ? t.GetInt32() : _loaded + items.Count;
            _loaded += items.Count;

            Dispatcher.UIThread.Post(() =>
            {
                foreach (var it in items)
                    _wrap.Children.Add(new Card(_core, _server, it, false,
                        LibraryPage.OpenDetail(_core, _server))
                    {
                        Margin = new Thickness(0, 0, 14, 16),
                    });
                _status.Text = _loaded >= _total ? $"共 {_total} 项" : $"已加载 {_loaded} / {_total}";
            });
            // 服务器返回空页但 total 还没到:再拉就是死循环,当作到底
            if (items.Count == 0) _total = _loaded;
        }
        catch (Exception e)
        {
            Dispatcher.UIThread.Post(() => _status.Text = $"加载失败:{LibraryPage.Advice(e)}");
        }
        finally { _busy = false; }
    }
}
