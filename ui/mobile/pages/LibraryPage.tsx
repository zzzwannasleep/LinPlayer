import { useEffect, useMemo, useRef, useState } from "react";
import {
  type Filters,
  type Item,
  type LoginResult,
  getFilters,
  listItemsPage,
  views,
} from "@shared/api";
import Card from "../components/Card";
import Sheet from "../components/Sheet";
import { IconChevronRight, IconLibrary } from "../app/icons";

/* 媒体库。

   ## 与 PC 的取舍差异
   PC 顶部一条工具栏摆着「排序下拉 + 筛选下拉 + 网格/列表切换」。手机上这条摆不下,
   而且下拉面板在触摸屏上是灾难(要精确点中一个 28px 高的选项)。
   所以改成:**顶部两个 chip(排序 / 筛选)→ 各自打开一个 bottom sheet**。
   代价是多一次点击,换来的是每个选项都有 48dp 高、单手够得着。

   ## 排序和筛选都走服务端
   服务端排的是整个库,本地排只能排到已加载的那一页 —— 翻页后顺序就乱了,
   而且**不报错**。分面(genres/tags/years)也来自服务端的 /Items/Filters,不是从
   已加载条目里猜出来的。这两条与 PC 端一致,别为了"手机上少发一个请求"改掉。 */

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

/* 评分档:CommunityRating 是 0-10 连续值,没有分面可列(服务端给的 official_ratings
   是 PG-13 那种分级,不是评分)。所以给固定下限档,走 ratingMin —— 参数是真的,档位是我们定的。 */
const RATINGS = [9, 8, 7, 6] as const;

/** 一页 60。PC 是 120 —— 手机一屏只放得下 9 张,拉 120 张是给自己找卡。 */
const PAGE = 60;

export default function LibraryPage({
  session,
  parentId,
  onOpen,
  onPickView,
}: {
  session: LoginResult;
  /** 没给就先让用户挑一个库 */
  parentId?: string;
  onOpen: (it: Item) => void;
  onPickView: (v: Item) => void;
}) {
  const [libs, setLibs] = useState<Item[] | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  const [total, setTotal] = useState(0);
  const [more, setMore] = useState(false);
  const [err, setErr] = useState("");
  const [facets, setFacets] = useState<Filters | null>(null);

  const [sort, setSort] = useState<SortId>("added");
  const [fGenres, setFGenres] = useState<string[]>([]);
  const [fTags, setFTags] = useState<string[]>([]);
  const [fYears, setFYears] = useState<number[]>([]);
  const [fRating, setFRating] = useState<number | null>(null);
  const [sheet, setSheet] = useState<null | "sort" | "filter">(null);

  const filterKey = useMemo(
    () => JSON.stringify([fGenres, fTags, fYears, fRating]),
    [fGenres, fTags, fYears, fRating],
  );
  const activeFilters = fGenres.length + fTags.length + fYears.length + (fRating ? 1 : 0);

  useEffect(() => {
    if (parentId) return;
    views().then(setLibs).catch((e) => setErr(String(e)));
  }, [parentId, session.server]);

  useEffect(() => {
    if (!parentId) return;
    getFilters(parentId).then(setFacets).catch(() => setFacets(null));
  }, [parentId, session.server]);

  useEffect(() => {
    if (!parentId) return;
    let alive = true;
    setErr("");
    setItems(null);
    const s = SORTS.find((x) => x.id === sort)!;
    listItemsPage(parentId, {
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
  }, [parentId, session.server, sort, filterKey]);

  /* 触底加载更多。★ 用 IntersectionObserver 而不是监听 scroll:
     scroll 事件在安卓 WebView 上一秒能来几十次,每次都算一遍 scrollHeight 会掉帧。
     哨兵元素进视口才算一次,浏览器自己在合成线程上判。 */
  const sentinel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = sentinel.current;
    if (!el || !parentId || !items) return;
    const io = new IntersectionObserver(
      (es) => {
        if (!es[0].isIntersecting || more || items.length >= total) return;
        setMore(true);
        const s = SORTS.find((x) => x.id === sort)!;
        listItemsPage(parentId, {
          startIndex: items.length,
          limit: PAGE,
          sortBy: s.by,
          sortOrder: s.order,
          genres: fGenres.length ? fGenres : undefined,
          tags: fTags.length ? fTags : undefined,
          years: fYears.length ? fYears : undefined,
          ratingMin: fRating ?? undefined,
        })
          .then((p) => {
            setItems((cur) => (cur ? [...cur, ...p.items] : p.items));
            setTotal(p.total);
          })
          .catch(() => {})
          .finally(() => setMore(false));
      },
      // 提前一屏开始加载,让用户滚到底时内容已经在了
      { rootMargin: "600px" },
    );
    io.observe(el);
    return () => io.disconnect();
  }, [parentId, items, total, more, sort, filterKey, fGenres, fTags, fYears, fRating]);

  /* 还没选库 —— 先给库列表。PC 是左侧一条常驻库栏,手机上没有那个位置。 */
  if (!parentId) {
    if (err) return <div className="empty"><b>加载失败</b><div className="dim">{err}</div></div>;
    if (!libs) return <ListSkeleton />;
    return (
      <div className="cells" style={{ marginTop: 12 }}>
        {libs.map((v) => (
          <button key={v.id} type="button" className="cell" onClick={() => onPickView(v)}>
            <span className="cell-i"><IconLibrary size={20} /></span>
            <span className="cell-l">{v.name}</span>
            <IconChevronRight size={18} />
          </button>
        ))}
      </div>
    );
  }

  const sortLabel = SORTS.find((s) => s.id === sort)!.label;

  return (
    <div>
      <div className="chips lib-bar">
        <button type="button" className="chip" onClick={() => setSheet("sort")}>
          {sortLabel} ▾
        </button>
        <button
          type="button"
          className={`chip${activeFilters ? " on" : ""}`}
          onClick={() => setSheet("filter")}
        >
          筛选{activeFilters ? ` · ${activeFilters}` : ""} ▾
        </button>
        {total > 0 && <span className="lib-total dim">{total}</span>}
      </div>

      {err ? (
        <div className="empty"><b>加载失败</b><div className="dim">{err}</div></div>
      ) : !items ? (
        <GridSkeleton />
      ) : !items.length ? (
        <div className="empty"><div className="dim">这个筛选下没有内容</div></div>
      ) : (
        <>
          <div className="grid" style={{ marginTop: 12 }}>
            {items.map((it, i) => (
              <Card key={it.id} item={it} session={session} index={i} onOpen={onOpen} />
            ))}
          </div>
          <div ref={sentinel} className="lib-more">
            {more ? "加载中…" : items.length >= total ? `共 ${total} 项` : ""}
          </div>
        </>
      )}

      <Sheet open={sheet === "sort"} onClose={() => setSheet(null)} title="排序">
        <div className="opts">
          {SORTS.map((s) => (
            <button
              key={s.id}
              type="button"
              className={`opt${s.id === sort ? " on" : ""}`}
              onClick={() => {
                setSort(s.id);
                setSheet(null);
              }}
            >
              {s.label}
            </button>
          ))}
        </div>
      </Sheet>

      <Sheet open={sheet === "filter"} onClose={() => setSheet(null)} title="筛选" snap>
        <FilterBody
          facets={facets}
          genres={fGenres} setGenres={setFGenres}
          tags={fTags} setTags={setFTags}
          years={fYears} setYears={setFYears}
          rating={fRating} setRating={setFRating}
          onClear={() => {
            setFGenres([]);
            setFTags([]);
            setFYears([]);
            setFRating(null);
          }}
          onDone={() => setSheet(null)}
        />
      </Sheet>
    </div>
  );
}

function FilterBody({
  facets, genres, setGenres, tags, setTags, years, setYears, rating, setRating, onClear, onDone,
}: {
  facets: Filters | null;
  genres: string[]; setGenres: (v: string[]) => void;
  tags: string[]; setTags: (v: string[]) => void;
  years: number[]; setYears: (v: number[]) => void;
  rating: number | null; setRating: (v: number | null) => void;
  onClear: () => void; onDone: () => void;
}) {
  const toggle = <T,>(arr: T[], v: T, set: (x: T[]) => void) =>
    set(arr.includes(v) ? arr.filter((x) => x !== v) : [...arr, v]);

  return (
    <>
      {/* 分面来自服务端 /Items/Filters,不是从已加载条目里猜的 —— 猜的话
          翻页前后能选的类型会变,用户会觉得"筛选栏自己在动"。 */}
      <FilterGroup title="类型">
        {(facets?.genres ?? []).map((g) => (
          <button key={g} type="button" className={`chip${genres.includes(g) ? " on" : ""}`}
            onClick={() => toggle(genres, g, setGenres)}>{g}</button>
        ))}
      </FilterGroup>
      {/* 没有「地区」分面 —— Emby 不提供,用 Tags 兜。见 [[library-filter-panel]] */}
      <FilterGroup title="标签">
        {(facets?.tags ?? []).slice(0, 40).map((t) => (
          <button key={t} type="button" className={`chip${tags.includes(t) ? " on" : ""}`}
            onClick={() => toggle(tags, t, setTags)}>{t}</button>
        ))}
      </FilterGroup>
      <FilterGroup title="年份">
        {(facets?.years ?? []).slice(0, 40).map((y) => (
          <button key={y} type="button" className={`chip${years.includes(y) ? " on" : ""}`}
            onClick={() => toggle(years, y, setYears)}>{y}</button>
        ))}
      </FilterGroup>
      <FilterGroup title="评分不低于">
        {RATINGS.map((r) => (
          <button key={r} type="button" className={`chip${rating === r ? " on" : ""}`}
            onClick={() => setRating(rating === r ? null : r)}>{r} 分</button>
        ))}
      </FilterGroup>
      {/* 两个按钮吸在 sheet 底部:筛选项可能很长,滚到底才有按钮的话每次都要滑到头 */}
      <div className="sheet-acts">
        <button type="button" className="btn ghost" onClick={onClear}>清空</button>
        <button type="button" className="btn primary" onClick={onDone}>看结果</button>
      </div>
    </>
  );
}

function FilterGroup({ title, children }: { title: string; children: React.ReactNode }) {
  const arr = Array.isArray(children) ? children : [children];
  if (!arr.filter(Boolean).length) return null; // 服务端没给这一类分面就整组不画
  return (
    <div className="fgrp">
      <h3>{title}</h3>
      <div className="fchips">{children}</div>
    </div>
  );
}

function GridSkeleton() {
  return (
    <div className="grid" style={{ marginTop: 12 }}>
      {Array.from({ length: 9 }, (_, i) => (
        <div key={i} className="mcard-wrap">
          <div className="mcard ar-poster"><div className="mskel" /></div>
        </div>
      ))}
    </div>
  );
}

function ListSkeleton() {
  return (
    <div className="cells" style={{ marginTop: 12 }}>
      {Array.from({ length: 6 }, (_, i) => (
        <div key={i} className="cell"><span className="sk-t" /></div>
      ))}
    </div>
  );
}
