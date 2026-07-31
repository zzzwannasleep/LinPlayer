import { type CSSProperties, type SyntheticEvent, useEffect, useMemo, useState } from "react";
import { type SourceEntry, sourceListDir, sourcePlay, sourceSearch } from "@shared/api";
import { Icon } from "../app/icons";
import { useCtx } from "../app/ctx";
import Page from "../components/Page";

/* 网盘 / 文件浏览型源。

   进来直接 `sourceListDir(null)` 列根目录。**登录不在本页做** —— 那是添加服务器页的事,
   职责单一(PC 端同口径)。

   ## 面包屑改成"返回上一级"
   PC 是一条横向面包屑。手机屏宽装不下三层以上的路径,而且每一级都是个小点击目标。
   改成:顶部只显示当前目录名 + 一个「上一级」——**栈自己记在这一页里**,
   不进路由栈(否则用户从三层深处按返回要按三次才离开网盘页)。

   ## 搜索
   源端全盘搜索;后端返回「该源不支持搜索」时退回当前目录本地过滤。
   直接不给搜索框是更省事,但网盘动辄上千文件,没有搜索基本没法用。

   ## 两种版式
   过半条目带图就铺成海报墙,否则还是文件行。影视资源站这类源的分类页会自己变成
   海报墙,点进去的分集列表没有图、又自己退回文件行 —— 不需要用户点任何开关。
   条目顺序**原样照抄源给的顺序**,不排序:策展型的源(「最新在前」)一排就毁了。 */

export default function NetdiskPage() {
  const { back } = useCtx();
  /* 播放本地/网盘文件后退回上一页 —— mpv 已经在放了，继续堆在文件列表上没意义。 */
  const onPlaySource = back;
  /** 目录栈。栈底是根(null)。**不用路由栈** —— 理由见文件头。 */
  const [stack, setStack] = useState<{ id: string | null; name: string }[]>([{ id: null, name: "根目录" }]);
  const [entries, setEntries] = useState<SourceEntry[] | null>(null);
  const [err, setErr] = useState("");
  const [q, setQ] = useState("");
  const [searching, setSearching] = useState(false);
  /* 海报是 2:3、网盘缩略图多是 16:9,写死一个必然把另一种裁掉。
     用本屏第一张真正加载出来的图的实际宽高比。 */
  const [artRatio, setArtRatio] = useState<number | null>(null);

  const cur = stack[stack.length - 1];

  const posterWall = useMemo(
    () => !!entries && entries.length > 0 && entries.filter((e) => e.thumb_url).length * 2 >= entries.length,
    [entries],
  );

  useEffect(() => {
    let alive = true;
    setEntries(null);
    setErr("");
    setArtRatio(null);
    sourceListDir(cur.id)
      .then((e) => alive && setEntries(e))
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [cur.id]);

  const doSearch = async () => {
    const s = q.trim();
    if (!s) return;
    setSearching(true);
    setErr("");
    try {
      setEntries(await sourceSearch(s));
    } catch {
      /* 该源不支持搜索 → 退回当前目录本地过滤。**不弹错** ——
         "这个源不能搜"对用户不是错误,是能力差异。 */
      try {
        const all = await sourceListDir(cur.id);
        setEntries(all.filter((e) => e.name.toLowerCase().includes(s.toLowerCase())));
      } catch (e2) {
        setErr(String(e2));
      }
    } finally {
      setSearching(false);
    }
  };

  const open = (e: SourceEntry) => {
    if (e.is_dir) return setStack((s) => [...s, { id: e.id, name: e.name }]);
    if (!e.is_video) return; // 非视频文件点了不做事(也不假装能播)
    /* 起播成功后退回上一页 —— 播放层由 App 挂着,这一页不该留在栈顶,
       否则用户从播放页返回会落回网盘目录而不是他来的地方。 */
    void sourcePlay(e, 0).then(onPlaySource);
  };

  /** 第一张图加载完就把真实宽高比记下来,后面所有卡片跟着它。 */
  const onArtLoad = (ev: SyntheticEvent<HTMLImageElement>) => {
    if (artRatio != null) return;
    const im = ev.currentTarget;
    if (im.naturalWidth > 0 && im.naturalHeight > 0) setArtRatio(snapRatio(im.naturalWidth, im.naturalHeight));
  };

  return (
    <Page title="网盘文件" onBack={back} enterKey={entries}>
    <div className="nd">
      <div className="sf">
        <Icon n="search" size={18} />
        <input
          value={q}
          onChange={(e) => setQ(e.target.value)}
          onKeyDown={(e) => e.key === "Enter" && void doSearch()}
          placeholder={`在「${cur.name}」中搜索`}
          enterKeyHint="search"
          autoComplete="off"
        />
        {q && (
          <button
            type="button"
            className="sf-x"
            onClick={() => {
              setQ("");
              setEntries(null);
              sourceListDir(cur.id).then(setEntries).catch((e) => setErr(String(e)));
            }}
            aria-label="清空"
          >
            <Icon n="close" size={18} />
          </button>
        )}
      </div>

      {stack.length > 1 && (
        <button type="button" className="nd-up" onClick={() => setStack((s) => s.slice(0, -1))}>
          ↑ 上一级 · <span className="dim">{cur.name}</span>
        </button>
      )}

      {err ? (
        <div className="empty"><b>打不开</b><div className="dim">{err}</div></div>
      ) : !entries ? (
        <div className="empty"><div className="dim">{searching ? "搜索中…" : "加载中…"}</div></div>
      ) : !entries.length ? (
        <div className="empty"><div className="dim">这里是空的</div></div>
      ) : posterWall ? (
        <div
          className="nd-wall"
          style={artRatio ? ({ "--nd-art-ar": String(artRatio) } as CSSProperties) : undefined}
        >
          {entries.map((e) => (
            <button key={e.id} type="button" className="nd-poster" onClick={() => open(e)}>
              <span className="nd-poster-art">
                {e.thumb_url ? (
                  <img src={e.thumb_url} loading="lazy" alt="" onLoad={onArtLoad} />
                ) : (
                  <Icon n={e.is_dir ? "folder" : "file"} size={24} />
                )}
              </span>
              <span className="nd-poster-l">{e.name}</span>
            </button>
          ))}
        </div>
      ) : (
        <div className="cells">
          {entries.map((e) => (
            <button key={e.id} type="button" className="cell" onClick={() => open(e)}>
              <span className="cell-i"><Icon n={e.is_dir ? "folder" : "file"} size={20} /></span>
              <span className="cell-l">{e.name}</span>
              {!e.is_dir && e.size != null && <span className="cell-s">{fmt(e.size)}</span>}
              {e.is_dir && <Icon n="chevR" size={18} />}
            </button>
          ))}
        </div>
      )}
    </div>
    </Page>
  );
}

/* 把一张图的实际宽高比归到几个标准版式:海报 2:3、方图 1:1、剧照 16:9。
   直接用实测值不行 —— 同一个目录里的海报本来就有 0.71 和 0.80 的差别,而"第一张
   加载完的是谁"取决于网络竞速,同一个目录两次进来版式会不一样(PC 真机上量到过)。 */
function snapRatio(w: number, h: number): number {
  const r = w / h;
  if (r < 0.9) return 2 / 3;
  if (r < 1.2) return 1;
  return 16 / 9;
}

/** 网盘条目的体积。api.ts 的 fmtSize 对 0 返回空串,这里的语义是"未知大小"也不显示,正好。 */
function fmt(n: number): string {
  const u = ["B", "KB", "MB", "GB", "TB"];
  let i = 0;
  let v = n;
  while (v >= 1024 && i < u.length - 1) {
    v /= 1024;
    i++;
  }
  return `${v.toFixed(v >= 10 || i === 0 ? 0 : 1)} ${u[i]}`;
}
