/* 端到端自检:起真进程、走真 HTTP,验白名单 / 短期缓存 / 弹幕库 / 出站闸门 / 管理界面。
 *
 * ★ 自带一个**假的弹弹Play**(UPSTREAM_BASE 指过去)。真上游打一次就是真烧一次配额 ——
 *   而这个服务存在的全部理由就是省配额,自检去刷配额是荒唐的。
 *   假上游会校验签名头,所以"代理有没有真的签名"这条照样测得到。
 *
 * 跑法:
 *   cargo build -p linplayer-danmaku-proxy
 *   node crates/danmaku-proxy/e2e.mjs
 *
 * 跑一趟约 20 秒 —— 其中 17 秒是在等刷新间隔过期(下限 5 秒 × 3 轮)。
 * 那三轮等的是本服务最核心的行为(合并、不再增长、上游挂了回存量),不能省。
 */
import http from "node:http";
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

const UP_PORT = 8798;
const PORT = 8799;
const BASE = `http://127.0.0.1:${PORT}`;
const ADMIN_PW = "e2e-admin-pw-12345";
const DATA = path.join(os.tmpdir(), `lp-danmaku-proxy-e2e-${process.pid}`);
const BIN = path.resolve(
  "target",
  "debug",
  process.platform === "win32" ? "linplayer-danmaku-proxy.exe" : "linplayer-danmaku-proxy",
);

if (!fs.existsSync(BIN)) {
  console.error(`!! 找不到 ${BIN}`);
  console.error("   先跑:cargo build -p linplayer-danmaku-proxy");
  process.exit(2);
}

// ---------- 假上游 ----------
/** 下一次 /comment 要返回哪些 cid;设成 null = 返回错误(模拟上游挂了/配额用尽)。 */
let nextComments = [1, 2, 3];
let upstreamCalls = 0;
const upstream = http.createServer((req, res) => {
  upstreamCalls++;
  const u = new URL(req.url, "http://x");
  res.setHeader("Content-Type", "application/json");
  // 代理必须签名。不签这里就报 403 —— 「有没有真签」不靠读代码,靠上游说话。
  if (!(req.headers["x-appid"] && req.headers["x-signature"] && req.headers["x-timestamp"])) {
    return res.end(JSON.stringify({ errorCode: 403, errorMessage: "缺少签名(代理没签)" }));
  }
  if (u.pathname.includes("/comment/")) {
    if (nextComments === null) {
      return res.end(JSON.stringify({ errorCode: 429, errorMessage: "已达到接口调用配额上限" }));
    }
    const comments = nextComments.map((c) => ({ cid: c, p: "1.0,1,16777215,u", m: `弹幕${c}` }));
    return res.end(JSON.stringify({ count: comments.length, comments }));
  }
  if (u.searchParams.get("keyword") === "quota") {
    return res.end(JSON.stringify({ errorCode: 429, errorMessage: "已达到接口调用配额上限" }));
  }
  res.end(JSON.stringify({ errorCode: 0, animes: [{ animeId: 1, animeTitle: "假的番" }] }));
});
await new Promise((r) => upstream.listen(UP_PORT, "127.0.0.1", r));

// ---------- 被测进程 ----------
fs.rmSync(DATA, { recursive: true, force: true });
const proc = spawn(BIN, [], {
  stdio: "ignore",
  env: {
    ...process.env,
    DATA_DIR: DATA,
    PORT: String(PORT),
    BIND: "127.0.0.1",
    UPSTREAM_BASE: `http://127.0.0.1:${UP_PORT}`,
    DANDANPLAY_APP_ID: "e2e-id",
    DANDANPLAY_APP_SECRET: "e2e-secret",
    ADMIN_PASSWORD: ADMIN_PW,
  },
});

let fails = 0;
const check = (name, cond, detail) => {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${cond ? "" : `\n      ${detail}`}`);
  if (!cond) fails++;
};
const head = (t) => console.log(`\n== ${t} ==`);
const j = async (r) => {
  try {
    return await r.json();
  } catch {
    return null;
  }
};
const post = (p, body, cookie) =>
  fetch(BASE + p, {
    method: "POST",
    headers: { "Content-Type": "application/json", ...(cookie ? { Cookie: cookie } : {}) },
    body: JSON.stringify(body),
  });
/** 返回 {tag, cids, err}。tag 是 X-LP-Cache —— 唯一能看出走了哪条路的证据。 */
const getComments = async (ep) => {
  const r = await fetch(`${BASE}/api/v2/comment/${ep}?withRelated=true`);
  const b = await j(r);
  return {
    tag: r.headers.get("x-lp-cache"),
    cids: String((b?.comments ?? []).map((c) => c.cid).sort((a, z) => a - z)),
    err: b?.errorCode,
  };
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

try {
  for (let i = 0; i < 80; i++) {
    try {
      if ((await fetch(BASE + "/healthz")).ok) break;
    } catch {}
    await sleep(250);
  }

  head("不需要任何凭据");
  const open = await fetch(BASE + "/api/v2/search/anime?keyword=fake");
  check("裸请求就能用(用户 2026-08-02 定的:不做客户端鉴权)", open.status === 200, "实得 " + open.status);

  head("白名单");
  const bj = await j(await fetch(BASE + "/api/v2/user/profile"));
  check("白名单外的接口被拒", bj?.errorCode === 1005, JSON.stringify(bj));

  head("短期缓存(搜索 / 集表 / 排行榜)");
  const a = await fetch(BASE + "/api/v2/search/anime?keyword=x1&v2=true");
  check("首次穿透上游(MISS)", a.headers.get("x-lp-cache") === "MISS");
  const aj = await j(a);
  check(
    "★ 代理真的签了名(假上游会校验,没签它回 403)",
    aj?.animes?.[0]?.animeTitle === "假的番",
    JSON.stringify(aj),
  );
  check(
    "第二次命中(HIT)",
    (await fetch(BASE + "/api/v2/search/anime?keyword=x1&v2=true")).headers.get("x-lp-cache") === "HIT",
  );
  check(
    "★ 参数换个顺序仍然命中(不归一化 = 白掏配额)",
    (await fetch(BASE + "/api/v2/search/anime?v2=true&keyword=x1")).headers.get("x-lp-cache") === "HIT",
  );

  head("上游报错不入缓存");
  const e1 = await j(await fetch(BASE + "/api/v2/search/anime?keyword=quota"));
  check("429 原样透传给客户端", e1?.errorCode === 429, JSON.stringify(e1));
  check(
    "★ 报错没被存下来(存了的话配额恢复了还在看旧错误)",
    (await fetch(BASE + "/api/v2/search/anime?keyword=quota")).headers.get("x-lp-cache") !== "HIT",
  );

  head("弹幕库:入库与命中");
  nextComments = [1, 2, 3];
  const d1 = await getComments("100001");
  check("首次入库", d1.tag === "UPDATED" && d1.cids === "1,2,3", JSON.stringify(d1));
  const d2 = await getComments("100001");
  check("间隔内直接用库里的,一次上游都不发", d2.tag === "FRESH", JSON.stringify(d2));

  const lg = await post("/admin/api/login", { password: ADMIN_PW });
  const cookie = (lg.headers.get("set-cookie") || "").split(";")[0];
  const st0 = await j(await fetch(BASE + "/admin/api/state", { headers: { Cookie: cookie } }));
  // 压到配置允许的下限(5 秒),这样下面几轮等一下就能走到「过期 → 去上游看看」。
  await post("/admin/api/config", { ...st0.config, refresh_min_secs: 5, refresh_max_secs: 5 }, cookie);

  head("弹幕库:合并只增不减");
  nextComments = [3, 4, 5]; // 和首轮的 1,2,3 只有 3 重叠
  await sleep(5600);
  const m1 = await getComments("100001");
  check(
    "★ 过期后去上游拉,新旧按 cid 求并集(我们是最后一份拷贝,替换会永久毁掉历史)",
    m1.tag === "UPDATED" && m1.cids === "1,2,3,4,5",
    JSON.stringify(m1),
  );

  nextComments = [3, 4, 5]; // 这一轮一条新的都没有
  await sleep(5600);
  const m2 = await getComments("100001");
  check("一条新的都没长 → 标 NOCHANGE(自适应间隔据此翻倍)", m2.tag === "NOCHANGE", JSON.stringify(m2));
  check("而且存量一条不少", m2.cids === "1,2,3,4,5", JSON.stringify(m2));

  head("★ 上游挂了要回存量,而不是回错误");
  // 这是「自己存」相对「每次问上游」最实在的那点收益,必须端到端测到。
  nextComments = null;
  await sleep(5600); // 逼过期
  const stale = await getComments("100001");
  check(
    "★ 过期 + 上游挂了 → 回库里的存量(标 STALE),不把 429 甩给用户",
    stale.tag === "STALE" && stale.cids === "1,2,3,4,5",
    JSON.stringify(stale),
  );
  const gone = await getComments("300003");
  check("但库里根本没有的那一集,还是要如实报错", gone.err === 429, JSON.stringify(gone));
  nextComments = [1, 2, 3];
  await post("/admin/api/config", { ...st0.config }, cookie);

  head("统计(管理界面上那几个数)");
  await getComments("200002");
  const st1 = await j(await fetch(BASE + "/admin/api/state", { headers: { Cookie: cookie } }));
  check("已存弹幕集数", st1?.store?.episodes === 2, JSON.stringify(st1?.store));
  check("弹幕总条数(5 + 3)", st1?.store?.comments === 8, JSON.stringify(st1?.store));
  check("存储总大小 > 0", st1?.store?.bytes > 0, JSON.stringify(st1?.store));
  check("其中还新鲜的集数", st1?.store?.fresh === 2, JSON.stringify(st1?.store));

  head("管理界面");
  const pg = await fetch(BASE + "/admin");
  check("管理页可访问", pg.ok && (await pg.text()).includes("LinPlayer 弹幕代理"));
  check("未登录取不到状态", (await fetch(BASE + "/admin/api/state")).status === 401);
  check("密码错 → 401", (await post("/admin/api/login", { password: "wrong" })).status === 401);
  check("下发了会话 cookie", cookie.startsWith("lp_admin="), cookie);
  check(
    "状态里有闸门/缓存/弹幕库/来源",
    !!st1?.governor && !!st1?.cache && !!st1?.store && Array.isArray(st1?.sources),
  );
  check("来源表统计到了上游穿透次数", st1?.sources?.[0]?.upstream >= 1, JSON.stringify(st1?.sources?.[0]));

  head("出站闸门");
  const before = upstreamCalls;
  await post("/admin/api/config", { ...st0.config, upstream_per_day: 1 }, cookie);
  const blocked = await j(await fetch(BASE + "/api/v2/search/anime?keyword=neverseen"));
  check("★ 超出每日上限 → 拦住", blocked?.errorCode === 1003, JSON.stringify(blocked));
  check("★ 而且确实一个字节都没发给上游", upstreamCalls === before, `上游被多打了 ${upstreamCalls - before} 次`);
  check("拦住时给的是人话(会原样显示在播放器上)", /配额/.test(blocked?.errorMessage || ""), blocked?.errorMessage);
  const stillOk = await getComments("100001");
  check("★ 闸门关着,弹幕库里的照样发", stillOk.cids === "1,2,3,4,5", JSON.stringify(stillOk));

  head("清空:两个按钮互不影响");
  await post("/admin/api/config", { ...st0.config }, cookie);
  await post("/admin/api/cache/clear", {}, cookie);
  const st2 = await j(await fetch(BASE + "/admin/api/state", { headers: { Cookie: cookie } }));
  check(
    "★ 清短期缓存不动弹幕库",
    st2?.store?.episodes === 2 && st2?.cache?.entries === 0,
    JSON.stringify({ store: st2?.store, cache: st2?.cache }),
  );
  await post("/admin/api/store/clear", {}, cookie);
  const st3 = await j(await fetch(BASE + "/admin/api/state", { headers: { Cookie: cookie } }));
  check("清弹幕库才是真的全删", st3?.store?.episodes === 0, JSON.stringify(st3?.store));

  console.log(`\n${fails ? `${fails} 项未通过` : "全部通过"}`);
} finally {
  proc.kill();
  upstream.close();
  fs.rmSync(DATA, { recursive: true, force: true });
}
process.exit(fails ? 1 : 0);
