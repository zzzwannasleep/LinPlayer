import { useEffect, useMemo, useRef, useState } from "react";
import {
  type Item,
  type ItemDetail,
  type MediaVersion,
  type SeasonInfo,
  type StreamInfo,
  backdropUrl,
  downloadEnqueue,
  fmtBitrate,
  fmtRes,
  fmtSize,
  itemDetailLite,
  itemMedia,
  logoUrl,
  peekItemDetailLite,
  personUrl,
  posterUrl,
  seasonEpisodes,
  seriesSeasons,
  setFavorite,
  setPlayed,
  similarItems,
  thumbUrl,
  defaultVersion,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { choreograph, haptic, toast } from "../app/motion";
import Page from "../components/Page";
import Sheet from "../components/Sheet";
import { Empty, Opt, OptGroup, Row, usePress } from "../components/ui";

/* 详情页 —— 剧集 / 电影共用这一页,靠 type 判分支。单集详情是**另一页**(EpisodePage)。

   ═══ 这一版重做的依据(2026-07-28,4 份调研 + 真服务器实测) ═══

   ★ Hero 从 `3:4 / max-height:62vh` 砍到 **16:9**。
     两份版式调研给的带宽是 260~300dp(占屏 31~36%),原来占 62% —— 播放按钮
     要滚一下才看得见。改 16:9 之后通栏播放按钮落在首屏内,这是这次最主要的收益。

   ★ 集列表**两种形态**,按集数自动选,可手动切:
       图文列表(≤50 集)  16:9 剧照 + 集号标题 + 时长/首播 + 2 行简介
       集号网格(>50 集)   6 列小方块,只有集号
     这不是审美选择 —— 实测那台服务器上 13.5% 的剧 ≥60 集,最长「康熙来了」**2648 集**,
     「哆啦A梦」862 集还**是单季**(季选择器救不了它)。图文列表在那种剧上不成立。

   ★ 集列表**分页**,30 条一批,滚到底续拉。
     实测全量拉 2648 集 = 1813.9KB / 1841ms;分页 30 条 = 20.0KB / 435ms。
     `content-visibility` 只省渲染,省不掉这 1.8MB 的下载和解析。
     → 所以这一页走 `itemDetailLite`(不带 children)+ `seasonEpisodes` 分页。

   ★ 季名用**服务器返回的 Name**,不拼「第 N 季」。
     实测真名是 "全 1 季" / "果宝特攻2" / "怪奇物语 4" —— 自己拼在真机上对不上。

   ★ 技术规格(4K/HDR/杜比/码率)**不上首屏**,收进「媒体信息」面板。
     Netflix/Disney+/Apple 详情页干脆不显示,Jellyfin 收面板里 —— 和用户砍画质标签
     的判断一致:"没人会为了参数去看一部烂片"。 */

const PAGE = 30;
/** 超过这个集数默认切集号网格 */
const GRID_THRESHOLD = 50;

/** 状态字段来自真接口的 `Status`,实测值:Continuing / Ended / Unreleased */
const STATUS_TEXT: Record<string, string> = {
  Continuing: "连载中",
  Ended: "已完结",
  Unreleased: "未播出",
};

/* 电影时长要说人话。fmtTime 给的是 "2:46:00" —— 那是**播放器进度**的格式,
   放在元信息行里读起来像时间戳。 */
const fmtDur = (s: number) => {
  const m = Math.round(s / 60);
  return m >= 60 ? `${Math.floor(m / 60)} 小时 ${m % 60} 分` : `${m} 分钟`;
};

export default function DetailPage({
  itemId,
  onHero,
}: {
  itemId?: string;
  /** FLIP 落点。★ 详情页 Hero 挂好后交给 App,由它把卡片那张封面飞过来。 */
  onHero: (el: HTMLElement | null) => void;
}) {
  const { session, go, back, openItem, play } = useCtx();
  const [d, setD] = useState<ItemDetail | null>(() => (itemId ? peekItemDetailLite(itemId) ?? null : null));
  const [err, setErr] = useState("");
  const [versions, setVersions] = useState<MediaVersion[]>([]);
  const [ver, setVer] = useState<MediaVersion | null>(null);
  /* ★ 用户**动过**版本选择器没有。`ver` 一进页面就被填成第一条(要给「版本」那行显示),
     所以它不能当「选过了」的判据 —— 起播时无脑把它的 id 传给核层,
     resolve_stream 就走「手动指定版本」分支,版本筛选正则整个被跳过
     (wiki regex-filters:手动选的 ＞ 正则命中 ＞ 列表第一个)。 */
  const [verPicked, setVerPicked] = useState(false);
  const [similar, setSimilar] = useState<Item[]>([]);
  const [fav, setFav] = useState(false);
  const [busy, setBusy] = useState("");
  const [sheet, setSheet] = useState<null | "ver" | "media" | "more">(null);
  const [ovOpen, setOvOpen] = useState(false);

  /* 季 + 集 */
  const [seasons, setSeasons] = useState<SeasonInfo[]>([]);
  const [seasonIdx, setSeasonIdx] = useState(0);
  const [eps, setEps] = useState<Item[]>([]);
  const [epTotal, setEpTotal] = useState(0);
  const [mode, setMode] = useState<"list" | "grid">("list");

  const heroRef = useRef<HTMLDivElement>(null);
  const epBoxRef = useRef<HTMLDivElement>(null);

  const isSeries = d?.type_ === "Series";

  useEffect(() => {
    if (!itemId) return;
    let alive = true;
    setErr("");
    itemDetailLite(itemId)
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
        // 显示正则会挑中的那条(= 核层起播会挑的那条),不是列表第一条。
        setVer(defaultVersion(v));
        setVerPicked(false);
      })
      .catch(() => {});
    similarItems(itemId).then((s) => alive && setSimilar(s)).catch(() => {});
    return () => {
      alive = false;
    };
  }, [itemId]);

  /* 季列表。★ 返回空数组是合法的 —— 有些剧没分季,集直接挂在剧下。
     那种情况把 seriesId 当 parent 直接分页拉集。 */
  useEffect(() => {
    if (!itemId || !isSeries) return;
    let alive = true;
    seriesSeasons(itemId)
      .then((s) => {
        if (!alive) return;
        setSeasons(s);
        setSeasonIdx(0);
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [itemId, isSeries]);

  /** 当前这一季的 parent id 和集数 —— 没有季就回落到剧本身。 */
  const cur = seasons[seasonIdx];
  const epParent = cur?.id ?? (isSeries ? itemId : undefined);
  const epCount = cur?.child_count ?? d?.child_count ?? 0;

  useEffect(() => {
    if (!epParent) return;
    let alive = true;
    setEps([]);
    setEpTotal(0);
    // 集数多就默认集号网格。★ 自动选了之后**仍然允许手动切** —— "我就想看剧照"是合理诉求
    setMode(epCount > GRID_THRESHOLD ? "grid" : "list");
    seasonEpisodes(epParent, 0, PAGE)
      .then((p) => {
        if (!alive) return;
        setEps(p.items);
        setEpTotal(p.total);
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [epParent, epCount]);

  const loadMore = () => {
    if (!epParent || eps.length >= epTotal) return;
    seasonEpisodes(epParent, eps.length, PAGE)
      .then((p) => setEps((x) => [...x, ...p.items]))
      .catch(() => {});
  };

  useEffect(() => {
    choreograph(epBoxRef.current);
  }, [eps.length, mode]);

  /* Hero 一挂好就把 FLIP 交出去。★ 必须在**图片元素存在之后** —— 交早了
     flipTo 拿到的 rect 是 0 宽高,会直接 return,共享元素静默退化成"直接出现"。 */
  useEffect(() => {
    if (d && heroRef.current) onHero(heroRef.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [d?.id]);

  /* 「播放」按到哪一集:剧集找第一个有进度的、否则第一个没看完的、否则第一集。 */
  const target: Item | null = useMemo(() => {
    if (!d) return null;
    if (isSeries) return eps.find((e) => e.resume_secs > 0) ?? eps.find((e) => !e.played) ?? eps[0] ?? null;
    return {
      id: d.id, name: d.name, type_: d.type_, is_folder: false,
      has_primary: d.has_primary, runtime_secs: d.runtime_secs, resume_secs: d.resume_secs,
      series_name: d.series_name, episode_no: d.episode_no, season_no: d.season_no,
      video_height: null, bitrate: null, size_bytes: null, played: false,
      unplayed_item_count: 0, genres: d.genres, year: d.year, rating: d.rating,
      provider_ids: {}, presentation_unique_key: null, path: null,
      series_id: d.series_id, date_updated: null, sort_name: null,
    };
  }, [d, isSeries, eps]);

  const moreBtn = usePress<HTMLButtonElement>();

  if (err) {
    return (
      <Page title="详情" onBack={back}>
        <Empty icon="info" title="加载失败" desc={err} />
      </Page>
    );
  }
  if (!d || !session) {
    return (
      <Page title="详情" onBack={back}>
        <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
      </Page>
    );
  }

  /* ★ 播放按钮文案带上"剩余 xx 分"(调研里 Netflix/Prime 的做法):
     "继续播放"三个字不告诉你还剩多少,而那正是决定现在看不看的信息。 */
  let playLabel: string;
  let playSub: string | null = null;
  if (isSeries && target) {
    const se = `S${target.season_no ?? 1}E${target.episode_no ?? 1}`;
    playLabel = target.resume_secs ? `继续 ${se}` : `播放 ${se}`;
    playSub = target.resume_secs
      ? `剩余 ${Math.round((target.runtime_secs - target.resume_secs) / 60)} 分`
      : null;
  } else {
    playLabel = d.resume_secs ? "继续播放" : "播放";
    playSub = d.resume_secs ? `剩余 ${Math.round((d.runtime_secs - d.resume_secs) / 60)} 分` : null;
  }

  const ovText =
    d.overview || "这部作品还没有简介 —— 服务器上的元数据里就是空的,不是没加载出来。";

  return (
    <Page
      title={d.name}
      onBack={back}
      right={
        <button type="button" ref={moreBtn} aria-label="更多" onClick={() => setSheet("more")}>
          <Icon n="more" size={21} />
        </button>
      }
      enterKey={d.id}
    >
      <div className="detail">
        {/* ★ `.dt-hero` 是 FLIP 的落点。改类名要同步改 App.tsx 里交接的那一处,
            否则共享元素静默退化成"直接出现"(不报错,只是没了)。 */}
        <div className="dt-hero" ref={heroRef}>
          <img
            src={d.has_backdrop ? backdropUrl(session, d.id, 1080) : posterUrl(session, d.id, 720)}
            alt=""
            decoding="async"
            onError={(e) => ((e.target as HTMLImageElement).style.opacity = "0")}
          />
          <div className="dt-scrim" />
          <div className="dt-cap">
            {/* 艺术字实测 88% 有,缺的 12% 回退成纯文字大标题 —— 两种都要能看,
                不能做成"有 logo 才好看,没 logo 就秃"。 */}
            <img
              className="dt-logo"
              src={logoUrl(session, d.id, 150)}
              alt={d.name}
              decoding="async"
              onError={(e) => {
                const im = e.target as HTMLImageElement;
                im.style.display = "none";
                // 没有 logo 时才把纯文字标题放大 —— 两个一起显示是重复
                im.parentElement?.classList.add("no-logo");
              }}
            />
            <div className="dt-name">{d.name}</div>
          </div>
        </div>

        <div className="dt-head">
          {/* 年份 · 分级 · 状态 · 评分 · 季集数/时长 · 类型
              ★ 分级(OfficialRating)和状态(Status)是这一版**新加**的 —— 真接口有,
                而"这剧完结没有"是选片时真正会问的问题,比画质标签有用得多。 */}
          <div className="dt-mi">
            {joinDots([
              d.year ? <span key="y">{d.year}</span> : null,
              d.official_rating ? <span className="mi-cert" key="c">{d.official_rating}</span> : null,
              isSeries && d.status ? (
                <span className={d.status === "Continuing" ? "mi-on" : undefined} key="s">
                  {STATUS_TEXT[d.status] ?? d.status}
                </span>
              ) : null,
              d.rating ? (
                <span className="mi-star" key="r">
                  <Icon n="star" size={12} />
                  {d.rating.toFixed(1)}
                </span>
              ) : null,
              isSeries ? (
                <span key="n">
                  {seasons.length > 1
                    ? `${seasons.length} 季 ${seasons.reduce((a, s) => a + s.child_count, 0)} 集`
                    : `${epTotal || epCount} 集`}
                </span>
              ) : d.runtime_secs ? (
                <span key="d">{fmtDur(d.runtime_secs)}</span>
              ) : null,
              d.genres?.length ? <span key="g">{d.genres.join(" / ")}</span> : null,
            ])}
          </div>

          {/* ★ 播放按钮做通栏 —— 拇指区在下面,通栏是为了不用瞄准。 */}
          <div className="dt-acts">
            <PlayBtn
              label={playLabel}
              sub={playSub}
              disabled={!target}
              onClick={() => {
                if (!target) return;
                haptic("tap");
                void play(target, isSeries || !verPicked ? null : ver?.id ?? null);
              }}
            />
            <IcoBtn
              icon={fav ? "heartOn" : "heart"}
              label={fav ? "取消收藏" : "收藏"}
              on={fav}
              beat
              onClick={() => {
                const next = !fav;
                setFav(next); // 先反显再发请求 —— 手机网络慢,等回包再变会让人以为没点上
                haptic(next ? "ok" : "tap");
                setFavorite(d.id, next)
                  .then(() => toast(next ? "已加入收藏" : "已取消收藏", next ? "ok" : ""))
                  .catch(() => setFav(!next));
              }}
            />
            <IcoBtn
              icon="download"
              label="下载"
              disabled={!target || busy === "dl"}
              onClick={() => {
                if (!target) return;
                setBusy("dl");
                haptic("tap");
                /* container 传 "mkv" 与 PC 一致 —— 核层拿它做落盘文件名后缀,
                   不是"要求服务端转成 mkv"。传空会得到一个没有扩展名的文件。 */
                downloadEnqueue(target.id, target.type_, target.name, "mkv", posterUrl(session, target.id, 360))
                  .then(() => toast("已加入下载队列"))
                  .catch((e) => toast(String(e), "bad"))
                  .finally(() => setBusy(""));
              }}
            />
            <IcoBtn icon="more" label="更多" onClick={() => setSheet("more")} />
          </div>
        </div>

        {/* ★ 标语实测只有 34% 的条目有 —— 没有就**整行不画**,不留空位。
            ★ 「更多」浮在最后一行**行尾**,不另起一行:另起一行会在简介只有 3 行时
              平白多占一行高度。 */}
        <div className="dt-intro">
          {d.tagline ? <div className="dt-tag">{d.tagline}</div> : null}
          <div className={`dt-ov${ovOpen ? "" : " clamp"}`}>
            <div className="dt-ov-t">{ovText}</div>
            <button type="button" className="dt-ov-more" onClick={() => setOvOpen((v) => !v)}>
              {ovOpen ? "收起" : "更多"}
            </button>
          </div>
        </div>

        <div className="dt-rows">
          {versions.length > 1 && (
            <DtRow
              icon="version"
              label="版本"
              value={`${fmtRes(ver?.streams?.find((s) => s.type_ === "Video")?.height ?? null) || ver?.name || ""} · ${fmtSize(ver?.size_bytes ?? 0)}`}
              onClick={() => setSheet("ver")}
            />
          )}
          {ver && (
            <DtRow
              icon="info"
              label="媒体信息"
              value={mediaSummary(ver)}
              onClick={() => setSheet("media")}
            />
          )}
        </div>

        {isSeries && (
          /* ★ `.dt-eps` 不参与进场动画 —— 它里面是 sticky 的季条,祖先一旦带 transform
             sticky 会**静默失效**,进场那 400ms 季条会跟着一起滚走。
             这和「transform 关键帧毁 fixed 定位」是同一个坑。 */
          <section className="dt-sec dt-eps">
            <div className="row-hd">
              <h2>剧集</h2>
              <button
                type="button"
                className="ep-mode"
                aria-label="切换列表形态"
                onClick={() => {
                  haptic("sel");
                  setMode((m) => (m === "grid" ? "list" : "grid"));
                }}
              >
                <Icon n={mode === "grid" ? "list" : "grid"} size={18} />
              </button>
            </div>

            {seasons.length > 1 && (
              <div className="season-bar">
                <div className="season-scroll">
                  {seasons.map((s, i) => (
                    <button
                      key={s.id}
                      type="button"
                      className={`season-t${i === seasonIdx ? " on" : ""}`}
                      onClick={(e) => {
                        if (i === seasonIdx) return;
                        haptic("sel");
                        setSeasonIdx(i);
                        e.currentTarget.scrollIntoView({ inline: "center", block: "nearest", behavior: "smooth" });
                      }}
                    >
                      {/* ★ 季名直接用服务器给的 —— 别拼「第 N 季」 */}
                      <span>{s.name}</span>
                      <i>{s.child_count} 集</i>
                    </button>
                  ))}
                </div>
              </div>
            )}

            <div className={`ep-box ${mode === "grid" ? "as-grid" : "as-list"}`} ref={epBoxRef}>
              {eps.map((e, i) =>
                mode === "grid" ? (
                  <EpCell key={e.id} e={e} i={i % PAGE} onOpen={() => goEp(e)} />
                ) : (
                  <EpCard key={e.id} e={e} i={i % PAGE} session={session} onOpen={() => goEp(e)} />
                ),
              )}
            </div>

            <div className="ep-foot">
              {eps.length >= epTotal && epTotal > 0 ? (
                <div className="ep-all">全 {epTotal} 集</div>
              ) : epTotal > 0 ? (
                /* 数字要说人话:"30 / 2648" 比"加载更多"信息量大得多 */
                <button
                  type="button"
                  className="ep-more"
                  onClick={() => {
                    haptic("tap");
                    loadMore();
                  }}
                >
                  加载更多 · 已显示 {eps.length} / {epTotal}
                </button>
              ) : (
                <div className="ep-all dim">这一季一集都没有</div>
              )}
            </div>
          </section>
        )}

        {d.people.length > 0 && (
          <section className="dt-sec">
            <div className="row-hd">
              <h2>演职员</h2>
            </div>
            {/* ★ 实测 18.6% 的人**没有头像**。破图不是"偶发",是每五个人里就有一个。
                兜底 = 姓氏首字 + 该人的主色底,和有头像的排在一起不掉队。 */}
            <div className="row-scroll">
              {d.people.slice(0, 24).map((p) => (
                <div className="person" key={p.id} onClick={() => toast(`按「${p.name}」筛选还没做`)}>
                  {p.has_primary ? (
                    <div className="person-av">
                      <img src={personUrl(session, p.id, 160)} alt="" loading="lazy" decoding="async" />
                    </div>
                  ) : (
                    <div className="person-av fb" style={{ background: hueOf(p.id) }}>
                      {p.name.slice(0, 1)}
                    </div>
                  )}
                  <div className="person-n">{p.name}</div>
                  {p.role ? <div className="person-r">{p.role}</div> : null}
                </div>
              ))}
            </div>
          </section>
        )}

        {similar.length > 0 && (
          <section className="dt-sec">
            <Row
              title={isSeries ? "相似剧集" : "相似影片"}
              items={similar}
              session={session}
              onOpen={(x, el) => openItem(x, el ? flipOf(el) : null)}
            />
          </section>
        )}
        <div style={{ height: 28 }} />
      </div>

      {/* ── 版本选择 ── */}
      <Sheet open={sheet === "ver"} onClose={() => setSheet(null)} title="选择版本">
        <div className="opts">
          {versions.map((v, i) => (
            <Opt
              key={v.id}
              i={i}
              on={v.id === ver?.id}
              label={v.name}
              sub={[
                fmtRes(v.streams?.find((s) => s.type_ === "Video")?.height ?? null),
                fmtSize(v.size_bytes ?? 0),
                v.container?.toUpperCase(),
                fmtBitrate(v.bitrate),
              ]
                .filter(Boolean)
                .join(" · ")}
              onClick={() => {
                setVer(v);
                setVerPicked(true);
                haptic("sel");
                setSheet(null);
              }}
            />
          ))}
        </div>
      </Sheet>

      {/* ── 媒体信息 ──
          分 视频 / 音频 / 字幕 三组(Jellyfin 的分法)。
          ★ 每一行的主标题直接用服务器的 `DisplayTitle` —— 实测它已经是人话
            ("English TRUEHD 7.1"、"Chinese AC3 stereo (默认)"),自己拼反而拼不过它。 */}
      <Sheet
        open={sheet === "media"}
        onClose={() => setSheet(null)}
        title="媒体信息"
      >
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
                    sub={streamSub(s)}
                    badge={s.is_default ? "默认" : undefined}
                  />
                ))}
              </div>
            );
          })}
          <OptGroup>文件</OptGroup>
          <div className="mi-path">
            {[ver?.container?.toUpperCase(), fmtSize(ver?.size_bytes ?? 0), fmtBitrate(ver?.bitrate ?? null)]
              .filter(Boolean)
              .join(" · ") || "服务器没给这一版的文件信息"}
          </div>
        </div>
      </Sheet>

      {/* ── 更多 ── */}
      <Sheet open={sheet === "more"} onClose={() => setSheet(null)} title={d.name}>
        <div className="opts">
          <Opt
            label={`标为${isSeries ? "整部" : ""}已看`}
            i={0}
            onClick={() => {
              setSheet(null);
              setPlayed(d.id, true).then(() => toast("已标为看完", "ok")).catch((e) => toast(String(e), "bad"));
            }}
          />
          <Opt
            label={fav ? "取消收藏" : "加入收藏"}
            i={1}
            onClick={() => {
              setSheet(null);
              const next = !fav;
              setFav(next);
              setFavorite(d.id, next).then(() => toast(next ? "已加入收藏" : "已取消收藏", "ok"));
            }}
          />
          {isSeries && eps.length > 0 && (
            <Opt
              label={`下载本季 ${eps.length} 集`}
              sub="按当前已加载的集数排队"
              i={2}
              onClick={() => {
                setSheet(null);
                Promise.allSettled(
                  eps.map((e) =>
                    downloadEnqueue(e.id, e.type_, e.name, "mkv", posterUrl(session, e.id, 360)),
                  ),
                ).then(() => toast(`已排队 ${eps.length} 集`, "ok"));
              }}
            />
          )}
          <Opt
            label="在媒体库里看这一部"
            i={3}
            onClick={() => {
              setSheet(null);
              go({ page: "library", parentId: d.series_id ?? d.id, title: d.name });
            }}
          />
        </div>
      </Sheet>
    </Page>
  );

  function goEp(e: Item) {
    haptic("tap");
    go({
      page: "episode",
      itemId: e.id,
      title: e.name,
      season: e.season_no ?? undefined,
      ep: e.episode_no ?? undefined,
    });
  }
}

/* ---------- 小件 ---------- */

function PlayBtn({
  label,
  sub,
  disabled,
  onClick,
}: {
  label: string;
  sub: string | null;
  disabled?: boolean;
  onClick: () => void;
}) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button type="button" className="btn primary dt-play" ref={ref} disabled={disabled} onClick={onClick}>
      <Icon n="play" size={19} />
      <span className="dt-play-t">{label}</span>
      {sub ? <span className="dt-play-s">{sub}</span> : null}
    </button>
  );
}

function IcoBtn({
  icon,
  label,
  on,
  beat,
  disabled,
  onClick,
}: {
  icon: string;
  label: string;
  on?: boolean;
  beat?: boolean;
  disabled?: boolean;
  onClick: () => void;
}) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button
      type="button"
      className={`btn dt-ico${on ? " on" : ""}${on && beat ? " beat" : ""}`}
      aria-label={label}
      ref={ref}
      disabled={disabled}
      onClick={onClick}
    >
      <Icon n={icon} size={19} />
    </button>
  );
}

function DtRow({
  icon,
  label,
  value,
  onClick,
}: {
  icon: string;
  label: string;
  value: string;
  onClick: () => void;
}) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button type="button" className="dt-row" ref={ref} onClick={onClick}>
      <span className="dt-row-l">
        <Icon n={icon} size={17} />
        {label}
      </span>
      <span className="dt-row-v">{value}</span>
      <Icon n="chevR" size={16} />
    </button>
  );
}

function EpCard({
  e,
  i,
  session,
  onOpen,
}: {
  e: Item;
  i: number;
  session: NonNullable<ReturnType<typeof useCtx>["session"]>;
  onOpen: () => void;
}) {
  const [loaded, setLoaded] = useState(false);
  return (
    <button
      type="button"
      className={`ep${e.played ? " seen" : ""}`}
      style={{ ["--i" as string]: i }}
      onClick={onOpen}
    >
      <div className="ep-th">
        {!loaded && <div className="skel" />}
        <img
          src={thumbUrl(session, e.id, 400)}
          alt=""
          loading="lazy"
          decoding="async"
          onLoad={(x) => {
            (x.target as HTMLImageElement).classList.add("ready");
            setLoaded(true);
          }}
          onError={() => setLoaded(true)}
        />
        {e.resume_secs > 0 && e.runtime_secs > 0 && (
          <div className="prog">
            <i style={{ transform: `scaleX(${Math.min(1, e.resume_secs / e.runtime_secs)})` }} />
          </div>
        )}
        {e.played && (
          <div className="ep-done">
            <Icon n="check" size={12} />
          </div>
        )}
      </div>
      <div className="ep-t">
        <div className="ep-n">
          <b>{e.episode_no ?? ""}</b>
          {e.name}
        </div>
        <div className="ep-m">
          {[
            e.runtime_secs ? fmtDur(e.runtime_secs) : null,
            e.video_height ? fmtRes(e.video_height) : null,
            e.size_bytes ? fmtSize(e.size_bytes) : null,
          ]
            .filter(Boolean)
            .join(" · ")}
        </div>
      </div>
    </button>
  );
}

function EpCell({ e, i, onOpen }: { e: Item; i: number; onOpen: () => void }) {
  const part = e.resume_secs > 0 && e.runtime_secs > 0;
  return (
    <button
      type="button"
      className={`epc${e.played ? " seen" : ""}${part ? " part" : ""}`}
      style={{ ["--i" as string]: i }}
      onClick={onOpen}
    >
      <span>{e.episode_no ?? "?"}</span>
      {part && <i style={{ transform: `scaleX(${Math.min(1, e.resume_secs / e.runtime_secs)})` }} />}
    </button>
  );
}

/* ---------- 工具 ---------- */

/** 用 `<i class="mi-d">` 当分隔点插在各项之间。null 项直接跳过,不留空分隔。 */
function joinDots(nodes: (React.ReactNode | null)[]) {
  const xs = nodes.filter(Boolean);
  return xs.flatMap((n, i) => (i ? [<i className="mi-d" key={`d${i}`} />, n] : [n]));
}

function mediaSummary(v: MediaVersion) {
  const vid = v.streams?.find((s) => s.type_ === "Video");
  return [vid?.video_range_type || vid?.video_range, v.container?.toUpperCase(), fmtSize(v.size_bytes ?? 0)]
    .filter(Boolean)
    .join(" · ");
}

function streamSub(s: StreamInfo) {
  return [
    s.codec?.toUpperCase(),
    s.width && s.height ? `${s.width}×${s.height}` : null,
    s.frame_rate ? `${s.frame_rate.toFixed(3)} fps` : null,
    s.channel_layout,
    fmtBitrate(s.bitrate),
    s.is_external ? "外挂" : null,
  ]
    .filter(Boolean)
    .join(" · ");
}

/** 没头像时的兜底底色。确定性:同一个人每次都是同一个颜色。 */
function hueOf(id: string) {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return `hsl(${h % 360} 32% 26%)`;
}

function flipOf(el: HTMLElement) {
  const img = el.querySelector("img");
  return {
    rect: el.getBoundingClientRect(),
    src: img?.currentSrc || img?.src || "",
    radius: getComputedStyle(el).borderRadius,
  };
}
