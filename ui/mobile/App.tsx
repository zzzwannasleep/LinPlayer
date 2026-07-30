import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  type AccountInfo,
  type Item,
  type LoginResult,
  currentSession,
  currentSource,
  onAccountsChanged,
  play,
} from "@shared/api";
import { consumeBack, onShellKey } from "./app/backkey";
import { PageCtx, type Ctx } from "./app/ctx";
import { FULLSCREEN_PAGES, TABS, type PageId, type TabId } from "./app/nav";
import { flipTo, toast, wait, type FlipSource } from "./app/motion";
import PageStack from "./app/PageStack";
import PageBoundary from "./app/PageBoundary";
import Tabs from "./app/Tabs";
import { useNav, type Frame, type Route } from "./app/router";
import MiniPlayer from "./components/MiniPlayer";
import { Empty } from "./components/ui";

import HomePage from "./pages/HomePage";
import AggregatePage, { ResumePage } from "./pages/AggregatePage";
import SearchPage from "./pages/SearchPage";
import LibraryPage from "./pages/LibraryPage";
import FavoritesPage from "./pages/FavoritesPage";
import DownloadsPage from "./pages/DownloadsPage";
import RankingsPage from "./pages/RankingsPage";
import CalendarPage from "./pages/CalendarPage";
import DetailPage from "./pages/DetailPage";
import EpisodePage from "./pages/EpisodePage";
import PlayerPage from "./pages/PlayerPage";
import SettingsPage, { SettingsSubPage } from "./pages/SettingsPage";
import ServersPage from "./pages/ServersPage";
import AddServerPage from "./pages/AddServerPage";
import LinesPage from "./pages/LinesPage";
import IconPage from "./pages/IconPage";
import NetdiskPage from "./pages/NetdiskPage";
import PluginsPage from "./pages/PluginsPage";
import AniRssPage from "./pages/AniRssPage";
import LoginPage from "./pages/LoginPage";

export default function App() {
  /* undefined = 还在问核层要会话。**不能当"没登录"处理** —— 否则每次启动都闪一下首启页。 */
  const [session, setSession] = useState<LoginResult | null | undefined>(undefined);
  const [source, setSource] = useState<AccountInfo | null>(null);
  /** 正在播的条目。收进 MiniPlayer 后还要靠它显示片名、以及重新展开。 */
  const [playing, setPlaying] = useState<Item | null>(null);

  const nav = useNav();
  const { tab, stacks, route, depth, goTab, push, replace, pop, popToRoot } = nav;

  /* 会话闸口。
     ★ **必须同时问 currentSession 和 currentSource。**
       核层的 current_session 是 `.filter(|a| !a.is_file_browse())` —— 只连了网盘的用户
       在那边永远返回 null。宿主只判 session 的话,这类用户加完源仍被挡在登录页外,
       加一次挡一次。这个坑 PC 端栽过,别在手机端再栽一遍。 */
  const loadGate = useCallback(
    () =>
      Promise.allSettled([currentSession(), currentSource()]).then(([s, c]) => {
        setSession(s.status === "fulfilled" ? s.value : null);
        setSource(c.status === "fulfilled" ? c.value : null);
      }),
    [],
  );
  useEffect(() => {
    loadGate();
    return onAccountsChanged(loadGate);
  }, [loadGate]);

  /* 撤掉 index-mobile.html 里那块启动动画。
     ★ 撤的时机是**会话闸口出结果**,不是 React 挂载完 —— 挂载完到会话回来之间
       还有一段问核层的空窗(真机上是几十到几百毫秒),那段时间第一帧什么都没有。
       撤早了用户看到的就是"启动动画闪一下 → 黑一下 → 才进来"。 */
  useEffect(() => {
    if (session === undefined) return;
    const b = document.getElementById("boot");
    if (!b) return;
    b.classList.add("off");
    const t = setTimeout(() => b.remove(), 200);
    return () => clearTimeout(t);
  }, [session]);

  /* 安卓物理返回键。优先级从内到外,漏掉任何一层都是一类具体的 bug:
       1) 覆盖层(sheet/菜单)自己吃掉  —— 漏了:面板没关,页面先退了
       2) 当前 Tab 栈深 >1 → 弹一层     —— 漏了:详情页按返回直接退出应用
       3) 不在首页 Tab → 回首页 Tab     —— 漏了:在服务器页按返回直接退出应用(安卓惯例)
       4) 首页 Tab 栈底 → 交给壳(退出) —— 我们**不做任何事**,让 Activity 处理 */
  useEffect(
    () =>
      onShellKey((k) => {
        if (k !== "back") return;
        if (consumeBack()) return;
        if (pop()) return;
        if (tab !== "home") goTab("home");
      }),
    [pop, tab, goTab],
  );

  /* ── FLIP 共享元素 ──
     卡片 → 详情页 Hero。起点在点卡片的那一刻记下来(此时卡片还在屏幕上),
     终点由详情页挂载后自己认领。★ 起点必须**当场**取,等 push 之后卡片已经
     跟着旧页滑走了,getBoundingClientRect 拿到的是滑到一半的位置。 */
  const flip = useRef<FlipSource | null>(null);

  const openItem = useCallback(
    (it: Item, from?: FlipSource | null) => {
      flip.current = from ?? null;
      push({ page: "detail", itemId: it.id, title: it.name });
    },
    [push],
  );

  /** 详情页 Hero 挂好后调它,把卡片那张图飞过来。 */
  const claimFlip = useCallback(async (el: HTMLElement | null) => {
    const from = flip.current;
    flip.current = null;
    if (!from || !el) return;
    /* 等一帧让新页排好版 —— 立刻量的话 Hero 还没拿到最终尺寸,飞过去会错位。 */
    await wait(16);
    await flipTo(from, el);
  }, []);

  /* 起播。★ 与 TV 端同一条路:先 await play(),成功了才导航 ——
     反过来的话起播失败会停在一个空的播放页上,用户只看到黑屏。 */
  const playItem = useCallback(
    async (it: Item, mediaSourceId?: string | null) => {
      try {
        await play(it.id, it.resume_secs || 0, mediaSourceId ?? null);
        setPlaying(it);
        push({ page: "player", itemId: it.id, title: it.name });
      } catch (e) {
        toast(`播放失败:${e}`, "bad");
      }
    },
    [push],
  );

  const ctx = useMemo<Ctx>(
    () => ({
      session: session ?? null,
      route,
      go: push,
      replace,
      back: () => void pop(),
      openItem,
      play: playItem,
      reloadGate: () => void loadGate(),
    }),
    [session, route, push, replace, pop, openItem, playItem, loadGate],
  );

  /* ── 切 Tab 的 fade-through ──
     旧的先淡出并轻微缩小(90ms),新的延后 90ms 淡入。
     ★ 不用横向滑动 —— 底栏三个目的地是**平级**的,横滑意味着"有前后顺序"。
     ★ 三条栈的 DOM 全程挂着,切换只动 hidden 和两个动画类。

     ★★ `hidden` **完全由这个 effect 管,不能同时写成 JSX 属性**。
     两边一起写会出一个只有真渲染才现形的 bug:JSX 上写 `hidden={t.id !== tab}` 的话,
     React 认为这个属性归它管;而这里为了做转场又直接改 `el.hidden` ——
     等 React 下一次 render 时,它比对**自己上一次的虚拟值**发现没变,于是
     **不会把属性写回去**。表现是切过一次 Tab 之后,被藏起来那条栈的 `hidden`
     属性永远消失了,三条栈全部可见叠在一起。
     实测症状:在「首页」Tab 上量到的却是「服务器」那条栈的内容 —— 因为
     `document.querySelector` 一路匹配到了最后一条。 */
  /* ★ 容器用 **callback ref 存进 state**,不用 useRef。
     useRef 版本有一个只有冷启动才现形的 bug:第一次 render 时 `session === undefined`,
     组件早退成 `<div className="app" />` —— `.stacks` **根本不在 DOM 里**,
     于是这个 effect 拿到 null 直接 return,`prevTab` 还停在 null。
     等会话回来第二次 render 把 `.stacks` 挂上时,`tab` 一个字都没变 ——
     依赖数组是 `[tab]`,**effect 不会再跑**。结果:三条栈的 `hidden` 谁也没摘,
     `.stack[hidden]{display:none}` 把整个应用画成一块空屏,只剩底栏那条胶囊浮着。
     再点「首页」也没用:`setTab("home")` 值没变,React 直接 bail out。
     必须点一次别的 Tab 才会活过来。
     把容器本身放进依赖里,DOM 一挂上就重跑一次,这条时序缝就没了。 */
  const [stacksEl, setStacksEl] = useState<HTMLDivElement | null>(null);
  const prevTab = useRef<TabId | null>(null);
  useEffect(() => {
    const root = stacksEl;
    if (!root) return;
    const all = [...root.querySelectorAll<HTMLElement>(".stack")];
    const to = all.find((s) => s.dataset.tab === tab);
    if (!to) return;

    // 首次挂载:直接定住,不放动画(第一屏凭空淡入很怪)
    if (prevTab.current === null) {
      all.forEach((s) => (s.hidden = s !== to));
      prevTab.current = tab;
      return;
    }
    if (prevTab.current === tab) return;
    const from = all.find((s) => s.dataset.tab === prevTab.current);
    prevTab.current = tab;
    if (!from) return;

    from.classList.add("tab-out");
    to.hidden = false;
    to.classList.add("tab-in");
    const t1 = setTimeout(() => {
      // 除了新的那条,其余一律藏起来 —— 只藏 from 的话,中途快速连点会漏掉一条
      all.forEach((s) => (s.hidden = s !== to));
      from.classList.remove("tab-out");
    }, 90);
    const t2 = setTimeout(() => to.classList.remove("tab-in"), 400);
    return () => {
      clearTimeout(t1);
      clearTimeout(t2);
    };
  }, [tab, stacksEl]);

  const full = FULLSCREEN_PAGES.has(route.page);

  if (session === undefined) {
    // 首帧什么都不画。有会话就直接进首页,没有才画登录页 —— 中间不闪任何东西
    return <div className="app" />;
  }

  /* 一台源都没有 → 首启。此时不画底栏:三个 Tab 一个都点不动,
     只会让用户在空页面之间转圈。 */
  if (!session && !source) {
    return (
      <div className="app">
        <PageBoundary resetKey="login">
          <LoginPage onLoggedIn={loadGate} />
        </PageBoundary>
      </div>
    );
  }

  /* 播放中且不在播放页 = 该出迷你播放器。
     ★ 它和底栏一样在页面栈**外面**,不能塞进页面里 —— 页面转场带 transform,
       它会跟着一起滑走。 */
  const showMini = playing != null && route.page !== "player";

  return (
    <PageCtx.Provider value={ctx}>
      <div className={`app${full ? "" : " has-tabs"}`}>
        <div className="stacks" ref={setStacksEl}>
          {/* ★ `.stack` 上**故意不写受控的 `hidden`** —— 可见性全由上面那个 effect 管
              (理由写在那里)。这里一律先 `hidden`,effect 在挂载时立刻把当前那条打开,
              这样第一帧也不会三条栈叠在一起闪一下。 */}
          {TABS.map((t) => (
            <div className="stack" data-tab={t.id} key={t.id} hidden>
              <PageStack
                frames={stacks[t.id]}
                onPop={() => void pop()}
                /* 播放页禁用侧滑返回 —— 它的横滑要留给进度手势。
                   这是 README 里写死的三条手势冲突裁决之一。 */
                canSwipe={(f) => !FULLSCREEN_PAGES.has(f.route.page)}
                render={(f) => (
                  <PageBoundary resetKey={f.key}>
                    <Body
                      frame={f}
                      playing={playing}
                      onClaimFlip={claimFlip}
                      onStopped={() => setPlaying(null)}
                    />
                  </PageBoundary>
                )}
              />
            </div>
          ))}
        </div>

        {showMini && (
          <MiniPlayer
            title={playing?.name}
            onExpand={() => push({ page: "player", itemId: playing!.id, title: playing!.name })}
            onClose={() => setPlaying(null)}
          />
        )}

        {!full && (
          <Tabs
            tab={tab}
            onTab={(t) => {
              if (t === tab && depth > 1) popToRoot();
              else goTab(t);
            }}
          />
        )}
      </div>
    </PageCtx.Provider>
  );
}

function Body({
  frame,
  playing,
  onClaimFlip,
  onStopped,
}: {
  frame: Frame;
  /** 正在播的条目。播放页拿它给弹幕自动匹配喂剧名/集号(route.title 是拼好的串,搜不到)。 */
  playing: Item | null;
  onClaimFlip: (el: HTMLElement | null) => void;
  onStopped: () => void;
}) {
  const r: Route = frame.route;
  switch (r.page) {
    case "home":
      return <HomePage />;
    case "aggregate":
      return <AggregatePage />;
    case "resume":
      return <ResumePage />;
    case "search":
      return <SearchPage />;
    case "library":
      return <LibraryPage parentId={r.parentId} title={r.title} />;
    case "favorites":
      return <FavoritesPage />;
    case "downloads":
      return <DownloadsPage />;
    case "rankings":
      return <RankingsPage />;
    case "calendar":
      return <CalendarPage />;
    case "detail":
      return <DetailPage itemId={r.itemId} onHero={onClaimFlip} />;
    case "episode":
      return <EpisodePage itemId={r.itemId} season={r.season} ep={r.ep} />;
    case "player":
      return <PlayerPage title={r.title} item={playing} onStopped={onStopped} />;
    case "settings":
      return <SettingsPage />;
    case "settingsSub":
      return <SettingsSubPage group={r.group} />;
    case "servers":
      return <ServersPage />;
    case "addServer":
      return <AddServerPage />;
    case "lines":
      return <LinesPage serverId={r.serverId} />;
    case "icon":
      return <IconPage serverId={r.serverId} />;
    case "netdisk":
      return <NetdiskPage />;
    case "plugins":
      return <PluginsPage />;
    case "anirss":
      return <AniRssPage />;
    default:
      return <Unknown page={r.page} />;
  }
}

/** 路由表漏了一格。**故意写成一眼能认出是漏的** —— 不做假 UI。 */
function Unknown({ page }: { page: PageId }) {
  return (
    <div className="pg-body">
      <Empty
        icon="info"
        title={`没有「${page}」这一页`}
        desc="路由表和入口对不上了。加页面要同时改 app/nav.ts 的 PageId 和 App.tsx 的 Body —— 只改一处的表现就是这个。"
      />
    </div>
  );
}
