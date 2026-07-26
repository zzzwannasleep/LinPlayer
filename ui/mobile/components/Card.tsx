import { useRef, useState } from "react";
import { type Item, type LoginResult, itemLabel, posterUrl, thumbUrl } from "@shared/api";
import { IconCheck, IconLibrary, IconPlay } from "../app/icons";

/* 海报卡(手机版)。

   和 PC 版 ui/desktop/components/Poster.tsx 的**取舍差异**,每条都是有理由的:

   | | PC | 手机 |
   |---|---|---|
   | 悬停浮起 + 中央 ▶ + 右下快捷键 | 有 | **没有**。触摸屏没有 hover,把它做成"点一下出按钮再点第二下"是给每个操作凭空加一次点击 —— 而 Emby 官方安卓端被喷得最多的就是"同一件事比别人多点 2-3 次" |
   | 右键菜单 | 有 | 换成**长按**(500ms + 触觉反馈) |
   | 按压反馈 | 无 | **有**。触摸没有 hover 态,不给按压反馈用户不确定自己点没点上 |

   角标口径与 PC 一致(是同一批用户在两端看同样的库):
   左上评分 / 右上状态(绿勾=看完,蓝数字=未看集数,勾优先) / 底部续播进度条。 */

type Props = {
  item: Item;
  session: LoginResult;
  variant?: "poster" | "thumb";
  onOpen: (it: Item) => void;
  /** 长按。不传 = 不响应长按(纯展示卡,比如跨服搜索结果不该对错服务器写操作) */
  onLongPress?: (it: Item) => void;
  /** 入场阶梯下标。**只给首屏传**,滚动出来的不要再错开淡入 —— 那会变成"边滚边闪" */
  index?: number;
};

/** 长按阈值。500ms 是安卓的系统惯例(ViewConfiguration.getLongPressTimeout());
 *  自己另定一个数,用户的肌肉记忆就对不上了。 */
const LONG_PRESS_MS = 500;
/** 手指抖动容差:超过这个位移就当成滚动,取消长按。
 *  没有它的话轨道横滑到一半会莫名弹出菜单。 */
const SLOP_PX = 10;

export default function Card({
  item,
  session,
  variant = "poster",
  onOpen,
  onLongPress,
  index = 0,
}: Props) {
  const thumb = variant === "thumb";
  const [loaded, setLoaded] = useState(false);
  const [down, setDown] = useState(false);

  const timer = useRef<number | null>(null);
  const start = useRef<{ x: number; y: number } | null>(null);
  /* 长按触发后要**吃掉随后的 click** —— 否则松手时既弹了菜单又进了详情。
     浏览器不会因为你处理了 pointer 事件就不派发 click。 */
  const fired = useRef(false);

  const clear = () => {
    if (timer.current) window.clearTimeout(timer.current);
    timer.current = null;
    setDown(false);
  };

  const progress =
    !item.is_folder && item.resume_secs > 0 && item.runtime_secs > 0
      ? Math.min(100, (item.resume_secs / item.runtime_secs) * 100)
      : 0;
  const label = itemLabel(item);

  return (
    <div className="mcard-wrap">
      <div
        className={`mcard ${thumb ? "ar-thumb" : "ar-poster"}${down ? " down" : ""}${
          index < 12 ? " enter" : ""
        }`}
        style={index < 12 ? { animationDelay: `${index * 30}ms` } : undefined}
        onPointerDown={(e) => {
          fired.current = false;
          start.current = { x: e.clientX, y: e.clientY };
          setDown(true);
          if (!onLongPress) return;
          timer.current = window.setTimeout(() => {
            fired.current = true;
            /* 触觉反馈。安卓 WebView 支持 vibrate,iOS 不支持 —— 但我们不做 iOS,
               而 ?. 保证了没有这个 API 的环境(桌面 WebView2)也不会抛。 */
            navigator.vibrate?.(12);
            onLongPress(item);
            clear();
          }, LONG_PRESS_MS);
        }}
        onPointerMove={(e) => {
          if (!start.current || !timer.current) return;
          const dx = e.clientX - start.current.x;
          const dy = e.clientY - start.current.y;
          if (Math.hypot(dx, dy) > SLOP_PX) clear(); // 在滚动,不是长按
        }}
        onPointerUp={clear}
        onPointerCancel={clear}
        onClick={() => {
          if (fired.current) return; // 刚才是长按,别再进详情
          onOpen(item);
        }}
      >
        {/* 骨架:图片没到位时占住这块,到位即撤。没有它的话快速下滑是一片白,
            看着像"页面没加载出来" —— 而文字和角标其实早就在了。 */}
        {item.has_primary && !loaded && <div className="mskel" />}
        {item.has_primary ? (
          <img
            className={loaded ? "ready" : ""}
            src={thumb ? thumbUrl(session, item.id, 480) : posterUrl(session, item.id, 360)}
            alt=""
            /* lazy:屏幕外的卡不发请求(一条轨道 20 张,可见的只有 3 张)。
               async:解码不挡主线程 —— 手机 CPU 上这一条比桌面重要得多。 */
            loading="lazy"
            decoding="async"
            onLoad={() => setLoaded(true)}
            onError={(e) => {
              setLoaded(true); // 失败也要撤骨架,否则永远是块灰
              (e.target as HTMLImageElement).style.visibility = "hidden";
            }}
          />
        ) : (
          <div className="mfallback">
            {item.is_folder ? <IconLibrary size={26} /> : <IconPlay size={22} />}
          </div>
        )}

        {item.rating != null && item.rating > 0 && (
          <div className="m-badge-tl">{item.rating.toFixed(1)}</div>
        )}
        {item.played ? (
          <div className="m-played">
            <IconCheck size={11} />
          </div>
        ) : (
          item.is_folder &&
          item.unplayed_item_count > 0 && (
            <div className="m-count">
              {item.unplayed_item_count > 99 ? "99+" : item.unplayed_item_count}
            </div>
          )
        )}
        {progress > 0 && (
          <div className="m-prog">
            <i style={{ width: `${progress}%` }} />
          </div>
        )}
      </div>
      <div className="mcap">{label}</div>
    </div>
  );
}
