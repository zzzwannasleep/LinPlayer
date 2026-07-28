import { useEffect, useState } from "react";
import { type Status, fmtTime, setPause, status as getStatus, stopPlayback } from "@shared/api";
import { Icon } from "../app/icons";

/* 迷你播放器 —— **PC 端没有这个东西**,是手机端独有的。

   为什么手机才需要:PC 上你可以一边开着播放窗口一边用别的窗口。手机是单窗口的,
   离开播放页就等于中断 —— 而"我想边听边翻找下一集"是手机上最常见的诉求之一。
   Emby 官方安卓端没有它。

   ## 它不重新起播
   收起 ≠ 停止。mpv 还在放(声音继续),这一条只是个控制条 + 回到播放页的入口。
   所以这里**不调 play**,只调 status/setPause/stopPlayback。

   ## 位置
   贴在底栏正上方。不做可拖拽 —— 可拖的浮窗在手机上会挡住内容且用户得自己收拾它,
   而固定位置的一条 56dp 高的横条既够点又不挡。 */

export default function MiniPlayer({
  title,
  onExpand,
  onClose,
}: {
  title?: string;
  /** 回到全屏播放页 */
  onExpand: () => void;
  /** 关掉 = 真正停止播放 */
  onClose: () => void;
}) {
  const [st, setSt] = useState<Status | null>(null);

  /* 2s 轮询就够 —— 这条上只有一个细进度条,没人盯着它看秒。
     播放页是 1s,那里进度数字要跟得上。 */
  useEffect(() => {
    let alive = true;
    const t = setInterval(async () => {
      try {
        const s = await getStatus();
        if (alive) setSt(s);
      } catch {
        /* 播放器没了(被别处停掉)—— 不刷屏 */
      }
    }, 2000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, []);

  const pct = st?.duration ? (st.time / st.duration) * 100 : 0;

  return (
    <div className="mini" onClick={onExpand} role="button" tabIndex={0}>
      {/* 只动 transform，不动 width —— 改 width 每秒一次重排 */}
      <div className="mini-prog"><i style={{ transform: `scaleX(${pct / 100})` }} /></div>
      <div className="mini-t">
        <div className="mini-title">{title ?? "正在播放"}</div>
        <div className="mini-sub">
          {st ? `${fmtTime(st.time)} / ${fmtTime(st.duration)}` : "…"}
        </div>
      </div>
      <button
        type="button"
        className="mini-ico"
        aria-label={st?.paused ? "播放" : "暂停"}
        onClick={(e) => {
          e.stopPropagation(); // 别把点击冒泡成"展开播放页"
          if (!st) return;
          void setPause(!st.paused);
          setSt({ ...st, paused: !st.paused });
        }}
      >
        <Icon n={st?.paused ? "play" : "pause"} size={22} />
      </button>
      <button
        type="button"
        className="mini-ico"
        aria-label="停止"
        onClick={(e) => {
          e.stopPropagation();
          // 停止要把进度落地(Emby 上报 + 本地观看记录),不能只是关掉这条 UI
          void stopPlayback(st?.time ?? 0).finally(onClose);
        }}
      >
        <Icon n="close" size={20} />
      </button>
    </div>
  );
}
