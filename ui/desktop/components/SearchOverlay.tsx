import { useEffect, useRef, useState } from "react";
import { type Item, type LoginResult, type ServerGroup, aggregateSearch, search } from "@shared/api";
import { useCardActions } from "../lib/cardActions";
import Poster from "./Poster";
import { IconSearch } from "../app/icons";
import "./SearchOverlay.css";

type Props = {
  session: LoginResult;
  onClose: () => void;
  /** serverId:该结果所属服务器(聚合搜可能跨服),宿主据此先切服务器再开详情。
      ★ 搜索结果只有这一个操作:点 = 进详情。不从这里起播(用户 2026-07-15 定)。 */
  onOpenItem: (it: Item, serverId?: string) => void;
  /** 库内搜索:只在这个媒体库里找。不给 = 全服务器搜(首页那个入口)。
      ★ 和聚合互斥 —— 聚合是「跨全部服务器」,和「只在本服的这个库里」是反义词,
        所以有 scope 时聚合开关整个不出现,别让用户拨一个必然会打破范围的开关。 */
  scope?: { id: string; name: string } | null;
};

/* 搜索历史(标注 34)。localStorage 存,封顶 8 条 —— 就一个字符串数组,不值得进核层配置。 */
const HIST_KEY = "lp.search.history";
const HIST_MAX = 8;

function readHist(): string[] {
  try {
    const v: unknown = JSON.parse(localStorage.getItem(HIST_KEY) ?? "[]");
    // 存的东西可能被别的版本/用户手改坏 → 逐项校验,坏了就当空,不让它把浮层搞崩。
    return Array.isArray(v) ? v.filter((x): x is string => typeof x === "string").slice(0, HIST_MAX) : [];
  } catch {
    return [];
  }
}
function writeHist(next: string[]): string[] {
  try {
    localStorage.setItem(HIST_KEY, JSON.stringify(next));
  } catch {
    // 隐私模式/配额满:历史丢了不影响搜索本身,不打扰用户。
  }
  return next;
}

/** 搜索浮层(草稿 PAGE 9):Ctrl K 唤起、Esc 收起,聚合开关按服务器分组。
 *  传了 `scope` 就变成库内搜索(媒体库顶栏那个入口)。 */
export default function SearchOverlay({ session, onClose, onOpenItem, scope }: Props) {
  const [q, setQ] = useState("");
  const [aggregate, setAggregate] = useState(!scope);
  /* 「包括集」。**默认关**:搜「凡人」应该先看到那部剧,而不是被 200 集分集淹掉。
     ★ 和聚合开关**故意不同**:这个进 effect 依赖 = 一拨就重搜。
       聚合不重搜是因为它一次要打 N 台服务器(用户 2026-07-15 报的);
       这个只多打一次当前服,而用户拨它就是为了立刻看到分集 —— 不重搜才是坏的。 */
  const [withEp, setWithEp] = useState(false);
  /* ★ 开关的**当前值**要给防抖里的异步闭包读,但它**不能进 effect 依赖** ——
     进了依赖 = 一拨开关就重跑 effect、重发一轮搜索。用户 2026-07-15:
     「聚合搜索 我点开又关闭 会自行搜索 这是不对的」,而且聚合一次要打 N 台服务器,
     手一抖来回拨两下就是 2N 个请求。
     ref 是这里唯一能「读到最新值又不触发重跑」的办法(state 做不到:它一变就重渲染+重跑)。 */
  const aggRef = useRef(!scope);
  const [groups, setGroups] = useState<ServerGroup[] | null>(null);
  const [local, setLocal] = useState<Item[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [hist, setHist] = useState<string[]>(readHist);
  const inputRef = useRef<HTMLInputElement>(null);

  /* 右键菜单(标记已看/收藏)只给**本服**结果 —— 聚合结果属别的服务器,
     不先切服务器就右键会写到当前服上(错服)。所以聚合分组仍只「点=进详情」,
     由宿主 openFromSearch 负责先切服再开。悬停播放同理不给(搜索页 2026-07-15 定不起播)。 */
  const card = useCardActions(session, {
    /* 屏蔽后这一屏立刻少一张。核层的 search 已经不再吐它,但结果是本组件手里的副本。
       只动本服那一份:聚合分组来自别的服务器,右键菜单本来就不给它们(见上面那段)。 */
    onBlockChanged: (it, blocked) =>
      blocked && setLocal((cur) => (cur ? cur.filter((x) => x.id !== it.id) : cur)),
  });

  /** 拨开关:只改「下一次搜用哪个模式」,**不搜**。当前结果原样留着。 */
  const toggleAggregate = () => {
    setAggregate((v) => {
      aggRef.current = !v;
      return !v;
    });
  };

  useEffect(() => {
    inputRef.current?.focus();
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && onClose();
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);

  // 输入防抖搜索。
  useEffect(() => {
    const kw = q.trim();
    if (!kw) {
      setGroups(null);
      setLocal(null);
      setErr("");
      setBusy(false);
      return;
    }
    setBusy(true);
    const t = window.setTimeout(async () => {
      setErr("");
      try {
        /* 类型**必须显式传**:不传时核层默认 Movie,Series,Episode —— 那就是「永远包括集」。
           核层拿到显式类型后还会自己滤一遍(有的服务端带 SearchTerm 时忽略
           IncludeItemTypes,见 emby::filter_types),所以这个开关在哪台服上都是真的。 */
        const types = withEp ? ["Movie", "Series", "Episode"] : ["Movie", "Series"];
        if (aggRef.current) {
          setGroups(await aggregateSearch(kw, withEp));
          setLocal(null);
        } else {
          /* 单服务器:走服务端 search。
             ★ 这里原来是「views() → 逐个 listItems(v.id) 全量拉 → 本地 .includes 过滤」,
               每敲一次键就把整个库拉一遍(N 个库 = N 次全量请求)。search 命令一直都在。 */
          // scope?.id = 库内搜索的范围;不传就是全服务器(首页入口)。
          setLocal(await search(kw, types, 40, scope?.id));
          setGroups(null);
        }
      } catch (e) {
        // 原来这里 catch 后 setGroups([]) → 报错被显示成「没有找到结果」。
        // 搜挂了和搜不到是两回事,合并就等于骗人。
        setErr(String(e));
        setGroups(null);
        setLocal(null);
      } finally {
        setBusy(false);
      }
    }, 320);
    return () => window.clearTimeout(t);
    /* 依赖只有 q:**别把 aggregate 加回来**(见 aggRef 上的注释)。
       scope 也别加 —— 浮层是「开一次建一次」,它在整个生命周期内不变,
       而它是个字面量对象,每次渲染都是新引用,进了依赖就是每帧重搜。 */
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q, withEp]);

  /* 只在用户真的点开了某个结果时才记历史 —— 跟着防抖记的话,
     打「阿凡达」会把「阿」「阿凡」「阿凡达」全记进去。 */
  const remember = () => {
    const kw = q.trim();
    if (kw) setHist((h) => writeHist([kw, ...h.filter((x) => x !== kw)].slice(0, HIST_MAX)));
  };
  const pick = (it: Item, serverId?: string) => {
    remember();
    onOpenItem(it, serverId); // 关浮层交给宿主(它可能要先切服务器)
  };

  /* 分集和剧/电影**分栏画**:一个是 16:9 剧照、一个是 2:3 海报,
     混在同一个网格里必然一行高矮不齐(而且分集数量常常压倒剧本身)。 */
  const isEp = (it: Item) => it.type_ === "Episode";
  const epGrid = (items: Item[], serverId?: string) => (
    <>
      <div className="ovl-grouplab">分集</div>
      <div className="ovl-epgrid">
        {items.map((it, i) => (
          <Poster
            key={it.id}
            item={it}
            session={session}
            variant="thumb"
            index={i}
            onOpen={(x) => pick(x, serverId)}
            /* 右键只给本服结果 —— 同上面 useCardActions 那段的理由(跨服会写错服务器)。 */
            onContextMenu={serverId ? undefined : card.openCtx}
          />
        ))}
      </div>
    </>
  );


  return (
    <div className="ovl-scrim" onClick={onClose}>
      <div className="ovl" onClick={(e) => e.stopPropagation()}>
        <div className="ovl-top">
          <div className="ovl-input">
            <IconSearch size={17} />
            <input
              ref={inputRef}
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder={scope ? `在「${scope.name}」中搜索…` : "搜索片名 / 聚合…"}
            />
          </div>
          <button
            className={`pill${withEp ? " on-pill" : ""}`}
            onClick={() => setWithEp((v) => !v)}
            title="关:只搜剧和电影;开:分集也搜,单独一栏用横版剧照显示"
          >
            包括集
            <span className={`sw${withEp ? " on" : ""}`} style={{ marginLeft: 4 }}>
              <i />
            </span>
          </button>
          {scope ? (
            // 范围徽标:不写清楚「只在这个库里」,搜不到东西时用户会以为搜索坏了。
            <span className="pill on-pill" title={`只搜索媒体库「${scope.name}」`}>
              库内：{scope.name}
            </span>
          ) : (
            <button className={`pill${aggregate ? " on-pill" : ""}`} onClick={toggleAggregate}>
              聚合搜索
              <span className={`sw${aggregate ? " on" : ""}`} style={{ marginLeft: 4 }}>
                <i />
              </span>
            </button>
          )}
          <span className="kbd">Esc</span>
        </div>

        <div className="ovl-body">
          {busy && <div className="spinner" style={{ margin: "20px auto" }} />}
          {err && <div className="empty" style={{ padding: "20px 4px", color: "var(--danger)" }}>搜索失败：{err}</div>}

          {/* 标注 34:空态显示搜索历史 chips。 */}
          {!q.trim() && (
            <>
              {hist.length > 0 && (
                <>
                  <div className="ovl-grouplab">最近搜索</div>
                  <div className="chipbar" style={{ padding: "2px 2px 10px" }}>
                    {hist.map((h) => (
                      <span className="genre ovl-chip" key={h}>
                        <span className="ovl-chip-t" onClick={() => setQ(h)}>
                          {h}
                        </span>
                        <span
                          className="x"
                          title="从历史中删除"
                          onClick={() => setHist((cur) => writeHist(cur.filter((x) => x !== h)))}
                        >
                          ✕
                        </span>
                      </span>
                    ))}
                    <span
                      className="genre"
                      style={{ cursor: "pointer" }}
                      onClick={() => setHist(writeHist([]))}
                    >
                      清除
                    </span>
                  </div>
                </>
              )}
              <div className="empty" style={{ padding: "18px 4px" }}>
                {scope ? `输入片名,只在「${scope.name}」里搜。` : "输入片名开始搜索。聚合模式跨全部服务器。"}
              </div>
            </>
          )}

          {groups?.map((g) => (
            <section key={g.server_id}>
              <div className="ovl-grouplab">{g.server_name}</div>
              <div className="rail">
                {g.items.filter((it) => !isEp(it)).map((it) => (
                  <div className="r-poster" key={it.id}>
                    <Poster
                      item={it}
                      session={session}
                      onOpen={(x) => pick(x, g.server_id)}
                    />
                  </div>
                ))}
              </div>
              {/* 分集走横版剧照,和上面那条竖海报轨道分开(混一条里高矮不齐)。 */}
              {g.items.some(isEp) && (
                <div className="rail">
                  {g.items.filter(isEp).map((it) => (
                    <div className="r-wide" key={it.id}>
                      <Poster
                        item={it}
                        session={session}
                        variant="thumb"
                        onOpen={(x) => pick(x, g.server_id)}
                      />
                    </div>
                  ))}
                </div>
              )}
            </section>
          ))}
          {groups && groups.length === 0 && !err && <div className="empty">没有找到结果</div>}

          {local && local.some((it) => !isEp(it)) && (
            <div className="dense-grid" style={{ padding: "4px 0 8px" }}>
              {local.filter((it) => !isEp(it)).map((it) => (
                <Poster key={it.id} item={it} session={session} onOpen={pick} onContextMenu={card.openCtx} />
              ))}
            </div>
          )}
          {local && local.some(isEp) && epGrid(local.filter(isEp))}
          {local && local.length === 0 && !err && (
            <div className="empty">
              没有找到结果{!withEp && "。分集不在搜索范围内 —— 打开「包括集」再试一次。"}
            </div>
          )}
        </div>
      </div>
      {card.menu}
      {card.toastNode}
    </div>
  );
}
