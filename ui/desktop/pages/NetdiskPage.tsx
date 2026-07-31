import { type CSSProperties, type ReactNode, useEffect, useMemo, useState } from "react";
import { type SourceEntry, sourceListDir, sourceSearch } from "@shared/api";
import {
  IconChevronDown,
  IconChevronRight,
  IconDownload,
  IconFile,
  IconFolder,
  IconPlay,
  IconRefresh,
  IconSearch,
} from "../app/icons";
import "./NetdiskPage.css";

/* ============================================================
   网盘 / 文件浏览页 —— 面包屑 + 文件表(草稿 PAGE 12)。
   本页假定已在「服务器 › 添加」登录了某个网盘/文件源;
   进来直接 sourceListDir(null) 列根目录。登录不在本页做,职责单一。
   双击文件夹下钻、双击视频直接播;右键 = 播放/下载/复制链接。
   ============================================================ */

type Crumb = { id: string | null; name: string };
/* 可排序列(草稿 40:表头可排序)。
   没有 mtime:核层 SourceEntry(crates/core/src/source/mod.rs)压根没有修改时间字段,
   排不了不存在的数据 —— 「修改时间」列保持 —,见下方渲染处注释。

   ★ "default" = 源怎么给就怎么显示,**不排序也不把文件夹置顶**。它是默认档。
   以前默认是「文件夹优先 + 名称升序」,对网盘没问题,对策展型的源是灾难:
   影视资源站返回的是「最新在前」,一按名称排就全乱了,连末尾那条「下一页 ›」
   都会被排到最上面去。源自己排好了序的时候,前端不该自作主张。 */
type SortField = "default" | "name" | "size" | "kind";
type Sort = { field: SortField; asc: boolean };
type Ctx = { x: number; y: number; entry: SourceEntry };

const SUB_EXT = /\.(srt|ass|ssa|sub|vtt|sup|idx)$/i;

const SORT_LABEL: Record<SortField, string> = {
  default: "源顺序",
  name: "名称",
  size: "大小",
  kind: "类型",
};
const SORT_CYCLE: SortField[] = ["default", "name", "size", "kind"];

function fmtSize(bytes: number | null, isDir: boolean): string {
  if (isDir) return "—";
  if (bytes == null || bytes <= 0) return "—";
  const u = ["B", "KB", "MB", "GB", "TB"];
  let n = bytes;
  let i = 0;
  while (n >= 1024 && i < u.length - 1) {
    n /= 1024;
    i++;
  }
  return `${n >= 100 || i === 0 ? Math.round(n) : n.toFixed(1)} ${u[i]}`;
}

/* 把一张图的实际宽高比归到几个标准版式:海报 2:3、方图 1:1、剧照 16:9。
   直接用实测值不行 —— 同一个目录里的海报本来就有 0.71 和 0.80 的差别,而"第一张
   加载完的是谁"取决于网络竞速,同一个目录两次进来版式会不一样(真机上量到过)。 */
function snapRatio(w: number, h: number): number {
  const r = w / h;
  if (r < 0.9) return 2 / 3;
  if (r < 1.2) return 1;
  return 16 / 9;
}

function kindLabel(e: SourceEntry): string {
  if (e.is_dir) return "文件夹";
  if (e.is_video) return "视频";
  if (SUB_EXT.test(e.name)) return "字幕";
  return "文件";
}

export default function NetdiskPage({
  onPlay,
  onBack,
}: {
  onPlay: (entry: SourceEntry) => void;
  onBack: () => void;
}) {
  // 面包屑栈:根目录起,点第 i 级 slice 回退再 listDir。
  const [trail, setTrail] = useState<Crumb[]>([{ id: null, name: "网盘" }]);
  const [entries, setEntries] = useState<SourceEntry[] | null>(null);
  const [err, setErr] = useState("");
  const [query, setQuery] = useState("");
  // 服务端搜索结果:非 null 时优先显示它(全盘搜);null = 未搜索或该源不支持,退回当前目录本地过滤。
  const [searchHits, setSearchHits] = useState<SourceEntry[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [sort, setSort] = useState<Sort>({ field: "default", asc: true });
  /* null = 跟着内容自适应(见下方 autoGrid);用户手动切过之后就听用户的。
     不落 localStorage 是故意的:一个目录是海报墙、下一层是分集列表,两种版式各自合适,
     把偏好钉死等于永远有一半目录是错的版式。 */
  const [grid, setGrid] = useState<boolean | null>(null);
  /* 海报是 2:3、视频缩略图是 16:9,写死一个必然裁掉另一种。
     用本页第一张真正加载出来的图的实际宽高比,谁都不裁。 */
  const [artRatio, setArtRatio] = useState<number | null>(null);
  const [ctx, setCtx] = useState<Ctx | null>(null);

  const currentId = trail[trail.length - 1]?.id ?? null;

  async function loadDir(dirId: string | null) {
    setEntries(null);
    setErr("");
    setCtx(null);
    // 切目录清掉上一次的搜索态,否则会显示别处的搜索结果。
    setQuery("");
    setSearchHits(null);
    setArtRatio(null);
    try {
      setEntries(await sourceListDir(dirId));
    } catch (e) {
      setErr(String(e));
      setEntries([]);
    }
  }

  /* 全盘搜索:输入 debounce 400ms 后打服务端。
     - 成功 → searchHits 显示全盘结果
     - 该源不支持(后端返回 unsupported)或出错 → searchHits=null,view 退回当前目录本地过滤
     115 等有频率限制的源不宜每次击键都打,故 debounce。空查询立即清。 */
  useEffect(() => {
    const q = query.trim();
    if (!q) {
      setSearchHits(null);
      setSearching(false);
      return;
    }
    let alive = true;
    setSearching(true);
    const timer = window.setTimeout(async () => {
      try {
        const hits = await sourceSearch(q);
        if (alive) setSearchHits(hits);
      } catch {
        // 不支持搜索 / 网络错误:退回本地过滤,不打断用户。
        if (alive) setSearchHits(null);
      } finally {
        if (alive) setSearching(false);
      }
    }, 400);
    return () => {
      alive = false;
      window.clearTimeout(timer);
    };
  }, [query]);

  // 进页即列根目录。
  useEffect(() => {
    loadDir(null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  function openDir(entry: SourceEntry) {
    setTrail((t) => [...t, { id: entry.id, name: entry.name }]);
    loadDir(entry.id);
  }

  function goCrumb(i: number) {
    if (i === trail.length - 1) return;
    const c = trail[i];
    setTrail((t) => t.slice(0, i + 1));
    loadDir(c.id);
  }

  /* Alt+← 返回上级(草稿 39)。
     ★ 必须常驻:本页原先唯一的 keydown 监听挂在右键菜单的 effect 里(if (!ctx) return),
     菜单没开时根本没人听键盘,快捷键等于不存在。 */
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.altKey && e.key === "ArrowLeft" && trail.length > 1) {
        e.preventDefault();
        goCrumb(trail.length - 2);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [trail]);

  function activate(entry: SourceEntry) {
    if (entry.is_dir) openDir(entry);
    else if (entry.is_video) onPlay(entry);
  }

  // 右键菜单:开、随外部点击/滚动/Esc 关。
  useEffect(() => {
    if (!ctx) return;
    const close = () => setCtx(null);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setCtx(null);
    window.addEventListener("click", close);
    window.addEventListener("scroll", close, true);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("scroll", close, true);
      window.removeEventListener("keydown", onKey);
    };
  }, [ctx]);

  // 搜索(优先服务端全盘,退回当前目录本地过滤)+ 排序(文件夹恒置顶,升降序只作用于同类之内)。
  const view = useMemo(() => {
    const q = query.trim().toLowerCase();
    // 服务端给了全盘结果就用它;否则本地过滤当前目录。
    const src = searchHits ?? entries;
    if (!src) return [];
    const list =
      q && !searchHits ? src.filter((e) => e.name.toLowerCase().includes(q)) : src.slice();
    // 源顺序档:原样交出去。连"文件夹置顶"都不做 —— 那也是一种重排。
    if (sort.field === "default") return list;
    const dir = sort.asc ? 1 : -1;
    list.sort((a, b) => {
      if (a.is_dir !== b.is_dir) return a.is_dir ? -1 : 1;
      switch (sort.field) {
        case "size":
          return ((a.size ?? 0) - (b.size ?? 0)) * dir;
        case "kind":
          // 同类型再按名字,否则一堆「视频」之间的顺序是随机的。
          return (
            (kindLabel(a).localeCompare(kindLabel(b), "zh") ||
              a.name.localeCompare(b.name, "zh")) * dir
          );
        default:
          return a.name.localeCompare(b.name, "zh") * dir;
      }
    });
    return list;
  }, [entries, searchHits, query, sort]);

  /* 这一屏过半条目带图,就默认铺成网格 —— 影视资源站的分类页会自己变成海报墙,
     再点进去的分集列表没有图,又自己退回文件表。用户不用为此点任何按钮。 */
  const autoGrid = useMemo(
    () => view.length > 0 && view.filter((e) => e.thumb_url).length * 2 >= view.length,
    [view],
  );
  const showGrid = grid ?? autoGrid;

  /** 点表头:同列切升降序,换列则从升序开始(通用文件管理器的习惯)。 */
  const clickHead = (field: SortField) =>
    setSort((s) => (s.field === field ? { field, asc: !s.asc } : { field, asc: true }));

  function fileIcon(e: SourceEntry) {
    if (e.is_dir) return <IconFolder size={15} />;
    if (e.is_video) return <IconPlay size={13} />;
    return <IconFile size={15} />;
  }

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>网盘</b>
        </span>
        <span className="push">
          <label className="searchbox">
            <IconSearch size={14} />
            <input
              className="nd-search-input"
              placeholder={searching ? "搜索中…" : "搜索…"}
              value={query}
              onChange={(e) => setQuery(e.target.value)}
            />
          </label>
          {/* 顶栏 pill 与表头是同一个 sort 态:点它循环换列,升降序在表头点。 */}
          <button
            className="pill"
            title="排序(表头可点,再点切升降序)"
            onClick={() =>
              setSort((s) => ({
                field: SORT_CYCLE[(SORT_CYCLE.indexOf(s.field) + 1) % SORT_CYCLE.length],
                asc: s.asc,
              }))
            }
          >
            排序 · {SORT_LABEL[sort.field]} {sort.asc ? "↑" : "↓"}
            <IconChevronDown size={12} />
          </button>
          <button
            className={`ibtn${showGrid ? " on" : ""}`}
            title={showGrid ? "切到列表" : "切到网格"}
            onClick={() => setGrid(!showGrid)}
          >
            <ViewIcon grid={showGrid} />
          </button>
          <button className="ibtn" title="刷新" onClick={() => loadDir(currentId)}>
            <IconRefresh size={15} />
          </button>
        </span>
      </div>

      <div className="scroll">
        <div className="nd-body">
          <div className="nd-crumbbar">
            {trail.map((c, i) => (
              <span className="nd-crumb-seg" key={`${c.id ?? "root"}-${i}`}>
                {i > 0 && (
                  <span className="nd-sep">
                    <IconChevronRight size={12} />
                  </span>
                )}
                <button
                  className={`nd-cr${i === trail.length - 1 ? " on" : ""}`}
                  onClick={() => goCrumb(i)}
                >
                  {c.name}
                </button>
              </span>
            ))}
          </div>

          {entries == null ? (
            <div className="nd-loading">
              <div className="spinner" />
            </div>
          ) : err ? (
            <div className="empty nd-empty">
              未登录网盘源。请在「服务器 › 添加」登录网盘 / 文件源后进入。
              <div className="nd-empty-act">
                <button className="btn" onClick={onBack}>
                  前往 服务器 › 添加
                </button>
              </div>
              <div className="nd-empty-err">{err}</div>
            </div>
          ) : view.length === 0 ? (
            <div className="empty">
              {query ? "没有匹配的文件。" : "这个目录是空的。"}
            </div>
          ) : showGrid ? (
            <div
              className="nd-grid enter"
              style={artRatio ? ({ "--nd-art-ar": String(artRatio) } as CSSProperties) : undefined}
            >
              {view.map((e) => (
                <button
                  key={e.id}
                  type="button"
                  className={`nd-cell${e.is_dir ? " nd-dir" : ""}`}
                  disabled={!e.is_dir && !e.is_video}
                  title={e.name}
                  onDoubleClick={() => activate(e)}
                  onContextMenu={(ev) => {
                    ev.preventDefault();
                    setCtx({ x: ev.clientX, y: ev.clientY, entry: e });
                  }}
                >
                  <div className="nd-art">
                    {e.thumb_url ? (
                      <img
                        src={e.thumb_url}
                        loading="lazy"
                        alt=""
                        onLoad={(ev) => {
                          if (artRatio != null) return;
                          const im = ev.currentTarget;
                          if (im.naturalWidth > 0 && im.naturalHeight > 0) {
                            setArtRatio(snapRatio(im.naturalWidth, im.naturalHeight));
                          }
                        }}
                      />
                    ) : e.is_dir ? (
                      <IconFolder size={30} />
                    ) : (
                      <IconFile size={30} />
                    )}
                    {e.is_video && (
                      <span className="nd-play">
                        <IconPlay size={14} />
                      </span>
                    )}
                  </div>
                  <div className="nd-cell-name">{e.name}</div>
                </button>
              ))}
            </div>
          ) : (
            <div className="nd-ftable enter">
              <div className="nd-ftrow head">
                <SortHead field="name" sort={sort} onClick={clickHead}>
                  名称
                </SortHead>
                <SortHead field="size" sort={sort} onClick={clickHead}>
                  大小
                </SortHead>
                {/* 修改时间不可排:核层没这个数据(见 SourceEntry 注释),
                    做成可点却排不动比不可点更坑。 */}
                <span className="nd-hd-off" title="核层 SourceEntry 未提供修改时间">
                  修改时间
                </span>
                <SortHead field="kind" sort={sort} onClick={clickHead}>
                  类型
                </SortHead>
              </div>
              {view.map((e) => (
                <div
                  key={e.id}
                  className={`nd-ftrow${e.is_dir || e.is_video ? " tap" : ""}`}
                  onDoubleClick={() => activate(e)}
                  onContextMenu={(ev) => {
                    ev.preventDefault();
                    setCtx({ x: ev.clientX, y: ev.clientY, entry: e });
                  }}
                >
                  <span className="nd-nm">
                    <span className={`nd-fi${e.is_video ? " vid" : ""}`}>
                      {fileIcon(e)}
                    </span>
                    <span className="nd-nm-t">{e.name}</span>
                  </span>
                  <span className="nd-val">{fmtSize(e.size, e.is_dir)}</span>
                  {/* 修改时间恒 —:SourceEntry(crates/core/src/source/mod.rs)没有 mtime 字段,
                      各网盘后端也就没往上传。要真显示得先改 Rust,这里不编一个假日期。 */}
                  <span className="nd-val" title="核层 SourceEntry 未提供修改时间">
                    —
                  </span>
                  <span className="nd-val">{kindLabel(e)}</span>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      {ctx && (
        <div
          className="ctxmenu"
          style={{ left: ctx.x, top: ctx.y }}
          onClick={(e) => e.stopPropagation()}
        >
          {ctx.entry.is_dir ? (
            <div
              className="mi"
              onClick={() => {
                openDir(ctx.entry);
                setCtx(null);
              }}
            >
              <IconFolder size={15} /> 打开
            </div>
          ) : (
            <>
              {ctx.entry.is_video && (
                <div
                  className="mi"
                  onClick={() => {
                    onPlay(ctx.entry);
                    setCtx(null);
                  }}
                >
                  <IconPlay size={15} /> 播放
                </div>
              )}
              {/* 下载 / 复制直链:核层确实没有能用的命令,诚实禁用(这两条不是过时注释,已核对):
                  · download_enqueue 写死了 Emby 的取流 URL + 会话,吃不下一个 SourceEntry;
                  · resolve_play 只有 source_play / source_watchdog 两个入口,两个都是
                    解析完**立刻(重)起播**,没有一个把裸链接还给前端。
                  要接得先改 Rust:拆出 source_resolve(entry) -> String,
                  再加 source_download_enqueue(entry)。在那之前给个能点的按钮才是骗人。 */}
              <div className="mi nd-mi-off" title="需 Rust 侧新增 source_download_enqueue">
                <IconDownload size={15} /> 下载
              </div>
              <div className="mi nd-mi-off" title="需 Rust 侧从 source_play 拆出 source_resolve">
                <IconFile size={15} /> 复制链接
              </div>
            </>
          )}
        </div>
      )}
    </>
  );
}

/** 可排序表头:当前列显方向箭头(草稿 40)。 */
function SortHead({
  field,
  sort,
  onClick,
  children,
}: {
  field: SortField;
  sort: Sort;
  onClick: (f: SortField) => void;
  children: ReactNode;
}) {
  const on = sort.field === field;
  return (
    <span
      className={`nd-hd${on ? " on" : ""}`}
      role="button"
      tabIndex={0}
      onClick={() => onClick(field)}
      onKeyDown={(e) => (e.key === "Enter" || e.key === " ") && onClick(field)}
    >
      {children}
      {on && <i className="nd-hd-ar">{sort.asc ? "↑" : "↓"}</i>}
    </span>
  );
}

// 网格/列表切换图标(app/icons 无对应,内联,currentColor,不用 emoji)。
function ViewIcon({ grid }: { grid: boolean }) {
  return grid ? (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.7} strokeLinecap="round" aria-hidden>
      <path d="M4 6h16M4 12h16M4 18h16" />
    </svg>
  ) : (
    <svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={1.6} aria-hidden>
      <rect x="3.5" y="3.5" width="7" height="7" rx="1.4" />
      <rect x="13.5" y="3.5" width="7" height="7" rx="1.4" />
      <rect x="3.5" y="13.5" width="7" height="7" rx="1.4" />
      <rect x="13.5" y="13.5" width="7" height="7" rx="1.4" />
    </svg>
  );
}
