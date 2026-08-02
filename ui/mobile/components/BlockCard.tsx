import { useCallback, useEffect, useState } from "react";
import { blockName, blockedList, setBlocked, type Item } from "@shared/api";
import { haptic, toast } from "../app/motion";
import Sheet from "./Sheet";

/* 长按卡片 → 屏蔽 / 解除屏蔽(用户 2026-08-02:「移动端和TV端都是长按卡片选择是否屏蔽」)。

   ## 为什么是一个 hook 而不是各页自己写
   首页/媒体库/搜索/收藏四处都有卡片网格,四份拷贝迟早各改一半 —— 和 PC 端把这套
   收进 useCardActions 是同一个理由。这里出两样东西:接给 `<Grid>/<Row>` 的
   `onLongPress`,和渲染在页面最外层的确认弹窗。

   ## 为什么要确认弹窗,不是长按即屏蔽
   长按是**误触率最高**的手势(手指在列表上停一下就触发),而屏蔽的后果是"这部剧
   从首页、搜索、播放记录里全都消失"。不给一次确认的话,用户会遇到"东西不见了、
   而且不知道自己干了什么"。

   ## 记名字不是记 id
   用 `@shared/api` 的 `blockName`(三端唯一一份):分集记**剧名**不是「第 35 集」——
   观看记录是跨服务器的,核层只有名字对得上(见 crates/core/src/blocklist.rs)。 */

export function useBlockCard(opts?: {
  /** 屏蔽落地后。页面据此把这张卡从自己手里那份副本里移走 / 整页重拉。 */
  onChanged?: (it: Item, blocked: boolean) => void;
  /** 屏蔽的是**媒体库**而不是条目。
   *  ★ 反显要按 **id** 判,不能按名字:两台服务器上都叫「电影」的库是两个不同的库,
   *    按名字会显示成"另一台那个也已屏蔽"。核层对应 `blocklist::is_blocked_id`。
   *  ★ 文案也不一样(屏蔽一个库 ≠ 屏蔽一部剧),见下面的弹窗。 */
  library?: boolean;
}) {
  const lib = !!opts?.library;
  const [target, setTarget] = useState<Item | null>(null);
  const [names, setNames] = useState<Set<string>>(new Set());
  const [ids, setIds] = useState<Set<string>>(new Set());
  const [busy, setBusy] = useState(false);

  /* 名单是**跨服务器**的(核层按名字对齐),所以只拉一次,不跟着换服重拉。 */
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

  const onLongPress = useCallback((it: Item) => {
    haptic("ok");
    setTarget(it);
  }, []);

  const apply = async (it: Item, next: boolean) => {
    setBusy(true);
    const name = blockName(it);
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
      setTarget(null);
      opts?.onChanged?.(it, next);
      toast(next ? `已屏蔽《${name}》` : `已解除屏蔽《${name}》`, "ok");
    } catch (e) {
      toast(`操作失败:${e}`, "bad");
    } finally {
      setBusy(false);
    }
  };

  const on = target ? (lib ? ids.has(target.id) : names.has(blockName(target))) : false;
  const dialog = (
    <Sheet open={!!target} onClose={() => setTarget(null)} title={target ? blockName(target) : ""}>
      <div className="pad">
        <p className="blk-desc">
          {lib
            ? on
              ? "解除屏蔽后,这个媒体库会重新出现在首页。"
              : /* 说清楚能力边界:屏蔽库**不会**自动屏蔽库里的片子。
                   不写的话用户会以为"继续观看里还有"是 bug。 */
                "屏蔽后这个媒体库不在首页出现。库里的片子如果也不想看见,要对片子本身单独屏蔽。本页仍然列出它,随时可以解除。"
            : on
              ? "解除屏蔽后,它会重新出现在首页、搜索和播放记录里。"
              : "屏蔽后不在首页显示,不出现在搜索结果和播放记录里。媒体库里仍能找到它,随时可以解除。"}
        </p>
      </div>
      <div className="sheet-acts">
        <button type="button" className="btn ghost" onClick={() => setTarget(null)}>
          取消
        </button>
        <button
          type="button"
          className={`btn ${on ? "primary" : "danger"}`}
          disabled={busy}
          onClick={() => target && void apply(target, !on)}
        >
          {on ? "解除屏蔽" : lib ? "屏蔽此媒体库" : "屏蔽"}
        </button>
      </div>
    </Sheet>
  );

  return { onLongPress, dialog, blockedNames: names, blockedIds: ids };
}
