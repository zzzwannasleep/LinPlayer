import { useEffect, useState } from "react";
import { type Item, type LoginResult, listFavorites } from "@shared/api";
import { SORTS, type SortId, sortItems } from "@shared/favorites-sort";
import Card from "../components/Card";
import Sheet from "../components/Sheet";

/* 收藏。

   ★ 排序**在本地做**,不传 SortBy 给服务端 —— 不是偷懒:
     实测 v1.uhdnow.com(Emby 的一个 fork)在 `Filters=IsFavorite` 上**不认 SortBy**
     (同一台服务器的媒体库接口却认)。传了不报错,只是顺序纹丝不动。
     排序逻辑三端共用 @shared/favorites-sort —— 连"空值沉底"这种细节都在那儿,
     别再抄一份。 */

export default function FavoritesPage({
  session,
  onOpen,
}: {
  session: LoginResult;
  onOpen: (it: Item) => void;
}) {
  const [items, setItems] = useState<Item[] | null>(null);
  const [err, setErr] = useState("");
  const [sort, setSort] = useState<SortId>("updated");
  const [asc, setAsc] = useState(false);
  const [sheet, setSheet] = useState(false);

  useEffect(() => {
    let alive = true;
    listFavorites()
      .then((x) => alive && setItems(x))
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [session.server]);

  if (err) return <div className="empty"><b>加载失败</b><div className="dim">{err}</div></div>;
  if (!items) return <div className="empty"><div className="dim">加载中…</div></div>;
  if (!items.length) return <div className="empty"><div className="dim">还没有收藏</div></div>;

  const label = SORTS.find((s) => s.id === sort)?.label ?? "排序";

  return (
    <div>
      <div className="chips lib-bar">
        <button type="button" className="chip" onClick={() => setSheet(true)}>
          {label} {asc ? "↑" : "↓"}
        </button>
        <span className="lib-total dim">{items.length}</span>
      </div>
      <div className="grid" style={{ marginTop: 12 }}>
        {sortItems(items, sort, asc).map((it, i) => (
          <Card key={it.id} item={it} session={session} index={i} onOpen={onOpen} />
        ))}
      </div>
      <Sheet open={sheet} onClose={() => setSheet(false)} title="排序">
        <div className="opts">
          {SORTS.map((s) => (
            <button
              key={s.id}
              type="button"
              className={`opt${s.id === sort ? " on" : ""}`}
              onClick={() => {
                /* 点已选中的那一项 = 翻转升降序。手机上没有 PC 那个独立的
                   ↑↓ 小按钮的位置,而"再点一次翻转"是列表排序的通用手势。 */
                if (s.id === sort) setAsc((v) => !v);
                else {
                  setSort(s.id);
                  setAsc(false);
                }
                setSheet(false);
              }}
            >
              {s.label}
              {s.id === sort ? (asc ? " ↑" : " ↓") : ""}
            </button>
          ))}
        </div>
      </Sheet>
    </div>
  );
}
