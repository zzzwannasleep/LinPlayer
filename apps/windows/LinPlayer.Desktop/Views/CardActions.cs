using System;
using Avalonia;
using Avalonia.Controls;
using Avalonia.Media;
using Avalonia.Media.Transformation;
using Avalonia.Threading;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 卡片动作:标记已看 / 收藏 / 屏蔽。一处实现,所有卡片共用。
///
/// <para>这几个动作在首页、媒体库网格、收藏、详情页的分集里都要有 —— 各处各写
/// 一份的表现是「某个入口少一项」,而少的那一项永远是最后加的那个。
/// 参数名照核心层原样:收藏是 <c>fav</c> 不是 <c>favorite</c>,屏蔽是 <c>id</c>/<c>blocked</c>。
/// 写错了不报错,布尔默认成 false —— 表现是「点收藏反而取消了收藏」。</para>
/// </summary>
public static class CardActions
{
    /// <summary>
    /// 给一张卡挂右键菜单。<paramref name="after"/> 在动作成功后调,用来刷新。
    ///
    /// <para>菜单是右键那一下才建的,不是造卡时就建 —— 一个 <see cref="ContextMenu"/>
    /// 是个弹出宿主,不是轻量对象;一屏 140 张卡就是 140 个宿主 + 200 多个菜单项,
    /// 而其中被打开过的是 0 个。建好之后留住:菜单项里的「标记为已看 / 未看」
    /// 是有状态的,每次重建会把它抹掉。</para>
    /// </summary>
    public static void Attach(Control host, CoreClient core, CardItem item, Action<string>? after = null)
    {
        host.ContextRequested += (_, e) =>
        {
            if (host.ContextMenu is not null) return; // 已经建过了,让它自己弹
            host.ContextMenu = Build(core, item, after);
            /* 这一次的右键要**自己补开一次**:ContextMenu 是在事件处理当中才挂上去的,
               挂之前那一下已经走过「有没有菜单」的判断了。不补的话第一次右键没反应,
               第二次才出来 —— 而用户只会认为右键坏了。 */
            e.Handled = true;
            host.ContextMenu.Open(host);
        };
    }

    /// <summary>
    /// 菜单弹出的入场动效。用户 2026-09-04:「右键菜单没有动效,没有小图标,看着生硬」。
    ///
    /// <para>挂在 <c>Opened</c> 上而不是写进样式表:Avalonia 的 ContextMenu 弹出时
    /// 另开一个 PopupRoot,样式里的 <c>:open</c> 伪类<b>触发不到它</b> ——
    /// 写了不生效,而且不报错。</para>
    ///
    /// <para>90ms + 往下 6px:菜单是**跟手**的东西,再长一点就成了「卡了一下」。
    /// 位移朝下 —— 菜单是从鼠标那一点长出来的。</para>
    /// </summary>
    internal static void AnimateMenu(ContextMenu menu) => Animate(menu);

    private static void Animate(ContextMenu menu)
    {
        menu.Transitions =
        [
            new Avalonia.Animation.DoubleTransition
            {
                Property = Visual.OpacityProperty,
                Duration = TimeSpan.FromMilliseconds(90),
                Easing = new Avalonia.Animation.Easings.CubicEaseOut(),
            },
            new Avalonia.Animation.TransformOperationsTransition
            {
                Property = Visual.RenderTransformProperty,
                Duration = TimeSpan.FromMilliseconds(90),
                Easing = new Avalonia.Animation.Easings.CubicEaseOut(),
            },
        ];
        menu.Opened += (_, _) =>
        {
            menu.Opacity = 0;
            menu.RenderTransform = TransformOperations.Parse("translateY(-6px)");
            // 下一帧再改终值:同一帧里设初值和终值,过渡读不到「变过」,一下就跳到位。
            Dispatcher.UIThread.Post(() =>
            {
                menu.Opacity = 1;
                menu.RenderTransform = TransformOperations.Parse("translateY(0px)");
            }, DispatcherPriority.Render);
        };
    }

    /// <summary>菜单项左边那个小图标。<b>Segoe MDL2</b>,和侧栏、播放页 OSD 同一套字形。</summary>
    private static TextBlock Icon(string glyph) => new()
    {
        Text = glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 13,
        Foreground = new SolidColorBrush(Color.FromRgb(0xa8, 0xb0, 0xc0)),
    };

    /// <summary>MDL2 字形。 集中一处写:散在下面的 new MenuItem 里的话,
    /// 「这一项忘了给图标」会静默漏掉 —— 缺图标和缺一个空格看起来一样。</summary>
    internal static class G
    {
        public const string Play = "\uE768";
        public const string Replay = "\uE72C";   // 从头播放
        public const string Played = "\uE73E";   // 打勾
        public const string Unplayed = "\uE739"; // 空框
        public const string Fav = "\uE734";      // 空心星
        public const string FavOn = "\uE735";    // 实心星
        public const string Block = "\uE711";    // 叉

        /// <summary>自检用:全表。字体里没这个码位时画出来是个空心方框,而它编译绿、运行不报错。</summary>
        public static readonly (string Name, string Glyph)[] All =
        [
            ("播放", Play), ("从头播放", Replay), ("已播放", Played), ("未播放", Unplayed),
            ("收藏", Fav), ("已收藏", FavOn), ("屏蔽", Block),
        ];
    }

    /// <summary>右键菜单能直接播的类型。剧 / 季点「播放」不知道该播哪一集,交给详情页。</summary>
    private static bool Playable(string type) =>
        type is "Movie" or "Episode" or "Video" or "MusicVideo";

    /// <summary>
    /// 建一张卡的右键菜单,按 Emby 自己那份排(用户 2026-09-03:「对齐 Emby,
    /// 方便观看的人标记等等;user / admin 的右键操作我们不做」)。
    ///
    /// <para>对照:播放 / 从头播放 —— 补上了(原来只有一条播放);标记已播放 —— 本来就有;
    /// 收藏 —— 原来是一条不带状态的「添加」,现在先按列表状态摆好再异步问准;
    /// 添加到播放列表 —— 不做,核心层根本没有播放列表,画一条点了没反应的更糟;
    /// 编辑元数据 / 删除 —— 用户点名不做。「从头播放」只在真看过一半时才画。</para>
    /// </summary>
    private static ContextMenu Build(CoreClient core, CardItem item, Action<string>? after)
    {
        var menu = new ContextMenu();
        Animate(menu);
        var items = new List<Control>();

        if (Playable(item.Type))
        {
            var play = new MenuItem
            {
                Header = item.ResumeSecs > 0 ? "继续播放" : "播放",
                Icon = Icon(G.Play),
            };
            play.Click += (_, _) => Play(core, item, item.ResumeSecs);
            items.Add(play);

            if (item.ResumeSecs > 0)
            {
                var fresh = new MenuItem { Header = "从头播放", Icon = Icon(G.Replay) };
                fresh.Click += (_, _) => Play(core, item, 0);
                items.Add(fresh);
            }
            items.Add(new Separator());
        }

        var played = new MenuItem
        {
            Header = item.Played ? "标记为未播放" : "标记为已播放",
            Icon = Icon(item.Played ? G.Unplayed : G.Played),
        };
        played.Click += async (_, _) =>
        {
            var want = played.Header as string == "标记为已播放";
            var ok = await Run(core, "emby.setPlayed", new { item_id = item.Id, played = want }, after);
            Toast.Result(ok, want ? "已标记为已播放" : "已标记为未播放", "标记失败");
            if (!ok) return;
            played.Header = want ? "标记为未播放" : "标记为已播放";
            played.Icon = Icon(want ? G.Unplayed : G.Played);
        };
        items.Add(played);

        /* 收藏和屏蔽跟着 Features 走,而且 card.block 必须和 set.blocked
           **成对**开关 —— 留着屏蔽却没有解除列表,用户屏蔽掉的东西再也找不回来。
           本仓的老规矩:隐藏类功能必须配集中解除列表。 */
        var fav = new MenuItem { Header = "添加到收藏", Tag = false, Icon = Icon(G.Fav) };
        fav.Click += async (_, _) =>
        {
            var want = fav.Tag is not true;
            /* <b>这里就是用户点名的那一处</b>(2026-09-04:「我在首页添加收藏
               就没有 toast 提示,我都不知道有没有加成功」)。菜单点完就关了、
               卡片上什么都不变 —— 成功和「什么都没发生」长得一模一样。 */
            var ok = await Run(core, "emby.setFavorite", new { item_id = item.Id, fav = want }, after);
            Toast.Result(ok, want ? "已添加到收藏" : "已从收藏中移除", "收藏操作失败");
            if (ok) Label(fav, want);
        };
        if (Features.On("card.favorite"))
        {
            items.Add(fav);
            /* 列表命令里<b>没有</b> is_favorite —— 那是 emby.itemDetail 才有的字段
               (给列表加这个字段要动 core 的输出形状,而 5 条差分对账语料录的正是
               那个形状,不能为了一句菜单文案去改黄金实现的对账基准)。
               所以状态在**右键那一下**才去问一次,回来再把文案改准。
               一次右键 = 一次小请求,而且只在用户真的右键时才发。
               没回来之前显示的是「添加到收藏」—— 猜错一次的代价是用户多点一下,
                 而反过来(默认显示「从收藏中移除」)会让人以为自己收藏过了。 */
            _ = SyncFavorite(core, item.Id, fav);
        }

        var block = new MenuItem { Header = "屏蔽这个", Icon = Icon(G.Block) };
        block.Click += async (_, _) =>
        {
            // id 和名字**都要送**:分集靠 series_id 认,跨服的同一部剧 id 不同、
            // 只有名字对得上。少送名字的表现是「换台服务器就又冒出来了」。
            var ok = await Run(core, "emby.setBlocked",
                new { id = item.Id, name = item.Name, blocked = true }, after);
            Toast.Result(ok, "已屏蔽「" + item.Name + "」,可在设置里解除", "屏蔽失败");
        };
        if (Features.On("card.block")) items.Add(block);

        menu.ItemsSource = items;
        return menu;
    }

    /// <summary>收藏那一条的文案 + 状态。<b>状态存在 Tag 里,不从文案反推</b> —— 文案是给人看的。</summary>
    private static void Label(MenuItem fav, bool on)
    {
        fav.Tag = on;
        fav.Header = on ? "从收藏中移除" : "添加到收藏";
        fav.Icon = Icon(on ? G.FavOn : G.Fav);
    }

    /// <summary>问一次这条到底收藏了没有,把菜单文案改准。问不到就保持原样(不报错)。</summary>
    private static async Task SyncFavorite(CoreClient core, string id, MenuItem fav)
    {
        try
        {
            var s = Nav.Session!;
            var d = await core.EmbyItemDetail(new
            {
                s.server, s.token, s.user_id, s.device_id, item_id = id, with_children = false,
            });
            if (d.ValueKind == System.Text.Json.JsonValueKind.Object &&
                d.TryGetProperty("is_favorite", out var v))
                Avalonia.Threading.Dispatcher.UIThread.Post(
                    () => Label(fav, v.ValueKind == System.Text.Json.JsonValueKind.True));
        }
        catch { /* 问不到就让它停在「添加到收藏」——点一下照样是一次真切换 */ }
    }

    /// <summary>
    /// 从右键菜单直接起播。<b>走的是详情页主按钮同一句</b> ——
    /// <c>Nav.Push(new PlayerPage(...))</c>,不另起一条起播路径。
    ///
    /// <para>不带 mediaSourceId / 音轨 / 字幕:右键这条路上用户什么都没选,
    /// 空着就是「交给核心层按正则挑」,和详情页里一次都没动过下拉是同一种状态。</para>
    /// </summary>
    private static void Play(CoreClient core, CardItem item, double resume) =>
        Nav.Push(new PlayerPage(core, item.Id, item.DisplayTitle, resume));

    private static async Task<bool> Run(CoreClient core, string cmd, object args, Action<string>? after)
    {
        try
        {
            var s = Nav.Session!;
            var merged = Merge(s, args);
            await core.CallAsync(cmd, merged);
            after?.Invoke("");
            return true;
        }
        catch (Exception e)
        {
            after?.Invoke(LibraryPage.Advice(e));
            return false;
        }
    }

    /// <summary>
    /// 把会话四件套并进参数。
    ///
    /// <para>迁移期命令层还要显式收 server/token/user_id/device_id;
    /// 匿名类型合不了,所以走字典 —— 字典的键名就是线上字段名,不会被 C# 命名习惯带偏。</para>
    /// </summary>
    private static Dictionary<string, object?> Merge(Sess s, object args)
    {
        var d = new Dictionary<string, object?>
        {
            ["server"] = s.server, ["token"] = s.token,
            ["user_id"] = s.user_id, ["device_id"] = s.device_id,
        };
        foreach (var p in args.GetType().GetProperties()) d[p.Name] = p.GetValue(args);
        return d;
    }
}
