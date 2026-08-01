/** 一个页面 id。
 *
 *  分三类,加新页时想清楚它属于哪一类:
 *  - **Tab 页**(home/aggregate/servers):底栏三个,各自持有一条独立的栈
 *  - **栈内页**:从某个 Tab 下钻进去的(library/detail/lines/...),压在那条栈上
 *  - **全屏页**(player):盖掉底栏和顶栏 */
export type PageId =
  // —— 三个 Tab 的根
  | "home"
  | "aggregate"
  | "servers"
  // —— 首页 chip 行进入的
  | "library"
  | "favorites"
  | "downloads"
  | "rankings"
  | "calendar"
  | "search"
  // —— 设置族
  | "settings"
  | "settingsSub"
  | "addServer"
  | "lines"
  | "icon"
  | "netdisk"
  | "plugins"
  | "anirss"
  // —— 内容
  | "detail"
  | "episode"
  | "person"
  | "player"
  // —— 聚合视界里的快捷入口
  | "resume";

export type TabId = "home" | "aggregate" | "servers";

export type TabItem = {
  id: TabId;
  label: string;
  /** 未选中时的图标名 */
  icon: string;
  /** 选中时的图标名(实心版)。同一个名字就是不换。 */
  iconOn: string;
};

/* ============================================================
   底栏三个 Tab(2026-07-28 改)。

   上一版是 首页 / 搜索 / 设置。这一版换成:

     首页  │  聚合视界  │  服务器

   ★ 「搜索」并进「聚合视界」—— 聚合搜索本来就是"跨源找东西",和"跨源看有什么"
     是同一件事的两面,拆成两个 Tab 是把一件事切两半。搜索条放在聚合视界顶部,
     少一次点击就到。
   ★ 「设置」从底栏挪到**首页右上角** —— 它是低频的配置入口,不配占拇指最贵的位置;
     「服务器」才是高频(多源用户天天切)。

   ★ 为什么不是 5 个:5 个图标平分屏宽后单个可点区会被压到 48dp 以下
     (Material / WCAG 的下限)。首页顶部的 chip 行可以横滑、能放任意多个、
     还带得下文字 —— 到达反而更快。
   ============================================================ */
export const TABS: TabItem[] = [
  { id: "home", label: "首页", icon: "home", iconOn: "homeOn" },
  { id: "aggregate", label: "聚合视界", icon: "grid", iconOn: "grid" },
  { id: "servers", label: "服务器", icon: "server", iconOn: "server" },
];

/** 每个 Tab 的栈底页。改 TABS 必须同步改这里 —— 漏了的表现是切过去一片空白。 */
export const TAB_ROOT: Record<TabId, PageId> = {
  home: "home",
  aggregate: "aggregate",
  servers: "servers",
};

/** 盖掉底栏 + 顶栏的页。**不是**「全屏播放」的意思 —— 是「这一页自己管整块屏」。 */
export const FULLSCREEN_PAGES = new Set<PageId>(["player"]);

/** 首页顶部的横滑 chip。顺序照 PC 侧栏(ui/desktop/app/nav.ts),用户已经习惯了那个序。 */
export const HOME_CHIPS: { id: PageId; label: string; icon: string }[] = [
  { id: "library", label: "媒体库", icon: "grid" },
  { id: "favorites", label: "收藏", icon: "heart" },
  { id: "downloads", label: "下载", icon: "download" },
  { id: "rankings", label: "排行榜", icon: "trophy" },
  { id: "calendar", label: "追剧日历", icon: "calendar" },
];

/** 页面标题兜底。页面自己给了 title 就用页面的。 */
export const PAGE_LABELS: Partial<Record<PageId, string>> = {
  library: "媒体库",
  favorites: "收藏",
  downloads: "下载",
  rankings: "排行榜",
  calendar: "追剧日历",
  search: "搜索",
  settings: "设置",
  servers: "服务器",
  addServer: "添加服务器",
  lines: "服务器线路",
  icon: "更换图标",
  netdisk: "网盘",
  plugins: "插件",
  anirss: "Ani-RSS 订阅",
  detail: "详情",
  person: "演职员",
  aggregate: "聚合视界",
  resume: "继续观看",
};
