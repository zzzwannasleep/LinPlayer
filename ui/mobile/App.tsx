import { useCallback, useEffect, useState } from "react";
import {
  type AccountInfo,
  type Item,
  type LoginResult,
  currentSession,
  currentSource,
  onAccountsChanged,
} from "@shared/api";
import { consumeBack, onShellKey } from "./app/backkey";
import { FULLSCREEN_PAGES, type PageId } from "./app/nav";
import { useNav, type Route } from "./app/router";
import PageBoundary from "./app/PageBoundary";
import Tabs from "./app/Tabs";
import TopBar from "./app/TopBar";
import HomePage from "./pages/HomePage";
import LoginPage from "./pages/LoginPage";
import SearchPage from "./pages/SearchPage";
import SettingsPage from "./pages/SettingsPage";

export default function App() {
  /* undefined = 还在问核层要会话。**不能当"没登录"处理** ——
     否则每次启动都会先闪一下首启页。 */
  const [session, setSession] = useState<LoginResult | null | undefined>(undefined);
  const [source, setSource] = useState<AccountInfo | null>(null);

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
       4) 首页 Tab 栈底 → 交给壳(退出) —— 我们**不 preventDefault**,让 Activity 处理 */
  useEffect(
    () =>
      onShellKey((k) => {
        if (k !== "back") return;
        if (consumeBack()) return;
        if (pop()) return;
        if (tab !== "home") {
          goTab("home");
          return;
        }
        // 到这儿就是"首页栈底再按返回" —— 什么都不做,壳自己退出应用
      }),
    [pop, tab, goTab],
  );

  const openItem = useCallback((it: Item) => push({ page: "detail", itemId: it.id }), [push]);
  const goPage = useCallback(
    (page: PageId, parentId?: string, title?: string) => push({ page, parentId, title }),
    [push],
  );

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

  const full = FULLSCREEN_PAGES.has(route.page);
  const bar = titleFor(route);

  return (
    <div className={`app${full ? " full" : ""}`}>
      {!full && (
        <TopBar
          title={bar.title}
          sub={bar.sub}
          /* 栈底不给返回箭头 —— 画一个按下去没反应的箭头比不画更糟 */
          onBack={depth > 1 ? () => void pop() : undefined}
        />
      )}

      {/* ★ 页面容器和底栏是**兄弟**,不是父子。底栏是 position:fixed,
          而只要祖先带了 transform / will-change,fixed 就不再以视口为参照 ——
          页面转场一动,底栏就跟着滑走。PC 端和 TV 端各栽过一次。 */}
      <main className="page" key={`${tab}:${depth}`}>
        <PageBoundary resetKey={`${route.page}:${route.itemId ?? route.parentId ?? ""}`}>
          <Body route={route} session={session} onOpen={openItem} onGo={goPage} />
        </PageBoundary>
      </main>

      {!full && (
        <Tabs
          tab={tab}
          onTab={(t) => {
            // 点当前 Tab = 回该 Tab 栈底(安卓/iOS 通用惯例,useNav 里实现)
            if (t === tab && depth > 1) popToRoot();
            else goTab(t);
          }}
        />
      )}
    </div>
  );
}

function titleFor(r: Route): { title: string; sub?: string } {
  switch (r.page) {
    case "home":
      return { title: "首页" };
    case "search":
      return { title: "搜索" };
    case "settings":
      return { title: "设置" };
    default:
      return { title: r.title ?? LABELS[r.page] ?? r.page };
  }
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
  onOpen,
  onGo,
}: {
  route: Route;
  session: LoginResult | null;
  onOpen: (it: Item) => void;
  onGo: (p: PageId, parentId?: string, title?: string) => void;
}) {
  switch (route.page) {
    case "home":
      /* 只连了网盘的用户没有 Emby 会话 —— 首页那套(继续观看/媒体库轨道)对他们
         一条都取不到。**不画一个全空的首页**,那看着像"加载失败"。 */
      return session ? (
        <HomePage session={session} onOpen={onOpen} onGo={onGo} />
      ) : (
        <Todo page="home" note="当前只登录了网盘/文件浏览型源,首页轨道要 Emby 会话才有内容。" />
      );
    case "search":
      return session ? (
        <SearchPage session={session} onOpen={onOpen} />
      ) : (
        <Todo page="search" note="全服聚合搜索要 Emby 会话。网盘内搜索走网盘页。" />
      );
    case "settings":
      return <SettingsPage onGo={onGo} />;
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
