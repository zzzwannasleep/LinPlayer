import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  type AccountInfo,
  type AccountStatus,
  type LoginResult,
  type IconEntry,
  type ServerLine,
  type SourceKind,
  accountIcon,
  clearAccountIcon,
  iconLibrary,
  listAccounts,
  onAccountsChanged,
  probeAccounts,
  probeLines,
  relogin,
  removeAccount,
  syncLines,
  reorderAccounts,
  setAccountIconFile,
  setActiveLine,
  setActiveServer,
  setLines,
  updateAccount,
} from "@shared/api";
import { getCurrentWebview } from "@tauri-apps/api/webview";
import { IconClose, IconGauge, IconPlus, IconRefresh, IconSearch } from "../app/icons";
import "./ServersPage.css";

/* ============================================================
   服务器页(草稿 PAGE 05,pin 24/25/26/29)。
   备注/图标/线路/排序全部落核层(update_account / set_lines / reorder_accounts),
   **不存 localStorage** —— 换台机器就没了不说,核层本来就持久化,影子存储纯属重复。
   ============================================================ */

/** onEnter(src):与 AddServerPage.onDone 同构 —— 空=进首页(Emby),否则进对应浏览页。
    可选:宿主(Shell)没接时只切服务器不跳页(= 接线前的旧行为),不会静默切错服。 */
type Props = {
  session: LoginResult;
  activeServer: string;
  onChanged: () => void;
  onGoAdd: () => void;
  onEnter?: (src?: "netdisk" | "anirss") => void;
};

/* 类型徽标(草稿 .badge:Emby/夸克/OpenList/飞牛/RSS)。写死 "Emby" 会让六张卡全是 Emby。
   ★ 键必须是**小写**的线上值。写成 "Emby"/"Openlist" 的那版一个都命中不了,
     六张卡的徽标全是空白 —— 而且不报错,看着只像是"设计上就没有徽标"。 */
const KIND_LABEL: Record<string, string> = {
  emby: "Emby",
  openlist: "OpenList",
  quark: "夸克",
  anirss: "RSS",
  feiniu: "飞牛",
  aliyundrive: "阿里云盘",
  baidu: "百度",
  pan115: "115",
  pan189: "天翼云盘",
  pan139: "移动云盘",
  smb: "SMB",
  webdav: "WebDAV",
  ftp: "FTP",
  local: "本机文件夹",
};

/** 插件贡献的源是 `plugin:<插件id>/<源id>`,不在上表里 —— 统一打「插件」。 */
function kindLabel(k: SourceKind): string {
  return KIND_LABEL[k] ?? (String(k).startsWith("plugin:") ? "插件" : String(k));
}

/* 状态点 = **连通健康**,不是「选中」(选中看 .sv-cur-tag「当前」角标)。
   down(探过确实不通) 与 unknown(还没探过) 同色不同义 —— 颜色相同不代表可以合并,
   title 必须分开写,否则用户看到灰点分不清「连不上」还是「还没测」。 */
const STATUS_DOT: Record<AccountStatus, "on" | "off" | "none"> = {
  ok: "on",
  reauth: "off",
  down: "none",
  unknown: "none",
};
const STATUS_TXT: Record<AccountStatus, string> = {
  ok: "连接正常",
  reauth: "需重新登录",
  down: "无法连接",
  unknown: "未探测",
};

/* 内置图标集(几何字形,非 emoji,对齐草稿 .iconpick)。空串 = 恢复默认 IconServer。 */
const GLYPHS = [
  "▣", "☁", "▦", "◆", "★", "♪", "▶", "⌘", "◈", "⬡",
  "✦", "◐", "❄", "▲", "◍", "✚", "❖", "⬟", "◑", "⬢",
];

/** icon_url 一个字段兼两用:内置字形直接存字形本身,网络/本地图存 URL/路径。
    判据是「短且不含路径分隔符」—— 核层 icon_cache 对非 http 值会当本地路径读,
    读不到就 Err,正好由这里回落成字形渲染,不用为字形再加一个核层命令。 */
const isGlyph = (s: string) => s.length <= 2 && !/[\\/:.]/.test(s);

/** 卡片/弹窗统一图标:data URI/URL→图片,字形→文本,都没有 → emby 默认图。
    ★ 兜底用 /emby_default.png(public/,Vite 原样打进 dist)——
    用户 2026-07-15:「既没有拉取网络图标 又没有图标 → 回退 emby_default.png」。
    不再用抽象的 IconServer 线框图。 */
function ServerGlyph({ icon, size = 20 }: { icon?: string | null; size?: number }) {
  if (icon && (icon.startsWith("http") || icon.startsWith("data:")))
    return <img className="sv-sic-img" src={icon} alt="" />;
  if (icon && isGlyph(icon))
    return <span className="sv-glyph" style={{ fontSize: size }}>{icon}</span>;
  return <img className="sv-sic-img" src="/emby_default.png" alt="" width={size} height={size} />;
}

/** 视图切换用的内联图标(icons.tsx 无网格/列表图标,就地描边,不用 emoji)。 */
function IconView({ mode, size = 15 }: { mode: "grid" | "list"; size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor"
      strokeWidth={1.7} strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      {mode === "grid" ? (
        <><rect x="3" y="3" width="8" height="8" rx="1.4" /><rect x="13" y="3" width="8" height="8" rx="1.4" />
          <rect x="3" y="13" width="8" height="8" rx="1.4" /><rect x="13" y="13" width="8" height="8" rx="1.4" /></>
      ) : (
        <><path d="M8 6h13M8 12h13M8 18h13" /><path d="M3.5 6h.01M3.5 12h.01M3.5 18h.01" /></>
      )}
    </svg>
  );
}

type DlgKind = "edit" | "relogin" | "lines" | "icon" | "remark" | "delete";

export default function ServersPage({ activeServer, onChanged, onGoAdd, onEnter }: Props) {
  const [accounts, setAccounts] = useState<AccountInfo[] | null>(null);
  const [icons, setIcons] = useState<Record<string, string>>({}); // server → data URI
  const [err, setErr] = useState("");
  const [q, setQ] = useState("");
  const [view, setView] = useState<"grid" | "list">("grid");
  const [pending, setPending] = useState(""); // 正在切换的 server(单飞)
  const [menu, setMenu] = useState<{ srv: AccountInfo; x: number; y: number } | null>(null);
  const [dlg, setDlg] = useState<{ kind: DlgKind; srv: AccountInfo } | null>(null);
  const dragFrom = useRef(-1);

  const reload = useCallback(async () => {
    try {
      setAccounts(await listAccounts());
    } catch (e) {
      setErr(String(e));
      setAccounts([]);
    }
  }, []);

  useEffect(() => {
    // 先出列表(状态用核层缓存,可能是 unknown),再并发探一次刷新状态点。
    // 探测最长 8s×并发,不能挡着首屏。
    (async () => {
      await reload();
      try {
        setAccounts(await probeAccounts());
      } catch (e) {
        setErr(String(e)); // 探测失败要说出来,否则状态点永远灰着没人知道为什么
      }
    })();
  }, [reload]);

  /* 反向也要通:从侧栏切服/删服后,本页这份副本同样会陈旧。
     两份 useState 副本谁都不知道对方改了 —— 广播是唯一的连接。 */
  useEffect(() => onAccountsChanged(() => void reload()), [reload]);

  /* 图标:icon_url 是网络地址/本地路径时找核层要 data URI(它负责下载+缓存)。
     失败**不弹错**(每台服都弹会刷屏),按草稿回落内置图标即可。 */
  useEffect(() => {
    if (!accounts) return;
    let alive = true;
    for (const a of accounts) {
      const u = a.icon_url;
      if (!u || isGlyph(u) || icons[a.server]) continue;
      accountIcon(a.server)
        .then((d) => alive && setIcons((m) => ({ ...m, [a.server]: d })))
        .catch(() => {});
    }
    return () => {
      alive = false;
    };
    // icons 不入依赖:它由本 effect 自己写,入依赖会自激。
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [accounts]);

  // 右键菜单:点击别处 / Esc 关闭。
  useEffect(() => {
    if (!menu) return;
    const close = () => setMenu(null);
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && setMenu(null);
    window.addEventListener("click", close);
    window.addEventListener("keydown", onKey);
    return () => {
      window.removeEventListener("click", close);
      window.removeEventListener("keydown", onKey);
    };
  }, [menu]);

  const isActive = (a: AccountInfo) => a.active || a.server === activeServer;
  const iconOf = (a: AccountInfo) => icons[a.server] ?? a.icon_url ?? "";

  const shown = useMemo(() => {
    const list = accounts ?? [];
    const kw = q.trim().toLowerCase();
    if (!kw) return list;
    return list.filter(
      (a) =>
        a.name.toLowerCase().includes(kw) ||
        a.user_name.toLowerCase().includes(kw) ||
        (a.remark || "").toLowerCase().includes(kw),
    );
  }, [accounts, q]);

  async function doSwitch(a: AccountInfo) {
    if (pending) return;
    setErr("");
    setPending(a.server);
    try {
      if (!isActive(a)) {
        await setActiveServer(a.server);
        onChanged();
        await reload();
      }
      // 草稿 L1216:点 Emby 卡 → 进首页;点网盘/文件源卡 → 进文件浏览。
      onEnter?.(a.is_file_browse ? (a.source_kind === "anirss" ? "anirss" : "netdisk") : undefined);
    } catch (e) {
      setErr(String(e));
    } finally {
      setPending("");
    }
  }

  /* 拖动排序(pin 25)。核层 list_accounts 按 cfg.accounts 原序返回,
     故「列表下标 == 账号下标」—— 但搜索过滤后 shown 的下标不再是账号下标,
     必须回 accounts 里查真实下标,否则筛选状态下拖一次就把别的服排乱了。 */
  const realIndex = (a: AccountInfo) => (accounts ?? []).findIndex((x) => x.server === a.server);
  async function doDrop(to: AccountInfo) {
    const from = dragFrom.current;
    const t = realIndex(to);
    dragFrom.current = -1;
    if (from < 0 || t < 0 || from === t) return;
    try {
      await reorderAccounts(from, t);
      await reload();
    } catch (e) {
      setErr(String(e));
    }
  }

  const openMenu = (e: React.MouseEvent, srv: AccountInfo) => {
    e.preventDefault();
    e.stopPropagation();
    setMenu({ srv, x: Math.min(e.clientX, window.innerWidth - 192), y: Math.min(e.clientY, window.innerHeight - 260) });
  };

  // 弹窗收尾:sessionChanged 时通知外层刷新会话;总是重拉账号 + 关窗。
  const finish = useCallback(
    async (sessionChanged: boolean) => {
      if (sessionChanged) onChanged();
      await reload();
      setDlg(null);
    },
    [onChanged, reload],
  );

  const count = accounts?.length ?? 0;

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>服务器</b> <span className="count">· {count}</span>
        </span>
        <span className="push">
          <label className="searchbox">
            <IconSearch size={14} />
            <input
              className="sv-search-inp"
              placeholder="搜索服务器…"
              value={q}
              onChange={(e) => setQ(e.target.value)}
            />
          </label>
          <button
            className={`ibtn${view === "list" ? " on" : ""}`}
            title={view === "grid" ? "切换列表视图" : "切换网格视图"}
            onClick={() => setView((v) => (v === "grid" ? "list" : "grid"))}
          >
            <IconView mode={view === "grid" ? "list" : "grid"} />
          </button>
          <button className="btn primary sm" onClick={onGoAdd}>
            <IconPlus size={15} /> 添加服务器
          </button>
        </span>
      </div>

      <div className="scroll">
        {err && (
          <div className="toast error" onClick={() => setErr("")}>
            {err}
          </div>
        )}

        {accounts == null ? (
          <div className="empty">
            <span className="spinner" />
          </div>
        ) : accounts.length === 0 ? (
          <div className="empty">还没有服务器,点右上角「添加服务器」。</div>
        ) : shown.length === 0 ? (
          <div className="empty">没有匹配「{q}」的服务器。</div>
        ) : (
          <div className={`sv-srvgrid${view === "list" ? " list" : ""}`}>
            {shown.map((a) => {
              const active = isActive(a);
              const busy = pending === a.server;
              return (
                <div
                  key={a.server}
                  className={`sv-srvcard enter${active ? " cur" : ""}`}
                  /* 阶梯延迟砍掉(第 12 张要等 312ms 才可见)。这页卡片少、不是热路径,
                     `.enter` 本体留着;真嫌慢连它一起去掉。 */
                  draggable
                  onDragStart={() => (dragFrom.current = realIndex(a))}
                  onDragOver={(e) => e.preventDefault()}
                  onDrop={() => doDrop(a)}
                  onDragEnd={() => (dragFrom.current = -1)}
                  onClick={() => doSwitch(a)}
                  onContextMenu={(e) => openMenu(e, a)}
                  title={active ? "当前服务器" : "点击切换到此服务器"}
                >
                  <span className="sv-sic">
                    {busy ? <span className="spinner" /> : <ServerGlyph icon={iconOf(a)} />}
                  </span>
                  <div className="sv-col">
                    <span className="sv-nm">
                      <span className={`dot ${STATUS_DOT[a.status]}`} title={STATUS_TXT[a.status]} />
                      {a.name}
                    </span>
                    {/* 草稿 pin 25:名称下方显示备注,**不显示线路地址**(避免暴露隐私)。 */}
                    <span className="sv-rm">{a.remark || "无备注"}</span>
                  </div>
                  <span className="sv-type">{kindLabel(a.source_kind)}</span>
                  {active && <span className="sv-cur-tag">当前</span>}
                </div>
              );
            })}
          </div>
        )}
        <div style={{ height: 40 }} />
      </div>

      {menu && (
        <div className="ctxmenu" style={{ left: menu.x, top: menu.y }} onClick={(e) => e.stopPropagation()}>
          {([
            ["编辑", "edit"],
            ["重新登录", "relogin"],
            ["服务器线路…", "lines"],
            ["更换图标", "icon"],
            ["修改备注", "remark"],
          ] as [string, DlgKind][]).map(([label, kind]) => (
            <div
              key={kind}
              className="mi"
              onClick={() => {
                setDlg({ kind, srv: menu.srv });
                setMenu(null);
              }}
            >
              {label}
            </div>
          ))}
          <div
            className="mi danger"
            onClick={() => {
              setDlg({ kind: "delete", srv: menu.srv });
              setMenu(null);
            }}
          >
            删除
          </div>
        </div>
      )}

      {dlg?.kind === "edit" && (
        <EditDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={finish} onErr={setErr} />
      )}
      {dlg?.kind === "relogin" && (
        <ReloginDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={finish} onErr={setErr} />
      )}
      {dlg?.kind === "lines" && (
        <LinesDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={finish} onErr={setErr} />
      )}
      {dlg?.kind === "icon" && (
        <IconDialog
          srv={dlg.srv}
          icon={iconOf(dlg.srv)}
          onClose={() => setDlg(null)}
          onDone={(server, uri) => {
            // 换图标不动会话,只需重拉账号 + 更新本地 data URI 缓存。
            setIcons((m) => {
              const n = { ...m };
              if (uri) n[server] = uri;
              else delete n[server];
              return n;
            });
            finish(false);
          }}
          onErr={setErr}
        />
      )}
      {dlg?.kind === "remark" && (
        <RemarkDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={finish} onErr={setErr} />
      )}
      {dlg?.kind === "delete" && (
        <DeleteDialog srv={dlg.srv} onClose={() => setDlg(null)} onDone={finish} onErr={setErr} />
      )}
    </>
  );
}

/* ============================================================
   居中模态弹窗 —— 每个右键项一个,均 .scrim>.dlg。
   ============================================================ */

function Scrim({
  onClose,
  children,
  className = "",
}: {
  onClose: () => void;
  children: React.ReactNode;
  className?: string;
}) {
  return (
    <div className="scrim" onClick={onClose}>
      <div className={`dlg ${className}`} onClick={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>
  );
}

/** 编辑:**服务器名称 / 账号 / 密码 / 备注**(+TLS 开关)。
 *
 *  字段与顺序是用户 2026-07-15 定的原话:「第一行是服务器名称 第二行账号 第三行密码 第四行备注」,
 *  并明确「**服务器地址是「服务器线路」里面填写的**」—— 故这里**没有地址行**,别加回来。
 *
 *  ★ 改账号/密码走 relogin(真登一次换 token),改名称/备注/TLS 走 update_account。
 *    只把 user_name 字段改掉而不重登 = token 还是旧用户的,表现为「显示新账号、
 *    媒体库还是旧账号的」,而且不报错。 */
function EditDialog({
  srv,
  onClose,
  onDone,
  onErr,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: (sessionChanged: boolean) => void;
  onErr: (m: string) => void;
}) {
  const [name, setName] = useState(srv.name);
  const [username, setUsername] = useState(srv.user_name);
  const [password, setPassword] = useState("");
  const [remark, setRemark] = useState(srv.remark || "");
  const [tls, setTls] = useState(srv.allow_insecure_tls);
  const [busy, setBusy] = useState(false);

  const userChanged = username.trim() !== srv.user_name;

  async function save() {
    if (busy) return;
    // 换账号必须验一次 —— 没有密码就没法验,存下去只会得到一个打不开的账号。
    if (userChanged && !password) {
      onErr("换账号必须填密码(要重新登录一次才能拿到新 token)");
      return;
    }
    setBusy(true);
    try {
      // 先换凭据(会真登一次),再落名称/备注/TLS —— 顺序反了的话 relogin 里的
      // find_mut 改的是同一条记录,不冲突,但登录失败时不该已经把名字改掉了。
      let sessionChanged = false;
      if (userChanged || password) {
        await relogin(srv.server, username.trim(), password);
        sessionChanged = true;
      }
      // 不传的字段核层不动;传空串才是清空 —— 故备注恒传(允许清空)。
      await updateAccount(srv.server, { name: name.trim(), remark, allowInsecureTls: tls });
      onDone(sessionChanged);
    } catch (e) {
      onErr(String(e));
      setBusy(false);
    }
  }

  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        编辑服务器
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        {/* 顺序 = 用户口径:名称 → 账号 → 密码 → 备注。**地址不在这儿**,在「服务器线路」里。 */}
        <div className="fld">
          <label>服务器名称</label>
          <input className="field" value={name} onChange={(e) => setName(e.target.value)} />
        </div>
        <div className="fld">
          <label>账号</label>
          <input className="field" value={username} onChange={(e) => setUsername(e.target.value)} />
        </div>
        <div className="fld">
          <label>密码{userChanged ? "(换账号必填)" : "(留空 = 不改)"}</label>
          <input
            className="field"
            type="password"
            placeholder="••••••••"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
        <div className="fld">
          <label>备注</label>
          <input className="field" value={remark} onChange={(e) => setRemark(e.target.value)} />
        </div>
        <label className="sv-chk" style={{ marginBottom: 0 }}>
          <input type="checkbox" checked={tls} onChange={(e) => setTls(e.target.checked)} />
          允许自签名 / 不受信任的 TLS 证书
        </label>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button className="btn primary" disabled={busy} onClick={save}>
          {busy ? <span className="spinner" /> : "保存"}
        </button>
      </div>
    </Scrim>
  );
}

/** 重新登录:**只重填账号+密码**。
 *
 *  用户 2026-07-15:「重新登录是重新填写账密,线路不用重新填写,用的还是服务器线路里面的线路」。
 *  故这里没有地址行 —— 核层 relogin 自己拿账号当前生效的那条线路去认证。
 *
 *  ★ 别改回 login():login 按「登录时用的地址」upsert,而 relogin 认证走的是线路地址
 *    (≠ 账号主键)—— 用 login 会**凭空多出一台服务器**,原账号还在,用户以为重登好了。 */
function ReloginDialog({
  srv,
  onClose,
  onDone,
  onErr,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: (sessionChanged: boolean) => void;
  onErr: (m: string) => void;
}) {
  const [username, setUsername] = useState(srv.user_name);
  const [password, setPassword] = useState("");
  const [busy, setBusy] = useState(false);

  async function go() {
    if (busy) return;
    setBusy(true);
    try {
      await relogin(srv.server, username.trim(), password);
      onDone(true);
    } catch (e) {
      onErr(String(e));
      setBusy(false);
    }
  }

  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        重新登录
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        {/* 地址行已按用户要求删掉:线路在「服务器线路」里维护,重登沿用当前生效那条。 */}
        <div className="fld">
          <label>账号</label>
          <input className="field" value={username} onChange={(e) => setUsername(e.target.value)} />
        </div>
        <div className="fld" style={{ marginBottom: 0 }}>
          <label>密码</label>
          <input
            className="field"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && go()}
            autoFocus
          />
        </div>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button className="btn primary" disabled={busy} onClick={go}>
          {busy ? <span className="spinner" /> : "登录"}
        </button>
      </div>
    </Scrim>
  );
}

/** 服务器线路(草稿 pin 29,本页最重要的窗):
    同步线路(=并发探延迟,GET /System/Info/Public,不是 ping)/ 添加 / 编辑 / 删除 / 拖动排序,
    行点击 = 切生效线路,当前线路高亮。增删改排序一律 set_lines 整表覆写。 */
function LinesDialog({
  srv,
  onClose,
  onDone,
  onErr,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: (sessionChanged: boolean) => void;
  onErr: (m: string) => void;
}) {
  /* lines 为空 = 核层的「单线路」形态(direct_line_url 回落到 account.server 本身)。
     这里补出一行可见主线,用户才能编辑/加线;probe_lines 对空表也正是探 server 本身
     并返回 index 0,下标对得上,不会错位。 */
  const [lines, setRows] = useState<ServerLine[]>(() =>
    srv.lines.length
      ? srv.lines
      : [{ id: srv.line_url, name: "主线", url: srv.line_url, remark: null }],
  );
  const [active, setActive] = useState(Math.min(srv.active_line, Math.max(srv.lines.length - 1, 0)));
  const [ms, setMs] = useState<Record<number, number | null>>({});
  const [busy, setBusy] = useState("");
  const [edit, setEdit] = useState<{ i: number; name: string; url: string } | null>(null);
  const dragFrom = useRef(-1);

  /** 整表落库 + 可选切生效线路。改完通知外层重拉(线路影响 line_url 展示)。 */
  async function persist(next: ServerLine[], nextActive: number) {
    setBusy("save");
    try {
      await setLines(srv.server, next);
      await setActiveLine(srv.server, nextActive);
      setRows(next);
      setActive(nextActive);
      setMs({}); // 行序变了,旧延迟对不上号,清掉比留着错位强
      onDone(true); // 生效线路可能变 → 会话地址跟着变,外层必须刷
    } catch (e) {
      onErr(String(e));
    } finally {
      setBusy("");
    }
  }

  /** 活跃行要跟着它的 URL 走 —— 只挪数组不挪下标,会静默把用户切到另一条线路上。 */
  const activeUrlAfter = (next: ServerLine[]) => {
    const cur = lines[active]?.url;
    const i = next.findIndex((l) => l.url === cur);
    return i < 0 ? 0 : i;
  };

  /** 同步线路 = 从服主部署的 emby_ext_domains 拉取备用域名并入表(草稿 pin 29 的原意)。
   *  ★ 这个按钮此前调的是 probeLines(测延迟)—— 名字叫「同步线路」却一条线路都不拉,
   *    是我做错了。测延迟已拆成旁边独立的按钮。
   *  ★ supported=false(服主没部署)是**常态**,绝大多数 Emby 服务器都没装,不能当错误弹。 */
  async function sync() {
    setBusy("sync");
    try {
      const r = await syncLines(srv.server);
      if (!r.supported) {
        onErr("这台服务器没有提供线路表(服主未部署 emby_ext_domains),线路请手动添加");
        return;
      }
      // 拉完重读:核层可能把裸地址落成了「主线」,本地这份副本必须跟着更新,否则下次
      // persist() 会拿旧表整表覆写,把刚同步进来的线路又抹掉。
      const fresh = await listAccounts();
      const me = fresh.find((x) => x.server === srv.server);
      if (me) {
        setRows(me.lines);
        setActive(me.active_line);
      }
      setMs({}); // 行变了,旧延迟对不上号
      onDone(true);
      onErr(r.added ? `已同步 ${r.added} 条新线路(共 ${r.total} 条)` : `线路已是最新(共 ${r.total} 条)`);
    } catch (e) {
      onErr(String(e));
    } finally {
      setBusy("");
    }
  }

  /** 测延迟:并发 GET 各线路的 /System/Info/Public(不是 ping)。单条不通 = ms:null,不算错误。 */
  async function probe() {
    setBusy("probe");
    try {
      const r = await probeLines(srv.server);
      const m: Record<number, number | null> = {};
      for (const p of r) m[p.index] = p.ms;
      setMs(m);
    } catch (e) {
      onErr(String(e)); // 探测整体失败要说出来;单条不通是 ms=null,不是错误
    } finally {
      setBusy("");
    }
  }

  async function pick(i: number) {
    if (busy || i === active) return;
    setBusy("save");
    try {
      await setActiveLine(srv.server, i);
      setActive(i);
      onDone(true);
    } catch (e) {
      onErr(String(e));
    } finally {
      setBusy("");
    }
  }

  function saveEdit() {
    if (!edit) return;
    const url = edit.url.trim();
    if (!url) {
      onErr("线路地址不能为空");
      return;
    }
    const row: ServerLine = {
      id: url.replace(/\/+$/, ""),
      name: edit.name.trim() || "线路",
      url,
      remark: null,
    };
    const next = [...lines];
    if (edit.i < 0) next.push(row);
    else next[edit.i] = { ...row, remark: lines[edit.i].remark };
    setEdit(null);
    persist(next, edit.i < 0 ? active : activeUrlAfter(next));
  }

  function del(i: number) {
    if (lines.length <= 1) {
      onErr("至少保留一条线路");
      return;
    }
    const next = lines.filter((_, k) => k !== i);
    persist(next, activeUrlAfter(next));
  }

  function drop(to: number) {
    const from = dragFrom.current;
    dragFrom.current = -1;
    if (from < 0 || from === to) return;
    const next = [...lines];
    const [it] = next.splice(from, 1);
    next.splice(to, 0, it);
    persist(next, activeUrlAfter(next));
  }

  const lat = (i: number) => {
    if (!(i in ms)) return "";
    const v = ms[i];
    return v == null ? "不通" : `${v}ms`;
  };

  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        服务器线路 · {srv.name}
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <div className="sv-linebar">
          <button className="btn sm" disabled={!!busy} onClick={sync}>
            {busy === "sync" ? <span className="spinner" /> : <><IconRefresh size={14} /> 同步线路</>}
          </button>
          {/* 测延迟拆成独立按钮(用户 2026-07-15 点名)。此前它和「同步线路」是同一个按钮,
              于是那个按钮名不副实:叫同步、干的却是测速。 */}
          <button className="btn sm" disabled={!!busy} onClick={probe}>
            {busy === "probe" ? <span className="spinner" /> : <><IconGauge size={14} /> 测延迟</>}
          </button>
          <button
            className="btn sm"
            disabled={!!busy}
            onClick={() => setEdit({ i: -1, name: "", url: "https://" })}
          >
            <IconPlus size={14} /> 添加线路
          </button>
          <span className="sv-note" style={{ margin: 0 }}>点「同步线路」一键探测全部线路延迟</span>
        </div>

        <div className="sv-lines">
          {lines.map((l, i) => (
            <div
              key={`${l.url}-${i}`}
              className={`sv-linerow${i === active ? " cur" : ""}`}
              draggable
              onDragStart={() => (dragFrom.current = i)}
              onDragOver={(e) => e.preventDefault()}
              onDrop={() => drop(i)}
              onDragEnd={() => (dragFrom.current = -1)}
              onClick={() => pick(i)}
              title={i === active ? "当前线路" : "点击切换到此线路"}
            >
              <span className="sv-drag" title="拖动排序">⠿</span>
              <span className="sv-u">{l.name} · {l.url}</span>
              <span className={`sv-lat${ms[i] != null && (ms[i] as number) > 300 ? " slow" : ""}${ms[i] === null ? " dead" : ""}`}>
                {lat(i)}
              </span>
              <span className="sv-acts" onClick={(e) => e.stopPropagation()}>
                <button className="sv-act" title="编辑" onClick={() => setEdit({ i, name: l.name, url: l.url })}>✎</button>
                <button className="sv-act" title="删除" onClick={() => del(i)}>✕</button>
              </span>
            </div>
          ))}
        </div>

        {edit && (
          <div className="sv-lineedit">
            <input
              className="field"
              placeholder="线路名(如:主线 / 备线 1)"
              value={edit.name}
              onChange={(e) => setEdit({ ...edit, name: e.target.value })}
            />
            <input
              className="field"
              placeholder="https://host:port"
              value={edit.url}
              onChange={(e) => setEdit({ ...edit, url: e.target.value })}
              onKeyDown={(e) => e.key === "Enter" && saveEdit()}
              autoFocus
            />
            <button className="btn sm" onClick={() => setEdit(null)}>取消</button>
            <button className="btn primary sm" onClick={saveEdit}>确定</button>
          </div>
        )}

        {/* 这里曾有一句「延迟自动探测(GET /System/Info/Public,非 ping),可拖动排序;当前线路高亮」。
            用户 2026-07-15:「下面对于测延迟的描述去掉 没有必要写出来」。
            而且那句还是**错的** —— 抄自草稿,但本弹窗里延迟从来不自动探,得点按钮。别加回来。 */}
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>关闭</button>
      </div>
    </Scrim>
  );
}

/** 更换图标(草稿 pin 26):三来源 —— 内置字形 / 网络图标源 / 本地上传。全部落核层。 */
function IconDialog({
  srv,
  icon,
  onClose,
  onDone,
  onErr,
}: {
  srv: AccountInfo;
  icon: string;
  onClose: () => void;
  /** uri:新的 data URI(字形/清空时为空)。 */
  onDone: (server: string, uri: string) => void;
  onErr: (m: string) => void;
}) {
  const [source, setSource] = useState<"builtin" | "net" | "upload">("builtin");
  const [glyph, setGlyph] = useState(srv.icon_url && isGlyph(srv.icon_url) ? srv.icon_url : "");
  const [url, setUrl] = useState(srv.icon_url && srv.icon_url.startsWith("http") ? srv.icon_url : "");
  const [path, setPath] = useState("");
  const [busy, setBusy] = useState(false);

  /* 网络图标库(四个聚合源,~1468 个,核层 24h 缓存)。首次开「网络图标源」页才拉,拉一次留着。
     lib=null 加载中 / [] 拉失败或空 / 有值渲染网格。q 按名字过滤。 */
  const [lib, setLib] = useState<IconEntry[] | null>(null);
  const [libErr, setLibErr] = useState("");
  const [q, setQ] = useState("");
  const loadLib = useCallback((force: boolean) => {
    setLib(null);
    setLibErr("");
    iconLibrary(force)
      .then((list) => {
        setLib(list);
        if (list.length === 0) setLibErr("图标库拉取失败,请检查网络后刷新");
      })
      .catch((e) => {
        setLib([]);
        setLibErr(String(e));
      });
  }, []);
  useEffect(() => {
    if (source === "net" && lib === null) loadLib(false);
  }, [source, lib, loadLib]);

  /* 过滤后**全量渲染**,不再封顶 300(用户 2026-07-16:「做成懒加载不得了」)。
     每个 <img loading="lazy"> + 格子 content-visibility:auto(见 css)→ 屏外不解码不排版,
     1468 个 DOM 结点在 webview 里稳得住,滚到哪拉到哪。 */
  const shownIcons = useMemo(() => {
    const all = lib ?? [];
    const kw = q.trim().toLowerCase();
    return kw ? all.filter((i) => i.name.toLowerCase().includes(kw)) : all;
  }, [lib, q]);

  /* 本地上传:webview 里的 <input type=file> 拿不到真实路径(File.path 不存在),
     而 set_account_icon_file 要的正是路径。项目未装 @tauri-apps/plugin-dialog,
     故用已装的 @tauri-apps/api 的拖放事件取真实路径(拖入即填),外加手填路径兜底。 */
  useEffect(() => {
    if (source !== "upload") return;
    let un: (() => void) | undefined;
    getCurrentWebview()
      .onDragDropEvent((e) => {
        if (e.payload.type === "drop" && e.payload.paths.length) setPath(e.payload.paths[0]);
      })
      .then((f) => {
        un = f;
      })
      .catch((e) => onErr(String(e)));
    return () => un?.();
  }, [source, onErr]);

  const preview = source === "net" && url ? url : source === "builtin" ? glyph : icon;

  async function apply() {
    if (busy) return;
    setBusy(true);
    try {
      if (source === "upload") {
        if (!path.trim()) throw new Error("请拖入图片,或填写图片的完整本机路径");
        // 它会缓存图片、回 data URI,并把原路径记进 icon_url(缓存清了还能重建)。
        const uri = await setAccountIconFile(srv.server, path.trim());
        onDone(srv.server, uri);
      } else if (source === "net") {
        const u = url.trim();
        if (!u) throw new Error("请粘贴图片 URL");
        // 先清旧缓存:icon_cache 命中缓存就直接返回,不清的话换了 URL 还是老图。
        await clearAccountIcon(srv.server);
        await updateAccount(srv.server, { iconUrl: u });
        const uri = await accountIcon(srv.server); // 下不动就报错,不静默留碎图
        onDone(srv.server, uri);
      } else {
        // 内置字形:字形本身存进 icon_url(短字符串,核层当本地路径读会 Err,
        // 前端 isGlyph 判定后按文本渲染)。空串 = 清空,回默认 IconServer。
        await clearAccountIcon(srv.server);
        await updateAccount(srv.server, { iconUrl: glyph });
        onDone(srv.server, "");
      }
    } catch (e) {
      onErr(String(e));
      setBusy(false);
    }
  }

  return (
    <Scrim onClose={onClose} className="sv-icondlg">
      <div className="dhd">
        更换图标 · {srv.name}
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <div className="seg" style={{ marginBottom: 12 }}>
          {(["builtin", "net", "upload"] as const).map((s) => (
            <span key={s} className={source === s ? "on" : ""} onClick={() => setSource(s)}>
              {s === "builtin" ? "内置图标" : s === "net" ? "网络图标源" : "本地上传"}
            </span>
          ))}
        </div>

        {source === "builtin" && (
          <div className="sv-iconpick">
            <span
              className={`sv-icell${!glyph ? " on" : ""}`}
              title="默认(Emby 图标)"
              onClick={() => setGlyph("")}
            >
              {/* 默认 = emby_default.png 本尊直接显示,不再用内置线框图 IconServer 顶替
                  (用户 2026-07-16:「默认的 Emby 图标就直接显示」)。 */}
              <img className="sv-def-ic" src="/emby_default.png" alt="默认" />
            </span>
            {GLYPHS.map((g) => (
              <span
                key={g}
                className={`sv-icell${glyph === g ? " on" : ""}`}
                onClick={() => setGlyph(g)}
              >
                {g}
              </span>
            ))}
          </div>
        )}

        {source === "net" && (
          <>
            {/* 搜索框 + 刷新。图标库来自四个聚合源(核层 24h 缓存),点选即选中,确定后下载缓存。 */}
            <div className="sv-libbar">
              <input
                className="field"
                placeholder={`搜索图标名${lib ? `(共 ${lib.length} 个)` : "…"}`}
                value={q}
                onChange={(e) => setQ(e.target.value)}
              />
              <button className="btn sm" disabled={lib === null} onClick={() => loadLib(true)} title="重新拉取">
                <IconRefresh size={14} />
              </button>
            </div>
            {lib === null ? (
              <div className="sv-libgrid loading"><span className="spinner" /></div>
            ) : libErr ? (
              <p className="sv-note">{libErr}</p>
            ) : (
              <div className="sv-libgrid">
                {shownIcons.map((ic) => (
                  <button
                    key={ic.url}
                    className={`sv-licell${url === ic.url ? " on" : ""}`}
                    title={`${ic.name}${ic.source ? ` · ${ic.source}` : ""}`}
                    onClick={() => setUrl(ic.url)}
                  >
                    {/* 缩略图直接 <img>,webview 自己缓存;选中的那张确定后才落 icon_cache。
                        loading=lazy:网格里几百张,滚到才拉。 */}
                    <img src={ic.url} alt={ic.name} loading="lazy"
                      onError={(e) => ((e.target as HTMLImageElement).style.visibility = "hidden")} />
                  </button>
                ))}
                {shownIcons.length === 0 && <p className="sv-note">没有匹配「{q}」的图标</p>}
              </div>
            )}
            {/* 高级:也能直接粘链接。选了网格里的图标这里会同步显示它的 URL。 */}
            <input
              className="field"
              style={{ marginTop: 8 }}
              placeholder="或直接粘贴图片 URL(http/https)…"
              value={url}
              onChange={(e) => setUrl(e.target.value)}
            />
          </>
        )}

        {source === "upload" && (
          <>
            <div className="sv-upload">
              {path || "把图片拖到窗口任意处,或在下方填写完整路径"}
            </div>
            <input
              className="field"
              style={{ marginTop: 10 }}
              placeholder="D:\\pic\\logo.png"
              value={path}
              onChange={(e) => setPath(e.target.value)}
            />
            <p className="sv-note">
              未装系统文件选择器插件(@tauri-apps/plugin-dialog),故用拖放取真实路径 + 手填兜底。
              图片上限 4MB,确定后由核层缓存并记住原路径。
            </p>
          </>
        )}

        <div className="sv-icon-preview">
          <span className="sv-sic lg">
            <ServerGlyph icon={preview} size={26} />
          </span>
          <span className="sv-note" style={{ margin: 0 }}>预览</span>
        </div>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button className="btn primary" disabled={busy} onClick={apply}>
          {busy ? <span className="spinner" /> : "确定"}
        </button>
      </div>
    </Scrim>
  );
}

/** 修改备注(草稿 pin 26):单输入,落核层(update_account.remark)。 */
function RemarkDialog({
  srv,
  onClose,
  onDone,
  onErr,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: (sessionChanged: boolean) => void;
  onErr: (m: string) => void;
}) {
  const [remark, setRemark] = useState(srv.remark || "");
  const [busy, setBusy] = useState(false);
  async function save() {
    if (busy) return;
    setBusy(true);
    try {
      await updateAccount(srv.server, { remark }); // 空串 = 清空备注
      onDone(false);
    } catch (e) {
      onErr(String(e));
      setBusy(false);
    }
  }
  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        修改备注 · {srv.name}
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <div className="fld" style={{ marginBottom: 0 }}>
          <label>备注(仅本机显示,不影响服务器)</label>
          <input
            className="field"
            value={remark}
            onChange={(e) => setRemark(e.target.value)}
            onKeyDown={(e) => e.key === "Enter" && save()}
            autoFocus
          />
        </div>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button className="btn primary" disabled={busy} onClick={save}>
          {busy ? <span className="spinner" /> : "保存"}
        </button>
      </div>
    </Scrim>
  );
}

/** 删除:确认后 removeAccount。 */
function DeleteDialog({
  srv,
  onClose,
  onDone,
  onErr,
}: {
  srv: AccountInfo;
  onClose: () => void;
  onDone: (sessionChanged: boolean) => void;
  onErr: (m: string) => void;
}) {
  const [busy, setBusy] = useState(false);
  async function del() {
    if (busy) return;
    setBusy(true);
    try {
      await removeAccount(srv.server);
      onDone(true);
    } catch (e) {
      onErr(String(e));
      setBusy(false);
    }
  }
  return (
    <Scrim onClose={onClose}>
      <div className="dhd">
        删除服务器
        <button className="x" onClick={onClose}>
          <IconClose size={16} />
        </button>
      </div>
      <div className="dbd">
        <p className="sv-note" style={{ marginTop: 0 }}>
          确定移除「{srv.name}」及其备注/图标/线路?此操作不会影响服务器本身。
        </p>
      </div>
      <div className="dft">
        <button className="btn" onClick={onClose}>取消</button>
        <button className="btn primary sv-danger-btn" disabled={busy} onClick={del}>
          {busy ? <span className="spinner" /> : "删除"}
        </button>
      </div>
    </Scrim>
  );
}
