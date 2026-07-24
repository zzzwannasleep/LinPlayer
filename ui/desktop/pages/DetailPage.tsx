import { useEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import {
  type AccountInfo,
  type Item,
  type ItemDetail,
  type LineProbe,
  type LoginResult,
  type MediaVersion,
  type Prefs,
  type StreamInfo,
  backdropUrl,
  downloadEnqueue,
  fmtBitrate,
  fmtRes,
  fmtSize,
  fmtTime,
  getPrefs,
  itemDetail,
  peekItemDetail,
  similarItems,
  itemMedia,
  listAccounts,
  personUrl,
  posterUrl,
  probeLines,
  setActiveLine,
  setFavorite,
  setPlayed,
  setPrefs,
  thumbUrl,
} from "@shared/api";
import {
  IconCheck,
  IconChevronDown,
  IconChevronLeft,
  IconChevronRight,
  IconDownload,
  IconHeart,
  IconInfo,
  IconList,
  IconPlay,
} from "../app/icons";
import Poster from "../components/Poster";
import "./DetailPage.css";

type Props = {
  session: LoginResult;
  item: Item;
  /** 第二参 = 版本选择器选中的 MediaSource id,已一路透传到核层 play()(Shell → App.playItem)。
      注意 TS 上少参函数可赋给多参形参 —— 这条链断了编译期也不报错,只会静默放默认版本,
      所以别把 Shell/App 那两处的第二参「顺手简化掉」。 */
  onPlay: (it: Item, mediaSourceId?: string | null) => void;
  onOpenChild: (it: Item) => void;
  onBack: () => void;
  /** 切线路后必须回调:核层只改自己那份会话,前端 session.server 不刷新的话,
      poster/backdrop 等 URL 会继续打刚被判死的那条线。 */
  onSessionChange: () => void;
};

/** 哪个下拉是打开态(同一时刻只开一个)。 */
type DdKind = "line" | "ver" | "audio" | "sub" | "season" | null;

function toItem(d: ItemDetail): Item {
  return {
    id: d.id,
    name: d.name,
    type_: d.type_,
    is_folder: false,
    has_primary: d.has_primary,
    runtime_secs: d.runtime_secs,
    resume_secs: d.resume_secs,
    series_name: d.series_name,
    episode_no: d.episode_no,
    season_no: d.season_no,
    video_height: null,
    bitrate: null,
    size_bytes: null,
    // ItemDetail 有的照搬,没有的给中性值(这条 Item 只用于起播/收藏,不参与列表排序)。
    played: false,
    unplayed_item_count: 0,
    genres: d.genres,
    year: d.year,
    rating: d.rating,
    provider_ids: {},
    presentation_unique_key: null,
    path: null,
    series_id: d.series_id,
    // 详情接口不带这两项(只有列表接口的 Fields 才要);收藏页排序不经过这里。
    date_updated: null,
    sort_name: null,
  };
}

/** 音轨/字幕的一行文字:服务端给了 display_title 就用它,否则自己拼。 */
function streamLabel(s: StreamInfo): string {
  if (s.display_title) return s.display_title;
  const parts =
    s.type_ === "Subtitle"
      ? [s.codec.toUpperCase(), s.language]
      : [s.codec.toUpperCase(), s.channel_layout ?? (s.channels ? `${s.channels}ch` : null), s.language];
  return parts.filter(Boolean).join(" · ") || `轨道 ${s.index}`;
}

/** 媒体信息卡的一行:没值就整行不渲染(草稿要求不出空行/undefined)。 */
function KV({ k, v }: { k: string; v: string | null | undefined }) {
  if (!v) return null;
  return (
    <div className="dt-kv">
      <span className="k">{k}</span>
      <span className="val">{v}</span>
    </div>
  );
}

/** 一张纵向流卡片(草稿 .mi;本项目改名 .dt-mi 避开 ui.css 里的右键菜单项 .mi)。 */
function MiCard({ cap, tag, children }: { cap: string; tag?: boolean; children: React.ReactNode }) {
  return (
    <div className="dt-mi">
      <div className="cap">
        {cap}
        {tag && <span className="tag">默认</span>}
      </div>
      {children}
    </div>
  );
}

export default function DetailPage({ session, item, onPlay, onOpenChild, onBack, onSessionChange }: Props) {
  const [d, setD] = useState<ItemDetail | null>(null);
  const [err, setErr] = useState("");
  const [fav, setFav] = useState(false);
  // ItemDetail 没有 played 字段,只有 Item 有 → 已看态从 item 起,标记后本地跟。
  const [played, setPlayedLocal] = useState(item.played);
  const [expand, setExpand] = useState(false);
  const [toast, setToast] = useState("");

  // 线路:属服务器(账号)不属条目 → 从活跃账号取。probes 按需(开下拉才测)。
  const [acct, setAcct] = useState<AccountInfo | null>(null);
  const [probes, setProbes] = useState<LineProbe[] | null>(null);
  const [probing, setProbing] = useState(false);
  // 选轨偏好:set_prefs 三项一起写,必须先有当前值才能只改一项(见 patchPrefs)。
  const [prefs, setPrefsLocal] = useState<Prefs | null>(null);

  const [versions, setVersions] = useState<MediaVersion[]>([]);
  const [verIdx, setVerIdx] = useState(0);
  const [audioIdx, setAudioIdx] = useState<number | null>(null);
  const [subIdx, setSubIdx] = useState<number | null>(null);
  const [dd, setDd] = useState<DdKind>(null);

  const [season, setSeason] = useState<number | null>(null);
  const [epView, setEpView] = useState<"grid" | "list">("grid");
  const [epCtx, setEpCtx] = useState<{ x: number; y: number; ep: Item } | null>(null);
  const [moreMenu, setMoreMenu] = useState<{ x: number; y: number } | null>(null);

  const railRef = useRef<HTMLDivElement | null>(null);

  /** 相似推荐(剧集/电影页底部)。null=没请求/加载中,[]=确实没有 → 整段不渲染。 */
  const [similar, setSimilar] = useState<Item[] | null>(null);

  const isSeries = (d?.type_ ?? item.type_) === "Series";
  const isEpisode = (d?.type_ ?? item.type_) === "Episode";

  // 详情 + 媒体信息并行发起:媒体信息只有 Movie/Episode 有(Series 自己没有 MediaSource)。
  // 媒体信息失败静默(整段不渲染),不能把整页搞红。
  useEffect(() => {
    let alive = true;
    /* ★ 有缓存就先把它画出来,别先 setD(null)。
       原来无条件清空 = 每次进详情页必然闪一下转圈,哪怕数据 3 秒前才拿过。
       itemDetail 命中缓存时是同步返回的,下面那个 .then 会立刻把它补齐 ——
       这里 peek 只是为了**这一帧**就有内容,不留白。 */
    setD(peekItemDetail(item.id) ?? null);
    setErr("");
    setExpand(false);
    setPlayedLocal(item.played);
    setVersions([]);
    setVerIdx(0);
    setAudioIdx(null);
    setSubIdx(null);
    setDd(null);
    setProbes(null);
    setSeason(null);
    setEpCtx(null);
    setMoreMenu(null);
    setSimilar(null);

    /* 相似推荐:**只给剧集/电影**(用户 2026-07-15:集详情页不要)。和详情**并发**,
       不串在 itemDetail 后面 —— 它慢不该拖累主内容出现,失败也静默(整段不渲染)。 */
    if (item.type_ === "Series" || item.type_ === "Movie") {
      similarItems(item.id)
        .then((s) => alive && setSimilar(s))
        .catch(() => alive && setSimilar([]));
    }

    itemDetail(item.id)
      .then((x) => {
        if (!alive) return;
        setD(x);
        setFav(x.is_favorite);
      })
      .catch((e) => alive && setErr(String(e)));

    // 线路清单的来源。失败不能静默 —— 否则线路选择器凭空消失,没人知道为什么。
    listAccounts()
      .then((as) => alive && setAcct(as.find((a) => a.active) ?? null))
      .catch((e) => alive && setToast(`读取服务器线路失败:${e}`));

    // 音轨/字幕偏好的基线(patchPrefs 要在它之上改单项)。
    getPrefs()
      .then((p) => alive && setPrefsLocal(p))
      .catch(() => {});

    if (item.type_ !== "Series") {
      itemMedia(item.id)
        .then((v) => alive && setVersions(v))
        .catch(() => {});
    }
    return () => {
      alive = false;
    };
  }, [item.id, item.type_]);

  const ver = versions[verIdx] ?? null;
  const audios = useMemo(() => ver?.streams.filter((s) => s.type_ === "Audio") ?? [], [ver]);
  const subs = useMemo(() => ver?.streams.filter((s) => s.type_ === "Subtitle") ?? [], [ver]);

  // 换版本 → 音轨/字幕回到该版本的默认轨。
  useEffect(() => {
    setAudioIdx(audios.find((s) => s.is_default)?.index ?? audios[0]?.index ?? null);
    setSubIdx(subs.find((s) => s.is_default)?.index ?? null);
  }, [audios, subs]);

  // 下拉/菜单:点外面、滚动、Esc 关(同 NetdiskPage 右键菜单套路)。
  useEffect(() => {
    if (!dd && !epCtx && !moreMenu) return;
    const close = () => {
      setDd(null);
      setEpCtx(null);
      setMoreMenu(null);
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && close();
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
      window.removeEventListener("keydown", onKey);
    };
  }, [dd, epCtx, moreMenu]);

  useEffect(() => {
    if (!toast) return;
    const t = window.setTimeout(() => setToast(""), 2000);
    return () => clearTimeout(t);
  }, [toast]);

  const bgId = d?.series_id ?? item.id;
  const episodes = d?.children ?? []; // children 已按季+集号排序。

  const seasons = useMemo(() => {
    const set = new Set<number>();
    for (const e of episodes) if (e.season_no != null) set.add(e.season_no);
    return [...set].sort((a, b) => a - b);
  }, [episodes]);

  const curSeason = season ?? seasons[0] ?? null;
  const shownEps = curSeason == null ? episodes : episodes.filter((e) => e.season_no === curSeason);

  async function toggleFav() {
    const next = !fav;
    setFav(next);
    try {
      await setFavorite(item.id, next);
    } catch {
      setFav(!next);
    }
  }

  /* ---------- 线路(标注 14) ----------
     ★ 传给 probe_lines / set_active_line 的 server_id 是**账号键**(Account.server,
     即 AccountInfo.server),**不是** session.server:set_active_line 会把活跃会话的
     session.server 改写成所选线路的 URL,切过一次后两者就不相等了,再拿 session.server
     当键去 cfg.find() 必然「找不到该服务器」。核层实测见 lib.rs:619-634 / 866-875。 */
  const lines = acct?.lines ?? [];
  const activeLine = acct?.active_line ?? 0;
  const lineName = (i: number) => lines[i]?.name || `线路 ${i + 1}`;

  /** 开线路下拉时才测速:进详情页就并发探 N 条线是白花的流量。 */
  function openLineDd() {
    const next = dd === "line" ? null : "line";
    setDd(next);
    if (next !== "line" || !acct || probing) return;
    setProbing(true);
    probeLines(acct.server)
      .then(setProbes)
      .catch((e) => setToast(`线路测速失败:${e}`))
      .finally(() => setProbing(false));
  }

  async function pickLine(i: number) {
    setDd(null);
    if (!acct || i === activeLine) return;
    try {
      await setActiveLine(acct.server, i);
      setAcct({ ...acct, active_line: i });
      /* 核层改的是它自己那份会话;前端这份 session.server 还是旧线路,而剧照/海报 URL
         都是拿它现拼的 —— 不刷新的话,用户正因旧线不通才切线路,切完图片继续打死线。 */
      onSessionChange();
      setToast(`已切到 ${lineName(i)}`);
    } catch (e) {
      setToast(`切换线路失败:${e}`);
    }
  }

  /* ---------- 音轨/字幕偏好(标注 14) ----------
     核层 play() 不收轨道参数,起播后由 App 的 afterStart → apply_prefs() 按**语言**选轨
     (pick_tracks/match_lang:拿 prefs 的 lang 去 contains 匹配 track 的 lang/title)。
     所以详情页「选音轨/字幕」的正确落点是写偏好,而不是当场 set_track(此刻还没起播)。 */

  /** set_prefs 是三项一起覆写:不带上当前值就会把另两项悄悄清成 null
      —— 选个音轨顺手把用户的字幕语言偏好抹了,且两头都不报错。故先取基线再改单项。 */
  async function patchPrefs(patch: Partial<Prefs>) {
    try {
      const base = prefs ?? (await getPrefs());
      const next = { ...base, ...patch };
      setPrefsLocal(next);
      await setPrefs(next);
    } catch (e) {
      setToast(`偏好保存失败:${e}`);
    }
  }

  /** 偏好只认语言。没有语言标记的轨道无法表达成偏好 → 明说,不假装选上了。 */
  function pickStream(s: StreamInfo, kind: "audio" | "sub") {
    if (kind === "audio") setAudioIdx(s.index);
    else setSubIdx(s.index);
    setDd(null);
    if (!s.language) {
      setToast(`该${kind === "audio" ? "音轨" : "字幕"}没有语言标记,选择无法记入偏好,起播仍用默认轨`);
      return;
    }
    patchPrefs(kind === "audio" ? { audio_lang: s.language } : { sub_lang: s.language, sub_enabled: true });
  }

  /* ---------- 标记已看/未看(标注 13 / 16) ---------- */
  async function markPlayed(id: string, next: boolean) {
    setMoreMenu(null);
    setEpCtx(null);
    try {
      await setPlayed(id, next);
      if (id === item.id) setPlayedLocal(next);
      // 分集的已看态藏在 d.children[].played 里 → 重取详情才反显得出来。
      setD(await itemDetail(item.id));
      setToast(next ? "已标记已看" : "已标记未看");
    } catch (e) {
      setToast(`标记失败:${e}`);
    }
  }

  /** 播放/续播目标:剧集挑第一条有进度的,否则第一集;电影/单集就是自己。 */
  const target: Item | null = (() => {
    if (isSeries) return episodes.find((c) => c.resume_secs > 0) ?? episodes[0] ?? null;
    return d ? toItem(d) : null;
  })();

  const resumeTarget = target && target.resume_secs > 0 ? target : null;
  const playLabel = (() => {
    if (!resumeTarget) return "播放";
    const se =
      resumeTarget.season_no != null && resumeTarget.episode_no != null
        ? ` · S${resumeTarget.season_no}E${resumeTarget.episode_no}`
        : "";
    const left =
      resumeTarget.runtime_secs > 0
        ? ` · 剩余 ${fmtTime(Math.max(0, resumeTarget.runtime_secs - resumeTarget.resume_secs))}`
        : "";
    return `继续观看${se}${left}`;
  })();

  const title = isEpisode && d?.series_name ? d.series_name : d?.name ?? item.name;

  const enqueueOne = (it: { id: string; type_: string; name: string }) =>
    downloadEnqueue(it.id, it.type_, it.name, "mkv", posterUrl(session, it.id));

  function enqueue(it: { id: string; type_: string; name: string }) {
    enqueueOne(it)
      .then(() => setToast("已加入下载"))
      .catch((e) => setToast(`下载失败:${e}`));
  }

  /** 下载整季(标注 13):当前季的每一集入队。
      ponytail: 串行入队 —— 入队本身只是写队列记录,真正的并发由下载引擎(download_set_threads)管;
      这里并发发 24 个 invoke 只会给核层添堵。单集失败不中断其余,最后统一报数。 */
  async function enqueueSeason() {
    if (shownEps.length === 0) return;
    setToast(`正在加入 ${shownEps.length} 集…`);
    let ok = 0;
    let firstErr = "";
    for (const ep of shownEps) {
      try {
        await enqueueOne(ep);
        ok++;
      } catch (e) {
        if (!firstErr) firstErr = String(e);
      }
    }
    const failed = shownEps.length - ok;
    setToast(failed === 0 ? `已加入 ${ok} 集下载` : `已加入 ${ok}/${shownEps.length} 集,${failed} 集失败:${firstErr}`);
  }

  /** 媒体信息卡片区左右拖动横滑(标注 20:和 Emby 官端一致)。 */
  function dragScroll(e: React.MouseEvent<HTMLDivElement>) {
    if (e.button !== 0) return;
    const el = e.currentTarget;
    const startX = e.clientX;
    const startLeft = el.scrollLeft;
    el.classList.add("grabbing");
    const move = (ev: MouseEvent) => {
      el.scrollLeft = startLeft - (ev.clientX - startX);
      ev.preventDefault();
    };
    const up = () => {
      el.classList.remove("grabbing");
      window.removeEventListener("mousemove", move);
      window.removeEventListener("mouseup", up);
    };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  }

  const chev = <IconChevronDown size={12} />;

  return (
    <>
      {/* 面包屑(标注 12)已按用户 2026-07-16 移除:「页面上面显示路径的地方…没啥作用又丑,
          且颜色和米黄底冲突」。返回走 Hero 里的玻璃 ‹ 按钮(dt-hero-back,onBack 仍在用)。 */}
      <div className="scroll detail">
      <div className="cbody" style={{ paddingTop: 0 }}>
        {/* ① Hero:全宽出血,不受正文 max-width 约束。
            集详情加 .ep:内容底对齐 + 简介进右侧宽区(见下),整块更紧凑贴近播放键。 */}
        <div className={`dt-hero${isEpisode ? " ep" : ""}`}>
          {/* 背景走 Backdrop(剧集/电影覆盖率 100%/92%,分集用 SeriesId 的 —— 见 bgId)。
              ★ 取不到就露出 .dt-hero 的纯色底(--panel-2),**不再回落 poster** ——
              海报现在是左边那张独立封面,背景再放一张海报就重复了。这就是决定「不提供就纯色」。 */}
          <img
            className="dt-hero-bg"
            src={backdropUrl(session, bgId)}
            onError={(e) => ((e.target as HTMLImageElement).style.opacity = "0")}
          />
          <div className="dt-hero-grad" />
          <button className="dt-hero-back" onClick={onBack} title="返回">
            <IconChevronLeft size={17} />
          </button>
          <div className="dt-hero-actions">
            <button className={`dt-ghost sm${fav ? " on" : ""}`} onClick={toggleFav} title="收藏">
              <IconHeart size={16} />
            </button>
            <button
              className="dt-ghost sm"
              title={isSeries ? "下载整季" : "下载"}
              disabled={isSeries ? shownEps.length === 0 : !d}
              onClick={() => (isSeries ? enqueueSeason() : d && enqueue(d))}
            >
              <IconDownload size={16} />
            </button>
            <button
              className="dt-ghost sm"
              title="更多"
              onClick={(e) => {
                e.stopPropagation();
                const r = e.currentTarget.getBoundingClientRect();
                setMoreMenu({ x: Math.max(8, r.right - 176), y: r.bottom + 6 });
              }}
            >
              <span className="dt-dots">
                <i />
                <i />
                <i />
              </span>
            </button>
          </div>
          {/* ★ 左侧独立封面 + 右侧信息(用户 2026-07-15 定,草稿已过审)。
              封面完整显示不裁不缩:剧集/电影用竖版 2:3,集详情用横版剧照 16:9。
              背景该裁就裁(object-fit:cover),封面不动 —— 这就是「不想裁封面,大可背景不用封面」。 */}
          <div className="dt-hero-inner">
            {/* 左列 = 封面 +(仅集详情)封面下方的简介。
                集详情的封面是 16:9,比 Hero 矮一大截,下方本来空一大块 —— 用户 2026-07-15:
                「封面下方有很宽的间隔 把它去掉 然后把集简介加进去 适当有一点间隔就行」。
                所以集详情的简介搬到这里(封面正下方,小间距),正文区那份 ③ 简介对 Episode 隐藏,不重复。 */}
            <div className="dt-hero-left">
              <div className={`dt-hero-cover ${isEpisode ? "wide" : ""}`}>
                {/* 集详情用分集自己的横版剧照(Primary,实测 22/22 有);剧集/电影用竖版海报。 */}
                <img
                  src={isEpisode ? thumbUrl(session, item.id, 480) : posterUrl(session, item.id, 480)}
                  alt={title}
                  onError={(e) => ((e.target as HTMLImageElement).style.visibility = "hidden")}
                />
              </div>
            </div>
            <div className="dt-hero-body">
              {isEpisode && d?.episode_no != null && (
                <div className="dt-hero-eyebrow">
                  第 {d.episode_no} 集{d.name ? ` · ${d.name}` : ""}
                </div>
              )}
              <div className="dt-hero-title">{title}</div>
              <div className="chipbar dt-hero-chips">
                {d?.rating != null && <span className="genre">★ {d.rating.toFixed(1)}</span>}
                {d?.year != null && <span className="genre">{d.year}</span>}
                {d?.genres.slice(0, 3).map((g) => (
                  <span className="genre" key={g}>
                    {g}
                  </span>
                ))}
                {isSeries && episodes.length > 0 && <span className="genre">{episodes.length} 集</span>}
              </div>
              {/* 集简介搬到这块宽区(用户 2026-07-16:「简介不长,有可用位置就用,不要叠多行」)。
                  在右侧宽区里短简介 1~2 行就放下,不再挤在窄封面下叠 4 行;正文区 ③ 简介对 Episode 仍隐藏,不重复。 */}
              {isEpisode && d?.overview && (
                <p className="dt-hero-epsyn">{d.overview}</p>
              )}
            </div>
          </div>
        </div>

        {/* 正文封顶:4K 全屏下不把内容拉成一条线、右边不死白 */}
        <div className="dt-body">
          {/* ② 大播放按钮 */}
          <div className="dt-playbar">
            {/* 版本选择器选中的 MediaSource 一并交给起播方(剧集起播的是分集,版本选择器不适用 → null)。
                ⚠️ 现阶段 App.playItem 只收第一参,这个 id 会被丢掉 —— 详见 Props.onPlay 的注释。 */}
            {(!isSeries || episodes.length > 0) && (
              <button
                className="btn primary big"
                onClick={() => target && onPlay(target, isSeries ? null : ver?.id ?? null)}
                disabled={!target}
              >
                <IconPlay size={16} /> {playLabel}
              </button>
            )}
            <button className={`dt-ghost${fav ? " on" : ""}`} onClick={toggleFav} title="收藏">
              <IconHeart size={17} />
            </button>
            <button
              className="dt-ghost"
              title={isSeries ? "下载整季" : "下载"}
              disabled={isSeries ? shownEps.length === 0 : !d}
              onClick={() => (isSeries ? enqueueSeason() : d && enqueue(d))}
            >
              <IconDownload size={17} />
            </button>
            <button
              className="dt-ghost"
              title="更多"
              onClick={(e) => {
                e.stopPropagation();
                const r = e.currentTarget.getBoundingClientRect();
                setMoreMenu({ x: Math.max(8, r.left), y: r.bottom + 6 });
              }}
            >
              <span className="dt-dots">
                <i />
                <i />
                <i />
              </span>
            </button>
          </div>

          {err && <div className="empty">加载失败：{err}</div>}

          {/* ③ 简介。集详情的简介已挪到 Hero 里封面正下方(见 dt-hero-left),这里对 Episode 隐藏,不重复。 */}
          {!isEpisode && d?.overview && (
            <>
              <div className="rowlab" style={{ margin: "20px 0 10px" }}>
                <span className="h">简介</span>
              </div>
              <p className={`dt-overview${expand ? "" : " clamp"}`}>{d.overview}</p>
              {d.overview.length > 120 && (
                <button className="dt-expand" onClick={() => setExpand((v) => !v)}>
                  {expand ? "收起" : "展开"} {chev}
                </button>
              )}
            </>
          )}

          {/* ④ 选择器:线路 / 版本 / 音轨 / 字幕。
              线路属服务器(剧集页也该有),版本/音轨/字幕要 MediaSource(Series 没有)→ 两段各自把门。 */}
          {(lines.length > 1 || (!isSeries && versions.length > 0)) && (
            <div className="dt-selrow" style={{ marginTop: 16 }}>
              {/* 线路:真接 probe_lines / set_active_line(核层 lib.rs:619,866 —— 一直都在)。
                  只有一条线时整个不显示:草稿 979「没有就不显示、不硬凑」,没得选的下拉是摆设。 */}
              {lines.length > 1 && (
                <span className="dt-selwrap" onClick={(e) => e.stopPropagation()}>
                  <span className={`sel${dd === "line" ? " on" : ""}`} onClick={openLineDd}>
                    线路 · {lineName(activeLine)} {chev}
                  </span>
                  {dd === "line" && (
                    <div className="dd">
                      {lines.map((l, i) => {
                        const p = probes?.find((x) => x.index === i);
                        return (
                          <div
                            key={l.id}
                            className={`li${i === activeLine ? " on" : ""}`}
                            title={l.remark ?? undefined}
                            onClick={() => pickLine(i)}
                          >
                            <span className="rad" />
                            {lineName(i)}
                            {/* ms=null 是「探过,不通」,和「还没探」不同义 → 前者「—」,后者留空。 */}
                            <span className="rt" title={p && p.ms == null ? "不通" : undefined}>
                              {probing && !probes ? "测速中…" : p ? (p.ms == null ? "—" : `${p.ms} ms`) : ""}
                            </span>
                          </div>
                        );
                      })}
                    </div>
                  )}
                </span>
              )}

              {!isSeries && versions.length > 0 && (
                <>
                {/* 版本:真数据。>1 个版本时按草稿 776 行用 accent 边框标当前生效项 */}
                <span className="dt-selwrap" onClick={(e) => e.stopPropagation()}>
                  <span
                    className={`sel${dd === "ver" ? " on" : ""}`}
                    style={versions.length > 1 ? { borderColor: "var(--accent)", color: "var(--ink)" } : undefined}
                    onClick={() => setDd(dd === "ver" ? null : "ver")}
                  >
                    版本 · {ver?.name ?? "—"} {chev}
                  </span>
                  {dd === "ver" && (
                    <div className="dd">
                      {versions.map((v, i) => (
                        <div
                          key={v.id}
                          className={`li${i === verIdx ? " on" : ""}`}
                          onClick={() => {
                            setVerIdx(i);
                            setDd(null);
                          }}
                        >
                          <span className="rad" />
                          {v.name}
                          <span className="rt">{fmtSize(v.size_bytes)}</span>
                        </div>
                      ))}
                    </div>
                  )}
                </span>

                {/* 音轨:选中版本的 Audio 流 */}
                {audios.length > 0 && (
                  <span className="dt-selwrap" onClick={(e) => e.stopPropagation()}>
                    <span
                      className={`sel${dd === "audio" ? " on" : ""}`}
                      onClick={() => setDd(dd === "audio" ? null : "audio")}
                    >
                      音轨 · {audios.find((s) => s.index === audioIdx) ? streamLabel(audios.find((s) => s.index === audioIdx)!) : "—"} {chev}
                    </span>
                    {dd === "audio" && (
                      <div className="dd">
                        {audios.map((s) => (
                          <div
                            key={s.index}
                            className={`li${s.index === audioIdx ? " on" : ""}`}
                            onClick={() => pickStream(s, "audio")}
                          >
                            <span className="rad" />
                            {streamLabel(s)}
                            {fmtBitrate(s.bitrate) && <span className="rt">{fmtBitrate(s.bitrate)}</span>}
                          </div>
                        ))}
                      </div>
                    )}
                  </span>
                )}

                {/* 字幕:选中版本的 Subtitle 流 + 关闭字幕 */}
                <span className="dt-selwrap" onClick={(e) => e.stopPropagation()}>
                  <span className={`sel${dd === "sub" ? " on" : ""}`} onClick={() => setDd(dd === "sub" ? null : "sub")}>
                    {/* 换版本时本帧 subIdx 可能还是旧版本的 → 查不到就按「关闭」显示,等 effect 校正 */}
                    字幕 · {subs.find((s) => s.index === subIdx) ? streamLabel(subs.find((s) => s.index === subIdx)!) : "关闭"} {chev}
                  </span>
                  {dd === "sub" && (
                    <div className="dd">
                      {subs.map((s) => (
                        <div
                          key={s.index}
                          className={`li${s.index === subIdx ? " on" : ""}`}
                          onClick={() => pickStream(s, "sub")}
                        >
                          <span className="rad" />
                          {streamLabel(s)}
                        </div>
                      ))}
                      <div
                        className={`li${subIdx == null ? " on" : ""}`}
                        onClick={() => {
                          setSubIdx(null);
                          setDd(null);
                          // 关字幕能直接表达成偏好(sub_enabled=false → pick_tracks 返回 "no"),无需语言。
                          patchPrefs({ sub_enabled: false });
                        }}
                      >
                        <span className="rad" />
                        关闭字幕
                      </div>
                    </div>
                  )}
                </span>
                </>
              )}
            </div>
          )}

          {/* ⑤ 分集:季用下拉切换(标注 15),右侧网格/列表切换 */}
          {isSeries && episodes.length > 0 && (
            <>
              <div className="rowlab" style={{ margin: "24px 0 10px" }}>
                <span className="h">分集</span>
                {seasons.length > 1 && (
                  <span className="dt-selwrap" style={{ marginLeft: 4 }} onClick={(e) => e.stopPropagation()}>
                    <span
                      className={`sel${dd === "season" ? " on" : ""}`}
                      onClick={() => setDd(dd === "season" ? null : "season")}
                    >
                      第 {curSeason} 季 {chev}
                    </span>
                    {dd === "season" && (
                      <div className="dd">
                        {seasons.map((s) => (
                          <div
                            key={s}
                            className={`li${s === curSeason ? " on" : ""}`}
                            onClick={() => {
                              setSeason(s);
                              setDd(null);
                            }}
                          >
                            <span className="rad" />第 {s} 季
                            <span className="rt">{episodes.filter((e) => e.season_no === s).length} 集</span>
                          </div>
                        ))}
                      </div>
                    )}
                  </span>
                )}
                <span className="all dt-viewtoggle">
                  <button
                    className={epView === "grid" ? "on" : ""}
                    title="网格"
                    onClick={() => setEpView("grid")}
                  >
                    <span className="dt-gridic">
                      <i />
                      <i />
                      <i />
                      <i />
                    </span>
                  </button>
                  <button className={epView === "list" ? "on" : ""} title="列表" onClick={() => setEpView("list")}>
                    <IconList size={14} />
                  </button>
                </span>
              </div>
              <div className={`dt-epgrid${epView === "list" ? " list" : ""}`}>
                {shownEps.map((ep) => {
                  const prog =
                    ep.resume_secs > 0 && ep.runtime_secs > 0
                      ? Math.min(100, (ep.resume_secs / ep.runtime_secs) * 100)
                      : 0;
                  // 标注 16:分集卡一行 mono 小字「2160p · 45M · 18.4G」,缺项跳过。
                  const meta = [fmtRes(ep.video_height), fmtBitrate(ep.bitrate), fmtSize(ep.size_bytes)]
                    .filter(Boolean)
                    .join(" · ");
                  return (
                    <div
                      className="dt-ep"
                      key={ep.id}
                      /* 单击进集详情。★ 这里曾为了「双击播放」把单击延后 220ms 等双击 ——
                         用户口径是「没有双击这一说」,而且那一拍延迟让单击手感发黏。
                         播放走缩略图上悬停显现的 ▶(草稿标注 16),不占双击。 */
                      onClick={() => onOpenChild(ep)}
                      onContextMenu={(e) => {
                        e.preventDefault();
                        setEpCtx({ x: e.clientX, y: e.clientY, ep });
                      }}
                    >
                      <div className="th">
                        {ep.has_primary ? (
                          <img
                            src={thumbUrl(session, ep.id, 320)}
                            loading="lazy"
                            onError={(e) => ((e.target as HTMLImageElement).style.visibility = "hidden")}
                          />
                        ) : (
                          <IconPlay size={18} />
                        )}
                        {prog > 0 && (
                          <div className="progress">
                            <i style={{ width: `${prog}%` }} />
                          </div>
                        )}
                        {/* 看完打勾(绿勾,和海报卡同口径)。markPlayed 后详情重取 → d.children[].played
                            刷新 → 这里自动反显。 */}
                        {ep.played && (
                          <div className="dt-ep-chk" title="已看完">
                            <IconCheck size={12} />
                          </div>
                        )}
                        {/* 标注 16:悬停显现播放 */}
                        <button
                          className="dt-ep-play"
                          title="播放"
                          onClick={(e) => {
                            e.stopPropagation();
                            onPlay(ep);
                          }}
                        >
                          <IconPlay size={14} />
                        </button>
                      </div>
                      <div className="lines">
                        <div className="en">{ep.name}</div>
                        {meta && <div className="em">{meta}</div>}
                        {!meta && ep.runtime_secs > 0 && <div className="em">{fmtTime(ep.runtime_secs)}</div>}
                      </div>
                    </div>
                  );
                })}
              </div>
            </>
          )}

          {/* ⑥ 演职人员(真数据,没有就整段不渲染) */}
          {d && d.people.length > 0 && (
            <>
              <div className="rowlab" style={{ margin: "18px 0 8px" }}>
                <span className="h">演职人员</span>
              </div>
              <div className="dt-castwrap">
                <div className="rail dt-castrail" ref={railRef}>
                  {d.people.map((p) => (
                    <div className="dt-cast" key={p.id + p.type_ + (p.role ?? "")} title={p.role ?? p.type_}>
                      <div className="av">
                        {p.has_primary ? (
                          <img
                            src={personUrl(session, p.id)}
                            loading="lazy"
                            onError={(e) => ((e.target as HTMLImageElement).style.visibility = "hidden")}
                          />
                        ) : (
                          <span className="ini">{p.name.slice(0, 1)}</span>
                        )}
                      </div>
                      <div className="cn">{p.name}</div>
                      <div className="cr">{p.role ?? p.type_}</div>
                    </div>
                  ))}
                </div>
                <button
                  className="dt-railarrow"
                  title="更多"
                  onClick={() => railRef.current?.scrollBy({ left: 300, behavior: "smooth" })}
                >
                  <IconChevronRight size={16} />
                </button>
              </div>
            </>
          )}

          {/* ⑦ 媒体信息:每个版本一整块,流卡片全部铺开(标注 20) */}
          {versions.length > 0 && (
            <>
              <div className="rowlab" style={{ margin: "26px 0 8px" }}>
                <span className="h">媒体信息</span>
                <span className="all" style={{ cursor: "default" }}>
                  每个版本一整块,流卡片全部铺开 · 无需点击
                </span>
              </div>
              {versions.map((v, i) => {
                const vid = v.streams.find((s) => s.type_ === "Video") ?? null;
                const va = v.streams.filter((s) => s.type_ === "Audio");
                const vs = v.streams.filter((s) => s.type_ === "Subtitle");
                return (
                  <div className="dt-ver-block" key={v.id}>
                    <div className="dt-ver-head">
                      <span className="nm">
                        版本 {i + 1} · {v.name}
                      </span>
                      <span className="badges chipbar">
                        {v.container && <span className="genre">{v.container.toUpperCase()}</span>}
                        {fmtSize(v.size_bytes) && <span className="genre">{fmtSize(v.size_bytes)}</span>}
                        {fmtRes(vid?.height ?? null) && <span className="genre">{fmtRes(vid?.height ?? null)}</span>}
                        {vid?.video_range && <span className="genre">{vid.video_range}</span>}
                      </span>
                    </div>
                    <div className="dt-ver-cards" onMouseDown={dragScroll}>
                      {vid && (
                        <MiCard cap="视频">
                          <KV k="编码" v={[vid.codec.toUpperCase(), vid.profile].filter(Boolean).join(" · ")} />
                          <KV k="分辨率" v={vid.width && vid.height ? `${vid.width}×${vid.height}` : null} />
                          <KV k="动态范围" v={vid.video_range} />
                          <KV k="帧率" v={vid.frame_rate ? vid.frame_rate.toFixed(3) : null} />
                          <KV k="码率" v={fmtBitrate(vid.bitrate)} />
                        </MiCard>
                      )}
                      {va.map((s, n) => (
                        <MiCard key={s.index} cap={`音频 ${n + 1}`} tag={s.is_default}>
                          <KV k="编码" v={s.codec.toUpperCase()} />
                          <KV k="声道" v={s.channel_layout ?? (s.channels ? String(s.channels) : null)} />
                          <KV k="语言" v={s.language} />
                          <KV k="码率" v={fmtBitrate(s.bitrate)} />
                        </MiCard>
                      ))}
                      {vs.map((s, n) => (
                        <MiCard key={s.index} cap={`字幕 ${n + 1}`} tag={s.is_default}>
                          <KV k="格式" v={s.codec.toUpperCase()} />
                          <KV k="语言" v={s.language} />
                        </MiCard>
                      ))}
                      <MiCard cap="常规">
                        <KV k="容器" v={v.container?.toUpperCase()} />
                        <KV k="大小" v={fmtSize(v.size_bytes)} />
                        <KV k="时长" v={v.runtime_secs > 0 ? fmtTime(v.runtime_secs) : null} />
                        <KV k="总码率" v={fmtBitrate(v.bitrate)} />
                      </MiCard>
                    </div>
                  </div>
                );
              })}
            </>
          )}

          {/* ⑧ 相似推荐(剧集/电影页,放最下面 —— 用户 2026-07-15)。
              空数组 = 服务端没给相似项 → 整段不渲染,不留空标题。
              用 Poster:它就是海报卡的标准形态(评分角标/进度/单击进详情都现成),
              onOpenChild 把点到的相似条目当新 item 推进详情栈,和分集点击同一个入口。
              相似项可能混 Series+Movie,Poster 不关心类型,照常渲染。 */}
          {similar && similar.length > 0 && (
            <>
              <div className="rowlab" style={{ margin: "26px 0 8px" }}>
                <span className="h">相似推荐</span>
              </div>
              <div className="rail" onMouseDown={dragScroll}>
                {similar.map((it, i) => (
                  <div className="r-poster" key={it.id}>
                    <Poster item={it} session={session} index={i} onOpen={onOpenChild} />
                  </div>
                ))}
              </div>
            </>
          )}
        </div>
        <div style={{ height: 40 }} />
      </div>

      {/* Hero/播放条的「更多」锚定菜单(标注 13)。
          草稿列的是「投屏 / 换源 / 标记 / 外部 MPV」,这里只剩「标记」:
          投屏(DLNA)、换源、外部 MPV 三项**核层 197 个 tauri::command 里一个都没有**
          (grep '#[tauri::command]' 全表核过:无 cast/dlna/external/open_with)。
          按草稿 979 自己立的规矩「没有就不显示、不硬凑」——弹个「待接」toast 的假菜单项
          比没有更坏:用户以为坏了,下一个人以为接过了。核层补齐命令后再加回来。 */}
      {/* ★ 通过 portal 挂到 body:.ctxmenu 是 position:fixed,但详情页祖先 .page 带
          animation(transform)会生成「包含块」,让 fixed 退化成相对该祖先定位 → 菜单跑到
          按钮下方老远(用户 2026-07-16「更多菜单不靠着按钮显示」)。挂到 body 就没有被
          transform 的祖先,fixed 恢复相对视口,坐标(getBoundingClientRect)才对得上。 */}
      {moreMenu && createPortal(
        <div className="ctxmenu" style={{ left: moreMenu.x, top: moreMenu.y }} onClick={(e) => e.stopPropagation()}>
          <div className="mi" onClick={() => markPlayed(item.id, !played)}>
            <IconInfo size={15} /> {played ? "标记未看" : "标记已看"}
          </div>
        </div>,
        document.body,
      )}

      {/* 分集右键菜单(标注 16)。「换源」同上:核层无此命令 → 不摆假项。 */}
      {epCtx && createPortal(
        <div className="ctxmenu" style={{ left: epCtx.x, top: epCtx.y }} onClick={(e) => e.stopPropagation()}>
          <div className="mi" onClick={() => markPlayed(epCtx.ep.id, true)}>
            <IconInfo size={15} /> 标记已看
          </div>
          <div className="mi" onClick={() => markPlayed(epCtx.ep.id, false)}>
            <IconInfo size={15} /> 标记未看
          </div>
          <div
            className="mi"
            onClick={() => {
              enqueue(epCtx.ep);
              setEpCtx(null);
            }}
          >
            <IconDownload size={15} /> 下载本集
          </div>
        </div>,
        document.body,
      )}

      {toast && <div className="toast">{toast}</div>}
      </div>
    </>
  );
}
