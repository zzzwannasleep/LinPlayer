import type { Item, LoginResult } from "@shared/api";
import Card from "./Card";

/* 一条横滑轨道(首页用)。

   ★ 为什么是横滑而不是网格:首页要在一屏里表达"有好几类内容",
     每类都铺成网格的话一屏只装得下一类,用户得一路往下滚才知道下面还有什么。
     横滑是媒体类 App 的通用语汇(Netflix / Plex / Emby 都是),不需要教。

   ★ 滚动条隐藏但**保留惯性和 snap**:`scroll-snap-type: x proximity` ——
     proximity 不是 mandatory,轻扫一下不会被硬拽到下一张,重扫才吸附。
     mandatory 在手机上手感很粘,像在跟系统较劲。

   ★ 轨道横滑和"侧滑返回"会打架 —— 裁决在 App.tsx:侧滑返回只在**左缘 20px**
     起手才认。这条不定死的话,用户想把轨道往回拨一点就退出了页面。 */
export default function Row({
  title,
  items,
  session,
  onOpen,
  onLongPress,
  onMore,
  variant = "poster",
}: {
  title: string;
  items: Item[];
  session: LoginResult;
  onOpen: (it: Item) => void;
  onLongPress?: (it: Item) => void;
  /** 给了就在标题右侧出「更多 ›」。不传 = 这条轨道就是全部 */
  onMore?: () => void;
  variant?: "poster" | "thumb";
}) {
  if (!items.length) return null; // 空轨道整条不渲染,不摆一个空框
  return (
    <section className="row">
      <div className="row-hd">
        <h2>{title}</h2>
        {onMore && (
          <button type="button" className="row-more" onClick={onMore}>
            更多 ›
          </button>
        )}
      </div>
      <div className="row-scroll">
        {items.map((it, i) => (
          <Card
            key={it.id}
            item={it}
            session={session}
            variant={variant}
            index={i}
            onOpen={onOpen}
            onLongPress={onLongPress}
          />
        ))}
      </div>
    </section>
  );
}
