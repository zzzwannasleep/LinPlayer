/* 安卓宿主能力的薄壳。
 *
 * ## 为什么不是一条 Tauri 命令
 * 屏幕方向是 **Activity 的属性**(`setRequestedOrientation`),不是 Rust 侧
 * 能碰的东西。走 Tauri 命令的话链条是 JS → Rust → JNI 回调进 Activity,
 * 中间要自己攒 JavaVM 引用和线程切换 —— 为了一行 setter 不值当。
 * `addJavascriptInterface` 是安卓官方给的正路,一行调用直达 Activity。
 *
 * ## 为什么不用 W3C 的 `screen.orientation.lock()`
 * 试过了不行:Android WebView 上它要求文档处于**全屏**状态(Fullscreen API),
 * 而我们的"全屏"是原生窗口层面的,DOM 从来没进过 fullscreen —— 调用直接
 * reject 成 NotSupportedError。而且它锁的是 WebView 的视口,锁不住底下那层
 * SurfaceView(视频真正画在那儿)。
 *
 * ## 拿不到宿主时静默降级
 * 桌面端 / 浏览器里跑同一份代码时 `window.LPHost` 不存在 —— 这里返回 false,
 * 调用点据此不做任何事。**不抛异常**:一个装饰性能力不该让整页崩掉。
 */

type Orientation = "landscape" | "portrait" | "auto";

type LPHost = {
  setOrientation?: (mode: string) => void;
};

const host = (): LPHost | null =>
  (typeof window !== "undefined" ? (window as unknown as { LPHost?: LPHost }).LPHost : null) ?? null;

export const hasHost = () => !!host()?.setOrientation;

/** 请求屏幕方向。`auto` = 交回系统(跟随传感器/系统锁)。返回是否真的下达了。 */
export function setOrientation(mode: Orientation): boolean {
  const h = host();
  if (!h?.setOrientation) return false;
  try {
    h.setOrientation(mode);
    return true;
  } catch {
    return false;
  }
}
