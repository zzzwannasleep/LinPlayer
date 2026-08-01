import { useEffect, useState } from "react";
import {
  type Item,
  type ItemDetail,
  type MediaVersion,
  defaultVersion,
  downloadEnqueue,
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
import { dominantOf, washColor } from "../app/color";
import { Icon } from "../app/icons";
import { haptic, toast } from "../app/motion";
import Page from "../components/Page";
import Sheet from "../components/Sheet";
import MediaCard from "../components/MediaCard";
import PlaySetup from "../components/PlaySetup";
import { Empty, Opt, usePress } from "../components/ui";
import { EpCard } from "./DetailPage";

/* 单集详情页 —— **独立一页**,不是弹窗。
   调研结论一致(NN/g + Netflix/Prime/Plex 做法):用弹窗会打断
   "从第 5 集跳到第 10 集"这个真实存在的流程,而且长简介在弹窗里堆不下。

   ★ 上一集/下一集走 `replace` 不是 `go` —— 那是**同一层**的横向移动。
     用 go 的话连按 5 次「下一集」就要按 5 次返回才回得到剧详情页,
     而用户心里的返回目标始终是那部剧。

   ═══ 2026-08-01 这一版改的四件事(用户逐条点名) ═══

   ★ **阅读顺序改成 标题/标签 → 简介 → 播放按钮。**

   ★ **「本季其它集」挪到播放按钮正下方**(原来在上一集/下一集之后)。

   ★ **「本季其它集」的封面根本不显示** —— 真因不是网络也不是接口,是
     `.card-a img` 在 CSS 里的初始状态就是 `opacity:0`,要靠 `onLoad` 加 `.ready`
     才淡入。这一页当初是**手抄了一份卡片 DOM**,抄漏了那个 onLoad,
     于是图下载完了、解码完了、就是永远透明。
     这一版直接复用剧集页那个 `EpCard`,不再各写一份 —— "散着写必然长出两套"
     在这里的具体后果就是一整栏封面全隐身。

   ★ **媒体信息改成平铺的卡片放在最下面**,不再是"点右上角更多 → 弹面板"。
     顺带解决了「右上角更多按钮点开的其实是媒体信息」这个名不副实的入口:
     现在右上角就是真的「更多」(标记已看 / 下载 / 回到剧)。

   ═══ 2026-08-02 这一版(用户逐条点名) ═══

   ★ **顶栏浮起来、不占布局高度**(`floatBar`)。剧照于是从屏幕最顶开始画,
     顶栏在首屏是真透明的,滚过一点才上玻璃底。

   ★ **换集不再重建这一页。** 用户原话:「点进第二集,整个页面感觉像被重新构建了一样,
     会发生跳动 —— 我在哪个位置点击,页面就应该停留在哪个位置」。
     根因在 app/router.ts 的 `replace`(它每次都发新 key,React 据此卸载重挂),
     已在那边修成"同种页面复用 key"。这边配套做两件事:
       1. 新数据没到之前**继续显示旧的**,不要塌成一行「加载中…」——
          页面一塌,scrollTop 会被浏览器截断到新的内容高度,那本身就是一次跳动;
       2. 用 `ready`(d.id === itemId)守住播放/下载这类写操作,
          否则那个窗口里点播放会播上一集。

   ★ **「上一集 / 下一集」整块删掉**(用户:「在这里没有任何用处」)——
     上面那条「本季其它集」轨道里就有相邻的集,而且能一次跨好几集。

   ★ **剧照做出播放器的样子**:玻璃播放键 + 剩余时长胶囊 + 进度条(见 mobile.css)。

   ★ **补上播放前的四件事**(版本 / 线路 / 音频 / 字幕,见 components/PlaySetup)。 */

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
  const { session, go, back, replace, play } = useCtx();
  const [d, setD] = useState<ItemDetail | null>(() => (itemId ? peekItemDetailLite(itemId) ?? null : null));
  const [err, setErr] = useState("");
  const [ver, setVer] = useState<MediaVersion | null>(null);
  const [more, setMore] = useState(false);
  /** 用户在 PlaySetup 里挑的版本;null = 没挑过 → 交给核层的版本筛选正则 */
  const [pickedVer, setPickedVer] = useState<string | null>(null);
  const [wash, setWash] = useState<string | null>(null);
  /** 邻集 + 本季其它集。null = 还没探;[] = 探过了但没命中 */
  const [near, setNear] = useState<{ prev: Item | null; next: Item | null; siblings: Item[] } | null>(null);

  useEffect(() => {
    if (!itemId) return;
    let alive = true;
    setErr("");
    setNear(null);
    setWash(null);
    setPickedVer(null);
    /* ★ **不清 `d`。** 换集时清掉的话这一页会先塌成一行「加载中…」,
       浏览器把 scrollTop 截到新的(极矮的)内容高度,等新数据回来再撑开 ——
       那一下就是用户说的"跳回最顶部"。留着旧的,新的到了原地替换。
       期间用 `ready` 守住写操作(见下面)。
       ★ 有缓存就先用缓存,那是零成本的即时替换。 */
    const cached = peekItemDetailLite(itemId);
    if (cached) setD(cached);
    itemDetailLite(itemId)
      .then((x) => alive && setD(x))
      .catch((e) => alive && setErr(String(e)));
    itemMedia(itemId)
      .then((v) => alive && setVer(defaultVersion(v)))
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
          seasonEpisodes(parent, Math.max(0, pos - 5), 14)
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
  /* 显示中的这一集,是不是路由要的那一集。换集的空窗里它是 false ——
     那时画的是**上一集**的内容,任何写操作(播放/标记/下载)都必须先停住。 */
  const ready = d.id === itemId;
  const left = Math.max(0, d.runtime_secs - d.resume_secs);

  return (
    <Page
      title={se}
      sub={d.series_name ?? undefined}
      onBack={back}
      right={
        <button type="button" ref={moreBtn} aria-label="更多" onClick={() => setMore(true)}>
          <Icon n="more" size={21} />
        </button>
      }
      enterKey={d.id}
      floatBar
    >
      <div
        className={`detail epd${wash ? " washed" : ""}`}
        style={wash ? ({ ["--wash" as string]: wash } as React.CSSProperties) : undefined}
      >
        {/* 单集的"封面"是这一集的**剧照**(16:9),不是剧的海报 ——
            三种详情页各用各的图,这正是用户要求"三个页面分开设计"的落点。 */}
        <div className="ep-hero">
          <img
            src={thumbUrl(session, d.id, 900)}
            alt=""
            decoding="async"
            crossOrigin="anonymous"
            onLoad={(e) => setWash(washColor(dominantOf(e.currentTarget)))}
            onError={(e) => ((e.target as HTMLImageElement).style.opacity = "0")}
          />
          <div className="dt-scrim" />
          {/* ★ 玻璃播放键 —— 用户 2026-08-02:「单集封面缺乏播放器的高级感」。
              一张 16:9 图配一条渐变,和列表里的缩略图除了尺寸没有任何区别,
              它没有说出"这是一块可以按下去的屏幕"。 */}
          <button
            type="button"
            className="ep-play"
            aria-label="播放"
            disabled={!ready}
            onClick={() => {
              if (!ready) return;
              haptic("tap");
              void play(self, pickedVer);
            }}
          >
            <Icon n="play" size={26} />
          </button>
          {d.runtime_secs > 0 && (
            <div className="ep-left">
              {d.resume_secs > 0 ? `剩余 ${Math.round(left / 60)} 分` : fmtDur(d.runtime_secs)}
            </div>
          )}
          {d.resume_secs > 0 && d.runtime_secs > 0 && (
            <div className="prog big">
              <i style={{ transform: `scaleX(${Math.min(1, d.resume_secs / d.runtime_secs)})` }} />
            </div>
          )}
        </div>

        {/* ① 标题 / 标签 */}
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
        </div>

        {/* ② 简介 —— 在播放按钮**上面**(用户 2026-08-01 定)。
            单集页的简介不截断:进到这一页来的人就是要看这个。 */}
        <div className="dt-intro">
          <div className={`dt-ov${d.overview ? "" : " dim"}`}>
            <div className="dt-ov-t">
              {d.overview || "这一集没有简介 —— 服务器的元数据里就是空的。实测约 9.5% 的分集是这样。"}
            </div>
          </div>
        </div>

        {/* ③ 播放前的四件事 —— 版本 / 线路 / 音频 / 字幕。
            ★ 放在播放按钮**上面**:用户 2026-08-02 原话是「有些片子字幕很多,
              用户需要先选好字幕再点击播放;线路和版本同理」。
              放下面的话阅读顺序就成了"先播了再说"。 */}
        <PlaySetup itemId={ready ? d.id : null} onVersion={setPickedVer} />

        {/* ④ 播放 */}
        <div className="dt-acts">
          <PlayBtn
            label={d.resume_secs ? "继续播放" : "播放"}
            sub={d.resume_secs ? `剩余 ${Math.round(left / 60)} 分` : null}
            disabled={!ready}
            onClick={() => {
              haptic("tap");
              void play(self, pickedVer);
            }}
          />
          <IcoBtn
            icon="check"
            label="标记已看"
            disabled={!ready}
            onClick={() => {
              haptic("ok");
              setPlayed(d.id, true).then(() => toast("已标为看完", "ok")).catch((e) => toast(String(e), "bad"));
            }}
          />
          <IcoBtn
            icon="download"
            label="下载"
            disabled={!ready}
            onClick={() => {
              haptic("tap");
              downloadEnqueue(d.id, d.type_, d.name, "mkv", posterUrl(session, d.id, 360))
                .then(() => toast("已加入下载队列"))
                .catch((e) => toast(String(e), "bad"));
            }}
          />
        </div>

        {/* ⑤ 本季其它集 —— 紧跟播放按钮(用户 2026-08-01 定)。
            卡片复用剧集页的 EpCard:上一版这里手抄了一份 DOM 却抄漏了 onLoad 里那句
            `classList.add("ready")`,而 `.card-a img` 的初始状态就是 opacity:0 ——
            于是整栏封面永远透明。别再各写一份。 */}
        {near && near.siblings.length > 1 && (
          <section className="dt-sec">
            <div className="row-hd">
              <h2>本季其它集</h2>
              <button type="button" className="row-more" onClick={back}>
                全部
                <Icon n="chevR" size={15} />
              </button>
            </div>
            <div className="ep-box as-rail">
              {near.siblings.map((x, i) => (
                <EpCard key={x.id} e={x} i={i} session={session} cur={x.id === d.id} onOpen={jump(x)} />
              ))}
            </div>
          </section>
        )}

        {/* ⑥ 媒体信息卡 —— **最下面**,平铺,不点击展开(用户 2026-08-01 定) */}
        <section className="dt-sec">
          <div className="row-hd">
            <h2>媒体信息</h2>
          </div>
          <MediaCard ver={ver} />
        </section>

        <div style={{ height: 28 }} />
      </div>

      <Sheet open={more} onClose={() => setMore(false)} title={d.name}>
        <div className="opts">
          <Opt
            label="标为已看"
            i={0}
            onClick={() => {
              setMore(false);
              setPlayed(d.id, true).then(() => toast("已标为看完", "ok")).catch((e) => toast(String(e), "bad"));
            }}
          />
          <Opt
            label="标为未看"
            i={1}
            onClick={() => {
              setMore(false);
              setPlayed(d.id, false).then(() => toast("已标为未看", "ok")).catch((e) => toast(String(e), "bad"));
            }}
          />
          <Opt
            label="下载这一集"
            i={2}
            onClick={() => {
              setMore(false);
              downloadEnqueue(d.id, d.type_, d.name, "mkv", posterUrl(session, d.id, 360))
                .then(() => toast("已加入下载队列"))
                .catch((e) => toast(String(e), "bad"));
            }}
          />
          {d.series_id ? (
            <Opt
              label="回到这部剧"
              i={3}
              onClick={() => {
                setMore(false);
                go({ page: "detail", itemId: d.series_id!, title: d.series_name ?? "" });
              }}
            />
          ) : null}
        </div>
      </Sheet>
    </Page>
  );
}

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
  disabled,
  onClick,
}: {
  icon: string;
  label: string;
  disabled?: boolean;
  onClick: () => void;
}) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button
      type="button"
      className="btn dt-ico"
      aria-label={label}
      ref={ref}
      disabled={disabled}
      onClick={onClick}
    >
      <Icon n={icon} size={19} />
    </button>
  );
}
