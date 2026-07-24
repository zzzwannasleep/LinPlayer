import { useCallback, useEffect, useRef, useState, type MouseEvent, type ReactNode } from "react";
import { type Item, type LoginResult, listFavorites, setFavorite, setPlayed } from "@shared/api";
import { AdminMenuItems, useIsAdmin } from "./admin";
import { IconCheck, IconHeart } from "../app/icons";

/* 卡片动作中枢:首页/媒体库/收藏/搜索四处网格共用一套「收藏 + 标记已看/未看 + 右键菜单」。
   过去只有首页手写了这套(其余页要么没有、要么只有管理员项),四份拷贝迟早各改一半 ——
   收进一个 hook,谁要谁 useCardActions,菜单/收藏态/toast 全由它出。

   页面各自持有 items 副本(见 memory: frontend-state-copies-need-broadcast),标记已看后
   得让持有方自己更新那一份 → 通过 onChanged/onFavChanged 回调把变更广播回调用页,
   hook 不去猜别人的列表该怎么改。 */

type Opts = {
  /** 悬停中央 ▶ 起播(仅非文件夹条目 Poster 才渲染)。不传 = 卡片没有悬停播放钮。 */
  onPlay?: (it: Item) => void;
  /** 标记已看/未看落地后:调用页据此更新自己那份 items(如把该卡 played 翻转)。 */
  onChanged?: (it: Item, played: boolean) => void;
  /** 收藏切换落地后:收藏页据此把取消收藏的卡片移出列表。 */
  onFavChanged?: (it: Item, faved: boolean) => void;
};

export function useCardActions(session: LoginResult, opts?: Opts) {
  const [favIds, setFavIds] = useState<Set<string>>(new Set());
  const [ctx, setCtx] = useState<{ x: number; y: number; item: Item } | null>(null);
  const [toast, setToast] = useState("");
  const admin = useIsAdmin(session.server);
  // opts 每次渲染是新字面量 → 存 ref,免得 useCallback 依赖天天变。
  const cb = useRef(opts);
  cb.current = opts;

  // 收藏集合:换服务器时重拉一次(海报的红心态、右键菜单文案都看它)。
  useEffect(() => {
    let alive = true;
    listFavorites()
      .then((f) => alive && setFavIds(new Set(f.map((x) => x.id))))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, [session.server]);

  // 右键菜单:点空白 / 滚动 / Esc 关(和各页原来的套路一致)。
  useEffect(() => {
    if (!ctx) return;
    const close = () => setCtx(null);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && close();
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
      window.removeEventListener("keydown", onKey);
    };
  }, [ctx]);

  useEffect(() => {
    if (!toast) return;
    const t = window.setTimeout(() => setToast(""), 2600);
    return () => window.clearTimeout(t);
  }, [toast]);

  const toggleFav = useCallback((it: Item) => {
    setFavIds((s) => {
      const next = !s.has(it.id);
      setFavorite(it.id, next)
        .then(() => cb.current?.onFavChanged?.(it, next))
        .catch((e) => {
          // 后端没落地就把红心退回去,不留假状态。
          setFavIds((cur) => {
            const back = new Set(cur);
            if (next) back.delete(it.id);
            else back.add(it.id);
            return back;
          });
          setToast(`收藏失败:${e}`);
        });
      const n = new Set(s);
      if (next) n.add(it.id);
      else n.delete(it.id);
      return n;
    });
  }, []);

  const markPlayed = useCallback(async (it: Item, played: boolean) => {
    setCtx(null);
    try {
      await setPlayed(it.id, played);
      cb.current?.onChanged?.(it, played);
    } catch (e) {
      setToast(`标记失败:${e}`);
    }
  }, []);

  const openCtx = useCallback((e: MouseEvent, it: Item) => {
    e.preventDefault();
    setCtx({ x: e.clientX, y: e.clientY, item: it });
  }, []);

  /** 传给 <Poster> 的动作 props（右键 + 悬停播放/标记/收藏一次带齐）。 */
  const cardProps = (it: Item) => ({
    onContextMenu: openCtx,
    onPlay: cb.current?.onPlay,
    favActive: favIds.has(it.id),
    onToggleFav: toggleFav,
    onToggleWatched: (x: Item) => void markPlayed(x, !x.played),
  });

  /** 右键菜单本体（标记已看/未看 + 收藏 + 管理员项）。页面把它渲染在最外层即可。 */
  const menu: ReactNode = ctx && (
    <div className="ctxmenu" style={{ left: ctx.x, top: ctx.y }} onClick={(e) => e.stopPropagation()}>
      <div className="mi" onClick={() => void markPlayed(ctx.item, true)}>
        <IconCheck size={15} /> 标记为已播放
      </div>
      <div className="mi" onClick={() => void markPlayed(ctx.item, false)}>
        <IconCheck size={15} /> 标记为未播放
      </div>
      <div
        className="mi"
        onClick={() => {
          toggleFav(ctx.item);
          setCtx(null);
        }}
      >
        <IconHeart size={15} /> {favIds.has(ctx.item.id) ? "从喜欢中移除" : "添加到喜欢"}
      </div>
      {/* 管理员项:非管理员整段不出现(出现了也只会 403)。 */}
      {admin && (
        <AdminMenuItems
          itemId={ctx.item.id}
          onDone={(m) => {
            setToast(m);
            setCtx(null);
          }}
        />
      )}
    </div>
  );

  const toastNode: ReactNode = toast && <div className="toast">{toast}</div>;

  return { favIds, toggleFav, markPlayed, openCtx, setCtx, cardProps, menu, toast, setToast, toastNode };
}
