namespace LinPlayer.Desktop.Views;

/// <summary>
/// 功能开关 —— **哪些东西现在给用户看得见**。
///
/// <para>★★ 2026-09-02 用户拍板:先把一条完整的基础流程做扎实,其余全部下线。</para>
///
/// <code>
/// 添加服务器 → 测试链接 → 登录 → 首页 → 媒体库 → 搜索 → 剧/影详情 → 集详情 → 播放
/// </code>
///
/// <para>原话:「整个流程打通了、做好了、UI 做好了、动效做流畅了,
/// 才是真的做好一个基础的 Emby 播放器」。此前侧栏 13 个入口、设置 12 组 ——
/// 摊子铺得比流程宽,每一处都只有七八分。</para>
///
/// <para>★ <b>只下线入口,不删核心层代码</b>。三个理由:
/// ① 核心层是差分对账的基准(<c>check-core.sh</c> 第 5 关),删了就没法和黄金实现对账;
/// ② 用户说的是「慢慢打磨」,不是「不要了」;
/// ③ 下线只改这一处,回来也只改这一处。</para>
///
/// <para>★★ <b>打磨好一个,就从 Off 里删掉一行</b> —— 这是这张表存在的全部意义。
/// 别在别处再写 if:散在各页里的开关,过两周就没人知道哪些是关着的。</para>
/// </summary>
public static class Features
{
    /// <summary>现在关着的。key 见各调用点。</summary>
    private static readonly HashSet<string> Off =
    [
        // —— 侧栏入口 ——
        "nav.favorites",   // 收藏
        "nav.aggregate",   // 聚合视界(跨服务器)
        "nav.history",     // 观看历史
        "nav.download",    // 下载
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
        // ★ card.block 和 set.blocked **必须成对开关**:留着屏蔽却没有解除列表,
        //   用户屏蔽掉的东西就再也找不回来了(本仓踩过:「隐藏类功能必须配集中解除列表」)。
        "card.favorite",
        "card.block",
    ];

    /// <summary>这个功能现在开着吗。</summary>
    public static bool On(string id) => !Off.Contains(id);
}
