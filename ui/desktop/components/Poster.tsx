import { type MouseEvent, useState } from "react";
import { type Item, type LoginResult, itemLabel, posterUrl, thumbUrl } from "@shared/api";
import { IconPlay, IconLibrary, IconCheck, IconHeart } from "../app/icons";

type Props = {
  item: Item;
  session: LoginResult;
  variant?: "poster" | "thumb";
  /** 单击就走它 —— 卡片主操作(进详情)。 */
  onOpen: (it: Item) => void;
  /** 入场动画的阶梯下标(同一行卡片错开一点点淡入)。列表里传 map 的 i 即可,不传按 0。 */
  index?: number;
  /** 右键菜单(标记已/未播放、收藏、管理员项)。不传 = 保留浏览器默认右键。 */
  onContextMenu?: (e: MouseEvent, it: Item) => void;
  /** 悬停中央 ▶ 起播。仅**非文件夹**(电影/单集)渲染 —— 剧集/合集没有单一可播流,
      悬停就不给假播放钮,点卡片进详情挑集。不传 = 无悬停播放钮。 */
  onPlay?: (it: Item) => void;
  /** 该条目当前是否已收藏(右下红心的实心态)。 */
  favActive?: boolean;
  /** 右下红心:切换收藏。不传 = 不出红心。 */
  onToggleFav?: (it: Item) => void;
  /** 右下 ✓:切换已看/未看(hook 内部按 item.played 决定翻向)。不传 = 不出该钮。 */
  onToggleWatched?: (it: Item) => void;
};

/* 海报卡:全端共用(首页轨道 / 媒体库网格 / 收藏网格 / 搜索浮层结果)。

   ★ 交互口径(2026-07-24 用户定,**推翻 2026-07-15「只浮起不出按钮」的旧决策**):
     单击 = 进详情页;悬停 = 浮起 + 中央 ▶(可播条目)+ 右下快捷键(✓ 标记已看 / ♥ 收藏);
     双击**没有这一说**。悬停各钮是**可选**的(靠 onPlay/onToggleFav/onToggleWatched 传不传决定),
     不传就退回纯展示卡 —— 搜索浮层的跨服结果就不传,避免对错服务器写操作。
   角标:右上角状态(绿勾=看完 / 蓝数字=未看集数),评分挪左上,两不打架。 */
export default function Poster({
  item,
  session,
  variant = "poster",
  onOpen,
  index = 0,
  onContextMenu,
  onPlay,
  favActive,
  onToggleFav,
  onToggleWatched,
}: Props) {
  const thumb = variant === "thumb";
  /* 图片就位前先摆骨架(用户 2026-07-16:「先加载骨架出来,名字这种文字先出来,
     图片有加载动画看起来不会这么卡」)。原来 <img> 未加载时那块是**纯空白** ——
     快速下滑时一片白,看着像页面没加载出来。现在:未加载=shimmer 骨架,加载完淡入。 */
  const [loaded, setLoaded] = useState(false);
  const progress =
    !item.is_folder && item.resume_secs > 0 && item.runtime_secs > 0
      ? Math.min(100, (item.resume_secs / item.runtime_secs) * 100)
      : 0;
  const src = thumb ? thumbUrl(session, item.id) : posterUrl(session, item.id);
  const label = itemLabel(item);

  return (
    <div
      className="pitem"
      // 不传 onContextMenu 就不拦右键(保留浏览器默认菜单)。
      onContextMenu={onContextMenu ? (e) => onContextMenu(e, item) : undefined}
    >
      <div
        className={`pcard ${thumb ? "thumb-ar" : "poster-ar"} enter`}
        style={{ animationDelay: `${Math.min(index, 12) * 24}ms` }}
        /* 单击直接进详情:不再延后一拍等双击了 —— 没有双击,延迟只会让点击发粘。 */
        onClick={() => onOpen(item)}
        title={label}
      >
        {/* 骨架:图片没到位时占住这块(shimmer),到位即撤 —— 文字/角标本来就已经在了。 */}
        {item.has_primary && !loaded && <div className="pskel skeleton" />}
        {item.has_primary ? (
          <img
            className={loaded ? "ready" : ""}
            src={src}
            onLoad={() => setLoaded(true)}
            /* ★ 关于「切换回去不秒加载」—— **别再拿这里的动画开刀,那不是原因**(用户 2026-07-15
               当面纠正过我一次:「其实不秒加载并不是你的动画问题」)。

               我曾量到「.enter 380ms + 按下标最多 288ms 阶梯 = 最后一张卡 668ms」,就把动画
               砍了 —— **那是拿掉表象**。真正的原因在 HomePage 的加载结构:五个请求 Promise.all
               等齐才 set、媒体库还串行 await(见那边的长注释),那是**秒级**的,668ms 是零头。
               结构修好后「骨架先出 → 图片陆续进来 → 每张淡入」正是用户要的观感。

               lazy + async 一起用:lazy 让屏幕外的卡不发请求(轨道 20 张只可见 6 张),
               async 让解码不挡主线程。两者不冲突。 */
            loading="lazy"
            decoding="async"
            onError={(e) => {
              setLoaded(true); // 失败也要撤骨架,否则永远转圈
              (e.target as HTMLImageElement).style.visibility = "hidden";
            }}
          />
        ) : (
          <div className="fallback">
            {item.is_folder ? <IconLibrary size={30} /> : <IconPlay size={26} />}
          </div>
        )}
        {/* 评分角标(草稿标注 11):挪到**左上角**,把右上角让给状态角标(勾/未看数)。 */}
        {item.rating != null && item.rating > 0 && (
          <div className="badge-tl" title={`评分 ${item.rating}`}>
            {item.rating.toFixed(1)}
          </div>
        )}
        {/* 状态角标(右上角,对标 Emby):看完=绿勾;否则剧集/季显未看集数=蓝数字。
            emby::Item.unplayed_item_count 现已透传;played=true 时它必为 0 → 勾优先、二者不并存。 */}
        {item.played ? (
          <div className="played-ind" title="已看完">
            <IconCheck size={12} />
          </div>
        ) : (
          item.is_folder &&
          item.unplayed_item_count > 0 && (
            <div className="count-ind" title={`${item.unplayed_item_count} 集未看`}>
              {item.unplayed_item_count > 99 ? "99+" : item.unplayed_item_count}
            </div>
          )
        )}
        {progress > 0 && (
          <div className="progress">
            <i style={{ width: `${progress}%` }} />
          </div>
        )}
        {/* 悬停操作层(可选):中央 ▶(仅可播条目)+ 右下 ✓/♥。都靠 stopPropagation 免得触发卡片单击。 */}
        {(onPlay || onToggleWatched || onToggleFav) && (
          <div className="overlay">
            {onPlay && !item.is_folder && (
              <button
                className="ov-play ov-center"
                title="播放"
                onClick={(e) => {
                  e.stopPropagation();
                  onPlay(item);
                }}
              >
                <IconPlay size={18} />
              </button>
            )}
            <div className="ov-actions">
              {onToggleWatched && (
                <button
                  className={`ov-chk${item.played ? " on" : ""}`}
                  title={item.played ? "标记为未播放" : "标记为已播放"}
                  onClick={(e) => {
                    e.stopPropagation();
                    onToggleWatched(item);
                  }}
                >
                  <IconCheck size={15} />
                </button>
              )}
              {onToggleFav && (
                <button
                  className={`ov-fav${favActive ? " on" : ""}`}
                  title={favActive ? "从喜欢中移除" : "添加到喜欢"}
                  onClick={(e) => {
                    e.stopPropagation();
                    onToggleFav(item);
                  }}
                >
                  <IconHeart size={15} />
                </button>
              )}
            </div>
          </div>
        )}
      </div>
      <div className="pcap">{label}</div>
    </div>
  );
}
