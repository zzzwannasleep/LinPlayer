/* Ani-RSS 模型层自检。跑法:
     node --experimental-strip-types ui/shared/anirss-model.test.mjs

   ## 为什么这份必须有测试
   2026-07-26 把这 200 多行从 `ui/desktop/pages/AniRssPage.tsx` 搬到共用层,
   为的是手机端能用同一份。**搬运本身就是一次可能静默改坏它的动作** ——
   而这里面的东西错了都不报错:
     - `parseEpisode` 的五条正则是按字幕组常见约定排的**优先级**,顺序有意义
     - `scoreMatch` 的 3/2/1 分档决定「这个种子属于哪部番」,错一档就把下载进度
       标到另一部番上,而界面看起来完全正常
     - `norm` 要剥掉的 token 是一条条踩出来的

   反向验证过(每条都真的注入过再看它红):
   反向验证:下面每一条都**真的注入过并看它红**(不是"看起来该红"):
     · 把 parseEpisode 的「- 12」那条正则挪到 pats 末尾
       → 「[Sub][01] 番名 - 12 [1080p]」变成 1 → 红
     · 把 scoreMatch 的标签档从 3 改成 1 → 标签命中不再优先于标题模糊 → 红
     · 同时把 matchTorrents 的 `if (s > bestScore)` 改成 `>=` **并**删掉
       `bestScore === 0` 那个守卫 → 0 分种子被硬塞给列表里第一部番 → 红

   ★ 最后那条是两道**独立**防线,拆任意一道测试都不红(实测过):
     `>` 让 0 分的种子永远赋不上 best,而 `bestScore === 0` 又兜了一层。
     所以这是真冗余,不是死代码 —— 别看它"没用"就顺手删掉一道。

   ★ 我在这份测试上栽过两次假绿,记下来:
     1. 用「[Sub] 番名 - 12 [1080p]」测正则顺序 —— 那个输入下有两条正则**都返回 12**,
        换顺序答案一样,把正则挪到末尾测试照样绿。要钉顺序,输入必须让两条给出**不同**答案。
     2. 头一版注入脚本因为 python 转义和 sed 分隔符出错,**根本没改到文件**,
        于是"通过"了 —— 那不是验证,那是什么都没做。注入之后必须回读确认真改了。
*/
import assert from "node:assert/strict";
import { parseEpisode, norm, scoreMatch, matchTorrents, statusOf } from "./anirss-model.ts";

let n = 0;
const ok = (name, fn) => {
  fn();
  n++;
  console.log("  ok ", name);
};

/* ---------- parseEpisode:五种字幕组写法 ---------- */
ok("集号:「- 12」形", () => {
  assert.equal(parseEpisode("[Sub] 番名 - 12 [1080p][x265]"), 12);
});
ok("集号:「[12]」形", () => {
  assert.equal(parseEpisode("[Sub][番名][12][BDRip]"), 12);
});
ok("集号:「E12 / EP 12」形", () => {
  assert.equal(parseEpisode("Show.Name.S02E12.WEB-DL"), 12);
  assert.equal(parseEpisode("番名 EP 07 简繁"), 7);
});
ok("集号:「第12话」形", () => {
  assert.equal(parseEpisode("番名 第12话 [简体]"), 12);
});
ok("集号:半集(12.5)不丢", () => {
  assert.equal(parseEpisode("[Sub] 番名 - 12.5 [1080p]"), 12.5);
});
ok("集号:解析不出来给 null,不瞎猜", () => {
  assert.equal(parseEpisode("番名 剧场版 [1080p]"), null);
});
ok("集号:清晰度不能被当成集号", () => {
  assert.equal(parseEpisode("[Sub] 番名 - 12 [1080p]"), 12);
});
/* ★ 这条钉的是**正则的先后顺序**,不是"能不能解析出来"。
   要钉顺序,输入就必须让两条正则给出**不同**答案:
     「[01]」形 → 1     「- 12」形 → 12
   按 pats 的排法「- 12」在前,所以正确答案是 12。

   ★ 第一版我用的是「[Sub] 番名 - 12 [1080p]」—— 那个输入下「- 12」和「 12 [」
     两条都返回 12,**换顺序答案一样**,于是把正则挪到末尾测试照样绿。
     那就是一条自我感觉良好的假绿:它测的是"解析得出来",而我以为它在测"顺序"。
     判据:反向注入(把「- 12」挪到 pats 末尾)必须让它红。 */
ok("集号:多条正则都命中时,按 pats 的顺序取第一条", () => {
  assert.equal(parseEpisode("[Sub][01] 番名 - 12 [1080p]"), 12);
});

/* ---------- norm:归一化 ---------- */
ok("归一化:方括号块**整块**剥掉(不是只剥标记)", () => {
  /* ★ 这条容易想当然:`[Sub][番名 S2][1080p]` 归一化后是**空串**,不是「番名」——
     正则剥的是整个 [...] 块,块里的内容一起没了。所以 scoreMatch 的标题模糊档
     比的是**块外**那部分。第一版测试就是照直觉写成「番名」,当场红。 */
  assert.equal(norm("[Sub][番名 S2][1080p]"), "");
  assert.equal(norm("[Sub] 番名 S2 [1080p]"), "番名");
});
ok("归一化:季度 token 和符号空白都剥掉", () => {
  assert.equal(norm("番 名  第二季"), "番名");
  assert.equal(norm("Show.Name.S02"), "showname");
});

/* ---------- scoreMatch:三档置信度 ---------- */
const ani = (o) => ({
  raw: {}, id: o.id ?? "1", key: o.id ?? "1", title: o.title ?? "", image: null,
  enable: true, currentEpisodeNumber: null, totalEpisodeNumber: null, week: null,
  season: null, lastDownloadTime: null, subgroup: null, score: null,
  tags: o.tags ?? [], downloadPath: o.downloadPath ?? null,
  themoviedbName: o.tmdb ?? null, jpTitle: o.jp ?? null,
});
const tor = (o) => ({
  name: o.name ?? "", progress: o.progress ?? 0.5, state: o.state ?? "downloading",
  tags: o.tags ?? [], downloadDir: o.dir ?? null,
});

ok("匹配:标签命中 = 3 分(最高)", () => {
  assert.equal(scoreMatch(ani({ title: "甲番", tags: ["ANI-RSS-A"] }), tor({ tags: ["ANI-RSS-A"] })), 3);
});
ok("匹配:目录命中 = 2 分", () => {
  assert.equal(scoreMatch(ani({ title: "甲番", downloadPath: "/media/甲番" }), tor({ dir: "/media/甲番/S1" })), 2);
});
ok("匹配:标题模糊 = 1 分", () => {
  assert.equal(scoreMatch(ani({ title: "甲番" }), tor({ name: "[Sub] 甲番 - 03 [1080p]" })), 1);
});
ok("匹配:不沾边 = 0 分", () => {
  assert.equal(scoreMatch(ani({ title: "甲番" }), tor({ name: "[Sub] 乙番 - 03 [1080p]" })), 0);
});
/* ★ 分档顺序的证据:同一个种子对 A(标签命中)和 B(标题命中)都能匹配,
   必须归给 A。档位改错的表现是进度标到 B 上,而两边界面都正常。 */
ok("匹配:标签优先于标题(分档顺序不能乱)", () => {
  const a = ani({ id: "A", title: "别的名字", tags: ["TAG1"] });
  const b = ani({ id: "B", title: "甲番" });
  const t = tor({ name: "[Sub] 甲番 - 03 [1080p]", tags: ["TAG1"] });
  assert.ok(scoreMatch(a, t) > scoreMatch(b, t));
});

/* ---------- matchTorrents:一个种子只归一部番 ---------- */
ok("归组:匹配不上的种子不硬塞给任何一部番", () => {
  const m = matchTorrents([ani({ id: "A", title: "甲番" })], [tor({ name: "[Sub] 完全无关 - 03" })]);
  assert.equal(m.size, 0);
});
ok("归组:只算下载中的,做种/校验的不上屏", () => {
  const m = matchTorrents(
    [ani({ id: "A", title: "甲番" })],
    [tor({ name: "[Sub] 甲番 - 03", state: "uploading" })],
  );
  assert.equal(m.size, 0);
});
ok("归组:同一部番取进度最高的那条", () => {
  const m = matchTorrents(
    [ani({ id: "A", title: "甲番" })],
    [
      tor({ name: "[Sub] 甲番 - 03", progress: 0.2 }),
      tor({ name: "[Sub] 甲番 - 04", progress: 0.9 }),
    ],
  );
  assert.equal(m.get("A").pct, 90);
  assert.equal(m.get("A").ep, 4);
});

/* ---------- statusOf ---------- */
ok("状态:暂停的订阅优先显示「已暂停订阅」", () => {
  const a = ani({ title: "甲番" });
  a.enable = false;
  assert.equal(statusOf(a, { ep: 3, pct: 50 }), "已暂停订阅");
});
ok("状态:下载中带集号和百分比", () => {
  assert.match(statusOf(ani({ title: "甲番" }), { ep: 3, pct: 62 }), /E3 下载中 · 62%/);
});

console.log(`\nanirss-model: 全部 ${n} 项通过。`);
