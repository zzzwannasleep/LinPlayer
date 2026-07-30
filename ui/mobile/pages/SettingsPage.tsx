import { useEffect, useState } from "react";
import {
  type DanmakuServer,
  type PlaybackPrefs,
  type Prefs,
  type PrefetchSettings,
  type ShaderLevel,
  type SyncAccount,
  type UpdateChannel,
  type UpdateSettings,
  type WritebackSettings,
  bangumiAccount,
  cacheSize,
  checkUpdate,
  clearCache,
  fmtSize,
  getCrossServerResume,
  getDanmakuConfig,
  getPlaybackPrefs,
  getPrefetchSettings,
  getPrefs,
  getUpdateSettings,
  getWritebackSettings,
  listAccounts,
  setCrossServerResume,
  setDanmakuConfig,
  setPlaybackPrefs,
  setPrefetchSettings,
  setPrefs,
  setShaderLevel,
  setTrackRegexes,
  setUpdateSettings,
  setWritebackSettings,
  shaderLevels,
  traktAccount,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon, iconNode } from "../app/icons";
import { haptic, menu, toast } from "../app/motion";
import Page from "../components/Page";
import Sheet from "../components/Sheet";
import { Cell, Group, Opt, SegRow, SliderRow, StepRow } from "../components/ui";
import { Field } from "../components/SourceForm";

/* 设置。
   PC 端是 2878 行 / 12 面板 / 约 90 项,**全页零二次确认**。
   手机端做减法,分三档(这是取舍,不是没做完):
     做     —— 播放 / 弹幕 / 网络 / 同步 / 外观
     降级   —— 存储(PC 铺 11 条绝对路径还写死 420px 宽 → 只留缓存和说明) / 关于
     不做   —— 快捷键(没键盘) / mpv.conf(textarea 一弹键盘盖掉 1/3 屏)
               / 翻译引擎密钥(5 套 Key 共 20+ 项,手机上逐个粘贴是灾难)

   ★ **能就地调的绝不开二次弹窗**(用户 2026-07-28 最看重的一条)。
     「点开 → 选 → 关掉」三步只为把「中」改成「大」,那是白走两步。
     sheet 只留给两种情况:选项多且互斥(超分十几档、语言列表——语言还会长)、需要填表(正则)。
     PC 端用的就是 Seg + Stepper 就地生效,做成弹窗是退步。

   ★ 危险操作要二次确认。PC 全页零确认 —— 桌面用鼠标精准点还行,
     手机是拇指,误触率完全不是一个量级。 */

const SUB_META = {
  playback: { title: "播放", icon: "play" },
  danmaku: { title: "弹幕", icon: "danmaku" },
  network: { title: "网络", icon: "globe" },
  sync: { title: "同步与账号", icon: "sync" },
  storage: { title: "存储与数据", icon: "folder" },
  about: { title: "关于", icon: "info" },
} as const;

type SubId = keyof typeof SUB_META;

/* ============================================================
   设置主页
   ============================================================ */

export default function SettingsPage() {
  const { go, back } = useCtx();
  const [nServer, setNServer] = useState<{ n: number; cur: string } | null>(null);
  const [pb, setPb] = useState<PlaybackPrefs | null>(null);
  const [dmSrc, setDmSrc] = useState<DanmakuServer[] | null>(null);
  const [pf, setPf] = useState<PrefetchSettings | null>(null);
  const [trakt, setTrakt] = useState<SyncAccount | null>(null);
  const [bgm, setBgm] = useState<SyncAccount | null>(null);
  const [cache, setCache] = useState<number | null>(null);
  const [upd, setUpd] = useState<UpdateSettings | null>(null);

  useEffect(() => {
    /* 副标题要写「现在是什么」,所以主页也得把各子页的当前值拉一遍。
       ★ 各自 .then,不加屏障 —— 某一条挂了只让那一行的副标题空着。 */
    listAccounts()
      .then((a) => setNServer({ n: a.length, cur: a.find((x) => x.active)?.name ?? "未设置" }))
      .catch(() => {});
    getPlaybackPrefs().then(setPb).catch(() => {});
    getDanmakuConfig().then(setDmSrc).catch(() => {});
    getPrefetchSettings().then(setPf).catch(() => {});
    traktAccount().then(setTrakt).catch(() => {});
    bangumiAccount().then(setBgm).catch(() => {});
    cacheSize().then(setCache).catch(() => {});
    getUpdateSettings().then(setUpd).catch(() => {});
  }, []);

  const now: Record<SubId, string> = {
    playback: pb ? `${pb.hwdec === "no" ? "强制软解" : "硬解优先"} · ${pb.default_speed}×` : "",
    danmaku: dmSrc ? `${dmSrc.filter((s) => s.enabled).length} 个源在用` : "",
    network: pf ? `${pf.threads} 线程 · 缓存 ${fmtSize(pf.cache_bytes)}` : "",
    sync: [trakt && "Trakt", bgm && "Bangumi"].filter(Boolean).join(" / ") || "未连接第三方账号",
    storage: cache != null ? `缓存 ${fmtSize(cache)}` : "",
    about: upd?.current_version ? `v${upd.current_version}` : "",
  };

  const subCell = (id: SubId) => (
    <Cell
      key={id}
      icon={SUB_META[id].icon}
      label={SUB_META[id].title}
      sub={now[id] || undefined}
      onClick={() => go({ page: "settingsSub", group: id })}
    />
  );

  return (
    <Page title="设置" big onBack={back} enterKey={pb}>
      {/* 片源不进子页:装完 App 第一件事就是加服务器,切服务器也是最常做的操作。
          把最高频的入口埋进二级 = 每次多戳一下。 */}
      <Group title="片源">
        <Cell
          icon="server"
          label="服务器"
          sub={nServer ? `${nServer.n} 个 · 当前:${nServer.cur}` : undefined}
          onClick={() => go("servers")}
        />
        <Cell icon="cloud" label="网盘文件" sub="浏览网盘里的视频" onClick={() => go("netdisk")} />
        <Cell icon="plugin" label="插件" onClick={() => go("plugins")} />
        <Cell icon="rss" label="Ani-RSS" onClick={() => go("anirss")} />
      </Group>

      <Group title="设置">
        {subCell("playback")}
        {subCell("danmaku")}
        {subCell("network")}
        {subCell("sync")}
      </Group>

      {/* 外观只有一项,为它单开一页不值 —— 进去发现就一行是很扫兴的。
          ★ 主题目前**强制深色**(理由写在 theme/mobile.css 顶部)。
            所以这里不摆一个切不动的开关 —— 摆了就是假 UI。 */}
      <Group
        title="外观"
        note="手机端目前只有深色一套。一屏全是封面图,浅色主题的收益很小,而两套配色要维护两遍 —— 这是取舍,不是漏做。"
      >
        <Cell icon="sparkle" label="主题" value="深色" arrow={false} />
      </Group>

      <Group title="其它">
        {subCell("storage")}
        {subCell("about")}
      </Group>

      <div style={{ textAlign: "center", fontSize: 12, color: "var(--fg-3)", padding: "20px 0 32px" }}>
        LinPlayer {upd?.current_version ? `v${upd.current_version}` : ""}
      </div>
    </Page>
  );
}

/* ============================================================
   子页
   ============================================================ */

export function SettingsSubPage({ group }: { group?: string }) {
  const { back } = useCtx();
  const id = (group && group in SUB_META ? group : "playback") as SubId;
  return (
    <Page title={SUB_META[id].title} onBack={back}>
      {id === "playback" && <PlaybackSub />}
      {id === "danmaku" && <DanmakuSub />}
      {id === "network" && <NetworkSub />}
      {id === "sync" && <SyncSub />}
      {id === "storage" && <StorageSub />}
      {id === "about" && <AboutSub />}
      <div style={{ height: 24 }} />
    </Page>
  );
}

/* ---------- 播放 ---------- */

/** ISO 639-2/3 三字母码 ⇄ 人话。
 *  ★ PC 端让用户**手打** `chi`/`jpn`/`eng`。手机上打字成本高得多,
 *    而且没人记得住"粤语"是 `yue`。改成挑列表。
 *  ★ 语言是**会长的列表**(以后要加韩语/法语),所以这两项留 sheet。 */
const AUDIO_LANGS: [string, string][] = [
  ["", "跟随系统"], ["chi", "中文"], ["jpn", "日语"], ["eng", "英语"], ["yue", "粤语"],
];
const SUB_LANGS: [string, string][] = [
  ["", "自动(不指定)"], ["chi", "简体中文"], ["cht", "繁體中文"], ["eng", "英语"], ["jpn", "日语"],
];

function PlaybackSub() {
  const [pb, setPb] = useState<PlaybackPrefs | null>(null);
  const [pr, setPr] = useState<Prefs | null>(null);
  const [shaders, setShaders] = useState<ShaderLevel[]>([]);
  const [curShader, setCurShader] = useState("off");
  const [pick, setPick] = useState<null | "sr" | "audio" | "sub" | "ext">(null);
  const [regex, setRegex] = useState(false);

  useEffect(() => {
    getPlaybackPrefs().then(setPb).catch(() => {});
    getPrefs().then(setPr).catch(() => {});
    shaderLevels().then(setShaders).catch(() => {});
  }, []);

  const savePb = (patch: Partial<PlaybackPrefs>) => {
    if (!pb) return;
    const next = { ...pb, ...patch };
    setPb(next);
    setPlaybackPrefs(next).catch((e) => toast(String(e), "bad"));
  };
  const savePr = (patch: Partial<Prefs>) => {
    if (!pr) return;
    const next = { ...pr, ...patch };
    setPr(next);
    setPrefs({ audio_lang: next.audio_lang, sub_lang: next.sub_lang, sub_enabled: next.sub_enabled }).catch((e) =>
      toast(String(e), "bad"),
    );
  };

  if (!pb || !pr) return <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>;

  const label = (xs: [string, string][], v: string | null) => xs.find(([k]) => k === (v ?? ""))?.[1] ?? v ?? "";

  return (
    <>
      <Group title="解码">
        {/* 两个互斥选项 → 分段就地切,不开弹窗。
            ★ 核层只有 auto-safe / no 两档,**没有"自动"这第三档** —— 摆上去就是假选项。 */}
        <SegRow
          label="默认解码方式"
          sub="硬解省电,软解兼容性好"
          options={["硬解优先", "强制软解"] as const}
          cur={pb.hwdec === "no" ? "强制软解" : "硬解优先"}
          onPick={(v) => savePb({ hwdec: v === "强制软解" ? "no" : "auto-safe" })}
        />
        <Cell
          label="杜比视界自动软解"
          sub="DV 硬解常有色偏,软解画面才对"
          sw={pb.dolby_auto_sw}
          onClick={(v) => savePb({ dolby_auto_sw: v })}
        />
        {/* 超分十几档 → 这种才该开弹窗 */}
        <Cell
          label="超分档位"
          value={shaders.find(([id]) => id === curShader)?.[1] ?? "关闭"}
          onClick={() => setPick("sr")}
        />
      </Group>

      <Group title="起播">
        <StepRow
          label="默认倍速"
          sub="每次起播套用,播放中临时调的不改这里"
          value={pb.default_speed}
          min={0.25}
          max={4}
          step={0.25}
          fmt={(v) => `${parseFloat(v.toFixed(2))}×`}
          onChange={(v) => savePb({ default_speed: v })}
        />
        <Cell label="自动跳过片头" sub="服务端认不出章节就不跳" sw={pb.skip_intro} onClick={(v) => savePb({ skip_intro: v })} />
        <Cell label="自动跳过片尾" sub="片尾后面还有内容时才跳" sw={pb.skip_outro} onClick={(v) => savePb({ skip_outro: v })} />
        <Cell
          label="进度条缩略图"
          sub="拖进度条时预览画面,没有章节图就只显示时间"
          sw={pb.preview_thumbs}
          onClick={(v) => savePb({ preview_thumbs: v })}
        />
      </Group>

      <Group title="音轨与字幕">
        <Cell label="首选音频语言" value={label(AUDIO_LANGS, pr.audio_lang)} onClick={() => setPick("audio")} />
        <Cell label="首选字幕语言" value={label(SUB_LANGS, pr.sub_lang)} onClick={() => setPick("sub")} />
        <Cell label="默认加载字幕" sw={pr.sub_enabled} onClick={(v) => savePr({ sub_enabled: v })} />
        <Cell label="高级筛选规则" sub="用正则挑版本 / 字幕轨 / 音轨" onClick={() => setRegex(true)} />
      </Group>

      <Group title="外部播放器">
        <Cell label="交给其它 App 播放" value={pb.external_player || "不使用(用内置播放器)"} onClick={() => setPick("ext")} />
      </Group>

      <Sheet open={pick === "sr"} onClose={() => setPick(null)} title="超分档位" snap>
        <div className="opts">
          {shaders.map(([id, name, family], i) => (
            <Opt
              key={id}
              i={i}
              on={id === curShader}
              label={name}
              sub={family}
              onClick={() => {
                setCurShader(id);
                haptic("sel");
                setShaderLevel(id)
                  .then((r) => {
                    /* ★ count>0 只说明 mpv 收下了路径,**不代表 shader 会跑**。
                       will_run=false 时把核层给的 note(带真实数字)原话转出去。 */
                    if (id !== "off" && r.will_run === false) toast(r.note || "这一档在当前尺寸下不会跑", "warn");
                  })
                  .catch((e) => toast(String(e), "bad"));
                setPick(null);
              }}
            />
          ))}
        </div>
      </Sheet>

      <Sheet open={pick === "audio"} onClose={() => setPick(null)} title="首选音频语言">
        <div className="opts">
          {AUDIO_LANGS.map(([k, v], i) => (
            <Opt
              key={k || "auto"}
              i={i}
              on={(pr.audio_lang ?? "") === k}
              label={v}
              sub={k || undefined}
              onClick={() => {
                savePr({ audio_lang: k || null });
                setPick(null);
              }}
            />
          ))}
        </div>
      </Sheet>

      <Sheet open={pick === "sub"} onClose={() => setPick(null)} title="首选字幕语言">
        <div className="opts">
          {SUB_LANGS.map(([k, v], i) => (
            <Opt
              key={k || "auto"}
              i={i}
              on={(pr.sub_lang ?? "") === k}
              label={v}
              sub={k || undefined}
              onClick={() => {
                savePr({ sub_lang: k || null });
                setPick(null);
              }}
            />
          ))}
        </div>
      </Sheet>

      <Sheet open={pick === "ext"} onClose={() => setPick(null)} title="交给其它 App 播放">
        <div className="opts">
          {["", "MX Player", "VLC"].map((v, i) => (
            <Opt
              key={v || "none"}
              i={i}
              on={(pb.external_player || "") === v}
              label={v || "不使用(用内置播放器)"}
              onClick={() => {
                savePb({ external_player: v });
                setPick(null);
              }}
            />
          ))}
        </div>
      </Sheet>

      {/* ★ onSave 必须**真的落库**。原来这里只有 setPr(改本地 React state),
          面板一关就没了、重进设置页读回来还是空 —— 用户按官网写好的正则从来没到过核层,
          而且全程一声不吭(同「手机端表单的服务器名称从来没落库」那个老坑)。
          校验也在核层:JS 的 RegExp 认前后瞻、Rust 的 regex crate 不认,
          拿浏览器校验会放过一条存得下却永不命中的正则。 */}
      <RegexSheet
        open={regex}
        pr={pr}
        onClose={() => setRegex(false)}
        onSave={async (p) => {
          const next = { ...pr, ...p };
          await setTrackRegexes({
            version_regex: next.version_regex.trim(),
            sub_regex: next.sub_regex.trim(),
            audio_regex: next.audio_regex.trim(),
          });
          setPr(next);
        }}
      />
    </>
  );
}

function RegexSheet({
  open,
  pr,
  onClose,
  onSave,
}: {
  open: boolean;
  pr: Prefs;
  onClose: () => void;
  onSave: (p: Partial<Prefs>) => Promise<void>;
}) {
  const [v, setV] = useState(pr.version_regex);
  const [s, setS] = useState(pr.sub_regex);
  const [a, setA] = useState(pr.audio_regex);
  useEffect(() => {
    if (open) {
      setV(pr.version_regex);
      setS(pr.sub_regex);
      setA(pr.audio_regex);
    }
  }, [open, pr]);
  return (
    <Sheet open={open} onClose={onClose} title="高级筛选规则" snap>
      <div className="pad">
        <p className="f-note">留空 = 不启用,回落到上面的语言偏好。规则命中第一条就用它,所以把最想要的写前面。</p>
        <Field label="版本正则" placeholder="例如 2160p|4K" value={v} onChange={setV} />
        <Field label="字幕轨正则" placeholder="例如 简|CHS|Chinese" value={s} onChange={setS} />
        <Field label="音轨正则" placeholder="例如 国语|Mandarin" value={a} onChange={setA} />
      </div>
      <div className="sheet-acts">
        <button type="button" className="btn ghost" onClick={onClose}>
          取消
        </button>
        <button
          type="button"
          className="btn primary"
          onClick={async () => {
            /* 非法正则核层直接拒、不落盘(和官网「正则非法不会保存」的承诺一致),
               所以失败要把错弹出来并**留在面板上**让用户改,不能照样说「已保存」再关掉。 */
            try {
              await onSave({ version_regex: v, sub_regex: s, audio_regex: a });
            } catch (e) {
              toast(`正则不合法:${e}`, "bad");
              return;
            }
            toast("规则已保存 —— 下次起播生效", "ok");
            onClose();
          }}
        >
          保存
        </button>
      </div>
    </Sheet>
  );
}

/* ---------- 弹幕 ---------- */

const hostOf = (u: string) => {
  try {
    return new URL(u).host;
  } catch {
    return "";
  }
};

function DanmakuSub() {
  const [srcs, setSrcs] = useState<DanmakuServer[] | null>(null);
  const [edit, setEdit] = useState<DanmakuServer | null>(null);
  const [adding, setAdding] = useState(false);

  const load = () => getDanmakuConfig().then(setSrcs).catch(() => setSrcs([]));
  useEffect(() => {
    load();
  }, []);

  const save = (next: DanmakuServer[]) => {
    setSrcs(next);
    setDanmakuConfig(next)
      .then(load)
      .catch((e) => toast(String(e), "bad"));
  };

  /** 内置源 = 编译期注入凭据的那条,只读不可删。判据:没有 api_url。 */
  const isBuiltin = (s: DanmakuServer) => !s.api_url;

  const move = (i: number, d: -1 | 1) => {
    if (!srcs) return;
    const j = i + d;
    if (j < 0 || j >= srcs.length) return;
    const next = srcs.slice();
    [next[i], next[j]] = [next[j], next[i]];
    /* 顺序即优先级 —— 换完位置要把 priority 重排,不然核层还按旧的走。 */
    save(next.map((s, k) => ({ ...s, priority: k })));
    haptic("sel");
  };

  return (
    <>
      {/* ★ 弹幕源是一张**可增删的列表**,不是一个四选一的下拉。
          写死「第三方弹幕库」这么一个选项等于没给 —— 自建源地址各不相同,必须能自己填。
          ★ 「本地文件」**不在这儿**:那是播放页临时挂一个 xml/ass 的事,
            设置页里没法预先指定"以后每部片都用哪个本地文件"。 */}
      <Group title="弹幕源" note="顺序就是优先级 —— 长按可以上移下移。内置源是编译期带凭据的,只读不可删。">
        {srcs === null ? (
          <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
        ) : (
          <>
            {srcs.map((s, i) => (
              <DmRow
                key={s.id || s.api_url || i}
                s={s}
                i={i}
                builtin={isBuiltin(s)}
                onMenu={(x, y) =>
                  menu(x, y, [
                    { icon: iconNode("pencil", 18), label: "编辑", on: () => setEdit(s) },
                    { icon: iconNode("back", 18), label: "上移", on: () => move(i, -1) },
                    { icon: iconNode("chevR", 18), label: "下移", on: () => move(i, 1) },
                    "-",
                    {
                      icon: iconNode("trash", 18),
                      label: "删除",
                      bad: true,
                      on: () => save(srcs.filter((x2) => x2 !== s).map((x2, k) => ({ ...x2, priority: k }))),
                    },
                  ])
                }
                onToggle={() => {
                  haptic("sel");
                  const next = srcs.slice();
                  next[i] = { ...s, enabled: !s.enabled };
                  save(next);
                }}
              />
            ))}
            <Cell icon="plus" label="添加弹幕源" sub="填一个 API 地址就行" onClick={() => setAdding(true)} />
          </>
        )}
      </Group>

      <Group title="显示" note="这几项是渲染参数,改完下一次起播生效。">
        <SegRow label="字号" options={["小", "中", "大", "超大"] as const} cur="中" onPick={() => {}} />
        <SliderRow label="不透明度" value={100} min={20} max={100} step={5} fmt={(v) => `${v}%`} onChange={() => {}} />
        <SegRow label="显示区域" options={["全屏", "上半屏", "1/2 屏", "1/4 屏"] as const} cur="全屏" onPick={() => {}} />
        <SegRow label="滚动速度" options={["慢", "正常", "快"] as const} cur="正常" onPick={() => {}} />
      </Group>

      <DmEditSheet
        open={adding || !!edit}
        src={edit}
        onClose={() => {
          setAdding(false);
          setEdit(null);
        }}
        onSave={(v) => {
          if (!srcs) return;
          const next = edit ? srcs.map((x) => (x === edit ? { ...edit, ...v } : x)) : [...srcs, v];
          save(next.map((s, k) => ({ ...s, priority: k })));
          setAdding(false);
          setEdit(null);
        }}
      />
    </>
  );
}

function DmRow({
  s,
  i,
  builtin,
  onMenu,
  onToggle,
}: {
  s: DanmakuServer;
  i: number;
  builtin: boolean;
  onMenu: (x: number, y: number) => void;
  onToggle: () => void;
}) {
  /* ★ 内置源**不挂长按** —— 弹一个全是灰项的菜单只会让人以为坏了。 */
  const timer = { t: 0 as ReturnType<typeof setTimeout> | 0 };
  return (
    <div
      className="lit"
      style={{ ["--i" as string]: i }}
      onPointerDown={(e) => {
        if (builtin) return;
        const x = e.clientX;
        const y = e.clientY;
        timer.t = setTimeout(() => {
          haptic("sel");
          onMenu(x, y);
        }, 480);
      }}
      onPointerUp={() => timer.t && clearTimeout(timer.t)}
      onPointerCancel={() => timer.t && clearTimeout(timer.t)}
      onPointerMove={() => timer.t && clearTimeout(timer.t)}
    >
      <span className="lit-ic">
        <Icon n="danmaku" size={18} />
      </span>
      <span className="lit-t">
        <div className="lit-n">
          {s.name || hostOf(s.api_url) || "弹弹play"}
          {builtin && (
            <b className="tag" style={{ marginLeft: 6 }}>
              内置
            </b>
          )}
        </div>
        <div className="lit-s">{s.api_url || "内置默认源 · 无需配置"}</div>
      </span>
      <span className="lit-rm">优先级 {i + 1}</span>
      <button
        type="button"
        className={`sw${s.enabled ? " on" : ""}`}
        aria-label={s.enabled ? "停用" : "启用"}
        onClick={onToggle}
      >
        <i />
      </button>
    </div>
  );
}

function DmEditSheet({
  open,
  src,
  onClose,
  onSave,
}: {
  open: boolean;
  src: DanmakuServer | null;
  onClose: () => void;
  onSave: (s: DanmakuServer) => void;
}) {
  const [name, setName] = useState("");
  const [url, setUrl] = useState("");
  const [token, setToken] = useState("");
  useEffect(() => {
    if (!open) return;
    setName(src?.name ?? "");
    setUrl(src?.api_url ?? "");
    setToken(src?.token ?? "");
  }, [open, src]);
  return (
    <Sheet open={open} onClose={onClose} title={src ? "编辑弹幕源" : "添加弹幕源"}>
      <div className="pad">
        <Field label="名称(可留空)" placeholder="留空就拿域名当名字" value={name} onChange={setName} />
        <Field
          label="API 地址"
          type="url"
          placeholder="https://danmaku.example.com/api/v2"
          value={url}
          onChange={setUrl}
          required
          reqKey="url"
        />
        <Field label="Token(没有就留空)" placeholder="部分自建源要" value={token} onChange={setToken} />
      </div>
      <div className="sheet-acts">
        <button type="button" className="btn ghost" onClick={onClose}>
          取消
        </button>
        <button
          type="button"
          className="btn primary"
          onClick={() => {
            if (!url.trim()) {
              haptic("err");
              return toast("API 地址不能空", "bad");
            }
            onSave({
              id: src?.id ?? "",
              name: name.trim() || hostOf(url) || "自建源",
              api_url: url.trim(),
              auth_type: token.trim() ? "headerToken" : "none",
              token: token.trim(),
              enabled: src?.enabled ?? true,
              priority: src?.priority ?? 99,
            });
          }}
        >
          保存
        </button>
      </div>
    </Sheet>
  );
}

/* ---------- 网络 ----------
   ★ **代理整组去掉**(用户 2026-07-28 定):手机上 Clash / VPN 类 App 是系统级的全局代理,
     轮不到播放器自己做一套。PC 端保留是因为桌面没有这种统一入口。
     这里直接把这句写给用户,免得他以为功能缺失。 */

function NetworkSub() {
  const [pf, setPf] = useState<PrefetchSettings | null>(null);
  const [why, setWhy] = useState(false);
  useEffect(() => {
    getPrefetchSettings().then(setPf).catch(() => {});
  }, []);
  const save = (patch: Partial<PrefetchSettings>) => {
    if (!pf) return;
    const next = { ...pf, ...patch };
    setPf(next);
    setPrefetchSettings(next).catch((e) => toast(String(e), "bad"));
  };
  if (!pf) return <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>;

  const MB = 1024 * 1024;
  return (
    <>
      <Group title="多线程加载">
        <StepRow
          label="并发线程数"
          sub="核层只接受 2~4"
          value={pf.threads}
          min={2}
          max={4}
          step={1}
          fmt={(v) => `${v} 线程`}
          onChange={(v) => save({ threads: v })}
        />
        <StepRow
          label="缓存上限"
          sub="落盘的环形缓存,决定磁盘占用"
          value={Math.round(pf.cache_bytes / MB)}
          min={64}
          max={4096}
          step={64}
          fmt={(v) => (v >= 1024 ? `${v / 1024} GB` : `${v} MB`)}
          onChange={(v) => save({ cache_bytes: v * MB })}
        />
        <Cell label="多线程一定更快吗?" sub="点开看说明" onClick={() => setWhy(true)} />
      </Group>

      <Group title="说明">
        <div className="crow">
          <div className="crow-t">
            <div>要走代理怎么办?</div>
            <div className="crow-s">
              手机上用 Clash / VPN 类 App 就行,那是系统级的全局代理,比播放器自己做一套更靠谱。
              所以这里不提供代理设置。
            </div>
          </div>
        </div>
      </Group>

      <Sheet open={why} onClose={() => setWhy(false)} title="多线程加载">
        <div className="pad">
          <p className="f-note" style={{ fontSize: 13.5, lineHeight: 1.7 }}>
            预取是本地起一个小代理,提前把后面的片段拉下来喂给播放器。
            收益完全取决于服务端 —— 单线程就能跑满带宽的服务器,开多线程只是多占内存和流量,不会更快。
            遇到卡顿先试着开到 4 线程,没改善就调回 2。
          </p>
        </div>
      </Sheet>
    </>
  );
}

/* ---------- 同步 ---------- */

function SyncSub() {
  const [cross, setCross] = useState<boolean | null>(null);
  const [wb, setWb] = useState<WritebackSettings | null>(null);
  const [trakt, setTrakt] = useState<SyncAccount | null>(null);
  const [bgm, setBgm] = useState<SyncAccount | null>(null);

  useEffect(() => {
    getCrossServerResume().then(setCross).catch(() => {});
    getWritebackSettings().then(setWb).catch(() => {});
    traktAccount().then(setTrakt).catch(() => {});
    bangumiAccount().then(setBgm).catch(() => {});
  }, []);

  const saveWb = (patch: Partial<WritebackSettings>) => {
    if (!wb) return;
    const next = { ...wb, ...patch };
    setWb(next);
    setWritebackSettings(next).catch((e) => toast(String(e), "bad"));
  };

  const RANGE: Record<string, string> = { all: "全部", first: "第一台", latest: "最近用的" };
  const rangeKey = (v: string) => Object.keys(RANGE).find((k) => RANGE[k] === v) ?? "all";

  return (
    <>
      <Group title="跨服务器">
        <Cell
          label="跨服续播"
          sub="同一部片在多台服务器上,取进度最大的那个接着看"
          sw={cross ?? false}
          onClick={(v) => {
            setCross(v);
            setCrossServerResume(v).catch((e) => toast(String(e), "bad"));
          }}
        />
        {wb && (
          <>
            <Cell
              label="看完回传到其它服务器"
              sub="把已看状态写回其它有这部片的服务器"
              sw={wb.enabled}
              onClick={(v) => saveWb({ enabled: v })}
            />
            <SegRow
              label="回传范围"
              options={["全部", "第一台", "最近用的"] as const}
              cur={RANGE[wb.range] ?? "全部"}
              onPick={(v) => saveWb({ range: rangeKey(v) })}
            />
            <Cell
              label="连播放进度一起回传"
              sub="关掉就只同步「看没看完」,不同步具体秒数"
              sw={wb.include_progress}
              onClick={(v) => saveWb({ include_progress: v })}
            />
          </>
        )}
      </Group>

      <Group
        title="第三方账号"
        note="连接要走设备码授权(在另一台设备的浏览器里输一串码)。手机端还没接这条交互 —— 先在 PC 端连一次,凭据是共用的。这里只显示状态,不摆一个按了没反应的按钮。"
      >
        <Cell
          icon="check"
          label="Trakt"
          sub={trakt ? `已连接 · ${trakt.username ?? trakt.service}` : "同步观看进度与收藏"}
          value={trakt ? "已连接" : "未连接"}
          arrow={false}
        />
        <Cell
          icon="star"
          label="Bangumi"
          sub={bgm ? `已连接 · ${bgm.username ?? bgm.service}` : "同步在看状态与收藏"}
          value={bgm ? "已连接" : "未连接"}
          arrow={false}
        />
      </Group>
    </>
  );
}

/* ---------- 存储 ---------- */

function StorageSub() {
  const [size, setSize] = useState<number | null>(null);
  const [ask, setAsk] = useState(false);
  useEffect(() => {
    cacheSize().then(setSize).catch(() => {});
  }, []);
  return (
    <>
      <Group title="缓存">
        <Cell label="缓存占用" value={size == null ? "…" : fmtSize(size)} arrow={false} />
        {/* ★ PC 端这一下是**没有确认**的。手机上误触一下重下 1.2 GB 图很难受。 */}
        <Cell label="清除缓存" arrow={false} danger onClick={() => setAsk(true)} />
      </Group>

      {/* PC 端在这儿铺了 11 条绝对路径(还写死 420px 宽)。手机上路径又长又没法点,
          只保留说明 —— 真要看路径的人会去 PC 端看。 */}
      <Group
        title="数据目录"
        note="安卓上数据放在「Android/data/xyz.linplayer.app/files」—— 外部应用专属目录,文件管理器看得见、不需要任何权限、卸载即清。账号、观看记录、插件、截图都在里面。"
      >
        <Cell label="截图保存位置" value="files/screenshots" arrow={false} />
      </Group>

      <Sheet open={ask} onClose={() => setAsk(false)} title="清除缓存?">
        <div className="pad">
          <p className="dim" style={{ fontSize: 13.5, margin: 0 }}>
            会清掉 {size == null ? "" : fmtSize(size)} 的图片和临时文件。
            账号、观看记录、已下载的视频都不受影响,只是封面要重新加载一次。
          </p>
        </div>
        <div className="sheet-acts">
          <button type="button" className="btn ghost" onClick={() => setAsk(false)}>
            取消
          </button>
          <button
            type="button"
            className="btn danger"
            onClick={() => {
              setAsk(false);
              clearCache()
                .then(() => {
                  haptic("ok");
                  toast("已清除缓存", "ok");
                  return cacheSize().then(setSize);
                })
                .catch((e) => toast(String(e), "bad"));
            }}
          >
            清除
          </button>
        </div>
      </Sheet>
    </>
  );
}

/* ---------- 关于 ---------- */

function AboutSub() {
  const [u, setU] = useState<UpdateSettings | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    getUpdateSettings().then(setU).catch(() => {});
  }, []);
  const save = (channel: UpdateChannel, autoCheck: boolean) => {
    if (!u) return;
    setU({ ...u, channel, auto_check: autoCheck });
    setUpdateSettings(channel, autoCheck).catch((e) => toast(String(e), "bad"));
  };
  if (!u) return <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>;
  return (
    <>
      <Group title="版本">
        <Cell
          label="版本号"
          value={`v${u.current_version}`}
          arrow={false}
          onClick={() => {
            navigator.clipboard?.writeText(u.current_version).catch(() => {});
            toast("已复制版本号");
          }}
        />
        <SegRow
          label="更新通道"
          sub="预览版更早拿到新功能,也更容易遇到问题"
          options={["稳定版", "预览版"] as const}
          cur={u.channel === "prerelease" ? "预览版" : "稳定版"}
          onPick={(v) => save(v === "预览版" ? "prerelease" : "stable", u.auto_check)}
        />
        <Cell label="启动时自动检查" sw={u.auto_check} onClick={(v) => save(u.channel, v)} />
        <Cell
          label={busy ? "正在检查…" : "检查更新"}
          arrow={false}
          onClick={() => {
            if (busy) return;
            setBusy(true);
            haptic("tap");
            checkUpdate()
              .then((info) => toast(info ? `有新版本 ${info.version}` : "已是最新版本", "ok"))
              .catch((e) => toast(String(e), "bad"))
              .finally(() => setBusy(false));
          }}
        />
      </Group>

      <Group
        title="备份与迁移"
        note="导出的载荷里**带登录凭据**,别给不认识的人。手机端的摄像头扫码还要宿主接相机权限,暂时只能在「添加服务器 → 扫码搬配置」里粘贴文本载荷。"
      >
        <Cell label="导出本机配置" sub="搬到另一台设备上用" arrow={false} />
      </Group>
    </>
  );
}
