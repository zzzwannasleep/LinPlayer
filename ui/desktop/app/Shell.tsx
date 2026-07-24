import { useEffect, useState } from "react";
import {
  type DownloadItem,
  type Item,
  type LoginResult,
  type SourceEntry,
  setActiveServer,
  getUpdateSettings,
  checkUpdate,
} from "@shared/api";
import SearchOverlay from "../components/SearchOverlay";
import { useTheme } from "@shared/theme";
import Sidebar from "./Sidebar";
import { type PageId } from "./nav";
import HomePage from "../pages/HomePage";
import LibraryPage from "../pages/LibraryPage";
import DetailPage from "../pages/DetailPage";
import FavoritesPage from "../pages/FavoritesPage";
import RankingsPage from "../pages/RankingsPage";
import DownloadsPage from "../pages/DownloadsPage";
import NetdiskPage from "../pages/NetdiskPage";
import ServersPage from "../pages/ServersPage";
import AddServerPage from "../pages/AddServerPage";
import SettingsPage from "../pages/SettingsPage";
import PluginsPage from "../pages/PluginsPage";
import PluginViewPage, { type PluginViewRef } from "../pages/PluginViewPage";
import { PluginUiHost } from "../components/PluginHost";
import AniRssPage from "../pages/AniRssPage";
import CalendarPage from "../pages/CalendarPage";
import PageBoundary from "./PageBoundary";

type Props = {
  session: LoginResult;
  /** 首屏落在哪一页。只连了网盘的用户没有 Emby 媒体库,首页是空的 → 直接进文件浏览。 */
  initialPage?: PageId;
  /** 第二参 = 详情页版本选择器选中的 MediaSource id,必须一路透传到 play()。 */
  onPlay: (it: Item, mediaSourceId?: string | null) => void;
  onPlaySource: (entry: SourceEntry) => void;
  /** 播放已下载完成的本地文件 —— 必须由 App 起播(mpv 窗口压在 Tauri 之下,
      只有 App 的 setPlaying 才会让画面露出来),页面自己调只会有声无画。 */
  onPlayDownload: (d: DownloadItem) => void;
  onSessionChange: () => void;
  searchOpen: boolean;
  onSearch: () => void;
  onCloseSearch: () => void;
};

/* 这里曾有个 connected: boolean,App 传的是写死的 true —— 拿它画状态点等于永远绿灯,
   状态点从来没反映过现实。已删。真状态由 Sidebar 自己 probeAccounts() 探(草稿标注 3/25 三态点)。 */
export default function Shell({
  session,
  initialPage,
  onPlay,
  onPlaySource,
  onPlayDownload,
  onSessionChange,
  searchOpen,
  onSearch,
  onCloseSearch,
}: Props) {
  const { theme, setTheme, toggle } = useTheme();
  const [page, setPage] = useState<PageId>(initialPage ?? "home");
  const [collapsed, setCollapsed] = useState(false);
  /* 当前打开的插件整页界面(侧栏的插件入口 / 插件详情页的「打开」都写它)。
     插件被停用时这里会留着一个指向不存在贡献点的引用 —— PluginSlot 查不到就画空,
     不会崩,用户点返回即可。 */
  const [pluginView, setPluginView] = useState<PluginViewRef | null>(null);
  const openPluginView = (v: PluginViewRef) => {
    setPluginView(v);
    setPage("pluginview");
  };
  const [libTarget, setLibTarget] = useState<Item | null>(null);
  const [detailStack, setDetailStack] = useState<Item[]>([]);
  const [reloadKey, setReloadKey] = useState(0);
  const detail = detailStack[detailStack.length - 1] ?? null;

  function nav(p: PageId) {
    setDetailStack([]);
    if (p === "library") setLibTarget(null);
    setPage(p);
  }
  function openLibrary(view: Item) {
    setDetailStack([]);
    setLibTarget(view);
    setPage("library");
  }
  const openDetail = (it: Item) => setDetailStack([it]);
  const pushDetail = (it: Item) => setDetailStack((s) => [...s, it]);
  const backDetail = () => setDetailStack((s) => s.slice(0, -1));

  /* 启动时自动检查更新(受设置页的「启动时自动检查」开关控制)。
     ★ 静默失败是**故意**的:自动检查失败(断网/GitHub 限流 60 次每小时)不该
     在用户一进门就弹个红字 —— 手动点「检查更新」时才如实报错。
     只提示一次,用户点「稍后」就不再烦他,下次启动再说。 */
  const [newVersion, setNewVersion] = useState<string | null>(null);
  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const s = await getUpdateSettings();
        if (!alive || !s.auto_check) return;
        const found = await checkUpdate();
        if (alive && found) setNewVersion(found.tag);
      } catch {
        /* 见上:自动检查失败不打扰用户 */
      }
    })();
    return () => {
      alive = false;
    };
  }, []);

  /* 通用规则 legend:「下拉刷新 → 工具栏刷新按钮 · F5」;标注 12:「Alt+← = 返回」。
     挂在 Shell 不挂 App:reloadKey / detailStack 都是 Shell 的状态。
     搜索浮层开着时不接管 —— 那时 F5 该由浮层自己管,而且 Alt+← 更没意义。 */
  useEffect(() => {
    if (searchOpen) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "F5") {
        e.preventDefault();
        setReloadKey((k) => k + 1);
        return;
      }
      // 只在详情栈非空时吃掉 Alt+←,否则用户在别处按会以为没反应。
      if (e.altKey && e.key === "ArrowLeft" && detailStack.length > 0) {
        e.preventDefault();
        backDetail();
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [searchOpen, detailStack.length]);

  /**
   * 聚合搜索的结果可能属于别的服务器。核层 item_detail/play 都走「当前活跃服务器」,
   * 不先切服务器就会拿 B 服的 itemId 去打 A 服 —— 必然 404 或播错片。
   * serverId 为空(本服结果)时不切,省一次往返。
   */
  async function openFromSearch(it: Item, serverId?: string) {
    onCloseSearch();
    if (serverId && serverId !== session.server) {
      try {
        await setActiveServer(serverId);
        onSessionChange();
      } catch {
        return; // 切服失败就别往下走,否则打错服务器
      }
    }
    openDetail(it);
  }

  /* 这个 key 同时干两件事:换页时重挂 .page(入场动画),以及重置错误边界 ——
     不重置的话某页崩过一次,切走再切回来它还顶着错误页。 */
  const pageKey = detail ? `d:${detail.id}` : page + (libTarget?.id ?? "");

  const body = (() => {
    switch (page) {
      case "home":
        return (
          <HomePage
            session={session}
            onOpenLibrary={openLibrary}
            onOpenItem={openDetail}
            onPlay={onPlay}
            onSearch={onSearch}
            onRefresh={() => setReloadKey((k) => k + 1)}
            reloadKey={reloadKey}
          />
        );
      case "library":
        return (
          <LibraryPage
            session={session}
            view={libTarget}
            onPickView={setLibTarget}
            onBack={() => setLibTarget(null)}
            onOpenItem={openDetail}
            onPlay={onPlay}
            onSearch={onSearch}
          />
        );
      case "favorites":
        return <FavoritesPage session={session} onOpenItem={openDetail} onPlay={onPlay} />;
      case "rankings":
        return <RankingsPage onOpenItem={openFromSearch} />;
      case "downloads":
        return <DownloadsPage onPlayLocal={onPlayDownload} />;
      case "netdisk":
        return <NetdiskPage onPlay={onPlaySource} onBack={() => nav("servers")} />;
      case "anirss":
        return <AniRssPage onBack={() => nav("servers")} />;
      case "calendar":
        return <CalendarPage onOpenItem={openFromSearch} />;
      case "servers":
        return (
          <ServersPage
            session={session}
            activeServer={session.server}
            onChanged={onSessionChange}
            onGoAdd={() => nav("addserver")}
            /* 草稿 L1216:点 Emby 卡 → 进首页;点网盘/文件源卡 → 进文件浏览。
               不接这个 prop 的话切了服务器仍停在服务器页,pin 25 就是半截的。 */
            onEnter={(src) => nav(src ?? "home")}
          />
        );
      case "addserver":
        return (
          <AddServerPage
            // 登录的是文件源时直接进对应浏览页,不绕回服务器页(Emby 才需要刷会话)。
            onDone={(src) => {
              if (src) return nav(src);
              onSessionChange();
              nav("servers");
            }}
            onBack={() => nav("servers")}
          />
        );
      case "plugins":
        return <PluginsPage onOpenView={openPluginView} />;
      case "pluginview":
        // 直接把 page 切过来但没设 view(不该发生)时退回插件页,别白屏。
        return pluginView ? (
          <PluginViewPage view={pluginView} onBack={() => nav("plugins")} />
        ) : (
          <PluginsPage onOpenView={openPluginView} />
        );
      case "settings":
        return <SettingsPage theme={theme} setTheme={setTheme} />;
    }
  })();

  return (
    <div className="app-surface">
      <div className="shell">
        <Sidebar
          page={page}
          onNav={nav}
          onOpenPluginView={openPluginView}
          activePluginView={page === "pluginview" ? pluginView : null}
          collapsed={collapsed}
          onToggleCollapse={() => setCollapsed((v) => !v)}
          activeServer={session.server}
          onSwitched={onSessionChange}
          theme={theme}
          onToggleTheme={toggle}
        />
        <div className="content">
          <div className="immersive" />
          {newVersion && (
            <div className="update-banner">
              <span>发现新版本 {newVersion}</span>
              <button
                type="button"
                className="btn"
                onClick={() => {
                  setNewVersion(null);
                  nav("settings");
                }}
              >
                去更新
              </button>
              <button type="button" className="btn ghost" onClick={() => setNewVersion(null)}>
                稍后
              </button>
            </div>
          )}
          {/* 错误边界包在 .page 里面:炸的只是这一页,侧栏照常在,还能切走。
              不包的话任何一页渲染抛错都会卸载整棵树 —— 而窗口是透明的,
              看起来就是「整个 app 黑屏、打都打不开」(2026-07-16 追剧日历真炸过)。 */}
          <div className="page" key={pageKey}>
            <PageBoundary resetKey={pageKey}>
              {detail ? (
                <DetailPage
                  session={session}
                  item={detail}
                  onPlay={onPlay}
                  onOpenChild={pushDetail}
                  onBack={backDetail}
                  onSessionChange={onSessionChange}
                />
              ) : (
                body
              )}
            </PageBoundary>
          </div>
        </div>
      </div>

      {/* 插件弹出的 UI(toast/对话框/表单/列表/进度)。挂 Shell 是因为它必须
          盖在任何一页之上,而且切页时不能被卸载 —— 插件那边的 await 还悬着。 */}
      <PluginUiHost />

      {/* 搜索浮层挂在 Shell 而非 App:它要用 openDetail(点结果进详情,不是直接开播)和切服务器。 */}
      {searchOpen && (
        <SearchOverlay session={session} onClose={onCloseSearch} onOpenItem={openFromSearch} />
      )}
    </div>
  );
}
