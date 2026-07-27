/* 播放器手势识别。

   Emby 官方安卓端**一个手势都没有** —— 这是最容易拉开差距的地方,
   也是社区吐槽它最集中的一条。这里实现六个:

   | 手势 | 行为 |
   |---|---|
   | 左半屏竖滑 | 亮度 |
   | 右半屏竖滑 | 音量 |
   | 横滑 | 进度 |
   | 双击左/右半屏 | ±10s |
   | 长按 | 2× 倍速,松开还原 |
   | 单击 | OSD 显隐 |

   ## 三条设计约束(踩过的坑都在这)

   1. **方向要先"锁定"再生效。** 手指很少走直线:不锁方向的话,竖着调音量时
      会顺带把进度也拨了。这里超过 12px 位移才判方向,判完就锁死到抬手。
   2. **进度不能边拖边 seek。** seek 是排队命令,每帧发一次会把 mpv 的
      命令队列灌满(本项目在进度条上栽过:「拖动弹回」的根因就是 seek 排队)。
      所以拖动期间只更新预览值,**抬手才 seek 一次**。
   3. **双击必须先排除长按和滑动。** 顺序是:按下起长按计时器 → 有位移就取消长按 →
      抬手时若无位移且距上次抬手 <280ms 判双击。少任何一步都会互相误触发。 */

export type GestureKind = "brightness" | "volume" | "seek";

export type GestureHandlers = {
  /** 竖滑中。delta 是 -1..1 的**增量比例**(向上为正) */
  onAdjust: (kind: "brightness" | "volume", deltaRatio: number) => void;
  /** 横滑中的进度预览(秒)。抬手前不要真 seek */
  onSeekPreview: (targetSecs: number) => void;
  /** 抬手,真正执行 seek */
  onSeekCommit: (targetSecs: number) => void;
  /** 手势结束,可以撤掉指示器 */
  onEnd: () => void;
  onSingleTap: () => void;
  onDoubleTap: (side: "left" | "right") => void;
  /** 长按开始 / 结束(倍速) */
  onLongPress: (on: boolean) => void;
};

export type GestureCtx = {
  /** 当前播放位置(秒),横滑基于它算目标 */
  time: number;
  duration: number;
};

/** 判方向前要走的最小位移。小于它一律不算手势(手指按下时的抖动)。 */
const SLOP = 12;
/** 竖滑走完全程需要的比例:屏高的 70%。100% 的话手指要从最上划到最下,够不着。 */
const V_TRAVEL = 0.7;
/** 横滑灵敏度:整个屏宽 ≈ 120 秒。再灵敏就没法精调,再钝就拖不到远处。 */
const H_SECONDS_PER_SCREEN = 120;
const LONG_PRESS_MS = 500;
const DOUBLE_TAP_MS = 280;

export function attachGestures(
  el: HTMLElement,
  getCtx: () => GestureCtx,
  h: GestureHandlers,
): () => void {
  let startX = 0;
  let startY = 0;
  let lock: GestureKind | null = null;
  let moved = false;
  let longTimer: number | null = null;
  let longActive = false;
  let lastUp = 0;
  let lastTapSide: "left" | "right" = "left";
  let seekTarget = 0;
  let active = false;

  const clearLong = () => {
    if (longTimer) window.clearTimeout(longTimer);
    longTimer = null;
  };

  const onDown = (e: PointerEvent) => {
    // 多指:直接放弃(系统缩放/误触),别硬猜用户想干嘛
    if (!e.isPrimary) return;
    active = true;
    startX = e.clientX;
    startY = e.clientY;
    lock = null;
    moved = false;
    longActive = false;
    clearLong();
    longTimer = window.setTimeout(() => {
      // 有位移就不是长按 —— 这一条在 onMove 里已经 clear 过,这里是兜底
      if (moved) return;
      longActive = true;
      navigator.vibrate?.(12);
      h.onLongPress(true);
    }, LONG_PRESS_MS);
  };

  const onMove = (e: PointerEvent) => {
    if (!active || !e.isPrimary) return;
    const dx = e.clientX - startX;
    const dy = e.clientY - startY;

    if (!lock) {
      if (Math.hypot(dx, dy) < SLOP) return;
      moved = true;
      clearLong();
      /* 方向锁:横向位移更大就是进度,否则按起手位置分左右(亮度/音量)。
         ★ 锁一次到抬手为止 —— 中途允许改方向的话,调音量时手一歪就把进度拨了。 */
      if (Math.abs(dx) > Math.abs(dy)) {
        lock = "seek";
        const c = getCtx();
        seekTarget = c.time;
      } else {
        lock = startX < el.clientWidth / 2 ? "brightness" : "volume";
      }
      // 锁定后重置起点,避免那 12px 的判定位移被当成有效调节量
      startX = e.clientX;
      startY = e.clientY;
      return;
    }

    if (lock === "seek") {
      const c = getCtx();
      const secs = ((e.clientX - startX) / el.clientWidth) * H_SECONDS_PER_SCREEN;
      /* 上界 `|| Infinity` 不是 `|| 0`:时长还没就绪(起播/换片)时 `Math.min(0, …)`
         会把目标一律夹成 0,横滑调进度变成「一律跳回片头」。夹不住就交给 mpv 夹。 */
      seekTarget = Math.max(0, Math.min(c.duration || Infinity, c.time + secs));
      h.onSeekPreview(seekTarget);
    } else {
      // 向上是增加 → dy 为负,所以取反
      const ratio = -(e.clientY - startY) / (el.clientHeight * V_TRAVEL);
      startY = e.clientY; // 增量式:每次报的是"这一小段"的变化量
      h.onAdjust(lock, ratio);
    }
  };

  const onUp = (e: PointerEvent) => {
    if (!active || !e.isPrimary) return;
    active = false;
    clearLong();

    if (longActive) {
      longActive = false;
      h.onLongPress(false);
      h.onEnd();
      return;
    }

    if (lock === "seek") h.onSeekCommit(seekTarget);
    if (lock) {
      lock = null;
      h.onEnd();
      return;
    }

    // 没位移 = 点击。判单击还是双击
    if (moved) return;
    const side: "left" | "right" = e.clientX < el.clientWidth / 2 ? "left" : "right";
    const now = e.timeStamp;
    if (now - lastUp < DOUBLE_TAP_MS && side === lastTapSide) {
      lastUp = 0; // 吃掉,避免三击被算成两次双击
      h.onDoubleTap(side);
      return;
    }
    lastUp = now;
    lastTapSide = side;
    /* ★ 单击要等 DOUBLE_TAP_MS 确认不是双击的前半 —— 不等的话双击会先闪一下 OSD。
       这个延迟是移动端点击"发粘"的常见来源,但在播放器上它是必要的:
       OSD 闪一下再快进,比晚 280ms 出 OSD 难受得多。 */
    window.setTimeout(() => {
      if (lastUp === now) h.onSingleTap();
    }, DOUBLE_TAP_MS);
  };

  el.addEventListener("pointerdown", onDown);
  el.addEventListener("pointermove", onMove);
  el.addEventListener("pointerup", onUp);
  el.addEventListener("pointercancel", onUp);
  return () => {
    clearLong();
    el.removeEventListener("pointerdown", onDown);
    el.removeEventListener("pointermove", onMove);
    el.removeEventListener("pointerup", onUp);
    el.removeEventListener("pointercancel", onUp);
  };
}
