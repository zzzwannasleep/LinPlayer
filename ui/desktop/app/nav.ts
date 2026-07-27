import type { ReactElement } from "react";
import {
  IconHome,
  IconLibrary,
  IconHeart,
  IconDownload,
  IconRanking,
  IconCalendar,
  IconServer,
  IconSettings,
  IconPlugin,
} from "./icons";

/** 路由 id。netdisk / anirss / addserver / pluginview 是内部路由(不进侧栏):
 *  netdisk·anirss 登录对应源后进入;pluginview 由侧栏的插件入口或插件详情页打开。 */
export type PageId =
  | "home"
  | "library"
  | "favorites"
  | "downloads"
  | "rankings"
  | "servers"
  | "plugins"
  | "settings"
  | "addserver"
  | "netdisk"
  | "anirss"
  | "calendar"
  | "pluginview";

export type NavItem = {
  id: PageId;
  label: string;
  icon: (p: { size?: number; className?: string }) => ReactElement;
};

/** 侧栏主导航(草稿序):首页 / 媒体库 / 收藏 / 下载 / 排行榜 / 追剧日历。 */
export const NAV: NavItem[] = [
  { id: "home", label: "首页", icon: IconHome },
  { id: "library", label: "媒体库", icon: IconLibrary },
  { id: "favorites", label: "收藏", icon: IconHeart },
  { id: "downloads", label: "下载", icon: IconDownload },
  { id: "rankings", label: "排行榜", icon: IconRanking },
  { id: "calendar", label: "追剧日历", icon: IconCalendar },
];

/** 侧栏底部(管理区):服务器 / 插件 / 设置。
 *  插件从设置里的一个小面板提到这里 —— 它现在是市场 + 已装 + 源三个页签,
 *  塞在设置的第 N 项里等于没人找得到。 */
export const NAV_FOOT: NavItem[] = [
  { id: "servers", label: "服务器", icon: IconServer },
  { id: "plugins", label: "插件", icon: IconPlugin },
  { id: "settings", label: "设置", icon: IconSettings },
];

/** 快捷键命令 id → 页面。命令的键位/中文名在 `lib/shortcuts.ts` 的 COMMANDS 里,
 *  这张表只管「按下之后去哪一页」。**长度和顺序必须固定**(Shell 里在循环中调 hook)。 */
export const NAV_COMMANDS: [string, PageId][] = [
  ["nav-home", "home"],
  ["nav-library", "library"],
  ["nav-favorites", "favorites"],
  ["nav-downloads", "downloads"],
  ["nav-rankings", "rankings"],
  ["nav-calendar", "calendar"],
  ["nav-servers", "servers"],
  ["nav-plugins", "plugins"],
  ["nav-settings", "settings"],
];
