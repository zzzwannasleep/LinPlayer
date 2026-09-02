using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Controls.Primitives;
using Avalonia.Controls.Templates;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Media.Imaging;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 影视目录(<c>UI_PC.md</c> §7.8)。
///
/// <para>★★ <b>这一页存在的唯一理由:资源站不是文件树。</b>
/// 旧版把资源站塞进文件浏览页,于是每样东西都得伪装成文件 —— 分类伪装成文件夹、
/// 翻页伪装成一个叫「下一页」的文件夹、「更新至 17 集」只能拼进文件名。全错。</para>
///
/// <para>★★ <b>首屏要预抓几页</b>:只抓一页的话内容铺不满一屏 → 没有滚动 →
/// 无限下拉永远不会被触发,表现是「只有十几个,再也刷不出来了」。</para>
///
/// <para>★ 探能力时拿到「不支持」= 这是个文件型源 → <b>静默换路</b>退回文件浏览页,
/// 不当错误弹。</para>
/// </summary>
public sealed class CatalogPage : PageBase
{
    private readonly CoreClient _core;
    private readonly Action _fallbackToBrowse;

    private readonly StackPanel _catBar = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly StackPanel _subBar = new() { Orientation = Orientation.Horizontal, Spacing = 8 };
    private readonly TextBox _search = new() { Classes = { "field" }, Width = 240, Watermark = "站内搜索…" };
    private readonly ItemsControl _grid = new() { ItemsPanel = new FuncTemplate<Panel?>(() => new WrapPanel()) };
    private readonly TextBlock _msg = Dim("加载中…");
    private readonly ScrollViewer _scroll;

    /// <summary>详情**盖在同一页上** —— 关掉时网格的滚动位置还在。</summary>
    private readonly Border _overlay;
    private readonly StackPanel _detailBody = new() { Spacing = 12 };

    private List<JsonElement> _cats = [];
    private string _curCat = "";
    private string _curKeyword = "";
    private uint _page = 1;
    private bool _hasMore;
    private bool _loading;

    public CatalogPage(CoreClient core, Action fallbackToBrowse)
    {
        _core = core;
        _fallbackToBrowse = fallbackToBrowse;

        _search.KeyDown += (_, e) =>
        {
            if (e.Key == Avalonia.Input.Key.Enter) _ = Reload(_curCat, (_search.Text ?? "").Trim());
        };

        var body = new StackPanel
        {
            Spacing = 14,
            Children =
            {
                new StackPanel
                {
                    Orientation = Orientation.Horizontal, Spacing = 12,
                    Children = { H1("影视目录"), _search },
                },
                _catBar, _subBar, _msg, _grid,
            },
        };
        _scroll = (ScrollViewer)Scrolled(body);
        _scroll.ScrollChanged += (_, _) => MaybeLoadMore();

        var close = new Button { Classes = { "ghost" }, Content = "返回目录", MinHeight = 32 };
        close.Click += (_, _) => _overlay!.IsVisible = false;
        _overlay = new Border
        {
            IsVisible = false,
            /* ★ 盖层必须**不透明**。半透明的话下面那一屏海报网格会透上来,
               详情的文字压在一堆卡片上,读起来很吃力 —— 截图里一眼就能看出来,
               而在代码里(alpha=250)看着像是「几乎不透明」。 */
            Background = new SolidColorBrush(Color.FromRgb(22, 22, 26)),
            Child = new ScrollViewer
            {
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                Content = new Border
                {
                    Padding = new Thickness(24), MaxWidth = 1200,
                    Child = new StackPanel { Spacing = 14, Children = { close, _detailBody } },
                },
            },
        };

        Content = new Grid { Children = { _scroll, _overlay } };
        _ = LoadCategories();
    }

    // ---------------------------------------------------------------- 分类

    private async Task LoadCategories()
    {
        JsonElement r;
        try { r = await _core.SourceCategories(); }
        catch (Exception e)
        {
            /* ★★ 「这个源不支持影视目录」= 它是个文件型源,**静默换路**,不弹错。
               弹错的话每个网盘用户点进来都会看到一句读不懂的红字,而正确行为是
               直接把他送到文件浏览页。核心层用 E_UNSUPPORTED 说这件事。 */
            if (IsUnsupported(e)) { Dispatcher.UIThread.Post(_fallbackToBrowse); return; }
            Dispatcher.UIThread.Post(() => _msg.Text = LibraryPage.Advice(e));
            return;
        }

        var cats = r.ValueKind == JsonValueKind.Array ? r.EnumerateArray().ToList() : [];
        Dispatcher.UIThread.Post(() =>
        {
            _cats = cats;
            _catBar.Children.Clear();
            foreach (var c in cats) _catBar.Children.Add(CatChip(c, top: true));

            /* ★★ **有子分类的父级本身多半是空的**。点它(或首屏默认选它)要先落到
               第一个子分类,而不是把用户扔进一张空页 —— 空页看起来像「这个站没内容」。 */
            var first = cats.Count > 0 ? cats[0] : default;
            _ = Reload(FirstLeaf(first), "");
            RenderSubBar(first);
        });
    }

    private static string FirstLeaf(JsonElement cat)
    {
        var kids = Arr(cat, "children");
        return kids.Count > 0 ? FirstLeaf(kids[0]) : Str(cat, "id");
    }

    private Control CatChip(JsonElement c, bool top)
    {
        var id = Str(c, "id");
        var btn = new Button
        {
            Classes = { "ghost" }, Content = Str(c, "name"), MinHeight = 30,
            Padding = new Thickness(12, 4),
        };
        btn.Click += (_, _) =>
        {
            if (top) RenderSubBar(c);
            _ = Reload(FirstLeaf(c), "");
        };
        _ = id;
        return btn;
    }

    private void RenderSubBar(JsonElement cat)
    {
        _subBar.Children.Clear();
        foreach (var k in Arr(cat, "children")) _subBar.Children.Add(CatChip(k, top: false));
        _subBar.IsVisible = _subBar.Children.Count > 0;
    }

    // ---------------------------------------------------------------- 目录

    private async Task Reload(string categoryId, string keyword)
    {
        _curCat = categoryId;
        _curKeyword = keyword;
        _page = 1;
        _hasMore = false;
        await Dispatcher.UIThread.InvokeAsync(() =>
        {
            _grid.ItemsSource = new List<Control>();
            _cards.Clear();
            _msg.Text = "加载中…";
        });
        // ★ 首屏预抓 3 页:抓一页铺不满屏就没有滚动条,无限下拉永远触发不了。
        for (var i = 0; i < 3; i++)
        {
            await LoadPage();
            if (!_hasMore) break;
        }
    }

    private readonly List<JsonElement> _cards = [];

    private async Task LoadPage()
    {
        if (_loading) return;
        _loading = true;
        try
        {
            var r = await _core.SourceCatalog(new
            {
                category_id = _curCat, keyword = _curKeyword, page = _page,
            });
            var items = Arr(r, "items");
            /* ★★ `_hasMore` 必须在**这条 goroutine 上同步落**,不能丢进 Post 里。
               丢进 Post 的话:调用方 `await LoadPage()` 返回时那个 Post 还没跑,
               读到的是上一轮的旧值 —— 首屏预抓的 for 循环第一轮就 break,
               只抓到一页。表现是「只有十几部,再往下滚也不出来」,而且时快时慢
               (2026-09-02 真机截图抓到:该 36 部,只出来 24)。 */
            _hasMore = r.TryGetProperty("has_more", out var hm) && hm.ValueKind == JsonValueKind.True;
            _page++;
            await Dispatcher.UIThread.InvokeAsync(() =>
            {
                _cards.AddRange(items);
                _grid.ItemsSource = _cards.Select(PosterCard).ToList();
                _msg.Text = _cards.Count == 0
                    ? (_curKeyword == "" ? "这个分类下没有内容。" : $"没有搜到「{_curKeyword}」。")
                    : $"{_cards.Count} 部" + (_hasMore ? "(往下滚继续)" : "");
            });
        }
        catch (Exception e)
        {
            if (IsUnsupported(e)) { Dispatcher.UIThread.Post(_fallbackToBrowse); return; }
            Dispatcher.UIThread.Post(() => _msg.Text = LibraryPage.Advice(e));
            _hasMore = false;
        }
        finally { _loading = false; }
    }

    private void MaybeLoadMore()
    {
        if (!_hasMore || _loading) return;
        var v = _scroll.Offset.Y;
        var max = _scroll.Extent.Height - _scroll.Viewport.Height;
        if (max <= 0) return;
        if (v >= max - 600) _ = LoadPage();
    }

    /// <summary>
    /// 一张海报卡。
    ///
    /// <para>★★ 角标 / 年份 / 评分**各占各的位置**,标题里只有标题。
    /// 拼进标题的话卡片下面会变成「神之水滴 · 更新至17集 · 2026」——
    /// 那不是标题,是把三样东西塞进一个格子。</para>
    ///
    /// <para>★ **单击就打开,不是双击** —— 海报墙不是文件管理器。</para>
    /// </summary>
    private Control PosterCard(JsonElement c)
    {
        var poster = new Image { Width = 150, Height = 210, Stretch = Stretch.UniformToFill };
        LoadPoster(poster, Str(c, "poster"));

        var badge = Str(c, "badge");
        var overlay = PosterBox(poster, 150, 210);
        if (badge != "")
        {
            overlay.Children.Add(new Border
            {
                HorizontalAlignment = HorizontalAlignment.Right,
                VerticalAlignment = VerticalAlignment.Bottom,
                Margin = new Thickness(0, 0, 4, 4),
                Background = new SolidColorBrush(Color.FromArgb(200, 0, 0, 0)),
                CornerRadius = new CornerRadius(4), Padding = new Thickness(6, 2),
                Child = new TextBlock { Text = badge, FontSize = 11, Foreground = Brushes.White },
            });
        }

        var meta = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
        if (Str(c, "year") != "") meta.Children.Add(Dim(Str(c, "year")));
        if (Str(c, "score") != "") meta.Children.Add(new TextBlock
        {
            Text = Str(c, "score"), FontSize = 12,
            Foreground = new SolidColorBrush(Color.FromRgb(240, 190, 90)),
        });

        var card = new Button
        {
            Classes = { "ghost" }, Padding = new Thickness(6), Margin = new Thickness(0, 0, 12, 14),
            Content = new StackPanel
            {
                Width = 150, Spacing = 6,
                Children =
                {
                    overlay,
                    new TextBlock
                    {
                        Text = Str(c, "title"), TextWrapping = TextWrapping.Wrap, MaxLines = 2,
                        FontSize = 13,
                    },
                    meta,
                },
            },
        };
        card.Click += async (_, _) => await OpenDetail(Str(c, "id"), Str(c, "title"));
        return card;
    }

    /// <summary>自检:打开第一张卡的详情(详情盖层是这一页最容易画错的部分)。</summary>
    public async Task SelfCheckOpenFirst()
    {
        for (var i = 0; i < 40 && _cards.Count == 0; i++) await Task.Delay(100);
        if (_cards.Count == 0) { _msg.Text = "自检:一张卡都没有,详情盖层没得开"; return; }
        await OpenDetail(Str(_cards[0], "id"), Str(_cards[0], "title"));
    }

    /// <summary>
    /// 海报 + 占位底。
    ///
    /// <para>★ 没海报时垫一层**占位**,不是留一个空框:资源站缺图是常态,
    /// 空框看起来像「这一格加载坏了」,而实际上它只是没图。</para>
    /// </summary>
    private static Grid PosterBox(Image poster, double w, double h) => new()
    {
        Width = w, Height = h,
        Children =
        {
            new Border
            {
                Background = new SolidColorBrush(Color.FromArgb(28, 255, 255, 255)),
                CornerRadius = new CornerRadius(6),
                Child = new TextBlock
                {
                    Text = "无封面", FontSize = 12, Classes = { "dim" },
                    HorizontalAlignment = HorizontalAlignment.Center,
                    VerticalAlignment = VerticalAlignment.Center,
                },
            },
            poster,
        },
    };

    // ---------------------------------------------------------------- 详情

    private async Task OpenDetail(string id, string fallbackTitle)
    {
        _detailBody.Children.Clear();
        _detailBody.Children.Add(Dim("加载中…"));
        _overlay.IsVisible = true;

        JsonElement d;
        try { d = await _core.SourceMediaDetail(new { id }); }
        catch (Exception e)
        {
            Dispatcher.UIThread.Post(() =>
            {
                _detailBody.Children.Clear();
                _detailBody.Children.Add(Dim(LibraryPage.Advice(e)));
            });
            return;
        }

        Dispatcher.UIThread.Post(() =>
        {
            _detailBody.Children.Clear();

            var title = Str(d, "title") == "" ? fallbackTitle : Str(d, "title");
            var head = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 18 };
            var poster = new Image { Width = 180, Height = 252, Stretch = Stretch.UniformToFill };
            LoadPoster(poster, Str(d, "poster"));
            head.Children.Add(PosterBox(poster, 180, 252));

            var info = new StackPanel { Spacing = 6, MaxWidth = 720 };
            info.Children.Add(new TextBlock { Text = title, Classes = { "h1" } });
            var bits = new[] { "badge", "year", "area", "lang", "genre", "score" }
                .Select(k => Str(d, k)).Where(s => s != "").ToList();
            if (bits.Count > 0) info.Children.Add(Dim(string.Join(" · ", bits)));
            foreach (var (k, label) in new[] { ("director", "导演"), ("actors", "主演") })
                if (Str(d, k) != "") info.Children.Add(Dim($"{label}:{Str(d, k)}"));
            if (Str(d, "overview") != "") info.Children.Add(Dim(Str(d, "overview")));
            head.Children.Add(info);
            _detailBody.Children.Add(head);

            var lines = Arr(d, "lines");
            if (lines.Count == 0)
            {
                _detailBody.Children.Add(Dim("这部片没有可播线路。"));
                return;
            }

            /* ★ 线路是**并列的几套分集**,不是一个下拉里的选项就完事 ——
               有的线路给的是网页播放页而不是流,播不出来时用户要能一眼换一条。 */
            foreach (var line in lines)
            {
                _detailBody.Children.Add(H2(Str(line, "name")));
                var eps = new WrapPanel();
                foreach (var ep in Arr(line, "episodes"))
                {
                    var b = new Button
                    {
                        Classes = { "ghost" }, Content = Str(ep, "name"), MinHeight = 30,
                        Margin = new Thickness(0, 0, 8, 8), Padding = new Thickness(10, 4),
                    };
                    var epCopy = ep;
                    b.Click += async (_, _) => await PlayEpisode(epCopy, title);
                    eps.Children.Add(b);
                }
                _detailBody.Children.Add(eps);
            }
        });
    }

    private Task PlayEpisode(JsonElement ep, string title)
    {
        /* ★★ 起播必须**导航到播放页**,不是在这里调一下 source.play 就完事。
           「起播了但没有画面」这一类故障的根因就是只调命令不导航 —— 后端确实在播,
           前台还停在原来那一页。

           ★ 分集的 raw 原样带过去:资源站的可播地址就在 raw 里,不带的话
           后端只拿到一个 id,解析不出流。 */
        var name = Str(ep, "name");
        Nav.Push(new PlayerPage(_core, Str(ep, "id"),
            name == "" ? title : $"{title} · {name}", 0,
            isSource: true,
            sourceRaw: ep.TryGetProperty("raw", out var raw) && raw.ValueKind != JsonValueKind.Null
                ? JsonSerializer.Deserialize<object>(raw.GetRawText()) : null));
        return Task.CompletedTask;
    }

    // ---------------------------------------------------------------- 小工具

    /// <summary>
    /// 「不支持这个能力」的判定。**靠核心层给的稳定标记,不靠中文文案** ——
    /// 靠文案判会在改一次提示语时静默失效,而失效的表现是网盘用户被扔进一张空的目录页。
    /// </summary>
    private static bool IsUnsupported(Exception e) =>
        e.Message.Contains("__LP_UNSUPPORTED__", StringComparison.Ordinal) ||
        e.Message.Contains("E_UNSUPPORTED", StringComparison.Ordinal);

    private static void LoadPoster(Image img, string url)
    {
        if (url == "") return;
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
            catch { /* 资源站的图床坏链是常态,留占位不影响整页 */ }
        });
    }

    private static List<JsonElement> Arr(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().ToList() : [];

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v)
            ? v.ValueKind switch
            {
                JsonValueKind.String => v.GetString() ?? "",
                JsonValueKind.Number => v.ToString(),
                _ => "",
            }
            : "";
}
