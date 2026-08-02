/* 弹幕官方配额护栏 —— 挂**真实运行的 exe** 验(CDP),不是纸面测试。
 *
 * 背景:2026-08-02 用户报「弹弹Play 配额老是被刷完」。查下来我们自己贡献了三份浪费:
 *   ① 核层 `is_anime` 写好了、配了单测,但**从落地起没有任何宿主调用过** ——
 *      播欧美剧/综艺/纪录片一样往官方接口打一整轮(/match + 最多 4 次 /search/episodes),
 *      而弹弹Play 根本不收录这些内容,一条候选都不可能有;
 *   ② 桌面端 autoDanmaku 在 autoLoad 返回 null 后又原样调一次 danmakuMatch ——
 *      同入参、同判据,结果恒为「可信度不足」,纯粹把配额翻倍;
 *   ③ 主动搜索没有任何频率限制。
 *
 * ★ 为什么必须挂真机:①②③ 全部是**宿主接线**问题,核层单测一路绿(那正是它们能
 *   活到今天的原因)。只有对着真进程调 invoke 才照得出来。
 *
 * 跑法(需要一个**带编译期凭据**的构建,npm run pack 的产物就是):
 *   cd dist-portable/LinPlayer
 *   WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS="--remote-debugging-port=9333" ./LinPlayer.exe &
 *   node ui/shared/danmaku-quota.check.mjs
 *
 * ★ 这个脚本自己会打真实的弹弹接口(每跑一次约 3~5 次调用)—— 它验的就是配额行为,
 *   没法拿假服务器代替。别放进 CI 循环跑,那是在自己刷自己的配额。
 */

const PORT = process.env.CDP_PORT || 9333;
const TITLE = process.env.DM_TITLE || "败犬女主太多了"; // 一部弹弹Play 确实收录的番
const OPT = {
  blockwords: [],
  user_blocklist: [],
  block_scroll: false,
  block_top: false,
  block_bottom: false,
  dedup: false,
  dedup_window_secs: 0,
};

const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
const page = list.find((t) => t.type === "page");
if (!page) {
  console.error(`!! ${PORT} 端口上没有页面 —— exe 起了吗?带 --remote-debugging-port 了吗?`);
  process.exit(2);
}
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));

let id = 0;
const pend = new Map();
ws.onmessage = (m) => {
  const v = JSON.parse(m.data);
  if (pend.has(v.id)) pend.get(v.id)(v), pend.delete(v.id);
};
const send = (method, params) =>
  new Promise((res) => (pend.set(++id, res), ws.send(JSON.stringify({ id, method, params }))));

/** 直接调 Tauri 命令,绕开 UI —— 我们验的是核层+宿主的行为,不是某个按钮长什么样。 */
const inv = async (cmd, args) =>
  (
    await send("Runtime.evaluate", {
      expression: `(async()=>{try{return {ok:await window.__TAURI_INTERNALS__.invoke(${JSON.stringify(
        cmd,
      )},${JSON.stringify(args ?? {})})}}catch(e){return {err:String(e)}}})()`,
      awaitPromise: true,
      returnByValue: true,
    })
  ).result?.result?.value;

/* 返回 {res, ms}。★ 判据用**耗时**而不是「有没有拿到弹幕」:
   上游是不稳的(同一入参连打四次,第四次就可能因为 /search 429 而回空 ——
   2026-08-02 真机实测),拿它当判据这个检查会随机红,而随机红的门禁等于没有门禁。
   耗时判的是另一件事、而且判得死:被门控挡掉时核层**一个字节都不发**,
   30ms 级返回;真去打接口最快也要 200ms 上下。两者差一个数量级,分得开。 */
const autoLoad = async (genres) => {
  const t = Date.now();
  const res = await inv("danmaku_auto_load", {
    input: { title: TITLE, episode_no: 1, file_name: `${TITLE}.S01E01.mkv`, genres },
    options: OPT,
  });
  return { res, ms: Date.now() - t };
};
const NETWORK_MS = 100; // 低于它 = 根本没出网

let fails = 0;
const check = (name, cond, detail) => {
  console.log(`${cond ? "PASS" : "FAIL"}  ${name}${cond ? "" : `\n      ${detail}`}`);
  if (!cond) fails++;
};
/* 限流窗口是 5 秒,过闸门的用例之间必须等够,否则后一条会被前一条的闸门拦住,
   报出来像是功能坏了。 */
const cooldown = () => new Promise((r) => setTimeout(r, 5300));

const off = await inv("get_official_danmaku");
if (!off?.ok?.available) {
  console.error("!! 这个构建没有编译期凭据(官方源不可用),本检查测不了。用 npm run pack 的产物。");
  process.exit(2);
}
/* 自建源要按**有效**条目数算:配置里常留着一条 api_url 全空的占位记录,
   宿主侧本来就会把它滤掉(见 danmaku_sources 的 filter)。按原始长度算会误判分支。 */
const selfHosted = (await inv("get_danmaku_config"))?.ok?.filter((s) => s.api_url?.trim()) ?? [];
console.log(`官方源可用;有效自建源 ${selfHosted.length} 个\n`);

console.log("== 一、主动搜索 5 秒限流(用户 2026-08-02 点名) ==");
await cooldown();
const first = await inv("danmaku_search", { keyword: TITLE });
check("第一次搜索放行", !/搜得太快/.test(first?.err ?? ""), JSON.stringify(first).slice(0, 200));
check("而且真的搜到了东西(别把「被拦住」测成「通过」)", Array.isArray(first?.ok) && first.ok.length > 0, JSON.stringify(first).slice(0, 200));

const second = await inv("danmaku_search", { keyword: TITLE });
check(
  "紧接着第二次被挡住,并如实说还剩几秒",
  /搜得太快了,请 \d+ 秒后再试/.test(second?.err ?? ""),
  JSON.stringify(second).slice(0, 200),
);

const manual = await inv("danmaku_match", { input: { title: TITLE, file_name: "x.mkv" } });
check(
  "手动重新匹配和搜索**共用**同一个闸门(它一样烧一整轮配额)",
  /搜得太快/.test(manual?.err ?? ""),
  JSON.stringify(manual).slice(0, 200),
);

await cooldown();
const again = await inv("danmaku_search", { keyword: TITLE });
check("满 5 秒后重新放行(闸门要会重新计时,不能一次性)", !/搜得太快/.test(again?.err ?? ""), JSON.stringify(again).slice(0, 200));

console.log("\n== 二、自动匹配:非动漫内容不该烧官方配额 ==");
const anime = await autoLoad(["动画", "奇幻"]);
check(
  "是番 → 真的去打了接口",
  anime.ms >= NETWORK_MS,
  `仅 ${anime.ms}ms → 压根没出网,门控把动漫也拦了,结果 ${JSON.stringify(anime.res).slice(0, 160)}`,
);

const unknown = await autoLoad([]);
check(
  "★ 元数据为空 = 不知道 → **必须放行**(反过来写会让没刮削的库弹幕静默死掉)",
  unknown.ms >= NETWORK_MS,
  `仅 ${unknown.ms}ms → 被当成非动漫跳过了,结果 ${JSON.stringify(unknown.res).slice(0, 160)}`,
);

const movie = await autoLoad(["剧情", "犯罪"]);
check(
  "确信不是番 → 一个请求都不发",
  movie.ms < NETWORK_MS && (selfHosted.length === 0 ? movie.res?.ok === null : !movie.res?.err),
  `耗时 ${movie.ms}ms,结果 ${JSON.stringify(movie.res).slice(0, 160)}`,
);

/* 顺带钉住 2026-08-02 的第四个 bug:/search 429 而 /match 正常回空时,
   旧代码(两路都失败才报错)会把它吞成「未找到匹配的弹幕」。
   这里只能验「不说谎」的方向 —— 上游此刻给不给 429 我们说了不算,
   所以断言写成:要么给结果,要么给**原因**,不许两手空空还装作没事。 */
if (unknown.res?.ok === null) {
  console.log("   (本次上游没返回弹幕 —— 若是配额/故障导致,核层应当报错而不是回 null)");
}

console.log(`\n${fails ? `${fails} 项未通过` : "全部通过"}`);
ws.close();
process.exit(fails ? 1 : 0);
