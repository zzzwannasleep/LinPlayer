import { useEffect, useMemo, useRef, useState } from "react";
import { type Filters, type Item, getFilters, listItemsPage, views } from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { choreograph, haptic } from "../app/motion";
import Page from "../components/Page";
import Sheet from "../components/Sheet";
import { Cell, Empty, Grid, usePress } from "../components/ui";
import { useBlockCard } from "../components/BlockCard";

/* 媒体库。顶部 chip 行做排序/筛选,下面网格,滚到底续拉。

   ## 排序和筛选都走服务端
   服务端排的是整个库,本地排只能排到已加载的那一页 —— 翻页后顺序就乱了,
   而且**不报错**。分面(genres/tags/years)也来自服务端的分面端点,**不是从
   已加载条目里猜** —— 猜的话翻页前后能选的项会变,用户看到的是"筛选栏自己在动"。

   ## 触底翻页用 IntersectionObserver
   不监听 scroll:scroll 在安卓 WebView 上一秒几十次,每次算 scrollHeight 都掉帧;
   哨兵元素进视口才算一次。

   ## PAGE = 60(PC 是 120)
   手机一屏放 9 张,拉 120 张是卡自己。 */

const PAGE = 60;

const SORTS = [
  { id: "added", label: "加入时间", by: "DateCreated", order: "Descending" },
  /* 「更新时间」≠「加入时间」:DateCreated 是条目自己被建出来的时间(剧集 = 剧第一次入库),
     DateLastContentAdded 才是"这部剧最近更新了一集"。追剧的人要的是后者。 */
  { id: "updated", label: "更新时间", by: "DateLastContentAdded", order: "Descending" },
  { id: "name", label: "名称", by: "SortName", order: "Ascending" },
  { id: "rating", label: "评分", by: "CommunityRating", order: "Descending" },
  { id: "year", label: "年份", by: "ProductionYear", order: "Descending" },
] as const;

type SortId = (typeof SORTS)[number]["id"];
type F = { genres: string[]; tags: string[]; years: number[] };

export default function LibraryPage({ parentId, title }: { parentId?: string; title?: string }) {
  const { session, go, back, openItem } = useCtx();
  const [libs, setLibs] = useState<Item[] | null>(null);
  const [items, setItems] = useState<Item[] | null>(null);
  const [total, setTotal] = useState(0);
  const [err, setErr] = useState("");
  const [more, setMore] = useState(false);
  const [facets, setFacets] = useState<Filters | null>(null);
  const [sort, setSort] = useState<SortId>("added");
  const [sheet, setSheet] = useState(false);
  /** 已选筛选。★ 存在这里的是**已应用**的那份;面板里改的是一份草稿,
   *  点「看结果」才合并回来 —— 边选边刷新会在你还没选完时就翻好几次页。 */
  const [f, setF] = useState<F>({ genres: [], tags: [], years: [] });
  const gridRef = useRef<HTMLDivElement>(null);
  const sentinel = useRef<HTMLDivElement>(null);
  /* 长按屏蔽。★ 不传 onChanged:这一页**不移除**卡片(它是唯一能解除屏蔽的入口),
     只让 blockedNames 变一下让角标翻过来。 */
  const block = useBlockCard();

  const nFilter = f.genres.length + f.tags.length + f.years.length;
  const sortDef = SORTS.find((s) => s.id === sort)!;
  /* 查询条件的指纹。★ 用对象本身当依赖的话引用每次都新,会无限重拉。 */
  const key = useMemo(() => JSON.stringify([parentId, sort, f]), [parentId, sort, f]);

  const query = (startIndex: number) =>
    listItemsPage(parentId!, {
      startIndex,
      limit: PAGE,
      sortBy: sortDef.by,
      sortOrder: sortDef.order,
      genres: f.genres.length ? f.genres : undefined,
      tags: f.tags.length ? f.tags : undefined,
      years: f.years.length ? f.years : undefined,
    });

  useEffect(() => {
    if (parentId) return;
    views().then(setLibs).catch((e) => setErr(String(e)));
  }, [parentId]);

  useEffect(() => {
    if (!parentId) return;
    let alive = true;
    setItems(null);
    setErr("");
    query(0)
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
  }, [key]);

  useEffect(() => {
    if (!parentId) return;
    getFilters(parentId).then(setFacets).catch(() => {});
  }, [parentId]);

  /* 触底续拉 */
  useEffect(() => {
    const el = sentinel.current;
    if (!el || !parentId || !items || items.length >= total) return;
    const io = new IntersectionObserver(
      (es) => {
        if (!es[0].isIntersecting || more) return;
        setMore(true);
        query(items.length)
          .then((p) => setItems((x) => [...(x ?? []), ...p.items]))
          .catch(() => {})
          .finally(() => setMore(false));
      },
      { threshold: 0.1 },
    );
    io.observe(el);
    return () => io.disconnect();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, total, parentId, more, key]);

  useEffect(() => {
    choreograph(gridRef.current);
  }, [items]);

  /* ── 还没选库:先列库 ── */
  if (!parentId) {
    return (
      <Page title="媒体库" onBack={back} enterKey={libs}>
        {err ? (
          <Empty icon="grid" title="取不到媒体库列表" desc={err} />
        ) : libs === null ? (
          <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
        ) : !libs.length ? (
          <Empty
            icon="grid"
            title="这台服务器上一个媒体库都没有"
            desc="不是加载失败 —— 服务端返回的库列表就是空的。去 Emby 后台建一个库并扫描一次。"
          />
        ) : (
          <div className="cells">
            {libs.map((v) => (
              <Cell
                key={v.id}
                icon="grid"
                label={v.name}
                onClick={() => go({ page: "library", parentId: v.id, title: v.name })}
              />
            ))}
          </div>
        )}
      </Page>
    );
  }

  return (
    <Page title={title ?? "媒体库"} onBack={back} enterKey={items}>
      <div className="chips">
        {SORTS.map((s) => (
          <Chip
            key={s.id}
            on={s.id === sort}
            label={s.label}
            onClick={() => {
              haptic("sel");
              setSort(s.id);
            }}
          />
        ))}
        <Chip
          on={nFilter > 0}
          icon="filter"
          label={nFilter ? `筛选 ${nFilter}` : "筛选"}
          onClick={() => {
            haptic("sel");
            setSheet(true);
          }}
        />
      </div>

      {items !== null && (
        <div className="lp-total">
          共 {total.toLocaleString("zh-CN")} 项{nFilter > 0 ? " · 已筛选" : ""}
        </div>
      )}

      <div ref={gridRef}>
        {err ? (
          <Empty icon="grid" title="加载失败" desc={err} />
        ) : items === null ? (
          /* 骨架:九张。**不要画空网格** —— 空的看着像"这个库是空的" */
          <div className="grid">
            {Array.from({ length: 9 }, (_, i) => (
              <div className="card" key={i}>
                <div className="card-a ar-poster">
                  <div className="skel" />
                </div>
                <div className="skel-line" style={{ marginTop: 8, width: "78%" }} />
              </div>
            ))}
          </div>
        ) : !items.length ? (
          <Empty
            icon="inbox"
            title={nFilter ? "没有符合筛选的内容" : "这个库是空的"}
            desc={
              nFilter
                ? "换个条件试试,或者直接清空筛选看全部"
                : "服务端返回 0 条 —— 去 Emby 后台扫描一次这个库。"
            }
            action={nFilter ? { label: "清空筛选", on: () => setF({ genres: [], tags: [], years: [] }) } : undefined}
          />
        ) : (
          session && (
            <Grid
              items={items}
              session={session}
              onOpen={(it) => openItem(it)}
              /* 长按 = 屏蔽/解除屏蔽。媒体库**不过滤**屏蔽项(核层只滤首页/搜索/推荐/
                 播放记录),这一页是唯一能把它找回来解除的地方 —— 所以只打标不隐藏。 */
              onLongPress={block.onLongPress}
              blockedNames={block.blockedNames}
            />
          )
        )}
      </div>
      {block.dialog}

      {items !== null && items.length > 0 && (
        <div className="lp-more" ref={sentinel}>
          {items.length >= total ? (
            `已加载全部 ${total.toLocaleString("zh-CN")} 项`
          ) : (
            <>
              <Icon n="refresh" size={15} className="spin-ic" />
              加载更多…
            </>
          )}
        </div>
      )}

      <FilterSheet
        open={sheet}
        facets={facets}
        cur={f}
        onClose={() => setSheet(false)}
        onApply={(next) => {
          setF(next);
          setSheet(false);
        }}
      />
    </Page>
  );
}

function Chip({ on, label, icon, onClick }: { on?: boolean; label: string; icon?: string; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button type="button" className={`chip${on ? " on" : ""}`} ref={ref} onClick={onClick}>
      {icon ? <Icon n={icon} size={15} /> : null}
      {label}
    </button>
  );
}

function FilterSheet({
  open,
  facets,
  cur,
  onClose,
  onApply,
}: {
  open: boolean;
  facets: Filters | null;
  cur: F;
  onClose: () => void;
  onApply: (f: F) => void;
}) {
  const [local, setLocal] = useState<F>(cur);
  useEffect(() => {
    if (open) setLocal(cur);
  }, [open, cur]);

  const toggleStr = (k: "genres" | "tags", v: string) => {
    haptic("sel");
    setLocal((s) => ({ ...s, [k]: s[k].includes(v) ? s[k].filter((x) => x !== v) : [...s[k], v] }));
  };
  const toggleYear = (v: number) => {
    haptic("sel");
    setLocal((s) => ({ ...s, years: s.years.includes(v) ? s.years.filter((x) => x !== v) : [...s.years, v] }));
  };

  const nothing = facets && !facets.genres.length && !facets.tags.length && !facets.years.length;

  return (
    <Sheet open={open} onClose={onClose} title="筛选" snap>
      {!facets ? (
        <div className="pad dim" style={{ fontSize: 13 }}>正在问服务器有哪些可选项…</div>
      ) : (
        <>
          <Group label="类型" opts={facets.genres} sel={local.genres} on={(v) => toggleStr("genres", v)} />
          <Group label="标签" opts={facets.tags} sel={local.tags} on={(v) => toggleStr("tags", v)} />
          <Group
            label="年份"
            opts={facets.years.map(String)}
            sel={local.years.map(String)}
            on={(v) => toggleYear(Number(v))}
          />
          {nothing && (
            /* 这台服务器一个分面端点都没有(实测某些 fork 上 /Years、/Tags 是 404)。
               说清楚是服务端的事,别让人以为是这一页坏了。 */
            <div className="note-box" style={{ margin: "12px var(--pad)" }}>
              这台服务器没有提供筛选分面(相关端点返回 404),所以这里是空的。排序仍然可用。
            </div>
          )}
        </>
      )}
      <div className="sheet-acts">
        <button type="button" className="btn ghost" onClick={() => setLocal({ genres: [], tags: [], years: [] })}>
          清空
        </button>
        <button type="button" className="btn primary" onClick={() => onApply(local)}>
          看结果
        </button>
      </div>
    </Sheet>
  );
}

function Group({ label, opts, sel, on }: { label: string; opts: string[]; sel: string[]; on: (v: string) => void }) {
  if (!opts.length) return null;
  return (
    <div>
      <div className="opt-grp">{label}</div>
      <div className="chips">
        {opts.slice(0, 40).map((o) => (
          <button key={o} type="button" className={`chip${sel.includes(o) ? " on" : ""}`} onClick={() => on(o)}>
            {o}
          </button>
        ))}
      </div>
    </div>
  );
}

