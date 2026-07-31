import { useCallback, useEffect, useState } from "react";
import { type MediaCategory, isUnsupported, sourceCategories } from "@shared/api";
import { useCtx } from "../app/ctx";
import Page from "../components/Page";
import NetdiskPage from "./NetdiskPage";
import VodPage from "./VodPage";

/* 进一个文件浏览型源时的分流口(桌面端 ui/desktop/pages/SourceBrowsePage.tsx 同构)。

   源分两类,不该共用一个页面:
     · **影视目录型**(资源站):分类 / 海报 / 分集 → 海报墙 + 详情
     · **文件树型**(网盘):目录 / 文件 / 大小 → 文件行

   判据不能看 source_kind:插件源的 kind 都是 `plugin:<id>/<src>`,同样是插件源,
   有的是资源站有的是网盘,光看 kind 分不出来。所以**探一次能力**。

   ★ 只有「明确不支持」才退回文件页。网络错退回文件页的话,用户会在一个文件表里
     看到一句网盘的报错,更迷惑 —— 那种情况给重试。 */

export default function SourceBrowsePage() {
  const { back } = useCtx();
  const [mode, setMode] = useState<
    { t: "probing" } | { t: "vod"; cats: MediaCategory[] } | { t: "files" } | { t: "error"; msg: string }
  >({ t: "probing" });

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

  if (mode.t === "vod") return <VodPage categories={mode.cats} onBack={back} />;
  if (mode.t === "files") return <NetdiskPage />;

  return (
    <Page title="浏览" onBack={back}>
      <div className="empty">
        {mode.t === "probing" ? (
          <div className="dim">正在连接…</div>
        ) : (
          <>
            <b>连不上这个源</b>
            <div className="dim">{mode.msg}</div>
            <div style={{ display: "flex", gap: 10, marginTop: 12 }}>
              <button className="btn" onClick={probe}>
                重试
              </button>
              {/* 逃生口:探测失败不代表源没用。 */}
              <button className="btn ghost" onClick={() => setMode({ t: "files" })}>
                按文件浏览
              </button>
            </div>
          </>
        )}
      </div>
    </Page>
  );
}
