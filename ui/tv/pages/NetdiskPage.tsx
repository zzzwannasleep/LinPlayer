import { useEffect, useState, type CSSProperties } from "react";
import {
  fmtSize,
  listAccounts,
  sourceListDir,
  sourcePlay,
  type LoginResult,
  type SourceEntry,
} from "@shared/api";
import type { Route } from "../App";
import { onTvKey } from "../app/focus";
import { Icon } from "../app/icons";
import { FocusColumn, FocusItem } from "../components/Focus";
import { useAsync } from "../lib/useAsync";

/** 网盘 / 文件浏览(草稿 18)。OpenList / 夸克 / 飞牛 等浏览型源。

    ★ **不做 PC 那种多列文件表**:列一多,每列都要横向移动才能看清,
      而横向移动在遥控器上按一次只走一格。改成单列大行,类型/大小压在同一行里。
    ★ 面包屑**可聚焦**:从第五层退回第二层,连按四次返回 vs 按两次方向键 + 确认。
    ★ 「.. 返回上级」放列表第一项并默认落焦 —— 进错目录时零成本退出,
      这是文件浏览里最高频的一个动作。 */
export default function NetdiskPage({ go }: { session: LoginResult; go: (r: Route) => void }) {
  /* 面包屑即路径栈。根目录的 id 是 null(sourceListDir 的约定)。 */
  const [path, setPath] = useState<Crumb[]>([{ id: null, name: "根目录" }]);
  const cur = path[path.length - 1];
  const [err, setErr] = useState<string | null>(null);

  const entries = useAsync(() => sourceListDir(cur.id), [cur.id]);
  /* 标题单独一块各自加载,不和目录列表并到一个 Promise.all 里 ——
     账号表慢的时候不该把整屏文件列表一起拖住。 */
  const accounts = useAsync(() => listAccounts(), []);
  const title =
    accounts.data?.find((a) => a.active && a.is_file_browse)?.name ?? "文件浏览";

  const up = () => setPath((p) => (p.length > 1 ? p.slice(0, -1) : p));

  /* 返回键 = 上一级。这一页在路由栈上是顶层页,App 的 back() 到栈底不动,
     所以退到根目录后再按返回是"退出应用",交给壳。 */
  useEffect(() => onTvKey((k) => k === "back" && up()), []);

  const enter = async (e: SourceEntry) => {
    if (e.is_dir) {
      setPath((p) => [...p, { id: e.id, name: e.name }]);
      return;
    }
    setErr(null);
    try {
      await sourcePlay(e, 0);
      go({ page: "player" });
    } catch (x) {
      setErr(x instanceof Error ? x.message : String(x));
    }
  };

  const list = entries.data;

  return (
    <FocusColumn focusKey="NETDISK">
      <div className="ptitle" style={{ marginBottom: 18 }}>
        {title}
      </div>

      <div style={{ display: "flex", gap: 12, alignItems: "center", marginBottom: 30 }}>
        {path.map((c, i) => (
          <span key={`${c.id ?? "root"}-${i}`} style={{ display: "flex", gap: 12, alignItems: "center" }}>
            {i > 0 && <span style={{ color: "var(--tv-ink-3)" }}>›</span>}
            <FocusItem
              className={`fchip${i === path.length - 1 ? " on" : ""}`}
              style={{ height: 52, padding: "0 20px" }}
              onEnter={() => setPath((p) => p.slice(0, i + 1))}
            >
              {c.name}
            </FocusItem>
          </span>
        ))}
      </div>

      {err && (
        <div style={{ color: "var(--danger)", fontSize: 19, marginBottom: 18 }}>{err}</div>
      )}

      <div style={{ display: "flex", flexDirection: "column", gap: 12 }}>
        {path.length > 1 && (
          /* key 跟着目录走 → 每换一层都重新挂载,autoFocus 才会再次生效。
             不这么做的话进下一层时焦点还挂在已经消失的那一行上。 */
          <FocusItem key={`up-${cur.id}`} style={ROW} autoFocus onEnter={up}>
            <Icon n="up" className="ic ic-c" />
            <div style={{ flex: 1, minWidth: 0, fontSize: 21 }}>.. 返回上级</div>
          </FocusItem>
        )}

        {!list
          ? [0, 1, 2, 3, 4].map((k) => (
              <div key={k} className="sk" style={{ height: 76 }} />
            ))
          : list.map((e, i) => (
              <FocusItem
                key={e.id}
                style={ROW}
                className={!e.is_dir && !e.is_video ? "dim" : ""}
                autoFocus={i === 0 && path.length === 1}
                /* 既不是目录也不是视频(字幕、nfo、压缩包)保留显示但不占焦点位:
                   消失会让用户以为文件丢了,可聚焦又白费一次按键。 */
                disabled={!e.is_dir && !e.is_video}
                onEnter={() => void enter(e)}
              >
                {/* 有封面就画封面。网盘和局域网源基本不给 thumb_url,但插件类元数据源
                    每一行都是一部片 —— 全靠片名认片在电视上太费眼。 */}
                {e.thumb_url ? (
                  <img
                    src={e.thumb_url}
                    alt=""
                    loading="lazy"
                    style={THUMB}
                    /* 封面挂了就把它藏掉,别在行首留一个破图图标。 */
                    onError={(ev) => {
                      ev.currentTarget.style.display = "none";
                    }}
                  />
                ) : (
                  <Icon n={e.is_dir ? "folder" : "file"} className="ic ic-c" />
                )}
                <div style={{ flex: 1, minWidth: 0, fontSize: 21 }}>{e.name}</div>
                <div style={{ fontSize: 17, color: "var(--tv-ink-3)", flex: "none" }}>
                  {e.is_dir ? "文件夹" : fmtSize(e.size)}
                </div>
              </FocusItem>
            ))}
      </div>
    </FocusColumn>
  );
}

type Crumb = { id: string | null; name: string };

/** 单列大行。行样式只此一处,写内联而不是往 tv.css 加类 ——
 *  tv.css 是草稿的直接抬升,只为一页加类会让两边慢慢对不上。 */
const ROW: CSSProperties = {
  display: "flex",
  alignItems: "center",
  gap: 24,
  padding: "20px 24px",
  borderRadius: 14,
  background: "#161a20",
};

/** 行内小封面。宽高写死 → 有没有图行高都一样,列表不会因为图片陆续加载而抖。
 *  海报是 2:3,按 48×72 给;非海报(剧集缩略图 16:9)用 cover 裁到同一框里。 */
const THUMB: CSSProperties = {
  width: 48,
  height: 72,
  flex: "none",
  borderRadius: 6,
  objectFit: "cover",
  background: "#0d1117",
};
