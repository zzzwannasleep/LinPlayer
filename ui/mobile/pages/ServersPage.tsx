import { useEffect, useState } from "react";
import {
  type AccountInfo,
  listAccounts,
  probeAccounts,
  removeAccount,
  setActiveServer,
} from "@shared/api";
import type { PageId } from "../app/nav";
import Sheet from "../components/Sheet";
import { IconCheck, IconPlus, IconRefresh, IconTrash } from "../app/icons";

/* 服务器 / 源列表。

   ★ 卡片上**只显示 图标 / 名称 / 备注**三样,不显示线路或 URL。
     名字下面那行小字是**备注**,不是域名 —— 这是 TV 端评审时用户逐条纠正过的口径,
     三端一致。想看线路去线路管理页。

   ★ 状态三态:ok / reauth / down / unknown。unknown 是「还没探过」,
     和 down「探过确实不通」**同色不同义**,所以文案要分开写 ——
     把没探过的显示成"离线"会让用户以为服务器挂了。 */

const STATUS: Record<string, { t: string; c: string }> = {
  ok: { t: "正常", c: "ok" },
  reauth: { t: "需重新登录", c: "warn" },
  down: { t: "连不上", c: "bad" },
  unknown: { t: "未检测", c: "dim" },
};

export default function ServersPage({ onGo }: { onGo: (p: PageId) => void }) {
  const [list, setList] = useState<AccountInfo[] | null>(null);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const [sel, setSel] = useState<AccountInfo | null>(null);

  const load = () => listAccounts().then(setList).catch((e) => setErr(String(e)));
  useEffect(() => {
    load();
  }, []);

  if (err) return <div className="empty"><b>加载失败</b><div className="dim">{err}</div></div>;
  if (!list) return <div className="empty"><div className="dim">加载中…</div></div>;

  return (
    <div className="srv">
      <div className="chips lib-bar">
        <button type="button" className="chip" onClick={() => onGo("addserver")}>
          <IconPlus size={15} /> 添加
        </button>
        <button
          type="button"
          className="chip"
          disabled={busy}
          onClick={() => {
            setBusy(true);
            probeAccounts().then(setList).catch(() => {}).finally(() => setBusy(false));
          }}
        >
          <IconRefresh size={15} /> {busy ? "检测中…" : "检测连通"}
        </button>
      </div>

      <div className="cells">
        {list.map((a) => {
          const st = STATUS[a.status] ?? STATUS.unknown;
          return (
            <button
              key={a.server}
              type="button"
              className={`cell srv-it${a.active ? " on" : ""}`}
              /* 单击 = 切到这台。长按/右侧「…」= 管理(删除等)。
                 手机上没有右键,所以把管理放进一个显式的入口而不是靠长按发现 ——
                 长按适合"高频用户知道的加速键",不适合"唯一入口"。 */
              onClick={() => {
                if (a.active) return;
                setActiveServer(a.server).then(load);
              }}
            >
              <span className="srv-ic">
                {a.icon_url ? <img src={a.icon_url} alt="" /> : <span className="srv-ph">{a.name.slice(0, 1)}</span>}
              </span>
              <span className="cell-l">
                <span className="srv-n">{a.name}</span>
                {/* 这一行是**备注**,不是域名 */}
                {a.remark && <span className="srv-r dim">{a.remark}</span>}
              </span>
              <span className={`srv-st ${st.c}`}>{st.t}</span>
              {a.active && <IconCheck size={16} />}
              <span
                className="srv-more"
                role="button"
                tabIndex={0}
                onClick={(e) => {
                  e.stopPropagation();
                  setSel(a);
                }}
              >
                ⋯
              </span>
            </button>
          );
        })}
      </div>

      <Sheet open={sel != null} onClose={() => setSel(null)} title={sel?.name}>
        <div className="opts">
          <button
            type="button"
            className="opt bad"
            onClick={() => {
              if (!sel) return;
              /* 删除前不弹二次确认对话框,但**文案写清后果** —— sheet 本身已经是
                 一次显式操作,再叠一层确认在手机上是纯粹的摩擦。 */
              removeAccount(sel.server).then(() => {
                setSel(null);
                load();
              });
            }}
          >
            <IconTrash size={18} /> 移除这个源
            <div className="dim">只从本机移除登录,不动服务器上的任何数据</div>
          </button>
        </div>
      </Sheet>
    </div>
  );
}
