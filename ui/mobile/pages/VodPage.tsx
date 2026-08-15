import { useCallback, useEffect, useRef, useState } from "react";
import {
  type MediaCard,
  type MediaCategory,
  type MediaDetail,
  episodeEntry,
  sourceCatalog,
  sourceMediaDetail,
} from "@shared/api";
import { Icon } from "../app/icons";
import { useCtx } from "../app/ctx";
import Page from "../components/Page";

/* 影视资源站浏览页(手机端)。桌面端 ui/desktop/pages/VodPage.tsx 是同一套模型。

   **资源站不是网盘。** 分类是横条不是文件夹,翻页是滚到底自动续不是一个叫「下一页」
   的条目,「更新至17集」是海报上的角标不是标题的一部分,点一下就开不用双击。
   这一页按影视目录本来的样子做,和网盘文件页(NetdiskPage)彻底分开。 */

type Props = { categories: MediaCategory[]; onBack: () => void };

/** 一页 20 条,手机一屏放得下 9 张,首屏抓两页才够触发续拉。 */
const PREFILL_PAGES = 2;

export default function VodPage({ categories, onBack }: Props) {
  const { back } = useCtx();
  const [top, setTop] = useState<MediaCategory | null>(null);
  const [pick, setPick] = useState<MediaCategory | null>(null);
  const [q, setQ] = useState("");
  const [kw, setKw] = useState("");

  const [items, setItems] = useState<MediaCard[]>([]);
  const [page, setPage] = useState(0);
  const [hasMore, setHasMore] = useState(true);
  const [loading, setLoading] = useState(false);
  const [err, setErr] = useState("");
  const [open, setOpen] = useState<MediaCard | null>(null);

  const bodyRef = useRef<HTMLDivElement>(null);
  const sentinel = useRef<HTMLDivElement>(null);
  /* 换分类/换关键词发一个新 token;慢的那次请求回来时 token 对不上就整包丢掉,
     否则它会把旧分类的结果追加到新分类下面。 */
  const token = useRef(0);

  useEffect(() => {
    const t = window.setTimeout(() => setKw(q.trim()), 350);
    return () => window.clearTimeout(t);
  }, [q]);

  const catId = pick?.id ?? null;

  useEffect(() => {
    token.current += 1;
    setItems([]);
    setPage(0);
    setHasMore(true);
    setErr("");
    bodyRef.current?.closest(".pg-body")?.scrollTo({ top: 0 });
  }, [catId, kw]);

  const loadMore = useCallback(async () => {
    if (loading || !hasMore) return;
    const mine = token.current;
    const next = page + 1;
    setLoading(true);
    try {
      const r = await sourceCatalog(kw ? null : catId, kw || null, next);
      if (mine !== token.current) return;
      setItems((old) => {
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
  }, [loading, hasMore, page, catId, kw]);

  useEffect(() => {
    if (!err && hasMore && !loading && page < PREFILL_PAGES) void loadMore();
  }, [page, loading, hasMore, err, loadMore]);

  useEffect(() => {
    const el = sentinel.current;
    if (!el) return;
    // root 用视口(null):滚动容器是 Page 自己的 .pg-body,这一页不该再造一层。
    const io = new IntersectionObserver((es) => es[0]?.isIntersecting && void loadMore(), {
      rootMargin: "700px",
    });
    io.observe(el);
    return () => io.disconnect();
  }, [loadMore]);

  const subs = top?.children ?? [];

  return (
    <Page title="影视" onBack={onBack ?? back} enterKey={items.length ? "on" : null}>
      <div className="vod" ref={bodyRef}>
        <div className="sf">
          <Icon n="search" size={18} />
          <input
            value={q}
            onChange={(e) => setQ(e.target.value)}
            placeholder="搜片名"
            enterKeyHint="search"
            autoComplete="off"
          />
          {q && (
            <button type="button" className="sf-x" onClick={() => setQ("")} aria-label="清空">
              <Icon n="close" size={18} />
            </button>
          )}
        </div>

        {/* 搜索时分类整条让位 —— 搜的是全站,还显示着分类是骗人。 */}
        {!kw && (
          <div className="vod-cats">
            <div className="vod-catrow">
              <Chip on={!pick} onClick={() => { setTop(null); setPick(null); }}>最新</Chip>
              {categories.map((c) => (
                <Chip
                  key={c.id}
                  on={top?.id === c.id || pick?.id === c.id}
                  onClick={() => {
                    setTop(c);
                    // 有子分类的父级本身多半是空的(实测),点它先落到第一个子分类。
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
          <div className="empty">
            <b>打不开</b>
            <div className="dim">{err}</div>
            <button className="btn" onClick={() => void loadMore()}>重试</button>
          </div>
        ) : !items.length && !loading ? (
          <div className="empty"><div className="dim">{kw ? "没搜到" : "这个分类是空的"}</div></div>
        ) : (
          <div className="vod-grid">
            {items.map((m) => (
              <Card key={m.id} m={m} onOpen={() => setOpen(m)} />
            ))}
            {/* 骨架先出:等整页齐了才画,用户看到的就是一片空白 —— 那正是「慢」的观感。 */}
            {loading && Array.from({ length: 6 }, (_, i) => <span key={`s${i}`} className="vod-card skel" />)}
          </div>
        )}

        <div ref={sentinel} className="vod-sentinel" />
        {!hasMore && items.length > 0 && <div className="vod-end">到底了 · 共 {items.length} 部</div>}
        {err && items.length > 0 && (
          <div className="vod-end">
            没能继续加载
            <button className="btn ghost" onClick={() => void loadMore()}>重试</button>
          </div>
        )}
      </div>

      {open && <Sheet card={open} onClose={() => setOpen(null)} />}
    </Page>
  );
}

function Chip({ on, onClick, children }: { on: boolean; onClick: () => void; children: React.ReactNode }) {
  return (
    <button type="button" className={`vod-chip${on ? " on" : ""}`} onClick={onClick}>
      {children}
    </button>
  );
}

function Card({ m, onOpen }: { m: MediaCard; onOpen: () => void }) {
  return (
    <button type="button" className="vod-card" onClick={onOpen}>
      <span className="vod-art">
        {m.poster ? <img src={m.poster} alt="" loading="lazy" /> : <span className="vod-noart">{m.title.slice(0, 1)}</span>}
        {m.badge && <span className="vod-badge">{m.badge}</span>}
        {m.score && <span className="vod-score">{m.score}</span>}
      </span>
      {/* 标题一行,**只有标题**;年份是另一行的弱化信息。 */}
      <span className="vod-t">{m.title}</span>
      <span className="vod-sub">{m.year ?? ""}</span>
    </button>
  );
}

/* ── 详情:从底部升起的整屏卡 ─────────────────────────────────────── */

function Sheet({ card, onClose }: { card: MediaCard; onClose: () => void }) {
  const [d, setD] = useState<MediaDetail | null>(null);
  const [err, setErr] = useState("");
  const [line, setLine] = useState(0);
  const [expand, setExpand] = useState(false);
  const [busy, setBusy] = useState<string | null>(null);
  const { playSource } = useCtx();

  useEffect(() => {
    let alive = true;
    sourceMediaDetail(card.id)
      .then((x) => alive && setD(x))
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [card.id]);

  const cur = d?.lines[line];
  const meta = [d?.year, d?.area, d?.genre, d?.lang].filter(Boolean).join(" · ");

  async function play(i: number) {
    if (!cur) return;
    const ep = cur.episodes[i];
    setBusy(ep.id);
    try {
      /* ★ 交给 App 的 playSource:它起播成功后会导航到播放页。
         这一页曾经自己 invoke 完就 back(),画面在 webview 底下的 SurfaceView 上,
         被这张不透明的详情卡整个盖住 —— 用户看到的就是「没画面」。 */
      await playSource(episodeEntry(ep, `${d?.title ?? card.title} · ${ep.name}`));
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(null);
    }
  }

  return (
    <div className="vod-sheet" onClick={onClose}>
      <div className="vod-sheet-in" onClick={(e) => e.stopPropagation()}>
        {(d?.poster ?? card.poster) && (
          <div className="vod-bg" style={{ backgroundImage: `url(${d?.poster ?? card.poster})` }} />
        )}
        <button className="vod-x" onClick={onClose} aria-label="关闭">
          <Icon n="close" size={20} />
        </button>

        <div className="vod-head">
          <span className="vod-head-art">
            {(d?.poster ?? card.poster) && <img src={(d?.poster ?? card.poster)!} alt="" />}
          </span>
          <span className="vod-head-t">
            <b>{d?.title ?? card.title}</b>
            <span className="vod-meta">
              {(d?.badge ?? card.badge) && <i className="vod-tag">{d?.badge ?? card.badge}</i>}
              {(d?.score ?? card.score) && <i className="vod-tag score">{d?.score ?? card.score}</i>}
              <i className="dim">{meta}</i>
            </span>
          </span>
        </div>

        {d?.overview && (
          <p className={`vod-ov${expand ? " on" : ""}`} onClick={() => setExpand((v) => !v)}>
            {d.overview}
          </p>
        )}
        {d?.director && <div className="vod-crew"><b>导演</b>{d.director}</div>}
        {d?.actors && <div className="vod-crew"><b>主演</b>{d.actors}</div>}
        {err && <div className="vod-err">{err}</div>}

        {!d && !err ? (
          <div className="vod-eps">
            {Array.from({ length: 9 }, (_, i) => <span key={i} className="vod-ep skel" />)}
          </div>
        ) : d && !d.lines.length ? (
          <div className="empty"><div className="dim">这条资源没有可播放的地址</div></div>
        ) : d ? (
          <>
            {d.lines.length > 1 && (
              <div className="vod-catrow" style={{ marginTop: 14 }}>
                {d.lines.map((l, i) => (
                  <Chip key={l.id} on={i === line} onClick={() => setLine(i)}>
                    {l.name}（{l.episodes.length}）
                  </Chip>
                ))}
              </div>
            )}
            {cur && cur.episodes.length === 1 ? (
              // 电影别让人在一个只有一格的分集网格里找播放键。
              <button className="btn primary vod-play1" disabled={!!busy} onClick={() => void play(0)}>
                <Icon n="play" size={16} /> {busy ? "正在起播…" : "播放"}
              </button>
            ) : (
              <div className="vod-eps">
                {cur?.episodes.map((ep, i) => (
                  <button
                    key={ep.id}
                    className={`vod-ep${busy === ep.id ? " on" : ""}`}
                    disabled={!!busy}
                    onClick={() => void play(i)}
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
