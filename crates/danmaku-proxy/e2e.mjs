/* 端到端自检:起真进程、走真 HTTP,验注册 / 鉴权 / 白名单 / 缓存 / 出站闸门 / 管理界面。
 *
 * ★ 自带一个**假的弹弹Play**(UPSTREAM_BASE 指过去)。真上游打一次就是真烧一次配额 ——
 *   而这个服务存在的全部理由就是省配额,自检去刷配额是荒唐的。
 *   假上游会校验签名头,所以"代理有没有真的签名"这条照样测得到。
 *
 * 跑法:
 *   cargo build -p linplayer-danmaku-proxy
 *   node crates/danmaku-proxy/e2e.mjs
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
  console.error(`!! 找不到 ${BIN}\n   先跑:cargo build -p linplayer-danmaku-proxy`);
  process.exit(2);
}

// ---------- 假上游 ----------
const upstream = http.createServer((req, res) => {
  const u = new URL(req.url, "http://x");
  res.setHeader("Content-Type", "application/json");
  // 代理必须签名。不签的话这里就报 403 —— 「有没有真签」这条不靠读代码,靠上游说话。
  if (!(req.headers["x-appid"] && req.headers["x-signature"] && req.headers["x-timestamp"])) {
    return res.end(JSON.stringify({ errorCode: 403, errorMessage: "缺少签名(代理没签)" }));
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

try {
  for (let i = 0; i < 80; i++) {
    try {
      if ((await fetch(BASE + "/healthz")).ok) break;
    } catch {}
    await new Promise((r) => setTimeout(r, 250));
  }

  console.log("== 注册 ==");
  const r1 = await j(await post("/api/register", { label: "端到端测试机" }));
  check("能拿到令牌", typeof r1?.token === "string" && r1.token.length === 64, JSON.stringify(r1));
  const TOKEN = r1?.token;
  const h = { "X-LP-Token": TOKEN };

  console.log("\n== 鉴权 ==");
  check("不带令牌 → 401", (await fetch(BASE + "/api/v2/search/anime?keyword=x")).status === 401);
  check(
    "令牌无效 → 401(客户端据此重新注册)",
    (await fetch(BASE + "/api/v2/search/anime?keyword=x", { headers: { "X-LP-Token": "deadbeef" } }))
      .status === 401,
  );

  console.log("\n== 白名单 ==");
  const bj = await j(await fetch(BASE + "/api/v2/user/profile", { headers: h }));
  check("白名单外的接口被拒", bj?.errorCode === 1005, JSON.stringify(bj));

  console.log("\n== 转发 + 缓存 ==");
  const a = await fetch(BASE + "/api/v2/search/anime?keyword=fake&v2=true", { headers: h });
  check("首次请求穿透上游(MISS)", a.headers.get("x-lp-cache") === "MISS");
  const aj = await j(a);
  check(
    "★ 代理真的签了名(假上游会校验,没签它回 403)",
    aj?.animes?.[0]?.animeTitle === "假的番",
    JSON.stringify(aj),
  );
  const b = await fetch(BASE + "/api/v2/search/anime?keyword=fake&v2=true", { headers: h });
  check("第二次命中缓存(HIT)", b.headers.get("x-lp-cache") === "HIT");
  const c = await fetch(BASE + "/api/v2/search/anime?v2=true&keyword=fake", { headers: h });
  check("★ 参数换个顺序仍然命中(不归一化 = 白掏配额)", c.headers.get("x-lp-cache") === "HIT");

  console.log("\n== 上游报错不入缓存 ==");
  const e1 = await j(await fetch(BASE + "/api/v2/search/anime?keyword=quota", { headers: h }));
  check("429 原样透传给客户端", e1?.errorCode === 429, JSON.stringify(e1));
  const e2 = await fetch(BASE + "/api/v2/search/anime?keyword=quota", { headers: h });
  check(
    "★ 报错没被缓存(缓存了的话配额恢复了客户端还在看旧错误)",
    e2.headers.get("x-lp-cache") === "MISS",
  );

  console.log("\n== 管理界面 ==");
  const pg = await fetch(BASE + "/admin");
  check("管理页可访问", pg.ok && (await pg.text()).includes("LinPlayer 弹幕代理"));
  check("未登录取不到状态", (await fetch(BASE + "/admin/api/state")).status === 401);
  check("密码错 → 401", (await post("/admin/api/login", { password: "wrong" })).status === 401);

  const lg = await post("/admin/api/login", { password: ADMIN_PW });
  check("密码对 → 登录成功", lg.ok);
  const cookie = (lg.headers.get("set-cookie") || "").split(";")[0];
  check("下发了会话 cookie", cookie.startsWith("lp_admin="), cookie);

  const st = await j(await fetch(BASE + "/admin/api/state", { headers: { Cookie: cookie } }));
  check("状态里有闸门/缓存/客户端", !!st?.governor && !!st?.cache && Array.isArray(st?.clients));
  check("客户端已登记且统计到上游次数", st?.clients?.[0]?.upstream >= 1, JSON.stringify(st?.clients?.[0]));
  check("★ 令牌明文不出现在管理接口里", !JSON.stringify(st).includes(TOKEN), "管理接口把令牌吐出来了");
  check("缓存命中被统计到", st?.cache?.hits >= 2, JSON.stringify(st?.cache));

  console.log("\n== 出站闸门 ==");
  await post("/admin/api/config", { ...st.config, upstream_per_day: 1 }, cookie);
  const blocked = await j(await fetch(BASE + "/api/v2/search/anime?keyword=neverseen", { headers: h }));
  check("★ 超出每日上限 → 拦住,不发给上游", blocked?.errorCode === 1003, JSON.stringify(blocked));
  check("拦住时给的是人话(会原样显示在播放器上)", /配额/.test(blocked?.errorMessage || ""), blocked?.errorMessage);
  const cached = await fetch(BASE + "/api/v2/search/anime?keyword=fake&v2=true", { headers: h });
  check("★ 闸门关着,已缓存的内容仍然能拿到", cached.headers.get("x-lp-cache") === "HIT");

  console.log("\n== 封禁 ==");
  await post("/admin/api/client", { id: st.clients[0].id, action: "ban" }, cookie);
  const banned = await fetch(BASE + "/api/v2/search/anime?keyword=fake&v2=true", { headers: h });
  check("封禁后立刻拒(连缓存也不给)", banned.status === 401, "实得 " + banned.status);

  console.log(`\n${fails ? `${fails} 项未通过` : "全部通过"}`);
} finally {
  proc.kill();
  upstream.close();
  fs.rmSync(DATA, { recursive: true, force: true });
}
process.exit(fails ? 1 : 0);
