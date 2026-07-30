import { useEffect, useRef, useState, type ReactNode } from "react";
import {
  type ParsedServerBlock,
  type SourceKind,
  batchAddServers,
  batchParse,
  currentSource,
  login,
  sourceLogin,
  sourcePasswordLogin,
  sourceQrPoll,
  sourceQrStart,
  updateAccount,
} from "@shared/api";
import { Icon } from "../app/icons";
import { haptic, toast } from "../app/motion";
import { usePress } from "./ui";

/* 添加服务器 / 首登闸口 / 重新登录 —— **三处共用这一份**。
   抄两份的下场是新增源类型时改一处漏一处,而两边都不报错。

   ## SourceKind 是 Rust 侧的封闭集,**全小写**
   前端曾经整套写成首字母大写(`Aliyun` / `P115`),结果每一处比较恒 false、
   登录送错值,**两边都不报错**。下面这些字面量必须和 crates/core 的 SourceKind 一致。
   Jellyfin **不是**独立 kind(和 emby 共用一套接口)。 */

export const KIND_UP = new Set<string>(["emby", "feiniu", "openlist", "anirss"]);
export const KIND_QR = new Set<string>(["aliyundrive", "quark", "baidu"]);
export const KIND_COOKIE = new Set<string>(["pan115"]);
export const KIND_PHONE = new Set<string>(["pan189", "pan139"]);

export type SrcKindDef = { id: string; name: string; desc: string; sec: string };

/** 源类型清单。**新增源只改这一处**(添加页和首登闸口共用)。 */
export const SOURCE_KINDS: SrcKindDef[] = [
  { id: "emby", name: "Emby / Jellyfin", desc: "地址 + 账号密码", sec: "媒体服务器" },
  { id: "feiniu", name: "飞牛影视", desc: "地址 + 账号密码", sec: "媒体服务器" },
  { id: "openlist", name: "OpenList", desc: "地址 + 账号密码", sec: "网盘 / 文件源" },
  { id: "aliyundrive", name: "阿里云盘", desc: "扫码登录", sec: "网盘 / 文件源" },
  { id: "quark", name: "夸克网盘", desc: "扫码登录", sec: "网盘 / 文件源" },
  { id: "baidu", name: "百度网盘", desc: "扫码登录", sec: "网盘 / 文件源" },
  { id: "pan115", name: "115 网盘", desc: "粘贴 Cookie", sec: "网盘 / 文件源" },
  { id: "pan189", name: "天翼云盘", desc: "短信 / 密码", sec: "网盘 / 文件源" },
  { id: "pan139", name: "移动云盘", desc: "短信 / 密码", sec: "网盘 / 文件源" },
  { id: "anirss", name: "Ani-RSS", desc: "地址 + 账号密码", sec: "网盘 / 文件源" },
  { id: "stremio", name: "Stremio", desc: "Addon manifest 地址", sec: "插件协议" },
  { id: "batch", name: "批量粘贴导入", desc: "一次贴多台", sec: "批量" },
  { id: "qrsync", name: "扫码搬配置", desc: "从另一台设备搬过来", sec: "批量" },
];

const SRC_IC: Record<string, string> = {
  emby: "server", feiniu: "server", stremio: "plugin", anirss: "rss",
  openlist: "cloud", aliyundrive: "cloud", quark: "cloud", baidu: "cloud",
  pan115: "cloud", pan189: "cloud", pan139: "cloud",
  batch: "list", qrsync: "qr",
};

/* ============================================================
   必填字段
   ★ 校验统一读 `[data-req]`,别在每个页面各写一套"哪个框不能空"。
   ★ 校验必须在**发请求之前**跑。等服务端回来才说"名字没填"是白等一趟网络。
   ============================================================ */

export function Field({
  label,
  type = "text",
  placeholder,
  value,
  onChange,
  required,
  reqKey = "name",
  area,
}: {
  label: string;
  type?: string;
  placeholder?: string;
  value: string;
  onChange: (v: string) => void;
  required?: boolean;
  reqKey?: string;
  area?: boolean;
}) {
  const [bad, setBad] = useState(false);
  useEffect(() => {
    if (value.trim()) setBad(false);
  }, [value]);
  return (
    <label className={`field${required ? " req" : ""}${bad ? " bad" : ""}`}>
      <span>
        {label}
        {required && <i className="req-star"> *</i>}
      </span>
      {area ? (
        <textarea
          placeholder={placeholder}
          rows={4}
          value={value}
          data-req={required ? reqKey : undefined}
          onChange={(e) => onChange(e.target.value)}
        />
      ) : (
        <input
          type={type}
          placeholder={placeholder}
          value={value}
          data-req={required ? reqKey : undefined}
          onChange={(e) => onChange(e.target.value)}
        />
      )}
    </label>
  );
}

/** 扫一遍容器里的必填框,空的标红并把第一个空的报出来。返回是否全部填了。 */
export function checkRequired(root: HTMLElement | null): boolean {
  if (!root) return true;
  const all = [...root.querySelectorAll<HTMLInputElement | HTMLTextAreaElement>("[data-req]")];
  const miss = all.filter((i) => !i.value.trim());
  all.forEach((i) => i.closest(".field")?.classList.toggle("bad", !i.value.trim()));
  if (miss.length) {
    haptic("err");
    const label = miss[0].closest(".field")?.querySelector("span")?.textContent?.replace(" *", "") ?? "必填项";
    toast(`${label}不能空`, "bad");
    miss[0].focus();
  }
  return miss.length === 0;
}

/* ============================================================
   源类型选择器 —— 按 sec 分组铺网格,首屏一眼看完 13 种。
   ★ 不用横滑 chip:13 个 chip 要滑三屏,滑到一半根本不知道后面还有没有。
   ============================================================ */

export function SrcPicker({
  cur,
  onPick,
  exclude = [],
}: {
  cur: string;
  onPick: (id: string) => void;
  exclude?: string[];
}) {
  const secs: { name: string; items: SrcKindDef[] }[] = [];
  for (const k of SOURCE_KINDS) {
    if (exclude.includes(k.id)) continue;
    const s = secs.find((x) => x.name === k.sec) ?? (secs.push({ name: k.sec, items: [] }), secs[secs.length - 1]);
    s.items.push(k);
  }
  return (
    <div>
      {secs.map((s) => (
        <div key={s.name}>
          <div className="src-sec">{s.name}</div>
          <div className="src-grid">
            {s.items.map((k) => (
              <button
                key={k.id}
                type="button"
                className={`src-it${k.id === cur ? " on" : ""}`}
                data-kind={k.id}
                onClick={() => {
                  if (k.id === cur) return;
                  haptic("sel");
                  onPick(k.id);
                }}
              >
                <Icon n={SRC_IC[k.id] || "server"} size={20} />
                <div className="src-n">{k.name}</div>
              </button>
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}

/* ============================================================
   表单本体
   ============================================================ */

export type FormState = {
  /** 服务器名称 —— **所有源类型都要,而且必填**。
   *  列表里认服务器靠的就是这个名字;不给名字的话六台里有三台都叫「未命名」或者一串域名,
   *  长按菜单点错的代价是删错服务器。
   *  ★ 它排在**表单第一行**:扫码型的用户扫完就跳走了,放后面等于没有。 */
  name: string;
  url: string;
  user: string;
  pass: string;
  cookie: string;
  phone: string;
  code: string;
};

export const emptyForm = (): FormState => ({ name: "", url: "", user: "", pass: "", cookie: "", phone: "", code: "" });

export function SourceForm({
  kind,
  f,
  set,
  /** 编辑已有服务器时不画名称字段之外的东西 */
  children,
}: {
  kind: string;
  f: FormState;
  set: (patch: Partial<FormState>) => void;
  children?: ReactNode;
}) {
  const nameField = (
    <Field
      label="服务器名称"
      placeholder="给它起个名,比如「家里的 Emby」"
      value={f.name}
      onChange={(v) => set({ name: v })}
      required
    />
  );

  if (KIND_UP.has(kind)) {
    return (
      <div>
        {nameField}
        <Field label="服务器地址" type="url" placeholder="https://example.com:8920" value={f.url} onChange={(v) => set({ url: v })} required reqKey="url" />
        <Field label="用户名" placeholder="账号" value={f.user} onChange={(v) => set({ user: v })} />
        <Field label="密码" type="password" placeholder="密码" value={f.pass} onChange={(v) => set({ pass: v })} />
        {children}
      </div>
    );
  }
  if (KIND_QR.has(kind)) {
    return (
      <div>
        {nameField}
        <QrPane kind={kind} name={f.name} />
      </div>
    );
  }
  if (KIND_COOKIE.has(kind)) {
    return (
      <div>
        {nameField}
        <Field
          label="Cookie"
          area
          placeholder="从浏览器网络请求里复制完整 Cookie 粘贴到这里"
          value={f.cookie}
          onChange={(v) => set({ cookie: v })}
          required
          reqKey="cookie"
        />
      </div>
    );
  }
  if (KIND_PHONE.has(kind)) {
    return (
      <div>
        {nameField}
        <PhonePane kind={kind} f={f} set={set} />
      </div>
    );
  }
  if (kind === "batch") return <BatchPane />;
  if (kind === "qrsync") return <QrSyncPane />;

  // stremio 及将来新源类型的兜底:名称 + 一个地址
  return (
    <div>
      {nameField}
      <Field
        label="Addon 地址"
        type="url"
        placeholder="https://v3-cinemeta.strem.io/manifest.json"
        value={f.url}
        onChange={(v) => set({ url: v })}
        required
        reqKey="url"
      />
    </div>
  );
}

/* ---------- 扫码型(阿里 / 夸克 / 百度) ---------- */
function QrPane({ kind, name }: { kind: string; name: string }) {
  const [qr, setQr] = useState<{ image: string; ctx: string } | null>(null);
  const [state, setState] = useState<"loading" | "pending" | "expired" | "done" | "error">("loading");
  const [err, setErr] = useState("");
  const nameRef = useRef(name);
  nameRef.current = name;

  const start = () => {
    setState("loading");
    setErr("");
    sourceQrStart(kind)
      .then((r) => {
        setQr(r);
        setState("pending");
      })
      .catch((e) => {
        setErr(String(e));
        setState("error");
      });
  };
  useEffect(start, [kind]);

  /* 轮询。★ 2 秒一次,不是 500ms —— 扫码是人的动作,轮询再密也快不过手速,
     只是白耗流量和电。过期就停,不要无限打。 */
  useEffect(() => {
    if (state !== "pending" || !qr) return;
    let alive = true;
    const t = setInterval(async () => {
      try {
        const r = await sourceQrPoll(kind, qr.ctx);
        if (!alive) return;
        if (r.state === "expired") {
          setState("expired");
          clearInterval(t);
        } else if (r.state === "confirmed") {
          setState("done");
          clearInterval(t);
          /* ★ 扫码确认后拿到的 credentials 要**原样**塞进 sourceLogin 的 extra 落库,
             别自己拆开重组 —— 各家的字段名不一样,拆错就是"扫了但没登上"。 */
          await sourceLogin(kind, "", "", "", null, r.credentials).catch((e) => toast(String(e), "bad"));
          /* ★ 扫码型同样要补名字。`nameRef` 一直存在却没人用过 ——
             表现和账密型一样:名称填了、进去显示的是地址。 */
          await nameIt(nameRef.current);
          toast("已添加", "ok");
        }
      } catch {
        /* 单次轮询失败不改状态 —— 网络抖一下不该让二维码作废 */
      }
    }, 2000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [state, qr, kind]);

  return (
    <>
      <div className="qr">
        {state === "loading" && <div className="dim" style={{ padding: 40, fontSize: 13 }}>正在取二维码…</div>}
        {qr && state !== "loading" && state !== "error" && (
          <img src={qr.image} alt="登录二维码" style={{ width: "100%", display: "block" }} />
        )}
        {state === "error" && <div className="dim" style={{ padding: 24, fontSize: 13 }}>{err}</div>}
      </div>
      <p className="dim" style={{ textAlign: "center", fontSize: 13, marginTop: 12 }}>
        {state === "pending" && "打开对应 App 扫一扫登录"}
        {state === "expired" && "二维码已过期"}
        {state === "done" && "已确认,正在写入…"}
        {state === "error" && "取码失败"}
      </p>
      {(state === "expired" || state === "error") && (
        <button type="button" className="btn" style={{ margin: "10px auto", display: "block" }} onClick={start}>
          换一张
        </button>
      )}
    </>
  );
}

/* ---------- 手机号型(天翼 / 移动云盘):短信 ⇄ 密码 ---------- */
/* ★ `kind` 暂时用不上：短信下发是各家不同的端点，核层还没提到命令层；
   密码登录那条路（source_password_login）对 pan189 / pan139 是同一个命令。
   接出短信命令后这里要拿 kind 分流，所以形参留着。 */
function PhonePane({ f, set }: { kind: string; f: FormState; set: (p: Partial<FormState>) => void }) {
  const [mode, setMode] = useState<"sms" | "pwd">("sms");
  const [sent, setSent] = useState(0);

  useEffect(() => {
    if (!sent) return;
    const t = setInterval(() => setSent((v) => (v <= 1 ? 0 : v - 1)), 1000);
    return () => clearInterval(t);
  }, [sent]);

  if (mode === "pwd") {
    return (
      <div>
        <Field label="手机号" type="tel" placeholder="手机号" value={f.phone} onChange={(v) => set({ phone: v })} required reqKey="phone" />
        <Field label="密码" type="password" placeholder="密码" value={f.pass} onChange={(v) => set({ pass: v })} required reqKey="pass" />
        <button type="button" className="linklike" onClick={() => setMode("sms")}>
          改用短信登录
        </button>
      </div>
    );
  }
  return (
    <div>
      <Field label="手机号" type="tel" placeholder="手机号" value={f.phone} onChange={(v) => set({ phone: v })} required reqKey="phone" />
      <div className="field-row">
        <Field label="验证码" type="tel" placeholder="6 位验证码" value={f.code} onChange={(v) => set({ code: v })} required reqKey="code" />
        <button
          type="button"
          className="btn"
          disabled={sent > 0 || !f.phone.trim()}
          onClick={() => {
            haptic("tap");
            /* 核层目前只暴露了 source_password_login;短信下发是各家不同的端点,
               还没提到命令层。★ 这里**不假装**发得出去 —— 说清楚,并给出可用的那条路。 */
            toast("短信验证码这条路核层还没接出命令,先用「改用密码登录」", "warn");
            setSent(60);
          }}
        >
          {sent ? `${sent}s` : "发送验证码"}
        </button>
      </div>
      <button type="button" className="linklike" onClick={() => setMode("pwd")}>
        改用密码登录
      </button>
    </div>
  );
}

/* ---------- 批量粘贴 ----------
   PC 是「先解析 → 核对表 → 兜底凭据 → 提交」三步。
   手机屏放不下三步并列,改成解析完就地长出核对表。 */
function BatchPane() {
  const [text, setText] = useState("");
  const [blocks, setBlocks] = useState<ParsedServerBlock[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [fbUser, setFbUser] = useState("");
  const [fbPass, setFbPass] = useState("");

  const noCred = (blocks ?? []).filter((b) => !b.username || !b.password).length;

  return (
    <div>
      <Field
        label="粘贴服务器信息"
        area
        placeholder={"支持一次贴多台,常见的分享格式都能认:\n地址 账号 密码\n每台一行或用空行隔开"}
        value={text}
        onChange={setText}
      />
      <button
        type="button"
        className="btn"
        disabled={busy || !text.trim()}
        onClick={() => {
          haptic("tap");
          setBusy(true);
          batchParse(text)
            .then((b) => {
              setBlocks(b);
              haptic(b.length ? "ok" : "err");
              if (!b.length) toast("一台都没解析出来 —— 检查格式", "warn");
            })
            .catch((e) => toast(String(e), "bad"))
            .finally(() => setBusy(false));
        }}
      >
        {busy ? "解析中…" : blocks ? "重新解析" : "解析"}
      </button>

      {blocks && blocks.length > 0 && (
        <div>
          <div className="f-note" style={{ padding: "10px 0 4px" }}>
            解析出 {blocks.length} 台,核对无误后点下面的「连接」一次全加进来:
          </div>
          {blocks.map((b, i) => (
            <div className="lit" key={i}>
              <span className="lit-ic">
                <Icon n="server" size={18} />
              </span>
              <span className="lit-t">
                <div className="lit-n">
                  <b>{b.lines[0]?.name || b.lines[0]?.url || `第 ${i + 1} 台`}</b>
                </div>
                <div className="lit-s">
                  {b.lines[0]?.url} · {b.username || "(没解析出账号)"}
                </div>
              </span>
            </div>
          ))}
          {noCred > 0 && (
            <>
              <div className="f-warn">有 {noCred} 台没解析出账号密码,会用下面填的兜底凭据去登。</div>
              <Field label="兜底账号(可留空)" placeholder="解析不出账号时用这个" value={fbUser} onChange={setFbUser} />
              <Field label="兜底密码(可留空)" type="password" placeholder="解析不出密码时用这个" value={fbPass} onChange={setFbPass} />
            </>
          )}
          <button
            type="button"
            className="btn primary"
            style={{ marginTop: 12 }}
            onClick={() => {
              haptic("tap");
              batchAddServers(blocks, fbUser || null, fbPass || null, null)
                .then((rs) => {
                  const ok = rs.filter((r) => !r.error).length;
                  const bad = rs.filter((r) => r.error);
                  toast(bad.length ? `成功 ${ok} 台,失败 ${bad.length} 台:${bad[0].error}` : `已加 ${ok} 台`, bad.length ? "warn" : "ok");
                })
                .catch((e) => toast(String(e), "bad"));
            }}
          >
            全部添加
          </button>
        </div>
      )}
    </div>
  );
}

/* ---------- 扫码搬配置 ----------
   手机有摄像头,这是手机端比 PC 强的地方 —— PC 只能粘文本载荷。 */
function QrSyncPane() {
  const [payload, setPayload] = useState("");
  const scan = usePress<HTMLButtonElement>();
  return (
    <div>
      <p className="f-note">
        在另一台已经配好的设备上打开「设置 → 关于 → 导出本机配置」,然后扫它出的二维码,
        服务器和登录状态一次全搬过来。
      </p>
      <button
        type="button"
        className="btn primary"
        ref={scan}
        onClick={() => {
          haptic("tap");
          /* 摄像头扫码要宿主提供相机权限 + 一个解码器,那是宿主侧的活。
             ★ **不假装**已经做了 —— 说清楚,并把可用的那条路(粘贴载荷)放在下面。 */
          toast("摄像头扫码还要宿主接相机权限,先用下面的粘贴载荷", "warn");
        }}
      >
        打开摄像头扫码
      </button>
      <p className="f-note" style={{ marginTop: 14 }}>
        扫不了码?直接粘贴文本载荷:
      </p>
      <Field label="配置载荷" area placeholder="LPSYNC1:…" value={payload} onChange={setPayload} />
    </div>
  );
}

/* ============================================================
   提交
   ★ 顺序:先校验(本地,零成本)→ 再发请求。
   ============================================================ */

/** 把用户填的「服务器名称」落库。
 *
 *  ★ **核层的 login / source_login 都不收 name**(确实如此,不是漏传参数),
 *    所以名字只能加完之后补一刀 `update_account`。少了这一刀的表现是:
 *    表单上名称还标着必填星号、也确实填了,进首页/聚合视界看到的却是
 *    `display_name()` 的回落值 —— 服务器的 **host**。用户会以为"显示的是线路名"。
 *    PC 端(desktop/pages/sources/sourceForms.tsx)一直是补这一刀的,手机端漏了。
 *
 *  ★ `source_login` 的返回是 `()`,拿不到账号键 —— 登录成功后它就是**当前活跃源**,
 *    回读 `current_source` 拿键。这条和 PC 端同一个写法。
 *
 *  ★ 改名失败**不能**把"已经加成功"变成"报错了":名字没写上顶多显示成地址。 */
async function nameIt(name: string, serverId?: string): Promise<void> {
  const nm = name.trim();
  if (!nm) return;
  try {
    const key = serverId ?? (await currentSource())?.server;
    if (key) await updateAccount(key, { name: nm });
  } catch {
    /* 名字没落上不影响源已经加成功 */
  }
}

export async function submitSource(kind: string, f: FormState): Promise<void> {
  if (KIND_UP.has(kind)) {
    if (kind === "emby") {
      const res = await login(f.url.trim(), f.user.trim(), f.pass);
      await nameIt(f.name, res.server);
      return;
    }
    await sourceLogin(kind as SourceKind, f.url.trim(), f.user.trim(), f.pass, null, null);
    await nameIt(f.name);
    return;
  }
  if (KIND_COOKIE.has(kind)) {
    await sourceLogin(kind as SourceKind, "", "", "", f.cookie.trim(), null);
    await nameIt(f.name);
    return;
  }
  if (KIND_PHONE.has(kind)) {
    const cred = await sourcePasswordLogin(kind, f.phone.trim(), f.pass);
    await sourceLogin(kind as SourceKind, "", f.phone.trim(), "", null, cred);
    await nameIt(f.name);
    return;
  }
  if (KIND_QR.has(kind)) {
    // 扫码型在 QrPane 里自己完成了 —— 这里点「连接」不该再发一次
    throw new Error("扫码登录请直接用上面的二维码");
  }
  // stremio 及兜底
  await sourceLogin(kind as SourceKind, f.url.trim(), "", "", null, null);
  await nameIt(f.name);
}
