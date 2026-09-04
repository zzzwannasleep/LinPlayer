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
/// 人物详情(<c>UI_PC.md</c> §7.16):头像 + 简介 + 参演作品网格。
///
/// <para>详情与作品<b>并发</b>拉。串起来的话这一页要等两个往返 ——
/// 而它们互不依赖。</para>
///
/// <para><b>作品失败 → 整段不渲染</b>,但简介照出。两条路各自吞错:
/// 把它们绑在一起的话,参演作品接口一抖,连人名和生平都看不到了。</para>
/// </summary>
public sealed class PersonPage : PageBase
{
    private readonly CoreClient _core;
    private readonly string _server;

    public PersonPage(CoreClient core, string server, string personId, string fallbackName)
    {
        _core = core;
        _server = server;

        var body = new StackPanel { Spacing = 18 };
        var back = new Button { Classes = { "ghost" }, Content = "← 返回", HorizontalAlignment = HorizontalAlignment.Left };
        back.Click += (_, _) => Nav.Back();
        body.Children.Add(back);

        var head = new StackPanel { Spacing = 18, Orientation = Orientation.Horizontal };
        var title = new TextBlock { Text = fallbackName, Classes = { "h1" } };
        var meta = Dim("");
        var bio = new TextBlock { FontSize = 13, TextWrapping = TextWrapping.Wrap, LineHeight = 21, MaxWidth = 900 };

        var avatar = new Border
        {
            Width = 140, Height = 140, CornerRadius = new CornerRadius(999), ClipToBounds = true,
            Background = Tok.Of("PanelAlt"),
            VerticalAlignment = VerticalAlignment.Top,
        };
        head.Children.Add(avatar);
        head.Children.Add(new StackPanel
        {
            Spacing = 10, Children = { title, meta, bio },
        });
        body.Children.Add(head);

        var worksTitle = H2("参演作品");
        worksTitle.IsVisible = false;
        var works = new WrapPanel { ItemSpacing = 14, LineSpacing = 14 };
        var worksMsg = Dim("");
        body.Children.Add(worksTitle);
        body.Children.Add(worksMsg);
        body.Children.Add(works);

        Content = Scrolled(body);

        // 两条各自吞错、各自渲染:作品挂了不该把简介一起带走
        _ = LoadDetail(personId, title, meta, bio, avatar);
        _ = LoadWorks(personId, worksTitle, works, worksMsg);
    }

    private async Task LoadDetail(string id, TextBlock title, TextBlock meta, TextBlock bio, Border avatar)
    {
        JsonElement d;
        try
        {
            var s = Nav.Session!;
            d = await _core.EmbyPersonDetail(new { s.server, s.token, s.user_id, s.device_id, person_id = id });
        }
        catch (Exception e)
        {
            Dispatcher.UIThread.Post(() => meta.Text = LibraryPage.Advice(e));
            return;
        }

        var name = Str(d, "name");
        var overview = Str(d, "overview");
        // 生卒 / 出生地**空是常态**:很多刮削器根本不写这几项。
        // 空的时候整行不出现,而不是显示「生日:」后面跟一片空白。
        var bits = new List<string>();
        if (Str(d, "birthday") is { Length: > 0 } bd) bits.Add("生于 " + Date(bd));
        if (Str(d, "death_day") is { Length: > 0 } dd) bits.Add("卒于 " + Date(dd));
        if (Str(d, "birth_place") is { Length: > 0 } bp) bits.Add(bp);

        Dispatcher.UIThread.Post(() =>
        {
            if (name.Length > 0) title.Text = name;
            meta.Text = string.Join("  ·  ", bits);
            meta.IsVisible = bits.Count > 0;
            // 「没有生平」要说出来,别留一片空白让人以为没加载完
            bio.Text = overview.Length > 0 ? overview : "这个人物没有生平简介。";
            bio.Opacity = overview.Length > 0 ? 1 : 0.55;
        });

        if (Bool(d, "has_primary"))
        {
            var im = new Image { Stretch = Stretch.UniformToFill };
            var bmp = await Images.LoadAsync(_core, Images.EmbyImageUrl(_server, Str(d, "id"), "Primary"), 280);
            if (bmp is null) return;
            Dispatcher.UIThread.Post(() =>
            {
                im.Source = bmp;
                avatar.Child = im;
            });
        }
    }

    private async Task LoadWorks(string id, TextBlock header, WrapPanel grid, TextBlock msg)
    {
        List<JsonElement> items;
        try
        {
            var s = Nav.Session!;
            var arr = await _core.EmbyPersonItems(new
            {
                s.server, s.token, s.user_id, s.device_id, person_id = id, limit = 60,
            });
            items = arr.ValueKind == JsonValueKind.Array ? arr.EnumerateArray().ToList() : [];
        }
        catch
        {
            // 作品失败 → **整段不渲染**(标题都不出)。
            // 出一个空的「参演作品」标题,比不出更糟:那是在说「他没演过东西」。
            return;
        }

        Dispatcher.UIThread.Post(() =>
        {
            header.IsVisible = true;
            if (items.Count == 0)
            {
                msg.Text = "没有找到参演作品。";
                return;
            }
            msg.IsVisible = false;
            foreach (var it in items)
                grid.Children.Add(new Card(_core, _server, CardItem.From(it), false,
                    LibraryPage.OpenDetail(_core, _server)));
        });
    }

    /// <summary>ISO 日期只取 yyyy-MM-dd —— 服务端给的是带时区的完整时间戳。</summary>
    private static string Date(string iso) => iso.Length >= 10 ? iso[..10] : iso;

    private static string Str(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String
            ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement e, string k) =>
        e.ValueKind == JsonValueKind.Object && e.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
}
