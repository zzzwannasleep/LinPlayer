/* 图标 —— **不重画一套**,直接借 PC 端那份。
 *
 * `ui/desktop/app/icons.tsx` 是一组纯 SVG 组件:只吃 size/className,
 * 用 currentColor,不带任何 CSS 依赖、不引第三方库。这种东西没有"PC 版"和
 * "手机版"之分,重画一份的唯一结果是两套图标慢慢长歪。
 *
 * ★ 那它为什么不在 `ui/shared/`?
 *   因为它现在的位置就在 desktop 下,而 `ui/desktop/pages/sources/sourceForms`
 *   (三端共用的数据源表单)也从那儿取图标 —— 也就是说这份文件**事实上已经是共用层**,
 *   只是还没搬家。真要搬得连着 sourceForms 一起动,那是另一件事。
 *   这个文件就是那道缝:全端只有这里跨目录 import,将来 icons 搬到 ui/shared
 *   只需要改本文件一行。页面一律从 `app/icons` 取,别自己去 ../../desktop 摸。
 */
export {
  IconHome,
  IconSearch,
  IconSettings,
  IconLibrary,
  IconHeart,
  IconDownload,
  IconRanking,
  IconCalendar,
  IconServer,
  IconPlugin,
  IconCloud,
  IconPlay,
  IconPause,
  IconPlus,
  IconCheck,
  IconClose,
  IconChevronRight,
  IconChevronLeft,
  IconChevronDown,
  IconRefresh,
  IconTrash,
  IconInfo,
  IconList,
  IconMenu,
  IconRewind,
  IconForward,
  IconVolume,
  IconFolder,
  IconFile,
} from "../../desktop/app/icons";
