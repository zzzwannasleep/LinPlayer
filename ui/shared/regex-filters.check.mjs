/* 「正则优先选择」端到端自检 —— PC 端 + 手机端,真渲染、真点击、真看发出去的命令。
 *
 * ## 为什么必须是这种测法
 * 这个功能的核层(crates/core/src/media.rs)一直有单测而且全绿,文档也写得明明白白,
 * 但用户报「按官网写好了却匹配不了」—— 因为**三个 bug 全在前端接线上**,
 * 一条 Rust 单测都照不到:
 *   1. 详情页无论用户有没有手动选版本,都把 `versions[0].id` 传给核层 play(),
 *      核层看见 media_source_id=Some(..) 就走「手动优先」分支 → **版本正则永远不参与**;
 *   2. 手机端「高级筛选规则」的保存按钮只改了 React state,从没调 set_track_regexes
 *      → 关掉面板就没了,重进还是空;
 *   3. 起播后的 apply_prefs 只在 1.2s 打一枪,网络流那会儿 track-list 还没 demux 出内封轨
 *      → 字幕/音频正则匹配了个空表。(这条在 track-poll.test.mjs 里测,不在这)
 *   4. 详情页/播放器面板的「当前版本」写死回落列表第一条,而实际在播的是正则挑中的那条 ——
 *      **起播其实已经对了,界面却全程在说「在放第一条」**,用户据此判定「正则根本没生效」
 *      (2026-07-30 用户挂真机实测报的就是这个)。核层现在给 `preferred` 标出那一条。
 * 所以断言的落点是**发给核层的 invoke 参数**,不是 UI 上有没有那个输入框。
 *
 * ## 跑法
 *   npx vite build && node ui/shared/regex-filters.check.mjs
 *
 * ## 纪律
 * 断言必须先红过。改这个文件时先把被测的接线改回旧写法,确认它真的报红。
 * 修复前实测红的是这三条(其余几条当时就是绿的,正好证明这套驱动本身没走丢):
 *   手机端「没手动选版本 → null」= ms-1080 ✗
 *   手机端「三条正则真落库」  = 一次 set_track_regexes 都没发 ✗
 *   桌面端「没手动选版本 → null」= ms-1080 ✗
 */
import { spawn } from "node:child_process";
import { existsSync } from "node:fs";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";

const ROOT = process.cwd();
const DIST = join(ROOT, "dist");
const PORT_HTTP = 4193;
const PORT_CDP = 9527;

const bin = [
  "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
  "C:/Program Files/Microsoft/Edge/Application/msedge.exe",
].find(existsSync);
if (!bin) {
  console.error("找不到 Edge");
  process.exit(1);
}
if (!existsSync(join(DIST, "index-mobile.html")) || !existsSync(join(DIST, "index.html"))) {
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

/* ---------- 假后端 ---------- */
const ITEM = {
  id: "it1", name: "测试电影", type_: "Movie", is_folder: false, has_primary: true,
  runtime_secs: 3600, resume_secs: 0, series_name: null, episode_no: null, season_no: null,
  video_height: 2160, bitrate: 2e7, size_bytes: 4e9, played: false, unplayed_item_count: 0,
  genres: ["剧情"], year: 2024, rating: 8, provider_ids: {}, presentation_unique_key: null,
  path: null, series_id: null, date_updated: "2026-07-01T00:00:00Z", sort_name: "测试电影",
};
const DETAIL = {
  id: "it1", name: "测试电影", type_: "Movie", overview: "简介", year: 2024, genres: ["剧情"],
  rating: 8, runtime_secs: 3600, resume_secs: 0, has_primary: true, has_backdrop: false,
  is_favorite: false, series_name: null, series_id: null, season_no: null, episode_no: null,
  official_rating: null, status: null, tagline: null, child_count: null, children: [], people: [],
};
const st = (i, t, extra = {}) => ({
  index: i, type_: t, codec: "h264", profile: null, display_title: t, language: "chi",
  width: null, height: null, bitrate: null, channels: null, channel_layout: null,
  frame_rate: null, video_range: null, video_range_type: null, is_default: i === 0,
  is_external: false, delivery_url: null, ...extra,
});
/* 两条版本:第一条 1080p、第二条 4K。核层的版本正则(如 `4K|2160`)本来就是为了
   **不要**默认拿第一条 —— 所以「传了第一条的 id」和「传 null」在这里是可分辨的。 */
const VERS = [
  { id: "ms-1080", name: "1080p x264", container: "mkv", size_bytes: 1e9, bitrate: 5e6,
    runtime_secs: 3600, preferred: false,
    streams: [st(0, "Video", { height: 1080 }), st(1, "Audio"), st(2, "Subtitle")] },
  /* ★ preferred = 版本正则挑中的那条(核层 media_versions 标的)。这里故意标**第二条**:
     界面必须显示它,而不是列表第一条 —— 显示第一条、播第二条,用户看到的就是「正则没生效」。 */
  { id: "ms-4k", name: "2160p HEVC", container: "mkv", size_bytes: 4e9, bitrate: 2e7,
    runtime_secs: 3600, preferred: true,
    streams: [st(0, "Video", { height: 2160 }), st(1, "Audio"), st(2, "Subtitle")] },
];
const DATA = {
  current_session: { server: "http://stub", token: "t", user_id: "u", user_name: "stub" },
  current_source: null, views: [{ ...ITEM, id: "v1", name: "电影", type_: "CollectionFolder", is_folder: true }],
  list_items_page: { items: [ITEM], total: 1 }, list_latest: [ITEM], list_resume: [ITEM],
  list_next_up: [], list_random: [ITEM], list_favorites: [], aggregate_search: [],
  aggregate_overview: [], list_accounts: [], probe_accounts: [], download_list: [],
  ranking_categories: [], ranking_fetch: [], bangumi_calendar: [], trakt_calendar: [],
  get_danmaku_config: [], shader_levels: [], icon_library: [], source_list_dir: [],
  plugin_list: [], plugin_market_list: { plugins: [], errors: [] }, plugin_market_sources: [],
  anirss_list_ani: [], anirss_torrents_infos: [], cache_size: 0, plugin_panels: [],
  list_collections: [], is_admin: false, check_update: null,
  item_detail: DETAIL, item_media: VERS, similar_items: [], chapter_info: [],
  play: 0, tracks: [], seasons: [], season_episodes: { items: [], total: 0 },
  get_playback_prefs: { hwdec: "auto-safe", default_speed: 1, skip_intro: false, skip_outro: false,
    preview_thumbs: true, dolby_auto_sw: true, external_player: "" },
  get_prefs: { audio_lang: null, sub_lang: null, sub_enabled: true, version_regex: "",
    sub_regex: "", audio_regex: "", detail_blur: 0 },
  get_prefetch_settings: { servers: [], threads: 2, cache_bytes: 268435456 },
  get_writeback_settings: { enabled: false, range: "all", include_progress: false },
  get_cross_server_resume: false, trakt_account: null, bangumi_account: null,
  get_update_settings: { channel: "stable", auto_check: true, current_version: "1.4.2", can_self_update: true },
};
/* ★ metadata 不能省:桌面壳一进来就 getCurrentWindow(),缺了它整页白板 ——
   而白板下面所有断言都会以「找不到元素」的形式红,看起来像是被测功能坏了。 */
const STUB = `(() => {
  window.__CALLS = [];
  const D = ${JSON.stringify(DATA)};
  window.__TAURI_INTERNALS__ = {
    invoke: (c, a) => { window.__CALLS.push({ c, a }); return Promise.resolve(c in D ? D[c] : (c.startsWith("plugin:") ? 1 : null)); },
    transformCallback: (cb) => cb,
    convertFileSrc: (p) => "stub://" + p,
    metadata: { currentWindow: { label: "main" }, currentWebview: { windowLabel: "main", label: "main" } },
  };
})()`;
await cmd("Page.addScriptToEvaluateOnNewDocument", { source: STUB });

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
const resetCalls = () => ev(`window.__CALLS = []`);
/* React 受控 input:必须走原生 setter 再派 input 事件,直接 el.value = x 是不算数的。 */
const typeInto = (sel, v) => ev(`(() => {
  const el = ${sel};
  if (!el) return false;
  const set = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
  set.call(el, ${JSON.stringify(v)});
  el.dispatchEvent(new Event("input", { bubbles: true }));
  return true;
})()`);

const WANT = { version_regex: "4K|2160", sub_regex: "中文|简|繁|chi", audio_regex: "jpn|日" };

/* ============================================================
   手机端
   ============================================================ */
console.log("\n══ 手机端 ══");
await cmd("Emulation.setDeviceMetricsOverride", {
  width: 390, height: 844, deviceScaleFactor: 2, mobile: true,
  screenOrientation: { angle: 0, type: "portraitPrimary" },
});
const mTop = `[...document.querySelectorAll('.stack:not([hidden]) .pg:not([data-leaving])')].pop()`;
/* 每个场景都从冷启动重来。手机端是**真页面栈**不是 history,
   用 history.back() 退不回去 —— 上一版这么写,后面几条全在错误的页面上跑,
   报出来的红是"找不到元素",看起来像被测功能坏了(而其实是测试自己走丢了)。 */
const mobileBoot = async () => {
  await cmd("Page.navigate", { url: `http://127.0.0.1:${PORT_HTTP}/index-mobile.html` });
  await sleep(2800);
};
const mobileDetail = async () => {
  await mobileBoot();
  await ev(`(() => { const c = [...${mTop}.querySelectorAll(".card-a")].pop(); c && c.click(); })()`);
  await sleep(1500);
};

console.log("\n── 版本正则:没手动选版本时必须传 null ──");
await mobileDetail();
must(await ev(`!!${mTop}.querySelector('.dt-play')`), "进得了详情页(有播放按钮)");
const mVerRow = await ev(`(() => {
  const r = [...${mTop}.querySelectorAll('.dt-row')].find(x => x.innerText.startsWith('版本'));
  return r ? r.innerText.replace(/\s+/g, ' ') : '';
})()`);
must(
  /2160p/.test(mVerRow),
  `「版本」那行要显示正则挑中的那条(2160p),实际「${mVerRow}」—— 显示第一条而播第二条 = 用户眼里的「没生效」`,
);
await resetCalls();
await ev(`${mTop}.querySelector('.dt-play').click()`);
await sleep(900);
let a = await lastCall("play");
console.log("   play 参数:" + JSON.stringify(a));
must(
  a && a.mediaSourceId === null,
  `没动过版本选择器 → mediaSourceId 必须是 null(实际 ${JSON.stringify(a?.mediaSourceId)})` +
    " —— 传了第一条的 id 等于每次都「手动选了第一版」,版本正则永远轮不到",
);

console.log("\n── 版本正则:手动选了版本必须照传 ──");
await mobileDetail();
await ev(`(() => {
  const r = [...${mTop}.querySelectorAll('.dt-row')].find(x => x.innerText.startsWith('版本'));
  r && r.click();
})()`);
await sleep(700);
const picked = await ev(`(() => {
  const o = [...document.querySelectorAll('.opt')].find(x => x.innerText.includes('2160p'));
  if (!o) return false;
  o.click();
  return true;
})()`);
must(picked, "版本面板里点得到 2160p 那一条");
await sleep(700);
await resetCalls();
await ev(`${mTop}.querySelector('.dt-play').click()`);
await sleep(900);
a = await lastCall("play");
must(
  a && a.mediaSourceId === "ms-4k",
  `手动选了 2160p → mediaSourceId 必须是 ms-4k(实际 ${JSON.stringify(a?.mediaSourceId)})`,
);

console.log("\n── 三条正则必须真落库 ──");
await mobileBoot();
await ev(`[...document.querySelectorAll('.home-bar .tb-r button')].pop()?.click()`);
await sleep(900);
await ev(`(() => {
  const c = [...${mTop}.querySelectorAll('.cell')].find(x => x.textContent.startsWith('播放'));
  c && c.click();
})()`);
await sleep(900);
const openedSheet = await ev(`(() => {
  const c = [...${mTop}.querySelectorAll('.cell')].find(x => /筛选|正则|规则/.test(x.textContent));
  if (!c) return false;
  c.click();
  return true;
})()`);
must(openedSheet, "设置 → 播放 里有「高级筛选规则」入口");
await sleep(700);
const fields = await ev(`document.querySelectorAll('.sheet input, .sht input, [class*=sheet] input').length`);
must(fields >= 3, `筛选面板里有三个输入框(实际 ${fields})`);
for (const [i, v] of [WANT.version_regex, WANT.sub_regex, WANT.audio_regex].entries()) {
  await typeInto(`document.querySelectorAll('.sheet input, .sht input, [class*=sheet] input')[${i}]`, v);
}
await resetCalls();
await ev(`(() => {
  const b = [...document.querySelectorAll('.sheet-acts .btn, [class*=sheet] button')].find(x => x.innerText.trim() === '保存');
  b && b.click();
})()`);
await sleep(900);
a = await lastCall("set_track_regexes");
console.log("   set_track_regexes 参数:" + JSON.stringify(a));
must(
  a && a.versionRegex === WANT.version_regex && a.subRegex === WANT.sub_regex && a.audioRegex === WANT.audio_regex,
  "点保存要真的把三条正则发给核层 —— 只改 React state 的话关掉面板就没了",
);

/* ============================================================
   桌面端
   ============================================================ */
console.log("\n══ 桌面端 ══");
await cmd("Emulation.setDeviceMetricsOverride", { width: 1440, height: 900, deviceScaleFactor: 1, mobile: false });
await cmd("Page.navigate", { url: `http://127.0.0.1:${PORT_HTTP}/index.html` });
await sleep(3200);

console.log("\n── 版本正则:没手动选版本时必须传 null ──");
await ev(`document.querySelector('.pcard')?.click()`);
await sleep(1800);
must(await ev(`!!document.querySelector('.dt-playbar .btn.primary')`), "进得了详情页(有播放按钮)");
const dVerSel = await ev(`(() => {
  const s = [...document.querySelectorAll('.sel')].find(x => x.innerText.startsWith('版本'));
  return s ? s.innerText.replace(/\s+/g, ' ') : '';
})()`);
must(
  /2160p/.test(dVerSel),
  `版本选择器要显示正则挑中的那条(2160p),实际「${dVerSel}」`,
);
await resetCalls();
await ev(`document.querySelector('.dt-playbar .btn.primary')?.click()`);
await sleep(1000);
a = await lastCall("play");
console.log("   play 参数:" + JSON.stringify(a));
must(
  a && a.mediaSourceId === null,
  `没动过版本选择器 → mediaSourceId 必须是 null(实际 ${JSON.stringify(a?.mediaSourceId)})`,
);

console.log("\n── 版本正则:手动选了版本必须照传 ──");
await ev(`(() => {
  const s = [...document.querySelectorAll('.sel')].find(x => x.innerText.startsWith('版本'));
  s && s.click();
})()`);
await sleep(500);
const picked2 = await ev(`(() => {
  const li = [...document.querySelectorAll('.dd .li')].find(x => x.innerText.includes('2160p'));
  if (!li) return false;
  li.click();
  return true;
})()`);
must(picked2, "版本下拉里点得到 2160p 那一条");
await sleep(500);
await resetCalls();
await ev(`document.querySelector('.dt-playbar .btn.primary')?.click()`);
await sleep(1000);
a = await lastCall("play");
must(
  a && a.mediaSourceId === "ms-4k",
  `手动选了 2160p → mediaSourceId 必须是 ms-4k(实际 ${JSON.stringify(a?.mediaSourceId)})`,
);

console.log("\n── 三条正则必须真落库 ──");
await ev(`[...document.querySelectorAll('.nav-item')].find(x => x.innerText.trim() === '设置')?.click()`);
await sleep(1200);
await ev(`(() => {
  const it = [...document.querySelectorAll('.mdnav .it, .mdnav button')].find(x => /播放/.test(x.innerText));
  it && it.click();
})()`);
await sleep(900);
/* 面板里的 .fld 不止这三个(还有首选音频/字幕语言),按 label 认才不会错位。 */
const RE_FLD = (label) =>
  `[...document.querySelectorAll('.mdpane .fld')].find(f => f.querySelector('label')?.textContent === ${JSON.stringify(label)})?.querySelector('input.field')`;
const flds = await ev(
  `[${["版本筛选", "字幕筛选", "音频筛选"].map((l) => RE_FLD(l)).join(",")}].filter(Boolean).length`,
);
must(flds === 3, `播放器面板里有版本/字幕/音频三个正则输入框(实际 ${flds})`);
await resetCalls();
/* ★ React 的 onBlur 挂的是 **focusout**(合成事件走委托),派 "blur" 是不冒泡的,
   永远进不了 React —— 上一版就这么写,断言红得像是保存逻辑坏了。 */
for (const [label, v] of [
  ["版本筛选", WANT.version_regex],
  ["字幕筛选", WANT.sub_regex],
  ["音频筛选", WANT.audio_regex],
]) {
  await typeInto(RE_FLD(label), v);
  await ev(`${RE_FLD(label)}.dispatchEvent(new FocusEvent("focusout", { bubbles: true }))`);
  await sleep(400);
}
await sleep(600);
a = await lastCall("set_track_regexes");
console.log("   set_track_regexes 参数:" + JSON.stringify(a));
must(
  a && a.versionRegex === WANT.version_regex && a.subRegex === WANT.sub_regex && a.audioRegex === WANT.audio_regex,
  "三个框失焦后三条正则一起落库",
);

console.log(fail === 0 ? "\n全绿 ✅" : `\n${fail} 条红 ❌`);
ws.close();
server.close();
proc.kill();
process.exit(fail === 0 ? 0 : 1);
