/* ============================================================
   焦点原语 —— 全站的可聚焦项 / 横向行 / 纵向页 / 焦点边界都走这四个。

   为什么要自己包一层而不是各页直接用 useFocusable:
   「焦点移出可视区要把容器滚过去」这件事每个列表都要做,散着写必然有页忘记,
   而忘记的表现是**焦点看不见了但按键还在生效** —— 用户会以为遥控器坏了。

   ★ 库没有 onChildFocused 这种东西(我一开始就是这么写的,是错的)。
     官方的滚动模式是「父把 onFocus 回调传给子」。这里用 React context 传,
     省得每个页面手工把回调一层层往下递 —— 递漏一个就是一段不会滚的列表。
   ============================================================ */

import { createContext, useContext, useEffect, useRef, type ReactNode } from "react";
import { pushBackHandler } from "../app/focus";
import { scrollDeltaY } from "../app/scroll";
import {
  FocusContext,
  useFocusable,
  type FocusableComponentLayout,
} from "@noriginmedia/norigin-spatial-navigation";

/** 子项聚焦时通知所在的滚动容器。null = 不在任何滚动容器里(比如导航轨)。 */
const ScrollNotify = createContext<((node: HTMLElement) => void) | null>(null);

/** 焦点项与滚动容器边缘的最小距离(CSS px)。

    ★ 这个数不是"留白好看",是**硬约束**:焦点态会画到元素盒子外面 ——
      外发光环 12px + 白环 3px,再加 scale(1.06) 在最大卡(330dp)上溢出约 10px,
      合计 25px。容器是 overflow:hidden,焦点项只要贴边,这些就会被整齐切掉,
      看起来像"卡片边缘被页面挡住了"。32 = 25 + 7px 余量。

    ★ 为什么不用 overflow-clip-margin 把裁剪盒放大:试过,**放出了不该看见的东西** ——
      行滚动后上一张卡的残影会渗进左边空白。放大裁剪盒和藏住滚出内容本质冲突。 */
const FOCUS_PAD = 32;

const clamp = (v: number, lo: number, hi: number) => Math.max(lo, Math.min(hi, v));

/* ------------------------------------------------------------
   可聚焦项
   ------------------------------------------------------------ */

type ItemProps = {
  children: ReactNode;
  className?: string;
  /** 焦点类名。默认 `foc`,对应 tv.css 里全站唯一那套焦点态。 */
  focusClass?: string;
  onEnter?: () => void;
  /** **长按**确认键(遥控器上的 OK 按住不放)。给「长按卡片选择是否屏蔽」用
   *  (用户 2026-08-02:「移动端和TV端都是长按卡片选择是否屏蔽」)。
   *
   *  ★ 传了它,`onEnter` 就改成**松手才触发** —— 不然长按会先开详情页再弹屏蔽框。
   *    没传的行为一个字节都不变(按下即触发),全站其余几十个 FocusItem 不受影响。 */
  onLongEnter?: () => void;
  /** 本项获得焦点时。给「焦点走到倒数第二行就预取下一页」这类无限加载用 ——
   *  没有它就只能拿 IntersectionObserver + 一个量出来的魔数当近似。 */
  onFocus?: () => void;
  /** 本项**失去**焦点时。
   *  ★ 缺了它会写出「一次性开关」:首页 Hero 原来只在 onFocus 里 setHeld(true) 停掉轮播,
   *    而焦点离开 Hero 后没有任何人把它放回去 —— 自动轮播从此**永久停摆**,
   *    表现正是用户报的「随机推荐根本不会自动切换」。 */
  onBlur?: () => void;
  focusKey?: string;
  /** 不可聚焦(如不可用的版本卡):保留显示,但跳过焦点位。 */
  disabled?: boolean;
  style?: React.CSSProperties;
  /** 挂载时抢焦点。一页只该有一个。 */
  autoFocus?: boolean;
};

/** 长按判定阈值(毫秒)。500 太容易误触(遥控器 OK 键行程长,手指会多停一下),
 *  800 又要按到心里发毛。600 是 Android 的 ViewConfiguration.getLongPressTimeout()
 *  默认值 500 往上加一档 —— 沙发上按遥控器比手指点屏幕慢。 */
const LONG_PRESS_MS = 600;

export function FocusItem({
  children,
  className = "",
  focusClass = "foc",
  onEnter,
  onLongEnter,
  onFocus,
  onBlur,
  focusKey,
  disabled,
  style,
  autoFocus,
}: ItemProps) {
  const notify = useContext(ScrollNotify);
  const host = useRef<HTMLDivElement | null>(null);
  /* 存进 ref 再用:调用方几乎都传的是内联箭头函数,每次渲染换个身份。
     直接交给库的 onBlur 会让它反复注销重注册,快速重渲染时会漏掉一次回调。 */
  const blurRef = useRef(onBlur);
  blurRef.current = onBlur;

  /* ── 长按确认键 ──
     norigin 的 onEnterPress 在**按键自动重复**时会一直发(它把重复次数记在
     pressedKeys 里),onEnterRelease 只在松手时发一次。所以:
       第一次按下 → 起 600ms 定时器;定时器到 → 长按动作,并标记「这一次已经处理过」;
       松手     → 撤定时器;没被长按吃掉的话才当短按。
     ★ 定时器句柄必须放 ref:放 state 的话重渲染就丢了句柄,到点没人清。 */
  const enterRef = useRef(onEnter);
  enterRef.current = onEnter;
  const longRef = useRef(onLongEnter);
  longRef.current = onLongEnter;
  const holdTimer = useRef<number | null>(null);
  const handled = useRef(false);
  useEffect(() => () => { if (holdTimer.current) window.clearTimeout(holdTimer.current); }, []);

  const pressHandlers = onLongEnter
    ? {
        onEnterPress: () => {
          if (holdTimer.current) return; // 自动重复的那几发,不重复起表
          handled.current = false;
          holdTimer.current = window.setTimeout(() => {
            holdTimer.current = null;
            handled.current = true;
            longRef.current?.();
          }, LONG_PRESS_MS);
        },
        onEnterRelease: () => {
          if (holdTimer.current) {
            window.clearTimeout(holdTimer.current);
            holdTimer.current = null;
          }
          if (!handled.current) enterRef.current?.();
        },
      }
    : { onEnterPress: onEnter };

  const { ref, focused, focusSelf } = useFocusable<object, HTMLDivElement>({
    focusable: !disabled,
    focusKey,
    ...pressHandlers,
    onBlur: () => blurRef.current?.(),
    onFocus: (layout: FocusableComponentLayout) => {
      notify?.(layout.node as HTMLElement);
      onFocus?.();
    },
  });

  useEffect(() => {
    if (autoFocus && !disabled) focusSelf();
  }, [autoFocus, disabled, focusSelf]);

  return (
    <div
      ref={(n) => {
        host.current = n;
        (ref as React.MutableRefObject<HTMLDivElement | null>).current = n;
      }}
      style={style}
      className={`${className} ${focused ? focusClass : ""}`.trim()}
    >
      {children}
    </div>
  );
}

/* ------------------------------------------------------------
   输入框:**焦点框就是输入框**
   ------------------------------------------------------------

   ★ 这一版推翻了原来的两段式(先 FocusItem 选中,按确认才把 DOM 焦点转给里面的
     <input>,期间 pause() 掉整个焦点库,再按确认/返回退出输入态)。那套的问题不是不能用,
     是**它把"选中"和"输入"做成了两件事**:
       - 高亮画在外面那个 div 上,里面才是真输入框 —— 看着就是两个盒子;
       - 进了输入态整个焦点库停摆,上下键失效 → 想先填密码再填地址得先退出、再走位;
       - 顺序被隐式钉死成"从上往下一路填",而先填哪个本该由用户定。

   ★ 现在:登记进焦点树的**就是 <input> 本身**,焦点走到它身上 DOM 焦点同步跟上
     (系统 IME 随之升起,不用按确认),上下键照常在字段间走 —— 想先填哪个填哪个。
     左右/退格这些编辑键在 input 上 stopPropagation 截住,不让焦点库拿去挪焦点
     (库是 window 冒泡阶段监听,截得住;SearchPage 早就靠这条拦 Escape)。 */

type InputProps = {
  value: string;
  onChange: (v: string) => void;
  placeholder?: string;
  password?: boolean;
  autoFocus?: boolean;
  focusKey?: string;
  className?: string;
  style?: React.CSSProperties;
  /** 确认键。给"填完直接连接/搜索"用。 */
  onEnter?: () => void;
  /** 失焦提交(设置页那种改完即存的行)。焦点一离开就调。 */
  onCommit?: (v: string) => void;
  inputMode?: "text" | "url" | "numeric";
};

export function FocusInput({
  value,
  onChange,
  placeholder,
  password,
  autoFocus,
  focusKey,
  className = "",
  style,
  onEnter,
  onCommit,
  inputMode,
}: InputProps) {
  const notify = useContext(ScrollNotify);
  const el = useRef<HTMLInputElement | null>(null);
  const commitRef = useRef(onCommit);
  commitRef.current = onCommit;

  const { ref, focused, focusSelf } = useFocusable<object, HTMLInputElement>({
    focusKey,
    /* 不接 onEnterPress:确认键在下面的 onKeyDown 里就被 stopPropagation 截住了,
       库根本收不到 —— 两边都接就是提交两次。 */
    onFocus: (layout: FocusableComponentLayout) => notify?.(layout.node as HTMLElement),
  });

  useEffect(() => {
    if (autoFocus) focusSelf();
  }, [autoFocus, focusSelf]);

  /* DOM 焦点跟着虚拟焦点走 —— 这就是"焦点框即输入框"。
     离开时 blur 并提交:不 blur 的话 Android 的输入法会一直悬在屏幕下半部分,
     焦点已经走到别的字段了键盘还对着上一个,比不升起更糟。 */
  useEffect(() => {
    const n = el.current;
    if (!n) return;
    if (focused) {
      if (document.activeElement !== n) n.focus();
    } else if (document.activeElement === n) {
      n.blur();
      commitRef.current?.(n.value);
    }
  }, [focused]);

  /* 正在输入时整页被拆掉(按返回退页/切设置分类):上面那条走不到,改动会静默丢。
     清理函数跑在 DOM 摘除**之前**,所以 activeElement 还指着自己 —— 拿它当判据,
     和 blur 那条互斥,不会提交两次。 */
  useEffect(
    () => () => {
      const n = el.current;
      if (n && document.activeElement === n) commitRef.current?.(n.value);
    },
    [],
  );

  return (
    <input
      ref={(n) => {
        el.current = n;
        (ref as React.MutableRefObject<HTMLInputElement | null>).current = n;
      }}
      className={`${className} ${focused ? "foc" : ""}`.trim()}
      style={style}
      type={password ? "password" : "text"}
      inputMode={inputMode}
      autoCapitalize="off"
      autoComplete="off"
      value={value}
      placeholder={placeholder}
      onChange={(e) => onChange(e.target.value)}
      onKeyDown={(e) => {
        /* 上下 = 换字段(放给焦点库);左右/编辑键 = 移光标改字(在这儿截住)。 */
        switch (e.key) {
          case "ArrowLeft":
          case "ArrowRight":
          case "Home":
          case "End":
          case "Backspace":
          case "Delete":
            e.stopPropagation();
            break;
          case "Enter":
            e.stopPropagation();
            onEnter?.();
            break;
          default:
            break; // Escape 放行:返回键该退页,不该被输入框吃掉
        }
      }}
    />
  );
}

/* ------------------------------------------------------------
   横向行
   ------------------------------------------------------------ */

/** 平移而不是 scrollLeft —— scrollLeft 在机顶盒 WebView 上触发整层重绘,
 *  transform 走合成器。差别在弱机上肉眼可见。 */
export function FocusRow({
  children,
  className = "",
  trackClass = "track breathe",
  focusKey,
}: {
  children: ReactNode;
  className?: string;
  trackClass?: string;
  focusKey?: string;
}) {
  const trackRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<HTMLDivElement>(null);
  /* ★ 行套在列里时,子项只能看见**最近的**那个 ScrollNotify(也就是本行的)。
     不往上冒的话:行内左右滚得好好的,但整行永远不会被带进视野 ——
     往下走几行之后焦点跑到屏幕外,按键还在生效,用户以为遥控器坏了。
     (这正是我在本文件开头写的那个失败模式,自己先踩了一遍。) */
  const outerNotify = useContext(ScrollNotify);

  const { ref, focusKey: fk } = useFocusable<object, HTMLDivElement>({
    focusKey,
    saveLastFocusedChild: true,
    trackChildren: true,
    /* ★ 容器**必须保持 focusable(默认 true)**,不能设 false。
       库的方向导航只在「同一个 parent 下 focusable 的兄弟」里找目标
       (smartNavigate 的 siblings 过滤器带 component.focusable),
       容器设 false 就从候选里被剔掉 → **焦点永远进不去这一行**。
       落到容器上时库会自己往下钻到子项(lastFocusedChild / preferredChild)。
       实测过:设了 false 之后按↓完全不动,而截图上一点都看不出来。 */
  });

  const notify = (node: HTMLElement) => {
    const track = trackRef.current;
    const view = viewRef.current;
    if (!track || !view) return;
    const viewR = view.getBoundingClientRect();
    /* ★ 整行装得下就一步都别挪。
       下面那条"聚焦第一项时整行右推 FOCUS_PAD 露出焦点环"只对**滚得动**的行成立;
       行宽正好等于视口时(播放页底栏有 .spring 撑满,正是这种),右推 32px 就把
       最右那个按钮(「更多」)顶出 .hscroll 的 overflow:hidden —— 实测切掉 32px。
       装得下 = 没有滚动这回事,焦点环的空间由 .vscroll 的横向外扩负责。 */
    if (track.getBoundingClientRect().width <= viewR.width) {
      outerNotify?.(node);
      return;
    }
    const r = node.getBoundingClientRect();
    const left = r.left - viewR.left;
    const cur = readTranslate(track, "X");
    const z = zoomOf(view); // gBCR 是设备 px,transform 是 CSS px,必须换算
    const PAD = FOCUS_PAD * z;
    let delta = 0;
    if (left < PAD) delta = left - PAD;
    else if (left + r.width > viewR.width - PAD)
      delta = left + r.width - viewR.width + PAD;
    if (delta !== 0)
      /* ★ 上界是 +FOCUS_PAD 而不是 0 —— 这一条就是"边缘卡片被裁"的解法。
         钳到 0 的话第一张卡永远贴着容器左边,它的焦点环和放大出来的边
         正好落在 overflow:hidden 的边界外被切掉(实测裁左 15.1px)。
         允许正向位移,聚焦第一张时整行右推一点点,环就完整露出来了。 */
      track.style.transform = `translateX(${clamp(cur - delta / z, -1e7, FOCUS_PAD)}px)`;
    /* 继续往外层冒:让包着这一行的纵向列把整行滚进视野。 */
    outerNotify?.(node);
  };

  return (
    <FocusContext.Provider value={fk}>
      <ScrollNotify.Provider value={notify}>
        <div ref={ref}>
          <div ref={viewRef} className={`hscroll ${className}`.trim()}>
            <div ref={trackRef} className={trackClass}>
              {children}
            </div>
          </div>
        </div>
      </ScrollNotify.Provider>
    </FocusContext.Provider>
  );
}

/* ------------------------------------------------------------
   纵向页
   ------------------------------------------------------------ */

export function FocusColumn({
  children,
  className = "",
  focusKey,
  /** 顶部固定区高度(页标题不跟着滚)。 */
  topPad = 0,
  /** 关掉滚动层,只保留焦点分组。
   *
   *  ★ 为什么需要:滚动层是 `.vscroll`(overflow:hidden) + `.inner`(位移 + will-change),
   *    对**内容本来就装得下**的地方是纯粹的负担,而且会静默出两种事故:
   *      1. `.inner` 带 will-change 就成了绝对定位后代的**包含块**,子元素若是
   *         out-of-flow,`.inner` 还会塌成 0 高 —— 播放页底栏因此被算到屏幕上方 200px。
   *      2. 行里那对 `.hscroll{padding:32px 0;margin:-32px 0}` 让 `.inner` 比 `.vscroll`
   *         凭空高 32px,于是"滚"了一下,把上面的进度条顶出裁剪盒(实测 9 个焦点位全没)。
   *    两条都表现为"东西不见了"且毫无报错。装得下的地方就别上滚动层。 */
  scroll = true,
}: {
  children: ReactNode;
  className?: string;
  focusKey?: string;
  topPad?: number;
  scroll?: boolean;
}) {
  const innerRef = useRef<HTMLDivElement>(null);
  const viewRef = useRef<HTMLDivElement>(null);
  const outerNotify = useContext(ScrollNotify);

  const { ref, focusKey: fk } = useFocusable<object, HTMLDivElement>({
    focusKey,
    saveLastFocusedChild: true,
    trackChildren: true,
  });

  const notify = (node: HTMLElement) => {
    const inner = innerRef.current;
    const view = viewRef.current;
    if (!inner || !view) return;
    const viewR = view.getBoundingClientRect();
    const r = node.getBoundingClientRect();
    const cur = readTranslate(inner, "Y");
    const z = zoomOf(view);
    const PAD = FOCUS_PAD * z; // 焦点项上下留呼吸位,否则光晕贴边被祖先 overflow 裁掉

    /* ★ 往上走时对齐的是**整段**,不是那一个焦点项。

       原来两个方向都只保证「焦点项自己露出来」,于是从下面的行往上回到 Hero 时,
       滚动停在「播放按钮顶端 + 32px」—— 按钮上方那 400 多 px 的封面全在视野外。
       用户的原话是「从下往上一滑就缺失内容」:内容没丢,是滚过头了。行也一样,
       停在卡片顶端就把行标题(「继续观看」)切在外面,整页看着像少了一截。

       段 = `.inner` 的直接子元素(一个 Hero / 一行 / 详情页的一块)。往上对齐它的顶,
       往下仍按焦点项的底 —— 段可能比整屏还高(Hero 486px),往下也按段底会直接翻过头。 */
    const sec = sectionOf(node, inner);
    const delta = scrollDeltaY({
      top: r.top - viewR.top,
      height: r.height,
      secTop: (sec ?? node).getBoundingClientRect().top - viewR.top,
      firstSection: !!sec && sec === inner.firstElementChild,
      viewH: viewR.height,
      topPad: topPad * z,
      pad: PAD,
    });
    if (delta !== 0)
      // 同上:上界是 +FOCUS_PAD,否则最上面一行的焦点环被 .vscroll 顶边切掉
      inner.style.transform = `translateY(${clamp(cur - delta / z, -1e7, FOCUS_PAD)}px)`;
    /* 嵌套时(行在列里)继续往上冒 —— 否则横向行会滚,但那一整行不会被带进视野。 */
    outerNotify?.(node);
  };

  if (!scroll)
    return (
      <FocusContext.Provider value={fk}>
        {/* 通知直接往外层传:自己不滚,但套在别人里面时那一层还得能滚。 */}
        <ScrollNotify.Provider value={outerNotify}>
          <div ref={ref} className={className}>
            {children}
          </div>
        </ScrollNotify.Provider>
      </FocusContext.Provider>
    );

  return (
    <FocusContext.Provider value={fk}>
      <ScrollNotify.Provider value={notify}>
        <div ref={ref} style={{ height: "100%" }}>
          <div
            ref={viewRef}
            className={`vscroll ${className}`.trim()}
            style={{ height: "100%" }}
          >
            <div ref={innerRef} className="inner">
              {children}
            </div>
          </div>
        </div>
      </ScrollNotify.Provider>
    </FocusContext.Provider>
  );
}

/* ------------------------------------------------------------
   焦点边界:面板 / 对话框打开时,焦点不许跑到底下的页面上
   ------------------------------------------------------------ */

/** ★ 只写 isFocusBoundary 不生效,必须同时套 FocusContext.Provider ——
 *  这是 norigin 最容易漏的一条,漏了的表现是「面板开着,按左却选中了背后的卡片」。 */
export function FocusBoundary({
  children,
  focusKey,
  className,
  style,
  onBack,
}: {
  children: ReactNode;
  focusKey?: string;
  className?: string;
  style?: React.CSSProperties;
  /** 返回键:关掉这个面板。**传了它,返回键就不会再穿透去退页面**。
   *  不传的话按返回会直接退出整个页面 —— 用户只想关面板,结果回上一页了。 */
  onBack?: () => void;
}) {
  const { ref, focusKey: fk, focusSelf } = useFocusable<object, HTMLDivElement>({
    focusKey,
    isFocusBoundary: true,
    saveLastFocusedChild: true,
    trackChildren: true,
  });

  useEffect(() => {
    focusSelf();
  }, [focusSelf]);

  /* 挂载期间占住返回键最内层。用 ref 存回调,避免调用方每次渲染换个函数身份
     就把处理器反复注销重注册(那样在快速重渲染时会漏掉一次按键)。 */
  const backRef = useRef(onBack);
  backRef.current = onBack;
  useEffect(() => {
    if (!onBack) return;
    return pushBackHandler(() => {
      backRef.current?.();
      return true;
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [!onBack]);

  return (
    <FocusContext.Provider value={fk}>
      {/* 面板内部自带滚动,复用纵向列的通知机制 */}
      <div ref={ref} className={className} style={style}>
        {children}
      </div>
    </FocusContext.Provider>
  );
}

/* ---- 小工具 ---- */

/** 焦点项所属的「段」= 滚动内容 `inner` 的那个直接子元素。
 *  焦点项不在 inner 里(理论上不该发生)时返回 null,调用方退回按焦点项自己算。 */
export function sectionOf(node: HTMLElement, inner: HTMLElement): HTMLElement | null {
  let cur: HTMLElement | null = node;
  while (cur && cur.parentElement !== inner) cur = cur.parentElement;
  return cur;
}

function readTranslate(el: HTMLElement, axis: "X" | "Y"): number {
  const m = new RegExp(`translate${axis}\\((-?[\\d.]+)px\\)`).exec(el.style.transform);
  return m ? parseFloat(m[1]) : 0;
}

/** 当前 zoom 系数。

    ★ 这个换算不能省。`.tv-app` 用 zoom 把 1920 版式缩到实际屏幕,于是:
      - `getBoundingClientRect()` 返回的是**缩放后的设备 px**(1920 的元素量出来 1175)
      - `style.transform = translateY(Npx)` 里的 N 却是**未缩放的 CSS px**
      两者直接相减再赋值,滚动距离就只有该走的 61%,表现是
      「能滚,但焦点项永远差一点点露不全」—— 比完全不滚更难发现。

    库自己的方向判定不受影响:它全程用 gBCR,同一套坐标系里比大小,等比缩放不改变相对关系。
    只有**我们把测量结果写回 transform** 这一步需要换算回去。 */
function zoomOf(el: HTMLElement): number {
  const app = el.closest(".tv-app") as HTMLElement | null;
  const z = app ? parseFloat(getComputedStyle(app).zoom || "1") : 1;
  return Number.isFinite(z) && z > 0 ? z : 1;
}
