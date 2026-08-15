import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  type MediaCategory,
  type MediaCard,
  type MediaDetail,
  type SourceEntry,
  episodeEntry,
  sourceCatalog,
  sourceMediaDetail,
} from "@shared/api";
import { IconChevronLeft, IconPlay, IconRefresh, IconSearch } from "../app/icons";
import "./VodPage.css";

/* ============================================================
   影视资源站浏览页。

   **这一页存在的理由,就是「资源站不是网盘」。** 上一版把资源站塞进了网盘文件页,
   于是每样东西都得伪装成文件:分类伪装成文件夹、翻页伪装成一个叫「下一页」的文件夹、
   「更新至17集」只能拼进文件名、打开要双击。全错。这一页按影视目录本来的样子做:

     · 分类是**顶部的横条**,不是网格里的卡片
     · 翻页是**滚到底自动续**,不是列表里的一个条目
     · 角标/年份/评分**各占各的位置**,标题里只有标题
     · **单击**就打开,不是双击(海报墙不是文件管理器)
     · 详情在**同一页**盖上来 —— 关掉时网格的滚动位置还在,不用重新滚回去

   数据来自核层的影视目录三件套(source_categories / source_catalog /
   source_media_detail),任何实现了它们的源都能用这一页,不只是资源站插件。
   ============================================================ */

type Props = {
  categories: MediaCategory[];
  onBack: () => void;
  title: string;
  /** 起播。**必须走 App 的 playSource**(它先把独立播放窗拉起来,视频窗焊在那个窗背面);
   *  页面自己 invoke source_play 的话 mpv 是在放,但视频窗还藏着 —— 只有声音没有画面。 */
  onPlay: (entry: SourceEntry) => void | Promise<void>;
};

/** 一次请求 20 条,首屏铺不满一屏就会没有滚动条 → 触发不了续拉。所以首次多抓几页。 */
const PREFILL_PAGES = 2;

export default function VodPage({ categories, onBack, title, onPlay }: Props) {
  // 选中的分类。null = 最新(不带 t 参数)。二级选中时 top 仍指向它的父级,好让横条保持展开。
  const [top, setTop] = useState<MediaCategory | null>(null);
  const [pick, setPick] = useState<MediaCategory | null>(null);
  const [query, setQuery] = useState("");
  const [debounced, setDebounced] = useState("");

  const [items, setItems] = useState<MediaCard[]>([]);
  const [page, setPage] = useState(0);
  const [hasMore, setHasMore] = useState(true);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState("");
  const [detail, setDetail] = useState<{ id: string; card: MediaCard } | null>(null);

  const scrollRef = useRef<HTMLDivElement>(null);
  const sentinel = useRef<HTMLDivElement>(null);
  /* 每次换分类/换关键词给一个新的 token。异步返回时 token 对不上就整包丢掉 ——
     不做这个的话,慢的那次请求会在你已经换了分类之后把旧结果追加进来。 */
  const token = useRef(0);

  useEffect(() => {
    const t = window.setTimeout(() => setDebounced(query.trim()), 350);
    return () => window.clearTimeout(t);
  }, [query]);

  const catId = pick?.id ?? null;

  /** 换条件:清空重来,并把滚动条拉回顶部。 */
  useEffect(() => {
    token.current += 1;
    setItems([]);
    setPage(0);
    setHasMore(true);
    setErr("");
    scrollRef.current?.scrollTo({ top: 0 });
  }, [catId, debounced]);

  const loadMore = useCallback(async () => {
    if (loading || !hasMore) return;
    const mine = token.current;
    const next = page + 1;
    setLoading(true);
    try {
      const r = await sourceCatalog(debounced ? null : catId, debounced || null, next);
      if (mine !== token.current) return; // 条件已经换了,这包是过期货
      setItems((old) => {
        // 站点偶尔会在相邻页里重复同一条,直接 append 会让 React 的 key 撞车。
        const seen = new Set(old.map((x) => x.id));
        return [...old, ...r.items.filter((x) => !seen.has(x.id))];
      });
      setPage(next);
      setHasMore(r.has_more);
      setErr("");
    } catch (e) {
      if (mine === token.current) setErr(String(e));
    } finally {
      if (mine === token.current) setLoading(false);
    }
  }, [loading, hasMore, page, catId, debounced]);

  // 首屏:预抓几页,否则内容铺不满一屏 → 没有滚动 → 无限下拉永远不会被触发。
  useEffect(() => {
    if (page === 0 && !loading && hasMore && !err) void loadMore();
    else if (page > 0 && page < PREFILL_PAGES && !loading && hasMore && !err) void loadMore();
  }, [page, loading, hasMore, err, loadMore]);

  // 滚到底自动续。IntersectionObserver 而不是 onScroll:不用自己算阈值,也不会每帧回调。
  useEffect(() => {
    const el = sentinel.current;
    const root = scrollRef.current;
    if (!el || !root) return;
    const io = new IntersectionObserver(
      (es) => {
        if (es[0]?.isIntersecting) void loadMore();
      },
      { root, rootMargin: "600px" }, // 提前 600px 开始拉,滚到底时下一批已经在了
    );
    io.observe(el);
    return () => io.disconnect();
  }, [loadMore]);

  const subs = top?.children ?? [];

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>{title}</b>
        </span>
        <span className="push">
          <label className="searchbox">
            <IconSearch size={14} />
            <input
              className="vod-search"
              placeholder="搜片名…"
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </label>
          <button className="ibtn" title="刷新" onClick={() => setPick((p) => (p ? { ...p } : null))}>
            <IconRefresh size={15} />
          </button>
          <button className="ibtn" title="返回服务器" onClick={onBack}>
            <IconChevronLeft size={16} />
          </button>
        </span>
      </div>

      <div className="scroll" ref={scrollRef}>
        <div className="vod-body">
          {/* 分类横条。搜索时整条让位 —— 搜的是全站,再显示分类是骗人。 */}
          {!debounced && (
            <div className="vod-cats">
              <div className="vod-catrow">
                <Chip on={!pick} onClick={() => { setTop(null); setPick(null); }}>
                  最新
                </Chip>
                {categories.map((c) => (
                  <Chip
                    key={c.id}
                    on={top?.id === c.id || pick?.id === c.id}
                    onClick={() => {
                      setTop(c);
                      // 有子分类的父级本身多半是空的(实测 360zy 的 t=2 total=0),
                      // 所以点它先落到第一个子分类,而不是把用户扔进一个空页。
                      setPick(c.children.length ? c.children[0] : c);
                    }}
                  >
                    {c.name}
                  </Chip>
                ))}
              </div>
              {subs.length > 0 && (
                <div className="vod-catrow sub">
                  {subs.map((s) => (
                    <Chip key={s.id} on={pick?.id === s.id} onClick={() => setPick(s)}>
                      {s.name}
                    </Chip>
                  ))}
                </div>
              )}
            </div>
          )}

          {err && items.length === 0 ? (
            <div className="empty vod-empty">
              <b>打不开</b>
              <div className="vod-err">{err}</div>
              <button className="btn" onClick={() => void loadMore()}>
                重试
              </button>
            </div>
          ) : items.length === 0 && !loading ? (
            <div className="empty">{debounced ? "没搜到。" : "这个分类是空的。"}</div>
          ) : (
            <div className="vod-grid">
              {items.map((m) => (
                <Card key={m.id} m={m} onOpen={() => setDetail({ id: m.id, card: m })} />
              ))}
              {/* 骨架:**先出格子再填内容**。等整页齐了才画的话,用户看到的是一片空白,
                  那正是「慢」的观感来源 —— 网络时间没变,但空白变成了正在长出来的东西。 */}
              {loading && Array.from({ length: 10 }, (_, i) => <div key={`sk${i}`} className="vod-card skel" />)}
            </div>
          )}

          <div ref={sentinel} className="vod-sentinel" />
          {!hasMore && items.length > 0 && <div className="vod-end">到底了 · 共 {items.length} 部</div>}
          {err && items.length > 0 && (
            <div className="vod-end vod-end-err">
              没能继续加载:{err}
              <button className="btn ghost" onClick={() => void loadMore()}>
                重试
              </button>
            </div>
          )}
        </div>
      </div>

      {detail && (
        <Detail id={detail.id} card={detail.card} onPlay={onPlay} onClose={() => setDetail(null)} />
      )}
    </>
  );
}

function Chip({ on, onClick, children }: { on: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button type="button" className={`vod-chip${on ? " on" : ""}`} onClick={onClick}>
      {children}
    </button>
  );
}

/** 一张卡。**单击就开** —— 这是海报墙不是文件管理器。 */
function Card({ m, onOpen }: { m: MediaCard; onOpen: () => void }) {
  return (
    <button type="button" className="vod-card" onClick={onOpen} title={m.title}>
      <span className="vod-art">
        {m.poster ? <img src={m.poster} alt="" loading="lazy" /> : <span className="vod-noart">{m.title.slice(0, 1)}</span>}
        {m.badge && <span className="vod-badge">{m.badge}</span>}
        {m.score && <span className="vod-score">{m.score}</span>}
        <span className="vod-hover">
          <IconPlay size={18} />
        </span>
      </span>
      {/* 标题一行,**只有标题**。年份是另一行的弱化信息,不是标题的一部分。 */}
      <span className="vod-t">{m.title}</span>
      <span className="vod-sub">{m.year ?? ""}</span>
    </button>
  );
}

/* ── 详情:盖在同一页上 ────────────────────────────────────────────── */

function Detail({
  id,
  card,
  onPlay,
  onClose,
}: {
  id: string;
  card: MediaCard;
  onPlay: (entry: SourceEntry) => void | Promise<void>;
  onClose: () => void;
}) {
  const [d, setD] = useState<MediaDetail | null>(null);
  const [err, setErr] = useState("");
  const [line, setLine] = useState(0);
  const [expand, setExpand] = useState(false);
  const [playing, setPlaying] = useState<string | null>(null);

  useEffect(() => {
    let alive = true;
    setD(null);
    setErr("");
    sourceMediaDetail(id)
      .then((x) => alive && setD(x))
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [id]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  const cur = d?.lines[line];
  const meta = useMemo(
    () => [d?.year, d?.area, d?.genre, d?.lang].filter(Boolean).join(" · "),
    [d],
  );

  async function play(epIdx: number) {
    if (!cur) return;
    const ep = cur.episodes[epIdx];
    setPlaying(ep.id);
    try {
      await onPlay(episodeEntry(ep, `${d?.title ?? card.title} · ${ep.name}`));
    } catch (e) {
      setErr(String(e));
    } finally {
      setPlaying(null);
    }
  }

  return (
    <div className="vod-sheet" onClick={onClose}>
      <div className="vod-sheet-in" onClick={(e) => e.stopPropagation()}>
        {/* 背景是这部片自己的海报虚化铺开 —— 一张彩色大图配一层死灰 UI 是最廉价的观感。 */}
        {(d?.poster ?? card.poster) && (
          <div className="vod-bg" style={{ backgroundImage: `url(${d?.poster ?? card.poster})` }} />
        )}
        <button className="vod-x" onClick={onClose} aria-label="关闭">
          ✕
        </button>

        <div className="vod-head">
          <div className="vod-head-art">
            {(d?.poster ?? card.poster) ? <img src={(d?.poster ?? card.poster)!} alt="" /> : null}
          </div>
          <div className="vod-head-t">
            <h2>{d?.title ?? card.title}</h2>
            <div className="vod-meta">
              {(d?.badge ?? card.badge) && <span className="vod-tag">{d?.badge ?? card.badge}</span>}
              {(d?.score ?? card.score) && <span className="vod-tag score">{d?.score ?? card.score} 分</span>}
              <span>{meta}</span>
            </div>
            {d?.overview && (
              <p className={`vod-ov${expand ? " on" : ""}`} onClick={() => setExpand((v) => !v)} title="点开/收起">
                {d.overview}
              </p>
            )}
            {d?.director && <div className="vod-crew"><b>导演</b>{d.director}</div>}
            {d?.actors && <div className="vod-crew"><b>主演</b>{d.actors}</div>}
          </div>
        </div>

        {err && <div className="vod-err">{err}</div>}

        {!d && !err ? (
          <div className="vod-eps-skel">
            {Array.from({ length: 12 }, (_, i) => (
              <span key={i} className="skel" />
            ))}
          </div>
        ) : d && d.lines.length === 0 ? (
          <div className="empty">这条资源没有可播放的地址。</div>
        ) : d ? (
          <>
            {d.lines.length > 1 && (
              <div className="vod-lines">
                {d.lines.map((l, i) => (
                  <Chip key={l.id} on={i === line} onClick={() => setLine(i)}>
                    {l.name}（{l.episodes.length}）
                  </Chip>
                ))}
              </div>
            )}
            {cur && cur.episodes.length === 1 ? (
              // 电影:别让人在一个只有一格的「分集网格」里找播放按钮。
              <button className="btn primary vod-play1" disabled={!!playing} onClick={() => void play(0)}>
                <IconPlay size={15} /> {playing ? "正在起播…" : "播放"}
              </button>
            ) : (
              <div className="vod-eps">
                {cur?.episodes.map((ep, i) => (
                  <button
                    key={ep.id}
                    className={`vod-ep${playing === ep.id ? " on" : ""}`}
                    disabled={!!playing}
                    onClick={() => void play(i)}
                    title={ep.name}
                  >
                    {ep.name}
                  </button>
                ))}
              </div>
            )}
          </>
        ) : null}
      </div>
    </div>
  );
}
