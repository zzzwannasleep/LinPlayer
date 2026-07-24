import { useEffect, useMemo, useState, type MouseEvent as ReactMouseEvent } from "react";
import {
  type Filters,
  type Item,
  type LoginResult,
  getFilters,
  listItemsPage,
  posterUrl,
  thumbUrl,
  views,
} from "@shared/api";
import { AdminMenuItems, useIsAdmin } from "../lib/admin";
import { useCardActions } from "../lib/cardActions";
import Poster from "../components/Poster";
import {
  IconChevronDown,
  IconChevronRight,
  IconLibrary,
  IconPlay,
  IconRefresh,
  IconSearch,
} from "../app/icons";
import "./LibraryPage.css";

type Props = {
  session: LoginResult;
  view: Item | null;
  onPickView: (v: Item) => void;
  onBack: () => void;
  onOpenItem: (it: Item) => void;
  onPlay: (it: Item) => void;
  onSearch: () => void;
};

/* 排序档位。by/order 是 Emby 的真值,直接透传给 list_items_page 让**服务端**排 ——
   服务端排的是整个库,本地排只能排到已加载的那一页,翻页后顺序就乱了。 */
const SORTS = [
  { id: "added", label: "加入时间", by: "DateCreated", order: "Descending" },
  /* 「更新时间」≠「加入时间」:DateCreated 是条目自己被建出来的时间(剧集 = 剧第一次入库),
     DateLastContentAdded 是**这部剧最近一集**入库的时间。追更要的是后者,两个都得留。 */
  { id: "updated", label: "更新时间", by: "DateLastContentAdded", order: "Descending" },
  { id: "premiere", label: "上映日期", by: "PremiereDate", order: "Descending" },
  { id: "name-asc", label: "名称 A→Z", by: "SortName", order: "Ascending" },
  { id: "name-desc", label: "名称 Z→A", by: "SortName", order: "Descending" },
  { id: "year", label: "年份", by: "ProductionYear", order: "Descending" },
  { id: "rating", label: "评分", by: "CommunityRating", order: "Descending" },
] as const;
type SortId = (typeof SORTS)[number]["id"];

/* 评分档:CommunityRating 是 0-10 连续值,没有「分面」可列(getFilters 给的
   official_ratings 是 PG-13 那种分级,不是评分)。所以这里给固定的下限档,
   走 list_items_page 的 ratingMin —— 参数是真的,档位是我们定的。 */
const RATINGS = [9, 8, 7, 6] as const;

const PAGE = 120;

/* 内联描边网格/列表图标(icons.tsx 里没有,禁 emoji)。
   收藏页要同一套视图切换图标 → 从这里 export 复用,不重画一遍。 */
export const IconGrid = ({ size = 15 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.7} aria-hidden>
    <rect x="3" y="3" width="7" height="7" rx="1.4" />
    <rect x="14" y="3" width="7" height="7" rx="1.4" />
    <rect x="3" y="14" width="7" height="7" rx="1.4" />
    <rect x="14" y="14" width="7" height="7" rx="1.4" />
  </svg>
);
export const IconRows = ({ size = 15 }: { size?: number }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" aria-hidden>
    <path d="M4 6h16M4 12h16M4 18h16" />
  </svg>
);

/** 数组型筛选的增删(多选分面共用)。 */
const toggle = <T,>(arr: T[], v: T): T[] =>
  arr.includes(v) ? arr.filter((x) => x !== v) : [...arr, v];

export default function LibraryPage({ session, view, onPickView, onBack, onOpenItem, onPlay, onSearch }: Props) {
  /* 库内**内容项**(电影/剧集)的卡片动作:收藏/标记已看/右键/悬停播放,走公共 hook。
     标记已看后就地把该卡 played 翻转 → 绿勾即时反显(本页自持 items 副本,得自己更新)。
     注意:下面另有一套 admin-only 的 ctx 是给**媒体库根**(电影/电视剧那种文件夹)用的 ——
     对整个库「标记已看」没意义,所以库列表右键仍只给管理员项,不并进这个 hook。 */
  const card = useCardActions(session, {
    onPlay,
    onChanged: (it, played) =>
      setItems((cur) => (cur ? cur.map((x) => (x.id === it.id ? { ...x, played } : x)) : cur)),
  });
  const [libs, setLibs] = useState<Item[] | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  /** 库里符合当前筛选的**总数**(不是已加载条数)—— 面包屑那个「· 1,284」要的就是它。 */
  const [total, setTotal] = useState(0);
  const [more, setMore] = useState(false);
  const [err, setErr] = useState("");
  const [reload, setReload] = useState(0);

  /** 真·服务端分面(类型/标签/年份/工作室/分级),不是从已加载条目里猜的。 */
  const [facets, setFacets] = useState<Filters | null>(null);
  const [facetErr, setFacetErr] = useState("");

  const [sort, setSort] = useState<SortId>("added");
  const [fGenres, setFGenres] = useState<string[]>([]);
  const [fTags, setFTags] = useState<string[]>([]);
  const [fYears, setFYears] = useState<number[]>([]);
  const [fRating, setFRating] = useState<number | null>(null);

  const [openDD, setOpenDD] = useState<null | "sort" | "filter">(null);
  const [layout, setLayout] = useState<"grid" | "list">("grid");
  const [toast, setToast] = useState("");

  /* 右键菜单。这页原本**一个右键菜单都没有**(库卡片和网格卡都没挂),
     管理员三项是它的第一批菜单项 —— 所以非管理员右键这里仍然什么都不弹,
     不画一个只有标题的空菜单。 */
  const admin = useIsAdmin(session.server);
  const [ctx, setCtx] = useState<{ x: number; y: number; id: string; name: string } | null>(null);
  const openCtx = (e: ReactMouseEvent, it: Item) => {
    if (!admin) return; // 目前菜单里只有管理员项,没权限就别拦浏览器右键
    e.preventDefault();
    setCtx({ x: e.clientX, y: e.clientY, id: it.id, name: it.name });
  };

  // 点外面 / 滚动 / Esc 关(同 DetailPage 套路)。
  useEffect(() => {
    if (!ctx) return;
    const close = () => setCtx(null);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && close();
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
      window.removeEventListener("keydown", onKey);
    };
  }, [ctx]);

  const nFilters = fGenres.length + fTags.length + fYears.length + (fRating != null ? 1 : 0);

  // 切库时清筛选/下拉状态。
  useEffect(() => {
    setFGenres([]);
    setFTags([]);
    setFYears([]);
    setFRating(null);
    setSort("added");
    setOpenDD(null);
  }, [view?.id]);

  useEffect(() => {
    if (!toast) return;
    const t = window.setTimeout(() => setToast(""), 2600);
    return () => window.clearTimeout(t);
  }, [toast]);

  // ---------------- 取数 ----------------
  const viewId = view?.id;
  // 数组不能直接进依赖数组(每次渲染都是新引用 → 死循环),压成字符串。
  const filterKey = `${fGenres.join("")}|${fTags.join("")}|${fYears.join("")}|${fRating}`;

  /** 库列表(view == null)。 */
  useEffect(() => {
    if (viewId) return;
    let alive = true;
    setErr("");
    setLibs(null);
    views()
      .then((vs) => alive && setLibs(vs))
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [viewId, session.server, reload]);

  /** 分面。跟着库/刷新走,不跟着筛选走 —— Emby 的 /Items/Filters 给的是整库分面,
      不随已选条件收窄,重复拉只是白费一个往返。 */
  useEffect(() => {
    if (!viewId) return;
    let alive = true;
    setFacets(null);
    setFacetErr("");
    getFilters(viewId)
      .then((f) => alive && setFacets(f))
      // 分面拉不到 → 筛选面板里明说,不静默变成「此库没有分面」。
      .catch((e) => alive && setFacetErr(String(e)));
    return () => {
      alive = false;
    };
  }, [viewId, session.server, reload]);

  /** 库内条目。排序/筛选/分页全在服务端做。 */
  useEffect(() => {
    if (!viewId) return;
    let alive = true;
    setErr("");
    setItems(null);
    const s = SORTS.find((x) => x.id === sort)!;
    listItemsPage(viewId, {
      startIndex: 0,
      limit: PAGE,
      sortBy: s.by,
      sortOrder: s.order,
      genres: fGenres.length ? fGenres : undefined,
      tags: fTags.length ? fTags : undefined,
      years: fYears.length ? fYears : undefined,
      ratingMin: fRating ?? undefined,
    })
      .then((p) => {
        if (!alive) return;
        setItems(p.items);
        setTotal(p.total);
      })
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [viewId, session.server, reload, sort, filterKey]);

  async function loadMore() {
    if (!viewId || !items || more || items.length >= total) return;
    setMore(true);
    const s = SORTS.find((x) => x.id === sort)!;
    try {
      const p = await listItemsPage(viewId, {
        startIndex: items.length,
        limit: PAGE,
        sortBy: s.by,
        sortOrder: s.order,
        genres: fGenres.length ? fGenres : undefined,
        tags: fTags.length ? fTags : undefined,
        years: fYears.length ? fYears : undefined,
        ratingMin: fRating ?? undefined,
      });
      setItems((cur) => (cur ? [...cur, ...p.items] : p.items));
      setTotal(p.total);
    } catch (e) {
      setToast(`加载更多失败:${e}`);
    } finally {
      setMore(false);
    }
  }

  // ---------------- 动作 ----------------
  /** 已选筛选胶囊(标注 10):[显示文本, 移除动作]。 */
  const chips = useMemo(() => {
    const out: { key: string; text: string; drop: () => void }[] = [];
    for (const g of fGenres)
      out.push({ key: `g:${g}`, text: `类型: ${g}`, drop: () => setFGenres((v) => toggle(v, g)) });
    for (const t of fTags)
      out.push({ key: `t:${t}`, text: `标签: ${t}`, drop: () => setFTags((v) => toggle(v, t)) });
    for (const y of fYears)
      out.push({ key: `y:${y}`, text: `年份: ${y}`, drop: () => setFYears((v) => toggle(v, y)) });
    if (fRating != null)
      out.push({ key: "r", text: `评分: ${fRating}+`, drop: () => setFRating(null) });
    return out;
  }, [fGenres, fTags, fYears, fRating]);

  /** 右键菜单本体。库列表和库内两个 return 都要画,提出来免得两份各改一半。 */
  const ctxMenu = ctx && (
    <div className="ctxmenu" style={{ left: ctx.x, top: ctx.y }} onClick={(e) => e.stopPropagation()}>
      <AdminMenuItems
        itemId={ctx.id}
        divider={false}
        onDone={(m) => {
          setToast(m);
          setCtx(null);
        }}
      />
    </div>
  );

  const clearAll = () => {
    setFGenres([]);
    setFTags([]);
    setFYears([]);
    setFRating(null);
  };

  // ---------------- 库列表(view == null) ----------------
  if (!view) {
    return (
      <>
        <div className="cbar">
          <span className="crumb">
            <b>媒体库</b>
          </span>
          <span className="push">
            <button className="searchbox" onClick={onSearch}>
              <IconSearch size={14} /> 搜索 / 聚合…
            </button>
            <button className="ibtn" title="刷新" onClick={() => setReload((k) => k + 1)}>
              <IconRefresh size={15} />
            </button>
          </span>
        </div>
        <div className="scroll">
          {err && <div className="empty">加载失败：{err}</div>}
          <div className="lib-grid">
            {libs == null
              ? Array.from({ length: 8 }).map((_, i) => (
                  <div className="lib-card" key={i}>
                    <div className="lib-cover skeleton lib-skel" />
                  </div>
                ))
              : libs.map((lib) => (
                  <button
                    key={lib.id}
                    type="button"
                    /* 不挂 enter+阶梯延迟:`.enter` 是 380ms 且 fill-mode:both(延迟期间
                       完全看不见),叠上 300ms 阶梯 = 最后一张卡 680ms 才出来。
                       和 Poster 同一个病,见那边的长注释。内容出现不能被动效挡着。 */
                    className="lib-card"
                    onClick={() => onPickView(lib)}
                    onContextMenu={(e) => openCtx(e, lib)}
                  >
                    <div className="lib-cover">
                      {lib.has_primary ? (
                        <img src={thumbUrl(session, lib.id, 720)} loading="lazy" />
                      ) : (
                        <IconLibrary size={38} />
                      )}
                    </div>
                    <div className="lib-name">{lib.name}</div>
                  </button>
                ))}
          </div>
          {libs != null && libs.length === 0 && !err && <div className="empty">没有可用的媒体库</div>}
          <div style={{ height: 40 }} />
        </div>
        {ctxMenu}
        {toast && <div className="toast">{toast}</div>}
      </>
    );
  }

  // ---------------- 库内(view != null) ----------------
  const sortLabel = SORTS.find((s) => s.id === sort)!.label;

  /** 分面小节(多选)。空分面不画小节 —— 画个空标题比不画更让人以为坏了。 */
  const facetSec = <T extends string | number>(
    label: string,
    all: T[],
    chosen: T[],
    set: (fn: (v: T[]) => T[]) => void,
  ) =>
    all.length === 0 ? null : (
      <div key={label}>
        <div className="lib-dd-sec">{label}</div>
        {all.map((v) => {
          const on = chosen.includes(v);
          return (
            <div key={String(v)} className={`li${on ? " on" : ""}`} onClick={() => set((cur) => toggle(cur, v))}>
              <span className="chk" />
              {String(v)}
            </div>
          );
        })}
      </div>
    );

  return (
    <>
      <div className="cbar">
        {/* 背板必须在 cbar 里面 —— 放外面会盖住整条顶栏(排序/筛选都点不动),见 .lib-ddscrim 注释。 */}
        {openDD && <div className="lib-ddscrim" onClick={() => setOpenDD(null)} />}
        <span className="crumb">
          <button className="crumb-btn" onClick={onBack}>
            媒体库
          </button>
          <span className="sep">›</span>
          <b>{view.name}</b>
          {/* 总数用服务端的 total,不是 items.length —— items 只是已加载的那几页。 */}
          {items != null && <span className="count">· {total.toLocaleString()}</span>}
        </span>
        <span className="push">
          <button className="searchbox" onClick={onSearch}>
            <IconSearch size={14} /> 库内搜索…
          </button>

          {/* 排序(锚定下拉) */}
          <span className="lib-ddwrap">
            <button
              className="pill"
              onClick={() => setOpenDD((d) => (d === "sort" ? null : "sort"))}
            >
              排序 · {sortLabel} <IconChevronDown size={13} />
            </button>
            {openDD === "sort" && (
              <div className="dd lib-dd">
                {SORTS.map((s) => (
                  <div
                    key={s.id}
                    className={`li${sort === s.id ? " on" : ""}`}
                    onClick={() => {
                      setSort(s.id);
                      setOpenDD(null);
                    }}
                  >
                    <span className="rad" />
                    {s.label}
                  </div>
                ))}
              </div>
            )}
          </span>

          {/* 筛选(锚定下拉,类型/标签/年份/评分 —— 标注 9) */}
          <span className="lib-ddwrap">
            <button
              className={`pill${nFilters ? " on" : ""}`}
              onClick={() => setOpenDD((d) => (d === "filter" ? null : "filter"))}
            >
              筛选{nFilters ? ` · ${nFilters}` : ""} <IconChevronDown size={13} />
            </button>
            {openDD === "filter" && (
              <div className="dd lib-dd">
                {facetErr ? (
                  <div className="lib-dd-note">分面加载失败:{facetErr}</div>
                ) : facets == null ? (
                  <div className="lib-dd-note">加载分面…</div>
                ) : (
                  <>
                    {/* 分面为空的小节自己不画(facetSec 返回 null)。评分不依赖分面,恒在 ——
                        所以没有「整个筛选面板都空」这种状态,不需要那句「此库无分面」。 */}
                    {facetSec("类型", facets.genres, fGenres, setFGenres)}
                    {facetSec("标签", facets.tags, fTags, setFTags)}
                    {/* 年份倒序:新片在最上面,不然 1920 打头要滚一百多行才看到今年。 */}
                    {facetSec("年份", [...facets.years].sort((a, b) => b - a), fYears, setFYears)}
                    <div className="lib-dd-sec">评分</div>
                    {RATINGS.map((r) => (
                      <div
                        key={r}
                        className={`li${fRating === r ? " on" : ""}`}
                        onClick={() => setFRating((cur) => (cur === r ? null : r))}
                      >
                        <span className="rad" />
                        {r} 分以上
                      </div>
                    ))}
                  </>
                )}
              </div>
            )}
          </span>

          {/* 网格/列表切换 */}
          <button
            className="ibtn"
            title={layout === "grid" ? "切换列表" : "切换网格"}
            onClick={() => setLayout((l) => (l === "grid" ? "list" : "grid"))}
          >
            {layout === "grid" ? <IconRows /> : <IconGrid />}
          </button>
          <button className="ibtn" title="刷新" onClick={() => setReload((k) => k + 1)}>
            <IconRefresh size={15} />
          </button>
        </span>
      </div>

      <div className="scroll">
        {/* 已选筛选胶囊行(标注 10) */}
        {chips.length > 0 && (
          <div className="chipbar" style={{ margin: "2px 18px 6px" }}>
            {chips.map((c) => (
              <span className="genre" key={c.key}>
                {c.text}
                <span className="x" onClick={c.drop}>
                  ✕
                </span>
              </span>
            ))}
            <span className="genre" style={{ cursor: "pointer" }} onClick={clearAll}>
              清除
            </span>
          </div>
        )}

        {err && <div className="empty">加载失败：{err}</div>}

        {items == null ? (
          <div className="dense-grid">
            {Array.from({ length: 14 }).map((_, i) => (
              <div className="pcard poster-ar skeleton" key={i} />
            ))}
          </div>
        ) : items.length === 0 ? (
          <div className="empty">{nFilters ? "没有符合筛选的内容" : "这个库还没有内容"}</div>
        ) : layout === "grid" ? (
          <div className="dense-grid">
            {/* 卡片:点=进详情;悬停=▶/✓/♥;右键=标记已看/收藏/管理员项(2026-07-24 用户定,四网格统一)。 */}
            {items.map((it) => (
              <Poster key={it.id} item={it} session={session} onOpen={onOpenItem} {...card.cardProps(it)} />
            ))}
          </div>
        ) : (
          <div className="lib-list">
            {items.map((it) => (
              <button
                className="lib-row enter"
                key={it.id}
                onClick={() => onOpenItem(it)}
                onContextMenu={(e) => card.openCtx(e, it)}
              >
                <span className="lib-row-thumb">
                  {it.has_primary ? (
                    <img src={posterUrl(session, it.id, 120)} loading="lazy" />
                  ) : (
                    <IconPlay size={16} />
                  )}
                </span>
                <span className="lib-row-name">{it.name}</span>
                <IconChevronRight size={15} className="lib-row-cv" />
              </button>
            ))}
          </div>
        )}

        {/* 分页:服务端一页 120,不做无限滚动 —— 一次拉完整库正是这页原来的毛病。 */}
        {items != null && items.length < total && (
          <div className="lib-more">
            <button className="btn" disabled={more} onClick={() => void loadMore()}>
              {more ? "加载中…" : `加载更多 · 还有 ${(total - items.length).toLocaleString()} 项`}
            </button>
          </div>
        )}
        <div style={{ height: 40 }} />
      </div>

      {/* 内容项的右键菜单 + 卡片动作 toast 走 hook;下面那条 toast 仍留给「加载更多失败」。 */}
      {card.menu}
      {card.toastNode}
      {toast && <div className="toast">{toast}</div>}
    </>
  );
}
