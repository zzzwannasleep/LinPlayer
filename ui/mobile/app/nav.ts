import type { ReactElement } from "react";
import { IconHome, IconSearch, IconSettings } from "./icons";

/** 一个页面 id。
 *
 *  分三类,加新页时想清楚它属于哪一类:
 *  - **Tab 页**(home/search/settings):底栏三个,各自持有一条独立的栈
 *  - **栈内页**:从某个 Tab 下钻进去的(library/detail/favorites/...),压在那条栈上
 *  - **全屏页**(player):盖掉底栏和顶栏 */
export type PageId =
  | "home"
  | "search"
  | "settings"
  // —— 首页 chip 行进入的
  | "library"
  | "favorites"
  | "downloads"
  | "rankings"
  | "calendar"
  // —— 设置页进入的
  | "servers"
  | "addserver"
  | "netdisk"
  | "plugins"
  | "anirss"
  // —— 内容
  | "detail"
  | "player";

export type TabId = "home" | "search" | "settings";

export type TabItem = {
  id: TabId;
  label: string;
  icon: (p: { size?: number }) => ReactElement;
};

/* ============================================================
   底栏只有三个 Tab(用户 2026-07-26 定)。

   PC 端侧栏有 9 个入口,这里只留 3 个。剩下 6 个的去处:
     媒体库·收藏·下载·排行榜·追剧日历 → 首页顶部的横滑 chip 行
     服务器·插件·网盘·Ani-RSS        → 设置页的分组项

   ★ 为什么不是 5 个:底栏是拇指最贵的位置,只配给「随时想去」的三件事。
     5 个图标平分屏宽后单个可点区会被压到 48dp 以下(Material / WCAG 的下限),
     而 chip 行可以横滑、能放任意多个、还带得下文字 —— 到达反而更快。
   ============================================================ */
export const TABS: TabItem[] = [
  { id: "home", label: "首页", icon: IconHome },
  { id: "search", label: "搜索", icon: IconSearch },
  { id: "settings", label: "设置", icon: IconSettings },
];

/** 盖掉底栏 + 顶栏的页。**不是**「全屏播放」的意思 —— 是「这一页自己管整块屏」。 */
export const FULLSCREEN_PAGES = new Set<PageId>(["player"]);

/** 首页顶部的横滑 chip。顺序照 PC 侧栏(ui/desktop/app/nav.ts),用户已经习惯了那个序。 */
export const HOME_CHIPS: { id: PageId; label: string }[] = [
  { id: "library", label: "媒体库" },
  { id: "favorites", label: "收藏" },
  { id: "downloads", label: "下载" },
  { id: "rankings", label: "排行榜" },
  { id: "calendar", label: "追剧日历" },
];
