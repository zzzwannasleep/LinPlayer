import { useCallback, useEffect, useState } from "react";
import { type MediaCategory, type SourceEntry, isUnsupported, sourceCategories } from "@shared/api";
import NetdiskPage from "./NetdiskPage";
import VodPage from "./VodPage";

/* 进一个文件浏览型源时的分流口。

   源分两类,不该共用一个页面:
     · **影视目录型**(资源站):有分类、有海报、有分集 → 海报墙 + 详情页
     · **文件树型**(网盘):有目录、有文件、有大小 → 面包屑 + 文件表

   判据不能看 source_kind:插件源的 kind 是 `plugin:<id>/<src>`,同样是插件源,
   有的是资源站有的是网盘,光看 kind 分不出来。所以**探一次能力**:
   core 的 source_categories 对不支持的源会返回带 __LP_UNSUPPORTED__ 的错误。

   ★ 只有「明确不支持」才退回文件页。网络错误退回文件页的话,用户会在一个
     文件表里看到一句网盘的报错,更迷惑 —— 那种情况给重试。 */

type Props = {
  onPlay: (entry: SourceEntry) => void;
  onBack: () => void;
  /** 顶栏显示的源名(服务器名)。 */
  title: string;
};

type Mode = { t: "probing" } | { t: "vod"; cats: MediaCategory[] } | { t: "files" } | { t: "error"; msg: string };

export default function SourceBrowsePage({ onPlay, onBack, title }: Props) {
  const [mode, setMode] = useState<Mode>({ t: "probing" });

  const probe = useCallback(() => {
    let alive = true;
    setMode({ t: "probing" });
    sourceCategories()
      .then((cats) => alive && setMode({ t: "vod", cats }))
      .catch((e) => {
        if (!alive) return;
        setMode(isUnsupported(e) ? { t: "files" } : { t: "error", msg: String(e) });
      });
    return () => {
      alive = false;
    };
  }, []);

  useEffect(probe, [probe]);

  if (mode.t === "probing") {
    return (
      <>
        <div className="cbar">
          <span className="crumb">
            <b>{title}</b>
          </span>
        </div>
        <div className="scroll">
          <div className="nd-loading">
            <div className="spinner" />
          </div>
        </div>
      </>
    );
  }

  if (mode.t === "error") {
    return (
      <>
        <div className="cbar">
          <span className="crumb">
            <b>{title}</b>
          </span>
        </div>
        <div className="scroll">
          <div className="empty vod-empty">
            <b>连不上这个源</b>
            <div className="vod-err">{mode.msg}</div>
            <div style={{ display: "flex", gap: 10 }}>
              <button className="btn" onClick={probe}>
                重试
              </button>
              {/* 逃生口:探测失败不代表源没用,让用户还能按文件浏览。 */}
              <button className="btn ghost" onClick={() => setMode({ t: "files" })}>
                按文件浏览
              </button>
              <button className="btn ghost" onClick={onBack}>
                返回服务器
              </button>
            </div>
          </div>
        </div>
      </>
    );
  }

  /* onPlay 两条路都要传:资源站和网盘只是版式不同,起播是同一条路
     (App 的 playSource → 开独立播放窗 → 那个窗里才 invoke source_play)。
     VodPage 这里曾经漏传,页面就自己 invoke 了 —— 有声音没画面。 */
  return mode.t === "vod" ? (
    <VodPage categories={mode.cats} onBack={onBack} title={title} onPlay={onPlay} />
  ) : (
    <NetdiskPage onPlay={onPlay} onBack={onBack} />
  );
}
