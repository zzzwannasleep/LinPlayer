import { createContext, useContext } from "react";
import type { Item, LoginResult, SourceEntry } from "@shared/api";
import type { PageId } from "./nav";
import type { Route } from "./router";

/* 页面上下文。
 *
 * ## 为什么是 context 而不是逐层传 props
 * 上一版 App.tsx 把 onOpen / onGo / onPlay / onBack 一个个当 props 传给每个页面,
 * 15 个页面每个签名都不一样,加一个能力就要改 16 处。而页面是被 `PageStack.render`
 * 渲染出来的 —— 中间还隔着一层组件,props 要再穿一次。
 *
 * ★ 这不违反「不引入 store」那条规矩:context 里放的全是**函数和只读会话**,
 *   一次性建好就不再变;真正的数据仍然是各页各持 useState 副本、
 *   靠 api.ts 的 invoke 层广播刷新。 */

export type Ctx = {
  /** Emby 会话。只连了网盘的用户这里是 null —— 依赖它的页面必须自己判。 */
  session: LoginResult | null;
  route: Route;
  /** 压一层 */
  go: (r: Route | PageId) => void;
  /** 原地换页(上一集/下一集),栈深不变 */
  replace: (r: Route | PageId) => void;
  back: () => void;
  /** 打开条目详情。★ 分集会被送到**单集页**,其余送详情页 —— 判断在 App.tsx 里做一次,
   *  调用点一律只管"打开这个条目"。 */
  openItem: (it: Item) => void;
  /** 起播。★ 先 await play() 成功才导航 —— 反过来的话起播失败会停在一个空的
   *  播放页上,用户只看到黑屏。 */
  play: (it: Item, mediaSourceId?: string | null) => void | Promise<void>;
  /** 起播一个源条目(网盘文件 / 资源站的一集)。★ 页面别自己 invoke source_play ——
   *  起播成功后**必须导航到播放页**,否则不透明的目录页盖着底下那层视频 SurfaceView,
   *  用户看到的是「有声音、没画面」。 */
  playSource: (entry: SourceEntry) => void | Promise<void>;
  /** 账号有变(加/删/切服务器、重新登录)时喊一声,重新问闸口 */
  reloadGate: () => void;
};

export const PageCtx = createContext<Ctx | null>(null);

export function useCtx(): Ctx {
  const c = useContext(PageCtx);
  /* 抛错而不是返回一个空壳:空壳会让页面静默地什么都不做(点了没反应),
     那比白屏难查十倍。 */
  if (!c) throw new Error("useCtx 必须在 PageCtx.Provider 里用");
  return c;
}
