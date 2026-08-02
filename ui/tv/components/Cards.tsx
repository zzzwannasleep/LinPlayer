import {
  fmtRes,
  itemLabel,
  posterUrl,
  thumbUrl,
  type Item,
  type LoginResult,
} from "@shared/api";
import { FocusItem } from "./Focus";

/* 卡片。封面失败时露出底下的占位渐变(.th 自带),不画"加载失败"字样 ——
   一屏几十张卡,每张都写字反而比缺图更吵。 */

/** 16:9 横卡:继续观看 / 接下来看 / 分集。320x180dp。 */
export function CardWide({
  it,
  session,
  onEnter,
  showProgress,
}: {
  it: Item;
  session: LoginResult;
  onEnter?: () => void;
  showProgress?: boolean;
}) {
  const pct =
    showProgress && it.runtime_secs > 0
      ? Math.min(100, (it.resume_secs / it.runtime_secs) * 100)
      : 0;
  return (
    <FocusItem className="card169 fx" onEnter={onEnter}>
      <div className="th">
        {it.has_primary && <img src={thumbUrl(session, it.id, 640)} alt="" loading="lazy" />}
        {pct > 0 && (
          <div className="prog">
            <i style={{ width: `${pct}%` }} />
          </div>
        )}
      </div>
      <div className="nm">{itemLabel(it)}</div>
      <div className="sub">{wideSub(it)}</div>
    </FocusItem>
  );
}

/** 2:3 竖卡:媒体库 / 收藏 / 搜索结果网格,**以及首页各媒体库行**。220x330dp。
 *
 *  ★ 剧和电影的封面本来就是竖版海报,横过来放要么裁掉大半张脸、要么两边留黑边。
 *    首页那些「某某媒体库」行里装的是剧/电影,必须用这个,不是 CardWide。
 *    横卡只留给**分集**(集封面本来就是 16:9 的截图)和继续观看。 */
export function CardPoster({
  it,
  session,
  onEnter,
  onLongEnter,
  blocked,
}: {
  it: Item;
  session: LoginResult;
  onEnter?: () => void;
  /** 长按 OK:屏蔽/解除屏蔽(用户 2026-08-02)。传了它,onEnter 改成松手才触发。 */
  onLongEnter?: () => void;
  /** 已屏蔽 —— 只有**媒体库网格**会传。别处核层已经把它滤掉了
   *  (见 crates/core/src/emby.rs 的 fetch_items),媒体库故意不滤,所以要打标。 */
  blocked?: boolean;
}) {
  return (
    <FocusItem className={`card23 fx${blocked ? " blocked" : ""}`} onEnter={onEnter} onLongEnter={onLongEnter}>
      <div className="th">
        {it.has_primary && <img src={posterUrl(session, it.id, 480)} alt="" loading="lazy" />}
        {blocked && <div className="blk">已屏蔽</div>}
        {/* 未看集数角标。UserData.UnplayedItemCount 走的是 Item 上的字段,
            这里只在剧集上有意义。 */}
      </div>
      <div className="nm">{it.name}</div>
      <div className="sub">{[it.year, fmtRes(it.video_height)].filter(Boolean).join(" · ")}</div>
    </FocusItem>
  );
}

function wideSub(it: Item): string {
  const parts: string[] = [];
  if (it.season_no != null && it.episode_no != null)
    parts.push(`S${it.season_no} E${it.episode_no}`);
  if (it.runtime_secs > 0) parts.push(`${Math.round(it.runtime_secs / 60)} 分钟`);
  return parts.join(" · ");
}
