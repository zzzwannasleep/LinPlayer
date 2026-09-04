namespace LinPlayer.Desktop.Views;

/// <summary>
/// 功能开关 —— 哪些东西现在给用户看得见。
///
/// <para>2026-09-02 用户拍板:先把「添加服务器 → 测试链接 → 登录 → 首页 → 媒体库 →
/// 搜索 → 剧/影详情 → 播放」这一条流程做扎实,其余全部下线。此前侧栏 13 个入口,
/// 摊子铺得比流程宽,每一处都只有七八分。只下线入口、不删核心层代码:核心层是
/// 差分对账的基准(<c>check-core.sh</c> 第 5 关),而且下线只改这一处、回来也只改这一处。
/// 打磨好一个就从 Off 里删掉一行 —— 别在别处再写 if。</para>
/// </summary>
public static class Features
{
    /// <summary>现在关着的。key 见各调用点。</summary>
    private static readonly HashSet<string> Off =
    [
        // —— 侧栏入口 ——
        // 「收藏」跟着卡片右键的收藏一起放出来(2026-09-04)。这两个**必须成对** ——
        // 能收藏却没有地方看收藏,和「能屏蔽却没有解除列表」是同一类坑。
        "nav.aggregate",   // 聚合视界(跨服务器)
        "nav.history",     // 观看历史
        // 「下载」2026-09-04 放出来(用户:「侧边栏增加一个下载,方便用户看
        // 已下载的剧集/电影」)。页(DownloadPage)、命令、详情页的下载按钮
        // 本来就全在,唯独侧栏那一条被这张表挡着 —— 又一次「后端领先前端」。
        "nav.ranking",     // 排行榜(弹弹Play / TMDB)
        "nav.calendar",    // 追剧日历(Trakt / Bangumi)
        "nav.plugins",     // 插件市场
        "nav.browse",      // 文件浏览(网盘 / 局域网源)—— 本来就是隐藏的
        "nav.catalog",     // 影视目录(VOD 插件源)—— 本来就是隐藏的

        // —— 设置分组 ——
        "set.preload",     // 预加载
        "set.writeback",   // 跨服务器进度
        "set.blocked",     // 已屏蔽的内容(和 card.block 成对,要关一起关)
        "set.translate",   // 字幕翻译
        "set.whisper",     // 本地转写
        "set.cfspeed",     // CF 线路优选
        "set.transfer",    // 扫码搬配置

        // —— 卡片右键 ——
        // card.block 和 set.blocked **必须成对开关**:留着屏蔽却没有解除列表,
        // 用户屏蔽掉的东西就再也找不回来了(本仓踩过:「隐藏类功能必须配集中解除列表」)。
        /* card.favorite 2026-09-04 放出来:用户要「首页的右键菜单对齐 Emby,
           方便观看的人标记等等操作」,而 Emby 的卡片菜单里「收藏」和「已看」
           是并排的两条 —— 只留已看不算对齐。 */
        "card.block",
    ];

    /// <summary>这个功能现在开着吗。</summary>
    public static bool On(string id) => !Off.Contains(id);
}
