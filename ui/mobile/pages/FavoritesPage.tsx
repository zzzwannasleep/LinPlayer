import { useEffect, useState } from "react";
import { type Item, listFavorites, posterUrl } from "@shared/api";
import { SORTS, type SortId, sortItems } from "@shared/favorites-sort";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { haptic } from "../app/motion";
import Page from "../components/Page";
import Sheet from "../components/Sheet";
import { Empty, Grid, Opt, usePress } from "../components/ui";

/* 收藏。

   ★ 排序**在本地做**,不传 SortBy 给服务端 —— 不是偷懒:
     实测 v1.uhdnow.com(Emby 的一个 fork)在 `Filters=IsFavorite` 上**不认 SortBy**
     (同一台服务器的媒体库接口却认)。传了不报错,只是顺序纹丝不动。
     排序逻辑三端共用 @shared/favorites-sort —— 连"空值沉底"这种细节都在那儿,别再抄一份。

   ★ 两种视图(网格 / 图文列表)。网格看封面,列表看名字 ——
     收藏里混着电影和剧,想找某一部时列表更快。 */

const TYPES = [
  { id: "all", label: "全部" },
  { id: "Movie", label: "电影" },
  { id: "Series", label: "剧集" },
  { id: "Episode", label: "单集" },
] as const;

export default function FavoritesPage() {
  const { session, back, go, openItem } = useCtx();
  const [items, setItems] = useState<Item[] | null>(null);
  const [err, setErr] = useState("");
  const [sort, setSort] = useState<SortId>("updated");
  const [asc, setAsc] = useState(false);
  const [type, setType] = useState<string>("all");
  const [view, setView] = useState<"grid" | "list">("grid");
  const [sheet, setSheet] = useState(false);

  useEffect(() => {
    let alive = true;
    listFavorites()
      .then((x) => alive && setItems(x))
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [session?.server]);

  const sortLabel = SORTS.find((s) => s.id === sort)?.label ?? "排序";
  const shown = (items ?? []).filter((it) => type === "all" || it.type_ === type);
  const sorted = sortItems(shown, sort, asc);

  return (
    <Page title="收藏" onBack={back} enterKey={items}>
      <div className="chips-row">
        <div className="chips">
          {TYPES.map((t) => (
            <Chip
              key={t.id}
              on={t.id === type}
              label={t.label}
              onClick={() => {
                haptic("sel");
                setType(t.id);
              }}
            />
          ))}
          <Chip
            label={`${sortLabel} ${asc ? "↑" : "↓"}`}
            icon="sort"
            onClick={() => {
              haptic("sel");
              setSheet(true);
            }}
          />
        </div>
        <div className="viewsw">
          <button
            type="button"
            className={view === "grid" ? "on" : undefined}
            aria-label="网格"
            onClick={() => {
              haptic("sel");
              setView("grid");
            }}
          >
            <Icon n="grid" size={18} />
          </button>
          <button
            type="button"
            className={view === "list" ? "on" : undefined}
            aria-label="列表"
            onClick={() => {
              haptic("sel");
              setView("list");
            }}
          >
            <Icon n="list" size={18} />
          </button>
        </div>
      </div>

      {err ? (
        <Empty icon="heart" title="加载失败" desc={err} />
      ) : items === null ? (
        <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
      ) : !sorted.length ? (
        <Empty
          icon="heart"
          title={type === "all" ? "还没有收藏" : "这一类还没有收藏"}
          desc="长按封面选「收藏」,或者去媒体库逛逛,看到喜欢的随手存一下。"
          action={{ label: "去媒体库看看", on: () => go("library") }}
        />
      ) : (
        <>
          <div className="lp-total">共 {sorted.length} 项</div>
          {view === "grid" ? (
            session && <Grid items={sorted} session={session} onOpen={(it) => openItem(it)} />
          ) : (
            <div>
              {sorted.map((it, i) => (
                <button
                  key={it.id}
                  type="button"
                  className="lit"
                  style={{ ["--i" as string]: i }}
                  onClick={() => openItem(it)}
                >
                  <div className="card-a ar-poster" style={{ width: 56, flexShrink: 0 }}>
                    {session && (
                      <img src={posterUrl(session, it.id, 200)} alt="" loading="lazy" decoding="async" />
                    )}
                  </div>
                  <div className="lit-t">
                    <div className="lit-n">{it.series_name || it.name}</div>
                    <div className="lit-s">
                      {[it.year, it.rating ? `★ ${it.rating.toFixed(1)}` : null].filter(Boolean).join(" · ")}
                    </div>
                  </div>
                </button>
              ))}
            </div>
          )}
        </>
      )}

      <Sheet open={sheet} onClose={() => setSheet(false)} title="排序">
        <div className="opts">
          {SORTS.map((s, i) => (
            <Opt
              key={s.id}
              i={i}
              on={s.id === sort}
              label={s.label}
              badge={s.id === sort ? (asc ? "升序" : "降序") : undefined}
              onClick={() => {
                /* 点已选中的那一项 = 翻转升降序。手机上没有 PC 那个独立的
                   ↑↓ 小按钮的位置,而"再点一次翻转"是列表排序的通用手势。 */
                if (s.id === sort) setAsc((v) => !v);
                else {
                  setSort(s.id);
                  setAsc(false);
                }
                haptic("sel");
                setSheet(false);
              }}
            />
          ))}
        </div>
      </Sheet>
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

