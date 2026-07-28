/* ============================================================
   动效原语。整段来自 `docs/mobile-drafts/motion.js`(评审台 87 格逐格看过的原型)。

   零依赖。所有动画只动 transform / opacity。

   ## 为什么这些是**命令式 DOM 操作**而不是 React 组件
   跟手的东西(侧滑返回 / sheet 拖拽 / 播放器手势 / 下拉刷新)每帧都要改 transform。
   走 setState 的话每帧一次 render + reconcile,安卓 WebView 上直接掉到 30fps ——
   这不是猜的,PC 端进度条就是这么栽的。所以跟手期间**绕过 React 直接写 style**,
   松手后再把最终值交回 state。React 不需要知道中间那 20 帧。

   ## 草稿里的 h() 没有搬过来
   那是给 vanilla 用的极简 hyperscript,这边 JSX 就是它。
   草稿里 h() 的两个坑(字符串子节点被当 props / CSS 自定义属性要 setProperty)
   在 JSX 下:前者不存在,后者仍在 —— React 的 style 对象**支持** `--x` 自定义属性
   (React 16+ 会走 setProperty),所以 `style={{ "--i": i }}` 是安全的。
   ============================================================ */

export const $ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = document) =>
  root.querySelector<T>(sel);
export const $$ = <T extends Element = HTMLElement>(sel: string, root: ParentNode = document) => [
  ...root.querySelectorAll<T>(sel),
];

/** 当前慢放倍率。CSS 那边是 var(--mo),这里读同一个值,两边才不会脱节。
 *  真机恒为 1;排查动效时把 :root 的 --mo 改成 4 就是 0.25× 慢放。 */
export const MO = () =>
  parseFloat(getComputedStyle(document.documentElement).getPropertyValue("--mo")) || 1;

/** 放慢过的 setTimeout */
export const wait = (ms: number) => new Promise<void>((r) => setTimeout(r, ms * MO()));

export const raf = () =>
  new Promise<void>((r) => requestAnimationFrame(() => requestAnimationFrame(() => r())));

/* ---------- 触觉 ----------
   ★ 必须在事件回调里同步调用,放进 setTimeout 会因为"没有用户激活"被静默丢掉。
   ★ 静音/勿扰下不震且不报错 —— 所以它永远只能是**附加**反馈,不能是唯一反馈。 */
const HAPTIC: Record<string, number | number[]> = {
  tap: 12,
  sel: 18,
  ok: 28,
  warn: [30, 40, 30],
  err: [40, 60, 40],
};
export function haptic(kind: keyof typeof HAPTIC | string = "tap") {
  try {
    navigator.vibrate?.(HAPTIC[kind] ?? 12);
  } catch {
    /* 不支持 vibrate 的设备直接跳过,这从来不是错误 */
  }
}

/* ---------- 涟漪 ----------
   Material 规格:600ms linear,scale 0→2,opacity 与 scale 同起但更早结束。
   用真实子元素而不是伪元素 —— 伪元素拿不到触点坐标,涟漪只能从中心出来,
   那就丢掉了"从我手指底下长出来"这个最关键的信息。 */
export function ripple(el: HTMLElement, ev?: { clientX: number; clientY: number }) {
  const r = el.getBoundingClientRect();
  const x = (ev?.clientX ?? r.left + r.width / 2) - r.left;
  const y = (ev?.clientY ?? r.top + r.height / 2) - r.top;
  // 半径取到最远角,保证一定铺满
  const d = Math.max(
    Math.hypot(x, y),
    Math.hypot(r.width - x, y),
    Math.hypot(x, r.height - y),
    Math.hypot(r.width - x, r.height - y),
  );
  const i = document.createElement("i");
  i.className = "ripple";
  i.style.left = `${x - d}px`;
  i.style.top = `${y - d}px`;
  i.style.width = `${d * 2}px`;
  i.style.height = `${d * 2}px`;
  el.classList.add("rip");
  el.append(i);
  i.addEventListener("animationend", () => i.remove(), { once: true });
}

/* ---------- 按压 ----------
   ★ 为什么不用 :active:安卓 WebView 上 :active 在滚动开始后**不会**及时移除,
     表现是"滑一下,某张卡就一直保持按下的样子"。所以自己管,滚动就取消。
   返回一个卸载函数 —— React 里挂在 useEffect 的 cleanup 上。 */
export function press(el: HTMLElement, { scale = true, rip = false } = {}) {
  let on = false;
  const down = (e: PointerEvent) => {
    on = true;
    if (scale) el.classList.add("down");
    if (rip) ripple(el, e);
  };
  const up = () => {
    on = false;
    el.classList.remove("down");
  };
  const move = () => on && up();
  el.addEventListener("pointerdown", down);
  el.addEventListener("pointerup", up);
  el.addEventListener("pointercancel", up);
  el.addEventListener("pointerleave", up);
  // 一旦开始滚动就当没按 —— 这是"卡住的按压态"的解药
  el.addEventListener("touchmove", move, { passive: true });
  return () => {
    el.removeEventListener("pointerdown", down);
    el.removeEventListener("pointerup", up);
    el.removeEventListener("pointercancel", up);
    el.removeEventListener("pointerleave", up);
    el.removeEventListener("touchmove", move);
  };
}

/* ---------- 长按(= PC 的右键) ----------
   ★ 只在「元素**自己**收到 pointermove 且位移 >10px」时取消。
     所以任何挂在 document 上的拖拽(比如线路页的排序手柄)必须自己
     `stopPropagation()` 掐掉这里的 pointerdown —— 否则按住手柄不动 480ms
     菜单就弹出来了,拖排序当场废掉。 */
export function longPress(el: HTMLElement, cb: (e: PointerEvent) => void, ms = 480) {
  let t: ReturnType<typeof setTimeout> | null = null;
  let sx = 0;
  let sy = 0;
  let fired = false;
  const clear = () => {
    if (t) clearTimeout(t);
    t = null;
  };
  const down = (e: PointerEvent) => {
    fired = false;
    sx = e.clientX;
    sy = e.clientY;
    t = setTimeout(() => {
      fired = true;
      haptic("sel");
      el.classList.add("lifted");
      cb(e);
    }, ms);
  };
  const end = () => {
    clear();
    el.classList.remove("lifted");
  };
  const up = (e: PointerEvent) => {
    if (fired) {
      e.preventDefault();
      e.stopPropagation();
    }
    end();
  };
  const move = (e: PointerEvent) => {
    if (t && Math.hypot(e.clientX - sx, e.clientY - sy) > 10) end();
  };
  // 捕获阶段吃掉 click,否则长按之后既弹菜单又进详情
  const click = (e: MouseEvent) => {
    if (fired) {
      e.preventDefault();
      e.stopPropagation();
    }
  };
  el.addEventListener("pointerdown", down);
  el.addEventListener("pointerup", up);
  el.addEventListener("pointercancel", end);
  el.addEventListener("pointermove", move);
  el.addEventListener("click", click, true);
  return () => {
    clear();
    el.removeEventListener("pointerdown", down);
    el.removeEventListener("pointerup", up);
    el.removeEventListener("pointercancel", end);
    el.removeEventListener("pointermove", move);
    el.removeEventListener("click", click, true);
  };
}

/* ---------- 图片进场 ----------
   ★ 已在缓存里的图必须**一帧都不动**。不做这一步的话,每次滚回去、每次翻页
     都要重播一次淡入 —— 用户看到的是"到处在闪",而不是"加载得很顺"。
   ★ 判据用 img.complete && naturalWidth>0,不是 onload(缓存命中时 onload 也会触发,
     但那时已经晚了一帧,该闪的还是闪了)。 */
export function imgIn(img: HTMLImageElement) {
  if (img.complete && img.naturalWidth > 0) {
    img.classList.add("instant", "ready");
    return;
  }
  img.addEventListener("load", () => img.classList.add("ready"), { once: true });
  img.addEventListener(
    "error",
    () => {
      img.style.opacity = "0";
    },
    { once: true },
  );
}

/** 新插入的一棵子树里所有 <img> 一次性接上 */
export const imgsIn = (root: ParentNode) => $$<HTMLImageElement>("img", root).forEach(imgIn);

/* ---------- 首屏 stagger ----------
   ★ 只给首屏。滚动出来的卡片不参与:边滚边闪比不动更像掉帧。 */
export function stagger(nodes: HTMLElement[], max = 12) {
  nodes.forEach((n, i) => {
    if (i >= max) return;
    n.style.setProperty("--i", String(i));
    n.classList.add("enter");
  });
}

/** 首屏之外:滚进视口再进场。用 IntersectionObserver 而不是
    scroll-driven animations —— 后者要 Chrome 115+,而且和 content-visibility 冲突。 */
const io =
  typeof IntersectionObserver === "undefined"
    ? null
    : new IntersectionObserver(
        (es) =>
          es.forEach((e) => {
            if (!e.isIntersecting) return;
            (e.target as HTMLElement).style.setProperty("--i", "0");
            e.target.classList.add("enter");
            io?.unobserve(e.target);
          }),
        { threshold: 0.05, rootMargin: "0px 0px -6% 0px" },
      );
export const enterOnScroll = (n: Element) => io?.observe(n);

/* ---------- 首屏进场编排 ----------
   ★ 只给首屏 12 项。屏幕外的交给 IntersectionObserver。
     全都加 = 一进页面几十个动画同时排队,那就是"卡了一下"。 */
export function choreograph(root: ParentNode | null) {
  if (!root) return;
  imgsIn(root);
  const cards = $$(".card", root);
  stagger(cards.slice(0, 12));
  cards.slice(12).forEach(enterOnScroll);
  // 非卡片的块(轨道标题 / 单元格组)也参与,但节奏更慢一点
  $$("[data-enter]", root).forEach((n, i) => {
    n.style.setProperty("--i", String(i));
    n.classList.add("enter");
  });
}

/* ============================================================
   FLIP 共享元素
   ★ 为什么不用 View Transitions API:它要 Chrome 111+,而我们的用户里有相当一部分
     是没有 Google Play 的国内 ROM,系统 WebView 版本不可控。FLIP 是 100% 支持的,
     而且能在**跟手中途被打断**,VT 不能。所以 FLIP 是地基,VT 只做锦上添花。
   ★ 两张宽高比不同的图之间飞(海报 2:3 → Hero 3:4)不能只用等比 scale,
     否则要么留黑边要么裁掉脸。做法和 View Transitions 内部一样:
     克隆盒做非等比 scale,盒里叠两张图 —— 源图淡出、目标图淡入,
     两张图各自 object-fit:cover,交叉淡化把非等比的形变盖住。
   ============================================================ */

export type FlipSource = { rect: DOMRect; src: string; radius: string };

const flipLayer = () => {
  let l = $("#flip-layer");
  if (!l) {
    l = document.createElement("div");
    l.id = "flip-layer";
    Object.assign(l.style, {
      position: "absolute",
      inset: "0",
      zIndex: "500",
      pointerEvents: "none",
      overflow: "hidden",
    });
    ($(".app") || document.body).append(l);
  }
  return l;
};

/** 记录起点。传 <img> 或任意元素。 */
export function flipFrom(el: HTMLElement | null): FlipSource | null {
  if (!el) return null;
  const img = el.tagName === "IMG" ? (el as HTMLImageElement) : $<HTMLImageElement>("img", el);
  const box = (el.tagName === "IMG" ? el.parentElement : el) as HTMLElement;
  if (!box) return null;
  return {
    rect: box.getBoundingClientRect(),
    src: img?.currentSrc || img?.src || "",
    radius: getComputedStyle(box).borderRadius,
  };
}

const EMPH =
  "linear(0,.0169 4.5%,.075 9.1%,.2055 13.6%,.5333 18.2%,.7251 22.7%,.8081 27.3%,.8579 31.8%,.892 36.4%,.9169 40.9%,.9359 45.5%,.9506 50%,.9623 54.5%,.9716 59.1%,.979 63.6%,.9848 68.2%,.9895 72.7%,.9931 77.3%,.9958 81.8%,.9977 86.4%,.999 90.9%,.9998 95.5%,1)";

/** 飞到终点元素上。返回一个 Promise,动画完成后 resolve。 */
export async function flipTo(from: FlipSource | null, toEl: HTMLElement | null, { ms = 460 } = {}) {
  if (!from || !toEl) return;
  const layer = flipLayer();
  const lr = layer.getBoundingClientRect();
  const to = toEl.getBoundingClientRect();
  if (!to.width || !to.height) return;

  const toImg = $<HTMLImageElement>("img", toEl);
  const clone = document.createElement("div");
  Object.assign(clone.style, {
    position: "absolute",
    left: `${to.left - lr.left}px`,
    top: `${to.top - lr.top}px`,
    width: `${to.width}px`,
    height: `${to.height}px`,
    overflow: "hidden",
    borderRadius: "0px",
    transformOrigin: "0 0",
    willChange: "transform",
  });
  const layerImg = (src: string, o: number) => {
    const im = document.createElement("img");
    im.src = src;
    Object.assign(im.style, {
      position: "absolute",
      inset: "0",
      width: "100%",
      height: "100%",
      objectFit: "cover",
      opacity: String(o),
    });
    return im;
  };
  const a = layerImg(from.src, 1); // 源图:淡出
  const b = layerImg(toImg?.currentSrc || toImg?.src || from.src, 0); // 目标图:淡入
  clone.append(b, a);
  layer.append(clone);

  // Invert:把克隆盒变回起点的位置和尺寸(非等比)
  const sx = from.rect.width / to.width;
  const sy = from.rect.height / to.height;
  const dx = from.rect.left - to.left;
  const dy = from.rect.top - to.top;
  clone.style.transform = `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})`;
  clone.style.borderRadius = from.radius;
  toEl.style.opacity = "0";

  await raf();

  const mo = MO();
  const an = clone.animate(
    [
      { transform: clone.style.transform, borderRadius: from.radius },
      { transform: "translate(0,0) scale(1,1)", borderRadius: "0px" },
    ],
    { duration: ms * mo, easing: EMPH, fill: "both" },
  );
  // 交叉淡化在前 60% 完成 —— 拖到最后会看见"图突然换了一张"
  a.animate([{ opacity: 1 }, { opacity: 0 }], { duration: ms * mo * 0.6, easing: "linear", fill: "both" });
  b.animate([{ opacity: 0 }, { opacity: 1 }], { duration: ms * mo * 0.6, easing: "linear", fill: "both" });

  await an.finished.catch(() => {});
  toEl.style.opacity = "";
  clone.remove();
}

/* ---------- Toast ----------
   ★ 这是**全局命令式**的,不走 React state。原因:toast 的调用点遍布各页面
   (保存成功 / 网络失败 / 已加入下载),让每个页面自己持一份 toast state 是重复,
   而提到 App 顶层又要把 setToast 一路 prop 传下去。DOM 直挂最省。 */
export function toast(msg: string, kind: "" | "ok" | "bad" | "warn" = "") {
  const app = $(".app");
  if (!app) return null;
  let box = $(".toasts");
  if (!box) {
    box = document.createElement("div");
    box.className = "toasts";
    app.append(box);
  }
  const t = document.createElement("div");
  t.className = "toast" + (kind ? " " + kind : "");
  t.textContent = msg;
  box.append(t);
  // 时长随字数增加:一条 20 字的提示 3 秒读不完
  const ms = Math.min(6000, 2200 + msg.length * 90);
  setTimeout(() => {
    t.classList.add("out");
    t.addEventListener("animationend", () => t.remove(), { once: true });
  }, ms * MO());
  return t;
}

/* ---------- 长按菜单(= PC 的右键) ----------
   ★ 背板监听的是 **pointerdown 不是 click**;close() 只加 .out,
     节点等 animationend 才移除 —— 写探针判断"菜单还在不在"要看 `.menu:not(.out)`。 */
/** 菜单项。`icon` 收的是**真 DOM 节点**不是 React 元素 —— 这一层在 React 之外,
 *  调用点用 `app/icons.tsx` 的 `iconNode()` 把图标渲染成 SVG 节点再传进来。 */
export type MenuItem = "-" | { icon?: Node | null; label: string; bad?: boolean; on?: () => void };

export function menu(x: number, y: number, items: MenuItem[]) {
  const app = $(".app");
  if (!app) return () => {};
  const r = app.getBoundingClientRect();
  const scrim = document.createElement("div");
  scrim.className = "scrim";
  scrim.style.zIndex = "148";
  scrim.style.background = "transparent";

  const el = document.createElement("div");
  el.className = "menu";
  for (const it of items) {
    if (it === "-") {
      const sep = document.createElement("div");
      sep.className = "menu-sep";
      el.append(sep);
      continue;
    }
    const b = document.createElement("button");
    b.type = "button";
    if (it.bad) b.classList.add("bad");
    if (it.icon) b.append(it.icon);
    b.append(document.createTextNode(it.label));
    b.onclick = () => {
      haptic("tap");
      close();
      it.on?.();
    };
    el.append(b);
  }
  app.append(scrim, el);

  // 贴边处理:菜单不能出屏,而且变形原点要跟着走,否则动画看起来是从屏幕外长出来的
  const mw = el.offsetWidth;
  const mh = el.offsetHeight;
  const lx = Math.min(Math.max(8, x - r.left - mw / 2), r.width - mw - 8);
  let ly = y - r.top + 12;
  let oy = "0%";
  if (ly + mh > r.height - 12) {
    ly = y - r.top - mh - 12;
    oy = "100%";
  }
  el.style.left = `${lx}px`;
  el.style.top = `${ly}px`;
  el.style.setProperty("--ox", `${((x - r.left - lx) / mw) * 100}%`);
  el.style.setProperty("--oy", oy);

  const close = () => {
    el.classList.add("out");
    scrim.remove();
    el.addEventListener("animationend", () => el.remove(), { once: true });
  };
  scrim.addEventListener("pointerdown", close);
  return close;
}

/* ---------- 下拉刷新 ----------
   阈值 68px,阻尼 0.5,过阈震一下。★ 过阈的**那一刻**震,不是松手时震 ——
   松手才震的话用户不知道自己拉够了没有,只能拉到底赌一把。 */
export function pullRefresh(scroller: HTMLElement, onRefresh: () => void | Promise<void>) {
  const ind = document.createElement("div");
  ind.className = "pr-ind";
  ind.innerHTML = `<svg width="18" height="18" viewBox="0 0 24 24" fill="none"
    stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M12 5v14M5 12l7 7 7-7"/></svg>`;
  const host = scroller.parentElement;
  if (!host) return () => {};
  host.style.position = "relative";
  host.prepend(ind);
  const TH = 68;
  let act = false;
  let sy = 0;
  let d = 0;
  let armed = false;
  let busy = false;

  const down = (e: PointerEvent) => {
    if (busy || scroller.scrollTop > 0) return;
    act = true;
    sy = e.clientY;
    d = 0;
    armed = false;
  };
  const move = (e: PointerEvent) => {
    if (!act) return;
    if (scroller.scrollTop > 0) {
      act = false;
      ind.style.transform = "";
      ind.style.opacity = "";
      return;
    }
    const raw = e.clientY - sy;
    if (raw <= 0) {
      d = 0;
      ind.style.transform = "";
      ind.style.opacity = "";
      return;
    }
    d = raw * 0.5; // 阻尼 0.5
    ind.style.transform = `translateY(${Math.min(d, TH + 24)}px) rotate(${d * 3}deg)`;
    ind.style.opacity = String(Math.min(1, d / 40));
    if (!armed && d >= TH) {
      armed = true;
      haptic("sel");
      ind.style.borderColor = "var(--acc)";
    }
    if (armed && d < TH) {
      armed = false;
      ind.style.borderColor = "";
    }
    e.preventDefault();
  };
  const end = async () => {
    if (!act) return;
    act = false;
    if (!armed) {
      ind.style.transform = "";
      ind.style.opacity = "";
      return;
    }
    busy = true;
    armed = false;
    ind.classList.add("spin");
    ind.style.transform = `translateY(${TH}px)`;
    await onRefresh?.();
    await wait(320);
    ind.classList.remove("spin");
    ind.style.transform = "";
    ind.style.opacity = "";
    ind.style.borderColor = "";
    busy = false;
  };
  scroller.addEventListener("pointerdown", down);
  scroller.addEventListener("pointermove", move);
  scroller.addEventListener("pointerup", end);
  scroller.addEventListener("pointercancel", end);
  return () => {
    scroller.removeEventListener("pointerdown", down);
    scroller.removeEventListener("pointermove", move);
    scroller.removeEventListener("pointerup", end);
    scroller.removeEventListener("pointercancel", end);
    ind.remove();
  };
}

/* ---------- 上下栏随滚动方向显隐 ----------
   往下滑 = 在看内容 → 收起两条栏,把屏幕还给内容;
   往上滑 = 想找入口 → 立刻还回来。
   ★ 三条不做就会"抖":
     1. **阈值**:位移小于 8px 不算方向(手指的微小抖动会让它疯狂开关)
     2. **顶部豁免**:scrollTop < 48 时永远显示 —— 在顶部还藏着顶栏很怪
     3. **底部豁免**:滚到底时也显示,否则最后一屏永远看不到底栏
   ★ 只切一个 class,动画交给 CSS(transform + opacity),JS 不碰样式。 */
export function autoHideBars(
  scroller: HTMLElement,
  bars: Array<HTMLElement | null>,
  { threshold = 8, topSafe = 48 } = {},
) {
  let last = scroller.scrollTop;
  let hidden = false;
  let tick = false;
  const set = (v: boolean) => {
    if (v === hidden) return;
    hidden = v;
    bars.forEach((b) => b && b.classList.toggle("bar-off", v));
  };
  const onScroll = () => {
    if (tick) return;
    tick = true;
    requestAnimationFrame(() => {
      tick = false;
      const y = scroller.scrollTop;
      const dy = y - last;
      const atBottom = y + scroller.clientHeight >= scroller.scrollHeight - 24;
      if (y < topSafe || atBottom) {
        last = y;
        return set(false);
      }
      if (Math.abs(dy) < threshold) return;
      last = y;
      set(dy > 0);
    });
  };
  scroller.addEventListener("scroll", onScroll, { passive: true });
  return () => {
    scroller.removeEventListener("scroll", onScroll);
    set(false);
  };
}

/* ---------- 顶栏随滚动实体化 ----------
   一上来就画一条分隔线 = 首屏被无谓地切了一刀。滚起来才需要那条线。 */
export function topbarOnScroll(scroller: HTMLElement, topbar: HTMLElement) {
  let on = false;
  const onScroll = () => {
    const should = scroller.scrollTop > 12;
    if (should !== on) {
      on = should;
      topbar.classList.toggle("solid", on);
    }
  };
  scroller.addEventListener("scroll", onScroll, { passive: true });
  return () => scroller.removeEventListener("scroll", onScroll);
}

/* ============================================================
   播放器手势
   ★ 方向锁:第一次判定之后就锁死,中途不再改。不锁的话斜着划会在
     "进度"和"音量"之间反复横跳,数值乱蹦。
   ★ 判定阈值 12px:太小会把"点一下时手指的轻微抖动"当成滑动。
   ============================================================ */

export type GestureHooks = {
  getTime: () => number;
  getDuration: () => number;
  onStart?: (lock: "x" | "y", side: "l" | "r") => void;
  onSeekPreview?: (target: number, delta: number) => void;
  onSeekCommit?: (target: number) => void;
  onAdjust?: (what: "brightness" | "volume", ratio: number) => void;
  onDoubleTap?: (side: "l" | "r", count: number, x: number, y: number) => void;
  onSingleTap?: () => void;
  onBoost?: (on: boolean) => void;
  onEnd?: () => void;
};

export function playerGestures(el: HTMLElement, hooks: GestureHooks) {
  let id: number | null = null;
  let sx = 0;
  let sy = 0;
  let lock: "x" | "y" | null = null;
  let side: "l" | "r" = "r";
  let t0 = 0;
  let lastTap = 0;
  let tapSide = "";
  let tapCount = 0;
  let lp: ReturnType<typeof setTimeout> | null = null;
  let boosted = false;
  let baseTime = 0;
  let dxTotal = 0;
  let tapSeq = 0;
  const W = () => el.clientWidth;
  const H = () => el.clientHeight;

  const down = (e: PointerEvent) => {
    if (id !== null) return;
    id = e.pointerId;
    sx = e.clientX;
    sy = e.clientY;
    lock = null;
    t0 = performance.now();
    side = e.clientX - el.getBoundingClientRect().left < W() / 2 ? "l" : "r";
    baseTime = hooks.getTime();
    dxTotal = 0;
    lp = setTimeout(() => {
      boosted = true;
      haptic("ok");
      hooks.onBoost?.(true);
    }, 520);
  };

  const move = (e: PointerEvent) => {
    if (e.pointerId !== id) return;
    const dx = e.clientX - sx;
    const dy = e.clientY - sy;
    if (!lock) {
      if (Math.hypot(dx, dy) < 12) return;
      if (lp) clearTimeout(lp);
      lock = Math.abs(dx) > Math.abs(dy) ? "x" : "y";
      hooks.onStart?.(lock, side);
    }
    if (lock === "x") {
      // 1px ≈ 屏宽/120 秒。★ 用**总位移**算,不是逐帧累加 ——
      // 逐帧累加会因为浮点误差飘,来回划一圈回到原点时时间对不上。
      dxTotal = dx;
      const target = Math.max(
        0,
        Math.min(hooks.getDuration() || Infinity, baseTime + (dx / W()) * 120),
      );
      hooks.onSeekPreview?.(target, target - baseTime);
    } else {
      // 全程 = 屏高 70%。★ 增量式(用上一帧的差),不是绝对式 ——
      // 绝对式会在手指第一次动的瞬间把音量"跳"到手指所在的高度。
      const ratio = -(e.movementY || 0) / (H() * 0.7);
      hooks.onAdjust?.(side === "l" ? "brightness" : "volume", ratio);
    }
  };

  const up = (e: PointerEvent) => {
    if (e.pointerId !== id) return;
    if (lp) clearTimeout(lp);
    const dt = performance.now() - t0;
    if (boosted) {
      boosted = false;
      hooks.onBoost?.(false);
    } else if (!lock && dt < 320) {
      const now = performance.now();
      const s = side;
      if (now - lastTap < 300 && tapSide === s) {
        tapCount++; // 连点累加:+10 → +20 → +30
        hooks.onDoubleTap?.(s, tapCount, e.clientX, e.clientY);
      } else {
        tapCount = 1;
        tapSide = s;
        // 单击要等 300ms 才能确定不是双击的第一下。
        // ★ 这 300ms 延迟是双击手势的固有代价,不是 bug —— 但 OSD 显隐感觉不到,
        //   因为它本来就是"慢动作"。用在跳转上就会觉得迟钝。
        const my = ++tapSeq;
        setTimeout(() => {
          if (my === tapSeq) hooks.onSingleTap?.();
        }, 300);
      }
      lastTap = now;
    } else if (lock === "x") {
      const target = Math.max(
        0,
        Math.min(hooks.getDuration() || Infinity, baseTime + (dxTotal / W()) * 120),
      );
      hooks.onSeekCommit?.(target); // ★ 抬手才 seek 一次
    }
    hooks.onEnd?.();
    id = null;
    lock = null;
  };

  el.addEventListener("pointerdown", down);
  el.addEventListener("pointermove", move);
  el.addEventListener("pointerup", up);
  el.addEventListener("pointercancel", up);
  return () => {
    if (lp) clearTimeout(lp);
    el.removeEventListener("pointerdown", down);
    el.removeEventListener("pointermove", move);
    el.removeEventListener("pointerup", up);
    el.removeEventListener("pointercancel", up);
  };
}

/* ---------- 数字滚动(下载速度 / 进度百分比) ----------
   ★ 只给"变化不快"的数字。播放时间每秒变一次,滚动数字反而看不清。 */
export function tweenNum(
  el: HTMLElement,
  from: number,
  to: number,
  ms = 500,
  fmt: (v: number) => string | number = (v) => Math.round(v),
) {
  const t0 = performance.now();
  const d = ms * MO();
  const step = (t: number) => {
    const p = Math.min(1, (t - t0) / d);
    const e = 1 - Math.pow(1 - p, 3);
    el.textContent = String(fmt(from + (to - from) * e));
    if (p < 1) requestAnimationFrame(step);
  };
  requestAnimationFrame(step);
}
