/* 起播后「按正则选轨」的时机自检。跑法:
     npx tsx ui/shared/track-poll.test.mjs
 *
 * ## 这条测的是什么
 * 字幕/音频筛选正则(wiki: /wiki/regex-filters)是核层 apply_prefs 在做的 ——
 * 它拿 mpv 当前的 track-list 去匹配。所以**什么时候调它**决定了正则有没有东西可匹配:
 * 网络流的 demux 是渐进的,起播后头几秒 track-list 是空的或只有音轨。
 * 桌面端原本只在起播后 1.2s 打一枪、手机端和 TV 端**一次都不调**,
 * 于是用户按官网写好的正则匹配了个空表 —— 「设了没反应」。
 *
 * 正解是跟着轨表走:轨表每变一次就重选一次,稳定了就停。这条测的就是这个契约。
 *
 * 反向验证过:把 track-poll.ts 里的 applyPrefs() 那行删掉,本测试立刻红。
 */
import assert from "node:assert/strict";

/* pollTracks 用的是 window.setTimeout,且 api.ts 走 @tauri-apps/api —— 两者都要 window。 */
globalThis.window = globalThis;

/** 每次 tracks() 依次返回下面这些快照:空 → 只有音轨 → 音轨+字幕 → 稳定。
 *  这正是真实网络流的样子(见 track-poll.ts 的注释)。 */
const SNAPSHOTS = [
  [],
  [{ kind: "audio", id: "1", title: "日本語", lang: "jpn", selected: true, codec: "flac", channels: 6 }],
  [
    { kind: "audio", id: "1", title: "日本語", lang: "jpn", selected: true, codec: "flac", channels: 6 },
    { kind: "sub", id: "2", title: "简体中文", lang: "chi", selected: false, codec: "ass", channels: 0 },
  ],
];
let shot = 0;
const calls = [];
window.__TAURI_INTERNALS__ = {
  invoke: async (c) => {
    calls.push(c);
    if (c !== "tracks") return null;
    const t = SNAPSHOTS[Math.min(shot, SNAPSHOTS.length - 1)];
    shot++;
    return t;
  },
  transformCallback: (cb) => cb,
  convertFileSrc: (p) => p,
};

const { pollTracks } = await import("./track-poll.ts");

const seen = [];
const stop = pollTracks((t) => seen.push(t.length));
// 600ms 起第一枪,之后每 700ms 一枪;等够 5 枪。
await new Promise((r) => setTimeout(r, 4200));
stop();

const applies = calls.filter((c) => c === "apply_prefs").length;
console.log("轨表快照:", JSON.stringify(seen), "| apply_prefs 次数:", applies);

assert.deepEqual(seen.slice(0, 3), [0, 1, 2], "轮询要按顺序看到 空 → 1 轨 → 2 轨");

/* ★ 核心断言:轨表**变成非空之后**必须重新选一次轨。
   只在起播那一枪选(轨表还是空的)= 正则匹配了个空表 = 用户说的「设了没反应」。 */
assert.ok(applies >= 2, `轨表每变一次就要重选一次轨,实际只调了 ${applies} 次 apply_prefs`);

/* 但也不能一直调:轨表稳定后还在选,会把用户在播放中手动切过的轨顶掉
   (wiki 的优先级是「手动切过的轨 ＞ 正则命中」)。 */
assert.ok(applies <= 3, `轨表稳定后就该停,实际调了 ${applies} 次 —— 会顶掉用户手动切的轨`);

console.log("全绿 ✅");
