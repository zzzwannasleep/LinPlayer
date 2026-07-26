import { useEffect, useMemo, useState } from "react";
import {
  type Item,
  type ItemDetail,
  type LoginResult,
  type MediaVersion,
  backdropUrl,
  downloadEnqueue,
  fmtRes,
  fmtSize,
  fmtTime,
  itemDetail,
  itemMedia,
  peekItemDetail,
  personUrl,
  posterUrl,
  setFavorite,
  setPlayed,
  similarItems,
} from "@shared/api";
import Card from "../components/Card";
import Sheet from "../components/Sheet";
import { IconCheck, IconDownload, IconHeart, IconList, IconPlay } from "../app/icons";

/* 详情页 —— **沉浸式**。

   ## 与 PC 的差异
   PC 是「左封面 + 右信息 + 下面几个页签」。手机上:
   - 背景图铺满上半屏,信息块压在上面(**不用渐变遮罩**,用不透明底 —— 理由见 mobile.css)
   - 没有页签。剧集/演员/相似**竖着排下去**,一路滚到底。
     页签在手机上是"每个都要点一下才知道里面有没有东西",而竖排一滑就全看见了。
   - 版本选择、剧集选择走 bottom sheet(PC 是下拉)

   ## 首屏不空白
   `peekItemDetail` 先同步偷缓存(5 分钟 TTL)。取不到才转圈。
   PC 端曾经每次 mount 都 setD(null) 全量重拉 —— 来回翻两个条目每次都回源,还必闪一下白。 */

type Props = {
  session: LoginResult;
  itemId?: string;
  onPlay: (it: Item, mediaSourceId?: string | null) => void;
  onOpen: (it: Item) => void;
};

export default function DetailPage({ session, itemId, onPlay, onOpen }: Props) {
  const [d, setD] = useState<ItemDetail | null>(() => (itemId ? peekItemDetail(itemId) ?? null : null));
  const [err, setErr] = useState("");
  const [versions, setVersions] = useState<MediaVersion[]>([]);
  const [ver, setVer] = useState<MediaVersion | null>(null);
  const [similar, setSimilar] = useState<Item[]>([]);
  const [season, setSeason] = useState<number | null>(null);
  const [sheet, setSheet] = useState<null | "ver" | "season">(null);
  const [fav, setFav] = useState(false);
  const [busy, setBusy] = useState("");

  useEffect(() => {
    if (!itemId) return;
    let alive = true;
    setErr("");
    itemDetail(itemId)
      .then((x) => {
        if (!alive) return;
        setD(x);
        setFav(x.is_favorite);
      })
      .catch((e) => alive && setErr(String(e)));
    // 版本和相似各自到、各自渲染 —— 不跟主详情绑成一个 Promise.all 屏障
    itemMedia(itemId)
      .then((v) => {
        if (!alive) return;
        setVersions(v);
        setVer(v[0] ?? null);
      })
      .catch(() => {});
    similarItems(itemId).then((s) => alive && setSimilar(s)).catch(() => {});
    return () => {
      alive = false;
    };
  }, [itemId]);

  const episodes = d?.children ?? []; // children 已按季+集号排序
  const seasons = useMemo(() => {
    const set = new Set<number>();
    for (const e of episodes) if (e.season_no != null) set.add(e.season_no);
    return [...set].sort((a, b) => a - b);
  }, [episodes]);
  const isSeries = d?.type_ === "Series";
  const curSeason = season ?? seasons[0] ?? null;
  const shownEps = curSeason == null ? episodes : episodes.filter((e) => e.season_no === curSeason);

  /* 「播放」按到哪一集:剧集找第一个有进度的,没有就第一集。
     电影/单集就是它自己。 */
  const target: Item | null = useMemo(() => {
    if (!d) return null;
    if (isSeries) return episodes.find((c) => c.resume_secs > 0) ?? episodes[0] ?? null;
    return {
      id: d.id, name: d.name, type_: d.type_, is_folder: false,
      has_primary: d.has_primary, runtime_secs: d.runtime_secs, resume_secs: d.resume_secs,
      series_name: d.series_name, episode_no: d.episode_no, season_no: d.season_no,
      video_height: null, bitrate: null, size_bytes: null, played: false,
      unplayed_item_count: 0, genres: d.genres, year: d.year, rating: d.rating,
      provider_ids: {}, presentation_unique_key: null, path: null,
      series_id: d.series_id, date_updated: null, sort_name: null,
    };
  }, [d, isSeries, episodes]);

  if (err) return <div className="empty"><b>加载失败</b><div className="dim">{err}</div></div>;
  if (!d) return <div className="empty"><div className="dim">加载中…</div></div>;

  const playLabel = target?.resume_secs
    ? `继续 ${fmtTime(target.resume_secs)}`
    : isSeries && target?.episode_no != null
      ? `播放 S${target.season_no ?? 1}E${target.episode_no}`
      : "播放";

  return (
    <div className="detail">
      <div className="dt-hero">
        <img
          className="dt-bd"
          src={d.has_backdrop ? backdropUrl(session, d.id, 1080) : posterUrl(session, d.id, 720)}
          alt=""
          decoding="async"
          onError={(e) => ((e.target as HTMLImageElement).style.opacity = "0")}
        />
        <div className="dt-cap">
          <div className="dt-title">{d.name}</div>
          <div className="dt-meta dim">
            {[
              d.year,
              d.runtime_secs ? fmtTime(d.runtime_secs) : null,
              d.rating ? `★ ${d.rating.toFixed(1)}` : null,
              isSeries && episodes.length ? `${episodes.length} 集` : null,
            ].filter(Boolean).join(" · ")}
          </div>
        </div>
      </div>

      {/* 主操作条排在屏幕上,但**播放按钮做满宽** —— 拇指区在下面,而这一条会被
          用户滚到手边;做满宽是为了不用瞄准。 */}
      <div className="dt-acts">
        <button
          type="button"
          className="btn primary dt-play"
          disabled={!target}
          onClick={() => target && onPlay(target, isSeries ? null : ver?.id ?? null)}
        >
          <IconPlay size={18} /> {playLabel}
        </button>
        <button
          type="button"
          className={`btn dt-ico${fav ? " on" : ""}`}
          aria-label={fav ? "取消收藏" : "收藏"}
          onClick={() => {
            const next = !fav;
            setFav(next); // 先反显再发请求 —— 手机网络慢,等回包再变会让人以为没点上
            setFavorite(d.id, next).catch(() => setFav(!next));
          }}
        >
          <IconHeart size={18} />
        </button>
        {!isSeries && (
          <button
            type="button"
            className="btn dt-ico"
            aria-label="标记已看"
            onClick={() => {
              setBusy("mark");
              setPlayed(d.id, true).finally(() => setBusy(""));
            }}
            disabled={busy === "mark"}
          >
            <IconCheck size={18} />
          </button>
        )}
        <button
          type="button"
          className="btn dt-ico"
          aria-label="下载"
          disabled={!target || busy === "dl"}
          onClick={() => {
            if (!target) return;
            setBusy("dl");
            /* container 传 "mkv" 与 PC 一致 —— 核层拿它做落盘文件名后缀,
               不是"要求服务端转成 mkv"。传空会得到一个没有扩展名的文件。 */
            downloadEnqueue(target.id, target.type_, target.name, "mkv", posterUrl(session, target.id, 360))
              .finally(() => setBusy(""));
          }}
        >
          <IconDownload size={18} />
        </button>
      </div>

      {versions.length > 1 && (
        <button type="button" className="dt-row" onClick={() => setSheet("ver")}>
          <span>版本</span>
          <span className="dim">
            {ver?.name ?? versions[0].name}
            {ver?.streams?.[0]?.height ? ` · ${fmtRes(ver.streams[0].height)}` : ""}
          </span>
        </button>
      )}

      {d.overview && <p className="dt-ov">{d.overview}</p>}

      {isSeries && episodes.length > 0 && (
        <section className="dt-sec">
          <div className="row-hd">
            <h2>剧集</h2>
            {seasons.length > 1 && (
              <button type="button" className="row-more" onClick={() => setSheet("season")}>
                第 {curSeason} 季 ▾
              </button>
            )}
          </div>
          <div className="eps">
            {shownEps.map((e) => (
              <button key={e.id} type="button" className="ep" onClick={() => onPlay(e)}>
                <div className="ep-th">
                  {e.has_primary ? (
                    <img src={posterUrl(session, e.id, 200)} alt="" loading="lazy" decoding="async" />
                  ) : (
                    <span className="mfallback"><IconList size={18} /></span>
                  )}
                  {e.resume_secs > 0 && e.runtime_secs > 0 && (
                    <div className="m-prog">
                      <i style={{ width: `${Math.min(100, (e.resume_secs / e.runtime_secs) * 100)}%` }} />
                    </div>
                  )}
                  {e.played && <div className="m-played"><IconCheck size={11} /></div>}
                </div>
                <div className="ep-t">
                  <div className="ep-n">
                    {e.episode_no != null ? `${e.episode_no}. ` : ""}
                    {e.name}
                  </div>
                  <div className="ep-m dim">
                    {[
                      e.runtime_secs ? fmtTime(e.runtime_secs) : null,
                      e.video_height ? fmtRes(e.video_height) : null,
                      e.size_bytes ? fmtSize(e.size_bytes) : null,
                    ].filter(Boolean).join(" · ")}
                  </div>
                </div>
              </button>
            ))}
          </div>
        </section>
      )}

      {d.people.length > 0 && (
        <section className="dt-sec">
          <div className="row-hd"><h2>演职员</h2></div>
          <div className="row-scroll">
            {d.people.slice(0, 24).map((p) => (
              <div key={p.id} className="person">
                <div className="person-av">
                  {p.has_primary && (
                    <img src={personUrl(session, p.id, 160)} alt="" loading="lazy" decoding="async" />
                  )}
                </div>
                <div className="person-n">{p.name}</div>
                {p.role && <div className="person-r dim">{p.role}</div>}
              </div>
            ))}
          </div>
        </section>
      )}

      {similar.length > 0 && (
        <section className="dt-sec">
          <div className="row-hd"><h2>相似内容</h2></div>
          <div className="row-scroll">
            {similar.map((it, i) => (
              <Card key={it.id} item={it} session={session} index={i} onOpen={onOpen} />
            ))}
          </div>
        </section>
      )}

      <Sheet open={sheet === "ver"} onClose={() => setSheet(null)} title="版本">
        <div className="opts">
          {versions.map((v) => (
            <button
              key={v.id}
              type="button"
              className={`opt${v.id === ver?.id ? " on" : ""}`}
              onClick={() => {
                setVer(v);
                setSheet(null);
              }}
            >
              <div>{v.name}</div>
              <div className="dim">
                {[
                  v.streams?.[0]?.height ? fmtRes(v.streams[0].height) : null,
                  v.size_bytes ? fmtSize(v.size_bytes) : null,
                  v.container,
                ].filter(Boolean).join(" · ")}
              </div>
            </button>
          ))}
        </div>
      </Sheet>

      <Sheet open={sheet === "season"} onClose={() => setSheet(null)} title="选择季">
        <div className="opts">
          {seasons.map((s) => (
            <button
              key={s}
              type="button"
              className={`opt${s === curSeason ? " on" : ""}`}
              onClick={() => {
                setSeason(s);
                setSheet(null);
              }}
            >
              第 {s} 季
            </button>
          ))}
        </div>
      </Sheet>
    </div>
  );
}
