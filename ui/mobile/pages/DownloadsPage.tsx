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
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { haptic, toast } from "../app/motion";
import Page from "../components/Page";
import { Empty, usePress } from "../components/ui";

/* 下载。

   ## 分两段:进行中 / 已完成
   PC 是一张大表 + 一列状态。手机上一张表塞不下,而用户的两种意图是分开的:
   "还要多久" 和 "看哪一个"。分段之后每段的操作也不同(暂停/续传 vs 播放/删除)。

   ## 2 秒轮询,只在有进行中任务时开
   ★ 依赖里放 `active` 而不是 `list`:放 list 的话每次轮询回来都会重建定时器,
     等于定时器永远在重置 —— 一个很难看出来的"轮询变慢"。

   ★ `playLocal` 传的是**任务 id**,不是文件路径。 */

export default function DownloadsPage() {
  const { back, go } = useCtx();
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

  const running = (list ?? []).filter((d) => d.status !== "Completed");
  const done = (list ?? []).filter((d) => d.status === "Completed");

  return (
    <Page title="下载" onBack={back} enterKey={list}>
      <div className="chips">
        <Chip
          icon="pause2"
          label="全部暂停"
          onClick={() => {
            haptic("tap");
            const xs = running.filter((d) => d.status === "Downloading");
            if (!xs.length) return toast("现在没有可暂停的任务");
            Promise.allSettled(xs.map((d) => downloadPause(d.id))).then(() => {
              toast(`已暂停 ${xs.length} 个任务`);
              load();
            });
          }}
        />
        <Chip
          icon="trash"
          label="清空已完成"
          onClick={() => {
            haptic("tap");
            if (!done.length) return toast("已完成列表本来就是空的");
            /* ★ 只清记录,**不删文件** —— 核层就是这个语义,文案必须对得上,
               否则用户以为片子被删了。 */
            downloadClearCompleted().then((n) => {
              toast(`已清掉 ${n} 条记录(文件还在)`, "ok");
              load();
            });
          }}
        />
      </div>

      {err && <Empty icon="download" title="取不到下载列表" desc={err} />}

      <div className="sgroup">
        <h2>进行中{running.length ? ` · ${running.length}` : ""}</h2>
        {list === null ? (
          <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
        ) : !running.length ? (
          <Empty
            icon="download"
            title="现在没有正在下载的任务"
            desc="去媒体库或详情页点「下载」,任务会出现在这里。离线通勤看片是手机独有的场景。"
            action={{ label: "去媒体库", on: () => go("library") }}
          />
        ) : (
          running.map((d, i) => (
            <ActiveRow key={d.id} d={d} i={i} onChanged={load} />
          ))
        )}
      </div>

      {done.length > 0 && (
        <div className="sgroup">
          <h2>已完成 · {done.length}</h2>
          {done.map((d) => (
            <DoneRow key={d.id} d={d} onChanged={load} />
          ))}
        </div>
      )}
    </Page>
  );
}

function ActiveRow({ d, i, onChanged }: { d: DownloadItem; i: number; onChanged: () => void }) {
  const paused = d.status === "Paused";
  return (
    <div className="lit" style={{ ["--i" as string]: i }}>
      <div className="card-a ar-thumb" style={{ width: 92, flexShrink: 0 }}>
        {d.poster_url ? <img src={d.poster_url} alt="" loading="lazy" decoding="async" /> : null}
      </div>
      <div className="lit-t">
        <div className="lit-n">{d.title}</div>
        <div className="lit-s num">
          {statusText(d)}
          {d.error ? ` · ${d.error}` : ""}
        </div>
        <div style={{ margin: "8px 0 2px" }}>
          <div className="bar">
            <i style={{ transform: `scaleX(${Math.max(0, Math.min(1, d.progress))})` }} />
          </div>
        </div>
        <div className="dl-acts">
          <DlBtn
            icon={paused ? "play" : "pause2"}
            label={paused ? "继续" : "暂停"}
            onClick={() => {
              haptic("tap");
              (paused ? downloadResume(d.id) : downloadPause(d.id)).then(onChanged);
            }}
          />
          <DlBtn
            icon="trash"
            label="移除"
            onClick={() => {
              haptic("warn");
              downloadRemove(d.id).then(() => {
                toast(`已移除「${d.title}」`, "ok");
                onChanged();
              });
            }}
          />
        </div>
      </div>
    </div>
  );
}

function DoneRow({ d, onChanged }: { d: DownloadItem; onChanged: () => void }) {
  return (
    <div className="lit">
      <div className="lit-ic">
        <Icon n="check" size={18} />
      </div>
      <div className="lit-t">
        <div className="lit-n">{d.title}</div>
        <div className="lit-s">
          {[fmtSize(d.total_bytes), d.container?.toUpperCase()].filter(Boolean).join(" · ")}
        </div>
      </div>
      <div className="dl-acts" style={{ marginTop: 0 }}>
        <DlBtn
          icon="play"
          label="播放"
          onClick={() => {
            haptic("tap");
            /* ★ 传任务 id,不是文件路径。 */
            playLocal(d.id).catch((e) => toast(`本地播放失败:${e}`, "bad"));
          }}
        />
        <DlBtn
          icon="trash"
          label="删除"
          onClick={() => {
            haptic("warn");
            downloadRemove(d.id).then(() => {
              toast("已删除", "ok");
              onChanged();
            });
          }}
        />
      </div>
    </div>
  );
}

function statusText(d: DownloadItem) {
  const pct = Math.round((d.progress || 0) * 100);
  const size = `${fmtSize(d.received_bytes)} / ${fmtSize(d.total_bytes)}`;
  switch (d.status) {
    case "Downloading":
      return `已下 ${pct}% · ${size}`;
    case "Queued":
      return "排队中";
    case "Paused":
      return `已暂停 · ${pct}% · ${size}`;
    case "Failed":
      return "失败";
    default:
      return String(d.status);
  }
}

function DlBtn({ icon, label, onClick }: { icon: string; label: string; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button type="button" className="dl-btn" aria-label={label} ref={ref} onClick={onClick}>
      <Icon n={icon} size={15} />
    </button>
  );
}

function Chip({ icon, label, onClick }: { icon: string; label: string; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button type="button" className="chip" ref={ref} onClick={onClick}>
      <Icon n={icon} size={14} />
      {label}
    </button>
  );
}
