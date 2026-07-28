import { useEffect, useRef, useState, type ReactNode } from "react";
import { type Item, type LoginResult, itemLabel, posterUrl, thumbUrl } from "@shared/api";
import { Icon } from "../app/icons";
import { haptic, longPress, press } from "../app/motion";

/* 共用组件词汇 —— 草稿 `ui.js` 的 React 版。
   所有页面只能用这里的原语拼,不许各页自造一套 —— 散着写必然长出两套间距
   (这条在 PC 端和 TV 端都栽过)。 */

/* ============================================================
   两个手势 hook
   ============================================================ */

/** 按压反馈。★ 不用 `:active` —— 安卓 WebView 上 `:active` 在滚动开始后
 *  **不会**及时移除,表现是"滑一下,某张卡就一直保持按下的样子"。 */
export function usePress<T extends HTMLElement>(opts?: { rip?: boolean }) {
  const ref = useRef<T>(null);
  const rip = opts?.rip;
  useEffect(() => {
    if (!ref.current) return;
    return press(ref.current, { rip });
  }, [rip]);
  return ref;
}

/** 长按 = PC 的右键。回调放 ref 里,免得每次 render 都重挂一遍监听。 */
export function useLongPress<T extends HTMLElement>(cb?: (e: PointerEvent) => void) {
  const ref = useRef<T>(null);
  const cbRef = useRef(cb);
  cbRef.current = cb;
  useEffect(() => {
    if (!ref.current || !cbRef.current) return;
    return longPress(ref.current, (e) => cbRef.current?.(e));
  }, []);
  return ref;
}

/** 按压 + 长按挂同一个元素。分开挂两个 ref 会互相覆盖。 */
export function useCardGestures<T extends HTMLElement>(onLong?: (e: PointerEvent) => void) {
  const ref = useRef<T>(null);
  const cbRef = useRef(onLong);
  cbRef.current = onLong;
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const offPress = press(el);
    const offLong = cbRef.current ? longPress(el, (e) => cbRef.current?.(e)) : undefined;
    return () => {
      offPress();
      offLong?.();
    };
  }, []);
  return ref;
}

/* ============================================================
   海报卡
   ★ 卡片不能单调(Emby 被喷得最多的一条)。一张卡最多同时表达五件事:
     封面 / 角标 / 未看集数 or 看完打勾 / 观看进度 / 长按菜单。
   ============================================================ */

/** 封面右上角的角标口径(用户 2026-07-28 定):
 *    剧集 → **未看集数**;全看完 → 打勾
 *    电影 → **评分**
 *    画质标签(4K/DV)**整个去掉** —— 用户原话:"没人会为了参数去看一部烂片"
 *
 *  ★ 角标要**小**(字号 10、内边距 3/5)—— 它压在封面上,大一分就多毁一分画面。 */
function Badge({ it }: { it: Item }) {
  if (it.is_folder || it.type_ === "Series") {
    if (it.unplayed_item_count > 0) {
      return <div className="b-ep">{it.unplayed_item_count > 99 ? "99+" : it.unplayed_item_count}</div>;
    }
    if (it.played) {
      return (
        <div className="b-ep done">
          <Icon n="check" size={11} />
        </div>
      );
    }
    return null;
  }
  if (it.rating != null && it.rating > 0) return <div className="b-rate">{it.rating.toFixed(1)}</div>;
  return null;
}

export type CardProps = {
  item: Item;
  session: LoginResult;
  variant?: "poster" | "thumb";
  onOpen: (it: Item, el: HTMLElement | null) => void;
  /** 长按。不传 = 不响应长按(比如跨服搜索结果,对错服务器写操作是真会写错) */
  onLongPress?: (it: Item, e: PointerEvent) => void;
  /** 入场阶梯下标。**只给首屏传** */
  index?: number;
  /** 不画卡片外的文字(媒体库轨道:海报本身就带片名,再写一遍是冗余) */
  noCap?: boolean;
  /** 第二行文字。给了就用它,否则:剧集写 SxxExx、其它写年份 */
  sub?: string;
};

export function Card({ item, session, variant = "poster", onOpen, onLongPress, index = 0, noCap, sub }: CardProps) {
  const isThumb = variant === "thumb";
  const [loaded, setLoaded] = useState(false);
  const aRef = useCardGestures<HTMLDivElement>(onLongPress ? (e) => onLongPress(item, e) : undefined);

  const progress =
    !item.is_folder && item.resume_secs > 0 && item.runtime_secs > 0
      ? Math.min(1, item.resume_secs / item.runtime_secs)
      : 0;

  const cap = item.series_name || itemLabel(item);
  const second =
    sub ??
    (item.series_name
      ? `S${item.season_no ?? 1}E${item.episode_no ?? 1}`
      : item.year
        ? String(item.year)
        : "");

  return (
    <div className={`card${isThumb ? " thumb" : ""}`} style={{ ["--i" as string]: index }}>
      <div
        className={`card-a ${isThumb ? "ar-thumb" : "ar-poster"}`}
        ref={aRef}
        onClick={() => onOpen(item, aRef.current)}
      >
        {/* 骨架:图片没到位时占住这块。没有它的话快速下滑是一片白,
            看着像"页面没加载出来" —— 而文字和角标其实早就在了。
            ★ 图到位后延后 150ms 再撤:立刻撤会在图还没完成第一次绘制时露出底色,
              那一帧就是"闪白"。 */}
        {item.has_primary && !loaded && <div className="skel" />}
        {item.has_primary ? (
          <img
            src={isThumb ? thumbUrl(session, item.id, 480) : posterUrl(session, item.id, 360)}
            alt=""
            /* lazy:屏幕外的卡不发请求(一条轨道 20 张,可见的只有 3 张)。
               async:解码不挡主线程 —— 手机 CPU 上这一条比桌面重要得多。 */
            loading="lazy"
            decoding="async"
            onLoad={(e) => {
              (e.target as HTMLImageElement).classList.add("ready");
              setTimeout(() => setLoaded(true), 150);
            }}
            onError={(e) => {
              setLoaded(true); // 失败也要撤骨架,否则永远是块灰
              (e.target as HTMLImageElement).style.opacity = "0";
            }}
          />
        ) : (
          <div className="mfallback">
            <Icon n={item.is_folder ? "grid" : "play"} size={22} />
          </div>
        )}

        <Badge it={item} />

        {progress > 0 && (
          <div className="prog">
            <i style={{ transform: `scaleX(${progress})` }} />
          </div>
        )}
      </div>
      {!noCap && <div className="card-cap">{cap}</div>}
      {!noCap && second ? <div className="card-sub">{second}</div> : null}
    </div>
  );
}

/* ---------- 横滑轨道 ---------- */

export function Row({
  title,
  items,
  session,
  variant = "poster",
  onOpen,
  onLongPress,
  onMore,
  skeleton = 0,
  noCap,
}: {
  title?: string;
  items?: Item[];
  session: LoginResult;
  variant?: "poster" | "thumb";
  onOpen: (it: Item, el: HTMLElement | null) => void;
  onLongPress?: (it: Item, e: PointerEvent) => void;
  onMore?: () => void;
  /** >0 = 画骨架轨道(数据还没到)。**不要画成空轨道** —— 空的看着像"这个库是空的" */
  skeleton?: number;
  noCap?: boolean;
}) {
  const moreRef = usePress<HTMLButtonElement>();
  return (
    <div className="row">
      <div className="row-hd">
        {skeleton ? (
          <div className="skel-line" style={{ width: 104, height: 16 }} />
        ) : (
          <h2>{title}</h2>
        )}
        {onMore && !skeleton ? (
          <button type="button" className="row-more" ref={moreRef} onClick={onMore}>
            更多
            <Icon n="chevR" size={15} />
          </button>
        ) : null}
      </div>
      <div className="row-scroll">
        {skeleton
          ? Array.from({ length: 4 }, (_, i) => (
              <div className={`card${variant === "thumb" ? " thumb" : ""}`} key={i}>
                <div className={`card-a ${variant === "thumb" ? "ar-thumb" : "ar-poster"}`}>
                  <div className="skel" />
                </div>
                <div className="skel-line" style={{ marginTop: 8, width: "78%" }} />
              </div>
            ))
          : items?.map((it, i) => (
              <Card
                key={it.id}
                item={it}
                session={session}
                variant={variant}
                index={i}
                onOpen={onOpen}
                onLongPress={onLongPress}
                noCap={noCap}
              />
            ))}
      </div>
    </div>
  );
}

/* ---------- 网格 ----------
   ★ 不用 `grid-template-columns: repeat(3,1fr)`:那样卡片宽度会跟着容器变,
     同一张卡在首页轨道里和在网格里是两个尺寸。改成 flex-wrap + 卡片保持自己的固定宽度。 */
export function Grid({
  items,
  session,
  variant = "poster",
  onOpen,
  onLongPress,
}: {
  items: Item[];
  session: LoginResult;
  variant?: "poster" | "thumb";
  onOpen: (it: Item, el: HTMLElement | null) => void;
  onLongPress?: (it: Item, e: PointerEvent) => void;
}) {
  return (
    <div className="grid">
      {items.map((it, i) => (
        <Card
          key={it.id}
          item={it}
          session={session}
          variant={variant}
          index={i}
          onOpen={onOpen}
          onLongPress={onLongPress}
        />
      ))}
    </div>
  );
}

/* ---------- 空态 / 错误态 ----------
   ★ 空态必须说人话:说清「是什么空了」+「怎么才能不空」。
     曾经排行榜整屏白板一个字都没有,根因是代码落进了 `{busy ? "加载中…" : ""}` 分支。 */
export function Empty({
  icon = "inbox",
  title,
  desc,
  action,
}: {
  icon?: string;
  title: string;
  desc?: ReactNode;
  action?: { label: string; on: () => void };
}) {
  const btn = usePress<HTMLButtonElement>();
  return (
    <div className="empty">
      <div className="empty-ic">
        <Icon n={icon} size={28} />
      </div>
      <b>{title}</b>
      {desc ? <div className="dim">{desc}</div> : null}
      {action ? (
        <button type="button" className="btn" ref={btn} onClick={action.on}>
          {action.label}
        </button>
      ) : null}
    </div>
  );
}

/* ---------- 设置类单元格 ---------- */

export function Switch({ on }: { on: boolean }) {
  return (
    <span className={`sw${on ? " on" : ""}`}>
      <i />
    </span>
  );
}

export function Cell({
  icon,
  label,
  value,
  sub,
  arrow = true,
  sw,
  onClick,
  onLongPress,
  danger,
}: {
  icon?: string;
  label: ReactNode;
  /** 右侧显示的当前值(点进去改) */
  value?: ReactNode;
  sub?: ReactNode;
  arrow?: boolean;
  /** 给了就画开关。onClick 收到的是**切换后**的值 */
  sw?: boolean;
  onClick?: (next: boolean) => void;
  onLongPress?: (e: PointerEvent) => void;
  danger?: boolean;
}) {
  const ref = useCardGestures<HTMLButtonElement>(onLongPress);
  return (
    <button
      type="button"
      className={`cell${danger ? " danger" : ""}`}
      ref={ref}
      onClick={() => {
        if (sw !== undefined) haptic("sel");
        onClick?.(!sw);
      }}
    >
      {icon ? (
        <span className="cell-i">
          <Icon n={icon} size={21} />
        </span>
      ) : null}
      <span className="cell-l">
        <div>{label}</div>
        {sub ? <div style={{ fontSize: 12, color: "var(--fg-3)", marginTop: 2 }}>{sub}</div> : null}
      </span>
      {value ? <span className="cell-s">{value}</span> : null}
      {sw !== undefined ? (
        <Switch on={sw} />
      ) : arrow ? (
        <span className="cell-arrow">
          <Icon n="chevR" size={18} />
        </span>
      ) : null}
    </button>
  );
}

/* ============================================================
   就地调节的三个原语
   ★ 选项少 / 数值型的东西**不该开二次弹窗**。「点开 → 选 → 关掉」三步
     只为把「中」改成「大」,那是白走两步。sheet 只留给两种情况:
       ① 选项多且互斥(超分十几档、语言列表、路径)
       ② 需要填表(正则、自建源)
     PC 端用的就是 Seg + Stepper 就地生效,这里不该退步成弹窗。
   ============================================================ */

function CrowHead({
  icon,
  label,
  sub,
  right,
}: {
  icon?: string;
  label: ReactNode;
  sub?: ReactNode;
  right?: ReactNode;
}) {
  return (
    <div className="crow-h">
      {icon ? (
        <span className="cell-i">
          <Icon n={icon} size={21} />
        </span>
      ) : null}
      <div className="crow-t">
        <div>{label}</div>
        {sub ? <div className="crow-s">{sub}</div> : null}
      </div>
      {right ?? null}
    </div>
  );
}

/** 分段控件 —— 2~4 个互斥选项,一步切完 */
export function SegRow<T extends string>({
  icon,
  label,
  sub,
  options,
  cur,
  onPick,
}: {
  icon?: string;
  label: ReactNode;
  sub?: ReactNode;
  options: readonly T[];
  cur: T;
  onPick: (v: T) => void;
}) {
  return (
    <div className="crow">
      <CrowHead icon={icon} label={label} sub={sub} />
      <div className="seg">
        {options.map((name) => (
          <button
            key={name}
            type="button"
            className={name === cur ? "on" : undefined}
            onClick={() => {
              if (name === cur) return;
              haptic("sel");
              onPick(name);
            }}
          >
            {name}
          </button>
        ))}
      </div>
    </div>
  );
}

/** 步进器 —— 有明确步长的数值(倍速 0.25 / 线程数 1 / 缓存翻倍) */
export function StepRow({
  icon,
  label,
  sub,
  value,
  min,
  max,
  step = 1,
  fmt = String,
  onChange,
}: {
  icon?: string;
  label: ReactNode;
  sub?: ReactNode;
  value: number;
  min: number;
  max: number;
  step?: number;
  fmt?: (v: number) => string;
  onChange: (v: number) => void;
}) {
  const bump = (d: number) => {
    // 浮点步长(0.25)直接加会攒出 1.7500000000000002,固定小数位收掉
    const nv = Math.min(max, Math.max(min, +(value + d * step).toFixed(4)));
    if (nv === value) return;
    haptic("sel");
    onChange(nv);
  };
  return (
    <div className="crow">
      <CrowHead
        icon={icon}
        label={label}
        sub={sub}
        right={
          <div className="stepper">
            {/* 到头了就把按钮禁掉 —— 不禁的话用户会一直点,还以为是没反应 */}
            <button type="button" aria-label="减少" disabled={value <= min} onClick={() => bump(-1)}>
              <Icon n="minus" size={18} />
            </button>
            <span className="v">{fmt(value)}</span>
            <button type="button" aria-label="增加" disabled={value >= max} onClick={() => bump(1)}>
              <Icon n="plus" size={18} />
            </button>
          </div>
        }
      />
    </div>
  );
}

/** 滑块 —— 连续值(透明度 / 模糊强度),拖着看实时变化比点列表直观。
 *  ★ 拖动期间只更新本地显示,`change`(松手)才回调 —— 每帧一次 invoke
 *    会把命令队列灌满,那是"拖着拖着卡住"的来源。 */
export function SliderRow({
  icon,
  label,
  sub,
  value,
  min,
  max,
  step = 1,
  fmt = String,
  onChange,
}: {
  icon?: string;
  label: ReactNode;
  sub?: ReactNode;
  value: number;
  min: number;
  max: number;
  step?: number;
  fmt?: (v: number) => string;
  onChange: (v: number) => void;
}) {
  const [live, setLive] = useState(value);
  useEffect(() => setLive(value), [value]);
  return (
    <div className="crow">
      <CrowHead icon={icon} label={label} sub={sub} right={<span className="crow-v">{fmt(live)}</span>} />
      <input
        className="rng"
        type="range"
        min={min}
        max={max}
        step={step}
        value={live}
        onChange={(e) => setLive(+e.target.value)}
        onPointerUp={() => {
          if (live === value) return;
          haptic("sel");
          onChange(live);
        }}
      />
    </div>
  );
}

/* ---------- 选项行(sheet / 播放器面板共用) ---------- */
export function Opt({
  label,
  sub,
  on,
  i = 0,
  badge,
  onClick,
}: {
  label: ReactNode;
  sub?: ReactNode;
  on?: boolean;
  i?: number;
  badge?: ReactNode;
  onClick?: () => void;
}) {
  return (
    <button type="button" className={`opt${on ? " on" : ""}`} style={{ ["--i" as string]: i }} onClick={onClick}>
      <span className="opt-t">
        <div>{label}</div>
        {sub ? <div className="opt-s">{sub}</div> : null}
      </span>
      {badge ? <span className="tag">{badge}</span> : null}
    </button>
  );
}

export const OptGroup = ({ children }: { children: ReactNode }) => <div className="opt-grp">{children}</div>;

export const Tag = ({ children, cls = "" }: { children: ReactNode; cls?: string }) => (
  <span className={`tag${cls ? " " + cls : ""}`}>{children}</span>
);

/** 分组标题 + 一组单元格。设置族全靠它排版。 */
export function Group({ title, note, children }: { title?: ReactNode; note?: ReactNode; children: ReactNode }) {
  return (
    <div className="sgroup" data-enter>
      {title ? <h2>{title}</h2> : null}
      <div className="cells">{children}</div>
      {note ? <div className="note-box">{note}</div> : null}
    </div>
  );
}
