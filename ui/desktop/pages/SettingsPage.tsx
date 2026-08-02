import { useEffect, useMemo, useRef, useState, type ReactNode } from "react";
import { listen } from "@tauri-apps/api/event";
import { openUrl } from "@tauri-apps/plugin-opener";
import QRCode from "qrcode";
import "./SettingsPage.css";
import {
  type AccountInfo,
  type CfProxyStatus,
  type CfTestResult,
  type DanmakuServer,
  type PrefetchSettings,
  type PreloadSettings,
  type ProxyConfig,
  type SyncAccount,
  type TraktDeviceCode,
  type WritebackSettings,
  getPrefs,
  setPrefs,
  setTrackRegexes,
  validateTrackRegex,
  setDetailBlur,
  blockedList,
  setBlocked,
  type BlockedItem,
  getProxy,
  setProxy,
  getDanmakuConfig,
  getOfficialDanmaku,
  type OfficialDanmaku,
  setDanmakuConfig,
  traktAccount,
  traktDeviceCode,
  traktPoll,
  traktLogout,
  bangumiAccount,
  bangumiAuthorizeUrl,
  bangumiExchange,
  bangumiLoginToken,
  bangumiLogout,
  configExportQr,
  configImportQr,
  type DataPaths,
  type RootKind,
  dataPaths,
  getScreenshotDir,
  pickDirectory,
  pickFile,
  type PlaybackPrefs,
  getPlaybackPrefs,
  setPlaybackPrefs,
  type MpvConf,
  getMpvConf,
  setMpvConf,
  setScreenshotDir,
  type ScreenshotDir,
  cacheSize,
  clearCache,
  openDataDir,
  fmtSize,
  getTranslationSettings,
  setTranslationSettings,
  translationEngineStatus,
  whisperModels,
  whisperDownload,
  whisperDelete,
  whisperDeps,
  whisperDownloadFfmpeg,
  listAccounts,
  cfSpeedTest,
  cfProxyEnable,
  cfProxyDisable,
  cfProxyStatus,
  getPrefetchSettings,
  getPreloadSettings,
  setPrefetchSettings,
  setPreloadSettings,
  getCrossServerResume,
  setCrossServerResume,
  getWritebackSettings,
  setWritebackSettings,
  getUpdateSettings,
  setUpdateSettings,
  checkUpdate,
  downloadAndApplyUpdate,
  type UpdateSettings,
  type UpdateInfo,
  type UpdateChannel,
} from "@shared/api";
import {
  allBindings,
  comboLabel,
  comboOf,
  conflicts,
  onBindingsChange,
  resetAll,
  setKeys,
} from "../lib/shortcuts";
import {
  IconSun,
  IconPlay,
  IconLibrary,
  IconEyeOff,
  IconFile,
  IconCloud,
  IconDownload,
  IconServer,
  IconRefresh,
  IconHeart,
  IconInfo,
  IconKeyboard,
  IconSearch,
} from "../app/icons";

/* ============================================================
   设置页 —— 严格照 docs/desktop-drafts.html PAGE 7:
   cbar(面包屑 + 搜索设置项) → .md 主从两栏:
   左 .mdnav(.sec/.it) 右 .mdpane(h4/.hint + .setrow/.sw/.seg/.stepper/.field)。
   改完即生效(输入 blur / 开关点按即调命令),绿字/toast 反馈。
   没接的一律诚实标注,不造假。
   ============================================================ */

type Theme = "dark" | "light";
type Props = { theme: Theme; setTheme: (t: Theme) => void };

/* ---------- 即时反馈 ---------- */
type Msg = { kind: "ok" | "err"; text: string };
function Flash({ msg }: { msg: Msg | null }) {
  const [show, setShow] = useState<Msg | null>(msg);
  useEffect(() => {
    setShow(msg);
    if (!msg) return;
    const t = setTimeout(() => setShow(null), msg.kind === "err" ? 5000 : 2400);
    return () => clearTimeout(t);
  }, [msg]);
  if (!show) return null;
  return show.kind === "err" ? (
    <div className="toast error">{show.text}</div>
  ) : (
    <span className="st-ok">{show.text}</span>
  );
}
function useFlash() {
  const [msg, setMsg] = useState<Msg | null>(null);
  return {
    ok: (text: string) => setMsg({ kind: "ok", text }),
    err: (e: unknown) => setMsg({ kind: "err", text: String(e) }),
    node: <Flash msg={msg} />,
  };
}

const copy = (t: string) => navigator.clipboard?.writeText(t);

/** 取 host 当回落显示名(源没起名时)。URL 还没填完就返空,别抛。 */
function hostOf(u: string): string {
  try {
    return new URL(u).host;
  } catch {
    return "";
  }
}

/* ---------- 草稿控件(全局类) ---------- */
function Sw({
  on,
  onChange,
  disabled,
}: {
  on: boolean;
  onChange: (v: boolean) => void;
  disabled?: boolean;
}) {
  return (
    <button
      type="button"
      className={"sw" + (on ? " on" : "")}
      role="switch"
      aria-checked={on}
      disabled={disabled}
      style={disabled ? { opacity: 0.45 } : undefined}
      onClick={() => onChange(!on)}
    >
      <i />
    </button>
  );
}

function Seg<T extends string>({
  value,
  opts,
  onChange,
}: {
  value: T;
  opts: { id: T; label: string }[];
  onChange: (v: T) => void;
}) {
  return (
    <span className="seg">
      {opts.map((o) => (
        <span
          key={o.id}
          className={value === o.id ? "on" : ""}
          onClick={() => onChange(o.id)}
        >
          {o.label}
        </span>
      ))}
    </span>
  );
}

function Stepper({
  value,
  onChange,
  min,
  max,
  step,
  fmt,
}: {
  value: number;
  onChange: (v: number) => void;
  min: number;
  max: number;
  step: number;
  fmt: (v: number) => string;
}) {
  const round = (v: number) => Math.round(v / step) * step;
  return (
    <span className="stepper">
      <button
        type="button"
        className="b"
        onClick={() => onChange(Math.max(min, +round(value - step).toFixed(2)))}
      >
        −
      </button>
      <span className="v">{fmt(value)}</span>
      <button
        type="button"
        className="b"
        onClick={() => onChange(Math.min(max, +round(value + step).toFixed(2)))}
      >
        ＋
      </button>
    </span>
  );
}

/* setrow 快捷:左标题(+说明) + 右控件 */
function Row({
  t,
  d,
  children,
}: {
  t: string;
  d?: string;
  children: ReactNode;
}) {
  return (
    <div className="setrow">
      <span className="l">
        <span className="t">{t}</span>
        {d && <span className="d">{d}</span>}
      </span>
      <span className="ctl">{children}</span>
    </div>
  );
}

/* ============================================================
   通用 · 外观与语言
   ============================================================ */
function AppearancePane({ theme, setTheme }: { theme: Theme; setTheme: (t: Theme) => void }) {
  const f = useFlash();
  /* null = 还没读回来。核层自带默认(40),前端别再硬编一份 —— 两份默认早晚对不上。 */
  const [blur, setBlur] = useState<number | null>(null);

  useEffect(() => {
    let alive = true;
    getPrefs()
      .then((p) => alive && setBlur(p.detail_blur))
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  /* 改完即落核层。同时写 :root 的 --detail-blur(App 启动时写的是同一个变量),
     详情页 .dt-hero-bg 直接读它 —— 不这么写就得等下次启动才看得见效果。
     失败要回滚 UI **和** 变量,否则数字停在新值而磁盘/画面是旧值。 */
  async function applyBlur(v: number) {
    const prev = blur;
    setBlur(v);
    document.documentElement.style.setProperty("--detail-blur", String(v));
    try {
      await setDetailBlur(v);
      f.ok("已保存");
    } catch (e) {
      setBlur(prev);
      if (prev != null) document.documentElement.style.setProperty("--detail-blur", String(prev));
      f.err(e);
    }
  }

  return (
    <div className="mdpane">
      <h4>外观与语言</h4>
      <p className="hint">主题与界面语言,切换立即生效并记住。</p>
      <Row t="界面主题" d="深色影院 / 米黄护眼,二选一">
        <Seg<Theme>
          value={theme}
          opts={[
            { id: "dark", label: "深色" },
            { id: "light", label: "米黄浅色" },
          ]}
          onChange={setTheme}
        />
      </Row>
      <Row t="详情页背景模糊" d="0 = 剧照清晰可辨,100 = 糊成一块底色">
        {blur == null ? (
          <span className="muted">读取中…</span>
        ) : (
          <Stepper value={blur} onChange={applyBlur} min={0} max={100} step={5} fmt={(v) => `${v}`} />
        )}
      </Row>
      <Row t="界面语言" d="目前仅简体中文,多语言待接">
        <span className="muted">简体中文</span>
      </Row>
      {f.node}
    </div>
  );
}

/* ============================================================
   通用 · 播放器
   ★ 这里**全部**真落核心配置,没有一项是本机暂存。
   audio_lang / sub_lang / sub_enabled → prefs(set_prefs)
   记忆播放进度 · 跨服续播        → prefs.cross_server_resume
   解码/倍速/跳片头/缩略图/杜比/外部播放器 → prefs(set_playback_prefs),
     由核层在**每次起播时**应用(src-tauri 的 apply_playback_defaults)。

   2026-07-19 之前这 6 项只写 localStorage("lp.playback.local"),Prefs 里根本没有字段,
   页面上还挂着一段「核心尚无落点」的说明 —— 说明是诚实的,但功能是死的。
   加新项时:落 Prefs → 在 apply_playback_defaults 里消费 → 才算做完。
   只加字段不加消费点,就是又造一个「存得下、没人读」的假开关。
   ============================================================ */
/* 一条筛选正则的输入框。校验**必须问 Rust** —— 浏览器 RegExp 认前后瞻,
   Rust 的 regex crate 不认;拿 JS 校验就会放过一条存得下、却永远不命中的正则,
   两边都不报错,用户只看到「设了没反应」。所以这里 blur 时先 validate 再 save,
   非法就红框 + 不落盘(和旧 Dart 版「正则非法不会保存」的承诺一致)。 */
function RegexField({
  label,
  hint,
  value,
  onChange,
  onCommit,
  disabled,
}: {
  label: string;
  hint: string;
  value: string;
  onChange: (v: string) => void;
  onCommit: () => Promise<void>;
  disabled?: boolean;
}) {
  const [err, setErr] = useState<string | null>(null);
  async function commit() {
    try {
      await validateTrackRegex(value);
    } catch (e) {
      setErr(String(e)); // 非法就停在这:不落盘,红框留着让用户看见
      return;
    }
    setErr(null);
    await onCommit();
  }
  return (
    <div className="fld">
      <label>{label}</label>
      <input
        className="field"
        style={err ? { borderColor: "var(--danger, #e5484d)" } : undefined}
        placeholder="留空 = 不启用"
        value={value}
        disabled={disabled}
        onChange={(e) => {
          onChange(e.target.value);
          setErr(null);
        }}
        onBlur={commit}
      />
      <p className="hint" style={{ margin: "4px 0 0" }}>
        {err ? <span style={{ color: "var(--danger, #e5484d)" }}>正则不合法:{err}</span> : hint}
      </p>
    </div>
  );
}

function PlaybackPane() {
  const f = useFlash();
  const [audio, setAudio] = useState("");
  const [sub, setSub] = useState("");
  const [subOn, setSubOn] = useState(true);
  const [reVer, setReVer] = useState("");
  const [reSub, setReSub] = useState("");
  const [reAudio, setReAudio] = useState("");
  const [loaded, setLoaded] = useState(false);
  /* null = 还没读回来。核层有自己的默认值,前端别硬编码一份 ——
     两份默认值早晚对不上,用户看到的就是「显示的和实际生效的不是一回事」。 */
  const [lp, setLp] = useState<PlaybackPrefs | null>(null);
  const [resume, setResume] = useState<boolean | null>(null);

  useEffect(() => {
    let alive = true;
    getPrefs()
      .then((p) => {
        if (!alive) return;
        setAudio(p.audio_lang ?? "");
        setSub(p.sub_lang ?? "");
        setSubOn(p.sub_enabled);
        setReVer(p.version_regex ?? "");
        setReSub(p.sub_regex ?? "");
        setReAudio(p.audio_regex ?? "");
        setLoaded(true);
      })
      .catch(f.err);
    getCrossServerResume()
      .then((v) => alive && setResume(v))
      .catch(f.err);
    getPlaybackPrefs()
      .then((v) => alive && setLp(v))
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  /* 原生文件选择器。取消(返回 null)不是错误,别弹提示。 */
  async function pickExternal() {
    try {
      const p = await pickFile(lp?.external_player, "可执行文件", ["exe"]);
      if (p) await patchLp({ external_player: p });
    } catch (e) {
      f.err(e);
    }
  }

  /* 跨服续播:点即调命令。失败要回滚 UI —— 否则开关停在「开」而磁盘是「关」。 */
  async function toggleResume(v: boolean) {
    const prev = resume;
    setResume(v);
    try {
      await setCrossServerResume(v);
      f.ok("已保存");
    } catch (e) {
      setResume(prev);
      f.err(e);
    }
  }

  /* 改完即落核心配置。失败要**回滚 UI** —— 否则开关停在新位置而磁盘是旧值,
     用户下次起播发现没生效,回来一看开关明明开着(同 toggleResume 的教训)。 */
  async function patchLp(p: Partial<PlaybackPrefs>) {
    if (!lp) return;
    const prev = lp;
    const next = { ...lp, ...p };
    setLp(next);
    try {
      await setPlaybackPrefs(next);
      f.ok("已保存");
    } catch (e) {
      setLp(prev);
      f.err(e);
    }
  }

  /* 三条正则一起落盘(核层是一条命令,只改这三项不动别的 Prefs)。
     单条的合法性已由 RegexField 在 blur 时问过 Rust,这里再失败只可能是
     别的字段还揣着非法值 —— 如实弹出来,别静默。 */
  async function saveRegexes() {
    try {
      await setTrackRegexes({
        version_regex: reVer.trim(),
        sub_regex: reSub.trim(),
        audio_regex: reAudio.trim(),
      });
      f.ok("已保存");
    } catch (e) {
      f.err(e);
    }
  }

  // 真 prefs:改完即调命令(输入 blur / 开关点按)。
  async function savePrefs(next?: { audio?: string; sub?: string; subOn?: boolean }) {
    try {
      await setPrefs({
        audio_lang: (next?.audio ?? audio).trim() || null,
        sub_lang: (next?.sub ?? sub).trim() || null,
        sub_enabled: next?.subOn ?? subOn,
      });
      f.ok("已保存");
    } catch (e) {
      f.err(e);
    }
  }

  return (
    <div className="mdpane">
      <h4>播放器</h4>
      <p className="hint">解码、进度、字幕默认行为。</p>

      <Row t="默认解码方式" d="硬解省电、软解兼容">
        <Seg<"auto-safe" | "no">
          value={lp?.hwdec ?? "auto-safe"}
          opts={[
            { id: "auto-safe", label: "硬解" },
            { id: "no", label: "软解" },
          ]}
          onChange={(hwdec) => patchLp({ hwdec })}
        />
      </Row>
      <Row t="记忆播放进度 · 跨服续播" d="同一部片在多台服务器上取最大进度续播">
        <Sw on={resume ?? false} disabled={resume === null} onChange={toggleResume} />
      </Row>
      {/* 两行,和播放页「更多」面板同粒度 —— 那边就是两个开关。 */}
      <Row t="自动跳过片头" d="需服务端有章节,认不出就不跳">
        <Sw on={lp?.skip_intro ?? false} disabled={!lp} onChange={(v) => patchLp({ skip_intro: v })} />
      </Row>
      <Row t="自动跳过片尾" d="片尾后面还有内容(如预告)时才跳">
        <Sw on={lp?.skip_outro ?? false} disabled={!lp} onChange={(v) => patchLp({ skip_outro: v })} />
      </Row>
      <Row t="进度条缩略图预览" d="用服务端章节图,没有则只显示时间">
        <Sw
          on={lp?.preview_thumbs ?? true}
          disabled={!lp}
          onChange={(v) => patchLp({ preview_thumbs: v })}
        />
      </Row>
      <Row t="默认倍速" d="每次起播套用,播放中临时调整不改这里">
        <Stepper
          value={lp?.default_speed ?? 1}
          min={0.25}
          max={4}
          step={0.25}
          fmt={(v) => `${v.toFixed(2)}×`}
          onChange={(default_speed) => patchLp({ default_speed })}
        />
      </Row>
      <Row t="杜比视界自动软解" d="DV 硬解常有色偏,软解画面才对">
        <Sw
          on={lp?.dolby_auto_sw ?? true}
          disabled={!lp}
          onChange={(v) => patchLp({ dolby_auto_sw: v })}
        />
      </Row>

      <div className="fld" style={{ marginTop: 14 }}>
        <label>外部播放器</label>
        <div className="st-pathrow">
          <code className="muted" title={lp?.external_player || undefined}>
            {lp?.external_player || "未设置 —— 用内置播放器"}
          </code>
          <button className="btn" disabled={!lp} onClick={pickExternal}>
            选择…
          </button>
          {lp?.external_player ? (
            <button className="btn" onClick={() => patchLp({ external_player: "" })}>
              清除
            </button>
          ) : null}
        </div>
      </div>
      <p className="hint" style={{ margin: "2px 0 18px" }}>
        设了外部播放器后,点播放会直接交给它打开,不再进内置播放器。
      </p>

      <h4 style={{ marginTop: 6 }}>轨道语言偏好</h4>
      <p className="hint">按语言优先选音轨与字幕(ISO 三字母,留空=自动)。改完离开输入框即保存。</p>
      <div className="fld">
        <label>首选音频语言</label>
        <input
          className="field"
          placeholder="如 chi / jpn / eng"
          value={audio}
          disabled={!loaded}
          onChange={(e) => setAudio(e.target.value)}
          onBlur={() => savePrefs()}
        />
      </div>
      <div className="fld">
        <label>首选字幕语言</label>
        <input
          className="field"
          placeholder="如 chi / jpn / eng"
          value={sub}
          disabled={!loaded}
          onChange={(e) => setSub(e.target.value)}
          onBlur={() => savePrefs()}
        />
      </div>
      <Row t="默认加载字幕" d="关闭则播放时不自动挂字幕轨">
        <Sw
          on={subOn}
          onChange={(v) => {
            setSubOn(v);
            savePrefs({ subOn: v });
          }}
        />
      </Row>

      <h4 style={{ marginTop: 22 }}>正则优先选择</h4>
      <p className="hint">
        比上面的语言偏好优先。留空 = 不启用。优先级:手动选过的 ＞ 正则命中 ＞ 语言/服务端默认。{" "}
        {/* Tauri webview 里 <a target="_blank"> 不会开系统浏览器,必须走 opener 插件。 */}
        <a
          href="https://linplayer.902541.xyz/wiki/regex-filters"
          onClick={(e) => {
            e.preventDefault();
            openUrl("https://linplayer.902541.xyz/wiki/regex-filters");
          }}
        >
          写法与示例 →
        </a>
      </p>
      <RegexField
        label="版本筛选"
        hint="多版本片源时优先选中匹配的那条。例:4K|2160 · HEVC|265 · 原盘|remux"
        value={reVer}
        onChange={setReVer}
        onCommit={saveRegexes}
        disabled={!loaded}
      />
      <RegexField
        label="字幕筛选"
        hint="匹配字幕轨的显示名/标题/语言/编码。例:中文|简|繁|chi|zh"
        value={reSub}
        onChange={setReSub}
        onCommit={saveRegexes}
        disabled={!loaded}
      />
      <RegexField
        label="音频筛选"
        hint="匹配音轨的显示名/标题/语言/编码/声道。例:jpn|日 · flac|truehd · 6ch"
        value={reAudio}
        onChange={setReAudio}
        onCommit={saveRegexes}
        disabled={!loaded}
      />
      {f.node}

      <MpvConfBlock />
    </div>
  );
}

/* ============================================================
   通用 · 播放器 › 自定义 mpv 配置
   ============================================================ */
/* 直接把 `<数据根>/data/mpv/mpv.conf` 交给 libmpv 自己解析(我们没写 ini 解析器,
   见 crates/mpv 里 user_config_dir 上方的注释)。所以这里就是个纯文本编辑器。

   两件必须如实说清楚的事,不然就是又一个「设了没用」:
     1. 配置是 Player::new 时读的,而播放器是**进程启动时**建的 → 改完要重启应用;
     2. 配置文件里的同名选项会盖掉我们的默认值,写坏了真能让播放起不来
        (起不来时错误里会点名 mpv.conf,不至于让人一头雾水)。 */
function MpvConfBlock() {
  const f = useFlash();
  const [conf, setConf] = useState<MpvConf | null>(null);
  const [text, setText] = useState("");
  const [dirty, setDirty] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    getMpvConf()
      .then((c) => {
        if (!alive) return;
        setConf(c);
        setText(c.text);
      })
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  async function save() {
    if (busy) return;
    setBusy(true);
    try {
      const c = await setMpvConf(text);
      setConf(c);
      setDirty(false);
      f.ok(c.active ? "已保存 —— 重启应用后生效" : "已清空,回到默认(无自定义配置)");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  return (
    <>
      <h4 style={{ marginTop: 26 }}>自定义 mpv 配置</h4>
      <p className="hint">
        内置播放器就是 mpv。这里写的内容会原样交给它解析,语法与 mpv 官网的{" "}
        <a
          href="https://mpv.io/manual/stable/#configuration-files"
          onClick={(e) => {
            e.preventDefault();
            openUrl("https://mpv.io/manual/stable/#configuration-files");
          }}
        >
          mpv.conf →
        </a>{" "}
        完全一致(一行一条 <code>选项=值</code>,<code>#</code> 开头是注释)。
        <b> 同名选项会覆盖 LinPlayer 的默认值</b>,写错可能导致播放起不来 —— 起不来时
        回到这里清空即可。
      </p>
      <p className="hint" style={{ marginTop: -4 }}>
        文件位置:<code className="muted">{conf?.path ?? "读取中…"}</code>
        {conf && !conf.active && <span> (尚未创建 —— 当前不加载任何自定义配置)</span>}
      </p>
      <div className="fld">
        <textarea
          className="field st-mono"
          rows={10}
          spellCheck={false}
          placeholder={"# 例:\n# 缓存加大一点\ncache=yes\ndemuxer-max-bytes=256MiB\n\n# 音频输出设备延迟\naudio-delay=0"}
          value={text}
          disabled={!conf}
          onChange={(e) => {
            setText(e.target.value);
            setDirty(true);
          }}
        />
        <div className="st-actions" style={{ marginTop: 8 }}>
          <button className="btn primary" disabled={!conf || busy || !dirty} onClick={save}>
            {busy ? "保存中…" : "保存"}
          </button>
          <button
            className="btn"
            disabled={!conf || busy || (!text && !conf.active)}
            onClick={() => {
              setText("");
              setDirty(true);
            }}
          >
            清空
          </button>
          {conf?.active && (
            <span className="hint" style={{ margin: 0 }}>
              下次启动应用时加载
            </span>
          )}
          {f.node}
        </div>
      </div>
    </>
  );
}

/* ============================================================
   通用 · 快捷键
   ============================================================ */
/* 表在 lib/shortcuts.ts,这儿只负责渲染 + 录键。**不要**在这里再抄一份命令清单 ——
   抄一份就是又一处「两处只改了一处」(本仓库的高发病)。 */
function ShortcutsPane() {
  const f = useFlash();
  const [, bump] = useState(0);
  const [recording, setRecording] = useState<string | null>(null);
  useEffect(() => onBindingsChange(() => bump((n) => n + 1)), []);

  /* 录键。用 capture 抢在全局分发器之前 —— 不抢的话按 Alt+1 会当场跳去首页,
     根本录不了任何已经被占用的键(而用户最想改的恰恰就是那些)。 */
  useEffect(() => {
    if (!recording) return;
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === "Escape") { setRecording(null); return; }
      const combo = comboOf(e);
      if (!combo) return; // 只按了修饰键,继续等
      setKeys(recording, [combo]);
      setRecording(null);
      f.ok(`已设为 ${comboLabel(combo)}`);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [recording]);

  const rows = allBindings();
  const bad = conflicts();
  const groups = [...new Set(rows.map((r) => r.cmd.group))];

  return (
    <div className="mdpane">
      <h4>快捷键</h4>
      <p className="hint">
        点「改键」后按新组合(<kbd>Esc</kbd> 取消);按 <kbd>;</kbd> 点屏上任意按钮。
      </p>
      <div className="st-actions" style={{ margin: "4px 0 14px" }}>
        <button
          className="btn"
          onClick={() => {
            resetAll();
            f.ok("已全部恢复默认");
          }}
        >
          全部恢复默认
        </button>
        {f.node}
      </div>

      {groups.map((g) => (
        <div key={g}>
          <h4 style={{ marginTop: 18 }}>{g}</h4>
          {rows
            .filter((r) => r.cmd.group === g)
            .map(({ cmd, keys }) => (
              <div className="setrow" key={cmd.id}>
                <span className="l">
                  <span className="t">{cmd.label}</span>
                  <span className="d">
                    {cmd.scope === "player" ? "播放中" : cmd.scope === "app" ? "主界面" : "任何时候"}
                  </span>
                </span>
                <span className="ctl st-kbdrow">
                  {recording === cmd.id ? (
                    <span className="st-kbdrec">按下新的组合键…</span>
                  ) : keys.length === 0 ? (
                    <span className="st-kbdrec">未设置</span>
                  ) : (
                    keys.map((k) => (
                      <kbd key={k} className={bad.has(k) ? "bad" : undefined} title={bad.has(k) ? "和另一条命令撞键了" : undefined}>
                        {comboLabel(k)}
                      </kbd>
                    ))
                  )}
                  {/* 鼠标手势录不了(录键器只收 keydown),不给改键按钮 —— 摆一个点了没反应的更差。 */}
                  {!cmd.fixed && (
                    <>
                      <button className="btn" onClick={() => setRecording(recording === cmd.id ? null : cmd.id)}>
                        {recording === cmd.id ? "取消" : "改键"}
                      </button>
                      {/* 只有改过的才给「恢复」,没改过时那个按钮点了什么都不会发生。 */}
                      {keys.join() !== cmd.keys.join() && (
                        <button className="btn ghost" onClick={() => setKeys(cmd.id, cmd.keys)}>
                          恢复
                        </button>
                      )}
                    </>
                  )}
                </span>
              </div>
            ))}
        </div>
      ))}
    </div>
  );
}

/* ============================================================
   通用 · 弹幕
   ============================================================ */
/* 核层存的一直是**一张源表**(Vec<DanmakuServer>),并行拉取后按 priority 挑主源。
   之前这里只编辑单个源 —— 读回来的数组塞进对象、写出去少个参数,两头都静默失败。 */
function DanmakuPane() {
  const f = useFlash();
  const [list, setList] = useState<DanmakuServer[] | null>(null);
  const [official, setOfficial] = useState<OfficialDanmaku | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let alive = true;
    getDanmakuConfig()
      .then((l) => alive && setList(l))
      .catch(f.err);
    // 默认源单独取:它不在源表里(凭据编译期注入)。失败不打断自建源的编辑。
    getOfficialDanmaku()
      .then((o) => alive && setOfficial(o))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);

  /** 存盘即读回:核层会补 id、排序,不读回来前端就和磁盘不一致了。 */
  async function commit(next: DanmakuServer[]) {
    setList(next);
    if (busy) return;
    setBusy(true);
    try {
      await setDanmakuConfig(next);
      setList(await getDanmakuConfig());
      f.ok("弹幕源已保存");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  const patch = (i: number, o: Partial<DanmakuServer>) =>
    setList((l) => (l ? l.map((s, j) => (j === i ? { ...s, ...o } : s)) : l));

  /* f.node 挂在加载分支里:getDanmakuConfig 失败时 list 恒为 null,不挂就没地方出错误。 */
  if (!list)
    return (
      <div className="mdpane">
        <h4>弹幕</h4>
        <p className="hint">读取中…</p>
        {f.node}
      </div>
    );

  return (
    <div className="mdpane">
      <h4>弹幕</h4>
      <p className="hint">可配多个源,按优先级挑主源。</p>

      {/* 默认源必须显示出来。它的凭据是编译期注入的、不在源表里,所以设置页原来完全看不见它 ——
          用户会以为「一个源都没有」,而它其实一直在工作。只读展示,没有可编辑项。 */}
      {official && (
        <div className="st-card">
          <div className="setrow">
            <span className="l">
              <span className="t">{official.name}</span>
              <span className="d">{official.available ? "内置默认源" : "此构建未内置凭据,不可用"}</span>
            </span>
          </div>
        </div>
      )}

      {list.length === 0 && <p className="hint">还没有自建源,点下方「添加源」。</p>}

      {list.map((s, i) => (
        <div className="st-card" key={s.id || i}>
          <div className="setrow">
            <span className="l">
              <span className="t">{s.name?.trim() || hostOf(s.api_url) || `源 ${i + 1}`}</span>
              <span className="d">{s.enabled ? "已启用" : "已停用"}</span>
            </span>
            <span className="ctl" style={{ display: "flex", gap: 10, alignItems: "center" }}>
              <Sw on={s.enabled} onChange={(v) => commit(list.map((x, j) => (j === i ? { ...x, enabled: v } : x)))} />
              <button className="btn" onClick={() => commit(list.filter((_, j) => j !== i))}>
                删除
              </button>
            </span>
          </div>
          <div className="fld">
            <label>名称(可选)</label>
            <input
              className="field"
              placeholder="留空则用域名"
              value={s.name}
              onChange={(e) => patch(i, { name: e.target.value })}
              onBlur={() => commit(list)}
            />
          </div>
          <div className="fld">
            <label>API 地址</label>
            <input
              className="field"
              placeholder="https://api.dandanplay.net"
              value={s.api_url}
              onChange={(e) => patch(i, { api_url: e.target.value })}
              onBlur={() => commit(list)}
            />
          </div>
          {/* 鉴权方式/Token 两个输入框已删。用户 2026-07-19:「用户也不知道啥是鉴权方式」。
              主流自建端(danmu_api / misaka_danmu_server)都把 token 放在**路径**里,
              也就是本来就在上面那条链接里 —— 核层 derive_auth 自动认,不用问用户。
              老配置里显式选过鉴权方式的源仍按原值走(danmaku_cfg 里做了兼容),不会失效。 */}
          <div className="setrow">
            <span className="l">
              <span className="t">优先级</span>
              <span className="d">越小越先用</span>
            </span>
            <span className="ctl">
              <Stepper
                value={s.priority}
                min={0}
                max={99}
                step={1}
                fmt={(v) => String(v)}
                onChange={(v) => commit(list.map((x, j) => (j === i ? { ...x, priority: v } : x)))}
              />
            </span>
          </div>
        </div>
      ))}

      <div className="st-actions">
        <button
          className="btn primary"
          disabled={busy}
          onClick={() =>
            commit([
              ...list,
              /* auth_type 留空 = 交给核层按地址推导(derive_auth)。
                 ★ 别写 "none":那是个**显式值**,核层会当成「用户选过了」而跳过推导,
                   于是带 ?token= 的地址永远修不好 —— 又一个「加了逻辑但永不触发」。 */
              { id: "", name: "", api_url: "", auth_type: "", token: "", enabled: true, priority: list.length },
            ])
          }
        >
          ＋ 添加源
        </button>
        {f.node}
      </div>
    </div>
  );
}

/* ============================================================
   通用 · 字幕翻译
   ★ 线上格式坑:core 的 TranslationSettings 打了 #[serde(rename_all="camelCase")],
     **Rust 字段名 ≠ 线上键名** —— target_lang 上线是 targetLang、baidu_general 是
     baiduGeneral、whisper_enabled 是 whisperEnabled。照 Rust 字段名写 snake_case 会被
     serde 当未知字段丢掉,而所有字段都带 #[serde(default)] → 反序列化**不报错**,
     直接给你一份默认值存回磁盘,把用户填的 key 全抹了。别改成 snake_case。
     引擎/排版/模型的枚举值同理走 camelCase / lowercase:
     openai|anthropic|baiduGeneral|baiduLlm|tencent、
     translatedOnly|translatedFirst|originalFirst、tiny|base|medium|large。
   ============================================================ */
type AiCfg = { baseUrl: string; apiKey: string; model: string };
type BaiduCfg = { endpoint: string; appId: string; secretKey: string; apiKey: string };
type TencentCfg = { secretId: string; secretKey: string; region: string; projectId: number };
type TrSettings = {
  engine: string;
  targetLang: string;
  layout: string;
  openai: AiCfg;
  anthropic: AiCfg;
  baiduGeneral: BaiduCfg;
  baiduLlm: BaiduCfg;
  tencent: TencentCfg;
  whisperEnabled: boolean;
  whisperModel: string;
  whisperMirror: string;
  whisperBinary: string;
  ffmpegPath: string;
};
/* core WhisperModelInfo 实际返回 key/display_name/size_label/downloaded/downloaded_bytes。
   api.ts 的 WhisperModelInfo 类型(id/name/size_mb)与核层对不上 —— 以核层为准,
   在这儿按真实形状收,别信那份类型。 */
type WhisperRow = {
  key: string;
  display_name: string;
  size_label: string;
  downloaded: boolean;
  downloaded_bytes: number;
};
/* 同理:whisper_deps 返回的是**可执行文件路径或 null**,不是 bool。 */
type WhisperDeps = { whisper: string | null; ffmpeg: string | null };

const TR_ENGINES = [
  { id: "openai", label: "AI · OpenAI 格式" },
  { id: "anthropic", label: "AI · Anthropic 格式" },
  { id: "baiduGeneral", label: "百度翻译 · 通用" },
  { id: "baiduLlm", label: "百度翻译 · 大模型" },
  { id: "tencent", label: "腾讯机器翻译" },
];
/* 目标语言:core lang::norm 认这些基准码(zh-hans/zh-hant/en/ja/…)。 */
const TR_LANGS = [
  { id: "zh-hans", label: "简体中文" },
  { id: "zh-hant", label: "繁体中文" },
  { id: "en", label: "English" },
  { id: "ja", label: "日本語" },
  { id: "ko", label: "한국어" },
  { id: "fr", label: "Français" },
  { id: "de", label: "Deutsch" },
  { id: "es", label: "Español" },
  { id: "ru", label: "Русский" },
];

function SubTransPane() {
  const f = useFlash();
  const [s, setS] = useState<TrSettings | null>(null);
  const [st, setSt] = useState<Record<string, boolean>>({});
  const [models, setModels] = useState<WhisperRow[] | null>(null);
  const [deps, setDeps] = useState<WhisperDeps | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  /** 下载进度 0~100:模型下 1~3GB,不报进度用户会以为卡死(core 的注释也这么说)。 */
  const [prog, setProg] = useState<{ what: string; pct: number } | null>(null);

  const refreshWhisper = async () => {
    // 并发:两者互不依赖,串行只是白等一轮。
    const [m, d] = await Promise.all([whisperModels(), whisperDeps()]);
    setModels(m as unknown as WhisperRow[]);
    setDeps(d as unknown as WhisperDeps);
  };

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        /* ★ 四个 invoke 全并发,别串行 await。
           用户 2026-07-15 报「每次打开设置的字幕翻译每次都会卡」:
           核层那边是元凶(whisper_deps 同步 spawn 子进程 + 命令跑在主线程,已改 async+缓存),
           但这里串行 await 把四次往返摞成一条链,等于把那个卡再放大四倍。 */
        const [cur, status, m, d] = await Promise.all([
          getTranslationSettings(),
          translationEngineStatus(),
          whisperModels(),
          whisperDeps(),
        ]);
        if (!alive) return;
        setS(cur as unknown as TrSettings);
        setSt(status);
        setModels(m as unknown as WhisperRow[]);
        setDeps(d as unknown as WhisperDeps);
      } catch (e) {
        f.err(e);
      }
    })();
    /* core 用 emit 推下载进度(whisper-download / ffmpeg-download,载荷 [done,total,pct])。
       listen 是异步注册,卸载时要 await 到 unlisten 再摘,否则漏监听。 */
    const off: Array<() => void> = [];
    listen<[number, number, number]>("whisper-download", (e) =>
      setProg({ what: "模型", pct: e.payload[2] }),
    ).then((u) => (alive ? off.push(u) : u()));
    listen<[number, number, number]>("ffmpeg-download", (e) =>
      setProg({ what: "ffmpeg", pct: e.payload[2] }),
    ).then((u) => (alive ? off.push(u) : u()));
    return () => {
      alive = false;
      off.forEach((u) => u());
    };
  }, []);

  /** 改完即存 + 重读状态点(engine_status 是从**磁盘**重新 load 的,不存就永远是旧的)。 */
  async function commit(patch: Partial<TrSettings>) {
    if (!s) return;
    const next = { ...s, ...patch };
    setS(next);
    try {
      await setTranslationSettings(next);
      setSt(await translationEngineStatus());
      f.ok("已保存");
    } catch (e) {
      f.err(e);
    }
  }
  /** 输入框:边打字只动本地态,blur 才落盘(照 PlaybackPane 的 onBlur 模式)。 */
  const edit = (patch: Partial<TrSettings>) => setS((p) => (p ? { ...p, ...patch } : p));

  async function dl(key: string) {
    if (busy) return;
    setBusy(key);
    setProg({ what: "模型", pct: 0 });
    try {
      await whisperDownload(key);
      await refreshWhisper();
      f.ok("模型已下载");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
      setProg(null);
    }
  }
  async function rm(key: string) {
    if (busy) return;
    setBusy(key);
    try {
      await whisperDelete(key);
      await refreshWhisper();
      f.ok("模型已删除");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }
  async function getFfmpeg() {
    if (busy) return;
    setBusy("ffmpeg");
    setProg({ what: "ffmpeg", pct: 0 });
    try {
      /* Linux 是 .tar.xz、core 解不了会返明确错误 —— 原样抛给用户,别吞成「失败」。 */
      await whisperDownloadFfmpeg();
      await refreshWhisper();
      f.ok("ffmpeg 已就绪");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
      setProg(null);
    }
  }

  if (!s) {
    /* f.node 必须挂在**加载分支里**:读取失败时 s 恒为 null,若这里不挂,
       错误 toast 根本没被 mount —— 用户只看到「读取中…」转到天荒地老,
       真正的原因被界面吞了。下面 CF / 多线程加载同理。 */
    return (
      <div className="mdpane">
        <h4>字幕翻译</h4>
        <p className="hint">读取中…</p>
        {f.node}
      </div>
    );
  }

  const ai = s.engine === "openai" || s.engine === "anthropic";
  const baidu = s.engine === "baiduGeneral" || s.engine === "baiduLlm";
  const aiCfg = s.engine === "anthropic" ? s.anthropic : s.openai;
  const bdCfg = s.engine === "baiduLlm" ? s.baiduLlm : s.baiduGeneral;
  const setAi = (o: Partial<AiCfg>, save: boolean) => {
    const v = { ...aiCfg, ...o };
    (save ? commit : edit)(s.engine === "anthropic" ? { anthropic: v } : { openai: v });
  };
  const setBd = (o: Partial<BaiduCfg>, save: boolean) => {
    const v = { ...bdCfg, ...o };
    (save ? commit : edit)(s.engine === "baiduLlm" ? { baiduLlm: v } : { baiduGeneral: v });
  };
  const setTx = (o: Partial<TencentCfg>, save: boolean) =>
    (save ? commit : edit)({ tencent: { ...s.tencent, ...o } });

  return (
    <div className="mdpane">
      <h4>字幕翻译</h4>
      <p className="hint">
        字幕实时翻译 / 双语叠加。选一个引擎并填好密钥,状态点变绿即可用。
      </p>

      <div className="fld">
        <label>翻译引擎</label>
        <select
          className="field"
          style={{ cursor: "pointer" }}
          value={s.engine}
          onChange={(e) => commit({ engine: e.target.value })}
        >
          {TR_ENGINES.map((e) => (
            <option key={e.id} value={e.id}>
              {e.label}
            </option>
          ))}
        </select>
      </div>

      {/* 状态点:key 就是引擎 storage_key,绿=已配好(core build_engine 认它) */}
      <div className="st-dots">
        {TR_ENGINES.map((e) => (
          <span className="st-dotrow" key={e.id}>
            <i className={"st-dot" + (st[e.id] ? " on" : "")} />
            {e.label}
          </span>
        ))}
      </div>

      <div className="fld">
        <label>目标语言</label>
        <select
          className="field"
          style={{ cursor: "pointer" }}
          value={s.targetLang}
          onChange={(e) => commit({ targetLang: e.target.value })}
        >
          {TR_LANGS.map((l) => (
            <option key={l.id} value={l.id}>
              {l.label}
            </option>
          ))}
        </select>
      </div>

      <Row t="双语排版" d="译文与原文的上下关系">
        <Seg
          value={s.layout}
          opts={[
            { id: "translatedOnly", label: "仅译文" },
            { id: "translatedFirst", label: "译文在上" },
            { id: "originalFirst", label: "原文在上" },
          ]}
          onChange={(layout) => commit({ layout })}
        />
      </Row>

      <h4 style={{ marginTop: 20 }}>{TR_ENGINES.find((e) => e.id === s.engine)?.label} · 密钥</h4>
      <p className="hint">
        密钥与服务器 token 同等姿态<b>明文存本地配置文件</b>(核心行为,此端不另加密)。改完离开输入框即保存。
      </p>

      {ai && (
        <>
          <div className="fld">
            <label>接口地址</label>
            <input
              className="field"
              placeholder="https://api.openai.com/v1"
              value={aiCfg.baseUrl}
              onChange={(e) => setAi({ baseUrl: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          <div className="fld">
            <label>API Key</label>
            <input
              className="field"
              type="password"
              placeholder="sk-…"
              value={aiCfg.apiKey}
              onChange={(e) => setAi({ apiKey: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          <div className="fld">
            <label>模型</label>
            <input
              className="field"
              placeholder="gpt-4o-mini"
              value={aiCfg.model}
              onChange={(e) => setAi({ model: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
        </>
      )}

      {baidu && (
        <>
          <div className="fld">
            <label>APP ID</label>
            <input
              className="field"
              placeholder="百度翻译开放平台的 APPID"
              value={bdCfg.appId}
              onChange={(e) => setBd({ appId: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          {s.engine === "baiduGeneral" ? (
            <div className="fld">
              <label>密钥</label>
              <input
                className="field"
                type="password"
                placeholder="通用接口的密钥(签名用)"
                value={bdCfg.secretKey}
                onChange={(e) => setBd({ secretKey: e.target.value }, false)}
                onBlur={() => commit({})}
              />
            </div>
          ) : (
            <div className="fld">
              <label>API Key</label>
              <input
                className="field"
                type="password"
                placeholder="大模型接口的 Bearer API Key"
                value={bdCfg.apiKey}
                onChange={(e) => setBd({ apiKey: e.target.value }, false)}
                onBlur={() => commit({})}
              />
            </div>
          )}
          <div className="fld">
            <label>接口地址(可选)</label>
            <input
              className="field"
              placeholder="留空用官方地址"
              value={bdCfg.endpoint}
              onChange={(e) => setBd({ endpoint: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
        </>
      )}

      {s.engine === "tencent" && (
        <>
          <div className="fld">
            <label>SecretId</label>
            <input
              className="field"
              value={s.tencent.secretId}
              onChange={(e) => setTx({ secretId: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          <div className="fld">
            <label>SecretKey</label>
            <input
              className="field"
              type="password"
              value={s.tencent.secretKey}
              onChange={(e) => setTx({ secretKey: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
          <div className="fld">
            <label>地域</label>
            <input
              className="field"
              placeholder="ap-beijing"
              value={s.tencent.region}
              onChange={(e) => setTx({ region: e.target.value }, false)}
              onBlur={() => commit({})}
            />
          </div>
        </>
      )}

      <h4 style={{ marginTop: 22 }}>Whisper 离线转写</h4>
      <p className="hint">
        无字幕的片子先本地转写出原文再翻译。需要 whisper-cli 与 ffmpeg 两个可执行文件,
        模型按需下载(不预置)。
      </p>
      <Row t="启用 Whisper 转写">
        <Sw on={s.whisperEnabled} onChange={(v) => commit({ whisperEnabled: v })} />
      </Row>

      {/* 依赖状态:核层返回的是**路径或 null**,有路径才算就位 */}
      <div className="st-dots">
        <span className="st-dotrow">
          <i className={"st-dot" + (deps?.whisper ? " on" : "")} />
          whisper-cli {deps?.whisper ? "已就位" : "未找到"}
        </span>
        <span className="st-dotrow">
          <i className={"st-dot" + (deps?.ffmpeg ? " on" : "")} />
          ffmpeg {deps?.ffmpeg ? "已就位" : "未找到"}
          {!deps?.ffmpeg && (
            <button className="btn sm" disabled={!!busy} onClick={getFfmpeg} style={{ marginLeft: 10 }}>
              {busy === "ffmpeg" ? "下载中…" : "自动下载"}
            </button>
          )}
        </span>
      </div>

      <Row t="转写模型" d="越大越准也越慢;选中的档位需先下载">
        <Seg
          value={s.whisperModel}
          opts={[
            { id: "tiny", label: "Tiny" },
            { id: "base", label: "Base" },
            { id: "medium", label: "Medium" },
            { id: "large", label: "Large" },
          ]}
          onChange={(v) => commit({ whisperModel: v })}
        />
      </Row>

      {models?.map((m) => (
        <Row
          key={m.key}
          t={m.display_name}
          d={m.downloaded ? `已下载 · ${fmtSize(m.downloaded_bytes)}` : m.size_label}
        >
          {m.downloaded ? (
            <button className="btn" disabled={!!busy} onClick={() => rm(m.key)}>
              删除
            </button>
          ) : (
            <button className="btn primary" disabled={!!busy} onClick={() => dl(m.key)}>
              {busy === m.key ? "下载中…" : "下载"}
            </button>
          )}
        </Row>
      ))}

      {prog && (
        <div className="st-prog">
          <span className="spinner" /> 正在下载{prog.what} {prog.pct.toFixed(1)}%
          <span className="bar">
            <i style={{ width: `${Math.min(100, prog.pct)}%` }} />
          </span>
        </div>
      )}

      <div className="fld" style={{ marginTop: 14 }}>
        <label>模型下载镜像(可选)</label>
        <input
          className="field"
          placeholder="留空用 Hugging Face 官方源"
          value={s.whisperMirror}
          onChange={(e) => edit({ whisperMirror: e.target.value })}
          onBlur={() => commit({})}
        />
      </div>
      <div className="fld">
        <label>whisper-cli 路径(可选)</label>
        <input
          className="field"
          placeholder="留空自动定位"
          value={s.whisperBinary}
          onChange={(e) => edit({ whisperBinary: e.target.value })}
          onBlur={() => commit({}).then(refreshWhisper)}
        />
      </div>
      <div className="fld">
        <label>ffmpeg 路径(可选)</label>
        <input
          className="field"
          placeholder="留空自动定位"
          value={s.ffmpegPath}
          onChange={(e) => edit({ ffmpegPath: e.target.value })}
          onBlur={() => commit({}).then(refreshWhisper)}
        />
      </div>
      {f.node}
    </div>
  );
}

/* ============================================================
   网络 · CF 优选加速
   ★ 粒度是**线路**,不是服务器(2026-08-01 改,用户原话:
     「不应该写『为哪台服务器优选』,而是『为哪条线路优选』…服务器有很多条线路,
      而且有些线路并没有使用 Cloudflare」)。
   核层的改写表键就是线路地址,cf_proxy_enable/disable 收的也是 lineUrl。
   按服务器开的旧口径会把该服**所有**线路劫持到同一个反代上,而反代上游 host 是开启时
   那条线定死的 —— 切到非 CF 线路后连得上、拉不到数据、还不报错。
   开/关都是热生效(核层内部 refresh_session_base),此处不必提示重启。
   ============================================================ */

/** 摊平成「一台服的一条线」。lines 为空 = 核层的单线路形态,用 line_url 顶一条主线出来。 */
type LineOpt = { key: string; url: string; serverName: string; lineName: string };
function flattenLines(accts: AccountInfo[]): LineOpt[] {
  const out: LineOpt[] = [];
  for (const a of accts) {
    const serverName = a.name || hostOf(a.server) || a.server;
    if (a.lines.length === 0) {
      out.push({ key: a.line_url, url: a.line_url, serverName, lineName: "主线" });
      continue;
    }
    for (const l of a.lines) {
      out.push({ key: `${a.server}|${l.url}`, url: l.url, serverName, lineName: l.name || "线路" });
    }
  }
  return out;
}

function CfPane() {
  const f = useFlash();
  const [accts, setAccts] = useState<AccountInfo[] | null>(null);
  const [rows, setRows] = useState<CfProxyStatus[]>([]);
  const [ips, setIps] = useState<CfTestResult[] | null>(null);
  const [pick, setPick] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  /** 选中的**线路地址**。测速的 validate_host 用它的域名剔掉「TCP 通但 HTTP 死」的边缘。 */
  const [target, setTarget] = useState("");

  const reload = async () => {
    const [a, r] = await Promise.all([listAccounts(), cfProxyStatus()]);
    setAccts(a);
    setRows(r);
    setTarget((t) => t || flattenLines(a)[0]?.url || "");
  };

  useEffect(() => {
    reload().catch(f.err);
  }, []);

  const lines = useMemo(() => flattenLines(accts ?? []), [accts]);
  const cur = lines.find((l) => l.url === target);

  async function test() {
    if (busy) return;
    setBusy("test");
    setIps(null);
    try {
      /* 测速拿**这条线路自己**的域名去校验 —— 换成别的线路的域名就等于在验错东西:
         那台边缘可能对 A 域名活、对 B 域名死,而我们要开的是 B。 */
      const res = await cfSpeedTest(hostOf(cur?.url ?? "") || null, null);
      setIps(res);
      setPick(res[0]?.ip ?? "");
      f.ok(res.length ? `测到 ${res.length} 个可用 IP` : "没测到可用 IP");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  async function enable(lineUrl: string, ip: string) {
    if (busy || !ip) return;
    setBusy(lineUrl);
    try {
      const url = await cfProxyEnable(lineUrl, ip);
      await reload();
      f.ok(`已启用 · ${url}`);
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  async function disable(lineUrl: string) {
    if (busy) return;
    setBusy(lineUrl);
    try {
      await cfProxyDisable(lineUrl);
      await reload();
      f.ok("已关闭,恢复直连");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(null);
    }
  }

  if (!accts) {
    return (
      <div className="mdpane">
        <h4>CF 优选加速</h4>
        <p className="hint">读取中…</p>
        {f.node}
      </div>
    );
  }

  return (
    <div className="mdpane">
      <h4>CF 优选加速</h4>
      <p className="hint">
        测出延迟低的 Cloudflare 边缘 IP,起一个本地反代把**这条线路**的 API / 封面 / 取流
        全部钉到这个 IP。同一台服的其它线路不受影响 —— 没走 Cloudflare 的线路照旧直连。
        开关即时生效,无需重启。
      </p>

      {lines.length === 0 && <p className="hint">还没有服务器,先去服务器页添加。</p>}

      {lines.length > 0 && (
        <>
          <div className="fld">
            <label>为哪条线路优选</label>
            <select
              className="field"
              style={{ cursor: "pointer" }}
              value={target}
              onChange={(e) => {
                setTarget(e.target.value);
                setIps(null); // 换线就得重测:边缘对上一条线的域名活,不代表对这条也活
              }}
            >
              {accts.map((a) => (
                <optgroup key={a.server} label={a.name || hostOf(a.server) || a.server}>
                  {(a.lines.length
                    ? a.lines.map((l) => ({ url: l.url, name: l.name || "线路" }))
                    : [{ url: a.line_url, name: "主线" }]
                  ).map((l) => (
                    <option key={l.url} value={l.url}>
                      {l.name} · {hostOf(l.url) || l.url}
                    </option>
                  ))}
                </optgroup>
              ))}
            </select>
          </div>

          <div className="st-actions" style={{ marginTop: 8 }}>
            <button className="btn primary" disabled={!!busy || !cur} onClick={test}>
              {busy === "test" ? "测速中…" : "开始测速"}
            </button>
            {busy === "test" && <span className="spinner" />}
            {f.node}
          </div>
        </>
      )}

      {ips && ips.length > 0 && (
        <>
          <div className="fld" style={{ marginTop: 14 }}>
            <label>候选 IP(已按优劣排序,最优在前)</label>
            <select
              className="field"
              style={{ cursor: "pointer" }}
              value={pick}
              onChange={(e) => setPick(e.target.value)}
            >
              {ips.map((r) => (
                <option key={r.ip} value={r.ip}>
                  {r.ip} · {r.latency_ms}ms · 丢包 {(r.loss_rate * 100).toFixed(0)}%
                  {r.download_kbps ? ` · ${(r.download_kbps / 1024).toFixed(1)} MB/s` : ""}
                </option>
              ))}
            </select>
          </div>
          <div className="st-actions" style={{ marginTop: 8 }}>
            <button
              className="btn primary"
              disabled={!!busy || !pick || !cur}
              onClick={() => cur && enable(cur.url, pick)}
            >
              {busy === cur?.url ? "启用中…" : "为这条线路启用"}
            </button>
          </div>
        </>
      )}
      {ips && ips.length === 0 && (
        <p className="hint" style={{ marginTop: 12 }}>
          没测到可用 IP —— 可能是网络封锁,或**这条线路**不在 Cloudflare 后面
          (那就别给它开优选,换一条走 CF 的线)。
        </p>
      )}

      <h4 style={{ marginTop: 22 }}>当前生效的优选</h4>
      {rows.length === 0 ? (
        <p className="hint">还没有线路在走优选,全部直连。</p>
      ) : (
        rows.map((r) => {
          const a = accts.find((x) => x.server === r.server_id);
          const who = a?.name || hostOf(r.server_id) || r.server_id;
          return (
            <Row
              key={r.line_url}
              /* 标题必须带线路名 —— 同一台服可能有多条线各开各的优选,
                 只写服务器名会出现两行长得一模一样、分不清关哪条。 */
              t={`${who} · ${r.line_name || "线路"} (${hostOf(r.line_url) || r.line_url})`}
              d={`钉住 ${r.pinned_ip || "(未知)"} · 本地反代 ${r.local_url}`}
            >
              <button className="btn" disabled={!!busy} onClick={() => disable(r.line_url)}>
                {busy === r.line_url ? "处理中…" : "关闭"}
              </button>
            </Row>
          );
        })
      )}
    </div>
  );
}

/* ============================================================
   网络 · 多线程加载(预取代理)
   本地起代理超前拉 Range 喂播放器。核层对 threads(2~4)/cache_bytes(64MB~4GB)
   是**拒绝**不是夹紧 —— 所以这里绝不能先把值 clamp 好再提交:那样用户点到上限
   会毫无反应,而错误信息(「预取线程数只支持 2~4」)正是唯一的反馈来源。
   Stepper 的 min/max 只做常规引导,越界一律让核层说话。
   ============================================================ */
const MB = 1024 * 1024;
function PrefetchPane() {
  const f = useFlash();
  const [s, setS] = useState<PrefetchSettings | null>(null);
  // 开关按服务器给,所以得把账号表也拉来。只列 Emby 账号:预取只对 Emby 直传流生效,
  // 给网盘/浏览型源摆个永远不起作用的开关等于骗人。
  const [servers, setServers] = useState<AccountInfo[]>([]);
  // CF 优选状态一起拉:两者叠着用才是完全体(优选解决「连得快」,多线程解决「喂得满」),
  // 所以要让用户在这一页就看见哪台服已经开了优选,而不是靠他自己去另一页对。
  const [cfOn, setCfOn] = useState<Set<string>>(new Set());

  useEffect(() => {
    let alive = true;
    Promise.all([getPrefetchSettings(), listAccounts(), cfProxyStatus()])
      .then(([v, accs, cf]) => {
        if (!alive) return;
        setS(v);
        setServers(accs.filter((a) => !a.is_file_browse));
        setCfOn(new Set(cf.map((c) => c.server_id)));
      })
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  /** 改完即存;核层拒了就回滚 UI 并把原话弹出来。 */
  async function commit(patch: Partial<PrefetchSettings>) {
    if (!s) return;
    const prev = s;
    const next = { ...s, ...patch };
    setS(next);
    try {
      await setPrefetchSettings(next);
      f.ok("已保存");
    } catch (e) {
      setS(prev);
      f.err(e);
    }
  }

  if (!s) {
    return (
      <div className="mdpane">
        <h4>多线程加载</h4>
        <p className="hint">读取中…</p>
        {f.node}
      </div>
    );
  }

  return (
    <div className="mdpane">
      {/* 说明一句话讲完。用户 2026-07-19:「那么多描述 看的眼睛都花了」。 */}
      <h4>多线程加载</h4>
      <p className="hint">多线程顺序拉流,缓解卡顿。按服务器开,默认全关。</p>
      {/* ★ 每行只显示服务器名称。**不显示线路、更不显示地址** —— 除了「线路管理」窗口,
          全端任何地方都不直接暴露线路地址(同 App.tsx / DetailPage 线路面板的口径)。
          开关本来就按服务器给:服主允许了,这台服的所有线路一起生效,没什么可选的。 */}
      {servers.length === 0 ? (
        <p className="hint">还没有 Emby 服务器;先添加账号再回来开。</p>
      ) : (
        servers.map((a) => (
          <Row
            key={a.server}
            t={a.name || hostOf(a.server)}
            d={cfOn.has(a.server) ? "CF 优选已开" : ""}
          >
            <Sw
              on={s.servers.includes(a.server)}
              onChange={(on) =>
                commit({
                  servers: on
                    ? [...s.servers, a.server]
                    : s.servers.filter((x) => x !== a.server),
                })
              }
            />
          </Row>
        ))
      )}
      <Row t="并发线程数" d="对每条播放连接生效;核心只接受 2~4,超出会被拒绝并提示">
        <Stepper
          value={s.threads}
          min={1}
          max={5}
          step={1}
          fmt={(v) => String(v)}
          onChange={(threads) => commit({ threads })}
        />
      </Row>
      <Row t="缓存上限" d="落盘的环形缓存,决定磁盘占用;拖回已看过的地方直接命中不重下。64MB~4GB">
        {/* 区间跟核层 PREFETCH_CACHE_MIN/MAX 对齐:超了核层会拒。
            别偷偷夹紧 —— 本页的规矩是越界让核层报错,不做「设了没反应」的静默欺骗。
            2026-07-19 从 16~32MB 放开:分段改落盘后这不再是每连接的内存占用。 */}
        <Stepper
          value={s.cache_bytes / MB}
          min={64}
          max={4096}
          step={64}
          fmt={(v) => (v >= 1024 ? `${(v / 1024).toFixed(v % 1024 ? 1 : 0)} GB` : `${v} MB`)}
          onChange={(v) => commit({ cache_bytes: v * MB })}
        />
      </Row>
      {f.node}
    </div>
  );
}

/* ============================================================
   网络 · 预加载
   ★ 和上面的「多线程加载」是**两个功能**,用户 2026-08-01 专门点名过它们不一样:
     多线程加载 = 播放**中**在本地起代理超前拉 Range 喂 mpv,数据落环形缓存;
     预加载     = 播放**前**(进详情页)把头 N MB + 尾 2MB 跑热,读完即丢,不改播放地址。
   所以这里是独立一栏,不能并进上面那栏。
   头部量核层是**拒绝**不是夹紧(>512MB 报错),Stepper 的 max 只做引导。
   ============================================================ */
function PreloadPane() {
  const f = useFlash();
  const [s, setS] = useState<PreloadSettings | null>(null);

  useEffect(() => {
    let alive = true;
    getPreloadSettings()
      .then((v) => alive && setS(v))
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  async function commit(patch: Partial<PreloadSettings>) {
    if (!s) return;
    const prev = s;
    const next = { ...s, ...patch };
    setS(next);
    try {
      await setPreloadSettings(next);
      f.ok("已保存");
    } catch (e) {
      setS(prev);
      f.err(e);
    }
  }

  if (!s) {
    return (
      <div className="mdpane">
        <h4>预加载</h4>
        <p className="hint">读取中…</p>
        {f.node}
      </div>
    );
  }

  return (
    <div className="mdpane">
      <h4>预加载</h4>
      <p className="hint">
        进详情页就把片头先下到本地,起播时<b>预热了多少就直接放多少</b>,不用重下一遍。
        和「多线程加载」不是一回事:那个管播放中喂得满,这个管起播快。两者共用同一份本地缓存,
        所以<b>开着预加载时,起播一律经过本地缓存</b>(多线程加载关着也一样,只是并发连接更少)。
      </p>
      <Row t="启用预加载" d="默认开;计费网络可关(关掉后起播行为完全同以前)">
        <Sw on={s.enabled} onChange={(enabled) => commit({ enabled })} />
      </Row>
      <Row
        t="预热头部"
        d="这部分会留在本地缓存里,起播直接用。尾部另外热 2MB(MKV 索引在末尾,起播第一跳就读它),只跑热不留存。0 = 只热尾部"
      >
        <Stepper
          value={s.head_mb}
          min={0}
          max={512}
          step={16}
          fmt={(v) => (v === 0 ? "关" : `${v} MB`)}
          onChange={(head_mb) => commit({ head_mb })}
        />
      </Row>
      {f.node}
    </div>
  );
}

/* ============================================================
   网络 · 代理设置
   ============================================================ */
const PROXY_TYPES: { id: string; label: string }[] = [
  { id: "none", label: "直连" },
  { id: "http", label: "HTTP" },
  { id: "https", label: "HTTPS" },
  { id: "socks5", label: "SOCKS5" },
  { id: "socks4", label: "SOCKS4" },
];
function ProxyPane() {
  const f = useFlash();
  const [type, setType] = useState("none");
  const [host, setHost] = useState("");
  const [port, setPort] = useState("");
  const [username, setUsername] = useState("");
  const [password, setPassword] = useState("");
  const [proxyMedia, setProxyMedia] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const off = type === "none";

  useEffect(() => {
    let alive = true;
    getProxy()
      .then((c) => {
        if (!alive) return;
        setType(c.type || "none");
        setHost(c.host);
        setPort(c.port ? String(c.port) : "");
        setUsername(c.username);
        setPassword(c.password);
        setProxyMedia(c.proxy_media);
        setLoaded(true);
      })
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  /* pin 31「改完即生效」:输入框 blur、分段/开关点按即落盘,不留「保存」按钮。
     原先「播放流也走代理」只 setState 不落盘 —— 拨一下走开就没了,还什么都不报。
     所有 setter 都必须经过这里,别再出现只动 React 态的分支。 */
  async function save(next?: Partial<ProxyConfig>) {
    if (!loaded) return; // 读回来之前别用初值把磁盘上的配置覆盖成空
    try {
      await setProxy({
        type,
        host: host.trim(),
        port: Number(port) || 0,
        username: username.trim(),
        password,
        proxy_media: proxyMedia,
        ...next,
      });
      f.ok("已保存");
    } catch (e) {
      f.err(e);
    }
  }

  return (
    <div className="mdpane">
      <h4>代理设置</h4>
      <p className="hint">
        为元数据与登录请求走代理。选「直连」则不走代理。改完离开输入框即保存。
      </p>
      <div className="fld">
        <label>代理类型</label>
        <Seg
          value={type}
          opts={PROXY_TYPES}
          onChange={(v) => {
            setType(v);
            save({ type: v });
          }}
        />
      </div>
      <div className="fld">
        <label>服务器</label>
        <div style={{ display: "flex", gap: 10 }}>
          <input
            className="field"
            placeholder="127.0.0.1"
            value={host}
            disabled={off || !loaded}
            onChange={(e) => setHost(e.target.value)}
            onBlur={() => save()}
          />
          <input
            className="field"
            style={{ flex: "0 0 110px" }}
            placeholder="7890"
            inputMode="numeric"
            value={port}
            disabled={off || !loaded}
            onChange={(e) => setPort(e.target.value.replace(/[^0-9]/g, ""))}
            onBlur={() => save()}
          />
        </div>
      </div>
      <div className="fld">
        <label>认证(可选)</label>
        <div style={{ display: "flex", gap: 10 }}>
          <input
            className="field"
            placeholder="用户名"
            value={username}
            disabled={off || !loaded}
            onChange={(e) => setUsername(e.target.value)}
            onBlur={() => save()}
          />
          <input
            className="field"
            type="password"
            placeholder="密码"
            value={password}
            disabled={off || !loaded}
            onChange={(e) => setPassword(e.target.value)}
            onBlur={() => save()}
          />
        </div>
      </div>
      <Row t="播放流也走代理" d="开启后视频流量也经代理(可能拖慢直连)">
        <Sw
          on={proxyMedia}
          disabled={off || !loaded}
          onChange={(v) => {
            setProxyMedia(v);
            save({ proxy_media: v });
          }}
        />
      </Row>
      <div className="st-actions">{f.node}</div>
    </div>
  );
}

/* ============================================================
   同步 · 同步记录 · 跨服聚合
   跨服续播开关(核层默认**关**)+ 回传三项。回传 range 核层对未知值是**拒绝**
   不是回落 —— 因为静默回落 "all" 会让选了「仅初次」的用户在写所有服务器。
   所以错误必须原样弹出来。

   ponytail: 观看记录列表(watch_history_list/delete)本该也在这个面板里,但 api.ts
   的这两个绑定与核层对不上、**调用必然报错**,而本任务不许改 api.ts:
     · watch_history_list 核层签名是 (current_only: bool),api.ts 一个参数都没传;
     · watch_history_delete 核层参数是 record_id(线上 recordId),api.ts 传的是 key。
   宁可先不做,也不做一个一进来就报错的列表 —— 等 api.ts 修好再补,别在这儿绕过封装。
   ============================================================ */
const WB_RANGES = [
  { id: "all", label: "所有服务器" },
  { id: "first", label: "仅初次" },
  { id: "latest", label: "仅最新" },
];
function SyncPane() {
  const f = useFlash();
  const [resume, setResume] = useState<boolean | null>(null);
  const [wb, setWb] = useState<WritebackSettings | null>(null);

  useEffect(() => {
    let alive = true;
    getCrossServerResume()
      .then((v) => alive && setResume(v))
      .catch(f.err);
    getWritebackSettings()
      .then((v) => alive && setWb(v))
      .catch(f.err);
    return () => {
      alive = false;
    };
  }, []);

  async function toggleResume(v: boolean) {
    const prev = resume;
    setResume(v);
    try {
      await setCrossServerResume(v);
      f.ok("已保存");
    } catch (e) {
      setResume(prev);
      f.err(e);
    }
  }

  async function commitWb(patch: Partial<WritebackSettings>) {
    if (!wb) return;
    const prev = wb;
    const next = { ...wb, ...patch };
    setWb(next);
    try {
      await setWritebackSettings(next);
      f.ok("已保存");
    } catch (e) {
      setWb(prev); // 被拒了就退回去,别让 UI 显示一个没存进去的选项
      f.err(e);
    }
  }

  return (
    <div className="mdpane">
      <h4>同步记录 · 跨服聚合</h4>
      <p className="hint">
        同一部片存在于多台服务器时,如何合并观看进度与已看状态。
      </p>

      <Row t="跨服务器续播" d="在任意一台看过,换台服务器接着看(取最大进度)。默认关闭">
        <Sw on={resume ?? false} disabled={resume === null} onChange={toggleResume} />
      </Row>

      <h4 style={{ marginTop: 20 }}>观看状态回传</h4>
      <p className="hint">看完一集后,把已看状态回写到其它拥有同一部片的服务器。</p>
      <Row t="启用回传">
        <Sw
          on={wb?.enabled ?? false}
          disabled={!wb}
          onChange={(enabled) => commitWb({ enabled })}
        />
      </Row>
      <Row t="回传范围" d="回写到哪些服务器">
        <Seg
          value={wb?.range ?? "all"}
          opts={WB_RANGES}
          onChange={(range) => commitWb({ range })}
        />
      </Row>
      <Row t="连播放进度一起回传" d="关闭则只回传「已看 / 未看」,不同步具体秒数">
        <Sw
          on={wb?.include_progress ?? false}
          disabled={!wb}
          onChange={(include_progress) => commitWb({ include_progress })}
        />
      </Row>
      {f.node}
    </div>
  );
}

/* ============================================================
   同步 · Trakt / Bangumi
   ============================================================ */
function TraktBlock() {
  const f = useFlash();
  const [acct, setAcct] = useState<SyncAccount | null>(null);
  const [code, setCode] = useState<TraktDeviceCode | null>(null);
  const [busy, setBusy] = useState(false);
  const timer = useRef<ReturnType<typeof setInterval> | null>(null);

  const stopPoll = () => {
    if (timer.current) clearInterval(timer.current);
    timer.current = null;
  };

  useEffect(() => {
    traktAccount().then(setAcct).catch(f.err);
    return stopPoll; // 卸载清定时器
  }, []);

  async function connect() {
    if (busy) return;
    setBusy(true);
    try {
      const dc = await traktDeviceCode();
      setCode(dc);
      stopPoll();
      timer.current = setInterval(async () => {
        try {
          const r = await traktPoll(dc.device_code);
          if (r.account) {
            stopPoll();
            setCode(null);
            setAcct(await traktAccount());
            f.ok("Trakt 已连接");
          }
        } catch (e) {
          stopPoll();
          setCode(null);
          f.err(e);
        }
      }, Math.max(1, dc.interval) * 1000);
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  async function disconnect() {
    try {
      await traktLogout();
      setAcct(null);
      f.ok("已断开 Trakt");
    } catch (e) {
      f.err(e);
    }
  }

  return (
    <>
      <Row t="Trakt" d={acct ? `已连接 · ${acct.username ?? "已授权"}` : "自动同步观看进度与收藏"}>
        {acct ? (
          <button className="btn" onClick={disconnect}>
            断开
          </button>
        ) : (
          <button className="btn primary" disabled={busy || !!code} onClick={connect}>
            {busy ? "获取中…" : "连接"}
          </button>
        )}
      </Row>
      {code && (
        <div className="st-auth">
          <p className="hint" style={{ margin: "0 0 10px" }}>
            浏览器打开下方地址,输入验证码完成授权:
          </p>
          <div className="st-copyrow" style={{ marginBottom: 12 }}>
            <input className="field" readOnly value={code.verification_url} />
            <button
              className="btn"
              onClick={() => {
                copy(code.verification_url);
                f.ok("已复制");
              }}
            >
              复制
            </button>
          </div>
          <div className="st-code">{code.user_code}</div>
          <div className="st-poll">
            <span className="spinner" /> 等待授权中,授权后自动完成…
          </div>
        </div>
      )}
      {f.node}
    </>
  );
}

function BangumiBlock() {
  const f = useFlash();
  const [acct, setAcct] = useState<SyncAccount | null>(null);
  const [authUrl, setAuthUrl] = useState("");
  const [code, setCode] = useState("");
  const [token, setToken] = useState("");
  const [tokenMode, setTokenMode] = useState(false);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    bangumiAccount().then(setAcct).catch(f.err);
  }, []);

  /* Access Token 直连。OAuth 那条要复制地址→浏览器授权→回粘 code,三步;
     Bangumi 官方提供了自助生成长期 token 的页面(next.bgm.tv/demo/access-token),
     粘一次就完事。核层 bangumi_login_token 会立刻打一次 /v0/me 验真伪,
     废 token 存不进配置。TV 端早就有这个入口,桌面这边一直漏着。 */
  async function submitToken() {
    if (busy || !token.trim()) return;
    setBusy(true);
    try {
      await bangumiLoginToken(token.trim());
      setAcct(await bangumiAccount());
      setToken("");
      setTokenMode(false);
      setAuthUrl("");
      f.ok("Bangumi 已连接");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  async function begin() {
    if (busy) return;
    setBusy(true);
    try {
      setAuthUrl(await bangumiAuthorizeUrl());
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  async function submit() {
    if (busy || !code.trim()) return;
    setBusy(true);
    try {
      await bangumiExchange(code.trim());
      setAcct(await bangumiAccount());
      setAuthUrl("");
      setCode("");
      f.ok("Bangumi 已连接");
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  async function disconnect() {
    try {
      await bangumiLogout();
      setAcct(null);
      f.ok("已断开 Bangumi");
    } catch (e) {
      f.err(e);
    }
  }

  return (
    <>
      <Row t="Bangumi" d={acct ? `已连接 · ${acct.username ?? "已授权"}` : "同步在看状态与收藏"}>
        {acct ? (
          <button className="btn" onClick={disconnect}>
            断开
          </button>
        ) : (
          <>
            <button
              className="btn"
              disabled={busy}
              onClick={() => {
                setTokenMode((v) => !v);
                setAuthUrl("");
              }}
            >
              用 Token
            </button>
            <button className="btn primary" disabled={busy || !!authUrl} onClick={begin}>
              {busy ? "获取中…" : "连接"}
            </button>
          </>
        )}
      </Row>
      {tokenMode && !acct && (
        <div className="st-auth">
          <p className="hint" style={{ margin: "0 0 10px" }}>
            在 next.bgm.tv/demo/access-token 生成一个 Access Token,粘到下方即可(不必走 OAuth):
          </p>
          <div className="st-copyrow">
            <input
              className="field"
              placeholder="粘贴 Access Token"
              value={token}
              onChange={(e) => setToken(e.target.value)}
              onKeyDown={(e) => {
                if (e.key === "Enter") submitToken();
              }}
            />
            <button className="btn primary" disabled={busy || !token.trim()} onClick={submitToken}>
              {busy ? "校验中…" : "连接"}
            </button>
          </div>
        </div>
      )}
      {authUrl && (
        <div className="st-auth">
          <p className="hint" style={{ margin: "0 0 10px" }}>
            浏览器打开授权地址,授权后把回调里的 code 粘到下方提交:
          </p>
          <div className="st-copyrow" style={{ marginBottom: 12 }}>
            <input className="field" readOnly value={authUrl} />
            <button
              className="btn"
              onClick={() => {
                copy(authUrl);
                f.ok("已复制");
              }}
            >
              复制
            </button>
          </div>
          <div className="st-copyrow">
            <input
              className="field"
              placeholder="粘贴授权 code"
              value={code}
              onChange={(e) => setCode(e.target.value)}
            />
            <button className="btn primary" disabled={busy || !code.trim()} onClick={submit}>
              提交
            </button>
          </div>
        </div>
      )}
      {f.node}
    </>
  );
}

function AccountPane() {
  return (
    <div className="mdpane">
      <h4>Trakt / Bangumi</h4>
      <p className="hint">连接第三方追剧服务,观看进度与收藏自动同步。</p>
      <TraktBlock />
      <BangumiBlock />
    </div>
  );
}

/* 追剧日历已提到侧栏(用户 2026-07-16「不需要放在设置里面」),原 CalendarPane 移除。 */

/* ============================================================
   其它 · 更新 · 备份 · 关于
   ============================================================ */
/* ============================================================
   其它 · 存储与数据目录
   ------------------------------------------------------------
   这一页存在的唯一理由:用户 2026-07-17「我不知道你放哪里了 我不希望软件乱拉」。
   重构前数据散在 6 个根(Roaming/Local/identifier 目录/%TEMP% 散文件/exe 同级),
   而 UI 里一个字都没提过 —— 路径不摆出来,再干净的目录结构用户也不知道。
   ============================================================ */
/* 已屏蔽的内容 —— **唯一一个能一次看全并逐条解除的地方**。

   为什么必须有它:屏蔽的东西按设计会从首页/搜索/播放记录里消失,能解除它的地方
   只剩「原来那张卡片」。库被屏蔽后要去媒体库页找,条目被屏蔽后要去它所在的库里翻——
   用户 2026-08-02 屏蔽完两个媒体库后直接问「那我怎么恢复呢?」,那一问就是答案:
   一个不在这儿的清单,等于没有退路。 */
function BlockedPane() {
  const [list, setList] = useState<BlockedItem[] | null>(null);
  const [busy, setBusy] = useState("");

  const load = () => blockedList().then(setList).catch(() => setList([]));
  useEffect(() => {
    void load();
  }, []);

  const unblock = async (b: BlockedItem) => {
    setBusy(b.id);
    try {
      await setBlocked(b.id, b.name, false);
      setList((cur) => (cur ? cur.filter((x) => x.id !== b.id) : cur));
    } catch {
      /* 失败就把列表重拉一次,别留个假的"已解除" */
      void load();
    } finally {
      setBusy("");
    }
  };

  return (
    <div className="mdpane">
      <h4>已屏蔽的内容</h4>
      <p className="hint">
        屏蔽的条目不在首页显示,也不出现在搜索结果和播放记录里;屏蔽的媒体库不在首页显示。
        媒体库页仍然列出它们(打「已屏蔽」标)可以右键解除 —— 这里是一次看全、逐条解除的地方。
      </p>
      {list === null ? (
        <p className="hint">加载中…</p>
      ) : list.length === 0 ? (
        <p className="hint">还没有屏蔽任何内容。在首页或媒体库右键一张卡片(手机/TV 长按)即可屏蔽。</p>
      ) : (
        list.map((b) => (
          <Row key={b.id} t={b.name} d={b.at ? new Date(b.at).toLocaleString("zh-CN") : ""}>
            <button className="btn" disabled={busy === b.id} onClick={() => void unblock(b)}>
              解除屏蔽
            </button>
          </Row>
        ))
      )}
    </div>
  );
}

function StoragePane() {
  const f = useFlash();
  const [p, setP] = useState<DataPaths | null>(null);
  const [size, setSize] = useState<number | null>(null);
  const [busy, setBusy] = useState(false);
  const [shot, setShot] = useState<ScreenshotDir | null>(null);
  const [shotEdit, setShotEdit] = useState("");

  /** 存截图目录(null=恢复默认)。核层会建目录验证可写,失败原样弹出来不吞。 */
  function saveShotDir(dir: string | null) {
    setScreenshotDir(dir)
      .then((v) => {
        setShot(v);
        setShotEdit(v.dir ?? "");
        f.ok(v.dir ? "已保存" : "已恢复默认");
      })
      .catch(f.err);
  }

  async function refresh() {
    try {
      setP(await dataPaths());
      const sd = await getScreenshotDir();
      setShot(sd);
      setShotEdit(sd.dir ?? "");
      setSize(null); // 先清空:统计要遍历目录,别让旧数字冒充新结果
      setSize(await cacheSize());
    } catch (e) {
      f.err(e);
    }
  }
  useEffect(() => {
    void refresh();
  }, []);

  async function doClear() {
    if (busy) return;
    setBusy(true);
    try {
      await clearCache();
      f.ok("缓存已清空");
      setSize(await cacheSize());
    } catch (e) {
      f.err(e);
    } finally {
      setBusy(false);
    }
  }

  /* 单行显示,过长省略号收尾,hover 看全文。样式在 .st-pathrow > code(SettingsPage.css)。
     原来是 wordBreak:"break-all" 让它换行 —— 一行路径折成三行,整页糊成一团。 */
  const Path = ({ v }: { v: string }) => (
    <code className="muted" title={v}>
      {v}
    </code>
  );

  const KIND_NOTE: Record<RootKind, string> = {
    Portable: "删掉这个文件夹即卸载干净",
    Overridden: "由 LP_DATA_DIR 指定",
    SystemFallback: "程序目录不可写,数据落在系统目录",
  };

  return (
    <div className="mdpane">
      <h4>存储与数据目录</h4>
      <p className="hint">数据全在程序目录的 userdata/ 里。</p>
      {f.node}

      {p?.kind === "SystemFallback" && (
        <p className="hint" style={{ color: "var(--warn, #e0a030)" }}>
          ⚠️ 程序目录写不进去,数据放在了系统目录 —— 删程序文件夹清不干净。把整个文件夹移到 D 盘等可写位置再启动即可。
        </p>
      )}

      <Row t="数据根目录" d={p ? KIND_NOTE[p.kind] : ""}>
        <span className="st-pathrow">
          {p && <Path v={p.root} />}
          <button className="btn" onClick={() => p && copy(p.root)} disabled={!p}>
            复制
          </button>
          <button className="btn" onClick={() => openDataDir().catch(f.err)} disabled={!p}>
            打开
          </button>
        </span>
      </Row>
      <Row t="程序目录" d="">
        <span className="st-pathrow">{p && <Path v={p.exe_dir} />}</span>
      </Row>

      <Row t="设置 · 账号" d="账号与偏好">
        <span className="st-pathrow">{p && <Path v={p.config} />}</span>
      </Row>
      <Row t="用户数据" d="观看记录 / 插件 / 模型">
        <span className="st-pathrow">{p && <Path v={p.data} />}</span>
      </Row>
      <Row t="缓存" d="可随时清,会自动重建">
        <span className="st-pathrow">{p && <Path v={p.cache} />}</span>
      </Row>
      <Row t="临时文件" d="">
        <span className="st-pathrow">{p && <Path v={p.temp} />}</span>
      </Row>
      <Row t="浏览器内核数据" d="清缓存不会动它">
        <span className="st-pathrow">{p && <Path v={p.webview} />}</span>
      </Row>
      <Row t="日志" d="">
        <span className="st-pathrow">
          {p && <Path v={p.logs} />}
          <button className="btn" onClick={() => openDataDir("logs").catch(f.err)} disabled={!p}>
            打开
          </button>
        </span>
      </Row>
      <Row t="下载" d="默认下载目录">
        <span className="st-pathrow">
          {p && <Path v={p.downloads} />}
          <button className="btn" onClick={() => openDataDir("downloads").catch(f.err)} disabled={!p}>
            打开
          </button>
        </span>
      </Row>
      {/* 截图**故意**默认在包外:它是用户要拿去用的产物,塞进 userdata/ 反而难找。 */}
      <Row t="截图保存位置" d={shot?.dir ? "自定义" : "默认:系统图片文件夹"}>
        <span style={{ display: "flex", gap: 6, alignItems: "center" }}>
          {/* 路径框仍可手填(粘贴/网络路径比翻对话框快),但主路径是右边的原生选择器。 */}
          <input
            className="input"
            style={{ minWidth: 220 }}
            value={shotEdit}
            placeholder={shot?.effective ?? ""}
            onChange={(e) => setShotEdit(e.target.value)}
          />
          <button
            className="btn"
            onClick={() => {
              // 从当前生效目录起步,省得每次从盘符翻起。取消返回 null —— 什么都不做,别报错。
              pickDirectory(shotEdit.trim() || shot?.effective)
                .then((picked) => picked && saveShotDir(picked))
                .catch(f.err);
            }}
          >
            选择…
          </button>
          <button className="btn" onClick={() => saveShotDir(shotEdit.trim() || null)}>
            保存
          </button>
          {shot?.dir && (
            <button className="btn" onClick={() => saveShotDir(null)}>
              恢复默认
            </button>
          )}
        </span>
      </Row>

      <Row t="缓存占用" d="缓存 + 临时文件。账号 / 观看记录 / 下载 / 模型 / 界面设置都不受影响">
        <span style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <span className="muted">{size === null ? "统计中…" : fmtSize(size) || "0 B"}</span>
          <button className="btn" onClick={doClear} disabled={busy || size === null}>
            {busy ? "清理中…" : "清空缓存"}
          </button>
        </span>
      </Row>
    </div>
  );
}

/* 更新 · 双渠道。稳定版 = publish.yml 提升出的正式 Release;
   预览版 = build.yml 每次推 main 出的 -pre。两个渠道的定义落在 CI,不在这儿。 */
function UpdateSection() {
  const f = useFlash();
  const [st, setSt] = useState<UpdateSettings | null>(null);
  const [found, setFound] = useState<UpdateInfo | null | undefined>(undefined);
  const [checking, setChecking] = useState(false);
  const [progress, setProgress] = useState<[number, number] | null>(null);

  useEffect(() => {
    let alive = true;
    getUpdateSettings()
      .then((s) => alive && setSt(s))
      .catch(() => {});
    return () => {
      alive = false;
    };
  }, []);

  useEffect(() => {
    const un = listen<[number, number]>("update-download", (e) => setProgress(e.payload));
    return () => {
      un.then((f) => f());
    };
  }, []);

  async function save(patch: Partial<UpdateSettings>) {
    if (!st) return;
    const next = { ...st, ...patch };
    setSt(next); // 乐观更新
    try {
      await setUpdateSettings(next.channel, next.auto_check);
      // 换了渠道,上一次的检查结果就作废了(稳定/预览看到的根本不是同一个发布)。
      setFound(undefined);
    } catch (e) {
      setSt(st); // 回滚 —— 否则开关停在新值而磁盘是旧值
      f.err(e);
    }
  }

  async function doCheck() {
    if (checking) return;
    setChecking(true);
    try {
      const r = await checkUpdate();
      setFound(r);
      if (!r) f.ok("已是最新版本");
    } catch (e) {
      // 查不动 ≠ 已是最新。这里必须报错,不能显示「已是最新」。
      setFound(undefined);
      f.err(e);
    } finally {
      setChecking(false);
    }
  }

  async function doApply() {
    setProgress([0, found?.asset_size ?? 0]);
    try {
      await downloadAndApplyUpdate();
    } catch (e) {
      setProgress(null);
      f.err(e);
    }
  }

  // 核层有自己的默认值,前端别硬编码一份 —— 两份默认值早晚对不上。
  if (!st) return null;

  const pct =
    progress && progress[1] > 0 ? Math.floor((progress[0] / progress[1]) * 100) : null;

  return (
    <>
      <h4 style={{ marginTop: 22 }}>更新</h4>
      <p className="hint">
        稳定版只收正式发布;预览版会收到每次主干构建,尝鲜但可能不稳定。
      </p>

      <Row t="更新通道" d="改完下次检查即按新渠道走">
        <Seg<UpdateChannel>
          value={st.channel}
          opts={[
            { id: "stable", label: "稳定版" },
            { id: "prerelease", label: "预览版" },
          ]}
          onChange={(channel) => save({ channel })}
        />
      </Row>

      <Row t="启动时自动检查" d="关掉之后只剩下面的手动检查">
        <Sw on={st.auto_check} onChange={(auto_check) => save({ auto_check })} />
      </Row>

      {!st.can_self_update && (
        <p className="hint" style={{ color: "var(--warn, #d88)" }}>
          安装目录不可写(装进了 Program Files 之类的地方?),无法就地更新 ——
          检查到新版本后请手动下载覆盖。
        </p>
      )}

      {found && (
        <div className="st-card">
          <div className="st-kv">
            <span className="k">发现新版本</span>
            <span className="v">
              {found.tag}
              {found.prerelease ? "(预览版)" : ""}
            </span>
          </div>
          {found.notes && (
            <pre className="hint" style={{ whiteSpace: "pre-wrap", maxHeight: 180, overflow: "auto" }}>
              {found.notes}
            </pre>
          )}
          {!found.asset_name && (
            <p className="hint">这个版本没有适用于当前平台的安装包,请到发布页手动下载。</p>
          )}
        </div>
      )}

      <div className="st-actions">
        <button className="btn" disabled={checking || !!progress} onClick={doCheck}>
          {checking ? "检查中…" : "检查更新"}
        </button>
        {found?.asset_name && st.can_self_update && (
          <button className="btn primary" disabled={!!progress} onClick={doApply}>
            {progress ? (pct === null ? "下载中…" : `下载中 ${pct}%`) : "下载并安装"}
          </button>
        )}
        {found && (
          <button className="btn" onClick={() => openUrl(found.html_url)}>
            打开发布页
          </button>
        )}
        {f.node}
      </div>
      {progress && (
        <p className="hint">
          下载完成后会自动覆盖并重启,请不要手动关闭程序。
        </p>
      )}
    </>
  );
}

function AboutPane() {
  const f = useFlash();
  const [payload, setPayload] = useState("");
  const [qr, setQr] = useState("");
  const [qrErr, setQrErr] = useState("");
  const [importText, setImportText] = useState("");
  const [busyOut, setBusyOut] = useState(false);
  const [busyIn, setBusyIn] = useState(false);

  async function doExport() {
    if (busyOut) return;
    setBusyOut(true);
    setQr("");
    setQrErr("");
    try {
      const p = await configExportQr();
      setPayload(p);
      /* 核层的 config_export_qr 就是给「前端渲染成二维码」用的。
         但载荷是 AES+gzip 的服务器配置,账号一多就会超出二维码容量上限
         (纠错级 L 也就 ~2.9KB)—— toDataURL 会直接 reject。
         那不是 bug 是物理上限:此时如实说明并留文本载荷兜底,别静默不出图。 */
      try {
        setQr(await QRCode.toDataURL(p, { errorCorrectionLevel: "L", margin: 1, width: 260 }));
      } catch (e) {
        setQrErr(String(e));
      }
      f.ok("已生成迁移载荷");
    } catch (e) {
      f.err(e);
    } finally {
      setBusyOut(false);
    }
  }

  async function doImport() {
    if (busyIn || !importText.trim()) return;
    setBusyIn(true);
    try {
      const n = await configImportQr(importText.trim());
      f.ok(`已导入 ${n} 个账号`);
      setImportText("");
    } catch (e) {
      f.err(e);
    } finally {
      setBusyIn(false);
    }
  }

  return (
    <div className="mdpane">
      <h4>更新 · 备份 · 关于</h4>
      <p className="hint">应用信息、配置备份与迁移。</p>

      <div className="st-kv">
        <span className="k">应用</span>
        <span className="v">LinPlayer</span>
      </div>
      <div className="st-kv">
        <span className="k">版本</span>
        {/* 构建期注入,来源是 tauri.conf.json —— 和发行 zip 的版本号是同一个数。
            以前这里硬编码 "0.1.0",版本一升就开始撒谎。 */}
        <span className="v">{__APP_VERSION__}</span>
      </div>
      <div className="st-kv">
        <span className="k">技术栈</span>
        <span className="v">Rust 核 + Tauri + React</span>
      </div>

      <UpdateSection />

      <h4 style={{ marginTop: 22 }}>配置备份 · 迁移</h4>
      <p className="hint">
        在设备间搬运服务器配置(<b>含登录凭据</b>)—— 用另一台设备扫码,或复制文本载荷粘贴。
        二维码等同于账号密码,别外发、别截图上传。
      </p>
      <Row t="导出本机配置" d="生成 LPSYNC1 载荷,扫码或复制到另一台设备导入">
        <button className="btn" disabled={busyOut} onClick={doExport}>
          {busyOut ? "生成中…" : "导出"}
        </button>
      </Row>
      {qr && (
        <div className="st-qr">
          <img src={qr} alt="配置迁移二维码" width={260} height={260} />
          <p className="hint">用另一台设备的 LinPlayer 扫这个码即可搬运。</p>
        </div>
      )}
      {qrErr && (
        <p className="hint" style={{ marginTop: 12 }}>
          载荷太大,超出二维码容量上限,出不了图({qrErr})—— 用下面的文本载荷复制粘贴,
          或先删掉几台用不上的服务器再导出。
        </p>
      )}
      {payload && (
        <div className="fld" style={{ marginTop: 12 }}>
          <textarea className="field" readOnly rows={4} value={payload} />
          <div>
            <button
              className="btn"
              onClick={() => {
                copy(payload);
                f.ok("已复制到剪贴板");
              }}
            >
              复制载荷
            </button>
          </div>
        </div>
      )}
      <div className="fld" style={{ marginTop: 6 }}>
        <label>导入配置</label>
        <textarea
          className="field"
          rows={4}
          placeholder="粘贴另一台设备导出的 LPSYNC1:… 载荷"
          value={importText}
          onChange={(e) => setImportText(e.target.value)}
        />
        <div className="st-actions" style={{ marginTop: 8 }}>
          <button className="btn primary" disabled={busyIn || !importText.trim()} onClick={doImport}>
            {busyIn ? "导入中…" : "导入"}
          </button>
          {f.node}
        </div>
      </div>
    </div>
  );
}

/* ============================================================
   左目录分组(照草稿:通用 / 网络 / 同步账号 / 其它)
   ============================================================ */
type ItemDef = { id: string; label: string; icon: ReactNode };
const SECTIONS: { sec: string; items: ItemDef[] }[] = [
  {
    sec: "通用",
    items: [
      { id: "appearance", label: "外观与语言", icon: <IconSun size={16} /> },
      { id: "playback", label: "播放器", icon: <IconPlay size={16} /> },
      { id: "shortcuts", label: "快捷键", icon: <IconKeyboard size={16} /> },
      { id: "danmaku", label: "弹幕", icon: <IconLibrary size={16} /> },
      { id: "subtrans", label: "字幕翻译", icon: <IconFile size={16} /> },
    ],
  },
  {
    sec: "网络",
    items: [
      { id: "cf", label: "CF 优选加速", icon: <IconCloud size={16} /> },
      { id: "prefetch", label: "多线程加载", icon: <IconRefresh size={16} /> },
      { id: "preload", label: "预加载", icon: <IconDownload size={16} /> },
      { id: "proxy", label: "代理设置", icon: <IconServer size={16} /> },
    ],
  },
  {
    sec: "同步 / 账号",
    items: [
      { id: "sync", label: "同步记录 · 跨服聚合", icon: <IconRefresh size={16} /> },
      { id: "account", label: "Trakt / Bangumi", icon: <IconHeart size={16} /> },
    ],
  },
  {
    sec: "其它",
    items: [
      { id: "blocked", label: "已屏蔽的内容", icon: <IconEyeOff size={16} /> },
      { id: "storage", label: "存储与数据目录", icon: <IconFile size={16} /> },
      { id: "about", label: "更新 · 备份 · 关于", icon: <IconInfo size={16} /> },
    ],
  },
];

const LABELS: Record<string, string> = Object.fromEntries(
  SECTIONS.flatMap((s) => s.items).map((i) => [i.id, i.label]),
);

export default function SettingsPage({ theme, setTheme }: Props) {
  const [active, setActive] = useState("appearance");
  const [q, setQ] = useState("");

  // 搜索:本地过滤左栏项(诚实 —— 仅筛目录,不搜项内文案)。
  const sections = useMemo(() => {
    const kw = q.trim().toLowerCase();
    if (!kw) return SECTIONS;
    return SECTIONS.map((s) => ({
      ...s,
      items: s.items.filter((i) => i.label.toLowerCase().includes(kw)),
    })).filter((s) => s.items.length);
  }, [q]);

  return (
    <>
      <div className="cbar">
        <span className="crumb">
          <b>设置</b>
          <span className="sep">›</span>
          {LABELS[active] ?? ""}
        </span>
        <span className="push">
          <label className="searchbox">
            <IconSearch size={13} />
            <input
              value={q}
              onChange={(e) => setQ(e.target.value)}
              placeholder="搜索设置项…"
              style={{
                background: "transparent",
                border: "none",
                outline: "none",
                color: "var(--ink)",
                width: "100%",
                font: "inherit",
              }}
            />
          </label>
        </span>
      </div>

      <div className="scroll">
        <div className="cbody">
          <div className="md">
            <div className="mdnav">
              {sections.map((s) => (
                <div key={s.sec}>
                  <div className="sec">{s.sec}</div>
                  {s.items.map((it) => (
                    <button
                      key={it.id}
                      className={"it" + (active === it.id ? " on" : "")}
                      onClick={() => setActive(it.id)}
                    >
                      {it.icon}
                      {it.label}
                    </button>
                  ))}
                </div>
              ))}
            </div>

            {active === "appearance" && <AppearancePane theme={theme} setTheme={setTheme} />}
            {active === "playback" && <PlaybackPane />}
            {active === "shortcuts" && <ShortcutsPane />}
            {active === "danmaku" && <DanmakuPane />}
            {active === "subtrans" && <SubTransPane />}
            {active === "cf" && <CfPane />}
            {active === "prefetch" && <PrefetchPane />}
            {active === "preload" && <PreloadPane />}
            {active === "proxy" && <ProxyPane />}
            {active === "sync" && <SyncPane />}
            {active === "account" && <AccountPane />}
            {active === "blocked" && <BlockedPane />}
            {active === "storage" && <StoragePane />}
            {active === "about" && <AboutPane />}
          </div>
        </div>
      </div>
    </>
  );
}
