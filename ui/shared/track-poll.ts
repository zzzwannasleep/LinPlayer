import { applyPrefs, tracks as tracksApi, type Track } from "./api";

/** 起播后把音轨/字幕轨探到稳定为止,期间每轮都回调最新结果。
 *
 *  为什么必须轮询而不是起播后拉一次:
 *  - 网络流的 demux 是渐进的,音轨常先于字幕出来 —— 拉一次很可能只拿到音轨;
 *  - 外挂字幕更晚:它们是**独立文件**,核层要等 mpv 的 FILE_LOADED 才能 sub-add,
 *    慢服务器上这可能是起播后好几秒的事。
 *  在那之前的任何一次快照都是「没有字幕」,而 TV 端原本就是拉一次就定死,
 *  于是外挂字幕挂上了也进不了面板 —— 用户看到的是「字幕选项里没有外挂字幕」。
 *
 *  停止条件:轨数连续两次不变(demux 稳定),或 ~14s 兜底。
 *
 *  ★ 这份逻辑两端共用。它原来只长在桌面 App.tsx 里,TV 端另写了一个残缺版 ——
 *    两端分叉正是这个 bug 的成因,所以放这儿,别再抄第三份。
 *
 *  @returns 取消函数。组件卸载/换片时必须调用。
 */
export function pollTracks(onUpdate: (t: Track[]) => void): () => void {
  let alive = true;
  let tries = 0;
  let lastLen = -1;
  let stable = 0;
  let timer: number | undefined;

  const poll = async () => {
    if (!alive) return;
    try {
      const t = await tracksApi();
      if (!alive) return;
      onUpdate(t); // 每轮都刷:字幕晚到也能补进来
      if (t.length > 0 && t.length === lastLen) {
        if (++stable >= 2) return; // 连续两次轨数不变 = demux 稳定,停
      } else {
        stable = 0;
        lastLen = t.length;
        /* ★ 轨表变了就按偏好重选一次(核层 apply_prefs:正则 ＞ 首选语言)。
           这一步原来只在桌面 App 的「起播后 1.2s」打一枪、手机端和 TV 端一次都不调 ——
           而 apply_prefs 匹配的正是**当时的** track-list:网络流那会儿内封轨还没 demux 出来,
           于是用户按官网写好的字幕/音频正则匹配了个空表,表现就是「设了没反应」。
           轨表稳定后循环自己会停,所以不会一直顶掉用户播放中手动切的轨
           (wiki 的优先级:手动切过的 ＞ 正则命中 ＞ 首选语言)。 */
        if (t.length > 0) await applyPrefs().catch(() => {});
      }
    } catch {
      /* 播放器还没就绪:继续探,不该刷屏也不该弹错。 */
    }
    if (++tries < 20) timer = window.setTimeout(poll, 700);
  };

  timer = window.setTimeout(poll, 600);
  return () => {
    alive = false;
    if (timer !== undefined) window.clearTimeout(timer);
  };
}
