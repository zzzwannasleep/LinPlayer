/* ============================================================
   壳按键桥 + 返回键消费栈(手机端)。

   ## 为什么这里有一份,ui/tv 里还有一份
   两端共用的是**线路协议**:壳(MainActivity.onKeyDown)统一喊
   `window.__lpTvKey('back')`,谁装了这个函数谁收得到。
   TV 那份长在 `ui/tv/app/focus.ts` 里,和 norigin 焦点库缠在一起 ——
   把它 import 过来等于把整个焦点库(以及它的 D-pad 语义)拖进手机端,
   而手机端一个格子都不需要。所以这里只复刻**协议本身**,四十行,不共享实现。

   ★ 函数名叫 `__lpTvKey` 而不是 `__lpKey`,是历史(TV 端先落的)。
     **别改**:它是 MainActivity.kt ↔ ui/tv ↔ ui/mobile 三处对齐的字面量,
     改一处就静默断一条 —— 而断了的表现是"返回键没反应",不报错。
     apps/android/src/lib.rs 里有测试盯着壳侧那一半。
   ============================================================ */

/** 壳发给前端的键。手机端只关心一部分(方向键那套是 TV 的)。 */
export type ShellKey =
  | "back"
  | "menu"
  | "wake"
  | "play"
  | "pause"
  | "playpause"
  | "stop"
  | "next"
  | "prev"
  | "ff"
  | "rew";

export const SHELL_KEY_EVENT = "lp:shellkey";

declare global {
  interface Window {
    __lpTvKey?: (k: ShellKey) => void;
  }
}

/** 启动时装一次,必须在任何组件挂载之前。 */
export function installShellKeyBridge() {
  window.__lpTvKey = (k: ShellKey) => {
    window.dispatchEvent(new CustomEvent(SHELL_KEY_EVENT, { detail: k }));
  };

  /* 桌面 Tauri 壳和浏览器里没有安卓 Activity —— 用键盘兜底,
     手机 UI 在 PC 上开发时就是靠这条走返回流程的。 */
  window.addEventListener("keydown", (e) => {
    if (e.key !== "Escape" && e.key !== "Backspace") return;
    const t = e.target as HTMLElement | null;
    // 输入框里的退格是删字,不是返回
    if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
    e.preventDefault();
    window.__lpTvKey?.("back");
  });
}

/** 订阅壳按键。返回退订函数,直接丢给 useEffect 的 cleanup。 */
export function onShellKey(fn: (k: ShellKey) => void): () => void {
  const h = (e: Event) => fn((e as CustomEvent<ShellKey>).detail);
  window.addEventListener(SHELL_KEY_EVENT, h);
  return () => window.removeEventListener(SHELL_KEY_EVENT, h);
}

/* ------------------------------------------------------------
   返回键消费栈
   ------------------------------------------------------------ */

const backHandlers: Array<() => boolean> = [];

/** 注册一层返回键处理(sheet / 面板 / 对话框挂载时调)。返回退订函数。
 *
 *  ★ 没有这个的话,App 会无条件把 back 变成「弹一层路由」——
 *    于是 **sheet 开着按返回,sheet 没关、整个页面先退了**。
 *    用户只想关掉那个筛选面板,结果回到了上一页。
 *    这是每个覆盖层的通病(不是某一页的),所以必须在这一层解,
 *    不能指望每个页面自己记得拦。TV 端已经栽过同一个坑。 */
export function pushBackHandler(fn: () => boolean): () => void {
  backHandlers.push(fn);
  return () => {
    const i = backHandlers.lastIndexOf(fn);
    if (i >= 0) backHandlers.splice(i, 1);
  };
}

/** 从内到外问一遍:有人吃掉返回键吗?返回 true = 已被消费,路由别动。 */
export function consumeBack(): boolean {
  for (let i = backHandlers.length - 1; i >= 0; i--) {
    if (backHandlers[i]()) return true;
  }
  return false;
}
