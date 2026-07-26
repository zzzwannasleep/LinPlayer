import { useCallback, useMemo, useState } from "react";
import type { PageId, TabId } from "./nav";

/** 一条路由。参数直接挂在上面 —— 页面少、层级浅,不值当上路由库。
 *  desktop 和 tv 两端都是这么干的,已经验证够用。 */
export type Route = {
  page: PageId;
  /** detail / player 用 */
  itemId?: string;
  /** library 下钻用 */
  parentId?: string;
  /** servers 页进线路管理用 */
  serverId?: string;
  title?: string;
};

/* ============================================================
   手工路由栈。

   与 desktop/tv 的**唯一区别**是:每个 Tab 各持一条独立的栈。

   ★ 为什么必须独立:手机上「切走再切回来」是最高频的动作。
     共用一条栈的话,用户在首页里翻到某部剧的详情 → 切去搜索 → 切回首页,
     看到的是首页顶层,刚才翻到哪儿全丢了。iOS/Android 两家的原生 Tab 容器
     都是每 Tab 一条栈,这是用户的肌肉记忆,不是我们的发挥空间。

   ★ 返回键的语义(优先级从高到低,由 App.tsx 编排):
       1. 有覆盖层(sheet/面板)→ 关它
       2. 当前 Tab 的栈深 > 1 → 弹一层
       3. 不在 home Tab → 回 home Tab
       4. 在 home Tab 栈底 → 交给壳(退出应用)
     第 3 条是安卓的惯例(iOS 没有全局返回键所以没这一条),漏了它的表现是
     用户在设置页按返回直接退出了应用。
   ============================================================ */

const TAB_IDS: TabId[] = ["home", "search", "settings"];

export type Nav = {
  tab: TabId;
  /** 当前 Tab 栈顶那一条 */
  route: Route;
  /** 当前 Tab 的栈深。返回键要用它判断该弹栈还是该回首页 */
  depth: number;
  /** 切 Tab。**再点一次当前 Tab = 回到该 Tab 的栈底**(安卓/iOS 通用惯例) */
  goTab: (t: TabId) => void;
  /** 在当前 Tab 上压一层 */
  push: (r: Route | PageId) => void;
  /** 弹一层。已在栈底返回 false —— 调用方据此决定是回 home 还是退出应用 */
  pop: () => boolean;
  /** 回当前 Tab 栈底 */
  popToRoot: () => void;
};

export function useNav(): Nav {
  const [tab, setTab] = useState<TabId>("home");
  const [stacks, setStacks] = useState<Record<TabId, Route[]>>(() => ({
    home: [{ page: "home" }],
    search: [{ page: "search" }],
    settings: [{ page: "settings" }],
  }));

  const stack = stacks[tab];
  const route = stack[stack.length - 1];

  const goTab = useCallback((t: TabId) => {
    setTab((cur) => {
      /* 再点一次当前 Tab → 回栈底。这是「我迷路了,带我回去」的通用手势,
         用户不会去想「按几次返回」。 */
      if (cur === t) setStacks((s) => (s[t].length > 1 ? { ...s, [t]: [s[t][0]] } : s));
      return t;
    });
  }, []);

  const push = useCallback(
    (r: Route | PageId) => {
      const next: Route = typeof r === "string" ? { page: r } : r;
      setStacks((s) => ({ ...s, [tab]: [...s[tab], next] }));
    },
    [tab],
  );

  /* ★ 返回 boolean 而不是静默无操作:调用方(返回键)必须能区分
       「弹掉了一层」和「已经在栈底」—— 两者的下一步动作完全不同。
     ★ 用函数式 setState 读到的是**最新**栈,但那个值出不来给调用方,
       所以这里读闭包里的 stacks。tab 和 stacks 都在依赖里,不会读到陈旧值。 */
  const pop = useCallback(() => {
    if (stacks[tab].length <= 1) return false;
    setStacks((s) => ({ ...s, [tab]: s[tab].slice(0, -1) }));
    return true;
  }, [tab, stacks]);

  const popToRoot = useCallback(() => {
    setStacks((s) => (s[tab].length > 1 ? { ...s, [tab]: [s[tab][0]] } : s));
  }, [tab]);

  return useMemo(
    () => ({ tab, route, depth: stack.length, goTab, push, pop, popToRoot }),
    [tab, route, stack.length, goTab, push, pop, popToRoot],
  );
}

export { TAB_IDS };
