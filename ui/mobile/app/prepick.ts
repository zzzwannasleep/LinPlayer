/* 起播前选好的音轨 / 字幕轨,交接给播放页。
 *
 * ## 为什么需要这么一个中转
 * 详情页能看到的是 **Emby 的 MediaStreams**(`item_media` 返回的版本里那张表),
 * 而播放页能操作的是 **mpv 的 track-list** —— 两者是两套编号,而且 mpv 那张表
 * 要等 demux 完才有(网络流上是起播后几百毫秒到几秒的事,外挂字幕更晚)。
 * 所以"选"和"生效"必然分处两个时刻:详情页只能把意图记下来,
 * 播放页在轨表稳定之后照着执行。
 *
 * ## 对应关系
 * 记的是**同类轨道里的第几条**(0 起),不是 mpv 的 track id ——
 * 后者在选之前根本不存在。内封轨在 mpv 里的顺序就是容器里的顺序,
 * 也就是 Emby MediaStreams 里同类流的顺序,两边对得上。
 * ★ 外挂字幕是 `sub-add` 挂上去的,排在内封字幕**之后** —— 详情页把外挂也
 *   一并列出来时,序号仍然是"字幕表里的第几条",顺序一致。
 * ★ `sub: -1` 是**明确要求关掉字幕**,和 `null`(没选过,交给核层的正则/首选语言)
 *   是两件事。混成一个值的表现是:用户关了字幕,起播后又被 apply_prefs 打开。
 *
 * ## 一次性
 * `take` 之后就清空:它描述的是"这一次起播",不是一个持久偏好。
 * 持久偏好在设置里(正则 / 首选语言),那条路不归这里管。
 */

export type PrePick = {
  /** 同类音轨里的第几条(0 起)。null = 没选过 */
  audio: number | null;
  /** 同类字幕里的第几条(0 起)。-1 = 明确关闭。null = 没选过 */
  sub: number | null;
};

let pending: PrePick | null = null;

export function setPrePick(p: PrePick | null) {
  pending = p && (p.audio != null || p.sub != null) ? p : null;
}

export function takePrePick(): PrePick | null {
  const p = pending;
  pending = null;
  return p;
}
