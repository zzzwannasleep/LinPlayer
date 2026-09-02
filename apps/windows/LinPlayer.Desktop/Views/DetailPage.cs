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
    private readonly Button _back = null!;

    public DetailPage(CoreClient core, string server, string itemId)
    {
        _core = core; _server = server;

        var body = new StackPanel { Spacing = 16 };
        /* ★ 返回按钮在**数据回来之前**就得能点:详情拉了 10 秒还在转的时候,
           用户第一件想做的事就是退出去。所以它先挂上,渲染时再被搬进背景大图里。 */
        var back = new Button { Classes = { "ghost" }, Content = "← 返回", HorizontalAlignment = HorizontalAlignment.Left };
        back.Click += (_, _) => Nav.Back();
        body.Children.Add(back);
        _back = back;
        /* ★ 占位用骨架,不是「加载中…」三个字 —— 详情页是全站内容最高的一页,
           从 20px 撑到 1200px 的那一跳最明显。 */
        Control busy = Skeleton.Detail();
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
                var why = LibraryPage.Advice(e);
                Dispatcher.UIThread.Post(() =>
                {
                    var at = body.Children.IndexOf(busy);
                    if (at >= 0) body.Children[at] = Dim($"加载失败:{why}");
                });
            }
        });
    }

    private void Render(StackPanel body, JsonElement d)
    {
        var id = Str(d, "id");
        var type = Str(d, "type_");
        var name = Str(d, "name");
        var series = Str(d, "series_name");

        // ★ 分集要在画头部**之前**拿到:主按钮是「继续观看 第 N 集」(得知道下一集),
        //   元信息里的「共 N 季 · M 集」也要数它。
        var episodes = Arr2(d, "children").Select(CardItem.From).ToList();

        // ---- 头部:海报 + 标题块 ----
        var poster = new Border
        {
            Width = 220, Height = 330, CornerRadius = new CornerRadius(12), ClipToBounds = true,
            VerticalAlignment = VerticalAlignment.Top,
            Background = new SolidColorBrush(Color.Parse("#1b212c")),
        };
        if (Bool(d, "has_primary"))
        {
            var im = new Image { Stretch = Stretch.UniformToFill, Opacity = 0, Classes = { "art" } };
            poster.Child = im;
            _ = Fill(im, Images.EmbyImageUrl(_server, id, "Primary"), 660);
        }

        var head = new StackPanel { Spacing = 10, MaxWidth = 900 };
        head.Children.Add(new TextBlock
        {
            Text = string.IsNullOrEmpty(series) ? name : $"{series} · {name}",
            FontSize = 30, FontWeight = FontWeight.SemiBold, TextWrapping = TextWrapping.Wrap,
        });

        var bits = new List<string>();
        if (Num(d, "year") > 0) bits.Add(((int)Num(d, "year")).ToString());
        if (Str(d, "official_rating") != "") bits.Add(Str(d, "official_rating"));
        if (StatusText(Str(d, "status")) != "") bits.Add(StatusText(Str(d, "status")));
        if (Num(d, "runtime_secs") > 0) bits.Add($"{(int)(Num(d, "runtime_secs") / 60)} 分钟");
        /* 剧:季数 / 集数。
           ★ 季数用**分集里真实出现过的季号**去数,不用 child_count ——
             那个字段在 Series 上是季数、在 Season 上是集数,两种含义,信它就会写反。 */
        if (type == "Series" && episodes.Count > 0)
        {
            var seasonCount = episodes.Select(e => e.SeasonNo).Distinct().Count();
            bits.Add(seasonCount > 1 ? $"{seasonCount} 季 · {episodes.Count} 集" : $"{episodes.Count} 集");
        }
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

        head.Children.Add(PlayRow(d, id, type, episodes));

        var overview = Str(d, "overview");
        if (overview != "")
        {
            head.Children.Add(new TextBlock
            {
                Text = overview, TextWrapping = TextWrapping.Wrap, LineHeight = 22,
                Foreground = new SolidColorBrush(Color.Parse("#c2cbdb")),
            });
        }

        var headRow = new StackPanel
        {
            Orientation = Orientation.Horizontal, Spacing = 26,
            Children = { poster, head },
        };
        /* ★★ 返回按钮要**盖在背景图上**,不能压在它上面一行。
           压在上面的话背景图是从页面中间才开始的,顶上留一条黑边 ——
           那不叫背景图,那叫一张插图。把它搬进来,图才是从内容区顶上铺开的。 */
        body.Children.Remove(_back);
        _back.Margin = new Thickness(0, 0, 0, 14);
        body.Children.Insert(0, Backdrop(d, id, new StackPanel
        {
            Spacing = 0, Children = { _back, headRow },
        }));

        // ---- 分集 ----
        if (episodes.Count > 0) body.Children.Add(Episodes(episodes));

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
                    var im = new Image { Stretch = Stretch.UniformToFill, Opacity = 0, Classes = { "art" } };
                    av.Child = im;
                    _ = Fill(im, Images.EmbyImageUrl(_server, Str(p, "id"), "Primary"), 168);
                }
                else
                {
                    /* ★ 没有头像时放姓氏,不留一个空圆。
                       演职员表里**大半都没有头像**(刮削器很少刮全),
                       一排空圆看着像加载失败,而它其实已经加载完了。 */
                    av.Child = new TextBlock
                    {
                        Text = Str(p, "name") is { Length: > 0 } nm ? nm[..1] : "?",
                        FontSize = 30, FontWeight = FontWeight.SemiBold,
                        Foreground = new SolidColorBrush(Color.Parse("#4a5464")),
                        HorizontalAlignment = HorizontalAlignment.Center,
                        VerticalAlignment = VerticalAlignment.Center,
                    };
                }
                // ★ 头像可点 → 人物详情。做成 Button 而不是给 Border 挂 PointerPressed:
                //   Button 自带 hover / focus / 键盘可达,手写那三样迟早漏一个。
                var pid = Str(p, "id");
                var pname = Str(p, "name");
                var cell = new Button
                {
                    Background = Brushes.Transparent,
                    BorderThickness = new Thickness(0),
                    Padding = new Thickness(0),
                    Cursor = new Avalonia.Input.Cursor(Avalonia.Input.StandardCursorType.Hand),
                };
                cell.Click += (_, _) => Nav.Push(new PersonPage(_core, _server, pid, pname));
                cell.Content = new StackPanel
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
                };
                wrap.Children.Add(cell);
            }
            body.Children.Add(wrap);
        }
    }

    /// <summary>
    /// 秒 → 时间点。
    ///
    /// <para>★ 超过一小时要写成 <c>1:05:30</c>。只按「分:秒」写的话
    /// 一部两小时的片会显示成 <c>95:12</c> —— 那不是任何人读得懂的时间。</para>
    /// </summary>
    private static string Clock(double secs)
    {
        var t = TimeSpan.FromSeconds(Math.Max(0, secs));
        return t.TotalHours >= 1
            ? $"{(int)t.TotalHours}:{t.Minutes:00}:{t.Seconds:00}"
            : $"{t.Minutes}:{t.Seconds:00}";
    }

    /// <summary>
    /// 连载状态的人话。
    ///
    /// <para>★★ Emby 回的是 <c>Continuing</c> / <c>Ended</c> —— <b>英文原文</b>。
    /// 原样摆在一整页中文里不是「没翻译」这种小事,是**用户读不懂这一栏在说什么**。
    /// 认不出来的值就整个不显示:摆一个原文英文比不摆更像 bug。</para>
    /// </summary>
    private static string StatusText(string raw) => raw switch
    {
        "Continuing" => "连载中",
        "Ended" => "已完结",
        "Unreleased" => "未播出",
        _ => "",
    };

    /// <summary>
    /// 给头部垫一张背景大图。
    ///
    /// <para>★★ 淡出用的是 <b>OpacityMask</b>,不是「盖一层背景色的渐变」——
    /// 盖色要知道当前主题的底色,而本仓有深浅两套皮;写死一个色号就等于
    /// 浅色主题下头顶一道黑边。遮罩让页面底色自己透上来,换皮不用改这里。</para>
    ///
    /// <para>★ 没有背景图就<b>原样返回内容</b>,不留空高度 —— 留着的话
    /// 没刮削背景的条目头顶会空出 420px。</para>
    /// </summary>
    private Control Backdrop(JsonElement d, string id, Control content)
    {
        if (!Bool(d, "has_backdrop")) return content;

        var img = new Image
        {
            Stretch = Stretch.UniformToFill, Opacity = 0, Classes = { "art" },
            VerticalAlignment = VerticalAlignment.Top,
            HorizontalAlignment = HorizontalAlignment.Stretch,
            // 上半段实,下半段化开 —— 图和正文之间不要留一条硬边。
            OpacityMask = new LinearGradientBrush
            {
                StartPoint = new RelativePoint(0, 0, RelativeUnit.Relative),
                EndPoint = new RelativePoint(0, 1, RelativeUnit.Relative),
                GradientStops =
                {
                    new GradientStop(Colors.White, 0),
                    new GradientStop(Colors.White, 0.35),
                    new GradientStop(Color.FromArgb(0, 255, 255, 255), 1),
                },
            },
        };
        _ = Fill(img, Images.EmbyImageUrl(_server, id, "Backdrop"), 720);

        return new Panel
        {
            Children =
            {
                new Border
                {
                    Height = 420, VerticalAlignment = VerticalAlignment.Top,
                    ClipToBounds = true,
                    /* ★ 0.42:实测 0.30 在深色底上**几乎看不见**,等于白做;
                       再往上标题就压不住图上的高光,读起来吃力。
                       背景是氛围不是内容 —— 它不许和正文抢注意力,但也得存在。 */
                    Opacity = 0.42, Child = img,
                },
                content,
            },
        };
    }

    /// <summary>
    /// 分集区。
    ///
    /// <para>★★ <b>多季必须分组</b>。20 集平铺成一片,想找「第二季第 1 集」只能从头数 ——
    /// 而剧集详情页最常见的动作恰恰就是这个。只有一季时不画季条:
    /// 一个只有一个选项的选择器是纯噪音。</para>
    ///
    /// <para>★ 默认落在**接着看的那一季**,不是第一季。追到第三季的人每次进来
    /// 都得先点一下第三季,那这个默认值等于没有。</para>
    /// </summary>
    private Control Episodes(List<CardItem> episodes)
    {
        var groups = episodes.GroupBy(e => e.SeasonNo).OrderBy(g => g.Key).ToList();
        var host = new StackPanel { Spacing = 14 };
        var gridHost = new ContentControl();

        void ShowSeason(List<CardItem> list) => gridHost.Content = LibraryPage.Grid(
            _core, _server, list, true,
            it => Nav.Push(new PlayerPage(_core, it.Id, it.DisplayTitle, it.ResumeSecs)),
            episodeStyle: true);

        if (groups.Count <= 1)
        {
            host.Children.Add(H2($"剧集 · 共 {episodes.Count} 集"));
            ShowSeason(episodes);
            host.Children.Add(gridHost);
            return host;
        }

        host.Children.Add(H2($"剧集 · {groups.Count} 季 · 共 {episodes.Count} 集"));
        var bar = new WrapPanel();
        var next = NextEpisode(episodes);
        var current = groups.FindIndex(g => g.Key == next.SeasonNo);
        if (current < 0) current = 0;

        for (var i = 0; i < groups.Count; i++)
        {
            var idx = i;
            var g = groups[i];
            var chip = new Button
            {
                Classes = { "chip" }, Margin = new Thickness(0, 0, 8, 0),
                Content = g.Key > 0 ? $"第 {g.Key} 季 · {g.Count()} 集" : $"其它 · {g.Count()} 集",
            };
            chip.Click += (_, _) =>
            {
                for (var k = 0; k < bar.Children.Count; k++)
                    ((Button)bar.Children[k]).Classes.Set("on", k == idx);
                ShowSeason(groups[idx].ToList());
            };
            bar.Children.Add(chip);
        }
        ((Button)bar.Children[current]).Classes.Set("on", true);
        ShowSeason(groups[current].ToList());
        host.Children.Add(bar);
        host.Children.Add(gridHost);
        return host;
    }

    /// <summary>
    /// 接着该看哪一集:①看了一半的 → ②第一集没看过的 → ③第一集。
    ///
    /// <para>★ <b>这个顺序和 Emby 的「继续观看」一致</b>,主按钮和季条默认值共用它 ——
    /// 两处各写一份的话迟早会指到不同的集上,而那种不一致没人会当成 bug 报上来。</para>
    /// </summary>
    private static CardItem NextEpisode(List<CardItem> eps) =>
        eps.FirstOrDefault(e => e.ResumeSecs > 0)
        ?? eps.FirstOrDefault(e => !e.Played)
        ?? eps[0];

    /// <summary>播放按钮行。有进度就把时间点写在按钮上 —— 只写「播放」用户会以为要从头看。</summary>
    private Control PlayRow(JsonElement d, string id, string type, List<CardItem> episodes)
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
                Content = resume > 0 ? $"▶ 继续播放 · 已看到 {Clock(resume)}" : "▶ 播放",
            };
            play.Click += (_, _) => Nav.Push(new PlayerPage(_core, id, name, resume));
            row.Children.Add(play);
        }
        else if (type == "Series" && episodes.Count > 0)
        {
            /* ★★ 剧集详情页**必须有主按钮**。之前只有 Movie/Episode 有,
               剧的详情页上一个播放按钮都没有 —— 用户得滚到下面的分集网格里
               自己找「我看到第几集了」。那不是详情页,那是目录。

               挑哪一集的顺序在 NextEpisode 里,和季条的默认季共用同一份。 */
            var next = NextEpisode(episodes);
            var label = next.SeasonNo > 0 && next.EpisodeNo > 0
                ? $"第 {next.SeasonNo} 季 · {next.Name}" : next.Name;
            var play = new Button
            {
                Classes = { "primary" },
                Content = next.ResumeSecs > 0 ? $"▶ 继续观看 · {label}" : $"▶ 播放 · {label}",
            };
            play.Click += (_, _) =>
                Nav.Push(new PlayerPage(_core, next.Id, next.DisplayTitle, next.ResumeSecs));
            row.Children.Add(play);
        }

        // ★ 收藏跟 Features 走 —— 侧栏的「收藏」下线了,这里还留着按钮的话,
        //   用户收藏完找不到地方看,和「屏蔽了没有解除列表」是同一类坑。
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
        if (Features.On("card.favorite")) row.Children.Add(fav);

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

            /* 用外部播放器打开。
               ★ 按钮**只在配了外部播放器时才出现**:没配的话点了只会得到
                 「未设置外部播放器」,那是一条纯噪音 —— 摆一个必定失败的按钮
                 比没有更糟。所以先问核心层,拿到非空才加。 */
            var ext = new Button { Classes = { "ghost" }, Content = "⧉ 外部播放器" };
            ext.Click += async (_, _) =>
            {
                ext.IsEnabled = false;
                try
                {
                    var s = Nav.Session!;
                    await _core.PlayerPlayExternal(new
                    {
                        s.server, s.token, s.user_id, s.device_id,
                        item_id = id, resume_secs = resume,
                    });
                    ext.Content = "已交给外部播放器";
                }
                catch (Exception e) { ext.Content = LibraryPage.Advice(e); }
                finally { ext.IsEnabled = true; }
            };
            _ = Task.Run(async () =>
            {
                try
                {
                    var p = await _core.PlayerGetPlaybackPrefs(new { });
                    if (Str(p, "external_player") != "")
                        Dispatcher.UIThread.Post(() => row.Children.Add(ext));
                }
                catch { /* 拿不到就当没配 —— 这一个按钮不值得把详情页拖红 */ }
            });
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

    /// <summary>
    /// 取一张图挂上去。
    ///
    /// <para>★★ <b>必须把 Opacity 拨回 1</b>。这些 Image 起手是 <c>Opacity=0</c>
    /// (配 <c>Image.art</c> 的过渡做淡入),只塞 Source 不拨透明度的话
    /// 图<b>拉回来了、也画上去了、就是看不见</b> —— 表现是海报和背景大图
    /// 永远是一块空底色,而请求日志里明明有 200。
    /// 2026-09-02 栽过一次,编译绿、日志绿,只有截图看得出来。</para>
    /// </summary>
    private static async Task Fill(Image target, string url, int maxH)
    {
        var bmp = await Images.LoadAsync(Program.Core!, url, maxH);
        if (bmp is null) return;
        Dispatcher.UIThread.Post(() =>
        {
            target.Source = bmp;
            target.Opacity = 1;
        });
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
