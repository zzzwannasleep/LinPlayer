import { useEffect, useMemo, useState } from "react";
import { type Item, type LoginResult, listFavorites, posterUrl } from "@shared/api";
import { useCardActions } from "../lib/cardActions";
import Poster from "../components/Poster";
// 视图切换图标复用媒体库那套(icons.tsx 没有网格/列表图标且不许改,不重画一遍)。
// 顺带把 LibraryPage.css 显式带进来:收藏页复用 .lib-ddwrap/.lib-dd/.lib-list/.lib-row —— 草稿说收藏页「和媒体库同款」。
import { IconGrid, IconRows } from "./LibraryPage";
import "./LibraryPage.css";
import { IconChevronDown, IconChevronRight, IconPlay } from "../app/icons";

type Props = {
  session: LoginResult;
  onOpenItem: (it: Item) => void;
  onPlay: (it: Item) => void;
};

// 排序逻辑单独放一个模块 —— 纯逻辑,node 可以直跑真模块做自检(见 favorites-sort.test.mjs)。
import { SORTS, type SortId, sortItems } from "@shared/favorites-sort";

/* 视图偏好持久化。纯前端渲染参数 → localStorage,不进核层 Prefs(和主题/弹幕那几项一个口径)。
   一个 key 存三项,省得开三个。存坏了就当没存过。 */
const VIEW_KEY = "lp.fav.view";
type View = { sort: SortId; asc: boolean; layout: "grid" | "list" };
function loadView(): View {
  const def: View = { sort: "name", asc: true, layout: "grid" };
  try {
    const v = { ...def, ...JSON.parse(localStorage.getItem(VIEW_KEY) ?? "{}") } as View;
    // 档位表以后可能改名,认不出的档回默认,别拿脏值去打服务端。
    return SORTS.some((s) => s.id === v.sort) ? v : def;
  } catch {
    return def;
  }
}

/** 收藏页(草稿 PAGE 10):和媒体库同款密集海报网格。
    卡片只有一个操作:单击 = 进详情 —— 用户 2026-07-15 定,覆盖草稿标注 36(悬停 ♥/▶ 和右键菜单都不做),别照草稿"复原"回来。 */
export default function FavoritesPage({ session, onOpenItem, onPlay }: Props) {
  const [items, setItems] = useState<Item[] | null>(null);
  const [err, setErr] = useState("");

  /* 卡片动作走公共 hook。这页是收藏列表 → 取消收藏就把卡片移出;标记已看就地翻转 played。 */
  const card = useCardActions(session, {
    onPlay,
    onChanged: (it, played) =>
      setItems((cur) => (cur ? cur.map((x) => (x.id === it.id ? { ...x, played } : x)) : cur)),
    onFavChanged: (it, faved) =>
      !faved && setItems((cur) => (cur ? cur.filter((x) => x.id !== it.id) : cur)),
  });
  // 初值写成函数,否则每次渲染都读一遍 localStorage。
  const [view, setView] = useState<View>(loadView);
  const { sort, asc, layout } = view;
  const [openDD, setOpenDD] = useState(false);

  useEffect(() => {
    try {
      localStorage.setItem(VIEW_KEY, JSON.stringify(view));
    } catch {
      /* 存不下不该影响浏览 */
    }
  }, [view]);

  // 只在换服务器时重新拉 —— 排序是本地的,切档不该再打一次网络。
  useEffect(() => {
    let alive = true;
    setItems(null);
    setErr("");
    listFavorites()
      .then((x) => alive && setItems(x))
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [session.server]);

  const shown = useMemo(() => (items ? sortItems(items, sort, asc) : []), [items, sort, asc]);
  const sortLabel = SORTS.find((s) => s.id === sort)!.label;

  return (
    <>
      <div className="cbar">
        {/* 背板必须在 cbar 里面 —— 放外面会盖住整条顶栏,见 .lib-ddscrim 注释。 */}
        {openDD && <div className="lib-ddscrim" onClick={() => setOpenDD(false)} />}
        <span className="crumb">
          <b>收藏</b>
          {items && <span className="count">· {items.length}</span>}
        </span>
        <span className="push">
          {/* 排序(锚定下拉,纯本地排,不需要后端) */}
          <span className="lib-ddwrap">
            <button className="pill" title="排序方式" onClick={() => setOpenDD((d) => !d)}>
              排序 · {sortLabel} <IconChevronDown size={12} />
            </button>
            {openDD && (
              <div className="dd lib-dd">
                {SORTS.map((s) => (
                  <div
                    key={s.id}
                    className={`li${sort === s.id ? " on" : ""}`}
                    onClick={() => {
                      // 名称默认升序,更新时间/评分默认降序(新的/高分的在前)。
                      setView((v) => ({ ...v, sort: s.id, asc: s.id === "name" }));
                      setOpenDD(false);
                    }}
                  >
                    <span className="rad" />
                    {s.label}
                  </div>
                ))}
              </div>
            )}
          </span>

          {/* 升/降序(和排序字段分开,免得档位表翻倍) */}
          <button className="pill" title="切换升降序" onClick={() => setView((v) => ({ ...v, asc: !v.asc }))}>
            {asc ? "升序" : "降序"}
          </button>

          {/* 网格/列表切换(和媒体库同款) */}
          <button
            className="ibtn"
            title={layout === "grid" ? "切换列表" : "切换网格"}
            onClick={() => setView((v) => ({ ...v, layout: v.layout === "grid" ? "list" : "grid" }))}
          >
            {layout === "grid" ? <IconRows /> : <IconGrid />}
          </button>
        </span>
      </div>

      <div className="scroll">
        {err && <div className="empty">加载失败：{err}</div>}
        {items == null ? (
          <div className="dense-grid">
            {Array.from({ length: 14 }).map((_, i) => (
              <div className="pitem" key={i}>
                <div className="pcard poster-ar skeleton" />
              </div>
            ))}
          </div>
        ) : items.length === 0 ? (
          <div className="empty">还没有收藏。在详情页点收藏即可加入。</div>
        ) : layout === "grid" ? (
          <div className="dense-grid">
            {/* 卡片:点=进详情;悬停=▶/✓/♥;右键=标记已看/收藏(2026-07-24 用户定,四网格统一)。 */}
            {shown.map((it) => (
              <Poster key={it.id} item={it} session={session} onOpen={onOpenItem} {...card.cardProps(it)} />
            ))}
          </div>
        ) : (
          <div className="lib-list">
            {shown.map((it) => (
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
        <div style={{ height: 40 }} />
      </div>

      {card.menu}
      {card.toastNode}
    </>
  );
}
