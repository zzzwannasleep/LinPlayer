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

/** 全局搜索浮层(草稿 PAGE 9):Ctrl K 唤起、Esc 收起,聚合开关按服务器分组。 */
export default function SearchOverlay({ session, onClose, onOpenItem }: Props) {
  const [q, setQ] = useState("");
  const [aggregate, setAggregate] = useState(true);
  /* ★ 开关的**当前值**要给防抖里的异步闭包读,但它**不能进 effect 依赖** ——
     进了依赖 = 一拨开关就重跑 effect、重发一轮搜索。用户 2026-07-15:
     「聚合搜索 我点开又关闭 会自行搜索 这是不对的」,而且聚合一次要打 N 台服务器,
     手一抖来回拨两下就是 2N 个请求。
     ref 是这里唯一能「读到最新值又不触发重跑」的办法(state 做不到:它一变就重渲染+重跑)。 */
  const aggRef = useRef(true);
  const [groups, setGroups] = useState<ServerGroup[] | null>(null);
  const [local, setLocal] = useState<Item[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [hist, setHist] = useState<string[]>(readHist);
  const inputRef = useRef<HTMLInputElement>(null);

  /* 右键菜单(标记已看/收藏)只给**本服**结果 —— 聚合结果属别的服务器,
     不先切服务器就右键会写到当前服上(错服)。所以聚合分组仍只「点=进详情」,
     由宿主 openFromSearch 负责先切服再开。悬停播放同理不给(搜索页 2026-07-15 定不起播)。 */
  const card = useCardActions(session);

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
        if (aggRef.current) {
          setGroups(await aggregateSearch(kw));
          setLocal(null);
        } else {
          /* 单服务器:走服务端 search。
             ★ 这里原来是「views() → 逐个 listItems(v.id) 全量拉 → 本地 .includes 过滤」,
               每敲一次键就把整个库拉一遍(N 个库 = N 次全量请求)。search 命令一直都在。 */
          setLocal(await search(kw, undefined, 40));
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
       eslint 会说 aggRef 不用进依赖(ref 本来就不用),这里也确实不需要。 */
  }, [q]);

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
              placeholder="搜索片名 / 聚合…"
            />
          </div>
          <button className={`pill${aggregate ? " on-pill" : ""}`} onClick={toggleAggregate}>
            聚合搜索
            <span className={`sw${aggregate ? " on" : ""}`} style={{ marginLeft: 4 }}>
              <i />
            </span>
          </button>
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
                输入片名开始搜索。聚合模式跨全部服务器。
              </div>
            </>
          )}

          {groups?.map((g) => (
            <section key={g.server_id}>
              <div className="ovl-grouplab">{g.server_name}</div>
              <div className="rail">
                {g.items.map((it) => (
                  <div className="r-poster" key={it.id}>
                    <Poster
                      item={it}
                      session={session}
                      onOpen={(x) => pick(x, g.server_id)}
                    />
                  </div>
                ))}
              </div>
            </section>
          ))}
          {groups && groups.length === 0 && !err && <div className="empty">没有找到结果</div>}

          {local && local.length > 0 && (
            <div className="dense-grid" style={{ padding: "4px 0 8px" }}>
              {local.map((it) => (
                <Poster key={it.id} item={it} session={session} onOpen={pick} onContextMenu={card.openCtx} />
              ))}
            </div>
          )}
          {local && local.length === 0 && !err && <div className="empty">没有找到结果</div>}
        </div>
      </div>
      {card.menu}
      {card.toastNode}
    </div>
  );
}
