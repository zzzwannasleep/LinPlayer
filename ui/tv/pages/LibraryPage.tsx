import { useCallback, useEffect, useRef, useState } from "react";
import { setFocus } from "@noriginmedia/norigin-spatial-navigation";
import {
  blockName,
  getFilters,
  listItemsPage,
  posterUrl,
  thumbUrl,
  views,
  type Item,
  type LoginResult,
} from "@shared/api";
import type { Route } from "../App";
import { onTvKey } from "../app/focus";
import { Icon } from "../app/icons";
import { FocusBoundary, FocusColumn, FocusItem } from "../components/Focus";
import { useBlockDialog } from "../components/BlockDialog";
import { useAsync } from "../lib/useAsync";

/** 媒体库(草稿 02)。先选库,再看该库的海报网格。

    ★ **标题下不显示线路,也不显示服务器地址**。「线路」这个概念只出现在线路管理页 ——
      它对"我现在要看哪部片"这个决定毫无帮助,却把当前用的域名摊在客厅电视上。
    ★ 筛选**不做横排 chip**:鼠标点击代价与距离无关,遥控器代价 = 焦点格数,
      横排 6 个 chip 够到最后一个要按 5 次。改成单入口 + 右侧悬浮面板,
      当前条件用**不可聚焦**的文字常驻在入口右边 —— 状态要看得见,但不该花按键去够。 */
export default function LibraryPage({
  session,
  go,
  parentId,
}: {
  session: LoginResult;
  go: (r: Route) => void;
  parentId?: string;
}) {
  /* 从导航轨进来是 undefined(先选库);从首页「查看全部」带 parentId 进来则直接进那个库。 */
  const [libId, setLibId] = useState<string | null>(parentId ?? null);
  const libs = useAsync(() => views(), []);

  if (!libId) {
    return <Picker libs={libs.data} session={session} onPick={setLibId} />;
  }

  const lib = (libs.data ?? []).find((l) => l.id === libId);
  return (
    /* key 换库即重置分页/筛选状态 —— 比在子组件里逐个 useEffect 清干净得多 */
    <Grid
      key={libId}
      libId={libId}
      title={lib?.name ?? "媒体库"}
      session={session}
      go={go}
      /* 带 parentId 直接进来的没有"上一层库列表"可退,返回键交给 App 退路由栈 */
      onBack={parentId ? null : () => setLibId(null)}
    />
  );
}

/* ------------------------------------------------------------
   库选择
   ------------------------------------------------------------ */

function Picker({
  libs,
  session,
  onPick,
}: {
  libs: Item[] | null;
  session: LoginResult;
  onPick: (id: string) => void;
}) {
  return (
    <FocusColumn focusKey="LIB_PICK">
      <div className="ptitle">媒体库</div>
      <div className="psub">选择一个库。</div>
      {!libs ? (
        <div className="grid wide c4">
          {[0, 1, 2, 3].map((k) => (
            <div key={k} className="cell">
              <div className="th sk" />
            </div>
          ))}
        </div>
      ) : (
        libs.length > 0 && (
          <div className="grid wide c4">
            {libs.map((lib, i) => (
              <FocusItem
                key={lib.id}
                className="cell fx"
                autoFocus={i === 0}
                onEnter={() => onPick(lib.id)}
              >
                <div className="th">
                  {lib.has_primary && <img src={thumbUrl(session, lib.id, 640)} alt="" />}
                </div>
                <div className="nm">{lib.name}</div>
              </FocusItem>
            ))}
          </div>
        )
      )}
    </FocusColumn>
  );
}

/* ------------------------------------------------------------
   库内容
   ------------------------------------------------------------ */

/** 排序档。服务端排序(listItemsPage 带 sortBy),不是本地排 ——
 *  本地排只能排已加载的那几页,翻到第三页顺序就乱了。 */
/** ★ 「更新时间」(DateLastContentAdded)和「加入日期」(DateCreated)**是两回事**,
 *  两个都要留:剧集的 DateCreated 是剧本身建条目的时间,一部老番今天更了新一集,
 *  按 DateCreated 排它还沉在底下;DateLastContentAdded 才是「最新一集入库的时间」。
 *  追更的人要的是后者 —— 这是用户 2026-07-21 点名要的。 */
const SORTS = [
  { id: "DateLastContentAdded", order: "Descending", label: "更新时间" },
  { id: "DateCreated", order: "Descending", label: "加入日期" },
  { id: "SortName", order: "Ascending", label: "名称" },
  /* 名称 Z→A:桌面有、TV 缺。同一个 sortBy 换 order,不是另一个字段。 */
  { id: "SortName", order: "Descending", label: "名称 Z→A" },
  { id: "CommunityRating", order: "Descending", label: "评分" },
  { id: "PremiereDate", order: "Descending", label: "上映日期" },
  { id: "ProductionYear", order: "Descending", label: "年份" },
] as const;

/** 一页 60 项 = 10 行。TV 上一屏只看得到两行多,再大就是白拉。 */
const PAGE = 60;

function Grid({
  libId,
  title,
  session,
  go,
  onBack,
}: {
  libId: string;
  title: string;
  session: LoginResult;
  go: (r: Route) => void;
  onBack: (() => void) | null;
}) {
  const [sort, setSort] = useState(0);
  const [genre, setGenre] = useState<string | null>(null);
  const [year, setYear] = useState<number | null>(null);
  const [open, setOpen] = useState(false);

  const [items, setItems] = useState<Item[] | null>(null);
  const [total, setTotal] = useState(0);

  /* 分页游标全走 ref:它们只驱动"下一次请求从哪开始",不需要引起重渲染,
     放 state 里反而会让 loadMore 的闭包每次都失效。 */
  const len = useRef(0);
  const busy = useRef(false);
  const done = useRef(false);
  /* 换筛选条件时旧请求可能还在飞。token 变了就把它的结果丢掉,
     否则上一套条件的第二页会追加到新结果后面。 */
  const token = useRef(0);

  const filters = useAsync(() => getFilters(libId), [libId]);

  const loadMore = useCallback(async () => {
    if (busy.current || done.current) return;
    busy.current = true;
    const t = token.current;
    try {
      const page = await listItemsPage(libId, {
        startIndex: len.current,
        limit: PAGE,
        sortBy: SORTS[sort].id,
        sortOrder: SORTS[sort].order,
        genres: genre ? [genre] : undefined,
        years: year != null ? [year] : undefined,
      });
      if (t !== token.current) return;
      len.current += page.items.length;
      setTotal(page.total);
      if (page.items.length < PAGE || len.current >= page.total) done.current = true;
      setItems((prev) => [...(prev ?? []), ...page.items]);
    } catch {
      /* 一页失败就停下,不重试 —— 机顶盒断网时重试只会把日志刷满,
         用户按返回重进一次就重来了。 */
      if (t === token.current) done.current = true;
      setItems((prev) => prev ?? []);
    } finally {
      if (t === token.current) busy.current = false;
    }
  }, [libId, sort, genre, year]);

  /* 条件变了 → 作废在飞的请求、清空、从头拉 */
  useEffect(() => {
    token.current += 1;
    len.current = 0;
    busy.current = false;
    done.current = false;
    setItems(null);
  }, [sort, genre, year]);

  useEffect(() => {
    if (items === null) void loadMore();
  }, [items, loadMore]);

  /* 预取:哨兵放在网格下方、往上吃掉一行的高度,所以焦点走到**倒数第二行**
     就已经把下一页拉上了。不用等到最后一行 —— TV 上焦点移动比滚轮快得多,
     等到最后一行用户会看见一段空白。
     ★ 用 IntersectionObserver 而不是"哪张卡被聚焦了":FocusItem 不往外抛 onFocus,
       而 IO 天然算上祖先的 overflow 裁剪和我们的 transform 位移。 */
  const sentinel = useRef<HTMLDivElement>(null);
  useEffect(() => {
    const el = sentinel.current;
    if (!el) return;
    const io = new IntersectionObserver((es) => {
      if (es.some((e) => e.isIntersecting)) void loadMore();
    });
    io.observe(el);
    return () => io.disconnect();
  }, [loadMore, items]);

  /* 面板一卸载,焦点就在树上没有落点了 —— 那是 TV 最经典的 P0(遥控器整个失灵)。
     显式送回筛选入口。 */
  const closePanel = () => {
    setOpen(false);
    void setFocus("LIB_FILTER");
  };

  /* 返回键:面板开着先关面板,否则退回库列表。
     ★ 这一页在路由栈上是顶层页,App 的 back() 到栈底就不动了,不会和这里打架。 */
  useEffect(
    () =>
      onTvKey((k) => {
        if (k !== "back") return;
        if (open) closePanel();
        else onBack?.();
      }),
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [open, onBack],
  );

  /* 长按屏蔽。★ 不传 onChanged:这一页不移除卡片(它是唯一能解除屏蔽的入口),
     只让 blockedNames 变一下让角标翻过来。 */
  const block = useBlockDialog();

  const cond = [
    SORTS[sort].label,
    genre ?? "全部类型",
    year != null ? `${year}` : "全部年份",
  ].join(" · ");

  return (
    <>
      <FocusColumn focusKey="LIB">
        <div style={{ display: "flex", alignItems: "baseline", gap: 20, marginBottom: 8 }}>
          <div className="ptitle" style={{ margin: 0 }}>
            {title}
          </div>
          {total > 0 && (
            <div style={{ fontSize: 19, color: "var(--tv-ink-3)" }}>
              {total.toLocaleString()} 项
            </div>
          )}
        </div>
        <div style={{ height: 26 }} />

        <div className="filters" style={{ alignItems: "center" }}>
          <FocusItem
            focusKey="LIB_FILTER"
            className="fchip on"
            style={{ height: 60, padding: "0 30px" }}
            autoFocus
            onEnter={() => setOpen(true)}
          >
            <Icon n="filter" className="ic" />
            筛选与排序
          </FocusItem>
          {/* 当前条件常驻但不可聚焦 */}
          <div style={{ fontSize: 17, color: "var(--tv-ink-3)" }}>{cond}</div>
        </div>

        {!items ? (
          <div className="grid poster c6">
            {[0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11].map((k) => (
              <div key={k} className="cell">
                <div className="th sk" />
              </div>
            ))}
          </div>
        ) : (
          items.length > 0 && (
            <div className="grid poster c6">
              {items.map((it) => (
                <FocusItem
                  key={it.id}
                  /* 长按 OK = 屏蔽/解除屏蔽。媒体库**不过滤**屏蔽项(核层只滤首页/搜索/
                     推荐/播放记录),这一页是唯一能找回来解除的地方 —— 只打标不隐藏。 */
                  className={`cell fx${block.blockedNames.has(blockName(it)) ? " blocked" : ""}`}
                  onEnter={() => go({ page: "detail", itemId: it.id })}
                  onLongEnter={() => block.openFor(it)}
                >
                  <div className="th">
                    {it.has_primary && (
                      <img src={posterUrl(session, it.id, 480)} alt="" loading="lazy" />
                    )}
                    {block.blockedNames.has(blockName(it)) && <div className="blk">已屏蔽</div>}
                  </div>
                  <div className="nm">{it.name}</div>
                  <div className="sub">{it.year ?? ""}</div>
                </FocusItem>
              ))}
            </div>
          )
        )}
        {/* 负 margin 把触发线提到最后一行之上一行 */}
        <div ref={sentinel} style={{ height: 1, marginTop: -440 }} />
      </FocusColumn>

      {open && (
        <FocusBoundary className="panel" focusKey="LIB_PANEL" onBack={closePanel}>
          <div className="ph">筛选与排序</div>
          <div className="scroll">
            <FocusColumn>
              <div className="grp">排序</div>
              {SORTS.map((s, i) => (
                /* key 用 label 不用 id:名称升/降序共用 id="SortName",
                   拿 id 当 key 会撞出重复 key(React 会静默复用错行)。 */
                <Row key={s.label} on={i === sort} label={s.label} onEnter={() => setSort(i)} />
              ))}

              <div className="grp">类型</div>
              <Row on={!genre} label="全部类型" onEnter={() => setGenre(null)} />
              {(filters.data?.genres ?? []).map((g) => (
                <Row key={g} on={genre === g} label={g} onEnter={() => setGenre(g)} />
              ))}

              <div className="grp">年份</div>
              <Row on={year == null} label="全部年份" onEnter={() => setYear(null)} />
              {(filters.data?.years ?? []).map((y) => (
                <Row key={y} on={year === y} label={`${y}`} onEnter={() => setYear(y)} />
              ))}
            </FocusColumn>
          </div>
        </FocusBoundary>
      )}

      {/* 屏蔽确认面板。和筛选面板互不相干,各自有自己的焦点边界和返回键处理。 */}
      {block.dialog}
    </>
  );
}

/** 面板里的一行。选中态只改字色 + 左侧竖条(.pitem.on),不换背景 ——
 *  背景是焦点态用的,两者同时用背景表示的话"我现在选到哪"就分不出来了。 */
function Row({
  on,
  label,
  onEnter,
}: {
  on: boolean;
  label: string;
  onEnter: () => void;
}) {
  return (
    <FocusItem className={`pitem${on ? " on" : ""}`} onEnter={onEnter}>
      {label}
      {on && <span className="r">✓</span>}
    </FocusItem>
  );
}
