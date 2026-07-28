/* 图标 —— 55 个内联 SVG,路径逐字来自 `docs/mobile-drafts/icons.js`。
 *
 * ## 为什么不再「从 ui/desktop/app/icons 再导出」
 * 上一版这个文件只有 44 行,内容是 `export { IconHome, ... } from "../../desktop/app/icons"`,
 * 理由写着「同一组纯 SVG 没有 PC 版和手机版之分,重画一份只会两套慢慢长歪」。
 * 那条理由在**图标语言没变**的前提下成立,现在前提没了:
 *   - **覆盖不够**:桌面那份导出 29 个,草稿版式要 55 个 —— 拖拽手柄 / 铅笔 / 钥匙 /
 *     地球 / 同步 / 弹幕 / 锁 / 奖杯 / 二维码 / 相机 / 分段筛选…… 桌面一个都没有。
 *     缺的那 26 个不是"顺手补两个"能糊过去的量。
 *   - **同名不同形**:草稿的 play 是**实心三角**(压在封面上要够醒目),桌面那个是描边;
 *     stroke-width 也不一样(1.9 vs 桌面的 1.6)—— 手机上图标更小、要更粗才看得清。
 * 也就是说这两套服务的是两个已经分叉的版式。硬共用的结果不是"不长歪",
 * 是**手机端被桌面的视觉参数绑住**。所以这里落草稿那一套,并把差异写在这儿。
 *
 * ★ 唯一还跨目录取图标的地方是 `ui/desktop/pages/sources/sourceForms`
 *   (三端共用的数据源表单,自己 import 自己那份)—— 那是它的内部事,不归这里管。
 *
 * ## 两种取用形态
 *   `<Icon n="play" size={20} />`  —— JSX 里用
 *   `iconNode("trash", 18)`        —— 给 motion.ts 的 menu()/toast() 这类**命令式**层用,
 *                                     它们在 React 之外,只吃真 DOM 节点
 */

type Opt = { fill?: boolean; w?: number };

/** 每个图标 = 内部路径串 + 描边/填充参数。路径逐字照搬草稿,别顺手"优化"。 */
const P: Record<string, [string, Opt?]> = {
  home: [`<path d="M3 10.5 12 3l9 7.5"/><path d="M5.5 9.5V20a1 1 0 0 0 1 1H10v-6h4v6h3.5a1 1 0 0 0 1-1V9.5"/>`],
  homeOn: [`<path d="M3 10.5 12 3l9 7.5v9.5a1 1 0 0 1-1 1h-5v-6h-4v6H4a1 1 0 0 1-1-1z"/>`, { fill: true }],
  search: [`<circle cx="11" cy="11" r="7"/><path d="m20 20-3.5-3.5"/>`],
  settings: [
    `<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1a2 2 0 1 1-2.8 2.8l-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21a2 2 0 1 1-4 0v-.1A1.7 1.7 0 0 0 8.9 19a1.7 1.7 0 0 0-1.9.3l-.1.1a2 2 0 1 1-2.8-2.8l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3a2 2 0 1 1 0-4h.1A1.7 1.7 0 0 0 5 8.9a1.7 1.7 0 0 0-.3-1.9l-.1-.1a2 2 0 1 1 2.8-2.8l.1.1a1.7 1.7 0 0 0 1.9.3H9.6a1.7 1.7 0 0 0 1-1.5V3a2 2 0 1 1 4 0v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1a2 2 0 1 1 2.8 2.8l-.1.1a1.7 1.7 0 0 0-.3 1.9v.1a1.7 1.7 0 0 0 1.5 1H21a2 2 0 1 1 0 4h-.1a1.7 1.7 0 0 0-1.5 1z"/>`,
  ],
  back: [`<path d="m15 5-7 7 7 7"/>`, { w: 2.1 }],
  play: [`<path d="M7 4.5 19.5 12 7 19.5z"/>`, { fill: true }],
  pause: [
    `<rect x="6.5" y="4.5" width="4" height="15" rx="1.2"/><rect x="13.5" y="4.5" width="4" height="15" rx="1.2"/>`,
    { fill: true },
  ],
  heart: [`<path d="M12 20s-7.5-4.6-7.5-9.6A4.4 4.4 0 0 1 12 7.6a4.4 4.4 0 0 1 7.5 2.8C19.5 15.4 12 20 12 20z"/>`],
  heartOn: [
    `<path d="M12 20s-7.5-4.6-7.5-9.6A4.4 4.4 0 0 1 12 7.6a4.4 4.4 0 0 1 7.5 2.8C19.5 15.4 12 20 12 20z"/>`,
    { fill: true },
  ],
  check: [`<path d="m5 12.5 4.5 4.5L19 7"/>`, { w: 2.3 }],
  download: [`<path d="M12 3v12"/><path d="m7 11 5 5 5-5"/><path d="M4 20h16"/>`],
  more: [
    `<circle cx="12" cy="5" r="1.6" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none"/><circle cx="12" cy="19" r="1.6" fill="currentColor" stroke="none"/>`,
  ],
  chevR: [`<path d="m9 5 7 7-7 7"/>`],
  chevD: [`<path d="m5 9 7 7 7-7"/>`],
  close: [`<path d="M6 6l12 12M18 6 6 18"/>`, { w: 2.1 }],
  list: [
    `<path d="M8 6h13M8 12h13M8 18h13"/><circle cx="3.6" cy="6" r="1.1" fill="currentColor" stroke="none"/><circle cx="3.6" cy="12" r="1.1" fill="currentColor" stroke="none"/><circle cx="3.6" cy="18" r="1.1" fill="currentColor" stroke="none"/>`,
  ],
  grid: [
    `<rect x="3.5" y="3.5" width="7" height="7" rx="1.6"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.6"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.6"/><rect x="13.5" y="13.5" width="7" height="7" rx="1.6"/>`,
  ],
  filter: [`<path d="M3 6h18M6.5 12h11M10 18h4"/>`, { w: 2 }],
  sort: [`<path d="M7 4v16M7 20l-3.2-3.2M7 20l3.2-3.2M17 20V4M17 4l-3.2 3.2M17 4l3.2 3.2"/>`],
  rewind: [`<path d="M11 6 4 12l7 6z"/><path d="M20 6l-7 6 7 6z"/>`, { fill: true }],
  forward: [`<path d="m13 6 7 6-7 6z"/><path d="M4 6l7 6-7 6z"/>`, { fill: true }],
  sub: [`<rect x="2.5" y="5" width="19" height="14" rx="2.6"/><path d="M6.5 14.5h4M13.5 14.5h4M6.5 10.5h11"/>`],
  audio: [`<path d="M4 9.5v5h3.5l4.5 4V5.5l-4.5 4z"/><path d="M15.5 9.2a4 4 0 0 1 0 5.6M18.4 6.6a8 8 0 0 1 0 10.8"/>`],
  version: [`<rect x="3" y="4" width="18" height="12" rx="2.2"/><path d="M8 20h8M12 16v4"/>`],
  line: [
    `<path d="M12 20v-5"/><path d="M4.5 9a10 10 0 0 1 15 0"/><path d="M7.5 12.5a6 6 0 0 1 9 0"/><circle cx="12" cy="17.5" r="2" fill="currentColor" stroke="none"/>`,
  ],
  sparkle: [`<path d="M12 3.5 13.8 9l5.5 1.8-5.5 1.8L12 18l-1.8-5.4L4.7 10.8 10.2 9z"/><path d="M18.5 3v3M20 4.5h-3"/>`],
  danmaku: [`<rect x="2.5" y="4.5" width="19" height="15" rx="2.6"/><path d="M6 9h7M6 12.5h4M14 12.5h4M6 16h9"/>`],
  lock: [`<rect x="4.5" y="10.5" width="15" height="10" rx="2.4"/><path d="M8 10.5V7.6a4 4 0 0 1 8 0v2.9"/>`],
  unlock: [`<rect x="4.5" y="10.5" width="15" height="10" rx="2.4"/><path d="M8 10.5V7.6a4 4 0 0 1 7.6-1.8"/>`],
  server: [
    `<rect x="3" y="4" width="18" height="7" rx="2"/><rect x="3" y="13" width="18" height="7" rx="2"/><circle cx="7" cy="7.5" r="1.1" fill="currentColor" stroke="none"/><circle cx="7" cy="16.5" r="1.1" fill="currentColor" stroke="none"/>`,
  ],
  cloud: [`<path d="M7 18h10a4 4 0 0 0 .6-7.96A6 6 0 0 0 6.1 11 3.5 3.5 0 0 0 7 18z"/>`],
  plugin: [`<path d="M9 3v4M15 3v4M5.5 7h13v6a6.5 6.5 0 0 1-13 0z"/><path d="M12 19.5V21"/>`],
  rss: [`<path d="M5 11a8 8 0 0 1 8 8M5 5a14 14 0 0 1 14 14"/><circle cx="5.5" cy="18.5" r="1.8" fill="currentColor" stroke="none"/>`],
  calendar: [`<rect x="3.5" y="5" width="17" height="16" rx="2.4"/><path d="M3.5 10h17M8 3v4M16 3v4"/>`],
  trophy: [
    `<path d="M7 4h10v5a5 5 0 0 1-10 0z"/><path d="M7 6H4.5v1.5A3.5 3.5 0 0 0 8 11M17 6h2.5v1.5A3.5 3.5 0 0 1 16 11"/><path d="M12 14v3M8.5 20h7"/>`,
  ],
  folder: [`<path d="M3.5 7.5A2 2 0 0 1 5.5 5.5h3.6l2 2.4h7.4a2 2 0 0 1 2 2v8.6a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/>`],
  file: [`<path d="M13.5 3.5H7a2 2 0 0 0-2 2v13a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2V9z"/><path d="M13.5 3.5V9H19"/>`],
  trash: [`<path d="M4 6.5h16M9.5 6.5V4.5h5v2M6.5 6.5l1 13.5h9l1-13.5"/>`],
  pause2: [`<path d="M9 5v14M15 5v14"/>`, { w: 2.2 }],
  qr: [
    `<rect x="3.5" y="3.5" width="7" height="7" rx="1.4"/><rect x="13.5" y="3.5" width="7" height="7" rx="1.4"/><rect x="3.5" y="13.5" width="7" height="7" rx="1.4"/><path d="M13.5 13.5h3v3h-3zM20.5 13.5v3M17.5 20.5h3M13.5 20.5h1"/>`,
  ],
  plus: [`<path d="M12 5v14M5 12h14"/>`, { w: 2.1 }],
  minus: [`<path d="M5 12h14"/>`, { w: 2.1 }],
  camera: [
    `<path d="M3.5 8.5a2 2 0 0 1 2-2h1.9l1.3-2h6.6l1.3 2h1.9a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"/><circle cx="12" cy="12.5" r="3.4"/>`,
  ],
  refresh: [`<path d="M20 11a8 8 0 1 0-.6 4"/><path d="M20 5v6h-6"/>`],
  inbox: [
    `<path d="M3.5 13.5h4l1.5 3h6l1.5-3h4"/><path d="M5.6 4.8 3.5 13.5v4a2 2 0 0 0 2 2h13a2 2 0 0 0 2-2v-4L18.4 4.8a2 2 0 0 0-1.9-1.3h-9a2 2 0 0 0-1.9 1.3z"/>`,
  ],
  star: [`<path d="m12 4 2.4 5 5.6.8-4 3.9 1 5.5-5-2.6-5 2.6 1-5.5-4-3.9 5.6-.8z"/>`],
  shield: [`<path d="M12 3.5 5 6v6c0 4.2 2.9 7.6 7 8.5 4.1-.9 7-4.3 7-8.5V6z"/>`],
  info: [`<circle cx="12" cy="12" r="8.5"/><path d="M12 11v5.5"/><circle cx="12" cy="7.9" r="1" fill="currentColor" stroke="none"/>`],
  grip: [`<path d="M8 6h.01M8 12h.01M8 18h.01M16 6h.01M16 12h.01M16 18h.01"/>`, { w: 2.6 }],
  pencil: [`<path d="M4 20h4L19.5 8.5a2.1 2.1 0 0 0-3-3L5 17z"/><path d="M14.5 6.5l3 3"/>`],
  image: [
    `<rect x="3.5" y="4.5" width="17" height="15" rx="2.4"/><circle cx="9" cy="10" r="1.8"/><path d="m4.5 17 4.2-4.2 3.3 3.3 3-3 4.5 4.4"/>`,
  ],
  key: [`<circle cx="8" cy="12" r="4"/><path d="M12 12h9M18 12v3.2M15.5 12v2.4"/>`],
  globe: [`<circle cx="12" cy="12" r="8.5"/><path d="M3.5 12h17"/><path d="M12 3.5a13 13 0 0 1 0 17 13 13 0 0 1 0-17z"/>`],
  sync: [
    `<path d="M4 10a8 8 0 0 1 13.7-4.4L20 8"/><path d="M20 4v4h-4"/><path d="M20 14a8 8 0 0 1-13.7 4.4L4 16"/><path d="M4 20v-4h4"/>`,
  ],
};

export type IconName = keyof typeof P;

const attrs = (o?: Opt) => ({
  fill: o?.fill ? "currentColor" : "none",
  stroke: o?.fill ? "none" : "currentColor",
  strokeWidth: o?.w ?? 1.9,
});

/** JSX 用。名字打错时回落 info,**不返回 null** —— 一个空洞比一个错图标更难查。 */
export function Icon({ n, size = 22, className }: { n: string; size?: number; className?: string }) {
  const [d, o] = P[n] ?? P.info;
  return (
    <svg
      width={size}
      height={size}
      viewBox="0 0 24 24"
      strokeLinecap="round"
      strokeLinejoin="round"
      className={className}
      {...attrs(o)}
      /* 路径是本文件里的字符串常量,不掺任何外部数据 —— 这是 SVG 图标唯一
         不用手写 55 遍 JSX 的办法。别把用户数据接到这里。 */
      dangerouslySetInnerHTML={{ __html: d }}
    />
  );
}

/** 给 React 之外的命令式层(motion.ts 的 menu / toast)用:直接吐一个 DOM 节点。 */
export function iconNode(n: string, size = 22, cls = ""): HTMLElement {
  const [d, o] = P[n] ?? P.info;
  const a = attrs(o);
  const s = document.createElement("span");
  s.style.display = "inline-grid";
  s.style.placeItems = "center";
  s.innerHTML = `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="${a.fill}"
    stroke="${a.stroke}" stroke-width="${a.strokeWidth}" stroke-linecap="round"
    stroke-linejoin="round" class="${cls}">${d}</svg>`;
  return s;
}
