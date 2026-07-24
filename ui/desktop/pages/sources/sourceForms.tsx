import { useCallback, useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import QRCode from "qrcode";
import { listen } from "@tauri-apps/api/event";
import {
  type BatchAddResult,
  type ParsedServerBlock,
  type PluginDataSource,
  type ServerInfo,
  batchAddServers,
  batchParse,
  configExportQr,
  configImportQr,
  currentSource,
  login,
  parseDeepLink,
  pluginDataSources,
  quarkScanPoll,
  quarkScanStart,
  sourceLogin,
  sourcePasswordLogin,
  sourceQrPoll,
  sourceQrStart,
  startupDeepLink,
  testConnection,
  updateAccount,
} from "@shared/api";
import { IconCloud, IconFile, IconPlugin, IconServer } from "../../app/icons";

/* ============================================================
   数据源表单的**唯一实现**。两个页面共用:
     - 添加服务器页(主从两栏,左 nav 选源)
     - 首次登录闸口(居中卡片,顶部芯片选源)

   ★ 为什么必须共用而不是各写一份:
     这个仓库的高发病就是「两处只改一处」—— 新增一个源类型时改了添加页、
     漏了登录页,新用户就永远看不到那个源,而且**两边都不会报错**。
     所以状态、提交逻辑、字段渲染全部收在这个 hook 里,页面只负责摆版式:
     选源用什么控件(nav / 芯片)、按钮叫什么名字、放在哪儿,由各页自己决定。

   本文件是从 AddServerPage.tsx 原样搬过来的(逻辑一行没改),只把
   「标题/字段/主按钮」拆成三个可分别调用的渲染函数,好让登录闸口
   跳过标题、自己摆按钮。
   ============================================================ */

export type SourceId =
  | "emby"
  | "openlist"
  | "quark"
  | "feiniu"
  | "anirss"
  | "stremio"
  | "aliyundrive"
  | "baidu"
  | "pan115"
  | "pan189"
  | "pan139"
  | "batch"
  | "qrsync"
  /** 插件贡献的源:`plugin:<插件id>/<源id>`,直接就是 SourceKind。 */
  | (string & {});


/* Stremio 配置框的默认内容。预填官方 Cinemeta —— 它是免费的元数据 addon,
   不填任何东西根目录就是空的,新用户会以为源坏了。用户想换随时删掉重写。
   ★ 只预填元数据 addon,不预置任何播放源 addon —— 装什么播放源是用户自己的事。 */
const STREMIO_DEFAULT = "https://v3-cinemeta.strem.io/manifest.json\n";

/* ★ api.ts 里的 ParsedServerBlock 类型与 Rust 侧 server_batch::ParsedServerBlock **对不上**
   (那边写的是 name/urls/remark,核层实际是 username/password/lines/danmaku_lines)。
   api.ts 非本页所有,不擅改;这里按核层真实结构声明,过 invoke 时窄转。
   块本身原样从 batch_parse 拿、原样喂 batch_add_servers,不在前端重组,故运行时安全。 */
type ParsedLine = { name: string; url: string };
export type Block = {
  username: string | null;
  password: string | null;
  lines: ParsedLine[];
  danmaku_lines: ParsedLine[];
};
const asBlocks = (b: ParsedServerBlock[]) => b as unknown as Block[];
const asApi = (b: Block[]) => b as unknown as ParsedServerBlock[];

/* 扫码图标 icons 里没有,内联描边(currentColor,无 emoji)。 */
export const IconQr = ({ size = 18 }: { size?: number }) => (
  <svg
    width={size}
    height={size}
    viewBox="0 0 24 24"
    fill="none"
    stroke="currentColor"
    strokeWidth={1.7}
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden
  >
    <rect x="3" y="3" width="7" height="7" rx="1" />
    <rect x="14" y="3" width="7" height="7" rx="1" />
    <rect x="3" y="14" width="7" height="7" rx="1" />
    <path d="M14 14h3v3M20 14v.01M14 20h.01M17 20h.01M20 17v4" />
  </svg>
);

/** 一个源在选择器里的样子。页面各自决定画成 nav 条目还是芯片。 */
export type SourceMeta = { id: SourceId; label: string; sec: string; icon: () => ReactNode };

/** 内置源。**新增源类型只需要往这里加一条,两个页面同时生效** —— 这正是共用的意义。 */
export const BUILTIN_SOURCES: SourceMeta[] = [
  { id: "emby", label: "Emby / Jellyfin", sec: "媒体服务器", icon: () => <IconServer size={16} /> },
  { id: "openlist", label: "OpenList", sec: "网盘 / 文件源", icon: () => <IconCloud size={16} /> },
  { id: "quark", label: "夸克网盘", sec: "网盘 / 文件源", icon: () => <IconCloud size={16} /> },
  { id: "feiniu", label: "飞牛影视", sec: "网盘 / 文件源", icon: () => <IconCloud size={16} /> },
  { id: "anirss", label: "Ani-RSS", sec: "网盘 / 文件源", icon: () => <IconCloud size={16} /> },
  { id: "aliyundrive", label: "阿里云盘", sec: "网盘 / 文件源", icon: () => <IconCloud size={16} /> },
  { id: "baidu", label: "百度网盘", sec: "网盘 / 文件源", icon: () => <IconCloud size={16} /> },
  { id: "pan115", label: "115 网盘", sec: "网盘 / 文件源", icon: () => <IconCloud size={16} /> },
  { id: "pan189", label: "天翼云盘", sec: "网盘 / 文件源", icon: () => <IconCloud size={16} /> },
  { id: "pan139", label: "移动云盘", sec: "网盘 / 文件源", icon: () => <IconCloud size={16} /> },
  { id: "stremio", label: "Stremio", sec: "插件协议", icon: () => <IconServer size={16} /> },
  { id: "batch", label: "批量粘贴导入", sec: "批量", icon: () => <IconFile size={16} /> },
  { id: "qrsync", label: "扫码搬配置", sec: "批量", icon: () => <IconQr size={16} /> },
];

/** 服务端已经渲染好的二维码**图**(base64 PNG),原样贴出来。
 *
 * ★ 别把它塞进 <Qr>:那是「给一张二维码图再编一个二维码」。
 *   夸克 /oauth/authorize 我们传的是 `qrcode=1&qr_width=460&qr_height=460` ——
 *   这两个尺寸参数只有「服务端出图」才讲得通,返回的 qr_data 就是 PNG 的 base64。
 *   实测(cargo test -p linplayer-core quark_qr_data_shape -- --ignored):
 *   长度 4860,开头 `iVBORw0KGgo` = PNG 文件头。喂给 QRCode.toDataURL 必然
 *   「The amount of data is too big to be stored in a QR Code」(纠错级 M 上限 ~2.3KB)。
 *   用户报的「夸克网盘根本生不出来二维码」就是这个,和「扫码搬配置」那个容量问题无关。 */
export function ServerQr({ b64, size = 176 }: { b64: string; size?: number }) {
  return (
    <img
      className="as-qr"
      src={`data:image/png;base64,${b64}`}
      width={size}
      height={size}
      alt="扫码登录二维码"
    />
  );
}

/** 扫码型源(百度/阿里/天翼189)的二维码。核层已经把码渲成 data URI(阿里/189 是 SVG)
 *  或直接给了图 URL(百度),`image` 原样当 `<img src>`,前端不再编码。 */
export function SourceQr({ src, size = 176 }: { src: string; size?: number }) {
  return <img className="as-qr" src={src} width={size} height={size} alt="扫码登录二维码" />;
}

/** 二维码画布:把**文本**编成二维码。只给真·文本载荷用(如扫码搬配置的 LPSYNC1: 串)。 */
export function Qr({ data, size = 176 }: { data: string; size?: number }) {
  const [img, setImg] = useState("");
  const [err, setErr] = useState("");
  useEffect(() => {
    let alive = true;
    setErr("");
    /* 纠错级 L(容量 ~2.9KB)必须和 SettingsPage 的出码点一致 —— 同一个 LPSYNC1 载荷
       两个入口用不同纠错级,会出现「设置页能出图、添加页报容量超限」这种见了鬼的现象。
       搬配置是屏对屏近距离扫,不需要 M 级的抗污损余量,换容量更划算。 */
    QRCode.toDataURL(data, { width: size, margin: 1, errorCorrectionLevel: "L" })
      .then((d) => alive && setImg(d))
      // 载荷过长(配置多到超出二维码容量)时会失败 —— 必须说出来,不能白框糊弄。
      .catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [data, size]);
  if (err) return <p className="as-warn" style={{ margin: 0 }}>二维码生成失败:{err}</p>;
  return img ? (
    <img className="as-qr" src={img} width={size} height={size} alt="二维码" />
  ) : (
    <span className="spinner" />
  );
}

/** Emby「测试连接」按钮的三态。登录闸口把结果直接画在按钮上(见 LoginPage)。 */
export type TestState = "idle" | "busy" | "ok";

type Options = {
  /** 登录/添加成功。src 非空表示刚登录的是文件浏览型源,宿主该直接带去对应页。 */
  onDone: (src?: "netdisk" | "anirss") => void;
  /** 不需要的源(登录闸口用来屏蔽「扫码搬配置」——PC 有键盘有剪贴板,粘文本更快)。 */
  exclude?: SourceId[];
};

export function useSourceForms({ onDone, exclude = [] }: Options) {
  const [sel, setSel] = useState<SourceId>("emby");

  // 各表单共用输入(切换类型时保留,填过的地址账号不用重敲)。
  const [server, setServer] = useState("https://");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [name, setName] = useState("");
  const [note, setNote] = useState("");
  const [cookie, setCookie] = useState("");
  const [stremio, setStremio] = useState(STREMIO_DEFAULT);
  // 百度双路线:扫码 / Cookie。默认扫码。
  const [baiduWay, setBaiduWay] = useState<"scan" | "cookie">("scan");
  // 天翼189 两路线:扫码 / 账密(手机号+密码)。默认扫码。
  const [pan189Way, setPan189Way] = useState<"scan" | "password">("scan");
  // 移动云139 三路线:扫码 / 手机号密码 / 手动粘 Authorization。默认扫码。
  const [pan139Way, setPan139Way] = useState<"scan" | "password" | "manual">("scan");
  const [batchText, setBatchText] = useState("");
  const [qrPayload, setQrPayload] = useState("");
  const [exportText, setExportText] = useState("");
  const [probed, setProbed] = useState<ServerInfo | null>(null);

  /* 插件贡献的数据源。**登录表单由 manifest 声明的字段现渲染** ——
     不这样的话每接一个插件源都要回来改这个文件一次,「用户自己做插件自己用」
     就成了空话。字段值单独存一份,别和上面那几个内置输入框混在一起
     (内置的是共用的,插件的是每个源一套)。 */
  const [pluginSources, setPluginSources] = useState<PluginDataSource[]>([]);
  const [pluginForm, setPluginForm] = useState<Record<string, string>>({});
  useEffect(() => {
    const load = () => pluginDataSources().then(setPluginSources).catch(() => setPluginSources([]));
    load();
    // 插件启用/停用后源会增减,不重新拉的话这一页会一直显示旧的那批。
    const un = listen("plugin://sources-changed", load);
    const un2 = listen("plugin://extensions-changed", load);
    return () => {
      un.then((f) => f());
      un2.then((f) => f());
    };
  }, []);
  // 切到别的源时把插件表单清空,免得上一个源填的账号串到下一个源里。
  useEffect(() => setPluginForm({}), [sel]);

  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const [toast, setToast] = useState("");

  /** 内置(去掉调用方不要的)+ 插件贡献的源。 */
  const sources: SourceMeta[] = useMemo(
    () => [
      ...BUILTIN_SOURCES.filter((s) => !exclude.includes(s.id)),
      ...pluginSources.map((p) => ({
        id: p.kind,
        label: p.name,
        sec: "插件源",
        icon: () => <IconPlugin size={16} />,
      })),
    ],
    // exclude 是调用方写死的字面量数组,每次渲染是新引用 —— 按内容比,别按引用比。
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [pluginSources, exclude.join(",")],
  );

  /** 按 sec 分组(添加服务器页的左侧 nav 要分组标题)。 */
  const groups = useMemo(() => {
    const m = new Map<string, SourceMeta[]>();
    for (const s of sources) m.set(s.sec, [...(m.get(s.sec) ?? []), s]);
    return [...m.entries()].map(([sec, items]) => ({ sec, items }));
  }, [sources]);

  async function run(fn: () => Promise<void>) {
    if (busy) return;
    setErr("");
    setToast("");
    setBusy(true);
    try {
      await fn();
    } catch (e) {
      setErr(String(e));
    } finally {
      setBusy(false);
    }
  }

  /** 插件源登录:把声明式表单里的值按约定字段名喂给 source_login。
   *  base_url 是核层唯一认得的定位字段(也是 $sourceServer 白名单令牌的来源),
   *  剩下的一股脑塞 cookie 那个自由字段(核层原样透给插件的 server.token)。 */
  const submitPluginSource = (p: PluginDataSource) =>
    run(async () => {
      const fields = p.auth?.fields ?? [];
      const val = (id: string) => (pluginForm[id] ?? "").trim();
      const known = new Set(["base_url", "username", "password"]);
      const extra = fields
        .filter((f) => !known.has(f.id))
        .reduce<Record<string, string>>((m, f) => ({ ...m, [f.id]: val(f.id) }), {});
      await sourceLogin(
        p.kind,
        val("base_url"),
        val("username"),
        val("password"),
        Object.keys(extra).length ? JSON.stringify(extra) : null,
      );
      await nameActiveSource();
      onDone("netdisk");
    });

  /* ---------- linplayer:// 深链(安全门禁) ----------
     ★ 深链可能来自任何网页/聊天窗口。解析出来 **不等于** 可以直接加 ——
     必须弹确认框把服务器地址和用户名摆给用户看,他点头才 batch_add_servers。
     直接静默添加 = 任意网页能把用户钉到攻击者的服务器上。 */
  const [deep, setDeep] = useState<{ name: string | null; block: Block } | null>(null);

  useEffect(() => {
    (async () => {
      try {
        // ★ startup_deep_link 的 Rust 签名是 -> Option<String>(原始 URL),
        // api.ts 却把它标成 DeepLinkAddServer|null —— 那边类型写错了(已上报)。
        // 这里按核层实际形态窄转,再交给 parse_deep_link 真正解析。
        const url = (await startupDeepLink()) as unknown as string | null;
        if (!url) return;
        const link = await parseDeepLink(url);
        if (!link) return;
        setDeep({ name: link.name, block: asBlocks([link.block])[0] });
      } catch (e) {
        setErr(String(e)); // 解析失败要说出来,别让用户干等一个不出现的确认框
      }
    })();
  }, []);

  const confirmDeep = () =>
    run(async () => {
      if (!deep) return;
      const r = await batchAddServers(asApi([deep.block]), null, null, deep.name);
      setDeep(null);
      const bad = r.filter((x) => x.error);
      if (bad.length) {
        setErr(bad.map((x) => `${x.name}:${x.error}`).join(" / "));
        return;
      }
      setToast(`已添加 ${r.length} 个服务器`);
      window.setTimeout(() => onDone(), 800);
    });

  // ---------- Emby ----------
  /* ★ 测试连接**只探测,不添加**。以前这里调的是 login() —— 它会 upsert 账号、
     落盘、还把活跃会话切过去,然后只回一句「连接成功」,用户根本没说要加。
     test_connection 是专为这个 pin 写的:登录前调用,不碰会话不落账号。 */
  const [testing, setTesting] = useState(false);
  const doTest = () =>
    run(async () => {
      setTesting(true);
      try {
        const info = await testConnection(server.trim());
        setProbed(info);
      } finally {
        setTesting(false);
      }
    });
  /** 测试按钮的三态。登录闸口拿它把「连接成功」画在按钮上,不再单开一块回执。 */
  const testState: TestState = testing ? "busy" : probed ? "ok" : "idle";

  const doAdd = () =>
    run(async () => {
      const res = await login(server.trim(), username, password);
      // login 既没有 name 也没有 note 参数(核层确实如此),但两者都是落库的 —— 加完补一刀。
      const nm = name.trim();
      const n = note.trim();
      if (nm || n) await updateAccount(res.server, { name: nm || undefined, remark: n || undefined });
      onDone();
    });

  /* 文件浏览型源的改名。source_login 是 `-> ()`,拿不到账号键 ——
     登录成功后它就是**当前活跃源**,用 current_source 回读一次拿键再改名。
     失败不阻断:名字没改上顶多显示成地址,不该让"加成功了"变成"报错了"。 */
  async function nameActiveSource() {
    const nm = name.trim();
    if (!nm) return;
    try {
      const a = await currentSource();
      if (a) await updateAccount(a.server, { name: nm });
    } catch { /* 改名失败不影响已经加成功的源 */ }
  }

  const submitSource = (kind: "openlist" | "feiniu" | "anirss") =>
    run(async () => {
      await sourceLogin(kind, server.trim(), username, password, null);
      await nameActiveSource();
      onDone(kind === "anirss" ? "anirss" : "netdisk");
    });

  /* Stremio 一个账号 = 一组 addon(catalog 来自元数据 addon、播放源来自另一个,
     Stremio 本来就是这么组合的),所以是多行输入而不是单个地址。
     核层约定(见 crates/core/src/source/stremio.rs 顶部注释):
       base_url = 第一个 addon(同时当账号 id,所以要挑稳定的)
       cookie   = 其余行原样带过去,核层再拆 `server=` 与追加 addon。 */
  const submitStremio = () =>
    run(async () => {
      const lines = stremio
        .split("\n")
        .map((s) => s.trim())
        .filter((s) => s && !s.startsWith("#"));
      const addons = lines.filter((l) => !/^server\s*=/i.test(l));
      if (addons.length === 0) throw new Error("至少要填一个 addon 的 manifest 地址");
      const primary = addons[0];
      const rest = lines.filter((l) => l !== primary);
      await sourceLogin("stremio", primary, "", "", rest.join("\n") || null);
      await nameActiveSource();
      onDone("netdisk");
    });

  // ---------- 夸克:扫码 / Cookie 两种方式 ----------
  const [quarkWay, setQuarkWay] = useState<"scan" | "cookie">("scan");
  const [scan, setScan] = useState<{ device_id: string; qr_data: string; query_token: string } | null>(null);
  const [scanMsg, setScanMsg] = useState("");
  const pollRef = useRef<number | null>(null);

  // ---------- 通用扫码(百度/阿里/天翼189):core 出码 → 轮询 → 确认后落库 ----------
  const [qr, setQr] = useState<{ image: string; ctx: string } | null>(null);
  const [qrMsg, setQrMsg] = useState("");
  const qrPollRef = useRef<number | null>(null);

  const stopPoll = useCallback(() => {
    if (pollRef.current != null) window.clearInterval(pollRef.current);
    pollRef.current = null;
  }, []);
  // 离页/切换方式必须停轮询,否则弹窗关了它还在后台每 2s 打夸克。
  useEffect(() => stopPoll, [stopPoll]);
  useEffect(() => {
    if (sel !== "quark" || quarkWay !== "scan") stopPoll();
  }, [sel, quarkWay, stopPoll]);

  const startScan = () =>
    run(async () => {
      stopPoll();
      setScanMsg("请用夸克 App 扫码并确认登录");
      const s = await quarkScanStart();
      setScan(s);
      pollRef.current = window.setInterval(async () => {
        try {
          const ok = await quarkScanPoll(s.device_id, s.query_token);
          if (!ok) return; // false = 还没确认,继续轮询
          stopPoll();
          setScanMsg("登录成功");
          // 扫码这一路也要改名 —— 五条登录路径少补一条,那个源就还是显示地址。
          await nameActiveSource();
          onDone("netdisk"); // poll 返回 true 时夸克源已装为活跃源
        } catch (e) {
          // 二维码过期/被拒都会走这里 —— 停下并说明,别无声空转。
          stopPoll();
          setErr(String(e));
          setScanMsg("扫码失败,请点「刷新二维码」重试");
        }
      }, 2000);
    });

  const submitQuarkCookie = () =>
    run(async () => {
      await sourceLogin("quark", "", "", "", cookie);
      await nameActiveSource();
      onDone("netdisk");
    });

  // 离页/切换源必须停通用扫码轮询,否则弹窗关了它还在后台每 2s 打网盘。
  const stopQrPoll = useCallback(() => {
    if (qrPollRef.current != null) window.clearInterval(qrPollRef.current);
    qrPollRef.current = null;
  }, []);
  useEffect(() => stopQrPoll, [stopQrPoll]);
  useEffect(() => {
    // 只有扫码型源在扫码分支时才留轮询;切走一律停 + 清码。
    const scanning =
      sel === "aliyundrive" ||
      (sel === "pan189" && pan189Way === "scan") ||
      (sel === "pan139" && pan139Way === "scan") ||
      (sel === "baidu" && baiduWay === "scan");
    if (!scanning) {
      stopQrPoll();
      setQr(null);
      setQrMsg("");
    }
  }, [sel, baiduWay, pan189Way, pan139Way, stopQrPoll]);

  /** 通用扫码:core 出码 → 每 2s 轮询 → confirmed 时把 credentials 塞进 source_login 落库。 */
  const startSourceScan = (kind: string) =>
    run(async () => {
      stopQrPoll();
      setQrMsg("请用对应 App 扫码并确认登录");
      const s = await sourceQrStart(kind);
      setQr(s);
      qrPollRef.current = window.setInterval(async () => {
        try {
          const r = await sourceQrPoll(kind, s.ctx);
          if (r.state === "pending") return;
          stopQrPoll();
          if (r.state === "expired") {
            setQr(null);
            setQrMsg("二维码已过期,请点「刷新二维码」重试");
            return;
          }
          // confirmed:凭据原样交给 source_login 落库(base_url 留空,以 kind 名作账号 id)。
          setQrMsg("登录成功");
          await sourceLogin(kind, "", "", "", null, r.credentials);
          await nameActiveSource();
          onDone("netdisk");
        } catch (e) {
          stopQrPoll();
          setErr(String(e));
          setQrMsg("扫码失败,请点「刷新二维码」重试");
        }
      }, 2000);
    });

  /** Cookie / 令牌粘贴系(115 Cookie、百度 Cookie、移动云139 Authorization):整段走 cookie 参数。 */
  const submitCookieSource = (kind: string) =>
    run(async () => {
      if (!cookie.trim()) throw new Error("请粘贴凭据");
      await sourceLogin(kind, "", "", "", cookie.trim());
      await nameActiveSource();
      onDone("netdisk");
    });

  /** 账密登录(天翼189):手机号+密码换令牌 → 令牌塞进 source_login 落库。 */
  const submitPasswordLogin = (kind: string) =>
    run(async () => {
      if (!username.trim() || !password) throw new Error("请填写手机号和密码");
      const creds = await sourcePasswordLogin(kind, username.trim(), password);
      await sourceLogin(kind, "", "", "", null, creds);
      await nameActiveSource();
      onDone("netdisk");
    });

  // ---------- 批量解析导入(两段式:先解析给用户核对,确认后才登录落盘) ----------
  const [blocks, setBlocks] = useState<Block[] | null>(null);
  const [fbUser, setFbUser] = useState("");
  const [fbPass, setFbPass] = useState("");
  const [fbName, setFbName] = useState("");
  const [results, setResults] = useState<BatchAddResult[] | null>(null);

  const doParse = () =>
    run(async () => {
      setResults(null);
      const b = asBlocks(await batchParse(batchText));
      setBlocks(b);
      if (!b.length) setToast("没解析出任何服务器,检查一下文本格式");
    });

  const doBatchAdd = () =>
    run(async () => {
      if (!blocks?.length) return;
      const r = await batchAddServers(
        asApi(blocks),
        fbUser.trim() || null,
        fbPass || null,
        fbName.trim() || null,
      );
      setResults(r);
      // 全绿才跳走;有失败就留在页面上让用户看结果(补用户名再来一次)。
      if (r.length && r.every((x) => !x.error)) window.setTimeout(() => onDone(), 900);
    });

  // ---------- 扫码搬配置 ----------
  const importQr = () =>
    run(async () => {
      const n = await configImportQr(qrPayload.trim());
      setToast(`已导入 ${n} 个账号`);
      window.setTimeout(() => onDone(), 1000);
    });

  const exportQr = () =>
    run(async () => {
      setExportText(await configExportQr());
    });

  const spin = (label: string) => (busy ? <span className="spinner" /> : label);

  /* ★ 名称在**地址上面**,且添加时就能填(用户 2026-07-23)。
     不填的话核层的显示名会回落成 host —— 侧栏、服务器页、切换菜单里到处都是那条线路的
     真实地址,截个图发出去就把自己的服务器暴露了;事后想改还得专门跑一趟服务器页。
     放第一行是因为它答的是"这台叫什么",逻辑上先于"它在哪"。

     ★ 每一种会建账号的源都要有它,不只是有地址的那几种:Stremio 的账号标识是第一个
       addon 的 URL、插件源是 base_url,同样会把地址摆到界面上。 */
  const nameField = (placeholder = "家里的 Emby") => (
    <div className="fld">
      <label>服务器名称（可选，不填就显示地址）</label>
      <input
        className="field"
        placeholder={placeholder}
        value={name}
        onChange={(e) => setName(e.target.value)}
      />
    </div>
  );

  // 名称 + 地址 + 用户名 + 密码(Emby 与网盘登录型共用)。
  const creds = (optional = false) => (
    <>
      {nameField()}
      <div className="fld">
        <label>服务器地址</label>
        <input
          className="field"
          placeholder="https://host:port"
          value={server}
          onChange={(e) => {
            setServer(e.target.value);
            setProbed(null); // 地址改了,上次的探测结果就不作数了
          }}
        />
      </div>
      <div className="as-grid2">
        <div className="fld">
          <label>用户名{optional ? "（可选）" : ""}</label>
          <input className="field" value={username} onChange={(e) => setUsername(e.target.value)} />
        </div>
        <div className="fld">
          <label>密码{optional ? "（可选）" : ""}</label>
          <input
            className="field"
            type="password"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
      </div>
    </>
  );

  const plug = () => pluginSources.find((p) => p.kind === sel) ?? null;

  /** 当前源的标题 + 一句说明。登录闸口不用(卡片自己有头部),故单拆出来。 */
  function heading(): ReactNode {
    const p = plug();
    if (p) {
      return (
        <>
          <h4>{p.name}</h4>
          <p className="hint">
            由插件「{p.pluginId}」提供。
            {(p.auth?.fields ?? []).length === 0 && "这个源不需要登录,直接添加即可。"}
          </p>
        </>
      );
    }
    const t: Record<string, [string, ReactNode]> = {
      emby: ["Emby / Jellyfin", "填写服务器地址与账号，测试连接后添加。"],
      openlist: ["OpenList", "填写服务器地址与账号后添加。"],
      feiniu: ["飞牛影视", "填写服务器地址与账号后添加。"],
      anirss: ["Ani-RSS", "填写服务器地址与账号后添加。"],
      quark: ["夸克网盘", "推荐扫码登录；也可粘贴浏览器 Cookie。"],
      aliyundrive: [
        "阿里云盘",
        <>用<b>阿里云盘 App</b> 扫码登录，确认后自动完成。</>,
      ],
      baidu: [
        "百度网盘",
        <>
          推荐用<b>百度 App 扫码</b>登录；也可粘浏览器 Cookie（含 BDUSS）。
          网页版取播放地址受风控限制，Cookie 过期请重新扫码。
        </>,
      ],
      pan115: [
        "115 网盘",
        <>浏览器登录 115 后，复制整段 <b>Cookie</b>（含 UID/SEID）粘到下方。</>,
      ],
      pan189: [
        "天翼云盘",
        <>用<b>天翼云盘 App</b> 扫码登录；也可用<b>手机号 + 密码</b>直接登录。</>,
      ],
      pan139: [
        "移动云盘",
        <>用<b>移动云盘 App</b> 扫码登录；也可用手机号 + 密码，或手动粘贴 Authorization。</>,
      ],
      stremio: [
        "Stremio",
        <>
          每行一个 addon 的 <b>manifest.json</b> 地址。第一行会作为这个账号的标识，
          建议放元数据 addon（如已预填的 Cinemeta）。
        </>,
      ],
      batch: [
        "批量粘贴导入",
        <>
          粘贴分享文本 → <b>解析</b>(只解析,不登录不落盘)→ 核对无误后 <b>添加</b>。
        </>,
      ],
      qrsync: [
        "扫码搬配置",
        <>
          在本机<b>导出</b>成二维码,另一台设备扫走(离线直传凭据);或把对方的 LPSYNC1 载荷粘到下方<b>导入</b>。
        </>,
      ],
    };
    const hit = t[sel as string];
    if (!hit) return null;
    return (
      <>
        <h4>{hit[0]}</h4>
        <p className="hint">{hit[1]}</p>
      </>
    );
  }

  /** 当前源的**输入控件**(不含标题、不含主按钮)。两个页面完全一样。 */
  function fields(): ReactNode {
    const p = plug();
    if (p) {
      return (
        <>
          {nameField(p.name)}
          {(p.auth?.fields ?? []).map((f) => (
        <div key={f.id} className="fld">
          <label>
            {f.label ?? f.id}
            {f.required ? "" : "(可选)"}
          </label>
          <input
            className="field"
            type={f.type === "password" ? "password" : "text"}
            placeholder={f.placeholder ?? (f.id === "base_url" ? "https://" : "")}
            value={pluginForm[f.id] ?? ""}
            onChange={(e) => setPluginForm((m) => ({ ...m, [f.id]: e.target.value }))}
          />
        </div>
          ))}
        </>
      );
    }

    // 扫码型源(百度/阿里/天翼189)共用的二维码块。nameField 由各 case 自己加。
    const scanBox = (kind: string, app: string) => (
      <div className="as-scan">
        {qr ? (
          <SourceQr src={qr.image} />
        ) : (
          <div className="as-qr placeholder">点下方按钮生成二维码</div>
        )}
        <div className="as-scan-side">
          <p className="hint" style={{ margin: 0 }}>
            {qrMsg || `用${app}扫码，确认后自动完成登录。`}
          </p>
          <button className="btn primary" disabled={busy} onClick={() => startSourceScan(kind)}>
            {spin(qr ? "刷新二维码" : "生成二维码")}
          </button>
        </div>
      </div>
    );

    // 手机号+密码子表单(天翼189 / 移动云139 共用)。
    const pwdFields = (
      <>
        <p className="hint">用网盘账号的手机号和登录密码。若提示需要图形验证码，请改用其它登录方式或稍后再试。</p>
        <div className="fld">
          <label>手机号</label>
          <input
            className="field"
            autoComplete="off"
            placeholder="13800138000"
            value={username}
            onChange={(e) => setUsername(e.target.value)}
          />
        </div>
        <div className="fld">
          <label>密码</label>
          <input
            className="field"
            type="password"
            autoComplete="off"
            value={password}
            onChange={(e) => setPassword(e.target.value)}
          />
        </div>
      </>
    );

    switch (sel) {
      case "emby":
        return (
          <>
            {creds()}
            <div className="fld">
              <label>备注（可选）</label>
              <input
                className="field"
                placeholder="家里的 Emby"
                value={note}
                onChange={(e) => setNote(e.target.value)}
              />
            </div>
          </>
        );

      case "openlist":
      case "feiniu":
        return creds();
      case "anirss":
        return creds(true);

      case "aliyundrive":
        return (
          <>
            {nameField("我的阿里云盘")}
            {scanBox("aliyundrive", "阿里云盘 App")}
          </>
        );

      case "pan189":
        return (
          <>
            {nameField("我的天翼云盘")}
            <div className="seg" style={{ marginBottom: 14 }}>
              {(["scan", "password"] as const).map((w) => (
                <span key={w} className={pan189Way === w ? "on" : ""} onClick={() => setPan189Way(w)}>
                  {w === "scan" ? "扫码登录" : "手机号密码"}
                </span>
              ))}
            </div>
            {pan189Way === "scan" ? scanBox("pan189", "天翼云盘 App") : pwdFields}
          </>
        );

      case "pan139":
        return (
          <>
            {nameField("我的移动云盘")}
            <div className="seg" style={{ marginBottom: 14 }}>
              {(["scan", "password", "manual"] as const).map((w) => (
                <span key={w} className={pan139Way === w ? "on" : ""} onClick={() => setPan139Way(w)}>
                  {w === "scan" ? "扫码登录" : w === "password" ? "手机号密码" : "手动粘贴"}
                </span>
              ))}
            </div>
            {pan139Way === "scan" ? (
              scanBox("pan139", "移动云盘 App")
            ) : pan139Way === "password" ? (
              pwdFields
            ) : (
              <>
                <p className="hint">
                  浏览器登录 yun.139.com 后，从开发者工具 Network 里复制任一请求的
                  <b> Authorization</b> 头（Basic 开头那串）粘到下方。
                </p>
                <div className="fld">
                  <label>Authorization</label>
                  <textarea
                    className="field"
                    rows={4}
                    spellCheck={false}
                    placeholder="Basic MTA3MDE6..."
                    value={cookie}
                    onChange={(e) => setCookie(e.target.value)}
                  />
                </div>
              </>
            )}
          </>
        );

      case "pan115":
        return (
          <>
            {nameField("我的 115")}
            <p className="hint">浏览器登录 115 后复制整段 Cookie（含 UID/SEID）粘到下方。</p>
            <div className="fld">
              <label>Cookie</label>
              <textarea
                className="field"
                rows={4}
                spellCheck={false}
                placeholder="UID=…; CID=…; SEID=…"
                value={cookie}
                onChange={(e) => setCookie(e.target.value)}
              />
            </div>
          </>
        );

      case "baidu":
        return (
          <>
            {nameField("我的百度网盘")}
            <div className="seg" style={{ marginBottom: 14 }}>
              {(["scan", "cookie"] as const).map((w) => (
                <span key={w} className={baiduWay === w ? "on" : ""} onClick={() => setBaiduWay(w)}>
                  {w === "scan" ? "扫码登录" : "Cookie"}
                </span>
              ))}
            </div>
            {baiduWay === "scan" ? (
              scanBox("baidu", "百度 App")
            ) : (
              <>
                <p className="hint">
                  浏览器登录百度网盘后复制整段 Cookie（含 BDUSS）粘到下方。网页版取播放地址
                  受风控限制，Cookie 过期请重新扫码登录。
                </p>
                <div className="fld">
                  <label>Cookie</label>
                  <textarea
                    className="field"
                    rows={4}
                    spellCheck={false}
                    placeholder="BDUSS=…; STOKEN=…"
                    value={cookie}
                    onChange={(e) => setCookie(e.target.value)}
                  />
                </div>
              </>
            )}
          </>
        );

      case "stremio":
        return (
          <>
            {nameField("我的 Stremio")}
            <div className="fld">
              <label>Addon 列表</label>
              <textarea
                className="field"
                rows={7}
                spellCheck={false}
                placeholder={
                  "https://v3-cinemeta.strem.io/manifest.json\n" +
                  "https://opensubtitles-v3.strem.io/manifest.json\n" +
                  "server=http://192.168.1.10:11470"
                }
                value={stremio}
                onChange={(e) => setStremio(e.target.value)}
              />
            </div>
            <p className="hint">
              只提供元数据的 addon（Cinemeta 等）不出播放源，要能播必须再加至少一个
              <b> stream 类 addon</b>。<br />
              返回 <b>直链</b> 的播放源可直接播；返回 <b>种子（infoHash）</b>的需要一台
              Stremio 流媒体服务器 —— 自建了就单起一行填
              <code> server=http://地址:11470</code>，没填的种子源会在列表里置灰并注明原因，不会静默消失。
            </p>
          </>
        );

      case "quark":
        return (
          <>
            {nameField("我的夸克")}
            <div className="seg" style={{ marginBottom: 14 }}>
              {(["scan", "cookie"] as const).map((w) => (
                <span key={w} className={quarkWay === w ? "on" : ""} onClick={() => setQuarkWay(w)}>
                  {w === "scan" ? "扫码登录" : "Cookie"}
                </span>
              ))}
            </div>
            {quarkWay === "scan" ? (
              <div className="as-scan">
                {scan ? <ServerQr b64={scan.qr_data} /> : <div className="as-qr placeholder">点下方按钮生成二维码</div>}
                <div className="as-scan-side">
                  <p className="hint" style={{ margin: 0 }}>
                    {scanMsg || "用夸克 App 扫码,确认后自动完成登录。"}
                  </p>
                  <button className="btn primary" disabled={busy} onClick={startScan}>
                    {spin(scan ? "刷新二维码" : "生成二维码")}
                  </button>
                </div>
              </div>
            ) : (
              <>
                <p className="hint">浏览器登录夸克后复制整段 Cookie 粘贴到下方。</p>
                <div className="fld">
                  <label>Cookie</label>
                  <textarea
                    className="field"
                    rows={5}
                    placeholder="__pus=…; __kp=…; …"
                    value={cookie}
                    onChange={(e) => setCookie(e.target.value)}
                  />
                </div>
              </>
            )}
          </>
        );

      case "batch":
        return (
          <>
            <div className="fld">
              <label>服务器列表 / 分享文本</label>
              <textarea
                className="field"
                rows={7}
                placeholder={"线路1|https://a.lan:8096\n线路2|https://b.lan:8096\n账号:user\n密码:pass"}
                value={batchText}
                onChange={(e) => setBatchText(e.target.value)}
              />
            </div>
            <div className="as-actions">
              <button className="btn" disabled={busy || !batchText.trim()} onClick={doParse}>
                {spin("解析")}
              </button>
            </div>
            {blocks && blocks.length > 0 && (
              <>
                <h4 style={{ marginTop: 20 }}>核对（{blocks.length} 个服务器）</h4>
                <div className="as-blocks">
                  {blocks.map((b, i) => {
                    const r = results?.[i];
                    return (
                      <div key={i} className="as-block">
                        <div className="as-block-hd">
                          <b>{b.lines[0]?.name || "(未命名)"}</b>
                          <span className="as-dim">{b.username || "缺用户名(用下方兜底)"}</span>
                          {r && (
                            <span className={`as-rst${r.error ? " bad" : ""}`}>
                              {r.error ? `✕ ${r.error}` : "✓ 已添加"}
                            </span>
                          )}
                        </div>
                        {b.lines.map((l, k) => (
                          <div key={k} className="as-line">
                            <span className="as-dim">{l.name}</span> {l.url}
                          </div>
                        ))}
                        {b.danmaku_lines.length > 0 && (
                          <div className="as-line as-dim">弹幕线路 × {b.danmaku_lines.length}</div>
                        )}
                      </div>
                    );
                  })}
                </div>
                <p className="hint" style={{ marginTop: 14 }}>
                  兜底凭据:套用到上面所有<b>没解析出用户名</b>的块（解析到的以文本里的为准）。
                </p>
                <div className="as-grid3">
                  <div className="fld">
                    <label>兜底用户名</label>
                    <input className="field" value={fbUser} onChange={(e) => setFbUser(e.target.value)} />
                  </div>
                  <div className="fld">
                    <label>兜底密码</label>
                    <input className="field" type="password" value={fbPass} onChange={(e) => setFbPass(e.target.value)} />
                  </div>
                  <div className="fld">
                    <label>兜底显示名（可选）</label>
                    <input className="field" value={fbName} onChange={(e) => setFbName(e.target.value)} />
                  </div>
                </div>
              </>
            )}
          </>
        );

      case "qrsync":
        return (
          <>
            <div className="fld">
              <label>导入载荷</label>
              <textarea
                className="field"
                rows={4}
                placeholder="LPSYNC1:…"
                value={qrPayload}
                onChange={(e) => setQrPayload(e.target.value)}
              />
            </div>
            {/* 扫「进来」要摄像头,桌面端没有 —— 故导入侧保留文本粘贴,这是真实约束不是偷懒。 */}
            <p className="hint" style={{ marginTop: 10 }}>
              桌面端无摄像头,故「导入」用文本粘贴;「导出」出二维码给手机扫。
            </p>
            {exportText && (
              <div className="as-export">
                <Qr data={exportText} size={200} />
                <div className="fld" style={{ flex: 1, marginBottom: 0 }}>
                  <label>本机配置载荷（也可复制文本到另一台设备导入）</label>
                  <textarea className="field" rows={5} readOnly value={exportText} />
                </div>
              </div>
            )}
          </>
        );

      default:
        return null;
    }
  }

  /** 当前源的主提交按钮。label 由页面给(添加页叫「添加」,登录闸口叫「添加并进入」)。 */
  function primary(label: string): ReactNode {
    const p = plug();
    if (p) {
      const fs = p.auth?.fields ?? [];
      const missing = fs.some((f) => f.required && !(pluginForm[f.id] ?? "").trim());
      return (
        <button className="btn primary big" disabled={busy || missing} onClick={() => submitPluginSource(p)}>
          {spin(label)}
        </button>
      );
    }
    switch (sel) {
      case "emby":
        return (
          <button className="btn primary big" disabled={busy} onClick={doAdd}>
            {spin(label)}
          </button>
        );
      case "openlist":
      case "feiniu":
      case "anirss":
        return (
          <button
            className="btn primary big"
            disabled={busy}
            onClick={() => submitSource(sel as "openlist" | "feiniu" | "anirss")}
          >
            {spin(label)}
          </button>
        );
      // 阿里:扫码按钮长在二维码旁边(见 fields),这里无主按钮。
      case "aliyundrive":
        return null;
      // 天翼189:扫码那一路按钮在二维码旁;账密需要底部主按钮。
      case "pan189":
        if (pan189Way === "password")
          return (
            <button
              className="btn primary big"
              disabled={busy || !username.trim() || !password}
              onClick={() => submitPasswordLogin("pan189")}
            >
              {spin(label)}
            </button>
          );
        return null;
      case "pan115":
        return (
          <button className="btn primary big" disabled={busy || !cookie.trim()} onClick={() => submitCookieSource("pan115")}>
            {spin(label)}
          </button>
        );
      case "pan139":
        if (pan139Way === "scan") return null; // 扫码按钮在二维码旁
        if (pan139Way === "password")
          return (
            <button
              className="btn primary big"
              disabled={busy || !username.trim() || !password}
              onClick={() => submitPasswordLogin("pan139")}
            >
              {spin(label)}
            </button>
          );
        return (
          <button className="btn primary big" disabled={busy || !cookie.trim()} onClick={() => submitCookieSource("pan139")}>
            {spin(label)}
          </button>
        );
      case "baidu":
        // 扫码那一路按钮在二维码旁;只有 Cookie 一路需要底部主按钮。
        return baiduWay === "cookie" ? (
          <button className="btn primary big" disabled={busy || !cookie.trim()} onClick={() => submitCookieSource("baidu")}>
            {spin(label)}
          </button>
        ) : null;
      case "stremio":
        return (
          <button className="btn primary big" disabled={busy || !stremio.trim()} onClick={submitStremio}>
            {spin(label)}
          </button>
        );
      case "quark":
        // 扫码那一路的按钮长在二维码旁边(见 fields),这里只有 Cookie 一路需要提交。
        return quarkWay === "cookie" ? (
          <button className="btn primary big" disabled={busy} onClick={submitQuarkCookie}>
            {spin(label)}
          </button>
        ) : null;
      case "batch":
        return blocks && blocks.length > 0 ? (
          <button className="btn primary big" disabled={busy} onClick={doBatchAdd}>
            {spin(`添加这 ${blocks.length} 个`)}
          </button>
        ) : null;
      case "qrsync":
        return (
          <>
            <button className="btn primary big" disabled={busy || !qrPayload.trim()} onClick={importQr}>
              {spin("导入")}
            </button>
            <button className="btn big" disabled={busy} onClick={exportQr}>
              {spin("导出本机配置")}
            </button>
          </>
        );
      default:
        return null;
    }
  }

  /** 深链确认弹窗(两个页面都要挂 —— 深链可能在任一页打开时到达)。 */
  const deepDialog: ReactNode = deep ? (
    <div className="scrim" onClick={() => setDeep(null)}>
      <div className="dlg" onClick={(e) => e.stopPropagation()}>
        <div className="dhd">确认添加服务器?</div>
        <div className="dbd">
          <p className="as-warn" style={{ marginBottom: 12 }}>
            这是通过 <b>linplayer://</b> 链接发起的请求,可能来自任意网页或聊天窗口。
            请确认下面的地址和用户名确实是你想添加的。
          </p>
          {deep.name && (
            <div className="fld">
              <label>名称</label>
              <input className="field" value={deep.name} disabled />
            </div>
          )}
          <div className="fld">
            <label>用户名</label>
            <input className="field" value={deep.block.username || "(未提供,添加会失败)"} disabled />
          </div>
          <div className="fld" style={{ marginBottom: 0 }}>
            <label>服务器地址（{deep.block.lines.length} 条线路）</label>
            {deep.block.lines.map((l, i) => (
              <input key={i} className="field" style={{ marginTop: i ? 6 : 0 }} value={`${l.name} · ${l.url}`} disabled />
            ))}
          </div>
        </div>
        <div className="dft">
          <button className="btn" onClick={() => setDeep(null)}>取消</button>
          <button className="btn primary" disabled={busy} onClick={confirmDeep}>
            {spin("确认添加")}
          </button>
        </div>
      </div>
    </div>
  ) : null;

  return {
    sel, setSel, sources, groups,
    busy, err, setErr, toast, setToast,
    heading, fields, primary, deepDialog,
    // Emby 的测试连接:两个页面按各自版式摆按钮,状态和动作从这里拿。
    doTest, testState, probed,
  };
}
