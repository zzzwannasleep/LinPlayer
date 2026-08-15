import { useEffect, useState } from "react";
import {
  type AccountInfo,
  accountIcon,
  listAccounts,
  probeAccounts,
  relogin,
  removeAccount,
  setActiveServer,
  updateAccount,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon, iconNode } from "../app/icons";
import { haptic, menu, toast } from "../app/motion";
import Page, { BarButton } from "../components/Page";
import Sheet from "../components/Sheet";
import { Empty, usePress } from "../components/ui";
import { Field, KIND_QR, KIND_UP, SourceForm, emptyForm, type FormState } from "../components/SourceForm";

/* 服务器 —— 底栏第三个 Tab(取代原来的「设置」;设置挪到首页右上角)。
   多源用户天天切服务器,它值得占拇指最贵的位置之一;设置是低频配置入口。

   ## 长按 = PC 的右键
   七项:设为当前 / 编辑信息 / 重新登录 / 服务器线路 / 更换图标 / 修改备注 / 删除。
   ★ 「设为当前」只在**不是当前**那台上出现 —— 摆一个点了没反应的项比不摆更糟。

   ## 两条从 PC 代码里钉出来的顺序,照抄
   1. 编辑弹窗里 **relogin 必须排在 updateAccount 前**:反了的话 relogin 写的记录
      会被随后的 updateAccount 整个覆盖掉。
   2. **重新登录不能用 `login()`** —— 它按「登录时用的地址」upsert,会凭空多出一台服务器;
      `relogin()` 才是原地换 token,而且自动用当前生效的那条线路。

   ## 我不照抄 PC 的一处
   PC 的 `ReloginDialog` 写死账号+密码两个字段,**扫码型源(阿里/夸克/百度)在 PC 的
   服务器页根本没法重登** —— 那是 PC 的残缺。这里复用 `SourceForm`,扫码型给二维码。 */

const ST: Record<string, { cls: string; text: string }> = {
  ok: { cls: "on", text: "连接正常" },
  reauth: { cls: "warn", text: "需重新登录" },
  down: { cls: "off", text: "无法连接" },
  unknown: { cls: "unk", text: "未探测" },
};

/** 图标三形态共用一个字符串字段(和 Rust `Account.icon_url` 一致):
 *  内置字形(1~2 个字符、不含路径符号)/ 图片地址 / 空。
 *  ★ **别在手机端另发明一个 iconType 字段** —— 判据抄 PC 那份。 */
export const isGlyph = (s: string | null) => !!s && s.length <= 2 && !/[\\/:.]/.test(s);

/** 源类型的中文名。★ 服务器列表第二行没有备注时显示它,**不显示地址**
 *  (用户 2026-08-02:「服务器名称下面跟的应该是备注,而不是线路名称或线路地址」)。
 *  认不出的 kind(插件源形如 `plugin:<id>/<src>`)回落成「插件源」。 */
const KIND_NAME: Record<string, string> = {
  emby: "Emby / Jellyfin", feiniu: "飞牛影视", anirss: "Ani-RSS",
  openlist: "OpenList", aliyundrive: "阿里云盘", quark: "夸克网盘", baidu: "百度网盘",
  pan115: "115 网盘", pan189: "天翼云盘", pan139: "移动云盘",
  smb: "SMB 共享", webdav: "WebDAV", ftp: "FTP", local: "本机文件夹",
};

const KIND_IC: Record<string, string> = {
  emby: "server", feiniu: "server", anirss: "rss",
  openlist: "cloud", aliyundrive: "cloud", quark: "cloud", baidu: "cloud",
  pan115: "cloud", pan189: "cloud", pan139: "cloud",
  smb: "server", webdav: "server", ftp: "server", local: "folder",
};

/** 这个源该进哪个浏览页;Emby 没有"它自己的浏览页"(内容摊在首页/媒体库),返回 null。
 *  插件源的 kind 形如 `plugin:<插件id>/<源id>`,和网盘一样走通用文件浏览页。 */
function browsePageOf(kind: string): "netdisk" | "anirss" | null {
  if (!kind || kind === "emby") return null;
  return kind === "anirss" ? "anirss" : "netdisk";
}

export default function ServersPage() {
  const { go, reloadGate } = useCtx();
  const [list, setList] = useState<AccountInfo[] | null>(null);
  const [err, setErr] = useState("");
  const [icons, setIcons] = useState<Record<string, string>>({});
  const [sheet, setSheet] = useState<null | { kind: "edit" | "relogin" | "remark" | "del"; sv: AccountInfo }>(null);

  const load = () =>
    listAccounts()
      .then((a) => {
        setList(a);
        // 图标各自异步取,取不到就回落内置图标 —— 不阻塞列表
        a.forEach((x) => {
          if (!x.icon_url || isGlyph(x.icon_url)) return;
          accountIcon(x.server)
            .then((d) => setIcons((m) => ({ ...m, [x.server]: d })))
            .catch(() => {});
        });
      })
      .catch((e) => setErr(String(e)));

  useEffect(() => {
    load();
  }, []);

  const openMenu = (sv: AccountInfo, x: number, y: number) => {
    const items: Parameters<typeof menu>[2] = [];
    /* ★ 只有不是当前那台才给「设为当前」 */
    if (!sv.active) {
      items.push({
        icon: iconNode("check", 18),
        label: "设为当前",
        on: () =>
          setActiveServer(sv.server)
            .then(() => {
              toast(`已切到 ${sv.name}`, "ok");
              reloadGate();
              load();
            })
            .catch((e) => toast(String(e), "bad")),
      });
    }
    items.push(
      { icon: iconNode("pencil", 18), label: "编辑信息", on: () => setSheet({ kind: "edit", sv }) },
      { icon: iconNode("key", 18), label: "重新登录", on: () => setSheet({ kind: "relogin", sv }) },
      { icon: iconNode("line", 18), label: "服务器线路…", on: () => go({ page: "lines", serverId: sv.server }) },
      { icon: iconNode("image", 18), label: "更换图标", on: () => go({ page: "icon", serverId: sv.server }) },
      { icon: iconNode("info", 18), label: "修改备注", on: () => setSheet({ kind: "remark", sv }) },
      "-",
      { icon: iconNode("trash", 18), label: "删除", bad: true, on: () => setSheet({ kind: "del", sv }) },
    );
    menu(x, y, items);
  };

  return (
    <Page
      title="服务器"
      big
      right={
        <>
          <BarButton
            icon="refresh"
            label="探测状态"
            onClick={() => {
              haptic("tap");
              toast("正在逐台探测…");
              probeAccounts()
                .then((a) => {
                  setList(a);
                  toast(`${a.filter((x) => x.status === "ok").length}/${a.length} 台正常`, "ok");
                })
                .catch((e) => toast(String(e), "bad"));
            }}
          />
          <BarButton icon="plus" label="添加服务器" onClick={() => go("addServer")} />
        </>
      }
      enterKey={list}
    >
      {err ? (
        <Empty icon="server" title="取不到服务器列表" desc={err} />
      ) : list === null ? (
        <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
      ) : !list.length ? (
        <Empty
          icon="server"
          title="一台服务器都还没有"
          desc="加一台 Emby,或者接一个网盘 —— 两种都从下面这个按钮进。"
          action={{ label: "添加服务器", on: () => go("addServer") }}
        />
      ) : (
        <div className="cells">
          {list.map((sv, i) => (
            <SrvRow
              key={sv.server}
              sv={sv}
              i={i}
              icon={icons[sv.server]}
              onMenu={(x, y) => openMenu(sv, x, y)}
              onTap={() => {
                /* 点文件浏览型的源 = 进它的浏览页。
                   ★ 这行原本是 `if (sv.active) return;` —— 已经是「当前」的那台再点就什么都不做。
                     对 Emby 没问题(它的内容摊在首页/媒体库里),但网盘 / 插件源的浏览页是**另一个
                     路由**,而手机端到那个路由的唯一另一条路是「设置 → 网盘文件」,设置的入口又是
                     首页右上角的齿轮 —— 没有 Emby 会话时首页整个换成空状态,齿轮跟着没了。
                     结果:只登录网盘 / 插件源的用户,浏览页一辈子进不去。PC 端的服务器页一直是点了
                     就进(onEnter),这里对齐它。 */
                const page = browsePageOf(sv.source_kind);
                if (sv.active) {
                  if (page) {
                    haptic("tap");
                    go(page);
                  }
                  return;
                }
                haptic("tap");
                setActiveServer(sv.server)
                  .then(() => {
                    toast(`已切到 ${sv.name}`, "ok");
                    reloadGate();
                    load();
                    // 放在最后:reloadGate 会重算登录闸口,先跳会被它顶回去。
                    if (page) go(page);
                  })
                  .catch((e) => toast(String(e), "bad"));
              }}
            />
          ))}
        </div>
      )}

      {sheet?.kind === "edit" && (
        <EditSheet
          sv={sheet.sv}
          onClose={() => setSheet(null)}
          onDone={() => {
            setSheet(null);
            reloadGate();
            load();
          }}
        />
      )}
      {sheet?.kind === "relogin" && (
        <ReloginSheet
          sv={sheet.sv}
          onClose={() => setSheet(null)}
          onDone={() => {
            setSheet(null);
            reloadGate();
            load();
          }}
        />
      )}
      {sheet?.kind === "remark" && (
        <RemarkSheet
          sv={sheet.sv}
          onClose={() => setSheet(null)}
          onDone={() => {
            setSheet(null);
            load();
          }}
        />
      )}
      {sheet?.kind === "del" && (
        <Sheet open onClose={() => setSheet(null)} title={`删除「${sheet.sv.name}」?`}>
          <div className="pad">
            <p className="dim" style={{ fontSize: 13.5, margin: 0 }}>
              只从这台设备上移除,服务器本身和上面的内容都不受影响。下载好的视频也还在。
            </p>
          </div>
          <div className="sheet-acts">
            <button type="button" className="btn ghost" onClick={() => setSheet(null)}>
              取消
            </button>
            <button
              type="button"
              className="btn danger"
              onClick={() => {
                const id = sheet.sv.server;
                setSheet(null);
                removeAccount(id)
                  .then(() => {
                    haptic("ok");
                    toast("已删除", "ok");
                    reloadGate();
                    load();
                  })
                  .catch((e) => toast(String(e), "bad"));
              }}
            >
              删除
            </button>
          </div>
        </Sheet>
      )}
    </Page>
  );
}

function SrvRow({
  sv,
  i,
  icon,
  onMenu,
  onTap,
}: {
  sv: AccountInfo;
  i: number;
  icon?: string;
  onMenu: (x: number, y: number) => void;
  onTap: () => void;
}) {
  const timer = { t: 0 as ReturnType<typeof setTimeout> | 0 };
  const fired = { v: false };
  const st = ST[sv.status] ?? ST.unknown;
  return (
    <button
      type="button"
      className="lit"
      style={{ ["--i" as string]: i }}
      onPointerDown={(e) => {
        fired.v = false;
        const x = e.clientX;
        const y = e.clientY;
        timer.t = setTimeout(() => {
          fired.v = true;
          haptic("sel");
          onMenu(x, y);
        }, 480);
      }}
      onPointerUp={() => timer.t && clearTimeout(timer.t)}
      onPointerCancel={() => timer.t && clearTimeout(timer.t)}
      onPointerMove={() => timer.t && clearTimeout(timer.t)}
      onClick={() => {
        if (fired.v) return; // 刚才是长按,别再切服务器
        onTap();
      }}
    >
      <span className="lit-ic">
        {icon ? (
          <img className="srv-ic-img" src={icon} alt="" />
        ) : isGlyph(sv.icon_url) ? (
          <span className="srv-gly">{sv.icon_url}</span>
        ) : (
          <Icon n={KIND_IC[sv.source_kind] || "server"} size={18} />
        )}
      </span>
      <span className="lit-t">
        <div className="lit-n">
          {sv.name}
          {sv.active && (
            <b className="tag acc" style={{ marginLeft: 6 }}>
              当前
            </b>
          )}
        </div>
        <div className="lit-s">
          {/* ★ 备注优先,没有备注就写源类型 —— **绝不回落到地址**。
              上一版是 `sv.remark || sv.line_url || sv.server`,于是没写备注的人
              一屏全是域名。地址是凭据的一部分,截图/投屏/录屏都会把它带出去。 */}
          {sv.remark || KIND_NAME[sv.source_kind] || ((sv.source_kind ?? "").startsWith("plugin:") ? "插件源" : "服务器")}
          {sv.lines.length > 1 ? ` · ${sv.lines.length} 条线路` : ""}
        </div>
      </span>
      <span className={`dot ${st.cls}`} title={st.text} />
    </button>
  );
}

/* ---------- 编辑信息 ---------- */

function EditSheet({ sv, onClose, onDone }: { sv: AccountInfo; onClose: () => void; onDone: () => void }) {
  const [name, setName] = useState(sv.name);
  const [user, setUser] = useState(sv.user_name);
  const [pass, setPass] = useState("");
  const [tls, setTls] = useState(sv.allow_insecure_tls);
  const [busy, setBusy] = useState(false);
  const userChanged = user.trim() !== sv.user_name;

  return (
    <Sheet open onClose={onClose} title="编辑服务器信息" snap>
      <div className="pad">
        {/* ★ 名称必填,排第一行。列表里认服务器靠的就是它;
            「留空就用地址里的域名」等于默许一屏全是域名。 */}
        <Field label="服务器名称" placeholder="列表里就靠这个名字认它" value={name} onChange={setName} required />
        <Field label="用户名" placeholder="账号" value={user} onChange={setUser} />
        <Field label="密码" type="password" placeholder={userChanged ? "换账号必须填" : "不改就留空"} value={pass} onChange={setPass} />
        {userChanged && !pass && <div className="f-warn">换了账号就必须填密码,否则换不了。</div>}
        <label className="crow" style={{ marginTop: 4 }}>
          <div className="crow-h">
            <div className="crow-t">
              <div>信任自签名证书</div>
              <div className="crow-s">只对这台服务器放行,不影响其它主机。自签名证书才需要开。</div>
            </div>
            <span className={`sw${tls ? " on" : ""}`} onClick={() => setTls((v) => !v)}>
              <i />
            </span>
          </div>
        </label>
        {/* 地址不在这儿改 —— 改地址等于换一台服务器,那条路是「线路管理」。 */}
        <p className="f-note">要改地址请用「服务器线路」——在这里改地址等于换一台服务器。</p>
      </div>
      <div className="sheet-acts">
        <button type="button" className="btn ghost" onClick={onClose}>
          取消
        </button>
        <button
          type="button"
          className="btn primary"
          disabled={busy}
          onClick={async () => {
            if (!name.trim()) {
              haptic("err");
              return toast("服务器名称不能空", "bad");
            }
            if (userChanged && !pass) {
              haptic("err");
              return toast("换账号必须填密码", "bad");
            }
            setBusy(true);
            try {
              /* ★ 顺序不能反:先换凭据(会真登一次),再落名称/TLS。
                 反了的话 relogin 写的记录会被 updateAccount 整个覆盖。 */
              if (userChanged || pass) await relogin(sv.server, user.trim(), pass);
              await updateAccount(sv.server, { name: name.trim(), allowInsecureTls: tls });
              haptic("ok");
              toast("已保存", "ok");
              onDone();
            } catch (e) {
              toast(String(e), "bad");
            } finally {
              setBusy(false);
            }
          }}
        >
          {busy ? "保存中…" : "保存"}
        </button>
      </div>
    </Sheet>
  );
}

/* ---------- 重新登录 ----------
   ★ 这是 PC 的残缺补齐处:PC 的 ReloginDialog 写死账密两字段,
     扫码型源(阿里/夸克/百度)在 PC 的服务器页**根本没法重登**。 */

function ReloginSheet({ sv, onClose, onDone }: { sv: AccountInfo; onClose: () => void; onDone: () => void }) {
  const [f, setF] = useState<FormState>(() => ({ ...emptyForm(), name: sv.name, url: sv.server, user: sv.user_name }));
  const [busy, setBusy] = useState(false);
  const set = (p: Partial<FormState>) => setF((s) => ({ ...s, ...p }));
  const isQr = KIND_QR.has(sv.source_kind);

  return (
    <Sheet open onClose={onClose} title="重新登录" snap>
      <div className="pad">
        <p className="f-note">
          {isQr
            ? "扫码型源的凭据过期了只能重新扫一次。扫完就生效,不用点下面的按钮。"
            : "只换这台服务器的登录凭据,名称、备注、线路、图标都保留。"}
        </p>
        {KIND_UP.has(sv.source_kind) ? (
          <>
            <Field label="用户名" placeholder="账号" value={f.user} onChange={(v) => set({ user: v })} required reqKey="user" />
            <Field label="密码" type="password" placeholder="密码" value={f.pass} onChange={(v) => set({ pass: v })} required reqKey="pass" />
          </>
        ) : (
          <SourceForm kind={sv.source_kind} f={f} set={set} />
        )}
      </div>
      {!isQr && (
        <div className="sheet-acts">
          <button type="button" className="btn ghost" onClick={onClose}>
            取消
          </button>
          <button
            type="button"
            className="btn primary"
            disabled={busy}
            onClick={async () => {
              if (!f.user.trim() || !f.pass) {
                haptic("err");
                return toast("账号和密码都要填", "bad");
              }
              setBusy(true);
              try {
                /* ★ 用 relogin 不用 login —— login 按「登录时用的地址」upsert,
                   会凭空多出一台服务器;relogin 才是原地换 token。 */
                await relogin(sv.server, f.user.trim(), f.pass);
                haptic("ok");
                toast("已重新登录", "ok");
                onDone();
              } catch (e) {
                toast(String(e), "bad");
              } finally {
                setBusy(false);
              }
            }}
          >
            {busy ? "登录中…" : "重新登录"}
          </button>
        </div>
      )}
    </Sheet>
  );
}

/* ---------- 修改备注 ---------- */

function RemarkSheet({ sv, onClose, onDone }: { sv: AccountInfo; onClose: () => void; onDone: () => void }) {
  const [v, setV] = useState(sv.remark ?? "");
  const ok = usePress<HTMLButtonElement>();
  return (
    <Sheet open onClose={onClose} title="修改备注">
      <div className="pad">
        <Field label="备注" placeholder="比如「群晖上那台,只有内网能连」" value={v} onChange={setV} />
        <p className="f-note">备注显示在列表第二行。留空就显示源的类型 —— 地址在任何列表里都不显示。</p>
      </div>
      <div className="sheet-acts">
        <button type="button" className="btn ghost" onClick={onClose}>
          取消
        </button>
        <button
          type="button"
          className="btn primary"
          ref={ok}
          onClick={() => {
            /* ★ 备注**恒传**(允许清空)—— 核层的语义是"不传的字段不动、传空串才是清空"。 */
            updateAccount(sv.server, { remark: v })
              .then(() => {
                haptic("ok");
                toast("已保存", "ok");
                onDone();
              })
              .catch((e) => toast(String(e), "bad"));
          }}
        >
          保存
        </button>
      </div>
    </Sheet>
  );
}
