import { useEffect, useRef } from "react";

/* ============================================================
   全局快捷键系统(PC 端)

   为什么是「命令注册 + 一条全局监听」而不是各处各挂一个 keydown:
     - 之前 App / Shell 各挂了一个,已经出现过「播放页按 F5 也会刷新底下那一页」这类
       互相打架的苗头;各挂各的还意味着**没有任何地方能列出全部快捷键**,
       更不可能让用户改键。
     - 现在按键 → combo 字符串 → 命令 id → 谁注册了谁执行。改键只改这张表,
       设置页照着 COMMANDS 渲染就是完整的快捷键列表,不会漏也不会撒谎。

   ★ 「所有能点的按钮都能用快捷键」这条,靠**两层**共同满足:
     1. 这里的具名命令 —— 高频动作(导航/播放/面板),可改键;
     2. HintOverlay 的按键提示(默认 `;`)—— 给当前屏幕上**每一个**可点元素
        现场发一个字母标签,输字母即点击。页面以后新增按钮也自动覆盖,
        不需要有人记得回来往这张表里补一条。
   ============================================================ */

/** 命令生效的界面。player = 正在播放;app = 在主界面;any = 都生效。 */
export type Scope = "app" | "player" | "any";

export type Command = {
  id: string;
  label: string;
  group: string;
  scope: Scope;
  /** 默认按键(可多个)。用户改键只覆盖这一项。 */
  keys: string[];
  /** 鼠标手势:列在表里让用户知道有这回事,但不参与录键(录键器只收 keydown,录不到鼠标)。
   *  keys 用 `mouse:*` 伪 combo —— 键盘永远产不出这个前缀,所以它既不会被 dispatch 命中,
   *  也不可能和真键位撞车,不用给冲突检测开特例。 */
  fixed?: boolean;
};

/* 默认键位。取值口径见 comboOf():全部小写,修饰键固定顺序 ctrl+alt+shift+meta。
   ★ 改这张表要同时想清楚**冲突**:同一 scope 里两条撞了,后面那条永远轮不到
     (dispatch 只取第一个命中的),而且不报错。设置页会把冲突标红。 */
export const COMMANDS: Command[] = [
  // ---- 全局 ----
  { id: "search", label: "搜索", group: "全局", scope: "app", keys: ["ctrl+k"] },
  { id: "refresh", label: "刷新当前页", group: "全局", scope: "app", keys: ["f5"] },
  { id: "back", label: "返回上一层", group: "全局", scope: "app", keys: ["alt+arrowleft"] },
  { id: "toggle-sidebar", label: "折叠 / 展开侧栏", group: "全局", scope: "app", keys: ["alt+s"] },
  { id: "toggle-theme", label: "切换深色 / 浅色", group: "全局", scope: "app", keys: ["alt+t"] },
  { id: "hints", label: "按键提示(点任意按钮)", group: "全局", scope: "any", keys: [";"] },
  { id: "help", label: "快捷键一览", group: "全局", scope: "any", keys: ["shift+?"] },

  // ---- 页面切换 ----
  { id: "nav-home", label: "首页", group: "页面", scope: "app", keys: ["alt+1"] },
  { id: "nav-library", label: "媒体库", group: "页面", scope: "app", keys: ["alt+2"] },
  { id: "nav-favorites", label: "收藏", group: "页面", scope: "app", keys: ["alt+3"] },
  { id: "nav-downloads", label: "下载", group: "页面", scope: "app", keys: ["alt+4"] },
  { id: "nav-rankings", label: "排行榜", group: "页面", scope: "app", keys: ["alt+5"] },
  { id: "nav-calendar", label: "追剧日历", group: "页面", scope: "app", keys: ["alt+6"] },
  { id: "nav-servers", label: "服务器", group: "页面", scope: "app", keys: ["alt+7"] },
  { id: "nav-plugins", label: "插件", group: "页面", scope: "app", keys: ["alt+8"] },
  { id: "nav-settings", label: "设置", group: "页面", scope: "app", keys: ["alt+9"] },

  // ---- 播放 ----
  { id: "play-pause", label: "播放 / 暂停", group: "播放", scope: "player", keys: ["space", "k"] },
  { id: "seek-back", label: "快退 10 秒", group: "播放", scope: "player", keys: ["arrowleft"] },
  { id: "seek-fwd", label: "快进 10 秒", group: "播放", scope: "player", keys: ["arrowright"] },
  { id: "seek-back-long", label: "快退 60 秒", group: "播放", scope: "player", keys: ["shift+arrowleft"] },
  { id: "seek-fwd-long", label: "快进 60 秒", group: "播放", scope: "player", keys: ["shift+arrowright"] },
  { id: "vol-up", label: "音量 +", group: "播放", scope: "player", keys: ["arrowup"] },
  { id: "vol-down", label: "音量 −", group: "播放", scope: "player", keys: ["arrowdown"] },
  { id: "mute", label: "静音", group: "播放", scope: "player", keys: ["m"] },
  { id: "fullscreen", label: "全屏切换", group: "播放", scope: "player", keys: ["f"] },
  { id: "prev-ep", label: "上一集", group: "播放", scope: "player", keys: ["p"] },
  { id: "next-ep", label: "下一集", group: "播放", scope: "player", keys: ["n"] },
  { id: "speed-down", label: "倍速 −0.25", group: "播放", scope: "player", keys: ["["] },
  { id: "speed-up", label: "倍速 +0.25", group: "播放", scope: "player", keys: ["]"] },
  { id: "speed-reset", label: "倍速归 1.0", group: "播放", scope: "player", keys: ["backspace"] },
  { id: "screenshot", label: "截图", group: "播放", scope: "player", keys: ["s"] },
  { id: "copy-time", label: "复制当前时间", group: "播放", scope: "player", keys: ["ctrl+shift+c"] },
  { id: "danmaku-toggle", label: "弹幕开 / 关", group: "播放", scope: "player", keys: ["d"] },
  { id: "close-player", label: "关闭面板 / 退出播放", group: "播放", scope: "player", keys: ["escape"] },

  // ---- 播放页面板 ----
  { id: "panel-eps", label: "选集", group: "播放面板", scope: "player", keys: ["e"] },
  { id: "panel-audio", label: "音轨", group: "播放面板", scope: "player", keys: ["a"] },
  { id: "panel-sub", label: "字幕", group: "播放面板", scope: "player", keys: ["c"] },
  { id: "panel-danmaku", label: "弹幕面板", group: "播放面板", scope: "player", keys: ["shift+d"] },
  { id: "panel-super", label: "超分", group: "播放面板", scope: "player", keys: ["u"] },
  { id: "panel-line", label: "线路", group: "播放面板", scope: "player", keys: ["l"] },
  { id: "panel-version", label: "版本", group: "播放面板", scope: "player", keys: ["v"] },
  { id: "panel-speed", label: "倍速面板", group: "播放面板", scope: "player", keys: ["r"] },
  { id: "panel-more", label: "更多", group: "播放面板", scope: "player", keys: ["o"] },

  // ---- 鼠标(手势固定,不可改键;实现在 App.tsx 的 .p-stage 上)----
  { id: "m-speed-hold", label: "临时 2× 快进(松开还原)", group: "鼠标", scope: "player", keys: ["mouse:rhold"], fixed: true },
  { id: "m-fullscreen", label: "全屏切换", group: "鼠标", scope: "player", keys: ["mouse:dbl"], fixed: true },
  { id: "m-volume", label: "音量 ±5", group: "鼠标", scope: "player", keys: ["mouse:wheel"], fixed: true },
  { id: "m-mute", label: "静音", group: "鼠标", scope: "player", keys: ["mouse:mid"], fixed: true },
];

const BY_ID = new Map(COMMANDS.map((c) => [c.id, c]));

/* ---------- 按键 → combo 字符串 ---------- */

/** 单个键的规范名。`" "` → space,其余一律小写(ArrowLeft → arrowleft、F5 → f5)。 */
function normKey(k: string): string {
  if (k === " ") return "space";
  return k.toLowerCase();
}

/** KeyboardEvent → combo。修饰键本身按下时返回 ""(那不是一个完整组合)。 */
export function comboOf(e: KeyboardEvent): string {
  if (["Control", "Shift", "Alt", "Meta"].includes(e.key)) return "";
  const p: string[] = [];
  if (e.ctrlKey) p.push("ctrl");
  if (e.altKey) p.push("alt");
  if (e.shiftKey) p.push("shift");
  if (e.metaKey) p.push("meta");
  p.push(normKey(e.key));
  return p.join("+");
}

const KEY_LABEL: Record<string, string> = {
  ctrl: "Ctrl", alt: "Alt", shift: "Shift", meta: "Win",
  arrowleft: "←", arrowright: "→", arrowup: "↑", arrowdown: "↓",
  space: "空格", escape: "Esc", backspace: "退格", enter: "回车", tab: "Tab",
};
/** 鼠标手势的显示名。伪 combo 见 Command.fixed。 */
const MOUSE_LABEL: Record<string, string> = {
  "mouse:rhold": "长按右键",
  "mouse:dbl": "双击画面",
  "mouse:wheel": "滚轮",
  "mouse:mid": "中键",
};
/** combo → 给人看的样子("ctrl+shift+c" → "Ctrl + Shift + C")。 */
export function comboLabel(combo: string): string {
  if (MOUSE_LABEL[combo]) return MOUSE_LABEL[combo];
  return combo
    .split("+")
    .map((k) => KEY_LABEL[k] ?? (k.length === 1 ? k.toUpperCase() : k.toUpperCase()))
    .join(" + ");
}

/* ---------- 用户改键的持久化 ----------
   只存**改过的**那几条(id → keys),不存全表:全存的话以后往 COMMANDS 里加命令,
   老用户的存档会把新命令覆盖成「没有键」,而且一声不吭。 */
const LS_KEY = "shortcuts:v1";
type Overrides = Record<string, string[]>;

function readOverrides(): Overrides {
  try {
    const raw = localStorage.getItem(LS_KEY);
    if (!raw) return {};
    const o = JSON.parse(raw) as Overrides;
    // 存档里可能有已经删掉的命令 id / 脏值,逐项过一遍再用。
    const out: Overrides = {};
    for (const [id, keys] of Object.entries(o)) {
      if (BY_ID.has(id) && Array.isArray(keys) && keys.every((k) => typeof k === "string")) {
        out[id] = keys;
      }
    }
    return out;
  } catch {
    return {};
  }
}

let overrides: Overrides = readOverrides();
/* 改键要让设置页 + 正在跑的 dispatch 一起看到新值 —— 前端没有 store,
   靠这一组订阅广播(同 [[frontend-state-copies-need-broadcast]] 的口径)。 */
const listeners = new Set<() => void>();

export function keysOf(id: string): string[] {
  return overrides[id] ?? BY_ID.get(id)?.keys ?? [];
}
/** 全部生效键位(含用户改过的)。设置页与冲突检测都读它。 */
export function allBindings(): { cmd: Command; keys: string[] }[] {
  return COMMANDS.map((cmd) => ({ cmd, keys: keysOf(cmd.id) }));
}
export function setKeys(id: string, keys: string[]) {
  if (!BY_ID.has(id)) return;
  const def = BY_ID.get(id)!.keys;
  // 和默认值一样就把覆盖删掉,别在存档里留一份等于默认的死数据。
  if (keys.length === def.length && keys.every((k, i) => k === def[i])) delete overrides[id];
  else overrides[id] = keys;
  persist();
}
export function resetAll() {
  overrides = {};
  persist();
}
function persist() {
  try {
    localStorage.setItem(LS_KEY, JSON.stringify(overrides));
  } catch {
    /* 存不下也不该让快捷键当场失效 —— 内存里那份照常生效,只是重启后回到默认 */
  }
  listeners.forEach((f) => f());
}
export function onBindingsChange(f: () => void): () => void {
  listeners.add(f);
  return () => {
    listeners.delete(f);
  };
}

/** 同一 scope 内被两条命令抢的 combo。设置页拿它标红。 */
export function conflicts(): Set<string> {
  const seen = new Map<string, string>();
  const bad = new Set<string>();
  for (const { cmd, keys } of allBindings()) {
    for (const k of keys) {
      for (const s of cmd.scope === "any" ? ["app", "player"] : [cmd.scope]) {
        const tag = `${s}:${k}`;
        if (seen.has(tag) && seen.get(tag) !== cmd.id) bad.add(k);
        else seen.set(tag, cmd.id);
      }
    }
  }
  return bad;
}

/* ---------- 命令注册 + 分发 ---------- */

type Handler = (e: KeyboardEvent) => void;
const handlers = new Map<string, Handler>();
let scope: Exclude<Scope, "any"> = "app";

/** 播放页开/关时调一次。命令按 scope 过滤,免得播放时按 Alt+1 把底下那一页切走。 */
export function setScope(s: Exclude<Scope, "any">) {
  scope = s;
}

/** 注册一个命令的实现。同一 id 只留最后一个注册者(播放器和主界面不会同时注册同一 id)。
 *
 *  ★ 真正注册进去的是一个**稳定的包装器**,实现放 ref。调用点几乎全是内联箭头函数,
 *    每次渲染都是新引用 —— 直接进依赖的话,播放页每 250ms 一次的状态轮询会把
 *    几十条命令全部卸载重装一遍。 */
export function useCommand(id: string, fn: Handler | null, enabled = true) {
  const ref = useRef(fn);
  ref.current = fn;
  useEffect(() => {
    if (!enabled) return;
    const wrap: Handler = (e) => ref.current?.(e);
    handlers.set(id, wrap);
    return () => {
      // 只有还是自己时才摘 —— 别把后来者的注册误删。
      if (handlers.get(id) === wrap) handlers.delete(id);
    };
  }, [id, enabled]);
}

/** 焦点在输入框里。此时无修饰键的字母/空格一律不劫持,否则搜索框敲不了字。 */
function inEditable(t: EventTarget | null): boolean {
  const el = t as HTMLElement | null;
  if (!el || !el.tagName) return false;
  return el.tagName === "INPUT" || el.tagName === "TEXTAREA" || el.isContentEditable === true;
}

/** 安装唯一的全局监听。App 挂一次即可,返回卸载函数。 */
export function installDispatcher(): () => void {
  const onKey = (e: KeyboardEvent) => {
    const combo = comboOf(e);
    if (!combo) return;
    // 输入框里只放行带 ctrl/alt/meta 的组合与 Esc(Esc 要能关面板/收起输入)。
    if (inEditable(e.target) && !e.ctrlKey && !e.altKey && !e.metaKey && combo !== "escape") return;
    for (const { cmd, keys } of allBindings()) {
      if (cmd.scope !== "any" && cmd.scope !== scope) continue;
      if (!keys.includes(combo)) continue;
      const h = handlers.get(cmd.id);
      if (!h) continue; // 当前界面没接这条 —— 静默放过,别吃掉按键
      e.preventDefault();
      h(e);
      return;
    }
  };
  window.addEventListener("keydown", onKey);
  return () => window.removeEventListener("keydown", onKey);
}
