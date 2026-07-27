import { useEffect, useMemo, useRef, useState } from "react";
import { allBindings, comboLabel } from "../lib/shortcuts";

/* 按键提示(默认 `;` 唤起)。

   需求原话是「所有页面的所有能点的按钮都需要能够使用快捷键」。逐个按钮去起名字发键位
   是做不到的 —— 光扫出来就 160 多个动作(首页/媒体库/详情/下载/网盘/服务器/插件/设置
   各自的排序、筛选、视图切换、右键菜单项…),而且每加一个按钮就得有人记得回来补一条,
   漏了还不报错。

   所以这一层不列举:唤起时**现场扫描当前屏幕上真正可点的元素**,给每个发一个字母标签,
   输字母即点击。页面以后怎么改都自动跟上,也不会出现「表里写了但按钮已经删了」。
   具名的高频动作仍走 lib/shortcuts.ts,两层互补。 */

/** 标签字母表。用主键盘区最顺手的一排,避开会和「取消」冲突的键。 */
const ALPHABET = "asdfghjklqwertyuiopzxcvbnm";

/* 可点元素的选择器。
   ★ React 的 onClick **不是 DOM 属性**,`[onclick]` 一个都选不到 —— 只能按语义标签
     + 本项目自己的可点类名来收。新增一类可点元素(且不是 <button>)时补在这里,
     或者直接给那个元素挂 `data-hint`。 */
const SELECTOR = [
  "button:not([disabled])",
  "a[href]",
  "input:not([type=hidden]):not([disabled])",
  "select:not([disabled])",
  "textarea:not([disabled])",
  '[role="button"]',
  "[data-hint]",
  ".pitem .pcard", // 海报卡(首页/媒体库/收藏/搜索):click 挂在 .pcard 上
  // 播放页面板的行。`.static` 那些是**容器**(里面装 stepper/开关),自己不接点击 ——
  // 给它发标签只会得到一个按了没反应的字母;里面的按钮各有各的标签。
  ".p-li:not(.static)",
  ".mi", // 右键菜单项
  ".rt.sel", // 面板里的「当前值 ▾」下拉触发
  ".seg > span", // 设置页分段控件
  ".li", // 侧栏服务器下拉 / 详情页线路·版本·音轨行
  ".hero-dots i", // 首页 Hero 圆点
].join(",");

type Hit = { el: HTMLElement; label: string; x: number; y: number };

/** 元素在不在视口里、有没有真的画出来。 */
function visible(el: HTMLElement): boolean {
  const r = el.getBoundingClientRect();
  if (r.width < 4 || r.height < 4) return false;
  if (r.bottom < 0 || r.top > window.innerHeight || r.right < 0 || r.left > window.innerWidth) {
    return false;
  }
  if (getComputedStyle(el).pointerEvents === "none") return false;
  /* ★ 可见性必须**沿祖先链**查,不能只看自己。海报卡上那三个动作钮(播放/已看/收藏)
     装在一整块 `.overlay` 里,悬停才 opacity:0→1 —— 按钮**自己**的 opacity 一直是 1,
     只看自己的话它们会被当成可点元素,把整张卡片的标签抢走(实测就是这样:
     首页 35 个标签里没有一个能打开条目,全是看不见的悬停钮)。 */
  for (let n: HTMLElement | null = el; n && n !== document.body; n = n.parentElement) {
    const s = getComputedStyle(n);
    if (s.display === "none" || s.visibility === "hidden" || Number(s.opacity) <= 0.05) return false;
  }
  return true;
}

/** 生成 n 个尽量短的标签。26 个以内全是一位;超了就只把**必要的那几个**首字母
 *  拿去当两位标签的前缀,其余仍是一位 —— 一屏 35 个元素不该人人都敲两下。 */
function labelsFor(n: number): string[] {
  const a = ALPHABET.split("");
  if (n <= a.length) return a.slice(0, n);
  // k 个前缀能带出 k*26 个两位标签,剩下 (26-k) 个字母仍是一位。
  const k = Math.ceil((n - a.length) / (a.length - 1));
  const singles = a.slice(0, a.length - k);
  const out = [...singles];
  for (const x of a.slice(a.length - k)) {
    for (const y of a) { out.push(x + y); if (out.length >= n) return out; }
  }
  return out;
}

export default function HintOverlay({ open, onClose }: { open: boolean; onClose: () => void }) {
  const [hits, setHits] = useState<Hit[]>([]);
  const [typed, setTyped] = useState("");
  const typedRef = useRef("");

  // 唤起时扫一次。不做实时跟随:扫描期间页面不会动,而每帧重扫是纯浪费。
  useEffect(() => {
    if (!open) {
      setHits([]);
      setTyped("");
      typedRef.current = "";
      return;
    }
    const els = Array.from(document.querySelectorAll<HTMLElement>(SELECTOR)).filter(visible);
    /* 去重:.p-li 本身常常就是 <button>,两个选择器会各收一次(querySelectorAll
       对同一元素只返回一次,但多条选择器命中同一元素时仍要保险)。 */
    const uniq = els.filter((el, i) => els.indexOf(el) === i);
    /* 「壳」才丢:子候选几乎铺满父候选 = 父只是个容器,留子不留父。
       ★ 不能无条件「有子就丢父」—— 海报卡里塞着几个小动作钮,那样整张卡就点不开了。 */
    const kept = uniq.filter((el) => {
      const r = el.getBoundingClientRect();
      const area = r.width * r.height;
      return !uniq.some((o) => {
        if (o === el || !el.contains(o)) return false;
        const ro = o.getBoundingClientRect();
        return ro.width * ro.height >= area * 0.9;
      });
    });
    const labels = labelsFor(kept.length);
    setHits(
      kept.map((el, i) => {
        const r = el.getBoundingClientRect();
        return { el, label: labels[i], x: r.left, y: r.top };
      }),
    );
    setTyped("");
    typedRef.current = "";
  }, [open]);

  // 输入过滤。挂 capture 抢在别的监听之前——提示模式下键盘整个归它。
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === "Escape") { onClose(); return; }
      if (e.key === "Backspace") {
        typedRef.current = typedRef.current.slice(0, -1);
        setTyped(typedRef.current);
        return;
      }
      if (e.key.length !== 1) return;
      const next = typedRef.current + e.key.toLowerCase();
      const match = hits.filter((h) => h.label.startsWith(next));
      if (match.length === 0) return; // 输错了就当没按,别把已经输对的一半也扔了
      if (match.length === 1 && match[0].label === next) {
        const el = match[0].el;
        onClose();
        /* 输入类元素要的是**聚焦**不是点击(点一下输入框什么也不会发生);
           其余一律 click() —— React 的合成事件监听在 root 上,原生 click 冒泡上去照样触发。 */
        if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement || el instanceof HTMLSelectElement) {
          el.focus();
          if (el instanceof HTMLInputElement || el instanceof HTMLTextAreaElement) el.select();
        } else {
          el.click();
        }
        return;
      }
      typedRef.current = next;
      setTyped(next);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [open, hits, onClose]);

  const shown = useMemo(
    () => (typed ? hits.filter((h) => h.label.startsWith(typed)) : hits),
    [hits, typed],
  );

  if (!open) return null;
  return (
    <div className="hintlayer" onClick={onClose}>
      {shown.map((h) => (
        <span className="hintkey" key={h.label} style={{ left: h.x, top: h.y }}>
          {h.label.split("").map((c, i) => (
            <b key={i} className={i < typed.length ? "done" : ""}>{c.toUpperCase()}</b>
          ))}
        </span>
      ))}
      {hits.length === 0 && <div className="hintkey-empty">这一屏没有可点的元素</div>}
    </div>
  );
}

/* 快捷键一览(`?`)。只读 —— 改键在 设置 › 快捷键,那儿才有录键的输入。
   放在播放页也能开:播放时整个 app-root 是 display:none 的,用户去不了设置页。 */
export function ShortcutsHelp({
  open,
  scope,
  onClose,
}: {
  open: boolean;
  scope: "app" | "player";
  onClose: () => void;
}) {
  if (!open) return null;
  const rows = allBindings().filter(
    ({ cmd, keys }) => keys.length > 0 && (cmd.scope === "any" || cmd.scope === scope),
  );
  const groups = [...new Set(rows.map((r) => r.cmd.group))];
  return (
    <div className="kbdhelp" onClick={onClose}>
      <div className="kh-box" onClick={(e) => e.stopPropagation()}>
        <div className="kh-hd">
          快捷键{scope === "player" ? " · 播放中" : ""}
          <button className="x" onClick={onClose}>✕</button>
        </div>
        <div className="kh-bd">
          {groups.map((g) => (
            <div className="kh-grp" key={g}>
              <div className="kh-lab">{g}</div>
              {rows
                .filter((r) => r.cmd.group === g)
                .map(({ cmd, keys }) => (
                  <div className="kh-row" key={cmd.id}>
                    <span>{cmd.label}</span>
                    <span className="kh-keys">
                      {keys.map((k) => <kbd key={k}>{comboLabel(k)}</kbd>)}
                    </span>
                  </div>
                ))}
            </div>
          ))}
        </div>
        <div className="kh-ft">
          按 <kbd>;</kbd> 给屏幕上每个可点元素发字母标签,输字母即点击 · 改键在 设置 › 快捷键
        </div>
      </div>
    </div>
  );
}
