/* 轻量描边图标集(currentColor，无第三方依赖、不用 emoji)。 */
import type { ReactNode } from "react";
type P = { size?: number; className?: string };
const svg = (size: number, className: string | undefined, d: ReactNode) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.7}
    strokeLinecap="round"
    strokeLinejoin="round"
    className={className}
    aria-hidden
  >
    {d}
  </svg>
);

export const IconHome = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M3 10.5 12 3l9 7.5" /><path d="M5 9.5V21h14V9.5" /></>);
export const IconLibrary = ({ size = 20, className }: P) =>
  svg(size, className, <><rect x="3" y="4" width="7" height="16" rx="1.4" /><rect x="12" y="4" width="4" height="16" rx="1.2" /><path d="M18 5.4l3 .8-2.4 14L16 19" /></>);
export const IconHeart = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M12 20s-7-4.6-9.2-9C1.3 7.7 3 5 5.8 5c1.9 0 3.1 1.1 4.2 2.4C11.1 6.1 12.3 5 14.2 5 17 5 18.7 7.7 21.2 11 19 15.4 12 20 12 20Z" />);
export const IconDownload = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M12 3v12" /><path d="m7 11 5 5 5-5" /><path d="M4 21h16" /></>);
export const IconServer = ({ size = 20, className }: P) =>
  svg(size, className, <><rect x="3" y="4" width="18" height="7" rx="1.6" /><rect x="3" y="13" width="18" height="7" rx="1.6" /><path d="M7 7.5h.01M7 16.5h.01" /></>);
export const IconSettings = ({ size = 20, className }: P) =>
  svg(size, className, <><circle cx="12" cy="12" r="3" /><path d="M19.4 15a1.6 1.6 0 0 0 .3 1.8l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.6 1.6 0 0 0-2.7 1.1V21a2 2 0 1 1-4 0v-.2a1.6 1.6 0 0 0-2.7-1.1l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.6 1.6 0 0 0-1.1-2.7H3a2 2 0 1 1 0-4h.2a1.6 1.6 0 0 0 1.1-2.7l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.6 1.6 0 0 0 2.7-1.1V3a2 2 0 1 1 4 0v.2a1.6 1.6 0 0 0 2.7 1.1l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.6 1.6 0 0 0-1.1 2.7V9a1.6 1.6 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.2a1.6 1.6 0 0 0-1.4.9Z" /></>);
export const IconRanking = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M6 20V10" /><path d="M12 20V4" /><path d="M18 20v-7" /></>);
export const IconCalendar = ({ size = 20, className }: P) =>
  svg(size, className, <><rect x="3" y="4.5" width="18" height="16" rx="2" /><path d="M3 9h18M8 3v3M16 3v3" /></>);
export const IconSearch = ({ size = 20, className }: P) =>
  svg(size, className, <><circle cx="11" cy="11" r="7" /><path d="m20 20-3.2-3.2" /></>);
export const IconRefresh = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M21 12a9 9 0 1 1-2.6-6.4" /><path d="M21 4v5h-5" /></>);
/** 仪表盘:测延迟。 */
export const IconGauge = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M4 18a9 9 0 1 1 16 0" /><path d="m12 14 4.2-4.2" /><circle cx="12" cy="14" r="1.4" /></>);
export const IconPlay = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M7 4.5v15l13-7.5-13-7.5Z" fill="currentColor" stroke="none" />);
export const IconChevronRight = ({ size = 20, className }: P) =>
  svg(size, className, <path d="m9 5 7 7-7 7" />);
export const IconChevronLeft = ({ size = 20, className }: P) =>
  svg(size, className, <path d="m15 5-7 7 7 7" />);
export const IconChevronDown = ({ size = 20, className }: P) =>
  svg(size, className, <path d="m6 9 6 6 6-6" />);
export const IconUnfold = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="m8 9 4-4 4 4" /><path d="m16 15-4 4-4-4" /></>);
export const IconClose = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="m6 6 12 12" /><path d="m18 6-12 12" /></>);
export const IconSun = ({ size = 20, className }: P) =>
  svg(size, className, <><circle cx="12" cy="12" r="4" /><path d="M12 2v2M12 20v2M4.9 4.9l1.4 1.4M17.7 17.7l1.4 1.4M2 12h2M20 12h2M4.9 19.1l1.4-1.4M17.7 6.3l1.4-1.4" /></>);
export const IconMoon = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M21 12.8A8.5 8.5 0 1 1 11.2 3a6.6 6.6 0 0 0 9.8 9.8Z" />);
export const IconCloud = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M6.5 19a4.5 4.5 0 0 1-.5-8.97A6 6 0 0 1 17.7 9.4 4.3 4.3 0 0 1 17.5 19H6.5Z" />);
export const IconInfo = ({ size = 20, className }: P) =>
  svg(size, className, <><circle cx="12" cy="12" r="9" /><path d="M12 11v5M12 7.5h.01" /></>);
export const IconPlus = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M12 5v14M5 12h14" />);
export const IconPause = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M8 5v14M16 5v14" /></>);
export const IconTrash = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M4 7h16M9 7V5h6v2M6 7l1 13h10l1-13" /></>);
export const IconFolder = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M3 6.5A1.5 1.5 0 0 1 4.5 5h4l2 2.5H19a1.5 1.5 0 0 1 1.5 1.5v8.5A1.5 1.5 0 0 1 19 19H4.5A1.5 1.5 0 0 1 3 17.5Z" />);
export const IconFile = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M6 3h8l4 4v14H6Z" /><path d="M14 3v4h4" /></>);
export const IconPrev = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M18 5.5v13L9 12l9-6.5ZM7 5v14" fill="currentColor" stroke="currentColor" strokeWidth={1.4} strokeLinejoin="round" />);
export const IconNext = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M6 5.5v13L15 12 6 5.5ZM17 5v14" fill="currentColor" stroke="currentColor" strokeWidth={1.4} strokeLinejoin="round" />);
export const IconRewind = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M11 5.5v13L2.5 12 11 5.5Z" fill="currentColor" stroke="none" /><path d="M21 5.5v13L12.5 12 21 5.5Z" fill="currentColor" stroke="none" /></>);
export const IconForward = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M3 5.5v13L11.5 12 3 5.5Z" fill="currentColor" stroke="none" /><path d="M13 5.5v13L21.5 12 13 5.5Z" fill="currentColor" stroke="none" /></>);
export const IconFullscreen = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" />);
/* 播放页自绘窗口控制(最小化 / 窗口化·还原 / 全屏·退出全屏)。 */
export const IconFullscreenExit = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M9 4v5H4M15 4v5h5M9 20v-5H4M15 20v-5h5" />);
export const IconMinimize = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M5 12h14" />);
export const IconWindow = ({ size = 20, className }: P) =>
  svg(size, className, <rect x="4.5" y="5.5" width="15" height="13" rx="1.6" />);
export const IconRestore = ({ size = 20, className }: P) =>
  svg(size, className, <><rect x="3.5" y="8.5" width="12" height="11" rx="1.5" /><path d="M8 8.5V6a1.5 1.5 0 0 1 1.5-1.5H19A1.5 1.5 0 0 1 20.5 6v9.5A1.5 1.5 0 0 1 19 17h-3.5" /></>);
export const IconVolume = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M4 9v6h3l5 4V5L7 9H4Z" /><path d="M16 8.5a4 4 0 0 1 0 7" /></>);
export const IconList = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M8 6h12M8 12h12M8 18h12M4 6h.01M4 12h.01M4 18h.01" />);
/** 侧栏折叠汉堡(草稿:「侧栏可折叠为窄图标条(顶栏汉堡切换)」)。 */
export const IconMenu = ({ size = 20, className }: P) =>
  svg(size, className, <path d="M4 7h16M4 12h16M4 17h16" />);
/** 已看/未看勾(海报右键菜单的「标记已看」)。 */
export const IconCheck = ({ size = 20, className }: P) =>
  svg(size, className, <path d="m4 12.5 5 5L20 6.5" />);
export const IconPlugin = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M9 3v3.5a1.5 1.5 0 0 1-3 0V3" /><path d="M18 3v3.5a1.5 1.5 0 0 1-3 0V3" /><rect x="4" y="6.5" width="16" height="8" rx="2" /><path d="M12 14.5V21" /></>);
export const IconShield = ({ size = 20, className }: P) =>
  svg(size, className, <><path d="M12 3l7 3v5.5c0 4.4-2.9 8.2-7 9.5-4.1-1.3-7-5.1-7-9.5V6l7-3z" /><path d="m9 12 2.2 2.2L15.5 10" /></>);
export const IconKeyboard = ({ size = 20, className }: P) =>
  svg(size, className, <><rect x="2.5" y="6" width="19" height="12" rx="2" /><path d="M6.5 9.5h.01M10 9.5h.01M13.5 9.5h.01M17 9.5h.01M6.5 12.8h.01M10 12.8h.01M13.5 12.8h.01M17 12.8h.01M8.5 15.6h7" /></>);
