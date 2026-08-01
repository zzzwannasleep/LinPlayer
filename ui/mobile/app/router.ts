import { useCallback, useMemo, useRef, useState } from "react";
import { TAB_ROOT, type PageId, type TabId } from "./nav";

/** 一条路由。参数直接挂在上面 —— 页面少、层级浅,不值当上路由库。
 *  desktop 和 tv 两端都是这么干的,已经验证够用。 */
export type Route = {
  page: PageId;
  /** detail / player / episode 用 */
  itemId?: string;
  /** library 下钻用 */
  parentId?: string;
  /** servers → 线路 / 图标 页用。**不能和 itemId 共用一个字段** ——
   *  「哪一台服务器」和「哪一个条目」是两个东西,混用的表现是进错页且不报错。 */
  serverId?: string;
  /** person 页:人物 id。**不复用 itemId** —— 演员在 Emby 里虽然也是个 Item,
   *  但「哪一个人」和「哪一个条目」是两条完全不同的取数路径,混用的表现是进错页且不报错。 */
  personId?: string;
  /** 设置二级页分流:playback / danmaku / network / sync / storage / about */
  group?: string;
  /** 单集页:季号 + 集号 */
  season?: number;
  ep?: number;
  title?: string;
};

/** 栈里的一格。key 是 React 的身份 —— 同一个页面被压两次必须是两格。 */
export type Frame = { key: string; route: Route };

/* ============================================================
   手工路由栈。

   与 desktop/tv 的**唯一区别**是:每个 Tab 各持一条独立的栈。

   ★ 为什么必须独立:手机上「切走再切回来」是最高频的动作。
     共用一条栈的话,用户在首页里翻到某部剧的详情 → 切去聚合视界 → 切回首页,
     看到的是首页顶层,刚才翻到哪儿全丢了。iOS/Android 两家的原生 Tab 容器
     都是每 Tab 一条栈,这是用户的肌肉记忆,不是我们的发挥空间。

   ★ 返回键的语义(优先级从高到低,由 App.tsx 编排):
       1. 有覆盖层(sheet/菜单)→ 关它
       2. 当前 Tab 的栈深 > 1 → 弹一层
       3. 不在 home Tab → 回 home Tab
       4. 在 home Tab 栈底 → 交给壳(退出应用)
     第 3 条是安卓的惯例(iOS 没有全局返回键所以没这一条),漏了它的表现是
     用户在服务器页按返回直接退出了应用。

   ★ `replace` 不是 `push`:单集页的「上一集 / 下一集」是**同一层**的横向移动。
     用 push 的话连按 5 次「下一集」要按 5 次返回才回得到剧详情页,
     而用户心里的返回目标始终是那部剧。
   ============================================================ */

const TAB_IDS: TabId[] = ["home", "aggregate", "servers"];

export type Nav = {
  tab: TabId;
  /** 三条栈全给出去。**三个 Tab 的 DOM 树是同时挂着的**(只有当前那条可见)——
   *  这样切走再切回来,滚动位置、已加载的数据、展开的分组全在。
   *  只挂当前那条的话切回来是重新挂载,首页那 15 条轨道要重新拉一遍。 */
  stacks: Record<TabId, Frame[]>;
  /** 当前 Tab 的整条栈(页面栈组件要全都挂着才做得出转场) */
  frames: Frame[];
  /** 当前 Tab 栈顶那一条 */
  route: Route;
  depth: number;
  /** 切 Tab。**再点一次当前 Tab = 回到该 Tab 的栈底**(安卓/iOS 通用惯例) */
  goTab: (t: TabId) => void;
  /** 在当前 Tab 上压一层 */
  push: (r: Route | PageId) => void;
  /** 原地换页,栈深度不变 */
  replace: (r: Route | PageId) => void;
  /** 弹一层。已在栈底返回 false —— 调用方据此决定是回 home 还是退出应用 */
  pop: () => boolean;
  /** 回当前 Tab 栈底 */
  popToRoot: () => void;
};

const mk = (r: Route | PageId, seq: number): Frame => ({
  key: `f${seq}`,
  route: typeof r === "string" ? { page: r } : r,
});

export function useNav(): Nav {
  const [tab, setTab] = useState<TabId>("home");
  /* 单调递增的帧序号。**不能拿 page+index 当 key** —— 从详情页再进详情页
     (相似推荐)会撞 key,React 会把两格当成同一格复用,表现是"进去了但内容没变"。 */
  const seq = useRef(0);
  const [stacks, setStacks] = useState<Record<TabId, Frame[]>>(() => {
    const init = {} as Record<TabId, Frame[]>;
    for (const t of TAB_IDS) init[t] = [mk(TAB_ROOT[t], seq.current++)];
    return init;
  });

  const frames = stacks[tab];
  const route = frames[frames.length - 1].route;

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
      setStacks((s) => ({ ...s, [tab]: [...s[tab], mk(r, seq.current++)] }));
    },
    [tab],
  );

  /* ★ 换到**同一种页面**时,帧的 key **原样保留**(2026-08-02)。
     用户原话:「点进第二集,整个页面感觉像被重新构建了一样,会发生跳动 ——
     我在哪个位置点击,页面就应该停留在哪个位置」。
     根因就在这里:原来每次 replace 都发一个新 key,React 据此判定是**另一个组件**,
     于是旧的 `.pg-body` 连同它的 scrollTop 一起被卸载,新的从头挂载 ——
     滚动位置归零、进场动画重放一遍,那就是"跳动"。
     key 不变则组件保持挂载、DOM 节点复用,只是 props 变了:滚动位置天然还在,
     页面自己按新的 itemId 重新取数即可(见 EpisodePage 的 effect)。
     ★ 只有页面**种类**变了才换 key —— 那种情况下复用 DOM 才是错的
       (两套完全不同的子树,React 会做一堆无意义的 diff,状态还会串)。 */
  const replace = useCallback(
    (r: Route | PageId) => {
      setStacks((s) => {
        const cur = s[tab];
        const top = cur[cur.length - 1];
        const next = typeof r === "string" ? { page: r } : r;
        const frame: Frame =
          top && top.route.page === next.page ? { key: top.key, route: next } : mk(next, seq.current++);
        return { ...s, [tab]: [...cur.slice(0, -1), frame] };
      });
    },
    [tab],
  );

  /* ★ 返回 boolean 而不是静默无操作:调用方(返回键)必须能区分
       「弹掉了一层」和「已经在栈底」—— 两者的下一步动作完全不同。 */
  const pop = useCallback(() => {
    if (stacks[tab].length <= 1) return false;
    setStacks((s) => ({ ...s, [tab]: s[tab].slice(0, -1) }));
    return true;
  }, [tab, stacks]);

  const popToRoot = useCallback(() => {
    setStacks((s) => (s[tab].length > 1 ? { ...s, [tab]: [s[tab][0]] } : s));
  }, [tab]);

  return useMemo(
    () => ({ tab, stacks, frames, route, depth: frames.length, goTab, push, replace, pop, popToRoot }),
    [tab, stacks, frames, route, goTab, push, replace, pop, popToRoot],
  );
}

export { TAB_IDS };
