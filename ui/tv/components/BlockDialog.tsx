import { useCallback, useEffect, useState } from "react";
import { blockName, blockedList, setBlocked, type Item } from "@shared/api";
import { FocusBoundary, FocusColumn, FocusItem } from "./Focus";

/* 长按 OK → 屏蔽 / 解除屏蔽(用户 2026-08-02:「移动端和TV端都是长按卡片选择是否屏蔽」)。

   ## 为什么要一个确认面板,不是长按即屏蔽
   屏蔽的后果是"这部剧从首页、搜索、播放记录里全都消失"。遥控器上长按是最容易
   误触的手势(OK 键行程长,手指多停一下就到),不给一次确认的话用户会遇到
   "东西不见了、而且不知道自己干了什么"。

   ## 焦点必须被 FocusBoundary 圈住
   不圈的话面板开着按左右仍会选中背后的卡片 —— norigin 上最经典的那条坑
   (只写 isFocusBoundary 不套 FocusContext.Provider 也一样,见 Focus.tsx)。

   ## 记名字不是记 id
   分集要记**剧名**:观看记录是跨服务器的,核层只有名字对得上
   (见 crates/core/src/blocklist.rs)。 */

export function useBlockDialog(opts?: {
  onChanged?: (it: Item, blocked: boolean) => void;
  /** 屏蔽的是**媒体库**而不是条目。
   *  ★ 反显按 **id** 判,不按名字:两台服务器上都叫「电影」的库是两个不同的库,
   *    按名字会显示成"另一台那个也已屏蔽"。核层对应 `blocklist::is_blocked_id`。 */
  library?: boolean;
}) {
  const lib = !!opts?.library;
  const [target, setTarget] = useState<Item | null>(null);
  const [names, setNames] = useState<Set<string>>(new Set());
  const [ids, setIds] = useState<Set<string>>(new Set());

  /* 名单是跨服务器的(核层按名字对齐),拉一次就够,不跟着换服重拉。 */
  useEffect(() => {
    let alive = true;
    blockedList()
      .then((b) => {
        if (!alive) return;
        setNames(new Set(b.map((x) => x.name)));
        setIds(new Set(b.map((x) => x.id)));
      })
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);

  const openFor = useCallback((it: Item) => setTarget(it), []);

  const apply = async (it: Item, next: boolean) => {
    const name = blockName(it);
    setTarget(null);
    try {
      await setBlocked(it.id, name, next);
      const put = <T,>(s: Set<T>, v: T) => {
        const n = new Set(s);
        if (next) n.add(v);
        else n.delete(v);
        return n;
      };
      setNames((s) => put(s, name));
      setIds((s) => put(s, it.id));
      opts?.onChanged?.(it, next);
    } catch {
      /* 失败就保持原样。TV 上没有 toast 通道,弹一个只能用遥控器关掉的错误框
         比"这次没生效、再长按一次"更烦人。 */
    }
  };

  const on = target ? (lib ? ids.has(target.id) : names.has(blockName(target))) : false;
  const dialog = target && (
    <FocusBoundary className="panel blkdlg" focusKey="BLOCK_DLG" onBack={() => setTarget(null)}>
      <div className="ph">{blockName(target)}</div>
      <div className="scroll">
        <FocusColumn scroll={false}>
          <div className="blk-desc">
            {lib
              ? on
                ? "解除屏蔽后,这个媒体库会重新出现在首页。"
                : /* 说清能力边界:屏蔽库**不会**自动屏蔽库里的片子。
                     不写的话用户会以为"继续观看里还有"是 bug。 */
                  "屏蔽后这个媒体库不在首页出现。库里的片子如果也不想看见,要对片子本身单独屏蔽。本页仍然列出它,随时可以解除。"
              : on
                ? "解除屏蔽后,它会重新出现在首页、搜索和播放记录里。"
                : "屏蔽后不在首页显示,不出现在搜索结果和播放记录里。媒体库里仍能找到它,随时可以解除。"}
          </div>
          <FocusItem className="pitem fx" autoFocus onEnter={() => void apply(target, !on)}>
            {on ? "解除屏蔽" : lib ? "屏蔽此媒体库" : "屏蔽这部内容"}
          </FocusItem>
          <FocusItem className="pitem fx" onEnter={() => setTarget(null)}>
            取消
          </FocusItem>
        </FocusColumn>
      </div>
    </FocusBoundary>
  );

  return { openFor, dialog, blockedNames: names, blockedIds: ids };
}
