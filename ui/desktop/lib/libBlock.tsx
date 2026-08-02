import { useCallback, useEffect, useState, type MouseEvent, type ReactNode } from "react";
import { blockedList, setBlocked, type Item } from "@shared/api";
import { IconEyeOff } from "../app/icons";

/* 右键**媒体库入口**(首页那条「媒体库」轨 / 媒体库页的库卡)→ 屏蔽整个库。

   ## 为什么和条目卡的 useCardActions 分开
   库不是条目:没有「已看 / 收藏 / 悬停播放」可言,共用一个菜单会画出三项对库
   毫无意义的动作。这里只有一项。

   ## 库按 id 判,**不按名字**
   条目那套会顺带比名字(跨服的同一部剧 id 不同,只有名字对得上,见
   crates/core/src/blocklist.rs)。库不能这么判 —— 两台服务器上都叫「电影」的库是
   两个不同的库,按名字会一屏两台一起屏蔽。核层对应的是 `blocklist::is_blocked_id`。

   ## 屏蔽一个库会发生什么
   `views` 命令缺省滤掉它 → 首页的媒体库轨、以及它那条「最新」行一起消失。
   **媒体库页仍然列出它**(那份传 includeBlocked=true)并打「已屏蔽」——
   否则点错一次就再也找不回来解除,屏蔽成了单向门。
   ★ 库里的**条目**不会自动跟着屏蔽:继续观看/搜索里那些片子如果也不想看见,
     得对片子本身右键屏蔽。这是能力边界,菜单文案里说清楚,不假装。 */

export function useLibBlockMenu(onChanged?: (lib: Item, blocked: boolean) => void) {
  const [ctx, setCtx] = useState<{ x: number; y: number; lib: Item } | null>(null);
  const [ids, setIds] = useState<Set<string>>(new Set());
  const [toast, setToast] = useState("");

  useEffect(() => {
    let alive = true;
    blockedList()
      .then((b) => alive && setIds(new Set(b.map((x) => x.id))))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);

  // 点空白 / 滚动 / Esc 关(和 useCardActions 同一套路)。
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

  const open = useCallback((e: MouseEvent, lib: Item) => {
    e.preventDefault();
    setCtx({ x: e.clientX, y: e.clientY, lib });
  }, []);

  const toggle = async (lib: Item) => {
    setCtx(null);
    const next = !ids.has(lib.id);
    try {
      await setBlocked(lib.id, lib.name, next);
      setIds((cur) => {
        const n = new Set(cur);
        if (next) n.add(lib.id);
        else n.delete(lib.id);
        return n;
      });
      onChanged?.(lib, next);
      setToast(next ? `已屏蔽「${lib.name}」,首页不再显示这个库` : `已解除屏蔽「${lib.name}」`);
    } catch (e) {
      setToast(`屏蔽失败:${e}`);
    }
  };

  const menu: ReactNode = ctx && (
    <div className="ctxmenu" style={{ left: ctx.x, top: ctx.y }} onClick={(e) => e.stopPropagation()}>
      <div className="mi" onClick={() => void toggle(ctx.lib)}>
        <IconEyeOff size={15} /> {ids.has(ctx.lib.id) ? "解除屏蔽此媒体库" : "屏蔽此媒体库"}
      </div>
    </div>
  );

  const toastNode: ReactNode = toast && <div className="toast">{toast}</div>;

  return { open, menu, toastNode, blockedIds: ids, toggle };
}
