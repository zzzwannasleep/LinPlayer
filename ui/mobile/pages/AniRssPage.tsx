import { useCallback, useEffect, useMemo, useState } from "react";
import {
  type Json,
  anirssDeleteAni,
  anirssListAni,
  anirssRefreshAll,
  anirssRefreshAni,
  anirssSetAni,
  anirssTorrentsInfos,
} from "@shared/api";
import {
  type Ani,
  aniOf,
  matchTorrents,
  statusOf,
  torrentOf,
} from "@shared/anirss-model";
import Sheet from "../components/Sheet";
import { IconRefresh, IconTrash } from "../app/icons";

/* Ani-RSS 追番订阅。

   ★ 模型层(Ani 归一化 / 种子归组 / 集号解析 / 状态文案)用 @shared/anirss-model,
     与 PC 端**同一份**。那里面 scoreMatch 的 3/2/1 分档决定"这个种子属于哪部番",
     抄错一档就会把下载进度标到另一部番上,而界面看起来完全正常。

   ## 手机端只做订阅列表,不做设置表单
   PC 版有三段:首页海报墙 / 订阅列表 / 设置。设置那段是**镜像服务端 Config 的大表单**
   (几十个字段:下载器地址、RSS 规则、重命名模板、代理…)。在手机上逐个填这些是灾难 ——
   TV 端为同样的理由整个不做 Ani-RSS。这里保留"看进度 / 刷新 / 暂停 / 删"这些
   真正会在手机上做的事,配置留给 PC。**这是明确的取舍,不是没做完**。 */

/** 种子进度轮询间隔。只在有订阅时转 —— 没订阅还每 3 秒打一次服务端是白耗电。 */
const TORRENT_POLL_MS = 3000;

export default function AniRssPage() {
  const [list, setList] = useState<Ani[] | null>(null);
  const [err, setErr] = useState("");
  const [torrents, setTorrents] = useState<ReturnType<typeof torrentOf>[]>([]);
  const [sel, setSel] = useState<Ani | null>(null);
  const [toast, setToast] = useState("");
  const [busy, setBusy] = useState(false);

  const load = useCallback(async () => {
    setErr("");
    try {
      setList((await anirssListAni()).map(aniOf));
    } catch (e) {
      setErr(String(e));
      setList([]);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  useEffect(() => {
    if (!list || list.length === 0) return;
    let alive = true;
    const tick = async () => {
      try {
        const d = await anirssTorrentsInfos();
        /* data=TorrentInfo[];服务端偶尔给 null 或对象 —— 不是数组就当没有,别炸整页。 */
        if (alive) setTorrents(Array.isArray(d) ? (d as Json[]).map(torrentOf) : []);
      } catch {
        // 轮询失败不打断整页:订阅列表还是好的,只是这一轮没有进度
        if (alive) setTorrents([]);
      }
    };
    tick();
    const t = setInterval(tick, TORRENT_POLL_MS);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [list]);

  const dls = useMemo(() => (list ? matchTorrents(list, torrents) : new Map()), [list, torrents]);

  const run = async (msg: string, fn: () => Promise<unknown>) => {
    setBusy(true);
    try {
      await fn();
      setToast(msg);
      await load();
    } catch (e) {
      setToast(String(e));
    } finally {
      setBusy(false);
      setSel(null);
    }
  };

  if (err) return <div className="empty"><b>连不上 Ani-RSS</b><div className="dim">{err}</div></div>;
  if (!list) return <div className="empty"><div className="dim">加载中…</div></div>;
  if (!list.length) return <div className="empty"><div className="dim">还没有订阅。添加订阅请在 PC 端做。</div></div>;

  return (
    <div className="anr">
      <div className="chips lib-bar">
        <button
          type="button"
          className="chip"
          disabled={busy}
          onClick={() => void run("已触发全部刷新", anirssRefreshAll)}
        >
          <IconRefresh size={15} /> 全部刷新
        </button>
        <span className="lib-total dim">{list.length}</span>
      </div>

      <div className="cells">
        {list.map((a) => (
          <button
            key={a.key}
            type="button"
            className={`anr-it${a.enable ? "" : " off"}`}
            onClick={() => setSel(a)}
          >
            <span className="anr-th">{a.image && <img src={a.image} alt="" loading="lazy" decoding="async" />}</span>
            <span className="anr-t">
              <span className="anr-n">{a.title}</span>
              <span className="anr-m dim">{statusOf(a, dls.get(a.key))}</span>
              {a.currentEpisodeNumber != null && (
                <span className="anr-ep dim">
                  {a.currentEpisodeNumber}
                  {a.totalEpisodeNumber ? ` / ${a.totalEpisodeNumber}` : ""} 集
                </span>
              )}
            </span>
          </button>
        ))}
      </div>

      <Sheet open={sel != null} onClose={() => setSel(null)} title={sel?.title}>
        <div className="opts">
          {/* ★ id 为空的订阅(服务端偶尔给空串)增删改都定位不到 —— 挡掉,
              别给一个按下去必然报错的按钮。 */}
          {!sel?.id ? (
            <div className="dim" style={{ padding: 12 }}>
              这条订阅没有服务端 id,只能在 PC 端处理。
            </div>
          ) : (
            <>
              <button
                type="button"
                className="opt"
                onClick={() => void run("已触发刷新", () => anirssRefreshAni(sel.id))}
              >
                立即刷新
              </button>
              <button
                type="button"
                className="opt"
                onClick={() =>
                  void run(sel.enable ? "已暂停订阅" : "已恢复订阅", () =>
                    anirssSetAni({ ...(sel.raw as object), enable: !sel.enable } as Json),
                  )
                }
              >
                {sel.enable ? "暂停订阅" : "恢复订阅"}
              </button>
              <button
                type="button"
                className="opt"
                onClick={() => void run("已删除订阅(文件保留)", () => anirssDeleteAni([sel.id], false))}
              >
                删除订阅
                <div className="dim">已下载的文件保留</div>
              </button>
              <button
                type="button"
                className="opt bad"
                onClick={() => void run("已删除订阅及文件", () => anirssDeleteAni([sel.id], true))}
              >
                <IconTrash size={18} /> 删除订阅及文件
                <div className="dim">连同已下载的文件一起删,不可撤销</div>
              </button>
            </>
          )}
        </div>
      </Sheet>

      {toast && <div className="toast" onClick={() => setToast("")}>{toast}</div>}
    </div>
  );
}
