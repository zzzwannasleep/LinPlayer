import type { Item } from "@shared/api";

/* ★ 收藏排序**必须本地做**。2026-07-19 在真实服务器(服务端A,服务端A(UHD fork))上实测:
   不管发 SortBy=SortName 还是 SortBy=CommunityRating,服务端返回的顺序**一模一样**
   (恒为 DateCreated 降序)—— 这台 fork 直接无视 Filters=IsFavorite 查询上的 SortBy。
   原版 Emby(服务端B)是认的,但**别拿原版的结论替 fork 签字**。
   收藏封顶 2000 条,本地排零压力且在任何服上都成立。 */
export const SORTS = [
  { id: "name", label: "名称" },
  { id: "updated", label: "更新时间" },
  { id: "rating", label: "评分" },
] as const;
export type SortId = (typeof SORTS)[number]["id"];

/** 排序键。返回 null = 该条目这项没值。 */
function sortKey(it: Item, sort: SortId): string | number | null {
  if (sort === "rating") return it.rating;
  if (sort === "updated") return it.date_updated;
  return it.sort_name || it.name;
}

/** 空值一律沉底(无论升降序)—— 否则「无评分」的条目在降序里会插到 10 分前面。 */
export function sortItems(items: Item[], sort: SortId, asc: boolean): Item[] {
  return [...items].sort((a, b) => {
    const ka = sortKey(a, sort);
    const kb = sortKey(b, sort);
    if (ka == null && kb == null) return a.name.localeCompare(b.name, "zh");
    if (ka == null) return 1;
    if (kb == null) return -1;
    const d =
      typeof ka === "number" && typeof kb === "number"
        ? ka - kb
        : String(ka).localeCompare(String(kb), "zh");
    return asc ? d : -d;
  });
}
