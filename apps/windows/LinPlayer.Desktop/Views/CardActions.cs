using Avalonia.Controls;
using LinPlayer.Core;
using LinPlayer.Desktop.Core;

namespace LinPlayer.Desktop.Views;

/// <summary>
/// 卡片动作:标记已看 / 收藏 / 屏蔽。
///
/// <para>★★ <b>一处实现,所有卡片共用</b>。这几个动作在首页、媒体库网格、搜索、
/// 收藏、详情页的分集里都要有 —— 各处各写一份的表现是「某个入口右键少一项」,
/// 而少的那一项永远是最后加的那个。旧栈这块叫 <c>useCardActions</c>,同一个道理。</para>
///
/// <para>★ 参数名照核心层的原样:收藏是 <c>fav</c> 不是 <c>favorite</c>,
/// 屏蔽是 <c>id</c>/<c>blocked</c> 不是 <c>item_id</c>。写错了**不报错**,
/// 布尔默认成 false —— 表现是「点收藏反而取消了收藏」。</para>
/// </summary>
public static class CardActions
{
    /// <summary>
    /// 给一张卡挂右键菜单。<paramref name="after"/> 在动作成功后调,用来刷新界面。
    ///
    /// <para>★★ <b>菜单是右键那一下才建的,不是造卡时就建</b>。
    /// 原来每张卡当场 new 一个 <see cref="ContextMenu"/> 加两三个 MenuItem ——
    /// 一个 ContextMenu 是个弹出宿主,不是一个轻量对象。
    /// 一屏 140 张卡就是 140 个弹出宿主 + 200 多个菜单项,
    /// 而其中<b>被打开过的是 0 个</b>。用户右键一张卡之前,这些东西一件都不需要存在。</para>
    ///
    /// <para>★ 建好之后留住(<c>host.ContextMenu</c>),第二次右键不再重建 ——
    /// 菜单项里的「标记为已看 / 未看」是有状态的,每次重建会把它复位。</para>
    /// </summary>
    public static void Attach(Control host, CoreClient core, CardItem item, Action<string>? after = null)
    {
        host.ContextRequested += (_, e) =>
        {
            if (host.ContextMenu is not null) return; // 已经建过了,让它自己弹
            host.ContextMenu = Build(core, item, after);
            /* ★ 这一次的右键要**自己补开一次**:ContextMenu 是在事件处理当中才挂上去的,
               挂之前那一下已经走过「有没有菜单」的判断了。不补的话第一次右键没反应,
               第二次才出来 —— 而用户只会认为右键坏了。 */
            e.Handled = true;
            host.ContextMenu.Open(host);
        };
    }

    private static ContextMenu Build(CoreClient core, CardItem item, Action<string>? after)
    {
        var menu = new ContextMenu();
        var items = new List<Control>();

        var played = new MenuItem { Header = item.Played ? "标记为未看" : "标记为已看" };
        played.Click += async (_, _) =>
        {
            var want = !item.Played;
            if (await Run(core, "emby.setPlayed", new { item_id = item.Id, played = want }, after))
                played.Header = want ? "标记为未看" : "标记为已看";
        };
        items.Add(played);

        /* ★★ 收藏和屏蔽跟着 Features 走,而且 card.block 必须和 set.blocked
           **成对**开关 —— 留着屏蔽却没有解除列表,用户屏蔽掉的东西再也找不回来。
           本仓的老规矩:隐藏类功能必须配集中解除列表。 */
        var fav = new MenuItem { Header = "收藏 / 取消收藏" };
        fav.Click += async (_, _) =>
        {
            // 列表里没有 is_favorite 字段,所以这里做不到「已收藏就显示取消」——
            // 一次点击就是一次切换,详情页才有准确的状态
            await Run(core, "emby.setFavorite", new { item_id = item.Id, fav = true }, after);
        };
        if (Features.On("card.favorite")) items.Add(fav);

        var block = new MenuItem { Header = "屏蔽这个" };
        block.Click += async (_, _) =>
        {
            // ★ id 和名字**都要送**:分集靠 series_id 认,跨服的同一部剧 id 不同、
            //   只有名字对得上。少送名字的表现是「换台服务器就又冒出来了」。
            await Run(core, "emby.setBlocked", new { id = item.Id, name = item.Name, blocked = true }, after);
        };
        if (Features.On("card.block")) items.Add(block);

        menu.ItemsSource = items;
        return menu;
    }

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
