/* 播放窗标题栏 / 换片黑屏 / 缓冲速度 / 媒体库屏蔽 —— 真渲染自检(桌面端)。
 *
 * ## 为什么这几条必须真渲染才测得到
 * 四条改动的失败形态**全都是编译绿、单测绿、只有挂上真 DOM 才现形**的那一类:
 *   1. 播放窗没有标题栏 → tsc 不会说话,只有用户拖不动窗口时才知道(2026-08-02 用户报的);
 *   2. 换片时黑屏没能盖住 play() 那几秒 → 露出上一片的残帧。这条最阴:
 *      复位黑屏的代码一直在(afterStart 里),位置也"看着没问题",
 *      真相是上一片的轮询还在跑、每 250ms 把它拍回去 —— 只有真渲染 + 慢 play() 才现形;
 *   3. 缓冲速度显示在哪儿 → 是布局问题,只有量真元素的位置才说得清;
 *   4. 右键菜单里有没有「屏蔽」、点了有没有真发 set_blocked → 前端接线,
 *      核层单测照不到(见 [[regex-filters-frontend-wiring]] 的同款教训)。
 *
 * ## 跑法
 *   npx vite build && node ui/shared/player-chrome.check.mjs
 *
 * ## 纪律(见 [[test-must-fail-first]])
 * 每条断言都反向注入过真 bug 并确认报红:
 *   · 把 <Titlebar/> 的播放窗分支去掉      → 「播放窗必须有可拖动的标题栏」红
 *   · 把 starting 那面旗子摘掉(或把复位挪回 afterStart)→ 「点了下一集必须立刻变黑」红
 *   · 把 .p-speed 那段 JSX 删掉            → 「出画后速度在标题右边」红
 *   · 把菜单里的「屏蔽此内容」删掉          → 「右键菜单有屏蔽项」红
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";

const ROOT = process.cwd();
const DIST = join(ROOT, "dist");
const PORT_HTTP = 4194;
const PORT_CDP = 9528;

const bin = [
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
].find(existsSync);
if (!bin) {
  console.error("找不到 Edge");
  process.exit(1);
}
if (!existsSync(join(DIST, "index.html"))) {
  console.error("★ dist 不全 —— 先跑 `npx vite build`");
  process.exit(1);
}

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript",
  ".css": "text/css",
  ".json": "application/json",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".woff2": "font/woff2",
};
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
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pend.has(m.id)) {
    pend.get(m.id)(m);
    pend.delete(m.id);
  }
};
const cmd = (me, p = {}) =>
  new Promise((r) => {
    const i = ++id;
    pend.set(i, r);
    ws.send(JSON.stringify({ id: i, method: me, params: p }));
  });
const ev = async (e) =>
  (await cmd("Runtime.evaluate", { expression: e, returnByValue: true })).result?.result?.value;
await cmd("Page.enable");
await cmd("Runtime.enable");

const ITEM = {
  id: "ep1", name: "第 1 集", type_: "Episode", is_folder: false, has_primary: true,
  runtime_secs: 1500, resume_secs: 0, series_name: "某剧", episode_no: 1, season_no: 1,
  video_height: 1080, bitrate: 5e6, size_bytes: 1e9, played: false, unplayed_item_count: 0,
  genres: [], year: 2024, rating: 8, provider_ids: {}, presentation_unique_key: null,
  path: null, series_id: "s1", date_updated: "2026-07-01T00:00:00Z", sort_name: "某剧",
};
const DATA = {
  current_session: { server: "http://stub", token: "t", user_id: "u", user_name: "stub" },
  current_source: null,
  views: [{ ...ITEM, id: "v1", name: "剧集", type_: "CollectionFolder", is_folder: true, series_id: null, series_name: null }],
  list_items_page: { items: [ITEM], total: 1 }, list_latest: [ITEM], list_resume: [ITEM],
  list_next_up: [], list_random: [], list_favorites: [], list_collections: [],
  aggregate_search: [], aggregate_overview: [], list_accounts: [], probe_accounts: [],
  download_list: [], ranking_categories: [], ranking_fetch: [], bangumi_calendar: [],
  trakt_calendar: [], get_danmaku_config: [], shader_levels: [], icon_library: [],
  source_list_dir: [], plugin_list: [], plugin_market_list: { plugins: [], errors: [] },
  plugin_market_sources: [], anirss_list_ani: [], anirss_torrents_infos: [], cache_size: 0,
  plugin_panels: [], is_admin: false, check_update: null, similar_items: [], chapter_info: [],
  item_media: [], tracks: [], seasons: [], season_episodes: { items: [], total: 0 },
  blocked_list: [],
  get_playback_prefs: { hwdec: "auto-safe", default_speed: 1, skip_intro: false, skip_outro: false,
    preview_thumbs: true, dolby_auto_sw: true, external_player: "" },
  get_prefs: { audio_lang: null, sub_lang: null, sub_enabled: true, version_regex: "",
    sub_regex: "", audio_regex: "", detail_blur: 0 },
  player_opts: { volume: 70, muted: false, speed: 1, audio_delay: 0, sub_delay: 0,
    hwdec: "auto-safe", dolby_vision: false, shader_count: 0 },
  get_cross_server_resume: false, trakt_account: null, bangumi_account: null,
  get_update_settings: { channel: "stable", auto_check: true, current_version: "1.4.2", can_self_update: true },
};

/* `label` 决定这一页扮演的是主窗还是播放窗;`pending` 是播放窗一起来就该取到的待播条目。
   状态由用例随时改写(window.__ST)。

   ★ 三处**不能偷懒**,否则测出来的红全是假的:
     1. `plugin:window|is_fullscreen` / `is_maximized` 必须回 false。
        统一回 1(截断式的"plugin: 就返回 1")会让播放页以为自己在全屏 ——
        标题栏按设计在全屏时本来就不渲染,断言红得像功能坏了。
     2. `transformCallback` 要发一个**真的 id** 并把回调存起来,
        这样用例才能从外面触发 `lp://play-pending`(换片那条用例全靠它)。
     3. `plugin:event|listen` 要记下 event → 回调 id 的对应关系。 */
const stub = (label, pending) => `(() => {
  window.__CALLS = [];
  window.__CB = {};
  window.__EV = {};
  let cbId = 0;
  const D = ${JSON.stringify(DATA)};
  window.__ST = { time: 0, duration: 1500, paused: false, buffered: 0, eof: false,
                  cache_speed: 0, buffering: false,
                  video: { vo: "gpu", width: 1920, height: 1080, has_video_track: true, hwdec: "d3d11va" } };
  window.__PENDING = ${JSON.stringify(pending ?? null)};
  window.__PLAY_DELAY = 0;
  /** 从外面点火一个核层事件(换片走的就是这条)。 */
  window.__fire = (name, payload) => {
    const id = window.__EV[name];
    const cb = window.__CB[id];
    if (cb) cb({ event: name, id: 0, payload: payload ?? null });
    return !!cb;
  };
  window.__TAURI_INTERNALS__ = {
    invoke: (c, a) => {
      window.__CALLS.push({ c, a });
      if (c === "status") return Promise.resolve(window.__ST);
      if (c === "player_take_pending") { const p = window.__PENDING; window.__PENDING = null; return Promise.resolve(p); }
      /* play() 在真机上是**慢的**(PlaybackInfo → 取流地址 → 起预取代理,慢服务器上好几秒)。
         这里可调延时,换片那条用例全靠它 —— 秒回的 play() 会把"露残帧"的那个时间窗
         整个抹掉,测出来必然全绿。 */
      if (c === "play" || c === "play_local" || c === "source_play")
        return new Promise((r) => setTimeout(() => {
          /* 核层的 load_inner 每次 loadfile 都会把位置记账**清回续播起点**
             (见 crates/mpv 的注释:不清的话新片头几拍会吐上一集的位置)。
             这里必须照做 —— 不照做的话 status 会继续吐上一片的 12 秒,
             播放页据此判"时间往前走了"就把黑屏撤了,测出来的绿是假的。 */
          window.__ST = { ...window.__ST, time: 0 };
          r(0);
        }, window.__PLAY_DELAY || 0));
      if (c === "plugin:event|listen") { window.__EV[a.event] = a.handler; return Promise.resolve(1); }
      if (c === "plugin:window|is_fullscreen" || c === "plugin:window|is_maximized") return Promise.resolve(false);
      return Promise.resolve(c in D ? D[c] : (c.startsWith("plugin:") ? 1 : null));
    },
    transformCallback: (cb) => { const id = ++cbId; window.__CB[id] = cb; return id; },
    convertFileSrc: (p) => "stub://" + p,
    metadata: { currentWindow: { label: ${JSON.stringify(label)} },
                currentWebview: { windowLabel: ${JSON.stringify(label)}, label: ${JSON.stringify(label)} } },
  };
})()`;

let fail = 0;
const must = (good, msg) => {
  if (good) console.log("   ✓ " + msg);
  else {
    console.log("   ✗ " + msg);
    fail++;
  }
};
const lastCall = (name) => ev(`(() => {
  const c = [...window.__CALLS].reverse().find(x => x.c === ${JSON.stringify(name)});
  return c ? c.a : null;
})()`);

await cmd("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });

/* ============================================================
   播放窗(index.html#player)
   ============================================================ */
console.log("\n══ 播放窗 · 还没起播 ══");
/* ★ URL 里必须带一个每次都变的 query。
   `Page.navigate` 到**完全相同**的 `index.html#player` 是一次**同文档**导航(只换 hash),
   浏览器根本不建新文档 —— addScriptToEvaluateOnNewDocument 不会重跑、React 也不重挂,
   于是第二次 bootPlayer 传进来的待播条目压根没进页面。
   我第一版就是这么写的,表现是「player_take_pending 调了却返回 null」,
   看起来像取件口坏了,其实是测试自己没换页。 */
let boots = 0;
const bootPlayer = async (pending) => {
  await cmd("Page.addScriptToEvaluateOnNewDocument", { source: stub("player", pending) });
  await cmd("Page.navigate", { url: `http://127.0.0.1:${PORT_HTTP}/index.html?b=${++boots}#player` });
  await sleep(2800);
};
await bootPlayer(null);

console.log("\n── 标题栏:拖得动窗口 ──");
/* 用户 2026-08-02:「单开的播放页要有标题栏,不然我拖动不了播放窗口,也点不到别的地方的选项」。
   判据是**拖动区真的存在于播放窗里**,不是"有个 div 叫标题栏"。
   OSD 顶栏里那条 .p-drag 不算:OSD 静止 3 秒就淡出,而且起播前整个 OSD 都不渲染。 */
must(
  await ev(`!!document.querySelector('.titlebar [data-tauri-drag-region]')`),
  "播放窗必须有可拖动的标题栏",
);
must(
  await ev(`document.querySelectorAll('.titlebar .tb-btn').length >= 3`),
  "标题栏要带最小化/最大化/关闭三个键(「点不到别的地方的选项」说的就是这三个)",
);
/* 黑屏层不能盖住标题栏 —— 盖住了按钮画得出来但点不到,和没有一样。 */
const geo = await ev(`(() => {
  const tb = document.querySelector('.titlebar');
  const ld = document.querySelector('.p-loading');
  if (!tb || !ld) return null;
  const a = tb.getBoundingClientRect(), b = ld.getBoundingClientRect();
  return { tbH: Math.round(a.height), loadTop: Math.round(b.top) };
})()`);
must(
  geo && geo.tbH > 0 && geo.loadTop >= geo.tbH,
  `黑屏层必须从标题栏下方开始(标题栏高 ${geo?.tbH}, 黑屏层 top ${geo?.loadTop})`,
);

must(
  await ev(`!!document.querySelector('.p-loading .sp')`),
  "还没拿到待播条目时也得盖着黑幕 + 转圈(窗口是透明的,不盖就直接看穿到桌面)",
);

/* ---------- 起播 → 出画 ---------- */
console.log("\n══ 播放窗 · 起播 ══");
await bootPlayer({ kind: "emby", item: ITEM, media_source_id: null });
must((await lastCall("play")) !== null, "播放窗一起来就自取待播条目并调 play()");

/* ★ 时间停在续播点不动 = 还在缓冲。旧判据是 `st.time > 0`,而核层一 loadfile 就把
   位置记账成续播点,第一拍读到的就已经 >0 —— 那条判据在续播路径上等于"起播即放行"。 */
await ev(`window.__ST = { ...window.__ST, time: 0, buffering: true, cache_speed: 3145728 }`);
await sleep(800);
must(
  await ev(`!!document.querySelector('.p-loading')`),
  "起播后时间还没往前走 → 黑屏层必须还盖着,不能露出上一片的残帧",
);
/* 用户 2026-08-02:「视频没播放前都显示在画面中间」—— 指的就是这一刻:
   已经在取数了,但第一帧还没出来。 */
const bigSpeed = await ev(`document.querySelector('.p-speed-big')?.innerText || ''`);
must(/3(\.0)? MB\/s/.test(bigSpeed), `没出画时缓冲速度显示在画面正中,实际「${bigSpeed}」`);

console.log("\n── 缓冲速度:出画后挪到集标题右侧 ──");
await ev(`window.__ST = { ...window.__ST, time: 12, buffering: false, cache_speed: 2097152 }`);
await sleep(900);
must(!(await ev(`!!document.querySelector('.p-loading')`)), "时间往前走了 → 黑屏层撤掉");
const beside = await ev(`(() => {
  const t = document.querySelector('.p-top .p-title');
  const s = document.querySelector('.p-top .p-speed');
  if (!t || !s) return null;
  const a = t.getBoundingClientRect(), b = s.getBoundingClientRect();
  return { text: s.innerText, rightOfTitle: b.left >= a.right - 1, sameRow: Math.abs(b.top - a.top) < 40 };
})()`);
must(beside && /2(\.0)? MB\/s/.test(beside.text), `出画后速度显示在标题右边,实际「${beside?.text}」`);
must(beside && beside.rightOfTitle && beside.sameRow, "速度必须在集标题**右侧同一行**,不是压在别处");

/* ---------- 换第二个视频 ---------- */
console.log("\n── 换片:第二个视频缓冲期间必须重新变黑 ──");
/* 这条钉的正是用户 2026-08-02 报的:「播过一个视频再播第二个,缓冲出来之前的背景
   不是黑色,是之前的视频的画面」。

   根因**不是**"没人把 ready 置回 false"(afterStart 里一直有那一句),而是两件事叠在一起:
     1. 那一句排在 play() 后面,而 play() 在真机上要好几秒;
     2. 这几秒里**上一片的状态轮询还在跑**,它每 250ms 就把 ready 拍回 true ——
        所以哪怕把复位提到 playItem 第一行,也会被当场盖掉(我第一版就是这么错的,
        这条用例当时照样红,才把 starting 那面旗子逼出来)。
   走的是真实换片路径:主窗每点一次播放,核层广播 lp://play-pending,播放窗再取一次。 */
const EP2 = { ...ITEM, id: "ep2", name: "第 2 集", episode_no: 2 };
await ev(`window.__PLAY_DELAY = 2000`); // 模拟真机上 play() 那几秒
await ev(`window.__PENDING = { kind: "emby", item: ${JSON.stringify(EP2)}, media_source_id: null }`);
must(await ev(`window.__fire("lp://play-pending")`), "核层的换片广播接得到(接不到的话下面两条测的是空气)");

/* ★ 这一拍是整条用例的重点:play() **还没返回**。
   此时 playing 还是上一集、mpv 还停在上一集的最后一帧(keep-open=yes 不卸载文件)。
   黑屏层如果不在,用户看到的就是"上一个视频的画面当背景"。
   把黑屏复位放在 afterStart(play() 之后)只能盖住后半段,这一拍会红。 */
await sleep(700);
must(
  await ev(`!!document.querySelector('.p-loading')`),
  "点了下一集、play() 还没返回 → 必须**立刻**变黑(这一拍就是用户看到上一片画面的那几秒)",
);

/* play() 返回之后,新片仍在缓冲(位置停在 0,而上一片已经播到 12 秒)。 */
await sleep(1800);
await ev(`window.__ST = { ...window.__ST, time: 0, buffering: true, cache_speed: 524288 }`);
await sleep(700);
must(
  await ev(`!!document.querySelector('.p-loading')`),
  "新片起播了但还没出画 → 黑屏层继续盖着",
);
await ev(`window.__PLAY_DELAY = 0`);

/* ============================================================
   主窗:媒体库屏蔽
   ============================================================ */
console.log("\n══ 主窗 · 屏蔽 ══");
await cmd("Page.addScriptToEvaluateOnNewDocument", { source: stub("main") });
await cmd("Page.navigate", { url: `http://127.0.0.1:${PORT_HTTP}/index.html` });
await sleep(3000);

const rightClick = async (sel) => ev(`(() => {
  const c = document.querySelector(${JSON.stringify(sel)});
  if (!c) return false;
  c.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, clientX: 300, clientY: 300 }));
  return true;
})()`);
const rightClickCard = () => rightClick('.pitem');
must(await rightClickCard(), "首页上有卡片可以右键");
await sleep(500);
const menuText = await ev(`document.querySelector('.ctxmenu')?.innerText || ''`);
must(/屏蔽/.test(menuText), `右键菜单里有屏蔽项,实际「${menuText.replace(/\n/g, " / ")}」`);

await ev(`window.__CALLS = []`);
await ev(`(() => {
  const mi = [...document.querySelectorAll('.ctxmenu .mi')].find(x => /屏蔽/.test(x.innerText));
  mi && mi.click();
})()`);
await sleep(800);
const arg = await lastCall("set_blocked");
console.log("   set_blocked 参数:" + JSON.stringify(arg));
/* ★ name 必须是**剧名**。分集卡的 item.name 是「第 1 集」——
   传成集名的话观看记录那条按名字的跨服比对永远命中不了,而且一声不吭。 */
must(arg && arg.blocked === true, "点「屏蔽」要真的发 set_blocked(只改 React state 的话刷新就没了)");
must(arg && arg.name === "某剧", `屏蔽记的必须是剧名「某剧」,实际「${arg?.name}」—— 记成集名 = 播放记录永远滤不掉`);

/* ---------- 媒体库本身 ---------- */
/* 用户 2026-08-02:「媒体库里面右键媒体库弹出的选项根本就没有屏蔽媒体库,
   我在首页的媒体库栏也没有」。
   ★ 这两条是我上一轮**漏测**的:只右键了条目卡(.pitem),没右键库卡。
     库卡走的是另一套菜单(媒体库页那套原来还是 admin-only),条目卡绿不代表它绿。 */
console.log("\n── 屏蔽整个媒体库 ──");
must(await rightClick('.hm-lib'), "首页「媒体库」轨里的库卡片能右键");
await sleep(500);
const libMenuHome = await ev(`document.querySelector('.ctxmenu')?.innerText || ''`);
must(/屏蔽此媒体库/.test(libMenuHome), `首页库卡右键菜单里有「屏蔽此媒体库」,实际「${libMenuHome.replace(/\n/g, " / ")}」`);

await ev(`window.__CALLS = []`);
await ev(`(() => {
  const mi = [...document.querySelectorAll('.ctxmenu .mi')].find(x => /屏蔽此媒体库/.test(x.innerText));
  mi && mi.click();
})()`);
await sleep(800);
const libArg = await lastCall("set_blocked");
console.log("   set_blocked(库) 参数:" + JSON.stringify(libArg));
must(libArg && libArg.itemId === "v1" && libArg.blocked === true, "点了要真的发 set_blocked,且带的是**库**的 id");

/* 媒体库页的库卡:菜单里同样要有,而且**不能是 admin-only** —— 假后端的 is_admin=false,
   原来那套 `if (!admin) return` 会让右键什么都不弹(这正是用户撞到的)。 */
await ev(`(() => { const b = [...document.querySelectorAll('.side-nav button, .nav button, button')].find(x => x.innerText.trim() === '媒体库'); b && b.click(); return !!b; })()`);
await sleep(1500);
must(await rightClick('.lib-card'), "媒体库页里列出的库卡片能右键(非管理员也要能)");
await sleep(500);
const libMenuPage = await ev(`document.querySelector('.ctxmenu')?.innerText || ''`);
must(
  /屏蔽/.test(libMenuPage),
  `媒体库页的库卡右键菜单里有屏蔽项,实际「${libMenuPage.replace(/\n/g, " / ")}」`,
);

console.log(fail === 0 ? "\n全绿 ✅" : `\n${fail} 条红 ❌`);
ws.close();
server.close();
proc.kill();
process.exit(fail === 0 ? 0 : 1);
