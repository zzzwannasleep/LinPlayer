import { useEffect, useState } from "react";
import {
  type MarketList,
  type PluginInfo,
  type PluginSource,
  pluginDisable,
  pluginEnable,
  pluginList,
  pluginMarketAddSource,
  pluginMarketInstall,
  pluginMarketList,
  pluginMarketRemoveSource,
  pluginMarketSources,
  pluginMarketToggleSource,
  pluginUninstall,
  resolvePluginAssetUrl,
} from "@shared/api";
import Sheet from "../components/Sheet";
import { IconRefresh, IconTrash } from "../app/icons";

/* 插件。三个页签:市场 / 已装 / 源。与 PC 端同结构。

   ## 手机端少了什么(明说,不假装)
   PC 上有「从本地 .ipk 安装」和「挂一个开发目录热重载」两个入口 ——
   它们走的是**原生文件/目录选择器**,安卓上没有对应能力(SAF 是另一套交互模型)。
   所以这两条在安卓壳里根本没注册命令(见 apps/android/src/lib.rs 的说明),
   这里也就**不画那两个按钮** —— 画了点下去必然报 command not found。

   ## 市场的错误是按源收集的
   一个第三方源挂了不该让整个市场变成报错页。所以 errors 单独列在顶部,
   plugins 该画还是照画。 */

type Tab = "market" | "installed" | "sources";

export default function PluginsPage() {
  const [tab, setTab] = useState<Tab>("market");
  return (
    <div className="pg">
      <div className="chips lib-bar">
        {(
          [
            ["market", "市场"],
            ["installed", "已装"],
            ["sources", "源"],
          ] as const
        ).map(([id, label]) => (
          <button key={id} type="button" className={`chip${tab === id ? " on" : ""}`} onClick={() => setTab(id)}>
            {label}
          </button>
        ))}
      </div>
      {tab === "market" && <Market />}
      {tab === "installed" && <Installed />}
      {tab === "sources" && <Sources />}
    </div>
  );
}

function Market() {
  const [data, setData] = useState<MarketList | null>(null);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState("");
  const [perm, setPerm] = useState<{ id: string; name: string; perms: string[] } | null>(null);

  const load = (refresh?: boolean) => {
    setData(null);
    pluginMarketList(refresh).then(setData).catch((e) => setErr(String(e)));
  };
  useEffect(() => {
    load();
  }, []);

  if (err) return <div className="empty"><b>市场打不开</b><div className="dim">{err}</div></div>;
  if (!data) return <div className="empty"><div className="dim">加载中…</div></div>;

  return (
    <>
      {/* 按源收集的错误 —— 一个源挂了不影响别的源的插件照常显示 */}
      {data.errors.map((e) => (
        <div key={e.source} className="bad" style={{ margin: "0 16px 12px" }}>
          <b>{e.source}</b>
          <div>{e.error}</div>
        </div>
      ))}
      <div className="cells">
        {data.plugins.map((p) => {
          const v = p.versions[0];
          return (
            <div key={`${p.source_id}:${p.id}`} className="pg-it">
              <span className="pg-ic">
                {p.icon && <img src={resolvePluginAssetUrl(p.icon)} alt="" />}
              </span>
              <span className="pg-t">
                <span className="pg-n">
                  {p.name}
                  {!p.from_builtin && <span className="pg-badge">第三方源</span>}
                </span>
                <span className="pg-d dim">{p.description}</span>
                <span className="pg-m dim">
                  {[p.author, v?.version, v?.sha256 ? null : "无校验和"].filter(Boolean).join(" · ")}
                </span>
              </span>
              <button
                type="button"
                className="btn"
                disabled={busy === p.id}
                /* ★ 装之前必须让用户看见权限。核层会照单授予 ——
                   把这一步省掉等于替用户点了同意。 */
                onClick={() => setPerm({ id: p.id, name: p.name, perms: p.permissions })}
              >
                {busy === p.id ? "安装中…" : "安装"}
              </button>
            </div>
          );
        })}
      </div>
      <div className="pg-ft">
        <button type="button" className="btn ghost" onClick={() => load(true)}>
          <IconRefresh size={16} /> 刷新市场
        </button>
      </div>

      <Sheet open={perm != null} onClose={() => setPerm(null)} title={`${perm?.name ?? ""} 要这些权限`}>
        <div className="perms">
          {!perm?.perms.length ? (
            <div className="dim">这个插件不要任何权限。</div>
          ) : (
            perm.perms.map((x) => (
              <div key={x} className="perm">
                <b>{PERM_LABEL[x] ?? x}</b>
                {PERM_WHY[x] && <div className="dim">{PERM_WHY[x]}</div>}
              </div>
            ))
          )}
        </div>
        <div className="sheet-acts">
          <button type="button" className="btn ghost" onClick={() => setPerm(null)}>取消</button>
          <button
            type="button"
            className="btn primary"
            onClick={() => {
              if (!perm) return;
              const id = perm.id;
              setPerm(null);
              setBusy(id);
              pluginMarketInstall(id)
                .catch((e) => setErr(String(e)))
                .finally(() => setBusy(""));
            }}
          >
            同意并安装
          </button>
        </div>
      </Sheet>
    </>
  );
}

function Installed() {
  const [list, setList] = useState<PluginInfo[] | null>(null);
  const load = () => pluginList().then(setList).catch(() => setList([]));
  useEffect(() => {
    void load();
  }, []);

  if (!list) return <div className="empty"><div className="dim">加载中…</div></div>;
  if (!list.length) return <div className="empty"><div className="dim">还没有安装插件</div></div>;

  return (
    <div className="cells">
      {list.map((p) => (
        <div key={p.id} className="pg-it">
          <span className="pg-ic">{p.icon && <img src={resolvePluginAssetUrl(p.icon)} alt="" />}</span>
          <span className="pg-t">
            <span className="pg-n">
              {p.name}
              {p.dev && <span className="pg-badge">开发中</span>}
            </span>
            <span className="pg-m dim">
              {[p.version, p.author, p.status !== "loaded" ? p.status : null].filter(Boolean).join(" · ")}
            </span>
            {/* 出错的插件把错误写在脸上 —— 否则用户只看到"装了但没反应" */}
            {p.error && <span className="pg-err">{p.error}</span>}
          </span>
          <button
            type="button"
            className={`btn${p.enabled ? "" : " ghost"}`}
            onClick={() => (p.enabled ? pluginDisable(p.id) : pluginEnable(p.id)).then(load)}
          >
            {p.enabled ? "已启用" : "已停用"}
          </button>
          <button
            type="button"
            className="mini-ico"
            aria-label="卸载"
            onClick={() => pluginUninstall(p.id).then(load)}
          >
            <IconTrash size={20} />
          </button>
        </div>
      ))}
    </div>
  );
}

function Sources() {
  const [list, setList] = useState<PluginSource[] | null>(null);
  const [adding, setAdding] = useState(false);
  const [name, setName] = useState("");
  const [url, setUrl] = useState("");
  const [err, setErr] = useState("");

  useEffect(() => {
    pluginMarketSources().then(setList).catch((e) => setErr(String(e)));
  }, []);

  if (err) return <div className="empty"><b>读不到源</b><div className="dim">{err}</div></div>;
  if (!list) return <div className="empty"><div className="dim">加载中…</div></div>;

  return (
    <>
      <div className="cells">
        {list.map((s) => (
          <div key={s.id} className="pg-it">
            <span className="pg-t">
              <span className="pg-n">
                {s.name}
                {s.builtin && <span className="pg-badge">官方</span>}
              </span>
              <span className="pg-m dim">{s.url}</span>
            </span>
            <button
              type="button"
              className={`btn${s.enabled ? "" : " ghost"}`}
              onClick={() => pluginMarketToggleSource(s.id, !s.enabled).then(setList)}
            >
              {s.enabled ? "已启用" : "已停用"}
            </button>
            {/* 官方源**可禁不可删** —— 删了用户就再也装不了官方插件,且没有恢复入口 */}
            {!s.builtin && (
              <button
                type="button"
                className="mini-ico"
                aria-label="移除"
                onClick={() => pluginMarketRemoveSource(s.id).then(setList)}
              >
                <IconTrash size={20} />
              </button>
            )}
          </div>
        ))}
      </div>
      <div className="pg-ft">
        <button type="button" className="btn ghost" onClick={() => setAdding(true)}>添加源</button>
      </div>

      <Sheet open={adding} onClose={() => setAdding(false)} title="添加插件源">
        <label className="field">
          <span>名称</span>
          <input value={name} onChange={(e) => setName(e.target.value)} placeholder="我的源" />
        </label>
        <label className="field">
          <span>registry 地址</span>
          <input
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="https://…/registry.json"
            autoCapitalize="none"
            autoCorrect="off"
          />
        </label>
        <div className="sheet-acts">
          <button type="button" className="btn ghost" onClick={() => setAdding(false)}>取消</button>
          <button
            type="button"
            className="btn primary"
            disabled={!name.trim() || !url.trim()}
            onClick={() =>
              pluginMarketAddSource(name.trim(), url.trim())
                .then((l) => {
                  setList(l);
                  setAdding(false);
                  setName("");
                  setUrl("");
                })
                .catch((e) => setErr(String(e)))
            }
          >
            添加
          </button>
        </div>
      </Sheet>
    </>
  );
}

/* 权限文案。★ 不要直接把权限 id 甩给用户 ——「net」对他毫无信息量,
   他要知道的是"装了之后这插件能干什么"。 */
const PERM_LABEL: Record<string, string> = {
  net: "访问网络",
  storage: "保存自己的数据",
  player: "控制播放器",
  ui: "显示界面",
  emby: "读取当前 Emby 会话",
  source: "提供片源",
  cfproxy: "使用 CF 优选代理",
};
const PERM_WHY: Record<string, string> = {
  net: "只能访问它声明过的域名",
  emby: "能拿到当前登录的服务器地址和令牌",
  player: "能播放、暂停、跳转",
};
