import { useEffect, useState } from "react";
import {
  type DownloadItem,
  downloadClearCompleted,
  downloadList,
  downloadPause,
  downloadRemove,
  downloadResume,
  fmtSize,
  playLocal,
} from "@shared/api";
import { IconPause, IconPlay, IconTrash } from "../app/icons";

/* 下载。

   ## 分两段:进行中 / 已完成
   PC 是一张大表 + 一列状态。手机上一张表塞不下,而用户的两种意图是分开的:
   "还要多久" 和 "看哪一个"。分段之后每段的操作也不同(暂停/续传 vs 播放/删除)。

   ## 2 秒轮询,只在有进行中任务时开
   全量轮询是最省事的写法,但下完之后还每 2 秒打一次核层是白耗电。
   ★ 依赖里放 `active` 而不是 `list`:放 list 的话每次轮询回来都会重建定时器,
     等于定时器永远在重置 —— 一个很难看出来的"轮询变慢"。 */

export default function DownloadsPage() {
  const [list, setList] = useState<DownloadItem[] | null>(null);
  const [err, setErr] = useState("");

  const load = () => downloadList().then(setList).catch((e) => setErr(String(e)));

  useEffect(() => {
    load();
  }, []);

  const active = (list ?? []).some((d) => d.status === "Downloading" || d.status === "Queued");
  useEffect(() => {
    if (!active) return;
    const t = setInterval(load, 2000);
    return () => clearInterval(t);
  }, [active]);

  if (err) return <div className="empty"><b>加载失败</b><div className="dim">{err}</div></div>;
  if (!list) return <div className="empty"><div className="dim">加载中…</div></div>;
  if (!list.length) return <div className="empty"><div className="dim">还没有下载任务</div></div>;

  const running = list.filter((d) => d.status !== "Completed");
  const done = list.filter((d) => d.status === "Completed");

  return (
    <div className="dls">
      {running.length > 0 && (
        <section className="sgroup">
          <h2>进行中 · {running.length}</h2>
          <div className="cells">
            {running.map((d) => (
              <div key={d.id} className="dl">
                <div className="dl-t">
                  <div className="dl-n">{d.title}</div>
                  <div className="dl-m dim">
                    {STATUS[d.status] ?? d.status}
                    {d.total_bytes > 0 && ` · ${fmtSize(d.received_bytes)} / ${fmtSize(d.total_bytes)}`}
                    {d.error && ` · ${d.error}`}
                  </div>
                  <div className="dl-bar"><i style={{ width: `${Math.round(d.progress * 100)}%` }} /></div>
                </div>
                <button
                  type="button"
                  className="mini-ico"
                  aria-label={d.status === "Paused" ? "继续" : "暂停"}
                  onClick={() =>
                    (d.status === "Paused" ? downloadResume(d.id) : downloadPause(d.id)).then(load)
                  }
                >
                  {d.status === "Paused" ? <IconPlay size={20} /> : <IconPause size={20} />}
                </button>
                <button
                  type="button"
                  className="mini-ico"
                  aria-label="删除"
                  onClick={() => downloadRemove(d.id).then(load)}
                >
                  <IconTrash size={20} />
                </button>
              </div>
            ))}
          </div>
        </section>
      )}

      {done.length > 0 && (
        <section className="sgroup">
          <h2>
            已完成 · {done.length}
            <button
              type="button"
              className="row-more"
              /* 只清记录不删文件 —— 核层的语义就是这样,所以文案不能写"删除" */
              onClick={() => downloadClearCompleted().then(load)}
            >
              清空记录
            </button>
          </h2>
          <div className="cells">
            {done.map((d) => (
              <div key={d.id} className="dl">
                <div className="dl-t">
                  <div className="dl-n">{d.title}</div>
                  <div className="dl-m dim">{fmtSize(d.total_bytes)}</div>
                </div>
                <button
                  type="button"
                  className="mini-ico"
                  aria-label="播放"
                  /* ★ playLocal 传的是**任务 id**,不是文件路径。 */
                  onClick={() => void playLocal(d.id, 0)}
                >
                  <IconPlay size={20} />
                </button>
                <button
                  type="button"
                  className="mini-ico"
                  aria-label="删除"
                  onClick={() => downloadRemove(d.id).then(load)}
                >
                  <IconTrash size={20} />
                </button>
              </div>
            ))}
          </div>
        </section>
      )}
    </div>
  );
}

const STATUS: Record<string, string> = {
  Queued: "排队中",
  Downloading: "下载中",
  Paused: "已暂停",
  Completed: "已完成",
  Failed: "失败",
  Canceled: "已取消",
};
