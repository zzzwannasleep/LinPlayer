import { useEffect, useMemo, useRef, useState } from "react";
import {
  type Item,
  type ItemDetail,
  type MediaVersion,
  type SeasonInfo,
  defaultVersion,
  downloadEnqueue,
  fmtRes,
  itemDetailLite,
  itemMedia,
  peekItemDetailLite,
  personUrl,
  posterUrl,
  seasonEpisodes,
  seriesSeasons,
  setFavorite,
  setPlayed,
  similarItems,
  thumbUrl,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { dominantOf, washColor } from "../app/color";
import { Icon } from "../app/icons";
import { choreograph, haptic, toast } from "../app/motion";
import Page from "../components/Page";
import Sheet from "../components/Sheet";
import MediaCard from "../components/MediaCard";
import PlaySetup from "../components/PlaySetup";
import { Empty, Opt, Row, usePress } from "../components/ui";

/* 详情页 —— 剧集 / 电影共用这一页,靠 type 判分支。单集详情是**另一页**(EpisodePage)。

   ═══ 2026-08-01 这一版(用户逐条点名) ═══

   ★ **Hero 从 16:9 剧照换成大海报。**
     上一版是通栏 16:9 backdrop,海报本身小到只是卡片里那一张。用户原话:
     「剧封面目前海报尺寸太小,不好看,需要做成大图」。现在是居中的 2:3 大海报,
     `object-fit: contain` —— **不裁剪**(用户点名),宁可两边留出背景。

   ★ **背景是海报的主色向下延伸的渐变。** 真去读像素投票选主色(见 app/color.ts),
     不是按 id 哈希那种"确定性的假主色" —— 海报就在渐变正上方,颜色对不上一眼看得出来。

   ★ **通透化。** 上一版的边框/分隔线/不透明底块(.dt-rows 的上下边线、季选择条的实心药丸、
     媒体信息那一行)全部让位给半透明玻璃。

   ★ **剧集列表默认横滑轨道**,右上角一个按钮切"矩形网格平铺"。
     上一版是纵向长列表,60 集以上下滑体验极差(实测这台服务器 13.5% 的剧 ≥60 集)。

   ★ **演职员改矩形头像、可点进人物页**(圆头像会把脸裁掉,而且我们不缺这点宽度)。

   ★ **去掉动作区里那个重复的「更多」** —— 顶栏右上角已经有一个了。

   ═══ 上一版留下来、仍然成立的结论 ═══
   ★ 集列表**分页**,30 条一批。实测全量拉 2648 集 = 1813.9KB / 1841ms;分页 30 条 = 20.0KB / 435ms。
     所以这一页走 `itemDetailLite`(不带 children)+ `seasonEpisodes` 分页。
   ★ 季名用**服务器返回的 Name**,不拼「第 N 季」(真名是 "全 1 季" / "怪奇物语 4")。 */

const PAGE = 30;

/* ── 集列表的三种形态 ──
   ★ 一个按钮轮换三档,不是三个并排的按钮:这一行右边只有 34px,
     摆三个图标会把「剧集」两个字挤没。轮换的代价是"想直接跳到第三档要点两下",
     而三档里真正常用的是前两档,第三档是给几百集的剧用的。 */
type EpMode = "rail" | "grid" | "num";
const EP_MODE_NEXT: Record<EpMode, EpMode> = { rail: "grid", grid: "num", num: "rail" };
/* 图标画的是**当前**这一档,不是下一档 —— 上一版画下一档,于是用户看到网格图标
   却身处轨道形态,一按还以为按反了。要看下一档去读 aria-label / 长按提示。 */
const EP_MODE_ICON: Record<EpMode, string> = { rail: "list", grid: "grid", num: "sort" };
const EP_MODE_LABEL: Record<EpMode, string> = {
  rail: "横滑轨道",
  grid: "网格平铺",
  num: "只看集号",
};

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

export default function DetailPage({ itemId }: { itemId?: string }) {
  const { session, go, back, openItem, play } = useCtx();
  const [d, setD] = useState<ItemDetail | null>(() => (itemId ? peekItemDetailLite(itemId) ?? null : null));
  const [err, setErr] = useState("");
  const [ver, setVer] = useState<MediaVersion | null>(null);
  const [similar, setSimilar] = useState<Item[]>([]);
  const [fav, setFav] = useState(false);
  const [busy, setBusy] = useState("");
  const [sheet, setSheet] = useState<null | "more">(null);
  const [ovOpen, setOvOpen] = useState(false);
  /** 海报主色算出来的背景色。null = 还没算出来 / 这张海报是灰的 → 不画渐变 */
  const [wash, setWash] = useState<string | null>(null);

  /* 季 + 集 */
  const [seasons, setSeasons] = useState<SeasonInfo[]>([]);
  const [seasonIdx, setSeasonIdx] = useState(0);
  const [eps, setEps] = useState<Item[]>([]);
  const [epTotal, setEpTotal] = useState(0);
  /* 三种集列表形态,右上角那个按钮依次轮换(用户 2026-08-02 点名要把 num 这一档拿回来):
       rail = 横滑轨道(带剧照,默认)
       grid = 矩形网格平铺(带剧照,一次看全)
       num  = **只有矩形、没有封面**的横向条 —— 集数极多时唯一能快速定位的形态,
              一屏能扫十几格,而带图的形态一屏只有 2.5 张 */
  const [mode, setMode] = useState<EpMode>("rail");
  /** 用户挑的版本(PlaySetup 给);null = 没挑过 → 交给核层的版本筛选正则。
   *  ★ setter 必须是稳定引用:PlaySetup 内部拿它当 effect 依赖,
   *    每次 render 都换一个新函数的话那个 effect 会无限重跑。
   *    useState 的 setter 本身就是稳定的,所以直接传它,别再包一层箭头函数。 */
  const [pickedVer, setPickedVer] = useState<string | null>(null);

  const epBoxRef = useRef<HTMLDivElement>(null);

  const isSeries = d?.type_ === "Series";

  useEffect(() => {
    if (!itemId) return;
    let alive = true;
    setErr("");
    setWash(null);
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
        // 显示正则会挑中的那条(= 核层起播会挑的那条),不是列表第一条。
        setVer(defaultVersion(v));
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

  useEffect(() => {
    if (!epParent) return;
    let alive = true;
    setEps([]);
    setEpTotal(0);
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
  }, [epParent]);

  const loadMore = () => {
    if (!epParent || eps.length >= epTotal) return;
    seasonEpisodes(epParent, eps.length, PAGE)
      .then((p) => setEps((x) => [...x, ...p.items]))
      .catch(() => {});
  };

  useEffect(() => {
    choreograph(epBoxRef.current);
  }, [eps.length, mode]);

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

  /* ★ 播放按钮文案带上"剩余 xx 分"(Netflix/Prime 的做法):
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
      /* ★ 顶栏浮在海报之上、不占布局高度(用户 2026-08-02:「顶栏必须做成透明的」)。
         常规顶栏是 flex 流里的一格,它自己透明也没用 —— 背后露出的是 .pg 的不透明底色,
         看着仍然是一条深色横带压在海报上。 */
      floatBar
    >
      <div
        className={`detail${wash ? " washed" : ""}`}
        style={wash ? ({ ["--wash" as string]: wash } as React.CSSProperties) : undefined}
      >
        {/* ── 海报**当底图**,通栏铺到屏幕最顶,主色向下渐变收进主题色 ──
            用户 2026-08-02:「现在的封面效果很丑,不是直接贴一张海报上去就完事了。
            海报应该作为一个背景底图往下延伸,主色调自然地渐变过渡到黑色」。
            上一版是屏幕中间摆一张 260px 宽、带圆角和投影的卡片 —— 那是"贴了一张海报"。
            渐变的四段停在 mobile.css 的 `.dt-hero::after`,理由写在那里。 */}
        <div className="dt-hero">
          <img
            src={posterUrl(session, d.id, 900)}
            alt={d.name}
            decoding="async"
            /* ★ 这一对(crossOrigin + 后端的 Access-Control-Allow-Origin)是取主色的前提。
               少任何一半 canvas 就被污染,getImageData 抛 SecurityError 被 catch 吞掉 ——
               表现是"渐变永远不出现",一点报错都没有。 */
            crossOrigin="anonymous"
            onLoad={(e) => setWash(washColor(dominantOf(e.currentTarget)))}
            onError={(e) => ((e.target as HTMLImageElement).style.opacity = "0")}
          />
          <div className="dt-cap">
            <h1 className="dt-name">{d.name}</h1>
            {/* 年份 · 分级 · 状态 · 评分 · 季集数/时长 · 类型 */}
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
                      : `${epTotal || d.child_count || 0} 集`}
                  </span>
                ) : d.runtime_secs ? (
                  <span key="d">{fmtDur(d.runtime_secs)}</span>
                ) : null,
              ])}
            </div>
            {d.genres?.length ? <div className="dt-gen">{d.genres.join(" · ")}</div> : null}
          </div>
        </div>

        {/* ── 简介在播放按钮**上面**(用户 2026-08-01 定)──
            阅读顺序:标题/标签 → 简介 → 播放。
            ★ 标语实测只有 34% 的条目有 —— 没有就整行不画,不留空位。 */}
        <div className="dt-intro">
          {d.tagline ? <div className="dt-tag">{d.tagline}</div> : null}
          <div className={`dt-ov${ovOpen ? "" : " clamp"}`}>
            <div className="dt-ov-t">{ovText}</div>
            <button type="button" className="dt-ov-more" onClick={() => setOvOpen((v) => !v)}>
              {ovOpen ? "收起" : "更多"}
            </button>
          </div>
        </div>

        {/* ★ 播放按钮做通栏 —— 拇指区在下面,通栏是为了不用瞄准。
            ★ 这一排**没有「更多」** —— 顶栏右上角那个就是,两个一模一样的入口是冗余。 */}
        <div className="dt-acts">
          <PlayBtn
            label={playLabel}
            sub={playSub}
            disabled={!target}
            onClick={() => {
              if (!target) return;
              haptic("tap");
              void play(target, isSeries ? null : pickedVer);
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
        </div>

        {/* ── 播放前的四件事:版本 / 线路 / 音频 / 字幕 ──
            ★ 只在**电影**页画。剧集页真正要播的是某一集,它的流表挂在那一集上,
              所以那四个选择器长在**单集页**(见 EpisodePage) —— 在剧这一层选
              "第几条音轨"是没有意义的,不同集的轨表可以完全不同。 */}
        {!isSeries && <PlaySetup itemId={d.id} onVersion={setPickedVer} />}

        {isSeries && (
          /* ★ `.dt-eps` 不参与进场动画 —— 它里面是 sticky 的季条,祖先一旦带 transform
             sticky 会**静默失效**,进场那 400ms 季条会跟着一起滚走。 */
          <section className="dt-sec dt-eps">
            <div className="row-hd">
              <h2>剧集</h2>
              <button
                type="button"
                className="ep-mode"
                aria-label={`集列表:${EP_MODE_LABEL[mode]}(点一下换下一种)`}
                title={EP_MODE_LABEL[mode]}
                onClick={() => {
                  haptic("sel");
                  setMode((m) => EP_MODE_NEXT[m]);
                }}
              >
                <Icon n={EP_MODE_ICON[mode]} size={18} />
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

            <div className={`ep-box as-${mode}`} ref={epBoxRef}>
              {eps.map((e, i) => (
                <EpCard key={e.id} e={e} i={i % PAGE} session={session} onOpen={() => goEp(e)} />
              ))}
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
            {/* ★ 矩形头像(用户 2026-08-01):圆形会把脸裁掉,而且我们不缺这点展示空间。
                ★ 实测 18.6% 的人**没有头像**。破图不是"偶发",是每五个人里就有一个 ——
                  兜底 = 姓氏首字 + 该人的确定性底色,和有头像的一样大,不掉队。 */}
            <div className="row-scroll crew">
              {d.people.slice(0, 30).map((p) => (
                <button
                  type="button"
                  className="person"
                  key={p.id}
                  onClick={() => {
                    haptic("tap");
                    go({ page: "person", personId: p.id, title: p.name });
                  }}
                >
                  {p.has_primary ? (
                    <div className="person-av">
                      <img src={personUrl(session, p.id, 260)} alt="" loading="lazy" decoding="async" />
                    </div>
                  ) : (
                    <div className="person-av fb" style={{ background: hueOf(p.id) }}>
                      {p.name.slice(0, 1)}
                    </div>
                  )}
                  <div className="person-n">{p.name}</div>
                  {p.role ? <div className="person-r">{p.role}</div> : null}
                </button>
              ))}
            </div>
          </section>
        )}

        {/* ── 相似 ──
            ★ 剧集页**这里就是最后一节**:媒体信息整块拿掉(用户 2026-08-02:
              「剧集详情页下方不应该直接展示媒体信息,这部分内容应该用『更多相似剧集』代替」)。
              道理站得住:剧本身没有媒体流,那张卡显示的其实是"会播的那一集"的规格 ——
              一个既不属于这一页、又要多打一趟请求的东西。电影页则保留(它自己就是一个文件)。 */}
        {similar.length > 0 && (
          <section className="dt-sec">
            <Row
              title={isSeries ? "更多相似剧集" : "更多相似影片"}
              items={similar}
              session={session}
              onOpen={(x) => openItem(x)}
            />
          </section>
        )}

        {!isSeries && (
          /* 电影的媒体信息:平铺在最下面,不做点击展开(用户 2026-08-01 点名) */
          <section className="dt-sec">
            <div className="row-hd">
              <h2>媒体信息</h2>
            </div>
            <MediaCard ver={ver} />
          </section>
        )}

        <div style={{ height: 28 }} />
      </div>

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

/** 一集。**同一张卡在横滑轨道和网格平铺里是同一个组件** ——
 *  两种形态只差外层容器的 CSS,不该长出两套卡片(散着写必然长出两套间距)。 */
export function EpCard({
  e,
  i,
  session,
  cur,
  onOpen,
}: {
  e: Item;
  i: number;
  session: NonNullable<ReturnType<typeof useCtx>["session"]>;
  /** 就是当前正在看的这一集(单集页的「本季其它集」用) */
  cur?: boolean;
  onOpen: () => void;
}) {
  const [loaded, setLoaded] = useState(false);
  return (
    <button
      type="button"
      className={`epx${e.played ? " seen" : ""}${cur ? " cur" : ""}`}
      style={{ ["--i" as string]: i }}
      onClick={onOpen}
    >
      <div className="epx-th">
        {!loaded && <div className="skel" />}
        <img
          src={thumbUrl(session, e.id, 480)}
          alt=""
          loading="lazy"
          decoding="async"
          onLoad={(x) => {
            (x.target as HTMLImageElement).classList.add("ready");
            setLoaded(true);
          }}
          onError={(x) => {
            setLoaded(true);
            (x.target as HTMLImageElement).style.opacity = "0";
          }}
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
      <div className="epx-n">
        <b>{e.episode_no ?? ""}</b>
        {e.name}
      </div>
      <div className="epx-m">
        {[e.runtime_secs ? fmtDur(e.runtime_secs) : null, e.video_height ? fmtRes(e.video_height) : null]
          .filter(Boolean)
          .join(" · ")}
      </div>
    </button>
  );
}

/* ---------- 工具 ---------- */

/** 用 `<i class="mi-d">` 当分隔点插在各项之间。null 项直接跳过,不留空分隔。 */
function joinDots(nodes: (React.ReactNode | null)[]) {
  const xs = nodes.filter(Boolean);
  return xs.flatMap((n, i) => (i ? [<i className="mi-d" key={`d${i}`} />, n] : [n]));
}

/** 没头像时的兜底底色。确定性:同一个人每次都是同一个颜色。 */
export function hueOf(id: string) {
  let h = 0;
  for (let i = 0; i < id.length; i++) h = (h * 31 + id.charCodeAt(i)) >>> 0;
  return `hsl(${h % 360} 32% 26%)`;
}

