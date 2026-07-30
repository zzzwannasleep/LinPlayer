import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { setFocus } from "@noriginmedia/norigin-spatial-navigation";
import {
  aggregateSearch,
  downloadEnqueue,
  fmtBitrate,
  fmtRes,
  fmtSize,
  fmtTime,
  itemDetail,
  itemMedia,
  listAccounts,
  peekItemDetail,
  play,
  posterUrl,
  setActiveLine,
  setFavorite,
  setPlayed,
  setTrack,
  thumbUrl,
  tracks,
  type AccountInfo,
  type Item,
  type LoginResult,
  type MediaVersion,
  type StreamInfo,
  type Track,
  defaultVersion,
} from "@shared/api";
import type { Route } from "../App";
import { onTvKey } from "../app/focus";
import { Icon } from "../app/icons";
import { FocusBoundary, FocusColumn, FocusItem, FocusRow } from "../components/Focus";
import { useAsync } from "../lib/useAsync";

/** 集详情(草稿 15)。**版本 / 音轨 / 字幕的选择全部集中在这一页** ——
    剧的层级上没有"版本"这回事,每一集的片源都可能来自不同来源、规格也不同,
    所以剧详情页一个都不放。

    ★ 底部是**集数栏**,不是「上一集 / 下一集」两个按钮:两个按钮一次只能挪一格,
      24 集的番要按 18 次。集数栏一次可见 13 集,横向直达。
    ★ 换集**不回上层**:集数栏切集只换本页内容(itemId 换成新的一集),
      版本行跟着重新聚合。 */
export default function EpisodePage({
  session,
  go,
  itemId,
}: {
  session: LoginResult;
  go: (r: Route) => void;
  itemId?: string;
}) {
  /* 当前这一集。集数栏切集改的是它,不动路由栈 —— 退出时按一次返回就回剧详情,
     而不是"切了几集就要按几次"。 */
  const [curId, setCurId] = useState(itemId ?? "");
  /* ★ 先偷看缓存再拉:集数栏来回切集时命中率极高,不偷看就是每切一集整页空一下。 */
  const ep = useAsync(() => itemDetail(curId), [curId], () => peekItemDetail(curId));
  const d = ep.data;

  /* 剧本体单独一块各自加载:集数栏要的是**整季的分集表**,而分集详情里没有。
     不和上面并到一个 Promise.all 里 —— 分集详情先回来,顶部就先画出来。 */
  const seriesId = d?.series_id ?? null;
  const series = useAsync(
    () => (seriesId ? itemDetail(seriesId) : Promise.resolve(null)),
    [seriesId],
    /* 剧本体这一份缓存命中率最高(整季切集都是同一个 seriesId)——
       没有它,集数栏每切一集都要空一次再重画。 */
    () => (seriesId ? peekItemDetail(seriesId) : undefined),
  );

  /* 同季分集。跨季混在一起会让 E01 出现两次(第一季和第二季各一个)。 */
  const episodes = useMemo(
    () =>
      (series.data?.children ?? []).filter(
        (c) => d?.season_no == null || c.season_no === d.season_no,
      ),
    [series.data, d?.season_no],
  );
  /* 本集在分集表里的那一行 —— ItemDetail 不带 played,已看状态只有这里有。
     拿不到就整个「标记已看」按钮不渲染,而不是猜一个默认值画上去。 */
  const cur = episodes.find((e) => e.id === curId) ?? null;

  /* 版本 + 各条流。选择器行和底部媒体信息块共用这一份 ——
     VersionRow 内部另有一次 item_media(它要在跨服探测的编排里用),不合并:
     合并就得把探测编排整个提上来,为省一次本机请求把一个自洽的组件拆散不划算。 */
  const media = useAsync(() => itemMedia(curId), [curId]);

  const [view, setView] = useEpView();
  const [fav, setFav] = useState<boolean | null>(null);
  const [played, setPlayedLocal] = useState<boolean | null>(null);
  const [picks, setPicks] = useState<Picks>(NO_PICKS);
  const [msg, setMsg] = useState<string | null>(null);

  /* 换集 = 换片源,上一集选的音轨/字幕/版本在新的一集上根本不是同一条流,留着就是错的。 */
  useEffect(() => setPicks(NO_PICKS), [curId]);

  useEffect(() => setFav(d?.is_favorite ?? null), [d?.is_favorite]);
  useEffect(() => setPlayedLocal(cur?.played ?? null), [cur?.played]);

  /* ★ 「选完版本(用户口中的『播放记录』)之后按↓进不了集数栏」的解法。
     根因是几何,不是这一页写错了,两条叠在一起:
       ① 集数栏是 `.hscroll`,它的负 margin 让登记给焦点库的矩形**比看上去的顶高 32px**,
          正好盖住上面那排「紧凑 / 详细」。库筛候选要求「兄弟的上边 ≥ 自己的下边」,
          于是站在「紧凑/详细」上按↓,集数栏被整个筛掉 —— 原地不动,死胡同。
       ② 版本卡按↓时库先在本行找不到人,回退到整行再找;而「详细」按钮的右边缘和
          版本行的右边缘几乎齐平(实测角距 4px),库的斜向惩罚(5 倍)也压不过这 4px
          → 焦点被吸到右上角那个小按钮上,而不是正下方的集数栏。
     ①已经靠把空隙加到 > 32px 解决(见下面两处 marginBottom 的注释),
     ②没法靠布局绕开(要么把版本行做窄、要么把视图切换挪走,都是改版式),
     所以只有版本行这一处走显式跳转。
     ★ **别把 data-eps-jump 也打到选集表头上**:那样「紧凑/详细」按↓永远被送去集数栏,
       而它自己下面就是集数栏 —— 看着没坏,实际是把切换钮变成了只进不出的死路。
     ★ 必须**捕获阶段**拦:库自己是在 window 冒泡阶段监听的(BaseWebAdapter),
       capture 先到,stopPropagation 才顶得掉它的默认判定。 */
  useEffect(() => {
    if (episodes.length === 0) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key !== "ArrowDown" && !DOWN_KEYCODES.has(e.keyCode)) return;
      /* 焦点项是普通 div(不是原生可聚焦元素),document.activeElement 认不出来;
         库开了 shouldFocusDOMNode,会把 data-focused 打在当前焦点节点上,认它。 */
      if (!document.querySelector("[data-focused]")?.closest("[data-eps-jump]")) return;
      e.preventDefault();
      e.stopPropagation();
      void setFocus(EPISODES_FK);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [episodes.length]);

  if (!itemId) return <Empty text="没有指定要播放的分集。" />;
  if (ep.err) return <Empty text={ep.err.message} />;
  if (!d) return <Empty text="载入中…" />;

  const resume = d.resume_secs > 1 ? d.resume_secs : 0;
  /** 当前生效的版本:用户没挑就是服务器给的第一个。媒体信息块和轨道映射都按它算。
   *  (名字不叫 cur —— 上面那个 cur 是"本集在分集表里的那一行",两回事。) */
  /* 显示用:没手动挑就显示正则挑中的那条。 */
  const curVer = picks.ver ?? defaultVersion(media.data ?? []);

  const start = async (secs: number) => {
    setMsg(null);
    try {
      /* ★ 只传**用户真挑过的**版本。传 curVer(没挑时=列表第一条)等于每次都手动指定了
         第一版,核层的版本筛选正则整个被跳过。 */
      await play(curId, secs, picks.ver?.id ?? null);
      go({ page: "player" });
      /* ★ 落轨放在导航之后且不 await:applyPicks 要等 mpv 的 track-list 出来
         (见它自己的注释),阻塞在这儿会让按下播放到画面出现之间多卡一两秒。 */
      void applyPicks(curVer, picks);
    } catch (e) {
      setMsg(e instanceof Error ? e.message : String(e));
    }
  };

  return (
    <div style={{ position: "relative", height: "100%", padding: "48px 64px" }}>
      <FocusColumn focusKey="EPISODE">
        <div style={{ fontSize: 19, color: "var(--tv-ink-3)", marginBottom: 10 }}>
          {[d.series_name, d.season_no != null ? `第 ${d.season_no} 季` : null]
            .filter(Boolean)
            .join(" · ")}
        </div>
        <h3 style={{ fontSize: 36, fontWeight: 700, letterSpacing: "-.02em", margin: "0 0 10px" }}>
          {d.episode_no != null ? `E${d.episode_no} · ${d.name}` : d.name}
        </h3>

        {/* 顶部**不重复规格**:编码 / 音轨 / 字幕都在版本卡上,这里只留时长和剩余。 */}
        <div style={META}>
          {d.runtime_secs > 0 && <span>{Math.round(d.runtime_secs / 60)} 分钟</span>}
          {resume > 0 && d.runtime_secs > resume && (
            <span>剩 {Math.round((d.runtime_secs - resume) / 60)} 分钟</span>
          )}
        </div>

        {/* ★ 切到「详细」时顶部简介必须消失 —— 详细卡自带简介,
            同一段话不该在一屏里出现两次。 */}
        {view === "compact" && d.overview && <p style={SYNOPSIS}>{d.overview}</p>}

        {resume > 0 && d.runtime_secs > 0 && (
          <div style={BAR}>
            <i
              style={{
                display: "block",
                height: "100%",
                borderRadius: 4,
                background: "var(--accent)",
                width: `${Math.min(100, (resume / d.runtime_secs) * 100)}%`,
              }}
            />
          </div>
        )}

        <div className="btnrow" style={{ marginBottom: 36 }}>
          <FocusItem className="btn pri fx" autoFocus onEnter={() => void start(resume)}>
            <Icon n="play" className="ic ic-btn" />
            {resume > 0 ? `继续播放 ${fmtTime(resume)}` : "播放"}
          </FocusItem>
          {resume > 0 && (
            <FocusItem className="btn fx" onEnter={() => void start(0)}>
              从头播放
            </FocusItem>
          )}
          {played != null && (
            <FocusItem
              className="btn fx"
              onEnter={() => {
                const next = !played;
                setPlayedLocal(next);
                void setPlayed(curId, next).catch(() => setPlayedLocal(!next));
              }}
            >
              <Icon n="check" className="ic ic-btn" />
              {played ? "标记未看" : "标记已看"}
            </FocusItem>
          )}
          <FocusItem
            className={`btn fx${fav ? " pri" : ""}`}
            onEnter={() => {
              const next = !fav;
              setFav(next);
              void setFavorite(curId, next).catch(() => setFav(!next));
            }}
          >
            <Icon n="heart" className="ic ic-btn" />
            {fav ? "已收藏" : "收藏"}
          </FocusItem>
          <FocusItem
            className="btn fx"
            onEnter={() => {
              /* container 拿不到就传空串:核层会兜成 mkv。别在前端瞎写一个扩展名 ——
                 落盘文件名会跟着错。 */
              void downloadEnqueue(
                curId,
                "Episode",
                d.series_name ? `${d.series_name} · ${d.name}` : d.name,
                curVer?.container ?? "",
                posterUrl(session, curId, 480),
              )
                .then(() => setMsg("已加入下载队列"))
                .catch((e) => setMsg(e instanceof Error ? e.message : String(e)));
            }}
          >
            <Icon n="download" className="ic ic-btn" />
            下载
          </FocusItem>
        </div>

        {/* ★ 播放键正下方的四个入口。原来这一页只能「按下去看运气」——
            字幕/音轨/版本/线路都调不了(用户 2026-07-20 评审)。 */}
        <PickBar
          fk="EP"
          versions={media.data}
          cur={curVer}
          picks={picks}
          onPicks={setPicks}
        />

        {msg && <div style={{ color: "var(--tv-ink-2)", fontSize: 19, marginBottom: 18 }}>{msg}</div>}

        {/* data-eps-jump = 「在这里按↓直接进集数栏」。顺带把版本行的标题和卡片包成
            **同一段**(FocusColumn 的 sectionOf 认 .inner 的直接子元素)——
            从卡片往上回时会连「版本」标题一起对齐,不再把标题切在视野外。 */}
        <div data-eps-jump="">
          <VersionRow
            itemId={curId}
            matchTitle={d.series_name ?? series.data?.name ?? null}
            /* ★ 「系列名」是跨来源认定同一集的唯一依据,而**有服务端不给**
               (Episode.SeriesName 缺失)。这时只能拿上层剧条目的名字顶上,
               置信度不足 → 卡片打「可能匹配」黄标,不假装是精确匹配。 */
            titleConfident={d.series_name != null}
            /* 版本行和 PickBar 的「版本」选的是同一件事,共用同一份状态 ——
               两个各记各的,用户在一处换了版本、另一处显示的还是旧的。 */
            onSelect={(v) => setPicks((p) => ({ ...p, ver: v }))}
          />
        </div>

        {/* 集数栏紧跟版本行,**不用 margin-top:auto 贴底** ——
            贴底会在版本行和集数栏之间留一大块空,焦点从版本走到集数要跨过一段虚无。 */}
        {episodes.length > 0 && (
          <>
            {/* 14 → 40:同一条 32px 规则(见上面版本行那段)。原来的 14px 让集数栏的焦点矩形
                盖住这排「紧凑 / 详细」,两个方向都断:站在切换钮上按↓跳过集数栏,
                站在集数栏上按↑又跳过切换钮 —— **视图切换实际上根本走不到**(单版本的剧
                连那个几何巧合都没有)。这是修版本行时顺出来的同源 bug,不是新加的间距。 */}
            <div className="rowhead" style={{ marginBottom: 40 }}>
              <div className="t">选集</div>
              <div style={{ fontSize: 17, color: "var(--tv-ink-3)" }}>
                {[d.season_no != null ? `第 ${d.season_no} 季` : null, `共 ${episodes.length} 集`]
                  .filter(Boolean)
                  .join(" · ")}
              </div>
              <div className="epsw" style={{ marginLeft: "auto" }}>
                <FocusItem
                  className={view === "compact" ? "on" : ""}
                  onEnter={() => setView("compact")}
                >
                  紧凑
                </FocusItem>
                <FocusItem
                  className={view === "detail" ? "on" : ""}
                  onEnter={() => setView("detail")}
                >
                  详细
                </FocusItem>
              </div>
            </div>
            {view === "compact" ? (
              <CompactStrip eps={episodes} curId={curId} onPick={setCurId} />
            ) : (
              <FocusRow className="epwrap" trackClass="track" focusKey={EPISODES_FK}>
                {episodes.map((e) => (
                  <EpisodeCard
                    key={e.id}
                    e={e}
                    session={session}
                    on={e.id === curId}
                    onEnter={() => setCurId(e.id)}
                  />
                ))}
              </FocusRow>
            )}
          </>
        )}

        {/* 页面下部原来是空的。放当前版本的规格,不重复顶部已有的时长/剩余。
            ★ 包成可聚焦块的原因见 InfoBlock 自己的注释(不然这一段永远滚不到)。 */}
        {curVer && (
          <InfoBlock>
            <MediaInfo v={curVer} />
          </InfoBlock>
        )}
      </FocusColumn>
    </div>
  );
}

/* ------------------------------------------------------------
   版本行 —— 集详情页和**电影详情页共用同一个组件**。
   同一个概念做两套视觉,用户每换一页就要重新认一遍。
   ------------------------------------------------------------ */

/** 一次探测的结果。
 *  ★ opaque 这个态是真实存在的能力边界,不是偷懒:核层只有 `item_media`(打**当前**
 *    服务器)和 `aggregate_search`(跨服搜,但只回 Movie/Series 且**不带 MediaSources**)。
 *    没有任何一个已导出命令能拿到"另一台 Emby 上这个条目的 MediaSource"。
 *    所以别台服务器只能确认"有没有这部",规格未知 —— 那就如实说未知,
 *    不编一个分辨率画上去。 */
type Probe =
  | { kind: "probing" }
  | { kind: "ok"; versions: MediaVersion[] }
  | { kind: "absent" }
  | { kind: "opaque"; maybe: boolean };

type VCard = {
  key: string;
  serverName: string;
  current: boolean;
  probe: Probe;
  v: MediaVersion | null;
};

export function VersionRow({
  itemId,
  matchTitle,
  titleConfident,
  onSelect,
}: {
  itemId: string;
  /** 跨来源认定"同一个条目"用的名字。null = 认不出来,别台服务器整个不探。 */
  matchTitle: string | null;
  titleConfident: boolean;
  onSelect: (v: MediaVersion | null) => void;
}) {
  const [accounts, setAccounts] = useState<AccountInfo[]>([]);
  const [probes, setProbes] = useState<Record<string, Probe>>({});
  const [sel, setSel] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    setProbes({});
    setSel(null);
    void (async () => {
      /* ★ 只聚合 Emby。网盘 / OpenList / 飞牛没有 MediaSource 这个概念,
         要聚合就得逐个探测文件在不在 —— 为一行选择器做这件事不划算。 */
      const accs = (await listAccounts().catch(() => [] as AccountInfo[])).filter(
        (a) => a.source_kind === "emby",
      );
      if (!alive) return;
      setAccounts(accs);

      /* ★★ 必须异步回填,**不许等齐再渲染**:当前来源本地就能问到,立刻出;
         其它来源回来一个填一个。等齐 = 进页白屏两秒。 */
      const me = accs.find((a) => a.active);
      if (me) {
        itemMedia(itemId)
          .then((vs) => {
            if (!alive) return;
            setProbes((p) => ({ ...p, [me.server]: { kind: "ok", versions: vs } }));
          })
          .catch(() => {
            if (alive) setProbes((p) => ({ ...p, [me.server]: { kind: "absent" } }));
          });
      }

      const others = accs.filter((a) => !a.active);
      if (others.length === 0) return;
      const mark = (f: (a: AccountInfo) => Probe) =>
        setProbes((p) => {
          const n = { ...p };
          for (const a of others) n[a.server] = f(a);
          return n;
        });
      if (!matchTitle) {
        /* 连名字都没有 → 无从认定,如实标"认不出"而不是留一排永远转圈的卡。 */
        mark(() => ({ kind: "absent" }));
        return;
      }
      const groups = await aggregateSearch(matchTitle).catch(() => []);
      if (!alive) return;
      mark((a) => {
        const hit = groups
          .find((g) => g.server_id === a.server)
          ?.items.some((it) => norm(it.name) === norm(matchTitle));
        return hit ? { kind: "opaque", maybe: !titleConfident } : { kind: "absent" };
      });
    })();
    return () => {
      alive = false;
    };
  }, [itemId, matchTitle, titleConfident]);

  const cards = useMemo(() => buildCards(accounts, probes), [accounts, probes]);

  /* 默认选中排序后的第一张(= 当前来源里分辨率/码率最高的那版)。
     ★ 焦点**不**用 autoFocus 抢:版本卡是异步回填的,挂载时抢焦点会把用户
       刚落在「继续播放」上的焦点偷走。落进这一行时库自己会走到第一张。 */
  const first = cards.find((c) => c.v)?.v ?? null;
  useEffect(() => {
    if (!first) return;
    setSel((s) => s ?? first.id);
    onSelect(first);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [first?.id]);

  /* 只有一个版本、也没有别的 Emby 可比 → 整行不渲染。
     留一个"只能选它自己"的选择器纯属占版面。 */
  if (cards.length <= 1) return null;

  return (
    <>
      <div className="rowhead" style={{ marginBottom: 16 }}>
        <div className="t">版本</div>
        <div style={{ fontSize: 17, color: "var(--tv-ink-3)" }}>
          来自 {accounts.length} 台 Emby 服务器
        </div>
      </div>
      <FocusRow trackClass="track breathe">
        {cards.map((c) => (
          <VersionCard
            key={c.key}
            c={c}
            on={c.v != null && c.v.id === sel}
            onEnter={() => {
              if (!c.v) return;
              setSel(c.v.id);
              onSelect(c.v);
            }}
          />
        ))}
      </FocusRow>
      {/* ★ 这个空隙**必须 > 32px**,不是留白好看:`.hscroll` 用 padding:32 + 负 margin
          给焦点环留呼吸位(见 tv.css),而那对负 margin 会**穿过 FocusRow 的外层 div 合并**
          —— 于是这一行登记给焦点库的矩形比它看上去的底部还低 32px。
          焦点库筛下一个候选的条件是「兄弟的上边 ≥ 自己的下边」,空隙不到 32 的话,
          紧跟在版本行后面的那一块**会被整个筛掉**:表现是按↓直接跳过它(甚至原地不动),
          而截图上一点都看不出来。实测(headless + 真 CSS):卡片 469..681,行矩形 437..713。 */}
      <div style={{ height: 40 }} />
    </>
  );
}

/** 排序 = **当前来源 → 分辨率降序 → 码率降序**。最可能想要的那张必须排第一。
 *  拿不到规格的(还在查 / 只知道有)排在真版本之后,确认没有的垫底。 */
function buildCards(accounts: AccountInfo[], probes: Record<string, Probe>): VCard[] {
  const out: VCard[] = [];
  for (const a of accounts) {
    const p = probes[a.server] ?? { kind: "probing" };
    if (p.kind === "ok") {
      for (const v of p.versions)
        out.push({ key: `${a.server}:${v.id}`, serverName: a.name, current: a.active, probe: p, v });
      if (p.versions.length === 0)
        out.push({ key: a.server, serverName: a.name, current: a.active, probe: { kind: "absent" }, v: null });
    } else {
      out.push({ key: a.server, serverName: a.name, current: a.active, probe: p, v: null });
    }
  }
  const rank = (c: VCard) => (c.v ? 0 : c.probe.kind === "absent" ? 2 : 1);
  return out.sort(
    (x, y) =>
      rank(x) - rank(y) ||
      Number(y.current) - Number(x.current) ||
      (height(y.v) - height(x.v)) ||
      ((y.v?.bitrate ?? 0) - (x.v?.bitrate ?? 0)),
  );
}

/** 380×212dp。信息四层:来源 18sp / **分辨率 30sp(最大)** / 编码·码率·体积 17sp / 音轨·字幕 16sp。
 *  分辨率最大是因为它是三米外唯一一眼可辨的字段。 */
function VersionCard({ c, on, onEnter }: { c: VCard; on: boolean; onEnter: () => void }) {
  const v = c.v;
  return (
    <FocusItem
      className={`vcard fx${on ? " on" : ""}${v ? "" : " off"}`}
      /* ★ 不可用来源**保留但不可聚焦**:整张消失会让用户以为片源丢了,
         可聚焦又白白多按一次方向键才能越过去。 */
      disabled={!v}
      onEnter={onEnter}
    >
      <div className="src">
        <Icon n="server" className="ic" />
        {c.serverName}
        {c.current && <span className="tag">当前</span>}
      </div>
      {v ? (
        <>
          <div className="res">{resLabel(v)}</div>
          <div className="spec">{specLabel(v)}</div>
          {/* ★ 版本卡**不显示观看进度** —— 起播一律接当前进度,
              不管这个版本在别的服务器上被看到哪。 */}
          <div className="trk">{trackLabel(v)}</div>
        </>
      ) : (
        <>
          <div className="res" style={{ color: "var(--tv-ink-3)" }}>
            —
          </div>
          <div className="spec">
            {c.probe.kind === "probing" ? "查询中…" : c.probe.kind === "absent" ? "此来源没有该条目" : "已找到,规格未知"}
          </div>
          {c.probe.kind === "opaque" && (
            <div className="trk">切换到该服务器后可看规格</div>
          )}
        </>
      )}
      {c.probe.kind === "opaque" && c.probe.maybe && <div className="warn">可能匹配</div>}
    </FocusItem>
  );
}

/* ------------------------------------------------------------
   集数栏
   ------------------------------------------------------------ */

/** 紧凑视图:集号 chip,**选中恒居中**,两端渐隐(.epwrap)。 */
function CompactStrip({
  eps,
  curId,
  onPick,
}: {
  eps: Item[];
  curId: string;
  onPick: (id: string) => void;
}) {
  const wrap = useRef<HTMLDivElement>(null);

  /* 居中靠自己算:FocusRow 自带的滚动只保证"焦点看得见",不保证居中。
     ★ 用 offsetLeft / clientWidth 而不是 getBoundingClientRect ——
       .tv-app 上有 zoom,gBCR 返回缩放后的设备 px,而 transform 吃的是未缩放的 CSS px,
       两者混用会让位移只走该走的 61%(见 Focus.tsx 的 zoomOf 注释)。
       offset* 系列是布局值,天生不受 zoom 影响,省掉一次换算。 */
  useEffect(() => {
    const strip = wrap.current?.querySelector<HTMLElement>(".epstrip");
    const view = strip?.parentElement;
    const sel = strip?.querySelector<HTMLElement>("[data-cur='1']");
    if (!strip || !view || !sel) return;
    const center = sel.offsetLeft + sel.offsetWidth / 2 - view.clientWidth / 2;
    /* 左端不过界:第 1 集"居中"意味着左边空掉半屏,那比不居中更难看。 */
    strip.style.transform = `translateX(${-Math.max(0, center)}px)`;
  }, [curId, eps.length]);

  return (
    <div ref={wrap}>
      <FocusRow className="epwrap" trackClass="epstrip" focusKey={EPISODES_FK}>
        {eps.map((e) => (
          <FocusItem
            key={e.id}
            className={`ep${e.played ? " done" : ""}${e.id === curId ? " on" : ""}`}
            onEnter={() => onPick(e.id)}
          >
            {/* data 属性只给上面那段居中计算认人用,不参与样式 */}
            <span data-cur={e.id === curId ? "1" : "0"}>
              {e.episode_no != null ? `E${e.episode_no}` : e.name}
            </span>
          </FocusItem>
        ))}
      </FocusRow>
    </div>
  );
}

/** 详细视图:封面卡。卡片自带简介 → 顶部那段简介同步隐藏(见上面 view 分支)。 */
function EpisodeCard({
  e,
  session,
  on,
  onEnter,
}: {
  e: Item;
  session: LoginResult;
  on: boolean;
  onEnter: () => void;
}) {
  const pct = e.runtime_secs > 0 ? Math.min(100, (e.resume_secs / e.runtime_secs) * 100) : 0;
  return (
    <FocusItem className={`epcard fx${on ? " on" : ""}`} onEnter={onEnter}>
      <div className="th">
        {e.has_primary && <img src={thumbUrl(session, e.id, 640)} alt="" loading="lazy" />}
        {e.episode_no != null && <div className="no">E{e.episode_no}</div>}
        {pct > 0 && (
          <div className="prog">
            <i style={{ width: `${pct}%` }} />
          </div>
        )}
      </div>
      <div className="nm">{e.name}</div>
      <div className="du">
        {[
          e.runtime_secs > 0 ? `${Math.round(e.runtime_secs / 60)} 分钟` : null,
          e.played ? "已看完" : pct > 0 ? `剩 ${Math.round((e.runtime_secs - e.resume_secs) / 60)} 分钟` : null,
        ]
          .filter(Boolean)
          .join(" · ")}
      </div>
    </FocusItem>
  );
}

/* ------------------------------------------------------------
   小工具
   ------------------------------------------------------------ */

/** 视图选择要**持久化**:切一次「详细」之后,下次进来还得是他要的那个。 */
function useEpView(): ["compact" | "detail", (v: "compact" | "detail") => void] {
  const [v, setV] = useState<"compact" | "detail">(() =>
    localStorage.getItem(EP_VIEW_KEY) === "detail" ? "detail" : "compact",
  );
  const set = useCallback((n: "compact" | "detail") => {
    setV(n);
    localStorage.setItem(EP_VIEW_KEY, n);
  }, []);
  return [v, set];
}
const EP_VIEW_KEY = "lp.tv.epview";

/** 集数栏的焦点键。显式给是因为要从版本行/选集表头**跳**过来(见上面那段注释)。 */
const EPISODES_FK = "EP_EPISODES";

/** 「下」键的 keyCode。★ 和 app/focus.ts 的 setKeyMap 保持一致 —— 库没把 keyMap 导出来,
 *  只能抄一份;那边补了新机型的 keyCode,这里要跟着补(不跟的表现是某些盒子上跳转失灵)。 */
const DOWN_KEYCODES = new Set([40, 212, 204, 216, 29461]);

/** 纯展示区块的「可走到」包装。
 *
 *  ★ 为什么要让一段不能按的内容可聚焦:FocusColumn 的滚动是**焦点驱动**的
 *    (只把拿到焦点的元素滚进视野)。所以位于最后一个可聚焦项**下面**的展示区块
 *    ——媒体信息、演职人员——遥控器的↓走到最后一个按钮就停住了,那块内容
 *    **永远滚不到,等于不存在**(用户原话:「我根本无法往下点,完全看不了」)。
 *
 *  ★ 焦点态刻意不用全站那套(`.fx` 放大 + 3px 环 + 12px 光晕):这是一整块正文,
 *    放大整块字会抖,重环看着像个巨大的按钮 —— 它不能按。改成一圈克制的描边,
 *    且用 outline + offset(不占布局,不会把下面的内容推走)。 */
export function InfoBlock({ children }: { children: ReactNode }) {
  return (
    <FocusItem className="infoblock" focusClass="focsoft">
      {children}
    </FocusItem>
  );
}

function Empty({ text }: { text: string }) {
  return (
    <div style={{ padding: "48px 64px" }}>
      <div className="psub">{text}</div>
    </div>
  );
}

const norm = (s: string) => s.toLowerCase().replace(/[\s·:：!！?？.、,,-]/g, "");

const videoOf = (v: MediaVersion): StreamInfo | null =>
  v.streams.find((s) => s.type_ === "Video") ?? null;
const height = (v: MediaVersion | null) => (v ? (videoOf(v)?.height ?? 0) : 0);

function resLabel(v: MediaVersion): string {
  const vs = videoOf(v);
  const r = fmtRes(vs?.height ?? null) || "未知";
  const hdr = vs?.video_range && vs.video_range.toUpperCase() !== "SDR" ? ` ${vs.video_range}` : "";
  return r + hdr;
}

/** ★ 码率必须给:只写「4K / 1080p」分不出好坏 —— 4 Mbps 的 2160p 压制不如 15 Mbps 的 1080p。 */
function specLabel(v: MediaVersion): string {
  return [videoOf(v)?.codec.toUpperCase(), fmtBitrate(v.bitrate), fmtSize(v.size_bytes)]
    .filter((x): x is string => !!x)
    .join(" · ");
}

/** 一条流的人话标签。服务端给了 display_title 就用它(那是 Emby 自己拼好的,
 *  比我们拼的准),没有才自己拼语言+编码+声道。 */
function streamLabel(s: StreamInfo): string {
  return (
    s.display_title ??
    [s.language, s.codec.toUpperCase(), s.channel_layout].filter((x): x is string => !!x).join(" ")
  );
}

/** 卡片上只**列出**有哪些音轨/字幕,不在这里逐条选(选定版本后进面板挑)。 */
function trackLabel(v: MediaVersion): string {
  const one = streamLabel;
  const audio = v.streams.filter((s) => s.type_ === "Audio").slice(0, 2).map(one).join(" / ");
  const subs = v.streams
    .filter((s) => s.type_ === "Subtitle")
    .map((s) => s.language ?? s.display_title)
    .filter((x): x is string => !!x)
    .slice(0, 4)
    .join(" / ");
  return [audio || "无音轨", subs || "无字幕"].join(" · ");
}

const META: React.CSSProperties = {
  display: "flex",
  gap: 18,
  alignItems: "center",
  fontSize: 19,
  color: "var(--tv-ink-2)",
  marginBottom: 16,
};

const SYNOPSIS: React.CSSProperties = {
  fontSize: 16,
  lineHeight: 1.5,
  color: "var(--tv-ink-2)",
  maxWidth: 760,
  margin: "0 0 16px",
  display: "-webkit-box",
  WebkitLineClamp: 2,
  WebkitBoxOrient: "vertical",
  overflow: "hidden",
};

const BAR: React.CSSProperties = {
  height: 8,
  borderRadius: 4,
  background: "rgba(255,255,255,.18)",
  maxWidth: 940,
  marginBottom: 28,
};

/* ============================================================
   播放键下面的四个选择器 —— 集详情页和**电影详情页共用**。

   ★ 「线路」出现在详情页是**用户 2026-07-20 评审的新要求**。
     本目录 README 里写着「线路只出现在线路管理页」,那条是旧口径,
     以用户最新要求为准 —— 后人看到两边不一致时别当成写错了顺手删掉。

   ★ 四个入口恒画,**没有可选项时开出来的面板如实说「没有」**,不是把入口藏掉:
     藏掉的表现是"这台机器上怎么没有字幕按钮",用户会以为是 App 少做了功能。
     这也和播放页 OSD 的轨道面板同一套写法(PlayerPage 的「没有可选的X」)。
   ============================================================ */

type PickKind = "sub" | "audio" | "ver" | "line";

/** 用户在详情页做的选择。**不落地到设置**:它只对这一次起播有效。 */
export type Picks = {
  ver: MediaVersion | null;
  /** null = 没挑过 → 交给核层的音轨偏好(track_preference),别在这里替它做主。 */
  audio: StreamInfo | null;
  /** "off" = 用户显式关字幕;null 同上,交给核层偏好。 */
  sub: StreamInfo | "off" | null;
};

export const NO_PICKS: Picks = { ver: null, audio: null, sub: null };

const PICK_TITLE: Record<PickKind, string> = {
  sub: "字幕",
  audio: "音频",
  ver: "版本",
  line: "线路",
};
const PICK_ICON = { sub: "sub", audio: "audio", ver: "file", line: "server" } as const;

export function PickBar({
  fk,
  versions,
  cur,
  picks,
  onPicks,
}: {
  /** 焦点键前缀。同一个组件在电影页和集详情页各挂一次,键重了 setFocus 会还错地方。 */
  fk: string;
  versions: MediaVersion[] | null;
  /** 当前生效的版本(用户没挑就是第一个)。字幕/音频列表都从它的 streams 里出。 */
  cur: MediaVersion | null;
  picks: Picks;
  onPicks: (p: Picks) => void;
}) {
  const [open, setOpen] = useState<PickKind | null>(null);
  const [acc, setAcc] = useState<AccountInfo | null>(null);
  const [err, setErr] = useState<string | null>(null);

  /* 线路表挂在账号上,没有单独的「取当前服务器线路」命令 → 从账号表里挑 active 那台。 */
  useEffect(() => {
    let alive = true;
    void listAccounts()
      .then((l) => {
        if (alive) setAcc(l.find((a) => a.active) ?? null);
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);

  /* 面板一卸载,焦点在树上就没有落点了 —— 那是 TV 最经典的 P0(遥控器整个失灵)。
     必须显式还给刚才那个入口。 */
  const close = useCallback(
    (k: PickKind) => {
      setOpen(null);
      void setFocus(`${fk}_${k}`);
    },
    [fk],
  );

  useEffect(
    () => onTvKey((k) => k === "back" && open != null && close(open)),
    [open, close],
  );

  const subs = cur?.streams.filter((s) => s.type_ === "Subtitle") ?? [];
  const auds = cur?.streams.filter((s) => s.type_ === "Audio") ?? [];
  const vers = versions ?? [];
  const lines = acc?.lines ?? [];
  /* picks.sub 的 "off" 分支单独摘出来,免得每个用到的地方都写一遍窄化。 */
  const subSel = picks.sub && picks.sub !== "off" ? picks.sub : null;

  const val: Record<PickKind, string> = {
    sub: picks.sub === "off" ? "关闭" : subSel ? streamLabel(subSel) : subs.length ? "默认" : "无",
    audio: picks.audio ? streamLabel(picks.audio) : auds.length ? "默认" : "无",
    ver: cur ? cur.name || resLabel(cur) : "—",
    line: lines[acc?.active_line ?? 0]?.name ?? "默认",
  };

  return (
    <>
      <div className="filters" style={{ marginBottom: 26 }}>
        {(Object.keys(PICK_TITLE) as PickKind[]).map((k) => (
          <FocusItem
            key={k}
            focusKey={`${fk}_${k}`}
            className="btn fx"
            onEnter={() => setOpen(k)}
          >
            <Icon n={PICK_ICON[k]} className="ic ic-btn" />
            {PICK_TITLE[k]}
            {/* 当前值挂在按钮里:三米外「字幕」两个字看不出现在是哪条轨。 */}
            <span style={PICK_VAL}>{val[k]}</span>
          </FocusItem>
        ))}
      </div>

      {err && <div style={{ color: "var(--danger)", fontSize: 18, marginBottom: 16 }}>{err}</div>}

      {open && (
        <FocusBoundary className="panel" focusKey={`${fk}_PANEL`} onBack={() => close(open)}>
          <div className="ph">{PICK_TITLE[open]}</div>
          <div className="scroll">
            <FocusColumn>
              {open === "sub" &&
                (subs.length === 0 ? (
                  <Dead text="该版本没有内封字幕" />
                ) : (
                  <>
                    <PickRow
                      on={picks.sub === "off"}
                      label="关闭字幕"
                      onEnter={() => {
                        onPicks({ ...picks, sub: "off" });
                        close("sub");
                      }}
                    />
                    {subs.map((s) => (
                      <PickRow
                        key={s.index}
                        on={subSel?.index === s.index}
                        label={streamLabel(s)}
                        right={s.is_default ? "默认" : undefined}
                        onEnter={() => {
                          onPicks({ ...picks, sub: s });
                          close("sub");
                        }}
                      />
                    ))}
                  </>
                ))}

              {open === "audio" &&
                (auds.length === 0 ? (
                  <Dead text="该版本没有音轨" />
                ) : (
                  auds.map((s) => (
                    <PickRow
                      key={s.index}
                      on={picks.audio?.index === s.index}
                      label={streamLabel(s)}
                      right={s.is_default ? "默认" : undefined}
                      onEnter={() => {
                        onPicks({ ...picks, audio: s });
                        close("audio");
                      }}
                    />
                  ))
                ))}

              {open === "ver" &&
                (vers.length === 0 ? (
                  <Dead text="没有可选的版本" />
                ) : (
                  vers.map((v) => (
                    <PickRow
                      key={v.id}
                      on={cur?.id === v.id}
                      label={v.name || resLabel(v)}
                      right={specLabel(v) || undefined}
                      onEnter={() => {
                        /* 换版本 = 换文件,原来选的那条音轨/字幕在新文件里不是同一条流,清掉。 */
                        onPicks({ ver: v, audio: null, sub: null });
                        close("ver");
                      }}
                    />
                  ))
                ))}

              {open === "line" &&
                (!acc || lines.length === 0 ? (
                  <Dead text="该服务器没有配置备用线路" />
                ) : (
                  lines.map((ln, i) => (
                    <PickRow
                      key={ln.id}
                      on={i === acc.active_line}
                      label={ln.name}
                      right={ln.remark ?? undefined}
                      onEnter={() => {
                        close("line");
                        setErr(null);
                        /* 切线路是**服务器级**的,不是本次播放级 —— 它会刷新会话地址。
                           乐观改本地态,失败再回滚,免得面板关了却看不出成没成。 */
                        setAcc({ ...acc, active_line: i });
                        void setActiveLine(acc.server, i).catch((e) => {
                          setAcc(acc);
                          setErr(e instanceof Error ? e.message : String(e));
                        });
                      }}
                    />
                  ))
                ))}
            </FocusColumn>
          </div>
        </FocusBoundary>
      )}
    </>
  );
}

function PickRow({
  on,
  label,
  right,
  onEnter,
}: {
  on: boolean;
  label: string;
  right?: string;
  onEnter: () => void;
}) {
  return (
    <FocusItem className={`pitem${on ? " on" : ""}`} onEnter={onEnter}>
      {label}
      <span className="r">{on ? "✓" : (right ?? "")}</span>
    </FocusItem>
  );
}

/** 面板里"这一项确实没得选"。不可聚焦 —— 能聚焦就是按下去没反应,比不能聚焦更糟。 */
function Dead({ text }: { text: string }) {
  return (
    <div className="pitem" style={{ color: "var(--tv-ink-3)" }}>
      {text}
    </div>
  );
}

/* ------------------------------------------------------------
   起播后落轨
   ------------------------------------------------------------ */

/** 把详情页选的音轨/字幕落到播放器。
 *
 *  ★ `play()` 只吃 mediaSourceId(版本),**没有**音轨/字幕参数 —— 那两样是播放器
 *    属性,只能起播后用 `set_track` 落。这是核层的契约,不是这里图省事。
 *
 *  ★ mpv 的 aid/sid 是**按类型从 1 起编号**的,而 Emby `StreamInfo.index` 是容器里的
 *    绝对序号,两者不通用(一个 1 视频+2 音轨+3 字幕的文件里,第一条字幕 index=3、sid=1)。
 *    所以先拿语言去 `tracks()` 里认人,语言不唯一才退回「同类型里的第几条」这个序号。
 *
 *  ★ 必须轮询:`play()` 在 mpv loadfile 发出去就返回了,这时 track-list 通常还是空的,
 *    直接 setTrack 会静默打空 —— 表现是"选了日语,放出来还是国语"。
 *
 *  ponytail: 轮询上限 2s(10×200ms),再慢就放弃并让核层的轨道偏好生效;
 *  真机上若发现慢盘/网盘首帧超过 2s,把 TRACK_TRIES 调大即可。 */
export async function applyPicks(v: MediaVersion | null, p: Picks): Promise<void> {
  // 一样都没挑 → 什么都别做,交给核层的 track_preference。抢着设反而覆盖掉用户的全局偏好。
  if (!p.audio && !p.sub) return;

  let list: Track[] = [];
  for (let i = 0; i < TRACK_TRIES && list.length === 0; i++) {
    list = await tracks().catch(() => []);
    if (list.length === 0) await new Promise((r) => setTimeout(r, 200));
  }

  // sid=no 是 mpv 关字幕的写法,不是某条轨的 id。
  if (p.sub === "off") await setTrack("sub", "no").catch(() => {});
  else if (p.sub) await setTrack("sub", mpvId(list, "sub", v, p.sub)).catch(() => {});
  if (p.audio) await setTrack("audio", mpvId(list, "audio", v, p.audio)).catch(() => {});
}

const TRACK_TRIES = 10;

function mpvId(list: Track[], kind: "sub" | "audio", v: MediaVersion | null, s: StreamInfo): string {
  /* 外挂字幕是核层 sub-add **追加**进 mpv 的,在 track-list 里排在所有内封轨之后 ——
     Emby 的 index 顺序和 mpv 的 sid 顺序根本对不上,下面那个序号兜底会选错轨。
     好在挂载时带了 title(核层按 display_title→language→「外挂字幕 N」生成),按它认最准。 */
  if (s.is_external) {
    const want = s.display_title || s.language || `外挂字幕 ${s.index}`;
    const hit = list.find((t) => t.kind === kind && t.title === want);
    if (hit) return hit.id;
  }
  const lang = (s.language ?? "").toLowerCase();
  const same = list.filter((t) => t.kind === kind && t.lang.toLowerCase() === lang);
  // 语言唯一时按语言认最稳;双日语音轨这种靠语言分不开,只能退回序号。
  if (lang && same.length === 1) return same[0].id;
  const ord = (v?.streams ?? []).filter((x) => x.type_ === s.type_).findIndex((x) => x.index === s.index);
  return String(ord >= 0 ? ord + 1 : 1);
}

/* ------------------------------------------------------------
   媒体信息块
   ------------------------------------------------------------ */

/** 当前版本的规格。**缺的字段整项不画** —— 编一个 "未知" 出来只是把噪音填满栅格。 */
export function MediaInfo({ v }: { v: MediaVersion | null }) {
  if (!v) return null;
  const vid = videoOf(v);
  const auds = v.streams.filter((s) => s.type_ === "Audio");
  const subs = v.streams.filter((s) => s.type_ === "Subtitle");

  const rows: [string, string][] = [];
  const push = (k: string, val: string | null | undefined) => {
    if (val) rows.push([k, val]);
  };
  push("分辨率", vid?.width && vid?.height ? `${vid.width}×${vid.height}` : fmtRes(vid?.height ?? null));
  push("编码", vid?.codec ? vid.codec.toUpperCase() : null);
  push("码率", fmtBitrate(v.bitrate ?? vid?.bitrate ?? null));
  push("体积", fmtSize(v.size_bytes));
  // 帧率服务端给的是 23.976023 这种,抹到两位;整数帧(24/25/30)不留小数尾巴。
  push("帧率", vid?.frame_rate ? `${+vid.frame_rate.toFixed(2)} fps` : null);
  // SDR 不是信息量,只有 HDR10/DV/HLG 这些才值一格。
  push(
    "动态范围",
    vid?.video_range && vid.video_range.toUpperCase() !== "SDR" ? vid.video_range : null,
  );
  push("封装", v.container ? v.container.toUpperCase() : null);

  if (rows.length === 0 && auds.length === 0 && subs.length === 0) return null;

  return (
    <div className="row">
      <div className="rowhead">
        <div className="t">媒体信息</div>
      </div>
      <div style={MI_GRID}>
        {rows.map(([k, val]) => (
          <div key={k}>
            <div style={MI_K}>{k}</div>
            <div style={MI_V}>{val}</div>
          </div>
        ))}
      </div>
      {auds.length > 0 && (
        <div style={MI_LIST}>
          <div style={MI_K}>音轨</div>
          {auds.map((s) => (
            <div key={s.index} style={MI_LINE}>
              {[
                s.language,
                s.codec.toUpperCase(),
                s.channel_layout ?? (s.channels ? `${s.channels} 声道` : null),
                s.profile,
              ]
                .filter((x): x is string => !!x)
                .join(" · ")}
            </div>
          ))}
        </div>
      )}
      {subs.length > 0 && (
        <div style={MI_LIST}>
          <div style={MI_K}>字幕</div>
          <div style={MI_LINE}>
            {subs
              .map((s) => s.language ?? s.display_title ?? s.codec.toUpperCase())
              .join(" · ")}
          </div>
        </div>
      )}
    </div>
  );
}

const PICK_VAL: React.CSSProperties = {
  color: "var(--tv-ink-3)",
  fontWeight: 500,
  maxWidth: 200,
  overflow: "hidden",
  textOverflow: "ellipsis",
  whiteSpace: "nowrap",
};

const MI_GRID: React.CSSProperties = {
  display: "grid",
  gridTemplateColumns: "repeat(4, minmax(0,1fr))",
  gap: "22px 32px",
  maxWidth: 1200,
};

const MI_K: React.CSSProperties = {
  fontSize: 15,
  letterSpacing: "0.1em",
  color: "var(--tv-ink-3)",
  fontWeight: 640,
};

const MI_V: React.CSSProperties = { fontSize: 21, fontWeight: 600, marginTop: 5 };

const MI_LIST: React.CSSProperties = { marginTop: 24, maxWidth: 1200 };

const MI_LINE: React.CSSProperties = { fontSize: 18, color: "var(--tv-ink-2)", marginTop: 6 };

