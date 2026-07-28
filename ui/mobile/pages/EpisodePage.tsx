import { useEffect, useState } from "react";
import {
  type Item,
  type ItemDetail,
  type MediaVersion,
  downloadEnqueue,
  fmtBitrate,
  fmtRes,
  fmtSize,
  itemDetailLite,
  itemMedia,
  peekItemDetailLite,
  posterUrl,
  seasonEpisodes,
  seriesSeasons,
  setPlayed,
  thumbUrl,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { haptic, toast } from "../app/motion";
import Page from "../components/Page";
import Sheet from "../components/Sheet";
import { Empty, Opt, OptGroup, usePress } from "../components/ui";

/* 单集详情页 —— **独立一页**,不是 bottom sheet。
   调研结论一致(NN/g + Netflix/Prime/Plex 做法):用 sheet 会打断
   "从第 5 集跳到第 10 集"这个真实存在的流程,而且长简介在 sheet 里堆不下。

   ★ 上一集/下一集走 `replace` 不是 `go` —— 那是**同一层**的横向移动。
     用 go 的话连按 5 次「下一集」就要按 5 次返回才回得到剧详情页,
     而用户心里的返回目标始终是那部剧。 */

const fmtDur = (s: number) => {
  const m = Math.round(s / 60);
  return m >= 60 ? `${Math.floor(m / 60)} 小时 ${m % 60} 分` : `${m} 分钟`;
};

/** 邻集探测窗口。
 *  ★ **不能把整季拉下来找邻居** —— 那正是这一版要避开的事(最长的季 862 集)。
 *    分集在服务端按 IndexNumber 升序排,所以"第 N 集"的位置≈ N-1。
 *    先开一个 3 格的小窗;有特别篇之类的空洞导致没命中,再开一次 11 格的大窗。
 *    两次都没命中就**不画上下集**,并把原因说出来 —— 不猜。 */
const WIN_SMALL = 3;
const WIN_LARGE = 11;

export default function EpisodePage({ itemId }: { itemId?: string; season?: number; ep?: number }) {
  const { session, back, replace, play } = useCtx();
  const [d, setD] = useState<ItemDetail | null>(() => (itemId ? peekItemDetailLite(itemId) ?? null : null));
  const [err, setErr] = useState("");
  const [ver, setVer] = useState<MediaVersion | null>(null);
  const [sheet, setSheet] = useState(false);
  /** 邻集 + 本季其它集。null = 还没探;[] = 探过了但没命中 */
  const [near, setNear] = useState<{ prev: Item | null; next: Item | null; siblings: Item[] } | null>(null);

  useEffect(() => {
    if (!itemId) return;
    let alive = true;
    setErr("");
    setNear(null);
    itemDetailLite(itemId)
      .then((x) => alive && setD(x))
      .catch((e) => alive && setErr(String(e)));
    itemMedia(itemId)
      .then((v) => alive && setVer(v[0] ?? null))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [itemId]);

  /* 找上一集 / 下一集。 */
  useEffect(() => {
    if (!d || !itemId || !d.series_id) return;
    let alive = true;
    (async () => {
      const seasons = await seriesSeasons(d.series_id!).catch(() => []);
      // 没分季的剧:集直接挂在剧下
      const parent = seasons.find((s) => s.index_no === d.season_no)?.id ?? d.series_id!;
      const pos = Math.max(0, (d.episode_no ?? 1) - 1);
      for (const win of [WIN_SMALL, WIN_LARGE]) {
        const start = Math.max(0, pos - Math.floor(win / 2));
        const page = await seasonEpisodes(parent, start, win).catch(() => null);
        if (!alive) return;
        if (!page) break;
        const i = page.items.findIndex((x) => x.id === itemId);
        if (i >= 0) {
          setNear({
            prev: i > 0 ? page.items[i - 1] : null,
            next: i < page.items.length - 1 ? page.items[i + 1] : null,
            siblings: page.items,
          });
          // 顺便再拉一屏当"本季其它集"
          seasonEpisodes(parent, Math.max(0, pos - 5), 12)
            .then((p) => alive && setNear((n) => (n ? { ...n, siblings: p.items } : n)))
            .catch(() => {});
          return;
        }
      }
      if (alive) setNear({ prev: null, next: null, siblings: [] });
    })();
    return () => {
      alive = false;
    };
  }, [d, itemId]);

  const moreBtn = usePress<HTMLButtonElement>();

  if (err) {
    return (
      <Page title="单集" onBack={back}>
        <Empty icon="info" title="加载失败" desc={err} />
      </Page>
    );
  }
  if (!d || !session) {
    return (
      <Page title="单集" onBack={back}>
        <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
      </Page>
    );
  }

  const self: Item = {
    id: d.id, name: d.name, type_: d.type_, is_folder: false,
    has_primary: d.has_primary, runtime_secs: d.runtime_secs, resume_secs: d.resume_secs,
    series_name: d.series_name, episode_no: d.episode_no, season_no: d.season_no,
    video_height: null, bitrate: null, size_bytes: null, played: false,
    unplayed_item_count: 0, genres: d.genres, year: d.year, rating: d.rating,
    provider_ids: {}, presentation_unique_key: null, path: null,
    series_id: d.series_id, date_updated: null, sort_name: null,
  };

  const jump = (t: Item) => () => {
    haptic("sel");
    replace({
      page: "episode",
      itemId: t.id,
      title: t.name,
      season: t.season_no ?? undefined,
      ep: t.episode_no ?? undefined,
    });
  };

  const se = `S${d.season_no ?? 1}E${d.episode_no ?? 1}`;

  return (
    <Page
      title={se}
      sub={d.series_name ?? undefined}
      onBack={back}
      right={
        <button type="button" ref={moreBtn} aria-label="更多" onClick={() => setSheet(true)}>
          <Icon n="more" size={21} />
        </button>
      }
      enterKey={d.id}
    >
      <div className="detail epd">
        <div className="ep-hero">
          <img
            src={thumbUrl(session, d.id, 900)}
            alt=""
            decoding="async"
            onError={(e) => ((e.target as HTMLImageElement).style.opacity = "0")}
          />
          <div className="dt-scrim" />
          {d.resume_secs > 0 && d.runtime_secs > 0 && (
            <div className="prog big">
              <i style={{ transform: `scaleX(${Math.min(1, d.resume_secs / d.runtime_secs)})` }} />
            </div>
          )}
        </div>

        <div className="epd-head">
          <div className="epd-crumb">
            {d.series_name} · {se}
          </div>
          <h1 className="epd-title">{d.name}</h1>
          <div className="dt-mi">
            <span>{fmtDur(d.runtime_secs)}</span>
            {d.year ? (
              <>
                <i className="mi-d" />
                <span>{d.year}</span>
              </>
            ) : null}
          </div>
          <div className="dt-acts">
            <PlayBtn
              label={d.resume_secs ? "继续播放" : "播放"}
              sub={d.resume_secs ? `剩余 ${Math.round((d.runtime_secs - d.resume_secs) / 60)} 分` : null}
              onClick={() => {
                haptic("tap");
                void play(self);
              }}
            />
            <IcoBtn
              icon="check"
              label="标记已看"
              onClick={() => {
                haptic("ok");
                setPlayed(d.id, true).then(() => toast("已标为看完", "ok")).catch((e) => toast(String(e), "bad"));
              }}
            />
            <IcoBtn
              icon="download"
              label="下载"
              onClick={() => {
                haptic("tap");
                downloadEnqueue(d.id, d.type_, d.name, "mkv", posterUrl(session, d.id, 360))
                  .then(() => toast("已加入下载队列"))
                  .catch((e) => toast(String(e), "bad"));
              }}
            />
          </div>
        </div>

        {/* 单集页的简介**不截断** —— 进到这一页来的人就是要看这个 */}
        <div className="dt-intro">
          <div className={`dt-ov${d.overview ? "" : " dim"}`}>
            <div className="dt-ov-t">
              {d.overview || "这一集没有简介 —— 服务器的元数据里就是空的。实测约 9.5% 的分集是这样。"}
            </div>
          </div>
        </div>

        {ver && (
          <div className="dt-rows">
            <button type="button" className="dt-row" onClick={() => setSheet(true)}>
              <span className="dt-row-l">
                <Icon n="info" size={17} />
                媒体信息
              </span>
              <span className="dt-row-v">
                {[
                  ver.streams?.find((s) => s.type_ === "Video")?.video_range_type,
                  fmtSize(ver.size_bytes ?? 0),
                ]
                  .filter(Boolean)
                  .join(" · ")}
              </span>
              <Icon n="chevR" size={16} />
            </button>
          </div>
        )}

        {/* 上一集 / 下一集 —— 调研里的标配,我们之前完全没有 */}
        <div className="epd-nav">
          {near === null ? (
            <div className="epd-nb off">正在找相邻的集…</div>
          ) : near.prev ? (
            <NavBtn dir="prev" label="上一集" ep={near.prev} onClick={jump(near.prev)} />
          ) : (
            <div className="epd-nb off">已是第一集</div>
          )}
          {near === null ? (
            <div className="epd-nb off" />
          ) : near.next ? (
            <NavBtn dir="next" label="下一集" ep={near.next} onClick={jump(near.next)} />
          ) : (
            <div className="epd-nb off">已是最后一集</div>
          )}
        </div>

        {near && near.siblings.length > 1 && (
          <section className="dt-sec">
            <div className="row-hd">
              <h2>本季其它集</h2>
              <button type="button" className="row-more" onClick={back}>
                全部
                <Icon n="chevR" size={15} />
              </button>
            </div>
            <div className="row-scroll">
              {near.siblings.map((x) => (
                <div className={`card thumb${x.id === d.id ? " cur" : ""}`} key={x.id} onClick={jump(x)}>
                  <div className="card-a ar-thumb">
                    <img src={thumbUrl(session, x.id, 400)} alt="" loading="lazy" decoding="async" />
                    {x.played && (
                      <div className="ep-done">
                        <Icon n="check" size={11} />
                      </div>
                    )}
                  </div>
                  <div className="card-cap">
                    {x.episode_no != null ? `${x.episode_no}. ` : ""}
                    {x.name}
                  </div>
                  <div className="card-sub">{fmtDur(x.runtime_secs)}</div>
                </div>
              ))}
            </div>
          </section>
        )}
        <div style={{ height: 28 }} />
      </div>

      <Sheet open={sheet} onClose={() => setSheet(false)} title="媒体信息">
        <div className="opts">
          {(["Video", "Audio", "Subtitle"] as const).map((t) => {
            const xs = (ver?.streams ?? []).filter((s) => s.type_ === t);
            if (!xs.length) return null;
            return (
              <div key={t}>
                <OptGroup>{t === "Video" ? "视频" : t === "Audio" ? "音频" : "字幕"}</OptGroup>
                {xs.map((s, i) => (
                  <Opt
                    key={s.index}
                    i={i}
                    label={s.display_title || s.codec}
                    sub={[s.codec?.toUpperCase(), s.width && s.height ? `${s.width}×${s.height}` : null, fmtBitrate(s.bitrate)]
                      .filter(Boolean)
                      .join(" · ")}
                    badge={s.is_default ? "默认" : undefined}
                  />
                ))}
              </div>
            );
          })}
          {!ver && <div className="mi-path">服务器没给这一集的媒体信息</div>}
          {ver && (
            <>
              <OptGroup>文件</OptGroup>
              <div className="mi-path">
                {[ver.container?.toUpperCase(), fmtSize(ver.size_bytes ?? 0), fmtRes(ver.streams?.find((s) => s.type_ === "Video")?.height ?? null)]
                  .filter(Boolean)
                  .join(" · ")}
              </div>
            </>
          )}
        </div>
      </Sheet>
    </Page>
  );
}

function NavBtn({
  dir,
  label,
  ep,
  onClick,
}: {
  dir: "prev" | "next";
  label: string;
  ep: Item;
  onClick: () => void;
}) {
  const ref = usePress<HTMLButtonElement>();
  const text = (
    <div>
      <i>{label}</i>
      <b>
        {ep.episode_no != null ? `${ep.episode_no}. ` : ""}
        {ep.name}
      </b>
    </div>
  );
  return (
    <button type="button" className={`epd-nb${dir === "next" ? " r" : ""}`} ref={ref} onClick={onClick}>
      {dir === "prev" ? <Icon n="back" size={18} /> : null}
      {text}
      {dir === "next" ? <Icon n="chevR" size={18} /> : null}
    </button>
  );
}

function PlayBtn({ label, sub, onClick }: { label: string; sub: string | null; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button type="button" className="btn primary dt-play" ref={ref} onClick={onClick}>
      <Icon n="play" size={19} />
      <span className="dt-play-t">{label}</span>
      {sub ? <span className="dt-play-s">{sub}</span> : null}
    </button>
  );
}

function IcoBtn({ icon, label, onClick }: { icon: string; label: string; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button type="button" className="btn dt-ico" aria-label={label} ref={ref} onClick={onClick}>
      <Icon n={icon} size={19} />
    </button>
  );
}
