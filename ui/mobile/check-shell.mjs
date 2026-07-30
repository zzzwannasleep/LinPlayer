/* 手机端外壳自检 —— **真渲染**,不看编译绿。
 *
 * 这个仓库反复栽在同一件事上:编译绿、CI 绿、控制台干净,而画出来是错的
 * (卡片标题静默消失、排行榜整屏白板、chip 行被 snap 切掉半张卡)。
 * 所以每一轮改完版式都要真跑一次。
 *
 * ## 它能验什么、不能验什么
 * 浏览器里 `window.__TAURI_INTERNALS__` **不存在**,所有 invoke 都是 TypeError ——
 * 所以这个脚本只验**外壳和版式**:挂载、三条栈、底栏、转场类、横向溢出、
 * 以及"所有页面在没有数据时会不会白屏/崩栈"。
 * 真数据要挂真壳跑(见 README 的 CDP 那一节)。
 *
 * ## 两条纪律
 * 1. 判有没有横向溢出要看 `documentElement.scrollWidth === innerWidth`,**别看截图边缘** ——
 *    headless 下 `--window-size=390` 时 innerWidth 实测是 504,按 390 截出来的图看着像溢出。
 *    所以尺寸一律靠 `Emulation.setDeviceMetricsOverride` 设。
 * 2. 断言必须**先红过**。改这个文件时先手动把某个选择器写错,确认它真的报红。
 *
 * 跑法:先 `npx vite build`,再 `node ui/mobile/check-shell.mjs`
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";

const ROOT = "D:/LinPlayer";
const PORT_HTTP = 4188;
const PORT_CDP = 9522;

const bin = [
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
].find(existsSync);
if (!bin) {
  console.error("找不到 Edge");
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/* 静态服务器**在这个进程里起**,不 spawn `vite preview`。
   两个理由:
   1. `npx vite preview` 中间隔着 cmd.exe / npx 两层进程,脚本结束时 kill() 只杀掉最外层,
      真正占着端口的 vite 活下来了 —— 下一次跑报 "Port already in use",
      而那句报错**看起来像是"构建没做"**,能把人绕进沟里(这一版就绕过)。
   2. 少一个外部依赖,CI 里也能跑。
   ★ 不能用 file://:vite 产物里的 `<script type="module" src="/assets/...">` 是绝对路径,
     file:// 下既解析不到、也会被 CORS 拦死 —— 表现是**整页全黑**。 */
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
};
const DIST = join(ROOT, "dist");
if (!existsSync(join(DIST, "index-mobile.html"))) {
  console.error("★ dist/index-mobile.html 不存在 —— 先跑 `npx vite build`");
  process.exit(1);
}
const server = createServer(async (req, res) => {
  try {
    const u = decodeURIComponent((req.url || "/").split("?")[0]);
    const f = join(DIST, normalize(u === "/" ? "/index.html" : u));
    if (!f.startsWith(DIST)) throw new Error("越界");
    const buf = await readFile(f);
    res.writeHead(200, { "content-type": MIME[extname(f)] || "application/octet-stream" });
    res.end(buf);
  } catch {
    res.writeHead(404).end("nope");
  }
});
await new Promise((r) => server.listen(PORT_HTTP, "127.0.0.1", r));

const proc = spawn(
  bin,
  [
    "--headless=new",
    `--remote-debugging-port=${PORT_CDP}`,
    "--no-first-run",
    "--disable-gpu",
    "--hide-scrollbars",
    /* ★ 关掉扩展:用户 profile 里的下载器扩展会往页面里注入脚本并抛
       `Cannot read properties of null (reading 'siteHostMap')` ——
       那不是我们的错,但会把"控制台干净"这条断言染红,而**染红久了真错误就没人看了**。 */
    "--disable-extensions",
    `--user-data-dir=${process.env.TEMP}/cdp-lp-${PORT_CDP}`,
    "about:blank",
  ],
  { stdio: "ignore" },
);

let wsUrl;
for (let i = 0; i < 80 && !wsUrl; i++) {
  try {
    const l = await (await fetch(`http://127.0.0.1:${PORT_CDP}/json/list`)).json();
    wsUrl = l.find((x) => x.type === "page")?.webSocketDebuggerUrl;
  } catch {}
  if (!wsUrl) await sleep(250);
}
const ws = new WebSocket(wsUrl);
await new Promise((r) => (ws.onopen = r));

let id = 0;
const pend = new Map();
let errs = [];
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pend.has(m.id)) {
    pend.get(m.id)(m);
    pend.delete(m.id);
  }
  const push = (t) => {
    if (!t) return;
    /* invoke 在浏览器里必然抛(没有 __TAURI_INTERNALS__)—— 那不是 bug。
       vibrate 在无头下没有用户手势也必然警告。两者都过滤掉,
       ★ 但**别把过滤写宽** —— 过滤宽了真错误也会被吞,那比不测还糟。 */
    if (/__TAURI_INTERNALS__|vibrate|Failed to load resource/.test(t)) return;
    errs.push(t.slice(0, 160));
  };
  if (m.method === "Log.entryAdded" && m.params.entry.level === "error") push(m.params.entry.text);
  if (m.method === "Runtime.exceptionThrown")
    push((m.params.exceptionDetails.exception?.description || "exc").split("\n")[0]);
};
const cmd = (me, p = {}) =>
  new Promise((r) => {
    const i = ++id;
    pend.set(i, r);
    ws.send(JSON.stringify({ id: i, method: me, params: p }));
  });
const ev = async (e) => (await cmd("Runtime.evaluate", { expression: e, returnByValue: true })).result?.result?.value;

await cmd("Page.enable");
await cmd("Runtime.enable");
await cmd("Log.enable");
await cmd("Emulation.setDeviceMetricsOverride", {
  width: 390,
  height: 844,
  deviceScaleFactor: 2,
  mobile: true,
  screenOrientation: { angle: 0, type: "portraitPrimary" },
});

let fail = 0;
const must = (cond, msg) => {
  let good = false;
  try {
    good = typeof cond === "function" ? cond() : cond;
  } catch (e) {
    good = false;
    msg += ` [探针抛错:${e.message}]`;
  }
  if (good) console.log("   ✓ " + msg);
  else {
    console.log("   ✗ " + msg);
    fail++;
  }
};

errs = [];
await cmd("Page.navigate", { url: `http://127.0.0.1:${PORT_HTTP}/index-mobile.html` });
await sleep(2500);

console.log("\n── 闸口态(没有 Tauri = 没有会话)──");
const shell = await ev(`(() => {
  const app = document.querySelector(".app");
  return {
    mounted: !!app,
    tabs: document.querySelectorAll(".tab").length,
    stacks: document.querySelectorAll(".stack").length,
    bodyText: (document.body.innerText || "").length,
    scrollW: document.documentElement.scrollWidth,
    innerW: window.innerWidth,
  };
})()`);
console.log("   " + JSON.stringify(shell));

must(shell.mounted, "React 挂上了(.app 存在)");
/* ★ 「一片黑」和「崩了」在透明窗口上长得一模一样 —— 用 bodyText 长度当判据。
   靠这一条曾经抓到「h() 把字符串子节点当 props 吃掉,整站文字静默消失」。 */
must(shell.bodyText > 20, `页面有文字(${shell.bodyText} 字符)—— 只有个位数就是渲染崩了`);
/* ★ 一台源都没有时**故意不画底栏** —— 三个 Tab 一个都点不动,
   画出来只会让用户在空页面之间转圈。所以这里断言的是"没有"。 */
must(() => shell.tabs === 0, "闸口态不画底栏(三个 Tab 都点不动,画了只会让人转圈)");
must(() => shell.stacks === 0, "闸口态不挂页面栈");
must(shell.scrollW === shell.innerW, `没有横向溢出(scrollWidth ${shell.scrollW} = innerWidth ${shell.innerW})`);

console.log("\n── 首启闸口 ──");
/* 没有 Tauri 就没有会话 → 应该落到首启闸口(LoginPage),而不是白屏。 */
const login = await ev(`(() => {
  const l = document.querySelector(".login");
  return {
    isLogin: !!l,
    brand: document.querySelector(".lg-brand")?.textContent ?? "",
    srcItems: [...document.querySelectorAll(".src-it")].map(b => b.dataset.kind),
    secs: [...document.querySelectorAll(".src-sec")].map(s => s.textContent),
    firstField: document.querySelector(".lg-pane .field span")?.textContent ?? "",
    reqStars: document.querySelectorAll(".lg-pane .req-star").length,
    connect: document.querySelector(".lg-acts .btn")?.textContent ?? "",
  };
})()`);
console.log("   " + JSON.stringify(login));

must(login.isLogin, "一台源都没有 → 落首启闸口,不是白屏");
/* SourceKind 是 Rust 的封闭集,全小写。写错**不报错**,只是登录送错值。 */
const WANT_KINDS = ["emby", "feiniu", "openlist", "aliyundrive", "quark", "baidu", "pan115", "pan189", "pan139", "anirss", "stremio", "qrsync"];
for (const k of WANT_KINDS) must(() => login.srcItems.includes(k), `源类型有 ${k}`);
for (const bad of ["aliyun", "p115", "tianyi", "mobile139", "jellyfin", "Emby"])
  must(() => !login.srcItems.includes(bad), `没有用错的 id「${bad}」(比较会恒 false 且不报错)`);
must(() => !login.srcItems.includes("batch"), "首启闸口排除了「批量粘贴导入」(第一次装没有那个场景)");
must(() => login.secs.length >= 3, `源类型按 sec 分了组:${login.secs.join(" / ")}`);
/* ★ 服务器名称必填、且**排第一行** —— 扫码型的用户扫完就跳走,放后面等于没有 */
must(() => login.firstField.startsWith("服务器名称"), `表单第一个字段是「服务器名称」(实际:${login.firstField})`);
must(login.reqStars >= 1, "名称带必填星号");

console.log("\n── 切源类型:扫码型不画「连接」按钮 ──");
await ev(`document.querySelector('.src-it[data-kind="aliyundrive"]')?.click()`);
await sleep(300);
const qr = await ev(`(() => ({
  firstField: document.querySelector(".lg-pane .field span")?.textContent ?? "",
  hasQr: !!document.querySelector(".qr"),
  acts: document.querySelectorAll(".lg-acts .btn").length,
}))()`);
console.log("   " + JSON.stringify(qr));
must(() => qr.firstField.startsWith("服务器名称"), "扫码型也把名称放在二维码**上面**");
must(qr.hasQr, "扫码型画了二维码位");
must(() => qr.acts === 0, "扫码型不画「连接」按钮(扫完就生效,画出来只会让人乱点)");


console.log("\n── 带 Tab 的外壳(注入假 invoke)──");
/* ★ 浏览器里没有 __TAURI_INTERNALS__,所有 invoke 都是 TypeError,App 会一直停在闸口。
   注入一个**返回空数据**的假 invoke,就能把三条栈、底栏、以及每一页在
   "接得通但一条数据都没有"这个最常见的真实情况下的样子全走一遍。
   这正是这个仓库最容易做砸的地方:排行榜曾经因为落进 `{busy ? "加载中…" : ""}`
   分支而**整屏白板一个字都没有**,CDP 里 crash=null、不报错。 */
const STUB = `(() => {
  const EMPTY = {
    current_session: { server: "http://stub", token: "t", user_id: "u", user_name: "stub" },
    current_source: null,
    views: [], list_items_page: { items: [], total: 0 }, list_latest: [], list_resume: [],
    list_next_up: [], list_random: [], list_favorites: [], aggregate_search: [],
    aggregate_overview: [], list_accounts: [], probe_accounts: [], download_list: [],
    ranking_categories: [], ranking_fetch: [], bangumi_calendar: [], trakt_calendar: [],
    get_danmaku_config: [], shader_levels: [], icon_library: [], source_list_dir: [],
    plugin_list: [], plugin_market_list: { plugins: [], errors: [] }, plugin_market_sources: [],
    anirss_list_ani: [], anirss_torrents_infos: [], cache_size: 0,
    get_playback_prefs: { hwdec: "auto-safe", default_speed: 1, skip_intro: false, skip_outro: false,
      preview_thumbs: true, dolby_auto_sw: true, external_player: "" },
    get_prefs: { audio_lang: null, sub_lang: null, sub_enabled: true, version_regex: "",
      sub_regex: "", audio_regex: "", detail_blur: 0 },
    get_prefetch_settings: { servers: [], threads: 2, cache_bytes: 268435456 },
    get_writeback_settings: { enabled: false, range: "all", include_progress: false },
    get_cross_server_resume: false, trakt_account: null, bangumi_account: null,
    get_update_settings: { channel: "stable", auto_check: true, current_version: "1.4.2", can_self_update: true }
  };
  window.__TAURI_INTERNALS__ = {
    invoke: (c) => Promise.resolve(c in EMPTY ? EMPTY[c] : null),
    transformCallback: (cb) => cb
  };
})()`;
await cmd("Page.addScriptToEvaluateOnNewDocument", { source: STUB });
errs = [];
await cmd("Page.navigate", { url: `http://127.0.0.1:${PORT_HTTP}/index-mobile.html` });
await sleep(2600);

const shell2 = await ev(`(() => {
  const app = document.querySelector(".app");
  return {
    tabs: [...document.querySelectorAll(".tab")].map(b => b.textContent.trim()),
    stacks: [...document.querySelectorAll(".stack")].map(s => s.dataset.tab),
    pgs: document.querySelectorAll(".pg").length,
    hasTabs: app?.classList.contains("has-tabs") ?? false,
    glass: !!document.querySelector(".tabs > .tabs-inner"),
    scrollW: document.documentElement.scrollWidth,
    innerW: window.innerWidth,
    text: (document.body.innerText || "").slice(0, 70).replace(/\s+/g, " ")
  };
})()`);
console.log("   " + JSON.stringify(shell2));
must(() => JSON.stringify(shell2.stacks) === JSON.stringify(["home", "aggregate", "servers"]),
  "三条栈按 TABS 的顺序挂着(home / aggregate / servers)");
must(() => JSON.stringify(shell2.tabs) === JSON.stringify(["首页", "聚合视界", "服务器"]),
  `底栏三个 Tab:${shell2.tabs.join(" / ")}`);
must(shell2.glass, "底栏是 .tabs > .tabs-inner 两层(外层定位、内层玻璃)");
must(() => shell2.pgs === 3, `三条栈各一格 .pg(共 ${shell2.pgs} 格)`);
must(shell2.hasTabs, ".app 带 has-tabs(内容才会给悬浮底栏让出高度)");
must(shell2.scrollW === shell2.innerW, `没有横向溢出(${shell2.scrollW} = ${shell2.innerW})`);

/* ★ 这一节是补的洞。2026-07-30 之前上面那些断言**全绿**,而真跑起来是
   「一整块空屏,只剩底栏那条胶囊浮着」—— 因为三条栈的 `hidden` 谁也没被摘掉
   (App.tsx 里那个 effect 依赖 `[tab]`,而 `.stacks` 是会话回来之后才挂上的,
   tab 一个字没变,effect 再也没跑第二次)。
   老断言查不出来的原因很具体:`shell2.text` 里的那几个字是**底栏三个 Tab 的
   label**,`document.querySelector('.home-bar ...')` 又不看可见性 —— 所以
   「页面有文字」「进得了设置」两条都照样过。
   判据必须是**当前 Tab 那条栈真的可见**,而不是"页面上有东西"。 */
const vis = await ev(`(() => {
  const ss = [...document.querySelectorAll(".stack")];
  const shown = ss.filter(s => !s.hidden);
  const pg = shown[0]?.querySelector(".pg");
  const body = pg?.querySelector(".pg-body");
  return {
    shown: shown.map(s => s.dataset.tab),
    pgPos: pg && getComputedStyle(pg).position,
    pgH: pg?.getBoundingClientRect().height ?? 0,
    bodyH: body?.clientHeight ?? 0,
    viewH: window.innerHeight,
  };
})()`);
console.log("   " + JSON.stringify(vis));
must(() => JSON.stringify(vis.shown) === JSON.stringify(["home"]),
  `冷启动后可见的栈正好是 home 一条(实际:${vis.shown.join(",") || "一条都没有 —— 整屏是空的"})`);
/* ★ `.pg` 必须一直是 absolute。下拉刷新曾经无脑写 `host.style.position="relative"`,
   把它顶回文档流 —— 高度从 844 塌成内容高度,`.pg-body` 跟着塌,
   **整页一动不动**(用户报的「首页不能滑动」)。内联样式压得过样式表,
   所以 CSS 怎么看都是对的。只有量运行时的 computed position 才看得见。 */
must(() => vis.pgPos === "absolute", `首页那一格仍是 position:absolute(实际 ${vis.pgPos})`);
must(() => vis.pgH === vis.viewH, `首页那一格撑满视口(${vis.pgH} = ${vis.viewH})—— 塌了就滑不动`);
must(() => vis.bodyH > 0, `滚动容器有高度(${vis.bodyH}px)`);

/* 图标库那 1468 张图**必须收进格子**。少一条 `.ico-it img` 的尺寸规则,
   图就按天然尺寸(普遍 256~512px)画在 65px 的格子里,只露左上角一小块。
   这里不进图标页(桩里图标库是空的),直接量这条 CSS 规则本身。 */
/* 两步走:先挂上去,等图解码完再量。一步写成 Promise 是量不到的 ——
   `Runtime.evaluate` 默认不 await,拿回来的是个空对象(这条自己踩过)。 */
await ev(`(() => {
  const cell = document.createElement("div");
  cell.className = "ico-it";
  cell.id = "__icoprobe";
  cell.style.cssText = "width:64px;height:64px;position:fixed;left:-999px;top:0";
  const im = document.createElement("img");
  // 512×512 的图,和真图标库一个量级
  im.src = 'data:image/svg+xml;utf8,<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512"><rect width="512" height="512" fill="red"/></svg>';
  cell.appendChild(im);
  document.body.appendChild(cell);
})()`);
await sleep(300);
const icoFit = await ev(`(() => {
  const cell = document.getElementById("__icoprobe");
  const im = cell.querySelector("img");
  const r = im.getBoundingClientRect();
  const out = { w: Math.round(r.width), h: Math.round(r.height),
                nat: im.naturalWidth, fit: getComputedStyle(im).objectFit };
  cell.remove();
  return out;
})()`);
console.log("   " + JSON.stringify(icoFit));
must(() => icoFit.nat === 512, `探针那张图确实是 512px 的(实际 ${icoFit.nat})—— 不是的话下面两条测了个寂寞`);
must(() => icoFit.w > 0 && icoFit.w <= 64 && icoFit.h <= 64,
  `512px 的图标被收进 64px 的格子(实际 ${icoFit.w}×${icoFit.h})—— 溢出就只看得见左上角`);
must(() => icoFit?.fit === "contain", `用 contain 不用 cover(图标有留白构图,cover 会裁边)`);

/* 启动动画。会话已经回来了,这时它必须已经撤掉 —— 撤不掉就是一块盖住全屏的板,
   而它是 fixed + z-index:999,底下什么都点不到。 */
const bootGone = await ev(`!document.getElementById("boot")`);
must(bootGone, "会话回来后启动动画已撤(#boot 不在了)");
/* ★ 空数据下**必须说人话**,不能是白板 */
must(() => shell2.text.length > 10, `首页空态有文字:「${shell2.text}」`);

console.log("\n── 切 Tab ──");
for (const [tab, sel, name] of [["aggregate", ".agg", "聚合视界"], ["servers", ".empty, .cells", "服务器"]]) {
  await ev(`document.querySelector('.tab[data-tab="${tab}"]').click()`);
  await sleep(800);
  const r = await ev(`(() => {
    const top = [...document.querySelectorAll('.stack:not([hidden]) .pg:not([data-leaving])')].pop();
    return {
      ok: !!top?.querySelector('${sel}'),
      crash: !!document.querySelector('.pb-crash'),
      text: (top?.innerText || "").slice(0, 46).replace(/\s+/g, " ")
    };
  })()`);
  must(() => r.ok && !r.crash, `${name}:画出来了且没崩 —— 「${r.text}」`);
}

console.log("\n── 设置族 ──");
await ev(`document.querySelector('.tab[data-tab="home"]').click()`);
await sleep(900);
/* 设置从**首页右上角**进(2026-07-28 从底栏挪上来的) */
await ev(`[...document.querySelectorAll('.home-bar .tb-r button')].pop()?.click()`);
await sleep(900);
const set = await ev(`(() => {
  const top = [...document.querySelectorAll('.stack:not([hidden]) .pg:not([data-leaving])')].pop();
  return {
    title: top?.querySelector('.tb-title')?.textContent ?? "",
    groups: [...(top?.querySelectorAll('.sgroup > h2') ?? [])].map(h => h.textContent),
    cells: [...(top?.querySelectorAll('.cell-l > div:first-child') ?? [])].map(x => x.textContent),
    crash: !!document.querySelector('.pb-crash')
  };
})()`);
console.log("   " + JSON.stringify(set));
must(() => set.title === "设置", `首页右上角进得了设置(标题:${set.title})`);
must(() => !set.crash, "设置页没崩");
must(() => JSON.stringify(set.groups) === JSON.stringify(["片源", "设置", "外观", "其它"]),
  `设置分四组:${set.groups.join(" / ")}`);
/* ★ 代理整组**必须不在**(用户 2026-07-28 定:手机上 Clash/VPN 是系统级的) */
must(() => !set.cells.some((c) => /代理/.test(c)), "设置里没有「代理」这一项");

for (const want of ["播放", "弹幕", "网络", "同步与账号", "存储与数据", "关于"]) {
  await ev(`(() => {
    const top = [...document.querySelectorAll('.stack:not([hidden]) .pg:not([data-leaving])')].pop();
    const c = [...top.querySelectorAll('.cell')].find(x => x.textContent.startsWith('${want}'));
    c && c.click();
  })()`);
  await sleep(900);
  const r = await ev(`(() => {
    const top = [...document.querySelectorAll('.stack:not([hidden]) .pg:not([data-leaving])')].pop();
    return {
      title: top?.querySelector('.tb-title')?.textContent ?? "",
      segs: top?.querySelectorAll('.seg').length ?? 0,
      steps: top?.querySelectorAll('.stepper').length ?? 0,
      cells: top?.querySelectorAll('.cell').length ?? 0,
      crash: !!document.querySelector('.pb-crash'),
      text: (top?.innerText || "").slice(0, 40).replace(/\s+/g, " ")
    };
  })()`);
  must(() => r.title === want && !r.crash,
    `${want}:seg ${r.segs} / stepper ${r.steps} / cell ${r.cells} —— 「${r.text}」`);
  await ev(`document.querySelector('.stack:not([hidden]) .pg:last-child .tb-back')?.click()`);
  await sleep(900);
}

console.log("\n── 就地调节:能 seg/stepper 的绝不开弹窗 ──");
await ev(`(() => {
  const top = [...document.querySelectorAll('.stack:not([hidden]) .pg:not([data-leaving])')].pop();
  const c = [...top.querySelectorAll('.cell')].find(x => x.textContent.startsWith('播放'));
  c && c.click();
})()`);
await sleep(800);
const inplace = await ev(`(() => {
  const top = [...document.querySelectorAll('.stack:not([hidden]) .pg:not([data-leaving])')].pop();
  return {
    segs: [...top.querySelectorAll('.crow')].filter(c => c.querySelector('.seg')).map(c => c.querySelector('.crow-t div').textContent),
    steps: [...top.querySelectorAll('.crow')].filter(c => c.querySelector('.stepper')).map(c => c.querySelector('.crow-t div').textContent),
    popups: [...top.querySelectorAll('.cell')].filter(c => c.querySelector('.cell-s')).map(c => c.querySelector('.cell-l div').textContent)
  };
})()`);
console.log("   " + JSON.stringify(inplace));
must(() => inplace.segs.includes("默认解码方式"), "解码方式是**就地分段**,不是弹窗");
must(() => inplace.steps.includes("默认倍速"), "默认倍速是**就地步进**,不是弹窗");
/* 弹窗只留给"选项多且互斥"和"要填表" —— 超过 5 个就说明又退回弹窗了 */
must(() => inplace.popups.length <= 5, `还开弹窗的只剩 ${inplace.popups.length} 项:${inplace.popups.join(" / ")}`);

console.log("\n── 控制台 ──");
must(() => errs.length === 0, `没有意料之外的报错${errs.length ? ":" + errs.join(" | ") : ""}`);

await cmd("Page.captureScreenshot", { format: "png" }).then(async (r) => {
  const { writeFileSync, mkdirSync } = await import("node:fs");
  mkdirSync(`${ROOT}/ui/mobile/check-shots`, { recursive: true });
  writeFileSync(`${ROOT}/ui/mobile/check-shots/login.png`, Buffer.from(r.result.data, "base64"));
});

console.log(fail ? `\n★ ${fail} 条没过` : "\n全部通过");
ws.close();
proc.kill();
server.close();
process.exit(fail ? 1 : 0);
