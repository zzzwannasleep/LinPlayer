/* 本地/局域网源(本地播放 / SMB / WebDAV / FTP)端到端自检 —— 真渲染、真点、真看发出去的命令。
 *
 * ## 为什么必须是这种测法
 * 这三个源的核层有单测(webdav 的 PROPFIND 解析、ftp 的 LIST 解析、smb 的路径拆分),
 * 而且全绿。但用户要的是**「第一次登录那一屏就能加」** —— 这句话的成败全在前端接线上,
 * 一条 Rust 单测都照不到:
 *   · 源加进了 BUILTIN_SOURCES 却没进登录闸口(闸口有 exclude 名单)→ 新用户永远看不到;
 *   · 手机端加了源却没加对应的**大类**(SOURCE_SECS)→ 第一步选不到,第二步就进不去;
 *   · 地址框占位符共用一个 https:// → 用户在 SMB 的框里照着填,必然连不上;
 *   · 提交按钮的 case 没补 → 点了没反应,而且**编译全绿**(switch 缺分支不报错)。
 * 所以断言的落点是**发给核层的 invoke 参数**,不是「界面上有没有那个字」。
 *
 * ## 跑法
 *   npx vite build && node ui/shared/lan-sources.check.mjs
 *
 * ## 纪律:断言必须先红过
 * 写完后逐条反向注入验过(见文末 REDCHECK 注释),不是「写完看着绿就完事」。
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

/* ---------- 假后端:**一个账号都没有**,这样两端都会停在首次登录闸口 ---------- */
const DATA = {
  // 闸口的判据:没有会话、也没有活跃的浏览型源。
  current_session: null,
  current_source: null,
  list_accounts: [],
  probe_accounts: [],
  plugin_data_sources: [],
  plugin_sources: [],
  // 「本地播放」的文件夹选择器。真机上是系统对话框,这里给个固定路径,
  // 好把「选完 → 显示出来 → 点添加」整条链走通。
  pick_local_folder: "D:\\影片\\测试",
  startup_deep_link: null,
  plugin_list: [],
  source_login: null,
  views: [],
  list_latest: [],
  list_resume: [],
  list_next_up: [],
  get_prefs: { audio_lang: null, sub_lang: null, sub_enabled: true, version_regex: "",
    sub_regex: "", audio_regex: "", detail_blur: 0 },
  check_update: null,
  is_admin: false,
  /* ★ 这几个是**桌面壳一进来就要的**。少一个就是 `null.xxx` 抛错 → 整页白板,
     而白板下面每一条断言都会以「找不到元素」的形式红,看着像被测功能坏了。 */
  shader_levels: [],
  get_playback_prefs: { hwdec: "auto-safe", default_speed: 1, skip_intro: false, skip_outro: false,
    preview_thumbs: true, dolby_auto_sw: true, external_player: "" },
  get_update_settings: { channel: "stable", auto_check: true, current_version: "1.4.2", can_self_update: true },
  get_danmaku_config: [],
  list_collections: [],
};
const STUB = `(() => {
  window.__CALLS = [];
  window.__ERR = [];
  addEventListener("error", (e) => window.__ERR.push(String(e.message)));
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
/* React 受控 input:必须走原生 setter 再派 input 事件,直接 el.value = x 不算数。 */
const typeInto = (sel, v) => ev(`(() => {
  const el = ${sel};
  if (!el) return false;
  const set = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
  set.call(el, ${JSON.stringify(v)});
  el.dispatchEvent(new Event("input", { bubbles: true }));
  return true;
})()`);

const LAN = ["smb", "webdav", "ftp"];

/* ============================================================
   桌面端:首次登录闸口
   ============================================================ */
console.log("\n══ 桌面端 · 首次登录闸口 ══");
await cmd("Emulation.setDeviceMetricsOverride", {
  width: 1440, height: 900, deviceScaleFactor: 1, mobile: false,
  screenOrientation: { angle: 0, type: "landscapePrimary" },
});
await cmd("Page.navigate", { url: `http://127.0.0.1:${PORT_HTTP}/index.html` });
await sleep(2600);

const pageErr = await ev(`window.__ERR`);
if (pageErr?.length) console.log("      ⚠ 页面抛错:", JSON.stringify(pageErr));
must(await ev(`!!document.querySelector('.lg-body, .lg-card, .login')`), "停在了首次登录闸口");

/* 闸口里的源选择器。它和「添加服务器」页共用 BUILTIN_SOURCES,
   但闸口自己有 exclude 名单 —— 漏进 exclude 的源新用户永远看不到。 */
const gateLabels = await ev(`(() =>
  [...document.querySelectorAll('.lg-body button, .lg-body .chip, .lg-chip, .as-nav button')]
    .map(b => (b.innerText || '').trim()).filter(Boolean)
)()`);
console.log("      闸口里的源:", JSON.stringify(gateLabels));

must(gateLabels.some((t) => t.includes("SMB")), "闸口里有 SMB");
must(gateLabels.some((t) => /WebDAV/i.test(t)), "闸口里有 WebDAV");
must(gateLabels.some((t) => /\bFTP\b/i.test(t)), "闸口里有 FTP");
must(gateLabels.some((t) => t.includes("本地播放")), "闸口里有「本地播放」");

/* 点 SMB → 地址框的占位符必须是 UNC,不能是共用的 https://。
   共用一个占位符的话,用户会照着 https:// 去填 SMB,连不上还看不出为什么。 */
const clickByText = (txt) => ev(`(() => {
  const b = [...document.querySelectorAll('.lg-body button, .lg-body .chip, .lg-chip, .as-nav button')]
    .find(x => (x.innerText || '').includes(${JSON.stringify(txt)}));
  if (!b) return false; b.click(); return true;
})()`);

must(await clickByText("SMB"), "点得动 SMB");
await sleep(600);
const smbPh = await ev(`(() => {
  const i = [...document.querySelectorAll('input.field')].find(x => /192\\.168|smb|http/i.test(x.placeholder || ''));
  return i ? i.placeholder : null;
})()`);
console.log("      SMB 地址框占位符:", JSON.stringify(smbPh));
must(!!smbPh && !/^https:\/\//.test(smbPh), "SMB 地址框没有沿用 https:// 占位符");
must(!!smbPh && /\\\\|smb:/i.test(smbPh), "SMB 占位符给的是 UNC / smb:// 样式");

/* 真填、真点、真看 invoke —— 这条才是「点了到底有没有反应」的判据。
   switch 少一个 case 时按钮点了不报错、编译也全绿,只有这里能抓到。 */
await resetCalls();
const inputs = `[...document.querySelectorAll('input.field')]`;
await typeInto(`${inputs}.find(x => /192\\.168|smb:/i.test(x.placeholder||''))`, "\\\\192.168.1.50");
const texts = `[...document.querySelectorAll('input.field')].filter(x => x.type !== 'password')`;
// 用户名 = 除名称/地址外的第一个文本框;密码框按 type 找。
await ev(`(() => {
  const all = ${texts};
  const u = all[all.length - 1];
  if (u) {
    const set = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
    set.call(u, "nasuser"); u.dispatchEvent(new Event("input", { bubbles: true }));
  }
  const p = document.querySelector('input.field[type=password]');
  if (p) {
    const set = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, "value").set;
    set.call(p, "naspass"); p.dispatchEvent(new Event("input", { bubbles: true }));
  }
})()`);
await sleep(200);
await ev(`(() => {
  const b = [...document.querySelectorAll('button.btn.primary')].find(x => !x.disabled);
  if (b) b.click();
})()`);
await sleep(900);
const call = await lastCall("source_login");
console.log("      source_login 参数:", JSON.stringify(call));
must(!!call, "点了主按钮真的发出了 source_login(没发 = switch 少了 case)");
must(call?.kind === "smb", `kind 传的是 smb(实际 ${call?.kind}）`);
must(
  typeof call?.baseUrl === "string" ? call.baseUrl.includes("192.168.1.50")
    : String(call?.base_url || "").includes("192.168.1.50"),
  "地址原样传给了核层",
);

/* ---------- 本地播放:选文件夹 → 添加 ---------- */
console.log("\n── 本地播放 ──");
must(await clickByText("本地播放"), "点得动「本地播放」");
await sleep(500);

/* 这一屏**不该有地址框**。摆一个路径输入框等于让用户手打路径,
   而他马上就要在系统选择器里点那个文件夹了。 */
const addrCount = await ev(`document.querySelectorAll('input.field[placeholder*="://"], input.field[placeholder*="192.168"]').length`);
must(addrCount === 0, `本地播放没有多余的地址框(实际 ${addrCount} 个)`);

await resetCalls();
must(
  await ev(`(() => {
    const b = [...document.querySelectorAll('button.btn')].find(x => (x.innerText||'').includes('选择文件夹'));
    if (!b) return false; b.click(); return true;
  })()`),
  "有「选择文件夹…」按钮且点得动",
);
await sleep(700);
must(!!(await lastCall("pick_local_folder")), "点了真的调起了系统文件夹选择器(pick_local_folder)");

/* 挑完要把路径显示出来让用户核对 —— 挑错目录时这是唯一的补救机会。 */
must(
  await ev(`document.body.innerText.includes("D:\\\\影片\\\\测试")`),
  "挑中的路径显示出来了",
);

await resetCalls();
await ev(`(() => {
  const b = [...document.querySelectorAll('button.btn.primary')].find(x => !x.disabled);
  if (b) b.click();
})()`);
await sleep(900);
const lcall = await lastCall("source_login");
console.log("      source_login 参数:", JSON.stringify(lcall));
must(!!lcall, "点添加真的发出了 source_login");
must(lcall?.kind === "local", `kind 传的是 local(实际 ${lcall?.kind}）`);
must(
  String(lcall?.baseUrl || lcall?.base_url || "").includes("影片"),
  "挑中的文件夹路径原样传给了核层(base_url)",
);

/* ============================================================
   手机端:首次登录闸口(两步选源)
   ============================================================ */
console.log("\n══ 手机端 · 首次登录闸口 ══");
await cmd("Emulation.setDeviceMetricsOverride", {
  width: 390, height: 844, deviceScaleFactor: 2, mobile: true,
  screenOrientation: { angle: 0, type: "portraitPrimary" },
});
await cmd("Page.navigate", { url: `http://127.0.0.1:${PORT_HTTP}/index-mobile.html` });
await sleep(2800);

/* 第一步是**大类**。源加进了 SOURCE_KINDS 但没加进 SOURCE_SECS 的话,
   这一屏根本没有入口,后面全都白搭(而且不报错)。 */
const cats = await ev(`(() =>
  [...document.querySelectorAll('.stp-cats button')].map(b => (b.innerText||'').trim())
)()`);
console.log("      大类:", JSON.stringify(cats));
must(cats.some((t) => t.includes("局域网")), "第一步有「局域网 / 本地」这个大类");
/* 大类里不能留空壳:某个大类下面一个源都不剩时必须一起删掉,
   否则用户点进去是一片空白 —— 这是删源时的高发漏项。 */
const secOf = (t) => t.split(String.fromCharCode(10))[0].trim();
must(cats.every((c) => secOf(c).length > 0), "没有空标题的大类");

must(
  await ev(`(() => {
    const b = [...document.querySelectorAll('.stp-cats button')].find(x => (x.innerText||'').includes('局域网'));
    if (!b) return false; b.click(); return true;
  })()`),
  "点得进「局域网 / 本地」",
);
await sleep(700);
const kinds = await ev(`(() =>
  [...document.querySelectorAll('button, .chip, [role=button]')]
    .map(b => (b.innerText||'').trim()).filter(Boolean)
)()`);
const hasAll = LAN.every((k) =>
  kinds.some((t) => new RegExp(k === "smb" ? "SMB" : k, "i").test(t)),
);
must(hasAll, `三种局域网源都列出来了(看到的: ${JSON.stringify(kinds.slice(0, 8))})`);

await cmd("Emulation.clearDeviceMetricsOverride");
console.log(fail ? `\n✗ ${fail} 条没过` : "\n✅ 局域网源自检全通过");
try { ws.close(); } catch {}
proc.kill();
server.close();
process.exit(fail ? 1 : 0);

/* REDCHECK(反向注入验过的):
   · 从 BUILTIN_SOURCES 删掉 smb 那行 → 「闸口里有 SMB」「点得动 SMB」「发出了 source_login」全红;
   · 把 creds(true, "...") 的第二个参数去掉(退回共用 https:// 占位符)→ 两条占位符断言红;
   · 主按钮 switch 里删掉 case "smb" → 「发出了 source_login」红,而 tsc 依然全绿(正是它存在的理由);
   · 手机端 SOURCE_SECS 里删掉「局域网 / 本地」→ 「第一步有大类」红。 */
