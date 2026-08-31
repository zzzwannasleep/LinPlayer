using System.Text.Json;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Layout;
using Avalonia.Media;
using Avalonia.VisualTree;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 详情页(UI_PC §7.3)。
///
/// <para>★ 「没值就整行不画,不留空位」:标语实测只有约三分之一的条目有,
/// 留空位的话大部分条目看上去像少加载了什么。</para>
/// </summary>
public sealed class DetailPage : PageBase
{
    private readonly CoreClient _core;
    private readonly string _server;

    public DetailPage(CoreClient core, string server, string itemId)
    {
        _core = core; _server = server;

        var body = new StackPanel { Spacing = 16 };
        var back = new Button { Classes = { "ghost" }, Content = "← 返回", HorizontalAlignment = HorizontalAlignment.Left };
        back.Click += (_, _) => Nav.Back();
        body.Children.Add(back);
        var busy = Dim("加载中…");
        body.Children.Add(busy);
        Content = Scrolled(body);

        _ = Task.Run(async () =>
        {
            try
            {
                var s = Nav.Session!;
                // ★ 桌面端 with_children=true:一屏铺完所有集。
                //   手机端才分页(实测最长的剧全量拉 1.8MB / 1841ms)。
                var d = await core.EmbyItemDetail(new
                {
                    s.server, s.token, s.user_id, s.device_id,
                    item_id = itemId, with_children = true,
                });
                Dispatcher.UIThread.Post(() =>
                {
                    body.Children.Remove(busy);
                    Render(body, d);
                });
            }
            catch (Exception e)
            {
                Dispatcher.UIThread.Post(() => busy.Text = $"加载失败:{LibraryPage.Advice(e)}");
            }
        });
    }

    private void Render(StackPanel body, JsonElement d)
    {
        var id = Str(d, "id");
        var type = Str(d, "type_");
        var name = Str(d, "name");
        var series = Str(d, "series_name");

        // ---- 头部:海报 + 标题块 ----
        var poster = new Border
        {
            Width = 200, Height = 300, CornerRadius = new CornerRadius(10), ClipToBounds = true,
            VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(Color.Parse("#1b212c")),
        };
        if (Bool(d, "has_primary"))
        {
            var im = new Image { Stretch = Stretch.UniformToFill };
            poster.Child = im;
            _ = Fill(im, Images.EmbyImageUrl(_server, id, "Primary"), 600);
        }

        var head = new StackPanel { Spacing = 10, MaxWidth = 900 };
        head.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(series) ? name : $"{series} · {name}",
            FontSize = 26, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap,
        });

        var bits = new List<string>();
        if (Num(d, "year") > 0) bits.Add(((int)Num(d, "year")).ToString());
        if (Str(d, "official_rating") != "") bits.Add(Str(d, "official_rating"));
        if (Str(d, "status") != "") bits.Add(Str(d, "status"));
        if (Num(d, "runtime_secs") > 0) bits.Add($"{(int)(Num(d, "runtime_secs") / 60)} 分钟");
        if (Num(d, "rating") > 0) bits.Add($"★ {Num(d, "rating"):0.0}");
        if (Arr(d, "genres").Count > 0) bits.Add(string.Join(" / ", Arr(d, "genres")));
        if (bits.Count > 0) head.Children.Add(Dim(string.Join("  ·  ", bits)));

        // 标语:没有就整行不画
        var tagline = Str(d, "tagline");
        if (tagline != "")
        {
            head.Children.Add(new TextBlock
            {
                Text = tagline, FontStyle = FontStyle.Italic, TextWrapping = TextWrapping.Wrap,
                Foreground = new SolidColorBrush(Color.Parse("#9aa5b8")),
            });
        }

        head.Children.Add(PlayRow(d, id, type));

        var overview = Str(d, "overview");
        if (overview != "")
        {
            head.Children.Add(new TextBlock
            {
                Text = overview, TextWrapping = TextWrapping.Wrap, LineHeight = 22,
                Foreground = new SolidColorBrush(Color.Parse("#c2cbdb")),
            });
        }

        body.Children.Add(new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 22,
            Children = { poster, head },
        });

        // ---- 分集 ----
        var children = Arr2(d, "children");
        if (children.Count > 0)
        {
            body.Children.Add(H2($"剧集({children.Count})"));
            body.Children.Add(LibraryPage.Grid(_core, _server,
                children.Select(CardItem.From).ToList(), true,
                it => Nav.Push(new PlayerPage(_core, it.Id, it.DisplayTitle, it.ResumeSecs))));
        }

        // ---- 演职人员 ----
        var people = Arr2(d, "people");
        if (people.Count > 0)
        {
            body.Children.Add(H2("演职人员"));
            var wrap = new WrapPanel();
            foreach (var p in people.Take(24))
            {
                var av = new Border
                {
                    Width = 84, Height = 84, CornerRadius = new CornerRadius(42), ClipToBounds = true,
                    Background = new SolidColorBrush(Color.Parse("#1b212c")),
                };
                if (Bool(p, "has_primary"))
                {
                    var im = new Image { Stretch = Stretch.UniformToFill };
                    av.Child = im;
                    _ = Fill(im, Images.EmbyImageUrl(_server, Str(p, "id"), "Primary"), 168);
                }
                wrap.Children.Add(new StackPanel
                {
                    Width = 100, Spacing = 6, Margin = new Thickness(0, 0, 10, 14),
                    Children =
                    {
                        av,
                        new TextBlock
                        {
                            Text = Str(p, "name"), FontSize = 12, MaxLines = 2,
                            TextWrapping = TextWrapping.Wrap, TextAlignment = TextAlignment.Center,
                        },
                        new TextBlock
                        {
                            Text = Str(p, "role"), FontSize = 11, MaxLines = 1,
                            TextTrimming = TextTrimming.CharacterEllipsis,
                            TextAlignment = TextAlignment.Center,
                            Foreground = new SolidColorBrush(Color.Parse("#6b7688")),
                        },
                    },
                });
            }
            body.Children.Add(wrap);
        }
    }

    /// <summary>播放按钮行。有进度就把时间点写在按钮上 —— 只写「播放」用户会以为要从头看。</summary>
    private Control PlayRow(JsonElement d, string id, string type)
    {
        var resume = Num(d, "resume_secs");
        var name = Str(d, "name");
        var playable = type is "Movie" or "Episode" or "Video" or "MusicVideo";

        var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
        if (playable)
        {
            var play = new Button
            {
                Classes = { "primary" },
                Content = resume > 0 ? $"▶ 继续播放 {(int)resume / 60}:{(int)resume % 60:00}" : "▶ 播放",
            };
            play.Click += (_, _) => Nav.Push(new PlayerPage(_core, id, name, resume));
            row.Children.Add(play);
        }

        var fav = new Button
        {
            Classes = { "ghost" },
            Content = Bool(d, "is_favorite") ? "♥ 已收藏" : "♡ 收藏",
        };
        fav.Click += async (_, _) =>
        {
            var on = (string?)fav.Content == "♡ 收藏";
            try
            {
                var s = Nav.Session!;
                // ★ 参数名是 fav,不是 favorite。写错了**不报错** ——
                //   布尔默认成 false,表现是「点收藏反而取消了收藏」。
                await _core.EmbySetFavorite(new
                {
                    s.server, s.token, s.user_id, s.device_id, item_id = id, fav = on,
                });
                fav.Content = on ? "♥ 已收藏" : "♡ 收藏";
            }
            catch (Exception e) { fav.Content = LibraryPage.Advice(e); }
        };
        row.Children.Add(fav);

        // ★ 下载只对**可播条目**给。给一部剧的总条目下载按钮,点了不知道该下哪一集。
        if (playable)
        {
            var dl = new Button { Classes = { "ghost" }, Content = "⭳ 下载" };
            dl.Click += async (_, _) =>
            {
                dl.IsEnabled = false;
                try
                {
                    /* ★ container 从媒体信息里取。给错的话文件后缀就错 ——
                       播放器认后缀,mkv 存成 mp4 有的播放器直接不认。
                       取不到就交给核心层兜底(它默认 mkv)。 */
                    await _core.DownloadEnqueue(new
                    {
                        item_id = id, type_ = type, title = name,
                        container = Str(d, "container"),
                        poster_url = (string?)null,
                    });
                    dl.Content = "已加入下载";
                }
                catch (Exception e)
                {
                    // ★ 下载权限是**服务端**判的:没权限时如实说,别写成「网络错误」
                    dl.Content = LibraryPage.Advice(e);
                    dl.IsEnabled = true;
                }
            };
            row.Children.Add(dl);
        }
        return row;
    }

    /// <summary>自检用:点一下「下载」按钮。</summary>
    internal void SelfCheckDownload()
    {
        foreach (var b in this.GetVisualDescendants().OfType<Button>())
            if ((b.Content as string) == "⭳ 下载") { b.Command?.Execute(null); RaiseClick(b); return; }
    }

    private static void RaiseClick(Button b) =>
        b.RaiseEvent(new Avalonia.Interactivity.RoutedEventArgs(Button.ClickEvent));

    private static async Task Fill(Image target, string url, int maxH)
    {
        var bmp = await Images.LoadAsync(Program.Core!, url, maxH);
        if (bmp is not null) Dispatcher.UIThread.Post(() => target.Source = bmp);
    }

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
    private static double Num(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number
            ? v.GetDouble() : 0;
    private static List<string> Arr(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().Select(x => x.GetString() ?? "").Where(x => x != "").ToList() : [];
    private static List<JsonElement> Arr2(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Array
            ? v.EnumerateArray().ToList() : [];
}
