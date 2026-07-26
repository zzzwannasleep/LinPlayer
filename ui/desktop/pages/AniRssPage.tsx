import { useCallback, useEffect, useMemo, useState } from "react";
import {
  type Json,
  anirssAddAni,
  anirssDeleteAni,
  anirssGetAniBySubjectId,
  anirssGetConfig,
  anirssListAni,
  anirssRefreshAll,
  anirssRefreshAni,
  anirssSearchBgm,
  anirssSetAni,
  anirssSetConfig,
  anirssTorrentsInfos,
} from "@shared/api";
import {
  type Ani,
  type Dl,
  type Torrent,
  aniOf,
  matchTorrents,
  statusOf,
  str,
  torrentOf,
} from "@shared/anirss-model";
import {
  IconChevronLeft,
  IconClose,
  IconPlay,
  IconPlus,
  IconRefresh,
  IconTrash,
} from "../app/icons";
import "./AniRssPage.css";

/* ============================================================
   Ani-RSS 追番订阅页(草稿 PAGE 13)。
   内容区顶部分段(首页/订阅/设置)取代移动端底部导航 —— 标注 41。
   首页 = 番剧海报墙,订阅 = 逐集进度行,设置 = 镜像服务端 Config 表单。

   数据走 anirss_* 专用命令(核层镜像 Ani-RSS 服务端 ~50 个接口)。
   ★ 别再改回 sourceListDir(null) + 手扒 entry.raw:那条通用文件浏览路径把每部番包成
     「文件夹」,id 是 `ani:<整个 JSON 字符串>`,拿不到干净的 ani.id,更没法做增删改。
   ============================================================ */

type Seg = "home" | "sub" | "settings";

/* 纯模型层(Ani 归一化 / 种子归组 / 集号解析 / 状态文案)已提到 @shared/anirss-model ——
   手机端用的是同一份。那些判据抄错一档就会把下载进度标到另一部番上,而界面看着完全正常。
   下面留的是**这一页私有**的东西:右键菜单上下文、删除确认、每行显示几集、轮询间隔。 */

type Ctx = { x: number; y: number; ani: Ani };
/** 删除要不要连文件一起删,必须让用户明说 —— 删片子不能靠猜。 */

/** 删除要不要连文件一起删,必须让用户明说 —— 删片子不能靠猜。 */
type DelAsk = { ani: Ani };

// 长番(百集以上)全渲染会刷出几百个格子拖垮列表,超出部分折成 +N。
const EP_CAP = 24;
// 种子进度轮询间隔,对齐旧 Flutter 端 anirss_providers 的 3s。

// 种子进度轮询间隔,对齐旧 Flutter 端 anirss_providers 的 3s。
const TORRENT_POLL_MS = 3000;

export default function AniRssPage({ onBack }: { onBack: () => void }) {
  const [seg, setSeg] = useState<Seg>("sub");
  const [list, setList] = useState<Ani[] | null>(null);
  const [err, setErr] = useState("");
  const [ctx, setCtx] = useState<Ctx | null>(null);
  const [addOpen, setAddOpen] = useState(false);
  const [delAsk, setDelAsk] = useState<DelAsk | null>(null);
  const [toast, setToast] = useState("");
  const [busy, setBusy] = useState(false);
  const [torrents, setTorrents] = useState<Torrent[]>([]);

  const load = useCallback(async () => {
    setList(null);
    setErr("");
    setCtx(null);
    try {
      setList((await anirssListAni()).map(aniOf));
    } catch (e) {
      setErr(String(e));
      setList([]);
    }
  }, []);

  useEffect(() => {
    load();
  }, [load]);

  // 种子进度轮询:只在订阅页且已有订阅时转,离开就停(别在设置页空转打服务端)。
  useEffect(() => {
    if (seg !== "sub" || !list || list.length === 0) return;
    let alive = true;
    const tick = async () => {
      try {
        const d = await anirssTorrentsInfos();
        // data=TorrentInfo[];服务端偶尔给 null/对象,不是数组就当没有,别炸。
        if (alive) setTorrents(Array.isArray(d) ? (d as Json[]).map(torrentOf) : []);
      } catch {
        // 轮询失败不打断整页:订阅列表还是好的,只是这一轮没有进度。
        if (alive) setTorrents([]);
      }
    };
    tick();
    const timer = setInterval(tick, TORRENT_POLL_MS);
    return () => {
      alive = false;
      clearInterval(timer);
    };
  }, [seg, list]);

  useEffect(() => {
    if (!toast) return;
    const t = setTimeout(() => setToast(""), 2600);
    return () => clearTimeout(t);
  }, [toast]);

  // 右键菜单:外部点击/滚动/Esc 关(同 NetdiskPage)。
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

  const dlMap = useMemo(() => matchTorrents(list ?? [], torrents), [list, torrents]);

  /** 写操作统一入口:错误要说出来,做完重拉(服务端是唯一真相,不本地猜新状态)。 */
  const run = async (label: string, fn: () => Promise<void>) => {
    if (busy) return;
    setBusy(true);
    setCtx(null);
    try {
      await fn();
      setToast(label);
      await load();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  const toggleEnable = (a: Ani) =>
    // ★ 回传完整 raw 改 enable 一个字段 —— 只发 {id, enable} 会把其它字段清空。
    run(a.enable ? "已停用订阅" : "已启用订阅", () =>
      anirssSetAni({ ...a.raw, enable: !a.enable }),
    );

  return (
    <>
      <div className="cbar">
        <button className="ibtn" title="返回" onClick={onBack}>
          <IconChevronLeft size={15} />
        </button>
        <span className="crumb">
          <b>Ani-RSS</b>
          {list && list.length > 0 && <span className="count">· {list.length}</span>}
        </span>
        <span className="push">
          <span className="seg">
            <span className={seg === "home" ? "on" : ""} onClick={() => setSeg("home")}>
              首页
            </span>
            <span className={seg === "sub" ? "on" : ""} onClick={() => setSeg("sub")}>
              订阅
            </span>
            <span className={seg === "settings" ? "on" : ""} onClick={() => setSeg("settings")}>
              设置
            </span>
          </span>
          <button className="btn sm" onClick={() => setAddOpen(true)}>
            <IconPlus size={13} /> 搜索并添加订阅
          </button>
          <button
            className="ibtn"
            title="刷新全部订阅"
            disabled={busy}
            onClick={() => run("已触发全部刷新", anirssRefreshAll)}
          >
            <IconRefresh size={15} />
          </button>
        </span>
      </div>

      {err && <div className="toast error">{err}</div>}

      <div className="scroll">
        <div className="cbody">
          {seg === "settings" ? (
            <ConfigForm onErr={setErr} onSaved={() => setToast("设置已保存")} />
          ) : list == null ? (
            <div className="empty ar-center">
              <span className="spinner" />
            </div>
          ) : err && list.length === 0 ? (
            <div className="empty">
              未登录 Ani-RSS 源。请在「服务器 › 添加」登录 Ani-RSS 后进入。
              <div className="ar-empty-act">
                <button className="btn" onClick={onBack}>
                  返回服务器
                </button>
              </div>
            </div>
          ) : list.length === 0 ? (
            <div className="empty">还没有订阅任何番剧。</div>
          ) : seg === "home" ? (
            // 首页 = 番剧海报墙(标注 41)。
            <div className="ar-wall enter">
              {list.map((a) => (
                <div className={`ar-tile${a.enable ? "" : " off"}`} key={a.key}>
                  <Cover ani={a} className="ar-tile-cv" />
                  <div className="ar-tile-cap">{a.title}</div>
                </div>
              ))}
            </div>
          ) : (
            <div className="enter">
              {list.map((a) => (
                <div
                  className="ar-subrow"
                  key={a.key}
                  onContextMenu={(ev) => {
                    ev.preventDefault();
                    setCtx({ x: ev.clientX, y: ev.clientY, ani: a });
                  }}
                >
                  <Cover ani={a} className="ar-cv" />
                  <div className="ar-mid">
                    <div className="ar-tt">
                      {a.title}
                      <span className={a.enable ? "ar-on" : "ar-offlbl"}>
                        {a.enable ? " · 启用" : " · 未启用"}
                      </span>
                    </div>
                    <Eps ani={a} dl={dlMap.get(a.key)} />
                    <div className="ar-sub">{statusOf(a, dlMap.get(a.key))}</div>
                  </div>
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
          {/* 三个管理动作都靠 id 定位。id 为空(服务端没给)时点了只会打一个必失败的请求,
              不如挡住并说清楚 —— 别把错误留到用户点完才炸。 */}
          {ctx.ani.id ? (
            <>
              <div
                className="mi"
                onClick={() => run("已触发刷新", () => anirssRefreshAni(ctx.ani.id))}
              >
                <IconRefresh size={15} /> 刷新此订阅
              </div>
              <div className="mi" onClick={() => toggleEnable(ctx.ani)}>
                <IconPlay size={15} /> {ctx.ani.enable ? "停用" : "启用"}
              </div>
              <div
                className="mi danger"
                onClick={() => {
                  setDelAsk({ ani: ctx.ani });
                  setCtx(null);
                }}
              >
                <IconTrash size={15} /> 删除订阅
              </div>
            </>
          ) : (
            <div className="mi ar-mi-off" title="服务端未给这条订阅 id,无法定位">
              该订阅缺 id，无法管理
            </div>
          )}
        </div>
      )}

      {delAsk && (
        <div className="scrim" onClick={() => setDelAsk(null)}>
          <div className="dlg" onClick={(e) => e.stopPropagation()}>
            <div className="dhd">
              删除订阅
              <button className="x" onClick={() => setDelAsk(null)}>
                <IconClose size={15} />
              </button>
            </div>
            <div className="dbd">
              确定删除「{delAsk.ani.title}」的订阅？
              <div className="caption-note ar-del-note">
                「同时删除文件」会把已下好的剧集文件一并删除，不可撤销。
              </div>
            </div>
            <div className="dft">
              <button className="btn" onClick={() => setDelAsk(null)}>
                取消
              </button>
              {/* 两个出口写清楚各删什么 —— 删文件这种事不能藏在一个「确定」后面。 */}
              <button
                className="btn"
                disabled={busy}
                onClick={() => {
                  const a = delAsk.ani;
                  setDelAsk(null);
                  run("已删除订阅(文件保留)", () => anirssDeleteAni([a.id], false));
                }}
              >
                仅删订阅
              </button>
              <button
                className="btn ar-btn-danger"
                disabled={busy}
                onClick={() => {
                  const a = delAsk.ani;
                  setDelAsk(null);
                  run("已删除订阅及文件", () => anirssDeleteAni([a.id], true));
                }}
              >
                同时删除文件
              </button>
            </div>
          </div>
        </div>
      )}

      {addOpen && (
        <AddDialog
          onClose={() => setAddOpen(false)}
          onAdded={(name) => {
            setAddOpen(false);
            setToast(`已添加订阅：${name}`);
            load();
          }}
        />
      )}

      {toast && <div className="toast">{toast}</div>}
    </>
  );
}

/** 封面:有图就用,加载失败或没有就退回全局斜纹占位。 */
function Cover({ ani, className }: { ani: Ani; className: string }) {
  const [bad, setBad] = useState(false);
  if (!ani.image || bad) return <div className={`${className} ph`} />;
  return (
    <img
      className={className}
      src={ani.image}
      alt=""
      loading="lazy"
      onError={() => setBad(true)}
    />
  );
}

/** 逐集格:≤ currentEpisodeNumber 视为已下载;正在下的那一集标 .dl(草稿 42)。 */
function Eps({ ani, dl }: { ani: Ani; dl: Dl | undefined }) {
  const total = ani.totalEpisodeNumber ?? ani.currentEpisodeNumber;
  if (total == null || total <= 0) return null;
  const done = ani.currentEpisodeNumber ?? 0;
  const shown = Math.min(total, EP_CAP);
  return (
    <div className="ar-eps">
      {Array.from({ length: shown }, (_, i) => {
        const n = i + 1;
        const cls = dl?.ep === n ? " dl" : n <= done ? " done" : "";
        return (
          <span className={`ar-epdot${cls}`} key={n}>
            {n}
          </span>
        );
      })}
      {total > shown && <span className="ar-epmore">+{total - shown}</span>}
    </div>
  );
}

/* ---------- 搜索并添加订阅(标注 42) ---------- */
/* 流程:searchBgm(名字) → 选条目 → getAniBySubjectId(id) 生成可添加的 Ani → addAni。
   中间那步不能省:addAni 要的是完整 Ani 对象,不是 bgm 的搜索结果。 */

type Bgm = { id: string; name: string; nameCn: string | null; image: string | null };

function bgmOf(j: Json): Bgm {
  return {
    id: String(j.id ?? ""),
    name: str(j.name) ?? "",
    nameCn: str(j.nameCn),
    image: str(j.image),
  };
}

function AddDialog({
  onClose,
  onAdded,
}: {
  onClose: () => void;
  onAdded: (name: string) => void;
}) {
  const [name, setName] = useState("");
  const [hits, setHits] = useState<Bgm[] | null>(null);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);

  const search = async () => {
    const q = name.trim();
    if (!q || busy) return;
    setBusy(true);
    setErr("");
    setHits(null);
    try {
      const d = await anirssSearchBgm(q);
      setHits(Array.isArray(d) ? (d as Json[]).map(bgmOf) : []);
    } catch (e) {
      setErr(String(e));
      setHits([]);
    } finally {
      setBusy(false);
    }
  };

  const add = async (b: Bgm) => {
    if (busy) return;
    setBusy(true);
    setErr("");
    try {
      // 服务端按 bgm 条目 id 生成订阅对象,原样回传给 addAni —— 别在前端拼这个对象。
      const ani = await anirssGetAniBySubjectId(b.id);
      await anirssAddAni(ani);
      onAdded(b.nameCn || b.name);
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="scrim" onClick={onClose}>
      <div className="dlg wide" onClick={(e) => e.stopPropagation()}>
        <div className="dhd">
          搜索并添加订阅
          <button className="x" onClick={onClose}>
            <IconClose size={15} />
          </button>
        </div>
        <div className="dbd">
          <div className="ar-add-row">
            <input
              className="field"
              placeholder="番剧名(搜 Bangumi)"
              value={name}
              autoFocus
              onChange={(e) => setName(e.target.value)}
              onKeyDown={(e) => e.key === "Enter" && search()}
            />
            <button className="btn primary" onClick={search} disabled={busy || !name.trim()}>
              搜索
            </button>
          </div>
          {err && <div className="ar-add-err">{err}</div>}
          {busy && hits == null ? (
            <div className="empty">
              <span className="spinner" />
            </div>
          ) : hits == null ? (
            <div className="caption-note ar-add-note">输入番剧名后回车搜索。</div>
          ) : hits.length === 0 ? (
            <div className="empty">没搜到条目。</div>
          ) : (
            hits.map((b) => (
              <div className="ar-add-hit" key={b.id}>
                {b.image ? (
                  <img className="ar-add-cv" src={b.image} alt="" loading="lazy" />
                ) : (
                  <span className="ar-add-cv ph" />
                )}
                <span className="ar-add-nm">
                  <b>{b.nameCn || b.name}</b>
                  {b.nameCn && b.name !== b.nameCn && <i>{b.name}</i>}
                </span>
                <button className="btn sm" disabled={busy} onClick={() => add(b)}>
                  添加
                </button>
              </div>
            ))
          )}
        </div>
        <div className="dft">
          <button className="btn" onClick={onClose}>
            关闭
          </button>
        </div>
      </div>
    </div>
  );
}

/* ---------- 设置:镜像服务端 Config 表单(标注 41) ---------- */
/* ★ 核层文档明写:set_config 必须回传 get_config 拿到的**完整 map** 改字段后的结果,
   否则丢字段。所以这里始终 {...cfg, [k]: v} 整表带走,不挑字段发。
   服务端 config 是扁平 map,标量字段直接渲染成输入;数组/对象等复杂字段不在此编辑,
   但**原样保留**在 map 里跟着一起回传(否则保存一次就把它们抹了)。 */

function ConfigForm({
  onErr,
  onSaved,
}: {
  onErr: (e: string) => void;
  onSaved: () => void;
}) {
  const [cfg, setCfg] = useState<Json | null>(null);
  const [saving, setSaving] = useState(false);
  const [filter, setFilter] = useState("");

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const c = await anirssGetConfig();
        if (alive) setCfg(c);
      } catch (e) {
        if (alive) {
          setCfg({});
          onErr(String(e));
        }
      }
    })();
    return () => {
      alive = false;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  const save = async () => {
    if (!cfg || saving) return;
    setSaving(true);
    try {
      await anirssSetConfig(cfg);
      onSaved();
    } catch (e) {
      onErr(String(e));
    } finally {
      setSaving(false);
    }
  };

  if (cfg == null) {
    return (
      <div className="empty ar-center">
        <span className="spinner" />
      </div>
    );
  }

  const keys = Object.keys(cfg).sort();
  const q = filter.trim().toLowerCase();
  const shown = q ? keys.filter((k) => k.toLowerCase().includes(q)) : keys;

  const patch = (k: string, v: unknown) => setCfg((c) => ({ ...(c ?? {}), [k]: v }));

  return (
    <div className="mdpane ar-pane">
      <h4>Ani-RSS 设置</h4>
      <p className="hint">
        镜像 Ani-RSS 服务端的配置项(共 {keys.length} 项)。保存会整表回传。
      </p>
      <div className="ar-cfg-tools">
        <input
          className="field"
          placeholder="筛选配置项…"
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
        />
        <button className="btn primary" onClick={save} disabled={saving}>
          {saving ? "保存中…" : "保存"}
        </button>
      </div>
      {shown.length === 0 ? (
        <div className="empty">没有匹配的配置项。</div>
      ) : (
        <div className="ar-cfg">
          {shown.map((k) => {
            const v = cfg[k];
            if (typeof v === "boolean") {
              return (
                <div className="ar-cfg-row" key={k}>
                  <label className="ar-cfg-k" title={k}>
                    {k}
                  </label>
                  <button
                    className={`p-sw${v ? " on" : ""}`}
                    onClick={() => patch(k, !v)}
                    type="button"
                  >
                    <i />
                  </button>
                </div>
              );
            }
            if (typeof v === "number") {
              return (
                <div className="ar-cfg-row" key={k}>
                  <label className="ar-cfg-k" title={k}>
                    {k}
                  </label>
                  <input
                    className="field"
                    type="number"
                    value={v}
                    onChange={(e) => {
                      const n = Number(e.target.value);
                      // 空/非数字不写回:写个 NaN 进去保存就把这项毁了。
                      if (Number.isFinite(n)) patch(k, n);
                    }}
                  />
                </div>
              );
            }
            if (typeof v === "string") {
              return (
                <div className="ar-cfg-row" key={k}>
                  <label className="ar-cfg-k" title={k}>
                    {k}
                  </label>
                  <input
                    className="field"
                    value={v}
                    onChange={(e) => patch(k, e.target.value)}
                  />
                </div>
              );
            }
            // 数组/对象/null:不在这儿编辑,但如实显示,且原样跟着整表回传。
            return (
              <div className="ar-cfg-row" key={k}>
                <label className="ar-cfg-k" title={k}>
                  {k}
                </label>
                <input
                  className="field"
                  value={JSON.stringify(v)}
                  readOnly
                  title="复杂字段,此处不编辑(保存时原样保留)"
                />
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
