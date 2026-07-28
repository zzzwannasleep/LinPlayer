import { useEffect, useLayoutEffect, useRef, useState, type ReactNode } from "react";
import { haptic } from "./motion";
import type { Frame } from "./router";

/* ============================================================
   页面栈 —— 草稿 `motion.js` 里那个命令式 `Stack` 的 React 版。

   ## 和上一版 ui/mobile 的根本区别
   上一版是 `<main className="page" key={tab:depth}>` 一个容器,换页 = 换 key,
   **React 一帧之内把旧页卸载、新页挂上** —— 所以根本不存在"转场",
   用户看到的是内容瞬间跳变。这一版把整条栈全部挂着,每一格是一层绝对定位的 `.pg`,
   转场靠两层同时动(共享轴 X)。

   ## 三件 React 天然做不到、必须自己接的事

   1. **被弹掉的那一页要留到动画跑完**。React 一 setState 就把它从树里摘了。
      解法:本地留一格 `leaving`,渲染在当前栈之后,350ms 后再真正丢掉。

   2. **盖住的页不参与绘制**。转场结束后给下面那些 `.pg` 上 `visibility:hidden` ——
      不上的话,首页那 200+ 个 `<img>` 会一直在合成树里,滚动时白白掉帧。

   3. **侧滑返回跟手时绕过 React**。每帧一次 setState = 一次 render + reconcile,
      安卓 WebView 上直接掉到 30fps。跟手期间直接写 `style.transform`,
      松手才调 `pop()` 把最终状态交回 React。

   ## 两个只有真跑起来才会现形的坑(草稿里踩过,注释一起搬过来)
   - 释放动画跑完之前**不能摘 `.dragging`**:`.pg.in-push` 带 `animation-fill-mode: both`,
     CSS 动画的 fill 值**压得过内联 style**。摘早了的表现是手指抬起的一瞬间页面"啪"地
     弹回原位,然后才播释放动画。`.dragging` 里的 `animation:none !important` 就是压住它的。
   - 返回成功后要把前一页身上的 `out-push` 摘掉:那个类 fill:both 按住 `-25%`,
     不摘的表现是"返回成功了,但整页往左偏了四分之一"。
   ============================================================ */

/** 只在左缘这个宽度内起手才认侧滑。
 *  不设这个窗口的话,首页的横滑轨道拨一下就退出页面了 —— 轨道横滑优先,
 *  这是 README 里写死的三条手势冲突裁决之一。 */
const EDGE_PX = 24;
/** 松手阈值:走过屏宽 35%,**或者**速度够快(利落地一甩)。
 *  只看位移的话,"快速一甩"这种最自然的返回手势会失败。 */
const BACK_RATIO = 0.35;
const BACK_VELOCITY = 0.5;

const PUSH_MS = 400;
const POP_MS = 350;

type Props = {
  frames: Frame[];
  /** 侧滑/返回键之外,由页面自己触发的返回 */
  onPop: () => void;
  /** 这一格能不能侧滑返回(播放页不能 —— 横滑要留给进度手势) */
  canSwipe: (f: Frame) => boolean;
  render: (f: Frame, isTop: boolean) => ReactNode;
};

export default function PageStack({ frames, onPop, canSwipe, render }: Props) {
  const rootRef = useRef<HTMLDivElement>(null);
  /** 刚被弹掉、正在播退场动画的那一格 */
  const [leaving, setLeaving] = useState<{ frame: Frame; node: ReactNode } | null>(null);
  const prevFrames = useRef<Frame[]>(frames);
  /** 转场方向。null = 首次挂载,不做转场(第一页凭空滑进来很怪) */
  const dir = useRef<"push" | "pop" | "replace" | null>(null);
  const busy = useRef(false);

  /* 判方向。用**栈深**判,不用 key 比对 —— replace 的深度不变但栈顶 key 变了。 */
  if (prevFrames.current !== frames) {
    const a = prevFrames.current;
    const b = frames;
    if (b.length > a.length) dir.current = "push";
    else if (b.length < a.length) dir.current = "pop";
    else if (b[b.length - 1]?.key !== a[a.length - 1]?.key) dir.current = "replace";
    else dir.current = null; // 同一条栈换了 Tab
    prevFrames.current = frames;
  }

  /* 弹栈:把被摘掉的那一格接住,留到动画跑完。
     ★ 依赖只放 frames —— 放 leaving 的话 setLeaving 会把这个 effect 再触发一次,
       第二次跑时 frames 没变但 dir 还是 "pop",会把已经在退场的那格又接一遍。 */
  const lastRendered = useRef<Map<string, ReactNode>>(new Map());
  useEffect(() => {
    if (dir.current !== "pop") return;
    const gone = prevPopped.current;
    if (!gone) return;
    prevPopped.current = null;
    setLeaving(gone);
    const t = setTimeout(() => setLeaving(null), POP_MS);
    return () => clearTimeout(t);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [frames]);

  /* 上一次渲染时的栈顶,用来在 pop 发生时把"消失的那一格"捞出来。
     必须在 render 阶段记(useLayoutEffect 里 frames 已经是新的了)。 */
  const prevPopped = useRef<{ frame: Frame; node: ReactNode } | null>(null);
  const prevTopRef = useRef<Frame | null>(null);
  {
    const top = frames[frames.length - 1];
    const before = prevTopRef.current;
    if (dir.current === "pop" && before && before.key !== top?.key) {
      prevPopped.current = { frame: before, node: lastRendered.current.get(before.key) ?? null };
    }
    prevTopRef.current = top ?? null;
  }

  /* 转场类。★ 用 useLayoutEffect:必须在浏览器画第一帧之前把类挂上,
     用 useEffect 的话新页会先以最终位置画一帧,再跳回右侧开始动 —— 那一帧就是"闪"。 */
  useLayoutEffect(() => {
    const root = rootRef.current;
    if (!root || !dir.current) return;
    const pgs = [...root.querySelectorAll<HTMLElement>(".pg")];
    // 正在退场的那一格排在最后,它不算"当前栈"的一员
    const stack = pgs.filter((p) => p.dataset.leaving !== "1");
    const top = stack[stack.length - 1];
    const under = stack[stack.length - 2];
    if (!top) return;

    // 每次转场先把上一轮的残留清干净,否则 fill:both 的类会按住旧位置
    for (const p of pgs) p.classList.remove("in-push", "out-push", "in-pop", "out-pop");

    if (dir.current === "push") {
      busy.current = true;
      top.classList.add("in-push");
      if (under) under.classList.add("out-push");
      const t = setTimeout(() => {
        busy.current = false;
        hideCovered(root);
      }, PUSH_MS);
      return () => clearTimeout(t);
    }
    if (dir.current === "pop") {
      busy.current = true;
      top.style.visibility = "";
      top.classList.add("in-pop");
      const out = pgs.find((p) => p.dataset.leaving === "1");
      out?.classList.add("out-pop");
      const t = setTimeout(() => {
        top.classList.remove("in-pop");
        busy.current = false;
        hideCovered(root);
      }, POP_MS);
      return () => clearTimeout(t);
    }
    /* replace:原地换页,**不做横向滑动** —— 那是"进了一层"的语言,
       而上一集/下一集是同一层的横向移动。只做 200ms 淡入。 */
    top.animate([{ opacity: 0 }, { opacity: 1 }], { duration: 200, fill: "both" });
    hideCovered(root);
  }, [frames, leaving]);

  /* 切 Tab 回来时栈没变,但盖住的页可能被上一轮 hide 过了 —— 这里兜一次底。 */
  useLayoutEffect(() => {
    if (rootRef.current && !busy.current) hideCovered(rootRef.current);
  });

  /* ── 侧滑返回 ── */
  useEffect(() => {
    const root = rootRef.current;
    if (!root) return;
    let act = false;
    let sx = 0;
    let dx = 0;
    let lastX = 0;
    let lastT = 0;
    let v = 0;
    let cur: HTMLElement | null = null;
    let under: HTMLElement | null = null;
    const W = () => root.clientWidth;
    const scrimOf = (p: HTMLElement | null) => p?.querySelector<HTMLElement>(".pg-scrim") ?? null;

    const down = (e: PointerEvent) => {
      if (busy.current) return;
      const stack = [...root.querySelectorAll<HTMLElement>(".pg")].filter(
        (p) => p.dataset.leaving !== "1",
      );
      if (stack.length < 2) return;
      if (stack[stack.length - 1].dataset.noswipe === "1") return;
      if (e.clientX - root.getBoundingClientRect().left > EDGE_PX) return;
      act = true;
      sx = lastX = e.clientX;
      lastT = performance.now();
      dx = 0;
      v = 0;
      cur = stack[stack.length - 1];
      under = stack[stack.length - 2];
      under.style.visibility = "";
      root.classList.add("dragging");
      cur.style.transform = "translateX(0)";
      under.style.transform = "translateX(-25%)";
      const s = scrimOf(under);
      if (s) s.style.opacity = "0.4";
    };

    const move = (e: PointerEvent) => {
      if (!act || !cur || !under) return;
      dx = Math.max(0, e.clientX - sx);
      const now = performance.now();
      if (now - lastT > 8) {
        v = (e.clientX - lastX) / (now - lastT);
        lastX = e.clientX;
        lastT = now;
      }
      const p = dx / W();
      cur.style.transform = `translateX(${dx}px)`;
      under.style.transform = `translateX(${-25 + 25 * p}%)`;
      const s = scrimOf(under);
      if (s) s.style.opacity = String(0.4 * (1 - p));
    };

    const end = () => {
      if (!act || !cur || !under) return;
      act = false;
      const c = cur;
      const u = under;
      const go = dx > W() * BACK_RATIO || v > BACK_VELOCITY;
      const ms = 300;
      const ease = "cubic-bezier(.05,.7,.1,1)";
      const us = scrimOf(u);

      if (go) {
        haptic("tap");
        busy.current = true;
        c.animate([{ transform: `translateX(${dx}px)` }, { transform: "translateX(100%)" }], {
          duration: ms,
          easing: ease,
          fill: "both",
        });
        u.animate([{ transform: u.style.transform }, { transform: "translateX(0)" }], {
          duration: ms,
          easing: ease,
          fill: "both",
        });
        if (us) us.animate([{ opacity: us.style.opacity }, { opacity: 0 }], { duration: ms, fill: "both" });
        setTimeout(() => {
          /* ★ 顺序不能反:先把 fill:both 的残留清掉,再摘 .dragging。
             反了的话 .dragging 一撤,out-push 立刻把前一页按回 -25%。 */
          u.classList.remove("in-push", "out-push", "in-pop", "out-pop");
          u.getAnimations().forEach((a) => a.cancel());
          u.style.transform = "";
          if (us) {
            us.getAnimations().forEach((a) => a.cancel());
            us.style.opacity = "";
          }
          root.classList.remove("dragging");
          busy.current = false;
          /* 交回 React。走的是同一条 pop,所以 PageStack 会照常接住退场那一格 ——
             但它此刻已经被 WAAPI 推到屏幕外了,退场动画肉眼看不出来,正好。 */
          onPop();
        }, ms);
      } else {
        const a1 = c.animate([{ transform: `translateX(${dx}px)` }, { transform: "translateX(0)" }], {
          duration: ms,
          easing: ease,
          fill: "both",
        });
        const a2 = u.animate([{ transform: u.style.transform }, { transform: "translateX(-25%)" }], {
          duration: ms,
          easing: ease,
          fill: "both",
        });
        if (us) us.animate([{ opacity: us.style.opacity || "0" }, { opacity: 0.4 }], { duration: ms, fill: "both" });
        Promise.all([a1.finished, a2.finished])
          .then(() => {
            root.classList.remove("dragging");
            c.style.transform = "";
            a1.cancel();
            u.style.visibility = "hidden";
            u.style.transform = "";
            a2.cancel();
            if (us) {
              us.getAnimations().forEach((x) => x.cancel());
              us.style.opacity = "";
            }
          })
          .catch(() => root.classList.remove("dragging"));
      }
      cur = null;
      under = null;
    };

    root.addEventListener("pointerdown", down);
    root.addEventListener("pointermove", move);
    root.addEventListener("pointerup", end);
    root.addEventListener("pointercancel", end);
    return () => {
      root.removeEventListener("pointerdown", down);
      root.removeEventListener("pointermove", move);
      root.removeEventListener("pointerup", end);
      root.removeEventListener("pointercancel", end);
    };
  }, [onPop]);

  lastRendered.current = new Map();

  return (
    /* ★ 类名叫 `pg-stack` 不叫 `stack` —— 外层那个按 Tab 分的容器已经叫 `.stack` 了。
       两层同名的后果：所有 `document.querySelectorAll(".stack")` 都会数出双倍（实测 6 个），
       而 CSS 上两层都是 `position:absolute;inset:0` 又刚好看不出毛病 ——
       这种"能跑但结构是错的"最难查。 */
    <div className="pg-stack" ref={rootRef}>
      {frames.map((f, i) => {
        const isTop = i === frames.length - 1;
        const node = render(f, isTop);
        lastRendered.current.set(f.key, node);
        return (
          <div className="pg" key={f.key} data-noswipe={canSwipe(f) ? undefined : "1"}>
            <div className="pg-scrim" />
            {node}
          </div>
        );
      })}
      {leaving && (
        <div className="pg" key={leaving.frame.key} data-leaving="1">
          <div className="pg-scrim" />
          {leaving.node}
        </div>
      )}
    </div>
  );
}

/** 盖住的页不参与绘制。★ 只藏"不是栈顶、也不在退场"的那些。 */
function hideCovered(root: HTMLElement) {
  const pgs = [...root.querySelectorAll<HTMLElement>(".pg")];
  const stack = pgs.filter((p) => p.dataset.leaving !== "1");
  stack.forEach((p, i) => {
    p.style.visibility = i === stack.length - 1 ? "" : "hidden";
  });
}
