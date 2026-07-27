import { useCallback, useEffect, useRef, useState, type ReactElement } from "react";
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
import { FULLSCREEN_PAGES, type PageId } from "./app/nav";
import { useNav, type Route } from "./app/router";
import PageBoundary from "./app/PageBoundary";
import Tabs from "./app/Tabs";
import TopBar from "./app/TopBar";
import MiniPlayer from "./components/MiniPlayer";
import AniRssPage from "./pages/AniRssPage";
import AddServerPage from "./pages/AddServerPage";
import CalendarPage from "./pages/CalendarPage";
import DetailPage from "./pages/DetailPage";
import DownloadsPage from "./pages/DownloadsPage";
import FavoritesPage from "./pages/FavoritesPage";
import HomePage from "./pages/HomePage";
import LibraryPage from "./pages/LibraryPage";
import LoginPage from "./pages/LoginPage";
import NetdiskPage from "./pages/NetdiskPage";
import PlayerPage from "./pages/PlayerPage";
import PluginsPage from "./pages/PluginsPage";
import RankingsPage from "./pages/RankingsPage";
import SearchPage from "./pages/SearchPage";
import ServersPage from "./pages/ServersPage";
import SettingsPage from "./pages/SettingsPage";

/** 侧滑返回:只在**左缘 20px** 起手才认。
 *  不设这个窗口的话,首页的横滑轨道拨一下就退出页面了 —— 轨道横滑优先,
 *  这是 README 里写死的三条手势冲突裁决之一。 */
const EDGE_PX = 20;
/** 松手阈值:走过屏宽 35%,或者速度够快(利落地一甩) */
const BACK_RATIO = 0.35;
const BACK_VELOCITY = 0.5;

export default function App() {
  /* undefined = 还在问核层要会话。**不能当"没登录"处理** —— 否则每次启动都闪一下首启页。 */
  const [session, setSession] = useState<LoginResult | null | undefined>(undefined);
  const [source, setSource] = useState<AccountInfo | null>(null);
  /** 正在播的条目。收进 MiniPlayer 后还要靠它显示片名、以及重新展开。 */
  const [playing, setPlaying] = useState<Item | null>(null);
  const [toast, setToast] = useState("");

  const nav = useNav();
  const { route, tab, depth, goTab, push, pop, popToRoot } = nav;

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

  /* 安卓物理返回键。优先级从内到外,漏掉任何一层都是一类具体的 bug:
       1) 覆盖层(sheet/面板)自己吃掉  —— 漏了:面板没关,页面先退了
       2) 当前 Tab 栈深 >1 → 弹一层     —— 漏了:详情页按返回直接退出应用
       3) 不在首页 Tab → 回首页 Tab     —— 漏了:在设置页按返回直接退出应用(安卓惯例)
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

  const openItem = useCallback((it: Item) => push({ page: "detail", itemId: it.id, title: it.name }), [push]);
  const goPage = useCallback(
    (page: PageId, parentId?: string, title?: string) => push({ page, parentId, title }),
    [push],
  );

  /* 起播。★ 与 TV 端同一条路:先 await play(),成功了才导航 ——
     反过来的话起播失败会停在一个空的播放页上,用户只看到黑屏。 */
  const playItem = useCallback(
    async (it: Item, mediaSourceId?: string | null) => {
      try {
        await play(it.id, it.resume_secs || 0, mediaSourceId ?? null);
        setPlaying(it);
        push({ page: "player", itemId: it.id, title: it.name });
      } catch (e) {
        setToast(`播放失败:${e}`);
      }
    },
    [push],
  );

  /* 侧滑返回。挂在页面容器上,只认左缘起手。
     ★ 播放页**不挂**(它的横滑是进度手势)—— 见下面 full 的判断。 */
  const pageRef = useRef<HTMLElement>(null);
  const swipe = useRef<{ x: number; t: number } | null>(null);
  const [swipeX, setSwipeX] = useState(0);

  const full = FULLSCREEN_PAGES.has(route.page);
  const canSwipeBack = !full && depth > 1;

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

  const bar = titleFor(route);
  /* 播放中且不在播放页 = 该出迷你播放器。
     ★ 它和底栏一样是 fixed,所以必须是 .page 的**兄弟**,不能塞进页面里 ——
       页面转场带 transform,fixed 会跟着一起滑走。 */
  const showMini = playing != null && route.page !== "player";

  return (
    <div className={`app${full ? " full" : ""}`}>
      {!full && (
        <TopBar
          title={bar.title}
          sub={bar.sub}
          onBack={depth > 1 ? () => void pop() : undefined}
        />
      )}

      <main
        className="page"
        ref={pageRef}
        key={`${tab}:${depth}`}
        style={swipeX ? { transform: `translateX(${swipeX}px)` } : undefined}
        onPointerDown={(e) => {
          if (!canSwipeBack || e.clientX > EDGE_PX) return;
          swipe.current = { x: e.clientX, t: e.timeStamp };
        }}
        onPointerMove={(e) => {
          if (!swipe.current) return;
          setSwipeX(Math.max(0, e.clientX - swipe.current.x));
        }}
        onPointerUp={(e) => {
          const s = swipe.current;
          swipe.current = null;
          if (!s) return;
          const dx = e.clientX - s.x;
          const v = dx / Math.max(1, e.timeStamp - s.t);
          setSwipeX(0);
          if (dx > window.innerWidth * BACK_RATIO || v > BACK_VELOCITY) void pop();
        }}
        onPointerCancel={() => {
          swipe.current = null;
          setSwipeX(0);
        }}
      >
        <PageBoundary resetKey={`${route.page}:${route.itemId ?? route.parentId ?? ""}`}>
          <Body
            route={route}
            session={session}
            playing={playing}
            onOpen={openItem}
            onGo={goPage}
            onPlay={playItem}
            onBack={() => void pop()}
            onStopped={() => setPlaying(null)}
          />
        </PageBoundary>
      </main>

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

      {toast && (
        <div className="toast" onClick={() => setToast("")}>
          {toast}
        </div>
      )}
    </div>
  );
}

function titleFor(r: Route): { title: string; sub?: string } {
  if (r.page === "home") return { title: "首页" };
  if (r.page === "search") return { title: "搜索" };
  if (r.page === "settings") return { title: "设置" };
  return { title: r.title ?? LABELS[r.page] ?? r.page };
}

const LABELS: Partial<Record<PageId, string>> = {
  library: "媒体库",
  favorites: "收藏",
  downloads: "下载",
  rankings: "排行榜",
  calendar: "追剧日历",
  servers: "服务器",
  addserver: "添加服务器",
  netdisk: "网盘",
  plugins: "插件",
  anirss: "Ani-RSS 订阅",
  detail: "详情",
};

function Body({
  route,
  session,
  playing,
  onOpen,
  onGo,
  onPlay,
  onBack,
  onStopped,
}: {
  route: Route;
  session: LoginResult | null;
  /** 正在播的条目。播放页拿它给弹幕自动匹配喂剧名/集号(route.title 是拼好的串,搜不到)。 */
  playing: Item | null;
  onOpen: (it: Item) => void;
  onGo: (p: PageId, parentId?: string, title?: string) => void;
  onPlay: (it: Item, mediaSourceId?: string | null) => void;
  onBack: () => void;
  onStopped: () => void;
}) {
  /* 只连了网盘的用户没有 Emby 会话 —— 依赖 session 的页面对他们一条都取不到。
     **不画一个全空的页面**,那看着像"加载失败"。 */
  const needSession = (node: (s: LoginResult) => ReactElement) =>
    session ? node(session) : (
      <Todo page={route.page} note="这一页要 Emby 会话。当前只登录了网盘/文件浏览型源。" />
    );

  switch (route.page) {
    case "home":
      return needSession((s) => <HomePage session={s} onOpen={onOpen} onGo={onGo} />);
    case "search":
      return needSession((s) => <SearchPage session={s} onOpen={onOpen} />);
    case "settings":
      return <SettingsPage onGo={onGo} />;
    case "library":
      return needSession((s) => (
        <LibraryPage
          session={s}
          parentId={route.parentId}
          onOpen={onOpen}
          onPickView={(v) => onGo("library", v.id, v.name)}
        />
      ));
    case "detail":
      return needSession((s) => (
        <DetailPage session={s} itemId={route.itemId} onPlay={onPlay} onOpen={onOpen} />
      ));
    case "player":
      return (
        <PlayerPage
          title={route.title}
          /* 弹幕自动匹配要剧名/集号/时长 —— route 里只有一个标题串,匹配不出东西。 */
          item={playing}
          onBack={() => {
            onStopped();
            onBack();
          }}
          /* 收起 ≠ 停止:只退出这一页,mpv 继续放,MiniPlayer 接管 */
          onMinimize={onBack}
        />
      );
    case "favorites":
      return needSession((s) => <FavoritesPage session={s} onOpen={onOpen} />);
    case "downloads":
      return <DownloadsPage />;
    case "rankings":
      return <RankingsPage onOpen={onOpen} />;
    case "calendar":
      return <CalendarPage />;
    case "servers":
      return <ServersPage onGo={onGo} />;
    case "addserver":
      return <AddServerPage onDone={onBack} />;
    case "netdisk":
      return <NetdiskPage onPlaySource={onBack} />;
    case "plugins":
      return <PluginsPage />;
    case "anirss":
      return <AniRssPage />;
    default:
      return <Todo page={route.page} />;
  }
}

/** 还没落的页。**故意写成一眼能认出是未完成** —— 不做假 UI。
 *  假 UI 在评审时会被当成"已经做好了",那比空白更贵。 */
function Todo({ page, note }: { page: PageId; note?: string }) {
  return (
    <div className="empty">
      <b>{LABELS[page] ?? page}</b>
      <div className="dim">{note ?? "这一页还没落地。规划见 ui/mobile/README.md 的分期表。"}</div>
    </div>
  );
}
