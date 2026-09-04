using System;
using System.Collections.Generic;
using System.Linq;
using System.Text.Json;
using System.Threading.Tasks;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 排行榜(<c>UI_PC.md</c> §7.13)。动漫走弹弹Play,影视走 TMDB。
///
/// <para>这一页最要紧的不是布局,是错误怎么显示。核心层已经把「缺凭据 / 429 /
/// 密钥无效 / 分类下线」分别说清楚了,UI 这边要原样透出来 —— 吞成「暂无数据」
/// 的话几种成因又变回一个样子,那正是排查花掉一整天的原因。
/// 没有凭据的构建里要说「这个版本没带排行榜凭据」,而不是画个空页面。</para>
/// </summary>
public sealed class RankingPage : PageBase
{
    private readonly CoreClient _core;
    private readonly ComboBox _group = new() { Width = 130, MinHeight = 34 };
    private readonly ComboBox _cat = new() { Width = 170, MinHeight = 34 };
    private readonly Button _refresh = new() { Content = "刷新", MinHeight = 34, Classes = { "ghost" } };
    private readonly WrapPanel _grid = new() { ItemSpacing = 14, LineSpacing = 14 };
    private readonly TextBlock _msg = Dim("");

    private sealed record Cat(string Id, string Group, string Label, string Source);

    private List<Cat> _all = [];
    private string _curCat = "";
    private bool _building;   // 重建下拉时别让 SelectionChanged 触发一次白拉

    public RankingPage(CoreClient core)
    {
        _core = core;

        var bar = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 10,
            Children = { _group, _cat, _refresh },
        };
        _refresh.Click += (_, _) =>
        {
            // 手动刷新要**绕过 6 小时缓存**,否则点了没反应
            if (_curCat.Length > 0) _ = Fetch(_curCat, force: true);
        };
        _group.SelectionChanged += (_, _) => { if (!_building) RebuildCats(); };
        _cat.SelectionChanged += (_, _) =>
        {
            if (_building) return;
            if (_cat.SelectedItem is ComboBoxItem { Tag: string id }) _ = Fetch(id, force: false);
        };

        Content = Scrolled(new StackPanel
        {
            Spacing = 14,
            Children = { H1("排行榜"), bar, _msg, _grid },
        });

        _ = Load();
    }

    private async Task Load()
    {
        _msg.Text = "加载中…";
        List<Cat> all;
        try
        {
            var arr = await _core.EmbyRankingCategories();
            all = arr.ValueKind == JsonValueKind.Array
                ? arr.EnumerateArray()
                    .Select(e => new Cat(Str(e, "id"), Str(e, "group"), Str(e, "label"), Str(e, "source")))
                    .ToList()
                : [];
        }
        catch (Exception e)
        {
            _msg.Text = "拿不到榜单分类:" + LibraryPage.Advice(e);
            return;
        }

        _all = all;
        if (_all.Count == 0)
        {
            // 空表不是「出错了」,是**这个构建没带凭据**。说清楚,别画空页面。
            _msg.Text = "这个版本没有带排行榜的凭据,所以排行榜不可用。\n" +
                        "官方发行包里是带的;自己从源码构建时,需要在构建环境里提供 " +
                        "DANDANPLAY_APP_ID / DANDANPLAY_APP_SECRET / TMDB_API_KEY。";
            _group.IsEnabled = _cat.IsEnabled = _refresh.IsEnabled = false;
            return;
        }

        _building = true;
        _group.Items.Clear();
        // 只列**真的有分类**的组:亮一个点进去是空的页签,比不亮更让人困惑
        foreach (var (key, label) in new[] { ("anime", "动漫"), ("movie", "电影"), ("tv", "剧集") })
        {
            if (_all.Any(c => c.Group == key)) _group.Items.Add(new ComboBoxItem { Content = label, Tag = key });
        }
        _building = false;
        _group.SelectedIndex = 0; // 触发 RebuildCats
    }

    private void RebuildCats()
    {
        if (_group.SelectedItem is not ComboBoxItem { Tag: string g }) return;
        _building = true;
        _cat.Items.Clear();
        foreach (var c in _all.Where(x => x.Group == g))
            _cat.Items.Add(new ComboBoxItem { Content = c.Label, Tag = c.Id });
        _building = false;
        if (_cat.ItemCount > 0) _cat.SelectedIndex = 0; // 触发 Fetch
    }

    private async Task Fetch(string catId, bool force)
    {
        _curCat = catId;
        _grid.Children.Clear();
        _msg.Text = "加载中…";

        JsonElement arr;
        try
        {
            arr = await _core.EmbyRankingFetch(new { category_id = catId, force_refresh = force });
        }
        catch (Exception e)
        {
            // 原样显示核心层给的那句话。它已经分清了缺凭据 / 429 / 密钥无效 /
            // 分类下线 —— 换成「暂无数据」的话,这几种又变回一个样子。
            _msg.Text = LibraryPage.Advice(e);
            return;
        }

        // 换分类比请求快得多:回来时用户可能已经点到别的榜了,别把旧结果画上去
        if (_curCat != catId) return;

        var n = 0;
        if (arr.ValueKind == JsonValueKind.Array)
        {
            foreach (var e in arr.EnumerateArray())
            {
                _grid.Children.Add(new RankCard(_core, e));
                n++;
            }
        }
        _msg.Text = n == 0 ? "这个榜当前是空的(上游没有返回条目)。" : "";
    }

    /// <summary>自检用:落到指定分组(anime / movie / tv)。分类清单是异步来的,所以要等。</summary>
    internal void SelfCheckGroup(string group) => _ = SelectGroupWhenReady(group);

    private async Task SelectGroupWhenReady(string group)
    {
        for (var i = 0; i < 40 && _all.Count == 0; i++) await Task.Delay(100);
        for (var i = 0; i < _group.ItemCount; i++)
        {
            if (_group.Items[i] is ComboBoxItem { Tag: string g } && g == group)
            {
                _group.SelectedIndex = i;
                return;
            }
        }
    }

    internal static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
}

/// <summary>
/// 榜单卡。和媒体卡不同:它<b>不指向用户媒体库里的条目</b>,只是一张榜单海报。
///
/// <para>所以不复用 <see cref="Card"/> —— 那个带右键动作(标记已看 / 收藏 / 屏蔽),
/// 而榜单条目在用户的服务器上根本不存在,那三项点下去只会报错。</para>
/// </summary>
public sealed class RankCard : Border
{
    public RankCard(CoreClient core, JsonElement e)
    {
        const double w = 150;
        const double h = w * 3 / 2;
        var title = RankingPage.Str(e, "title");
        var rank = e.TryGetProperty("rank", out var r) && r.ValueKind == JsonValueKind.Number ? r.GetInt32() : 0;
        var img = new Image { Stretch = Stretch.UniformToFill, Opacity = 0 };

        var art = new Border
        {
            Width = w, Height = h, CornerRadius = new CornerRadius(10), ClipToBounds = true,
            Background = Tok.Of("PanelAlt"),
            Child = new Panel
            {
                Children =
                {
                    // 占位:没有海报时也要看得出这是什么,而不是一块空砖
                    new TextBlock
                    {
                        Text = title, FontSize = 12, Margin = new Thickness(10),
                        Foreground = Tok.Of("Ink3"),
                        TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center,
                        VerticalAlignment = VerticalAlignment.Center,
                        HorizontalAlignment = HorizontalAlignment.Center,
                    },
                    img,
                    // 名次角标:左上角。 媒体卡的角标在右上(未看数)和左下(进度),
                    // 放左上是为了以后混排时一眼分得清「这是榜单卡」
                    new Border
                    {
                        HorizontalAlignment = HorizontalAlignment.Left,
                        VerticalAlignment = VerticalAlignment.Top,
                        Margin = new Thickness(6),
                        Padding = new Thickness(6, 2, 6, 2),
                        CornerRadius = new CornerRadius(6),
                        Background = new SolidColorBrush(Color.Parse("#cc000000")),
                        IsVisible = rank > 0,
                        Child = new TextBlock
                        {
                            Text = rank.ToString(),
                            FontSize = 12, FontWeight = FontWeight.Bold,
                            Foreground = new SolidColorBrush(Color.Parse(rank <= 3 ? "#e0a95b" : "#e8ebf1")),
                        },
                    },
                },
            },
        };

        var sub = RankingPage.Str(e, "subtitle");
        var rating = e.TryGetProperty("rating", out var rv) && rv.ValueKind == JsonValueKind.Number
            ? rv.GetDouble() : 0;
        var meta = string.Join(" · ",
            new[] { sub, rating > 0 ? rating.ToString("0.0") : "" }.Where(s => s.Length > 0));

        Child = new StackPanel
        {
            Width = w, Spacing = 6,
            Children =
            {
                art,
                new TextBlock
                {
                    Text = title, FontSize = 12.5, MaxLines = 2,
                    TextWrapping = TextWrapping.Wrap, TextTrimming = TextTrimming.CharacterEllipsis,
                },
                new TextBlock { Text = meta, FontSize = 11, Opacity = 0.6, IsVisible = meta.Length > 0 },
            },
        };

        var url = RankingPage.Str(e, "image_url");
        if (url.Length > 0) _ = LoadArt(core, url, img, (int)(h * 2));
    }

    private static async Task LoadArt(CoreClient core, string url, Image target, int maxH)
    {
        // 走本地图片通道(和封面同一条路)。图床在核心层的**静态白名单**里,
        // 不在账号表里 —— 见 core/net/localserve 的 AllowStatic。
        var bmp = await Images.LoadAsync(core, url, maxH);
        if (bmp is null) return;
        Dispatcher.UIThread.Post(() =>
        {
            target.Source = bmp;
            target.Opacity = 1;
        });
    }
}
