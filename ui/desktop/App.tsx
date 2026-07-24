import { useEffect, useRef, useState } from "react";
import { getCurrentWindow } from "@tauri-apps/api/window";
import {
  type AccountInfo,
  type DanmakuAnime,
  type DanmakuEpisode,
  type DanmakuMatchCandidate,
  type DanmakuMatchInput,
  type DanmakuSourceGroup,
  type DownloadItem,
  type Item,
  type LoginResult,
  type MediaVersion,
  type Prefs,
  type SourceEntry,
  type Status,
  type Track,
  addSubtitle,
  applyPrefs,
  currentSession,
  currentSource,
  danmakuAutoLoad,
  danmakuEpisodes,
  danmakuLoad,
  danmakuMatch,
  danmakuMinAutoScore,
  danmakuSearch,
  defaultDanmakuFilter,
  fmtBitrate,
  fmtRes,
  fmtSize,
  fmtTime,
  getPrefs,
  itemDetail,
  itemMedia,
  listAccounts,
  play,
  playLocal,
  playerOpts,
  type ChapterInfo,
  chapterInfo,
  type PlaybackPrefs,
  getPlaybackPrefs,
  setPlaybackPrefs,
  playExternal,
  posterUrl,
  probeLine,
  reportProgress,
  screenshot,
  seek as seekApi,
  setActiveLine,
  setAspectRatio as setAspectRatioApi,
  setAudioDelay,
  setHwdec as setHwdecApi,
  setMute as setMuteApi,
  setPause,
  setPrefs,
  setSecondarySub,
  setSecondarySubOpts,
  setShaderLevel,
  setSpeed as setSpeedApi,
  setSubDelay,
  setSubStyle,
  setTrack,
  setVolume as setVolumeApi,
  shaderLevels,
  type ShaderLevel,
  sourcePlay,
  sourceWatchdog,
  status as statusApi,
  stopPlayback,
  tracks as tracksApi,
} from "@shared/api";
import { pollTracks } from "@shared/track-poll";
import { DanmakuLayer, type DanmakuComment, type TimeSync } from "./Danmaku";
import LoginPage from "./pages/LoginPage";
import Shell from "./app/Shell";
import Titlebar from "./app/Titlebar";
import {
  IconChevronLeft,
  IconForward,
  IconFullscreen,
  IconFullscreenExit,
  IconMinimize,
  IconRestore,
  IconWindow,
  IconInfo,
  IconList,
  IconNext,
  IconPause,
  IconPlay,
  IconPrev,
  IconRefresh,
  IconRewind,
  IconSun,
  IconVolume,
} from "./app/icons";
import { PluginSlot } from "./components/PluginHost";
import "@shared/tokens.css";
import "./theme/ui.css";
import "./theme/plugins.css";
import "./theme/player.css";

type Panel = null | "eps" | "audio" | "sub" | "danmaku" | "super" | "line" | "version" | "speed" | "more";
/** 竖条弹出态:kind 决定调音量还是亮度,x 是按钮中心(贴着按钮弹,草稿 21)。 */
type VBar = null | { kind: "vol" | "bright"; x: number };

/** 超分滤镜家族分组 `[核层 family 键, 标题, 一句话说明]`。
 *  ★ 第一个字段必须和核层 `shaders::levels()` 的家族名**逐字一致** —— 对不上那一整族
 *    会从面板里静默消失(核层有测试钉家族名,这边有 api_contract 测试对齐)。
 *  用户 2026-07-20:「其实清晰最重要的是锐化」→ 锐化族排最前,它是日常首选;
 *  放大族(Anime4K/FSR/NIS)全部要输出大于源 1.2 倍,窗口里播原生 1080p 一帧都不跑。 */
const SHADER_FAMILIES: [string, string, string][] = [
  ["Sharpen", "锐化 · 清晰度首选", "窗口/全屏都生效 · 开销最低"],
  ["Anime4K", "Anime4K · 动漫特化", "去噪窗口可用 · 放大需全屏"],
  ["FSR", "AMD FSR · 通用", "锐化窗口可用 · 放大需全屏"],
  ["NVIDIA", "NVIDIA · NIS", "锐化窗口可用 · 放大需全屏"],
];
/** 草稿倍速面板「常用」档位。 */
const SPEEDS = [0.5, 1.0, 1.5, 2.0, 3.0];
/** 弹幕显示区域档位 → 占屏高百分比(草稿 stepper「1/2 屏」)。 */
const DM_AREAS = [25, 50, 75, 100];
/* 弹幕「显示速度 / 字体大小」是前端渲染参数(核层 danmaku_filter 文档写明渲染归前端),
   不是缺核层命令 —— 档位在这儿定,值透传给 DanmakuLayer 的 duration / fontSize props。
   两张表的默认下标(DM_DEFAULT)都对着组件原本写死的常量,不动档位 = 观感与以前一模一样。 */
/** 滚动弹幕横穿屏幕的秒数(越小越快)。「中」=8s = Danmaku.tsx 的 DURATION。 */
const DM_SPEEDS: [number, string][] = [[14, "极慢"], [11, "慢"], [8, "中"], [6, "快"], [4.5, "极快"]];
/** 弹幕字号(CSS px);null =「按画面高自适应」,即组件不传 fontSize 时的原行为。 */
const DM_SIZES: [number | null, string][] = [[16, "极小"], [20, "小"], [null, "中"], [28, "大"], [34, "极大"]];
const DM_DEFAULT = 2; // 两张表的「中」都在下标 2

/* 弹幕显示设置的持久化(用户 2026-07-16:「在某一集调整了,后续就不用再重新调整」)。

   为什么是 localStorage 而不是核层 Prefs:这五项**全是前端渲染参数** ——
   不透明度/显示区域是 CSS,速度/字号是 DanmakuLayer 的 props,Rust 侧从头到尾用不到它们
   (核层 danmaku 模块只有源的 CRUD + 搜索/匹配/过滤,没有任何显示配置,已 grep 确认)。
   为它们往 config.rs 加字段 = 让核层存一份自己永远不读的数据。
   ★ 但「用不到」不等于「可以不存」:换片会重建整个播放器状态,不落盘就每集都要重调。 */
const DM_KEY = "player:danmaku";
type DmSettings = { on: boolean; opacity: number; area: number; speed: number; size: number };
/* ★ on 的默认从 false 改成了 true,这是**配套改动**不是口味改动:
   以前靠 autoDanmaku 匹配成功时 setDmOn(true) 把它顶开,所以默认 false 也看得到弹幕;
   现在开关是用户的持久化偏好,自动匹配不能再擅自翻它(翻了就等于「关不掉」),
   于是默认必须自己立起来。没匹配到弹幕时 dmComments 为空,开着也只是一层空画布,观感不变。 */
const DM_FALLBACK: DmSettings = { on: true, opacity: 80, area: 1, speed: DM_DEFAULT, size: DM_DEFAULT };

/** 读回存档。★ 必须逐项夹紧:存档是上个版本写的,档位表增删过之后
    旧下标可能越界 → DM_SPEEDS[7] = undefined → 解构 [0] 直接崩在渲染里。 */
function loadDm(): DmSettings {
  try {
    const raw = localStorage.getItem(DM_KEY);
    if (!raw) return DM_FALLBACK;
    const p = JSON.parse(raw) as Partial<DmSettings>;
    const idx = (v: unknown, len: number, dft: number) =>
      typeof v === "number" && Number.isInteger(v) && v >= 0 && v < len ? v : dft;
    return {
      on: typeof p.on === "boolean" ? p.on : DM_FALLBACK.on,
      opacity: typeof p.opacity === "number" ? Math.min(100, Math.max(0, p.opacity)) : DM_FALLBACK.opacity,
      area: idx(p.area, DM_AREAS.length, DM_FALLBACK.area),
      speed: idx(p.speed, DM_SPEEDS.length, DM_FALLBACK.speed),
      size: idx(p.size, DM_SIZES.length, DM_FALLBACK.size),
    };
  } catch {
    return DM_FALLBACK; // 存档坏了就用默认,不能让它挡住起播
  }
}
/** 平台判定。只用来挑「哪些档位在本平台真的有意义」,不参与任何功能开关。
    WebKitGTK 的 UA 里带 "Linux",WebView2 不带。 */
const IS_LINUX = navigator.userAgent.includes("Linux");
/** 解码档位 → mpv hwdec 值。中间那档是**各平台各自的零拷贝路径**:
    Win 是 d3d11va,Linux 是 vaapi。把 d3d11va 摆给 Linux 用户,得到的是一个
    点了没任何反应的按钮 —— mpv 认不出这个值只会静默回落,不报错。软解(no)排查用。 */
const HWDECS: [string, string][] = [
  ["auto-safe", "硬解"],
  [IS_LINUX ? "vaapi" : "d3d11va", "零拷贝"],
  ["no", "软解"],
];
/** 定时关闭档位(分钟)。照搬旧 Flutter 端既有档位(player_screen_state _showTimerDialog),不另造一套。 */
const SLEEP_MINS = [15, 30, 45, 60, 90, 120];
/** 画面比例档位 → mpv video-aspect-override("" = 还原源比例)。 */
const ASPECTS: [string, string][] = [
  ["", "原始"], ["16:9", "16:9"], ["4:3", "4:3"], ["1.85", "1.85:1"], ["2.35", "2.35:1"], ["21:9", "21:9"],
];
/** 字幕字体档位。「默认」不能传字面量(核层守卫会当占位跳过),故映射到 mpv 真默认 sans-serif。 */
/** ★ 字体是**按名字**交给 libass 的,系统里没有这个名字就静默回落成默认 ——
    摆一排本平台根本不存在的字体,用户点了只会觉得「选了没用」。两端各给各的常见 CJK 字体。 */
const SUB_FONTS: [string, string][] = IS_LINUX
  ? [
      ["sans-serif", "默认"], ["Noto Sans CJK SC", "思源黑体"],
      ["Source Han Sans SC", "思源黑体(Adobe)"], ["WenQuanYi Zen Hei", "文泉驿正黑"],
      ["Noto Serif CJK SC", "思源宋体"],
    ]
  : [
      ["sans-serif", "默认"], ["Microsoft YaHei", "微软雅黑"], ["Noto Sans CJK SC", "思源黑体"],
      ["SimHei", "黑体"], ["KaiTi", "楷体"],
    ];
/** 延迟显示:带符号一位小数,0 也显示 0.0s 免得以为没接上。 */
const fmtDelay = (s: number) => `${s > 0 ? "+" : ""}${s.toFixed(1)}s`;
/** 浮点步进会攒出 0.30000000000000004,统一钉到一位小数。 */
const round1 = (v: number) => Math.round(v * 10) / 10;
/** hwdec-current 回读的是实际解码器(Win 如 d3d11va-copy,Linux 如 vaapi-copy/nvdec),
    归一到三档才好高亮。零拷贝那档按本平台的取值回填,否则 Linux 上永远高亮不中。 */
const normHwdec = (h: string) =>
  !h || h === "no"
    ? "no"
    : /^(d3d11|vaapi|nvdec|vdpau)/.test(h)
      ? (IS_LINUX ? "vaapi" : "d3d11va")
      : "auto-safe";

export default function App() {
  const [booted, setBooted] = useState(false);
  const [session, setSession] = useState<LoginResult | null>(null);
  /** 活跃的文件浏览型源(网盘/Stremio/插件源)。见下面 reloadEntry 的注释。 */
  const [srcAcc, setSrcAcc] = useState<AccountInfo | null>(null);
  /** 刚从登录闸口进来 —— 给主界面挂一次入场动画(见 ui.css 的 .app-root.entering)。 */
  const [entering, setEntering] = useState(false);
  const enterTimer = useRef<number | null>(null);
  const [searchOpen, setSearchOpen] = useState(false);

  const [playing, setPlaying] = useState<Item | null>(null);
  const [status, setStatus] = useState<Status>({ time: 0, duration: 0, paused: false, buffered: 0, eof: false });
  const [tracks, setTracks] = useState<Track[]>([]);
  const [prefs, setPrefs2] = useState<Prefs>({ audio_lang: null, sub_lang: null, sub_enabled: true, detail_blur: 40 });
  const [seeking, setSeeking] = useState<number | null>(null);
  /* 拖动中的值同时存一份 ref:提交动作挂在 window 上(见下面那个 effect),
     而 window 监听器闭包里读到的 state 是注册那一刻的快照,只有 ref 是最新的。 */
  const seekingRef = useRef<number | null>(null);
  const [panel, setPanel] = useState<Panel>(null);
  const [idle, setIdle] = useState(false);
  /* 视频出第一帧前:黑屏 + 加载动画,不露上一段残帧(用户 2026-07-16)。
     出画信号取「时间开始走(st.time>0)」,兜底 4s 强制放行(暂停起播/静态首帧)。 */
  const [ready, setReady] = useState(false);
  const timer = useRef<number | null>(null);
  const tick = useRef(0);
  /// status 轮询连续失败的拍数。见轮询里的 catch —— 用来把「一直读不到」说出来。
  const statusFail = useRef(0);
  /// status 的最新值。给那些**不该因为进度走动而重建**的回调用(键盘快捷键)。
  const statusRef = useRef<Status>({ time: 0, duration: 0, paused: false, buffered: 0, eof: false });
  /** 本片是否已按 eof 收过尾。见轮询里的 eof 分支 —— 一片只准触发一次。 */
  const ended = useRef(false);
  const idleTimer = useRef<number | null>(null);

  // 播放器 OSD 态
  const [siblings, setSiblings] = useState<Item[]>([]); // 当前剧全部分集(上/下一集 + 选集)
  const [versions, setVersions] = useState<MediaVersion[] | null>(null); // 版本面板(item_media)
  const [curMsId, setCurMsId] = useState<string | null>(null); // 当前在播的 media_source_id(版本高亮的真依据)
  /* 线路面板(probe_line / set_active_line 都真接)。
     lineMs:index → 延迟。**三态**,不能压成两态:
       - key 不存在  = 还在探(行上转圈)
       - null        = 探过、确实不通(显示「—」,不装成 0ms)
       - number      = 通,毫秒
     null(整个对象)= 还没开始探;设成 {} 即「已开工」,兼作只探一次的门。 */
  const [lineMs, setLineMs] = useState<Record<number, number | null> | null>(null);
  const [acct, setAcct] = useState<AccountInfo | null>(null);
  const [lineErr, setLineErr] = useState<string | null>(null);
  const [vbar, setVbar] = useState<VBar>(null);
  const [volume, setVol] = useState(70); // 真接 set_volume;起播后由 player_opts 覆盖成真值
  const [muted, setMuted] = useState(false);
  const [brightness, setBrightness] = useState(100); // 纯前端黑遮罩,真生效

  // 播放器可调项:初值都是占位,起播后 player_opts() 拉真值覆盖(否则滑块位置是假的)
  const [speed, setSpd] = useState(1);
  /* 长按连调的 interval 里拿不到 speed state 的最新值(闭包快照的是按下那刻的),
     故 applySpeed 同步往这份 ref 记一手,连调只读 ref。 */
  const speedRef = useRef(1);
  const [aDelay, setADelay] = useState(0);
  const [sDelay, setSDelay] = useState(0);
  const [hwdec, setHw] = useState("auto-safe");
  const [aspect, setAspect] = useState("");
  const [arOpen, setArOpen] = useState(false);
  // 超分:档位清单来自核层 shader_levels(),不再前端写死
  const [shaderList, setShaderList] = useState<ShaderLevel[]>([]);
  const [shaderLv, setShaderLv] = useState("off");
  /* 当前展开的滤镜家族。档位从 19 涨到 26 之后平铺会把面板撑到要滚动
     (用户 2026-07-20:「这样的话 就不能直接展示了 要叠起来 用户点击了某款超分模型再展开」)。
     null = 全部收起;收起时家族行仍显示本族当前选中的档位,不展开也看得见。 */
  const [shFam, setShFam] = useState<string | null>(null);
  /* 滤镜强度 0~100(核层落盘,起播后由 get_prefs 覆盖成真值)。
     用户实测「强度有点低」—— 因为此前一个参数都没设,一直在吃 shader 自带默认(CAS STR=0.5)。 */
  /* 字幕样式:核层无回读命令,故记前端态;初值必须对齐 **libmpv 的真默认**
     (2026-07-16 ctypes 实测:sub-scale=1 / sub-pos=100 / sub-font=sans-serif /
      secondary-sub-pos=0 / secondary-sub-ass-override=strip)。
     初值和 mpv 真实值对不上 = 面板显示的是假读数,用户还没动就已经在骗他。 */
  const [subFont, setSubFont] = useState("sans-serif");
  const [fontOpen, setFontOpen] = useState(false);
  /* 「大小」= sub-scale 百分比(100 = 1.0 倍),**不是 sub-font-size**。
     换旋钮的原因见 mpv.rs::set_sub_scale 的长注释:ASS 字幕不认 sub-font-size。 */
  const [subScale, setSubScale] = useState(100);
  const [subPos, setSubPos] = useState(100);
  const [sec2, setSec2] = useState(""); // 次字幕 sid,"" = 关
  const [sec2Delay, setSec2Delay] = useState(0);
  /* ★ 曾写死 100,而 mpv 的 secondary-sub-pos 真默认是 **0**(顶部)——
     面板一打开就显示「位置 100」,和画面上顶着的次字幕对不上。修正成 0。 */
  const [sec2Pos, setSec2Pos] = useState(0);
  /* 次字幕的 ASS 处理:mpv 默认 strip(剥成纯文本)= 用户报的「次字幕不渲染样式」。
     默认改成 scale,与主字幕同规矩(保留 ASS 自带样式)—— 这正是用户要的「调整」。 */
  const [sec2Ass, setSec2Ass] = useState("scale");
  const [subUrl, setSubUrl] = useState<string | null>(null); // 非 null = 外挂字幕输入框已展开
  // 定时关闭:纯前端,不需要核层命令。句柄必须放 ref —— 放 state 重渲染就丢了句柄,到点没人清。
  const [sleepMin, setSleepMin] = useState<number | null>(null); // null = 关闭
  const [sleepOpen, setSleepOpen] = useState(false);
  const sleepTimer = useRef<number | null>(null);
  const [dolby, setDolby] = useState(false);
  const [toast, setToast] = useState<string | null>(null);
  const [ctx, setCtx] = useState<{ x: number; y: number } | null>(null);
  const [marquee, setMarquee] = useState(false);
  const titleRef = useRef<HTMLSpanElement>(null);
  const toastTimer = useRef<number | null>(null);

  // 弹幕。源的增删改查在设置页(多源 CRUD),这儿只管「搜索 / 选源 / 显示」(草稿 L1119)。
  const [dmComments, setDmComments] = useState<DanmakuComment[]>([]);
  /* 显示设置从存档起步(用户:「某一集调整了,后续不用再重新调整」)。
     useState 的初值写成**函数**:不写函数的话 loadDm() 每次渲染都会跑一遍读 localStorage。 */
  const [dm, setDm] = useState<DmSettings>(loadDm);
  const { on: dmOn, opacity: dmOpacity, area: dmArea, speed: dmSpeed, size: dmSize } = dm;
  /** 改一项 = 存一次。写在同一个函数里,不靠各调用点自觉 —— 漏一处就是「这项不记」。
   *  ★ 收函数式入参:键盘快捷键的 handler 挂在一个 deps 里**没有 dm** 的 effect 上,
   *    直接读渲染作用域的 dmOn 会读到注册那一刻的旧值(按 D 只切一次就再也切不动)。
   *    原代码 setDmOn(v => !v) 是函数式所以躲过了这一劫,别在这里退化成读外层变量。 */
  const patchDm = (p: Partial<DmSettings> | ((d: DmSettings) => Partial<DmSettings>)) =>
    setDm((d) => {
      const next = { ...d, ...(typeof p === "function" ? p(d) : p) };
      try { localStorage.setItem(DM_KEY, JSON.stringify(next)); } catch { /* 存不下也不该影响播放 */ }
      return next;
    });
  const [dmResults, setDmResults] = useState<DanmakuSourceGroup[] | null>(null);
  /** 用户点开的那部番(第二层)。episodes=null 表示集表还在路上。 */
  const [dmPick, setDmPick] = useState<
    { group: DanmakuSourceGroup; anime: DanmakuAnime; episodes: DanmakuEpisode[] | null } | null
  >(null);
  const [dmKw, setDmKw] = useState("");
  const timeSync = useRef<TimeSync>({ base: 0, stamp: performance.now(), paused: false });

  // 进度条悬停时间气泡(草稿 pin 18);x 是条内像素偏移。
  const [hoverT, setHoverT] = useState<{ x: number; t: number } | null>(null);

  /* 章节:进度条缩略图 + 自动跳过片头片尾共用这一份。null = 还没拉到 / 没有章节。
     ★ 同时存一份 ref:500ms 状态轮询的回调只在 [playing] 变化时重建,
       回调里读 state 拿到的永远是建时的旧值(这里就是 null)→ 自动跳过一次都不会触发。
       ref 才读得到当前值。改这份数据必须走 putChapters,别单独 setChapters。 */
  const [chapters, setChapters] = useState<ChapterInfo | null>(null);
  const chaptersRef = useRef<ChapterInfo | null>(null);
  function putChapters(c: ChapterInfo | null) {
    chaptersRef.current = c;
    setChapters(c);
  }
  /* 每片只跳一次。放 ref 不放 state:轮询回调里读的必须是**当前值**,
     state 闭包会读到旧值 → 跳完又跳,用户想倒回去看片头根本退不回来。 */
  const skipped = useRef({ intro: false, outro: false });
  // 刚跳过时给个可撤销的提示条(自动跳错了得让人跳回去)。
  const [skipTip, setSkipTip] = useState<{ from: number; label: string } | null>(null);
  const skipTipTimer = useRef<number | null>(null);
  /* 播放器默认行为(设置页那一组)。播放页「更多」里的跳片头/片尾两行绑的就是它 ——
     它们和设置页是**同一个偏好**,不是本次播放的临时调整,所以在这儿改也要落盘。
     (倍速/解码方式相反:那两个是本次临时,面板改了不写回默认值。) */
  const [pbPrefs, setPbPrefs] = useState<PlaybackPrefs | null>(null);

  /* 长按 +/− 连调的句柄。必须放 ref —— 放 state 一重渲染就换了新值,松手时 clear 的是旧句柄,
     结果按一次停不下来,一路调到底。 */
  const repeat = useRef<number | null>(null);

  useEffect(() => {
    (async () => {
      await reloadEntry(); // 会话 + 活跃文件源一起拉,只拉一个会把网盘用户挡在门外
      getPrefs().then(setPrefs2).catch(() => {});
      /* 这里原本 invoke<DmConfig>("get_danmaku_config") 把 Vec<DanmakuServer> 读成单对象
         (api_url 恒 undefined),而弹幕源的增删改现已归设置页 —— 播放器不需要读它,直接删。
         真要读请走 api.ts 的 getDanmakuConfig(): DanmakuServer[],别再退回单对象。 */
      // 超分档位是核层静态清单(不依赖播放器),开机拉一次即可。
      shaderLevels().then(setShaderList).catch(() => {});
      setBooted(true);
    })();
  }, []);

  /* 详情页背景模糊:核层偏好 → :root 上的 --detail-blur(**无单位**数字),
     由 DetailPage.css 的 .dt-hero-bg 消费。走 CSS 变量而不是层层传 prop,
     因为设置页改完也只需写这一个变量就即时生效(见 AppearancePane.applyBlur)。 */
  useEffect(() => {
    document.documentElement.style.setProperty("--detail-blur", String(prefs.detail_blur));
  }, [prefs.detail_blur]);

  // 全局 Ctrl+K 唤起搜索。
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        if (session && !playing) setSearchOpen(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [session, playing]);

  const trackLang = (list: Track[], id: string) => list.find((t) => t.id === id)?.lang || "";
  async function persistPrefs(next: Prefs) {
    setPrefs2(next);
    await setPrefs(next).catch(() => {});
  }
  /** 切音/字轨:set_track 后立刻重拉 track-list 刷新 selected 高亮 —— 不然点了轨道,
      单选点还赖在旧轨上(mpv 的 selected 标志变了,前端这份 tracks 不重拉就看不出来)。 */
  async function chooseTrack(kind: "audio" | "sub", id: string) {
    await setTrack(kind, id).catch(() => {});
    setTracks(await tracksApi().catch(() => tracks));
  }

  /** OSD 统一提示(复用 ui.css 的 .toast)。
      停留时长按字数给:整句解释(如超分为何不生效)2.4s 根本读不完,读不完等于没说。 */
  function say(msg: string) {
    setToast(msg);
    if (toastTimer.current) window.clearTimeout(toastTimer.current);
    const ms = Math.min(9000, Math.max(2400, msg.length * 130));
    toastTimer.current = window.setTimeout(() => setToast(null), ms);
  }
  /** 核层确实没有的命令:诚实告知,不装作能用。 */
  const soon = (what: string) => say(`${what}:核层暂无对应命令,待接`);
  /** 真调用失败一律如实说,不静默吞(尤其超分:吞掉就成了「以为开了其实没开」)。 */
  const fail = (what: string, e: unknown) => say(`${what}失败:${e}`);

  /* 弹幕自动匹配。核层的 danmaku_auto_load 是一整套(多源并行 + 分数门槛 + 下一集锚点快路径),
     以前 afterStart 只 setDmKw 就完事,等于把这套子系统整个晾着,用户每集都得手搜一遍。
     anchor_key 传剧 id:核层据此走「紧邻上一集的下一集」快路径,省掉一整轮全网匹配。
     全程 catch:弹幕挂不上绝不能反向污染起播链路 —— 但也绝不静默,退化成手动挑并说清原因
     (弹幕最常见的失败是「没配源」,吞掉的话用户只会看见弹幕莫名其妙不出来)。 */
  async function autoDanmaku(it: Item) {
    const input: DanmakuMatchInput = {
      title: it.series_name ?? it.name, // 剧集要用剧名,Episode.name 是「第 35 集」搜不到
      episode_no: it.episode_no,
      file_name: it.name,
      duration_secs: it.runtime_secs > 0 ? it.runtime_secs : null,
    };
    try {
      const auto = await danmakuAutoLoad(input, defaultDanmakuFilter(), null, it.series_id ?? null);
      if (auto) { setDmComments(auto); return; } // 够可信 → 静默挂上,不打扰(开不开由持久化的开关说了算)
      // null = 核层认为没有够格自动挂的匹配。再看一眼候选:够门槛就挂,不够就把面板留给用户。
      const cands = await danmakuMatch(input);
      const top = cands.reduce<DanmakuMatchCandidate | null>((a, b) => (!a || b.score > a.score ? b : a), null);
      if (top && top.score >= (await danmakuMinAutoScore())) {
        setDmComments(await danmakuLoad(top.episode_id, top.source_id));
        say(`弹幕已自动匹配 · ${top.source_name} · ${top.anime_title}`);
        return;
      }
      say(cands.length ? "弹幕候选可信度不足,请在弹幕面板手动挑选" : "未找到匹配的弹幕,可在弹幕面板手动搜索");
    } catch (e) {
      say(`弹幕自动匹配失败:${e} · 可在弹幕面板手动搜索`);
    }
  }

  /* 自动跳过片头/片尾。挂在已有的 500ms 状态轮询上,不另开定时器。
     ★ 每片各跳一次(skipped ref):不设这个闸,用户手动倒回去看片头会被立刻再踹走一次,
       等于「退不回去」。
     ★ 片尾只在**后面还有东西**(下集预告)时才跳。片尾是最后一个章节时 seek 过去
       等于强行结束这一集 —— 用户要的是跳过片尾,不是提前结束。 */
  function autoSkip(t: number) {
    const c = chaptersRef.current;
    if (!c) return;
    if (c.intro && !skipped.current.intro) {
      const [s, e] = c.intro;
      if (t >= s && t < e - 1) {
        skipped.current.intro = true;
        seekApi(e).catch(() => {});
        showSkipTip(t, "已跳过片头");
        return; // 一拍只跳一次
      }
    }
    if (c.outro && !skipped.current.outro) {
      /* 核层只在「片尾后面还有内容」时才给 outro —— 收到就是可跳的,这里不用再判总时长
         (轮询闭包里的 status 会过期,拿旧值判会误跳)。 */
      const [s, e] = c.outro;
      if (t >= s && t < e - 1) {
        skipped.current.outro = true;
        seekApi(e).catch(() => {});
        showSkipTip(t, "已跳过片尾");
      }
    }
  }

  /* 悬停时刻对应的章节图。取**不晚于**该时间点的最后一张 —— 章节图是每章一张,
     离散的;取最近的一张会在章节边界前就换成下一章的画面,和实际内容对不上。 */
  function thumbAt(t: number): string | null {
    const list = chapters?.chapters;
    if (!list?.length) return null;
    let hit: string | null = null;
    for (const c of list) {
      if (c.start_secs > t) break;
      if (c.image_url) hit = c.image_url;
    }
    return hit;
  }

  /* 播放页「更多」里翻跳片头/片尾。和设置页是同一个偏好 → 落盘。
     ★ 翻完必须**重拉一次章节**:intro/outro 是核层按开关算好的,开关变了那两个值就过期了。
       不重拉的话,用户在片头前打开开关,这一集照样不跳(而开关明明是开的)——
       最气人的那种「设了没用」。 */
  async function toggleSkip(key: "skip_intro" | "skip_outro", on: boolean) {
    if (!pbPrefs) return;
    const prev = pbPrefs;
    const next = { ...pbPrefs, [key]: on };
    setPbPrefs(next);
    try {
      await setPlaybackPrefs(next);
      const label = key === "skip_intro" ? "片头" : "片尾";
      say(on ? `自动跳过${label}:开` : `自动跳过${label}:关`);
      if (playing) {
        const info = await chapterInfo(playing.id, playing.runtime_secs).catch(() => null);
        putChapters(info);
        // 开了却什么都没识别出来,得说清是**服务端没有章节**,不是开关没生效。
        if (on && !info?.[key === "skip_intro" ? "intro" : "outro"]) {
          say(`这一集没识别出${label}(服务端章节缺失或命名不常见),不会跳`);
        }
      }
    } catch (e) {
      setPbPrefs(prev); // 回滚:开关停在新位置而磁盘是旧值 = 又一个「显示的不是生效的」
      fail("自动跳过", e);
    }
  }

  /* 跳过提示条:自动跳过认错了得让人跳得回来(章节名匹配不可能 100% 准)。 */
  function showSkipTip(from: number, label: string) {
    setSkipTip({ from, label });
    if (skipTipTimer.current) window.clearTimeout(skipTipTimer.current);
    skipTipTimer.current = window.setTimeout(() => setSkipTip(null), 6000);
  }

  async function afterStart(it: Item) {
    setReady(false); // 新片:先黑屏,等出画
    putChapters(null); // 换片先清:否则新片的进度条上挂着上一集的缩略图和片头区间
    skipped.current = { intro: false, outro: false };
    setDmComments([]);
    /* ★ 这里以前有 setDmOn(false) —— 换片就把弹幕开关拍回关,
       用户上一集调好的东西下一集全废。开关现在是持久化偏好,换片不动它。 */
    setDmKw(it.series_name ?? it.name); // 手搜的预填也用剧名,和自动匹配同一口径
    setDmResults(null);
    setPanel(null);
    setVersions(null);
    // 换片重置前端侧样式态(核层是新播放器实例,旧的延迟/次字幕都没了)。
    setSubUrl(null);
    setADelay(0); setSDelay(0);
    setSec2(""); setSec2Delay(0); setSec2Pos(0); setSec2Ass("scale");
    setSubScale(100); setSubPos(100); setSubFont("sans-serif");
    /* 次字幕默认保留 ASS 样式:mpv 自己的默认是 strip(剥成纯文本),不主动设它就还是 strip。
       每换一片都要重设 —— 播放器是新实例,属性回到 mpv 默认。失败不打扰:
       这只是观感偏好,而且此刻播放器可能还没起来(afterStart 紧跟着 play)。 */
    setSecondarySubOpts({ assOverride: "scale", position: 0 }).catch(() => {});
    setAspect(""); setShaderLv("off");
    setSleepMin(null); setSleepOpen(false); setDolby(false); // 定时句柄由 [playing] 的 cleanup 清
    autoDanmaku(it); // 不 await:弹幕匹配要打网络,不能拖住起播后的 OSD 初始化
    /* 章节(跳过片头片尾 + 进度条缩略图)。同样不 await —— 它也是网络请求,
       而且**没有章节是常态**(库没刮削过就是空表),绝不能让它拖住或拦住起播。
       两个开关都关时核层直接返回空表,不会打服务器。 */
    chapterInfo(it.id, it.runtime_secs)
      .then(putChapters)
      .catch(() => putChapters(null)); // 拿不到就当没有,静默降级
    /* 本地下载/网盘源不走 playItem,也得把偏好读进来 —— 否则「更多」面板里
       跳片头/片尾两行永远是灰的。 */
    getPlaybackPrefs().then(setPbPrefs).catch(() => {});
    setTimeout(async () => {
      await applyPrefs().catch(() => {});
      /* 音轨/字幕**不在这里一次性拉**(见 [playing] 的轮询 effect)。
         网络流起播后 1.2s 往往还没 demux 出内封轨,track-list 为空 → 用户看到「字幕只有关闭/外挂、
         音轨整条不显示」(2026-07-16 报的)。改成轮询到位,别只赌这一枪。 */
      // 音量/倍速/静音/延迟/解码拉真值 —— 否则 OSD 滑块显示的是前端瞎猜的初值。
      try {
        const o = await playerOpts();
        setVol(Math.round(o.volume));
        setMuted(o.muted);
        setSpd(o.speed);
        speedRef.current = o.speed; // 连调基准也得跟着回读的真值走,否则长按会从 1.0 起跳
        setADelay(round1(o.audio_delay));
        setSDelay(round1(o.sub_delay));
        setHw(normHwdec(o.hwdec));
        /* 杜比视界软解:核层可能**已经自动切好了**(设置页那个开关 + 这片是 DV)。
           这行以前恒初始化成 false,于是「已经在软解、开关却显示关」。照实回读。 */
        setDolby(o.dolby_vision && normHwdec(o.hwdec) === "no");
        setShaderLv((lv) => (o.shader_count > 0 ? lv : "off"));
      } catch { /* 播放器未就绪:保持占位值,不弹错打扰起播 */ }
    }, 1200);
  }

  /** mediaSourceId = 详情页版本选择器选中的版本;省略 = 服务端给的第一个。
      ★ 这个第二参必须一路透传到 play():少了它,用户在详情页选了 4K 起播仍是
      默认版本,且**不报错** —— TS 上少参函数可赋给多参形参,编译期抓不到。 */
  async function playItem(it: Item, mediaSourceId?: string | null) {
    try {
      /* 外部播放器:设了就整条交出去,不进内置播放页。
         ★ 必须在 play() **之前**判 —— play() 会真的让内置 mpv 起播,
           之后再拉外部播放器就是两个播放器同时出声(本项目在
           [[desktop-double-audio-orphan-player]] 上栽过一模一样的跟头)。
         起不来时如实报错并回落内置播放器:外部程序可能被杀毒删了/被挪走了。
         ★ 这是个挡在起播前的串行 await([[perceived-slowness]] 点名的那类)。留着是权衡后的:
           它读的是**核层内存里的配置**,不打网络(~1ms);换成前端缓存就得自己做失效,
           缓存一旦过期 = 用户刚设完外部播放器却仍走内置,比 1ms 难受得多。 */
      const prefs = await getPlaybackPrefs().catch(() => null);
      setPbPrefs(prefs); // 顺手存下:播放页「更多」的跳片头/片尾两行要拿它显示真状态
      const ext = prefs?.external_player ?? "";
      if (ext) {
        try {
          await playExternal(it.id, it.resume_secs, mediaSourceId ?? null);
          say(`已用外部播放器打开:${ext.split(/[\\/]/).pop()}`);
          return;
        } catch (e) {
          say(`外部播放器启动失败(${e}),改用内置播放器`);
        }
      }
      const resume = await play(it.id, it.resume_secs, mediaSourceId ?? null);
      setPlaying(it);
      // 版本:详情页指定了就照它高亮,否则等 item_media 回来按服务端第一个初始化。
      setCurMsId(mediaSourceId ?? null);
      setStatus({ time: resume, duration: it.runtime_secs, paused: false, buffered: 0, eof: false });
      afterStart(it);
    } catch (e) {
      /* ★ 原来是 alert():Windows 原生模态框,和整套暗色 UI 完全不搭,而且**阻塞**——
         起播失败本就该继续留在原页面重试,弹个必须点确定的系统框只是添堵。
         走自家 .toast(和其它所有失败提示同一条口径,见 fail()) */
      say(`播放失败:${e}`);
    }
  }

  /** 播放已下载完成的本地文件(下载页 ▶ / 双击)。
      必须由 App 起播:mpv 的视频窗口压在 Tauri 窗口之下,只有 setPlaying 触发的
      .app-root.hidden 才让它露出来 —— 页面自己调 playLocal 只会有声音没画面。 */
  async function playDownload(d: DownloadItem) {
    try {
      const resume = await playLocal(d.id, 0);
      const synth: Item = {
        id: d.item_id || d.id, name: d.title, type_: "Video", is_folder: false, has_primary: false,
        runtime_secs: 0, resume_secs: resume, series_name: d.series_name, episode_no: d.episode_number,
        season_no: d.season_number, video_height: null, bitrate: null, size_bytes: d.total_bytes, date_updated: null, sort_name: null,
        played: false, unplayed_item_count: 0, genres: [], year: null, rating: null, provider_ids: {},
        presentation_unique_key: null, path: d.file_path, series_id: d.series_id,
      };
      setPlaying(synth);
      setCurMsId(null);
      setStatus({ time: resume, duration: 0, paused: false, buffered: 0, eof: false });
      afterStart(synth);
    } catch (e) {
      say(`播放下载文件失败:${e}`);
    }
  }

  async function playSource(entry: SourceEntry) {
    try {
      const start = await sourcePlay(entry, 0);
      // 网盘文件不是 Emby 条目:剧集号/规格字段一律 null。
      const synth: Item = { id: entry.id, name: entry.name, type_: "Video", is_folder: false, has_primary: false, runtime_secs: 0, resume_secs: 0, series_name: null, episode_no: null, season_no: null, video_height: null, bitrate: null, size_bytes: null, played: false, unplayed_item_count: 0, genres: [], year: null, rating: null, provider_ids: {}, presentation_unique_key: null, path: null, series_id: null, date_updated: null, sort_name: null };
      setPlaying(synth);
      setCurMsId(null);
      setStatus({ time: start, duration: 0, paused: false, buffered: 0, eof: false });
      afterStart(synth);
    } catch (e) {
      say(`播放失败:${e}`);
    }
  }

  async function refreshSession() {
    const s = await currentSession().catch(() => null);
    setSession(s);
  }

  /** 会话 + 活跃文件源一起拉。**两个都要**:核层把它们分在两个命令里
   *  (current_session 只认 Emby 型,current_source 只认文件浏览型),
   *  只刷一个的话切到另一类账号时界面会停在上一类的状态上。 */
  async function reloadEntry() {
    const [s, a] = await Promise.all([
      currentSession().catch(() => null),
      currentSource().catch(() => null),
    ]);
    setSession(s);
    setSrcAcc(a);
  }

  /* 登录闸口交棒:它自己先放 260ms 退场,这里接上主界面的入场。
     两段拼起来才是一次完整的"进入" —— 只做一头会显得前半段有动画、后半段是硬切。
     动画类挂一次就摘,不能常驻:留着的话之后每次重渲染都可能重放。 */
  async function enterFromLogin() {
    await reloadEntry();
    setEntering(true);
    if (enterTimer.current) window.clearTimeout(enterTimer.current);
    enterTimer.current = window.setTimeout(() => setEntering(false), 420);
  }
  useEffect(() => () => { if (enterTimer.current) window.clearTimeout(enterTimer.current); }, []);

  async function togglePause() {
    const p = !status.paused;
    await setPause(p).catch(() => {});
    setStatus((s) => ({ ...s, paused: p }));
    reportProgress(status.time, p);
  }
  const doSeek = (t: number) => { const v = Math.max(0, Math.min(status.duration || t, t)); seekApi(v); setStatus((s) => ({ ...s, time: v })); };

  /* ★ 进度条的「松手提交」必须挂在 **window** 上,不能挂在 <input> 自己身上。

     老写法是 `<input ... onMouseUp={...}>`。拖着滑块移出进度条(移出播放器、移出
     整个窗口都很常见)再松手时,input 收不到 mouseup —— `setSeeking(null)` 不执行,
     `seeking` 就永远停在最后拖到的那个值。而 `curTime = seeking ?? status.time`,
     于是进度条被**永久钉死**:画面照走、时间读数不动、条也不动。
     这就是用户报的「正常播放进度不走」——它不是轮询坏了,是一次拖拽把界面锁死了。

     pointerup 覆盖鼠标/触控/笔;pointercancel 管手势被系统接管;blur 管拖到一半
     Alt-Tab 走人(那时连 pointerup 都不会来)。三条任意一条到了就收工。 */
  useEffect(() => {
    if (seeking == null) return;
    const commit = () => {
      const v = seekingRef.current;
      seekingRef.current = null;
      setSeeking(null);
      if (v != null) seekApi(v).catch(() => {});
    };
    window.addEventListener("pointerup", commit);
    window.addEventListener("pointercancel", commit);
    window.addEventListener("blur", commit);
    return () => {
      window.removeEventListener("pointerup", commit);
      window.removeEventListener("pointercancel", commit);
      window.removeEventListener("blur", commit);
    };
    // 只关心「在不在拖」,不关心拖到哪 —— 拖动中的每一帧都重注册监听器纯属浪费。
  }, [seeking == null]);

  /** pos 省略 = 用当前进度。**播完(eof)必须显式传 st.duration**:
      status 是 state,轮询回调里读到的是闭包快照,靠它落库会把进度记成播放前的旧值,
      算出来的 progress 到不了 100%,Trakt/Bangumi 的「看完」就永远不触发。 */
  async function closePlayer(pos?: number) {
    await stopPlayback(pos ?? status.time);
    setPlaying(null);
    setTracks([]);
    setPanel(null);
    setVbar(null);
    setCtx(null);
    setSiblings([]);
    setBrightness(100);
  }

  /* 全屏切换期间把 OSD 藏起来(fsBusy),等窗口尺寸稳定了再淡回来。

     ★ 为什么需要:画面和 UI 是**两个渲染器**,天生不同步 ——
       - 画面(mpv)是个独立顶层窗口,`SetWindowPos` 一步到位,瞬时;
       - UI 是 WebView2,原生窗口变尺寸时它的合成器会先把**旧画面拉伸**顶着,
         再重排重绘,肉眼就是「画面已经放大了,UI 还在慢慢放大」(用户 2026-07-15 原话)。
     这不是我们哪个 CSS transition 干的(播放层只有 opacity 过渡),
     是浏览器合成器的行为,**追不平**。所以不去追,而是让这一段过渡不可见。 */
  const [fsBusy, setFsBusy] = useState(false);
  const fsTimer = useRef<number | null>(null);

  /** 藏 OSD → 切窗口 → 等尺寸不再变(连续 140ms 没有 resize)→ 放回来。 */
  async function withFsHidden(fn: (w: ReturnType<typeof getCurrentWindow>) => Promise<void>) {
    const w = getCurrentWindow();
    setFsBusy(true);
    try {
      await fn(w);
    } catch { /* 忽略:切不了全屏也得把 OSD 放回来,不能永远藏着 */ }
    /* 用防抖而不是固定延时:全屏一次会连着来好几个 resize 事件,
       固定 400ms 要么早了(还在抖)要么晚了(白等)。 */
    const settle = () => {
      if (fsTimer.current) window.clearTimeout(fsTimer.current);
      fsTimer.current = window.setTimeout(() => setFsBusy(false), 140);
    };
    settle();
    window.addEventListener("resize", settle);
    window.setTimeout(() => window.removeEventListener("resize", settle), 1200);
  }

  async function toggleFullscreen() {
    await withFsHidden(async (w) => w.setFullscreen(!(await w.isFullscreen())));
  }
  async function exitFullscreen() {
    await withFsHidden(async (w) => {
      if (await w.isFullscreen()) await w.setFullscreen(false);
    });
  }

  /* 播放页的窗口态(用户 2026-07-16:「点击全屏化就是一直全屏化了,根本没有其他的操作」)。

     根因不是全屏切不回来(f / Esc 一直能退),是**界面上看不出来**:
     播放时 <Titlebar/> 整个不渲染(那是给非播放页用的),而顶栏只有一个「全屏」按钮,
     图标和文案还永远是「全屏」—— 进了全屏之后,屏幕上没有任何一个可见的东西告诉你
     「最小化 / 窗口化」还存在。所以给播放页自绘一组窗口控制,三个动作各有各的按钮。

     fs/maxed 必须**回读窗口**而不是自己记账:双击标题栏、Win+↑、系统热键都会改变窗口态,
     只在点击时翻标志位,图标迟早和真实状态对不上。 */
  const [fs, setFs] = useState(false);
  const [maxed, setMaxed] = useState(false);
  useEffect(() => {
    const w = getCurrentWindow();
    const sync = () => {
      w.isFullscreen().then(setFs).catch(() => {});
      w.isMaximized().then(setMaxed).catch(() => {});
    };
    sync();
    let un: (() => void) | undefined;
    w.onResized(sync).then((f) => (un = f)).catch(() => {});
    return () => un?.();
  }, []);

  /** 窗口化:全屏中 = 退回窗口;不在全屏 = 最大化/还原互切。 */
  async function windowMode() {
    const w = getCurrentWindow();
    try {
      if (await w.isFullscreen()) {
        await exitFullscreen();
        return;
      }
      await w.toggleMaximize();
    } catch { /* 切不动就算了,别把播放页整崩 */ }
  }

  useEffect(() => {
    if (!playing) {
      if (timer.current) window.clearInterval(timer.current);
      return;
    }
    tick.current = 0;
    statusFail.current = 0;
    ended.current = false; // 换片必须解锁,否则第二部片播完不会自动收尾
    // 兜底:4s 后无论如何放行黑屏(暂停起播 st.time 不动,不能永远黑着)。
    const readyFallback = window.setTimeout(() => setReady(true), 4000);
    timer.current = window.setInterval(async () => {
      try {
        const st = await statusApi();
        statusRef.current = st;
        setStatus(st);
        if (st.time > 0) setReady(true); // 时间开始走 = 已出画,撤黑屏
        timeSync.current = { base: st.time, stamp: performance.now(), paused: st.paused };
        statusFail.current = 0;
        tick.current++;
        // 轮询提到 250ms 后,每 20 拍仍是 5s 上报一次 —— 别跟着轮询一起加倍打服务器。
        if (tick.current % 20 === 0) reportProgress(st.time, st.paused);
        sourceWatchdog(st.time);
        autoSkip(st.time);
        /* 正常播到结尾:走和用户手动点「返回」完全同一条路(closePlayer → stopPlayback),
           位置传 st.duration —— 播完了位置就是总时长,后端才算得出 100%。
           ★ 上锁:eof 会一直是 true,而这个回调每 500ms 跑一次,不锁就重复 stop。
             用 ref 不用 state:state 要等重渲染才更新,同一帧内的下一次 tick 读到的还是旧值。 */
        if (st.eof && !ended.current) {
          ended.current = true;
          // duration 拿不到(某些直链/网盘流报 0)就退回 time —— keep-open 下它停在最后一帧,
          // 已经是本片能拿到的最大进度;传 0 会把刚看完的片记成「没看」。
          await closePlayer(st.duration || st.time);
        }
      } catch (e) {
        /* ★ 原来这里是空 catch(「未就绪忽略」)。起播头几拍确实会失败,忽略是对的 ——
           但它同时把**持续失败**也一并咽了:status 一直取不到时 status.time 就永远停在
           起播时塞进去的续播位置,界面表现为「进度条停在上次看到的地方一动不动」,
           而画面在正常播。这类故障之所以只能靠猜,就是因为它一声不吭。
           前 8 拍(2s)照旧静默,之后说一次。只说一次,不刷屏。 */
        statusFail.current++;
        if (statusFail.current === 8) say(`播放状态读取失败,进度条可能不准:${e}`);
      }
    }, 250);
    return () => { if (timer.current) window.clearInterval(timer.current); window.clearTimeout(readyFallback); };
  }, [playing]);

  /* 定时关闭的兜底清理:换片/退播放器/组件卸载都必须 clearTimeout,
     否则播放器都关了它还在后台跑,到点 closePlayer 一个不存在的播放器。 */
  useEffect(() => {
    return () => {
      if (sleepTimer.current) { window.clearTimeout(sleepTimer.current); sleepTimer.current = null; }
    };
  }, [playing]);

  // OSD 自动隐藏(鼠标静止 3s)。
  useEffect(() => {
    if (!playing) return;
    const wake = () => {
      setIdle(false);
      if (idleTimer.current) window.clearTimeout(idleTimer.current);
      idleTimer.current = window.setTimeout(() => setIdle(true), 3000);
    };
    wake();
    window.addEventListener("mousemove", wake);
    return () => { window.removeEventListener("mousemove", wake); if (idleTimer.current) window.clearTimeout(idleTimer.current); };
  }, [playing]);

  /* 拉当前剧的分集列表(上一集/下一集/选集全靠它)。
     Item 本身没有 series_id,但 item_detail(集) 会回 series_id,
     再 item_detail(剧) 的 children 就是按季+集号排好序的全部分集(且带 MediaSources 规格)。 */
  useEffect(() => {
    if (!playing || playing.type_ !== "Episode") { setSiblings([]); return; }
    let dead = false;
    (async () => {
      try {
        const ep = await itemDetail(playing.id);
        if (dead || !ep.series_id) return;
        const series = await itemDetail(ep.series_id);
        if (!dead) setSiblings(series.children);
      } catch { /* 网盘/非 Emby 条目没有剧集树,静默 */ }
    })();
    return () => { dead = true; };
  }, [playing]);

  /* 音轨/字幕轮询到位。网络流 demux 慢,起播后内封轨要等几秒才在 track-list 出现 ——
     只在 afterStart 拉一枪必然赶不上,表现为「字幕只有关闭/外挂、音轨不显示」(2026-07-16)。
     这里从起播起每 700ms 探一次,拿到非空就停;最多 ~11s(16 次)兜底,别无限探。
     换集/换版本(playing 变或 setTracks 被 switchVersion 重置)自动重来。 */
  useEffect(() => {
    if (!playing) { setTracks([]); return; }
    /* ★ 别在「第一次非空」就停 —— 网络流里音轨常先于字幕 demux 出来,外挂字幕更是
       要等核层收到 FILE_LOADED 才挂得上。实现搬到 shared/track-poll.ts 与 TV 共用:
       TV 端原先自己写了个「拉一次」的残缺版,外挂字幕永远进不了面板。 */
    return pollTracks(setTracks);
  }, [playing]);

  // 版本面板 + 「更多」的静态播放信息都要 MediaSources:开这两个面板任一时拉,省请求。
  useEffect(() => {
    if ((panel !== "version" && panel !== "more") || !playing || versions) return;
    itemMedia(playing.id)
      .then((vs) => {
        setVersions(vs);
        // play() 不传 mediaSourceId 时核层用服务端给的第一个,故没切过版本时就高亮它。
        // 以前这里写死 i===0,切完版本高亮还赖在第一行 —— 别再用下标当选中态。
        setCurMsId((id) => id ?? vs[0]?.id ?? null);
      })
      .catch(() => setVersions([]));
  }, [panel, playing, versions]);

  /* 线路:**先出表,再逐条探**(用户 2026-07-16:「不需要做延迟探测,要做也是先显示线路
     再去探测 —— 不然一条线路探了好久,一直卡在那怎么办?」)。

     以前是 `setLineProbes(await probeLines(...))`:整表一次性返回,而 probe_lines 要等
     **最慢的那条**(最坏 6s 超时)。于是一条死线 = 整个面板扣住 6s 只显示「探测中…」,
     用户连切到那条能用的线都做不到 —— 而他打开这个面板,十有八九正是因为当前线路不通。

     现在:线路表直接从账号配置渲染(本地数据,零等待、立刻可点),再对每条线各发一个
     probe_line 各回各的。死线只让它自己那一行转圈,不牵连别人。
     ★ server_id 是**账号键**(list_accounts().server),不是 session.server:
       set_active_line 切完会把 session.server 改写成那条线路的 URL,此后拿它去探
       只会得到「找不到该服务器」。踩过,别改回去。
     草稿 L1037「进入服务器自动探测 · 缓存至退出程序清空」→ lineMs 非空即不重探。 */
  useEffect(() => {
    if (panel !== "line" || lineMs) return;
    let dead = false;
    (async () => {
      try {
        const a = (await listAccounts()).find((x) => x.active);
        if (dead) return;
        if (!a) { setLineErr("没有活跃的服务器账号"); return; }
        setAcct(a);
        setLineErr(null);
        setLineMs({}); // 开工:表已可渲染,同时关掉重入
        // 行数口径必须和核层 line_urls 一致:没配 lines 时 server 本身算一条。
        const n = a.lines.length || 1;
        for (let i = 0; i < n; i++) {
          probeLine(a.server, i)
            .then((p) => {
              // 逐条合并,不整表覆写 —— 覆写会把已回来的其它行抹掉。
              if (!dead) setLineMs((m) => ({ ...(m ?? {}), [p.index]: p.ms }));
            })
            .catch(() => {
              // 探测本身失败(命令报错)≠ 线路不通,但对用户是一回事:这条给不出延迟。
              if (!dead) setLineMs((m) => ({ ...(m ?? {}), [i]: null }));
            });
        }
      } catch (e) {
        if (!dead) setLineErr(String(e));
      }
    })();
    return () => { dead = true; };
  }, [panel, lineMs]);

  /** 切线路:立即生效无需重启(核层会同步刷新活跃会话地址)。 */
  async function switchLine(index: number) {
    if (!acct) return;
    try {
      await setActiveLine(acct.server, index); // 同上:必须是账号键
      setAcct({ ...acct, active_line: index });
      /* ★ 必须把前端 session 也拉一遍:核层改的是它自己那份会话,前端这份 session.server
         还是旧线路 —— 而 poster/backdrop/thumb/person 的 URL 全是拿 session.server 现拼的。
         不刷的话,用户正因为旧线不通才切线路,切完图片却继续打那条死线,看起来「切了跟没切一样」。 */
      await refreshSession();
      say(`已切到${lineName(acct, index)}`);
    } catch (e) { fail("切换线路", e); }
  }

  /** 切版本:mpv 一次只开一路流,没有热换源 → 只能 stop 再 play。
      先 stop_playback 把进度落库(不然这一段观看记录直接丢),再用当前位置起播新 MediaSource。 */
  async function switchVersion(v: MediaVersion) {
    if (!playing || v.id === curMsId) return;
    const at = status.time;
    try {
      await stopPlayback(at);
      const resume = await play(playing.id, at, v.id);
      setCurMsId(v.id);
      setStatus((s) => ({ ...s, time: resume, paused: false }));
      // 新版本 = 新的音/字轨表,得重拉;沿用 afterStart 的 1.2s 等播放器就绪。
      // 但不走整个 afterStart:同一集重开,弹幕不该重置更不该再匹配一次。
      setTimeout(async () => {
        await applyPrefs().catch(() => {});
        setTracks(await tracksApi().catch(() => []));
      }, 1200);
      say(`已切换版本 · 从 ${fmtTime(resume)} 继续`);
    } catch (e) { fail("切换版本", e); }
  }

  // 标题溢出才跑马灯,短标题白晃眼(草稿标注 17)。
  useEffect(() => {
    const el = titleRef.current;
    if (!el) { setMarquee(false); return; }
    setMarquee(el.scrollWidth > el.clientWidth + 2);
  }, [playing]);

  const epIndex = playing ? siblings.findIndex((s) => s.id === playing.id) : -1;
  const prevEp = epIndex > 0 ? siblings[epIndex - 1] : null;
  const nextEp = epIndex >= 0 && epIndex < siblings.length - 1 ? siblings[epIndex + 1] : null;

  /** 切集:先把当前进度落库再起播,否则这一集的观看记录丢了。 */
  async function goEpisode(ep: Item | null, dir: "上" | "下") {
    if (ep) {
      await stopPlayback(status.time);
      await playItem(ep);
      return;
    }
    if (siblings.length === 0) say("当前条目没有剧集列表");
    else say(`已经是${dir === "上" ? "第一" : "最后一"}集了`);
  }

  /** 复制当前时间:纯前端,真能做。 */
  async function copyTime() {
    try {
      await navigator.clipboard.writeText(fmtTime(status.time));
      say(`已复制 ${fmtTime(status.time)}`);
    } catch {
      say("复制失败:剪贴板不可用");
    }
  }

  /* ---- 播放器可调项:先落 UI 再调核层,失败如实 toast ---- */

  /** 音量 0..100(mpv 收到 130 是软增益,竖条按草稿只给到 100)。拖动会高频触发,
      set_property 是内存写不打网络,不做节流。 */
  async function applyVolume(v: number) {
    const n = Math.round(Math.max(0, Math.min(100, v)));
    setVol(n);
    if (muted && n > 0) { setMuted(false); await setMuteApi(false).catch(() => {}); } // 拖音量=想听见
    try { await setVolumeApi(n); } catch (e) { fail("音量", e); }
  }
  async function applyMute(m: boolean) {
    setMuted(m);
    try { await setMuteApi(m); } catch (e) { setMuted(!m); fail("静音", e); }
  }
  /** 倍速:草稿范围 0.25×–5.0×(核层再 clamp 到 0.1–6)。 */
  async function applySpeed(v: number) {
    const s = Math.max(0.25, Math.min(5, round1(v * 100) / 100));
    speedRef.current = s; // 先记 ref:连调下一拍(120ms 后)靠它,等 state 回来就晚了
    setSpd(s);
    try { await setSpeedApi(s); } catch (e) { fail("倍速", e); }
  }
  /** 长按 +/− 连调(草稿 L1086):按下先走一步,之后每 120ms 一步,松手/移出即停。 */
  const stopRepeat = () => { if (repeat.current) { window.clearInterval(repeat.current); repeat.current = null; } };
  const holdRepeat = (step: () => void) => {
    step();
    stopRepeat(); // 防上一次 mouseup 丢了(比如在窗口外松的手)留下野 interval
    repeat.current = window.setInterval(step, 120);
  };
  const bumpSpeed = (d: number) => applySpeed(speedRef.current + d);
  // 组件卸载兜底:连调途中被卸载,interval 还在调一个不存在的播放器。
  useEffect(() => stopRepeat, []);
  async function applyADelay(v: number) {
    const s = round1(v);
    setADelay(s);
    try { await setAudioDelay(s); } catch (e) { fail("音频延迟", e); }
  }
  async function applySDelay(v: number) {
    const s = round1(v);
    setSDelay(s);
    try { await setSubDelay(s); } catch (e) { fail("字幕延迟", e); }
  }
  async function applyAspect(r: string) {
    setAspect(r); setArOpen(false);
    try { await setAspectRatioApi(r); say(`画面比例:${ASPECTS.find(([id]) => id === r)?.[1] ?? r}`); }
    catch (e) { fail("画面比例", e); }
  }
  async function applyHwdec(m: string) {
    setHw(m);
    if (m !== "no") setDolby(false); // 手动切回硬解 = 杜比软解自然失效,开关别再显示成开着
    try { await setHwdecApi(m); say(`解码方式:${HWDECS.find(([id]) => id === m)?.[1] ?? m}`); }
    catch (e) { fail("解码方式", e); }
  }
  /* 杜比视界软解 = gpu-next + 软解(本项目既定做法,见 [[dolby-auto-decode]])。
     核层 init 已无条件 set("vo","gpu-next")(mpv.rs:152),gpu-next 这半永远成立,
     故这里只切 hwdec:运行时改 vo 会触发 VO 重初始化(白闪/d3d11 上下文churn,
     本项目在这类坑上栽过),为设一个本就设好的值去冒这风险不值。 */
  async function applyDolby(on: boolean) {
    /* 关掉时回到**用户设的默认解码方式**,不是写死 auto-safe ——
       默认设成软解的人关一下这个开关,反而被切成硬解,那叫帮倒忙。 */
    const mode = on ? "no" : (pbPrefs?.hwdec ?? "auto-safe");
    setDolby(on);
    setHw(mode);
    try {
      await setHwdecApi(mode);
      say(on ? "杜比视界软解已开启 · gpu-next + 软解" : "杜比视界软解已关闭 · 恢复硬解");
    } catch (e) { setDolby(!on); fail("杜比视界软解", e); }
  }
  /** 定时关闭:到点直接关播放器(closePlayer 会 stopPlayback 落进度,睡着了也不丢记录)。 */
  function applySleep(min: number | null) {
    if (sleepTimer.current) { window.clearTimeout(sleepTimer.current); sleepTimer.current = null; }
    setSleepMin(min);
    setSleepOpen(false);
    if (min == null) { say("已取消定时"); return; }
    sleepTimer.current = window.setTimeout(() => {
      sleepTimer.current = null;
      setSleepMin(null);
      closePlayer();
      say("已定时关闭播放");
    }, min * 60_000);
    say(`已设置 ${min} 分钟后关闭`);
  }
  /** 超分:核层挂完**双重回读** —— glsl-shaders 校验挂没挂上,尺寸校验会不会真跑。
      ★ 别只看 count 就报「已生效」:Anime4K 每个 pass 都带「输出 > 源 ×1.2」的门槛,
        窗口没比源大时整条链一帧都不跑,画面毫无变化,而旧文案还在说「已生效·挂载 6 个」——
        那就是假开,正是 [[superres-and-toast]] 要防的东西,结果自己又犯了一遍。 */
  async function applyShader(id: string) {
    try {
      const r = await setShaderLevel(id);
      setShaderLv(id);
      if (id === "off") { say("超分已关闭"); return; }
      // will_run=false:挂上了但不会跑 → 把核层给的真实数字原样告诉用户,别粉饰成成功。
      say(r.will_run === false && r.note ? r.note : `超分已生效 · 挂载 ${r.count} 个 shader`);
    } catch (e) {
      say(`超分未生效:${e}`); // 档位高亮不动:没生效就别显示成选中
    }
  }
  /** 字幕样式。scalePct 是**百分比**(UI 口径),传给核层前折成倍率 —— mpv 的 sub-scale 是倍率。 */
  async function applySubStyle(o: { font?: string; scalePct?: number; position?: number }) {
    if (o.font !== undefined) { setSubFont(o.font); setFontOpen(false); }
    if (o.scalePct !== undefined) setSubScale(o.scalePct);
    if (o.position !== undefined) setSubPos(o.position);
    try {
      await setSubStyle({
        font: o.font,
        scale: o.scalePct !== undefined ? o.scalePct / 100 : undefined,
        position: o.position,
      });
    } catch (e) { fail("字幕样式", e); }
  }
  async function applySec2(id: string) {
    setSec2(id);
    try { await setSecondarySub(id); } catch (e) { fail("次字幕", e); }
  }
  async function applySec2Opts(o: { delay?: number; position?: number; assOverride?: string }) {
    if (o.delay !== undefined) setSec2Delay(o.delay);
    if (o.position !== undefined) setSec2Pos(o.position);
    if (o.assOverride !== undefined) setSec2Ass(o.assOverride);
    try { await setSecondarySubOpts(o); } catch (e) { fail("次字幕设置", e); }
  }
  /** 截图:核层返回落盘路径,报给用户(不然不知道存哪了)。 */
  async function doShot() {
    try { say(`截图已保存:${await screenshot()}`); } catch (e) { fail("截图", e); }
  }
  /** 外挂字幕:没装 @tauri-apps/plugin-dialog(且不为此加依赖),故用路径/URL 输入框。 */
  async function doAddSub() {
    const u = (subUrl || "").trim();
    if (!u) return;
    try {
      await addSubtitle(u);
      setSubUrl(null);
      // sub-add 用 flags=auto 不自动切轨,故刷新列表让用户自己选那条新字幕。
      setTracks(await tracksApi().catch(() => []));
      say("外挂字幕已加载,请在左侧列表选中");
    } catch (e) { fail("加载外挂字幕", e); }
  }

  /** 竖条贴着按钮弹(草稿 21):取按钮中心当锚点。 */
  const openVbar = (kind: "vol" | "bright", e: React.MouseEvent) => {
    if (vbar?.kind === kind) { setVbar(null); return; }
    const r = e.currentTarget.getBoundingClientRect();
    setVbar({ kind, x: r.left + r.width / 2 - 22 });
  };

  /** 竖条拖动:草稿要求「鼠标上下拖动」,故按下即跟随,松手结束。 */
  const dragVbar = (e: React.MouseEvent<HTMLElement>, set: (v: number) => void) => {
    const el = e.currentTarget;
    const apply = (clientY: number) => {
      const r = el.getBoundingClientRect();
      set(Math.round(Math.max(0, Math.min(100, ((r.bottom - clientY) / r.height) * 100))));
    };
    apply(e.clientY);
    const move = (ev: MouseEvent) => apply(ev.clientY);
    const up = () => { window.removeEventListener("mousemove", move); window.removeEventListener("mouseup", up); };
    window.addEventListener("mousemove", move);
    window.addEventListener("mouseup", up);
  };

  /* 键盘快捷键(草稿 kbdcard,取代移动端手势)。仅播放时生效,全部真调核层。 */
  useEffect(() => {
    if (!playing) return;
    const onKey = (e: KeyboardEvent) => {
      // 输入框里不劫持,否则弹幕搜索框敲不了字。
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) return;
      if (e.ctrlKey || e.metaKey || e.altKey) return;

      switch (e.key) {
        case " ": e.preventDefault(); togglePause(); break;
        // 位置从 ref 取,不从 state ——「快捷键要用到 status」是这个 effect 依赖 status
        // 的唯一理由,而 status 每 250ms 换一个新对象,依赖它 = 每秒 4 次卸载重装监听器。
        case "ArrowLeft": e.preventDefault(); doSeek(statusRef.current.time - 10); break;
        case "ArrowRight": e.preventDefault(); doSeek(statusRef.current.time + 10); break;
        case "ArrowUp":
        case "ArrowDown": {
          e.preventDefault();
          applyVolume(volume + (e.key === "ArrowUp" ? 5 : -5));
          setVbar((b) => b?.kind === "vol" ? b : { kind: "vol", x: 24 }); // 顺手把竖条弹出来当读数
          break;
        }
        case "f": case "F": e.preventDefault(); toggleFullscreen(); break;
        case "Escape":
          e.preventDefault();
          if (ctx) setCtx(null);
          else if (vbar) setVbar(null);
          else if (panel) setPanel(null);
          else exitFullscreen();
          break;
        case "[": e.preventDefault(); applySpeed(speed - 0.25); say(`倍速 ${(Math.max(0.25, speed - 0.25)).toFixed(2)}×`); break;
        case "]": e.preventDefault(); applySpeed(speed + 0.25); say(`倍速 ${(Math.min(5, speed + 0.25)).toFixed(2)}×`); break;
        case "m": case "M": e.preventDefault(); applyMute(!muted); say(muted ? "已取消静音" : "已静音"); break;
        case "p": case "P": e.preventDefault(); goEpisode(prevEp, "上"); break;
        case "n": case "N": e.preventDefault(); goEpisode(nextEp, "下"); break;
        case "s": case "S": e.preventDefault(); doShot(); break;
        case "d": case "D": e.preventDefault(); patchDm((d) => ({ on: !d.on })); break;
        default: break;
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
    // ★ 依赖里**去掉了 status**:它每 250ms 就是一个新对象,留着等于每秒把
    //   keydown 监听器卸载重装 4 次(还连带重建整个 onKey 闭包)。真正要用到的
    //   只有 status.time,已改走 statusRef。其余几项都是低频状态,留着无妨。
  }, [playing, panel, vbar, ctx, prevEp, nextEp, volume, muted, speed]);

  /* ★ danmaku_search 回的是 Vec<DanmakuSourceGroup>(一源一组),**不是**番剧数组:
     曾经这里按 {anime_id, anime_title, episodes} 收,渲染时 a.episodes.map() 直接
     TypeError 把整个播放器渲染打挂(白屏)。分组结构见 api.ts DanmakuSourceGroup,别再拍平。 */
  async function doDmSearch() {
    const q = dmKw.trim();
    if (!q) return;
    setDmPick(null); // 换关键词 = 退回条目层,否则还停在上一次点开的番的集表里
    try { setDmResults(await danmakuSearch(q)); } catch (e) { fail("弹幕搜索", e); }
  }
  /** 第二段:点条目 → 取该条目的集列表。集表不预取,搜索结果里本来就没有。 */
  async function openDmAnime(g: DanmakuSourceGroup, a: DanmakuAnime) {
    setDmPick({ group: g, anime: a, episodes: null });
    try {
      const eps = await danmakuEpisodes(g.source_id, a.anime_id, a.anime_title);
      setDmPick({ group: g, anime: a, episodes: eps });
    } catch (e) { setDmPick(null); fail("取集列表", e); }
  }
  async function loadDmEpisode(sourceId: string, ep: DanmakuEpisode) {
    try {
      setDmComments(await danmakuLoad(ep.episode_id, sourceId));
      patchDm({ on: true }); // 手动挑了一集 = 明确要看,这一处强开(并落盘)
      setDmResults(null);
      setDmPick(null);
      say(`弹幕已加载 · ${ep.episode_title || ep.episode_number || ""}`);
    } catch (e) { fail("加载弹幕", e); }
  }

  if (!booted) return null;
  /* ★ 进不进得了门,看的是「有没有活跃账号」,不是「有没有 Emby 会话」。
     核层的 current_session 会 `.filter(|a| !a.is_file_browse())` —— 只连了网盘/Stremio/
     插件源的用户在那边**永远返回 null**。老登录页只能连 Emby,所以这条一直没暴露;
     新的登录闸口把六类源全摆出来了,再只判 session 就会出现「加成功了还是回登录页,
     加一次挡一次」。 */
  if (!session && !srcAcc) return (<><Titlebar /><LoginPage onLoggedIn={enterFromLogin} /></>);

  const audio = tracks.filter((t) => t.kind === "audio");
  const subs = tracks.filter((t) => t.kind === "sub");
  /* 「更多 · 播放信息」的静态规格(用户 2026-07-16:要常见静态项 —— 分辨率/码率/大小/
     字幕格式/音频格式,不要动态的时长/状态)。取当前在播版本的流规格(item_media)。 */
  const curVer = versions?.find((v) => v.id === curMsId) ?? versions?.[0] ?? null;
  const vStream = curVer?.streams.find((s) => s.type_ === "Video") ?? null;
  const uniqCodecs = (kind: string) =>
    curVer ? [...new Set(curVer.streams.filter((s) => s.type_ === kind).map((s) => s.codec.toUpperCase()))].join(" / ") : "";
  const aCodecs = uniqCodecs("Audio");
  const sCodecs = uniqCodecs("Subtitle");
  const infoRes = vStream?.width && vStream?.height ? `${vStream.width}×${vStream.height}` : fmtRes(playing?.video_height ?? null);
  const infoBitrate = fmtBitrate(curVer?.bitrate ?? playing?.bitrate ?? null);
  const infoSize = fmtSize(curVer?.size_bytes ?? playing?.size_bytes ?? null);
  const curTime = seeking ?? status.time;
  const pct = status.duration > 0 ? (curTime / status.duration) * 100 : 0;
  const bufPct = status.duration > 0 ? (status.buffered / status.duration) * 100 : 0;
  const wide = panel === "sub" || panel === "danmaku" || panel === "more";

  const pb = (i: React.ReactNode, label: string, on: boolean, click: (e: React.MouseEvent) => void, hot = false) => (
    <button className={`pb${on ? " on" : ""}${hot ? " hot" : ""}`} onClick={click} title={label}>
      <span className="i">{i}</span>
      {label}
    </button>
  );
  const togglePanel = (p: Panel) => () => { setPanel(panel === p ? null : p); setVbar(null); };
  /** 草稿的 stepper:−/＋ 夹一个值。 */
  const stepper = (label: string, val: React.ReactNode, dec: () => void, inc: () => void) => (
    <div className="p-li static" key={label}>
      {label}
      <span className="p-stepper">
        <button className="b" onClick={dec}>−</button>
        <b>{val}</b>
        <button className="b" onClick={inc}>＋</button>
      </span>
    </div>
  );
  /** 草稿的开关(尚无核层命令的项统一给诚实提示)。 */
  const swRow = (label: string, on: boolean, click: () => void) => (
    <div className="p-li static" key={label}>
      {label}
      <button className={`p-sw${on ? " on" : ""}`} onClick={click}><i /></button>
    </div>
  );

  // 标题:剧名 · S1E4 · 集名(草稿 L926)。
  const epTag = playing && playing.season_no != null && playing.episode_no != null
    ? `S${playing.season_no}E${playing.episode_no}` : null;
  const title = playing ? [playing.series_name, epTag, playing.name].filter(Boolean).join(" · ") : "";

  return (
    <>
      {/* 自绘标题栏:播放时不渲染(让 mpv 全屏铺满,且不与播放器顶栏冲突)。 */}
      {!playing && <Titlebar />}
      <div className={`app-root${playing ? " hidden" : ""}${entering ? " entering" : ""}`}>
        <Shell
          /* 只连了网盘/Stremio/插件源时没有 Emby 会话 —— 用活跃源顶一个上去。
             Shell 只拿 session.server 当「当前服务器」的标识(侧栏高亮 + 切换判断),
             token/user_id 那两条路对文件浏览型源本来就走不到(它们不打 Emby API)。 */
          session={session ?? { server: srcAcc!.server, token: "", user_id: "", user_name: srcAcc!.name }}
          /* 网盘源没有 Emby 媒体库,首页会是空的 —— 直接落文件浏览页。 */
          initialPage={!session && srcAcc ? "netdisk" : undefined}
          onPlay={playItem}
          onPlaySource={playSource}
          onPlayDownload={playDownload}
          onSessionChange={refreshSession}
          searchOpen={searchOpen && !playing}
          onSearch={() => setSearchOpen(true)}
          onCloseSearch={() => setSearchOpen(false)}
        />
      </div>

      {/* 出第一帧前的黑屏 + 加载动画:盖住 mpv 独立窗口,不露上一段残帧(用户 2026-07-16)。 */}
      {playing && !ready && (
        <div className="p-loading"><div className="sp" /></div>
      )}

      {/* 亮度遮罩:核层没有亮度命令,但 mpv 画面在网页层下面,盖一层黑就是真调光。
          放在 player-layer 外面,否则 OSD 淡出时亮度跟着一起变。 */}
      {playing && brightness < 100 && (
        <div className="p-dim" style={{ opacity: ((100 - brightness) / 100) * 0.85 }} />
      )}

      {/* 弹幕层外包一层:不透明度/显示区域纯 CSS 就能真生效(Danmaku.tsx 不动)。 */}
      {playing && (
        <div
          className="p-dmwrap"
          style={{ opacity: dmOpacity / 100, clipPath: `inset(0 0 ${100 - DM_AREAS[dmArea]}% 0)` }}
        >
          {/* 速度/字号:核层只管过滤去重,渲染参数本就是前端的事 → 直接透传 props。 */}
          <DanmakuLayer
            comments={dmComments}
            timeSync={timeSync}
            enabled={dmOn}
            duration={DM_SPEEDS[dmSpeed][0]}
            fontSize={DM_SIZES[dmSize][0] ?? undefined}
          />
        </div>
      )}

      {playing && (
        /* fs-busy:全屏切换期间整层瞬时隐藏(见 withFsHidden) —— 和 idle 的淡出是两回事,
           所以给了独立的 class,别合并:idle 要 0.4s 淡,这里要立刻消失。 */
        <div
          className={`player-layer${idle && !panel && !vbar && !ctx ? " idle" : ""}${fsBusy ? " fs-busy" : ""}`}
        >
          {/* 画面区:接右键菜单(草稿 L1152),点空白收起弹出层 */}
          <div
            className="p-stage"
            onContextMenu={(e) => { e.preventDefault(); setCtx({ x: e.clientX, y: e.clientY }); }}
            onClick={() => { setVbar(null); setCtx(null); }}
          />

          {/* 顶栏 */}
          <div className="p-top">
            <button className="p-back" onClick={() => closePlayer()} title="返回">
              <IconChevronLeft size={17} />
            </button>
            <span className={`p-title${marquee ? " run" : ""}`} ref={titleRef} title={title}>
              <b>{title}</b>
            </span>
            {/* 拖动区:窗口化播放时,<Titlebar/> 不在 = 没有任何地方能拖窗口 ——
                给了「窗口化」却挪不动那个窗口,等于没给。这条弹性空白就是播放页的标题栏。 */}
            <div className="p-drag" data-tauri-drag-region />
            <span className="p-top-r">
              {pb("✦", "超分", panel === "super", togglePanel("super"))}
              {pb("⇄", "线路", panel === "line", togglePanel("line"))}
              {pb("◈", "版本", panel === "version", togglePanel("version"))}
              {pb("⋯", "更多", panel === "more", togglePanel("more"))}
              <span className="p-sep" />
              {/* 自绘窗口控制:播放时 <Titlebar/> 不渲染,这三个动作在播放页只能自己长出来。
                  纯图标(顶栏已经四个带字按钮了,再加三个字满得没法看),动作靠 title 说明。
                  没有「关闭」—— 播放页的返回键在左上角,这里再放个 × 只会让人误关整个 app。 */}
              <span className="p-win">
                <button className="p-wb" title="最小化" onClick={() => void getCurrentWindow().minimize()}>
                  <IconMinimize size={15} />
                </button>
                <button className="p-wb" title={fs ? "窗口化" : maxed ? "还原" : "最大化"} onClick={windowMode}>
                  {maxed && !fs ? <IconRestore size={14} /> : <IconWindow size={14} />}
                </button>
                <button className="p-wb hot" title={fs ? "退出全屏" : "全屏"} onClick={toggleFullscreen}>
                  {fs ? <IconFullscreenExit size={15} /> : <IconFullscreen size={15} />}
                </button>
              </span>
            </span>
          </div>

          {/* 跳过片头/片尾的撤销条。章节名匹配不可能 100% 准,跳错了必须能一键跳回去 ——
              没有退路的自动跳过,比不跳还烦人。6 秒后自淡出。 */}
          {skipTip && (
            <div className="p-skiptip">
              <span>{skipTip.label}</span>
              <button
                className="btn"
                onClick={() => {
                  seekApi(skipTip.from).catch(() => {});
                  setSkipTip(null);
                }}
              >
                撤销
              </button>
            </div>
          )}

          {/* 底栏 */}
          <div className="p-bot">
            <div className="p-scrubrow">
              <span className="p-tc l">{fmtTime(curTime)}</span>
              {/* 悬停预览(草稿 pin 18):时间读数 + 服务端章节图缩略图。
                  缩略图是**尽力而为**——服务端没刮削章节图(chapters 空 / image_url 为 null)
                  就只出时间读数。按草稿「没有就不显示、不硬凑」,绝不画假缩略图。
                  精度也如实说:章节图每章一张(通常几分钟一张),不是逐秒的 trickplay 雪碧图,
                  悬停到哪就取**不晚于该时间点**的那一张。 */}
              <div
                className={`p-scrub${seeking != null ? " dragging" : ""}`}
                onMouseMove={(e) => {
                  const r = e.currentTarget.getBoundingClientRect();
                  const x = Math.max(0, Math.min(r.width, e.clientX - r.left));
                  setHoverT({ x, t: (x / r.width) * status.duration });
                }}
                onMouseLeave={() => setHoverT(null)}
              >
                <span className="buf" style={{ width: `${bufPct}%` }} />
                <span className="fill" style={{ width: `${pct}%` }} />
                <span className="knob" style={{ left: `${pct}%` }} />
                {hoverT && status.duration > 0 && (
                  <span className="prev" style={{ left: hoverT.x }}>
                    {(() => {
                      const src = thumbAt(hoverT.t);
                      // onError 兜底:章节图 401/404 时把自己藏掉,只留时间读数,
                      // 不要在气泡里留一个碎图图标(那比没有还难看)。
                      return src ? (
                        <img
                          className="shot"
                          src={src}
                          alt=""
                          onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = "none"; }}
                        />
                      ) : null;
                    })()}
                    <span className="tc">{fmtTime(hoverT.t)}</span>
                  </span>
                )}
                <input
                  type="range" min={0} max={Math.max(1, status.duration)} step={0.5}
                  value={curTime}
                  onChange={(e) => { const v = Number(e.target.value); seekingRef.current = v; setSeeking(v); }}
                  // 提交在 window 的 pointerup/pointercancel/blur 上,见 doSeek 下面那个 effect。
                />
              </div>
              <span className="p-tc">{fmtTime(status.duration)}</span>
            </div>
            <div className="p-ctrls">
              <span className="p-grp">
                {pb(<IconPrev size={16} />, "上一集", false, () => goEpisode(prevEp, "上"))}
                {pb(<IconNext size={16} />, "下一集", false, () => goEpisode(nextEp, "下"))}
                <span className="p-sep" />
                {pb(<IconVolume size={16} />, "音量", vbar?.kind === "vol", (e) => openVbar("vol", e))}
                {pb(<IconSun size={16} />, "亮度", vbar?.kind === "bright", (e) => openVbar("bright", e))}
              </span>
              <span className="p-grp">
                {pb(<IconRewind size={16} />, "快退", false, () => doSeek(curTime - 10))}
                <button className="pb hot big" onClick={togglePause} title="播放/暂停">
                  <span className="i">{status.paused ? <IconPlay size={18} /> : <IconPause size={18} />}</span>
                  {status.paused ? "播放" : "暂停"}
                </button>
                {pb(<IconForward size={16} />, "快进", false, () => doSeek(curTime + 10))}
              </span>
              {/* 草稿底栏右恰好 5 键:选集·音轨·字幕·弹幕·倍速。
                  弹幕开关按草稿收在弹幕面板里(见 L1115),故这里点击=开面板,与另外 4 键一致;开关另有 D 键。 */}
              <span className="p-grp">
                {pb(<IconList size={16} />, "选集", panel === "eps", togglePanel("eps"))}
                {audio.length > 0 && pb("♪", "音轨", panel === "audio", togglePanel("audio"))}
                {pb("文", "字幕", panel === "sub", togglePanel("sub"))}
                {pb("弹", "弹幕", dmOn, togglePanel("danmaku"))}
                {pb("▸", "倍速", panel === "speed", togglePanel("speed"))}
              </span>
            </div>
          </div>

          {/* 音量 / 亮度竖条(草稿 21) */}
          {vbar && (
            <div className="p-vbar" style={{ left: vbar.x }}>
              {/* 音量条的图标兼作静音键(草稿没画独立静音键,M 键同此) */}
              {vbar.kind === "vol" ? (
                <button className={`ic mute${muted ? " on" : ""}`} onClick={() => applyMute(!muted)} title="静音 (M)">
                  <IconVolume size={14} />
                </button>
              ) : (
                <span className="ic"><IconSun size={14} /></span>
              )}
              <span
                className="track"
                onMouseDown={(e) => dragVbar(e, vbar.kind === "vol" ? applyVolume : setBrightness)}
              >
                <i style={{ height: `${vbar.kind === "vol" ? (muted ? 0 : volume) : brightness}%` }} />
                <span className="knob" style={{ bottom: `${vbar.kind === "vol" ? (muted ? 0 : volume) : brightness}%` }} />
              </span>
              <span className="v">{vbar.kind === "vol" ? (muted ? "静音" : volume) : brightness}</span>
            </div>
          )}

          {/* 右键画面菜单(草稿 L1152):截图/复制时间/硬解/比例 */}
          {ctx && (
            <>
              <div className="p-ctxmask" onClick={() => setCtx(null)} onContextMenu={(e) => { e.preventDefault(); setCtx(null); }} />
              <div className="ctxmenu" style={{ left: Math.min(ctx.x, window.innerWidth - 190), top: Math.min(ctx.y, window.innerHeight - 160) }}>
                <div className="mi" onClick={() => { setCtx(null); doShot(); }}><span className="i">◱</span>截图<span className="k">S</span></div>
                <div className="mi" onClick={() => { setCtx(null); copyTime(); }}><span className="i">⧉</span>复制当前时间</div>
                {/* 右键菜单是「常用项不翻面板」的快捷入口(草稿 L1152):就地切,不再开「更多」 */}
                <div className="mi" onClick={() => { setCtx(null); applyHwdec(hwdec === "no" ? "auto-safe" : "no"); }}>
                  <span className="i">⚙</span>{hwdec === "no" ? "切回硬解" : "切到软解"}
                </div>
                <div className="mi" onClick={() => { setCtx(null); setPanel("more"); setArOpen(true); }}>
                  <span className="i">▭</span>画面比例<span className="k">{ASPECTS.find(([id]) => id === aspect)?.[1]}</span>
                </div>
              </div>
            </>
          )}

          {/* 滑出面板的暗化背板:点空白 / Esc 收起(草稿 L998) */}
          {panel && <div className="p-scrim" onClick={() => setPanel(null)} />}

          {/* 右侧滑出面板 */}
          {panel && (
            <div className={`p-slide${wide ? " wide" : ""}`}>
              <div className="hd">
                {panelTitle(panel)}
                <button className="x" onClick={() => setPanel(null)}>✕</button>
              </div>
              <div className={`bd${wide ? " two" : ""}`}>
                {/* ---- 选集:item_detail(剧).children 是真数据(含 MediaSources 规格) ---- */}
                {panel === "eps" && (
                  siblings.length > 0 ? siblings.map((ep) => (
                    <button
                      key={ep.id}
                      className={`p-li${ep.id === playing.id ? " on" : ""}`}
                      onClick={() => { if (ep.id !== playing.id) goEpisode(ep, "下"); }}
                    >
                      <span className="thumb">
                        {/* session 可能为空(只连了网盘的用户没有 Emby 会话)——
                            分集缩略图是 Emby 的图,没会话时不取,留占位方块。 */}
                        {ep.has_primary && session && <img src={posterUrl(session, ep.id, 120)} alt="" loading="lazy" />}
                      </span>
                      <span className="col">
                        <span className="t1">{ep.episode_no != null ? `E${ep.episode_no} ` : ""}{ep.name}</span>
                        <span className="t2">{[fmtRes(ep.video_height), fmtBitrate(ep.bitrate), fmtSize(ep.size_bytes)].filter(Boolean).join(" · ")}</span>
                      </span>
                      {ep.id === playing.id && <span className="rt">▶</span>}
                    </button>
                  )) : <div className="p-note">当前条目没有剧集列表(电影 / 网盘文件)。</div>
                )}

                {/* ---- 音轨:set_track + 音画同步(set_audio_delay)全真接 ---- */}
                {panel === "audio" && (
                  <>
                    {audio.map((t) => (
                      <button
                        key={t.id}
                        className={`p-li${t.selected ? " on" : ""}`}
                        onClick={() => { chooseTrack("audio", t.id); persistPrefs({ ...prefs, audio_lang: trackLang(audio, t.id) || prefs.audio_lang }); }}
                      >
                        <span className="rad" /> 音轨 {t.id} {t.lang || t.title}
                      </button>
                    ))}
                    <div className="grp-lab">音画同步</div>
                    {stepper("音频延迟", fmtDelay(aDelay), () => applyADelay(aDelay - 0.1), () => applyADelay(aDelay + 0.1))}
                    {aDelay !== 0 && (
                      <button className="p-li" onClick={() => applyADelay(0)}><span className="i"><IconRefresh size={13} /></span>归零</button>
                    )}
                    <div className="p-note">正值 = 音频延后播放(画面快于声音时用);步进 0.1s。</div>
                  </>
                )}

                {/* ---- 字幕:双栏。主字幕/样式/延迟/次字幕/外挂 全真接 ---- */}
                {panel === "sub" && (
                  <>
                    <div className="col">
                      <div className="grp-lab">主字幕</div>
                      <button className={`p-li${subs.every((t) => !t.selected) ? " on" : ""}`} onClick={() => { chooseTrack("sub", "no"); persistPrefs({ ...prefs, sub_enabled: false }); }}>
                        <span className="rad" /> 关闭
                      </button>
                      {subs.map((t) => (
                        <button
                          key={t.id}
                          className={`p-li${t.selected ? " on" : ""}`}
                          onClick={() => { chooseTrack("sub", t.id); persistPrefs({ ...prefs, sub_enabled: true, sub_lang: trackLang(subs, t.id) || prefs.sub_lang }); }}
                        >
                          <span className="rad" /> 字幕 {t.id} {t.lang || t.title}
                        </button>
                      ))}
                      {/* 没装 @tauri-apps/plugin-dialog,又不为此加依赖 → 退化成路径/URL 输入 */}
                      {subUrl === null ? (
                        <button className="p-li add" onClick={() => setSubUrl("")}>＋ 加载外挂字幕…</button>
                      ) : (
                        <>
                          <input
                            className="dmq" autoFocus placeholder="字幕本地路径 或 http(s):// URL"
                            value={subUrl}
                            onChange={(e) => setSubUrl(e.target.value)}
                            onKeyDown={(e) => { if (e.key === "Enter") doAddSub(); if (e.key === "Escape") setSubUrl(null); }}
                          />
                          <button className="p-li add" onClick={doAddSub}>确认加载</button>
                          <button className="p-li" onClick={() => setSubUrl(null)}>取消</button>
                        </>
                      )}
                      {stepper("位置", `${subPos}`, () => applySubStyle({ position: Math.max(0, subPos - 5) }), () => applySubStyle({ position: Math.min(100, subPos + 5) }))}
                      {stepper("延迟", fmtDelay(sDelay), () => applySDelay(sDelay - 0.1), () => applySDelay(sDelay + 0.1))}

                      {/* 主次共用的样式。★ 不是偷懒放一起 —— mpv 就只有一份:
                          secondary-sub-font-size / -font 这些属性**根本不存在**
                          (2026-07-16 实测 property-list,set 回 -8 property not found)。
                          与其在次字幕栏摆一个假的字号 stepper,不如如实标成「主次共用」。 */}
                      <div className="grp-lab">字幕样式 · 主次共用</div>
                      <div className="p-li static">
                        字体
                        <span className="rt sel" onClick={() => setFontOpen((o) => !o)}>
                          {SUB_FONTS.find(([id]) => id === subFont)?.[1] ?? subFont} ▾
                        </span>
                      </div>
                      {fontOpen && SUB_FONTS.map(([id, label]) => (
                        <button key={id} className={`p-li sub${subFont === id ? " on" : ""}`} onClick={() => applySubStyle({ font: id })}>
                          <span className="rad" /> {label}
                        </button>
                      ))}
                      {/* 大小 = sub-scale 百分比。以前拧的是 sub-font-size,而 ASS 字幕
                          (内封几乎都是)在 mpv 默认 sub-ass-override=scale 下**完全无视它** ——
                          这就是「主字幕大小调不动」的真因。sub-scale 对 ASS 和纯文本都生效。 */}
                      {stepper("大小", `${subScale}%`,
                        () => applySubStyle({ scalePct: Math.max(50, subScale - 10) }),
                        () => applySubStyle({ scalePct: Math.min(300, subScale + 10) }))}
                    </div>
                    <div className="col">
                      <div className="grp-lab">次字幕(双字幕)</div>
                      <button className={`p-li${sec2 === "" ? " on" : ""}`} onClick={() => applySec2("")}>
                        <span className="rad" /> 关闭
                      </button>
                      {subs.map((t) => (
                        <button key={t.id} className={`p-li${sec2 === t.id ? " on" : ""}`} onClick={() => applySec2(t.id)}>
                          <span className="rad" /> 字幕 {t.id} {t.lang || t.title}
                        </button>
                      ))}
                      {/* 与主字幕栏同样的两项(位置/延迟)—— 这两项 mpv 确实给了 secondary 独立属性。 */}
                      {stepper("位置", `${sec2Pos}`, () => applySec2Opts({ position: Math.max(0, sec2Pos - 5) }), () => applySec2Opts({ position: Math.min(100, sec2Pos + 5) }))}
                      {stepper("延迟", fmtDelay(sec2Delay), () => applySec2Opts({ delay: round1(sec2Delay - 0.1) }), () => applySec2Opts({ delay: round1(sec2Delay + 0.1) }))}

                      {/* 用户 2026-07-16:「为什么主字幕渲染样式对了,次字幕却不渲染样式?」
                          答:mpv 的 secondary-sub-ass-override 默认就是 strip —— 把次字幕的 ASS
                          标记整个剥掉当纯文本画。这里把它提成开关,默认已改成「保留原样式」。
                          ⚠️ 保留原样式 = 次字幕按它自己 ASS 里写的位置画,「位置」这项可能就推不动它了
                          (ASS 自带定位优先),而且多半和主字幕挤在底部。真挤了就切回「纯文本」。 */}
                      <div className="grp-lab">次字幕样式</div>
                      <button className={`p-li${sec2Ass === "scale" ? " on" : ""}`} onClick={() => applySec2Opts({ assOverride: "scale" })}>
                        <span className="rad" /> 保留原样式(同主字幕)
                      </button>
                      <button className={`p-li${sec2Ass === "strip" ? " on" : ""}`} onClick={() => applySec2Opts({ assOverride: "strip" })}>
                        <span className="rad" /> 纯文本(可用上面的位置)
                      </button>
                    </div>
                  </>
                )}

                {/* ---- 弹幕:左=源(真接),右=显示设置(不透明度/区域纯 CSS 真生效) ---- */}
                {panel === "danmaku" && (
                  <>
                    <div className="col">
                      <div className="grp-lab">弹幕源 · 先搜索匹配</div>
                      <input className="dmq" placeholder="搜索片名 / 手动匹配…" value={dmKw} onChange={(e) => setDmKw(e.target.value)} onKeyDown={(e) => e.key === "Enter" && doDmSearch()} />
                      <button className="p-li" onClick={doDmSearch}><span className="rad" /> 搜索</button>
                      {/* 三段式:条目 → 集 → 弹幕。一口气把所有集平铺出来(旧版)= 三个源
                          各二十几集,七十多行按钮糊在这一列里,用户根本挑不动。
                          dmPick 非空就整列换成该番的集表(带返回),不再显示条目层。 */}
                      {dmPick ? (
                        <>
                          {/* 不挂 .rad —— 那是单选圆点,返回是个动作不是选项(截图里看着像可选项) */}
                          <button className="p-li" onClick={() => setDmPick(null)}>
                            <span className="rt">←</span> 返回条目列表
                          </button>
                          <div className="grp-lab">
                            {dmPick.anime.anime_title}
                            {dmPick.anime.year ? ` · ${dmPick.anime.year}` : ""} · {dmPick.group.source_name}
                          </div>
                          {dmPick.episodes === null && <div className="p-note">正在取集列表…</div>}
                          {dmPick.episodes?.length === 0 && <div className="p-note">该条目没有可用的集</div>}
                          {dmPick.episodes?.map((ep) => (
                            <button key={ep.episode_id} className="p-li" onClick={() => loadDmEpisode(dmPick.group.source_id, ep)}>
                              <span className="col">
                                <span className="t1">{ep.episode_title || ep.episode_number || "?"}</span>
                              </span>
                            </button>
                          ))}
                        </>
                      ) : (
                        <>
                          {/* g.error 必须露出来 —— 单源挂了和单源没结果长得一样,吞了就没人知道该去修哪个源。 */}
                          {dmResults?.map((g) => (
                            <div key={g.source_id}>
                              <div className="grp-lab">{g.source_name}</div>
                              {g.error && <div className="p-note">该源失败:{g.error}</div>}
                              {!g.error && g.animes.length === 0 && <div className="p-note">该源没有结果</div>}
                              {g.animes.map((a) => (
                                <button key={`${g.source_id}:${a.anime_id}`} className="p-li" onClick={() => openDmAnime(g, a)}>
                                  <span className="thumb sq">
                                    {a.image_url && <img src={a.image_url} alt="" loading="lazy" />}
                                  </span>
                                  <span className="col">
                                    <span className="t1">{a.anime_title}</span>
                                    <span className="t2">
                                      {[a.type_description, a.year, a.episode_count ? `${a.episode_count} 集` : null]
                                        .filter(Boolean).join(" · ")}
                                    </span>
                                  </span>
                                  <span className="rt">›</span>
                                </button>
                              ))}
                            </div>
                          ))}
                          {dmResults && dmResults.length === 0 && <div className="p-note">没有可用的弹幕源(去设置页添加)。</div>}
                        </>
                      )}
                    </div>
                    <div className="col">
                      <div className="grp-lab">显示设置</div>
                      {swRow("弹幕开关", dmOn, () => patchDm({ on: !dmOn }))}
                      {stepper("不透明度", `${dmOpacity}%`,
                        () => patchDm({ opacity: Math.max(10, dmOpacity - 10) }),
                        () => patchDm({ opacity: Math.min(100, dmOpacity + 10) }))}
                      {stepper("显示区域", DM_AREAS[dmArea] === 100 ? "全屏" : `${DM_AREAS[dmArea] / 25}/4 屏`,
                        () => patchDm({ area: Math.max(0, dmArea - 1) }),
                        () => patchDm({ area: Math.min(DM_AREAS.length - 1, dmArea + 1) }))}
                      {stepper("显示速度", DM_SPEEDS[dmSpeed][1],
                        () => patchDm({ speed: Math.max(0, dmSpeed - 1) }),
                        () => patchDm({ speed: Math.min(DM_SPEEDS.length - 1, dmSpeed + 1) }))}
                      {stepper("字体大小", DM_SIZES[dmSize][1],
                        () => patchDm({ size: Math.max(0, dmSize - 1) }),
                        () => patchDm({ size: Math.min(DM_SIZES.length - 1, dmSize + 1) }))}
                    </div>
                  </>
                )}

                {/* ---- 版本:item_media 是真数据 ---- */}
                {panel === "version" && (
                  versions == null ? <div className="p-note">读取中…</div>
                    : versions.length === 0 ? <div className="p-note">没有取到版本信息。</div>
                      : <>
                        {versions.map((v) => {
                          const vid = v.streams.find((s) => s.type_ === "Video");
                          const spec = [fmtRes(vid?.height ?? null), vid?.video_range && vid.video_range !== "SDR" ? vid.video_range : null].filter(Boolean).join(" ");
                          return (
                            <button key={v.id} className={`p-li${v.id === curMsId ? " on" : ""}`} onClick={() => switchVersion(v)}>
                              <span className="rad" />
                              <span className="col">
                                <span className="t1">{spec || v.name}</span>
                                <span className="t2">{[v.container?.toUpperCase(), fmtBitrate(v.bitrate)].filter(Boolean).join(" · ")}</span>
                              </span>
                              <span className="rt">{fmtSize(v.size_bytes)}</span>
                            </button>
                          );
                        })}
                      </>
                )}

                {/* ---- 超分:档位来自核层 shader_levels(),按滤镜家族分三组(用户 2026-07-16)。
                        「需放大才生效」的分组/角标已去掉;某档在当前窗口尺寸下会不会真跑,由 applyShader
                        点击时如实 toast(will_run),不在列表里预标。 ---- */}
                {panel === "super" && (
                  shaderList.length === 0 ? <div className="p-note">读取档位中…</div> : (
                    <>
                      {/* 关闭档 */}
                      {shaderList.filter(([id]) => id === "off").map(([id, name]) => (
                        <button key={id} className={`p-li${shaderLv === id ? " on" : ""}`} onClick={() => applyShader(id)}>
                          <span className="rad" /> {name}
                        </button>
                      ))}
                      {/* 四家族折叠(用户 2026-07-20:「要叠起来 用户点击了某款超分模型再展开」)。
                          家族行本身**不是**按钮:点标题右侧的「当前档 ▾」才展开,和「更多」面板里
                          画面比例/定时播放用的是同一套 .p-li static + .rt.sel + .p-li.sub 惯例。
                          收起状态下右侧照样显示本族已选中的档位,不用逐个展开去找。 */}
                      {SHADER_FAMILIES.flatMap(([fam, label, hint]) => {
                        const items = shaderList.filter(([, , f]) => f === fam);
                        if (items.length === 0) return [];
                        const cur = items.find(([id]) => id === shaderLv);
                        return [
                          <div className={`p-li static${cur ? " on" : ""}`} key={`h-${fam}`}>
                            <span className="col">
                              <span className="t1">{label}</span>
                              <span className="t2">{hint}</span>
                            </span>
                            <span className="rt sel" onClick={() => setShFam((f) => (f === fam ? null : fam))}>
                              {cur?.[1] ?? "未启用"} ▾
                            </span>
                          </div>,
                          ...(shFam === fam
                            ? items.map(([id, name]) => (
                              <button key={id} className={`p-li sub${shaderLv === id ? " on" : ""}`} onClick={() => applyShader(id)}>
                                <span className="rad" /> {name}
                              </button>
                            ))
                            : []),
                        ];
                      })}
                    </>
                  )
                )}

                {/* ---- 线路:probe_line / set_active_line 全真接 ----
                    行来自本地账号配置(立刻出、立刻可点),延迟各行自己填。
                    「探测中…」这个整面板占位没了 —— 它正是「卡在那」的来源。 */}
                {panel === "line" && (
                  lineErr ? <div className="p-note">线路读取失败:{lineErr}</div>
                    : !acct ? <div className="p-note">读取中…</div>
                      : <>
                        {Array.from({ length: acct.lines.length || 1 }, (_, i) => {
                          const ms = lineMs?.[i];
                          return (
                            <button
                              key={i}
                              className={`p-li${acct.active_line === i ? " on" : ""}`}
                              onClick={() => switchLine(i)}
                            >
                              <span className="rad" />
                              {/* 用户 2026-07-16「线路选择不要直接显示地址 显示名称就行」:只留名称,不显 URL。 */}
                              <span className="col">
                                <span className="t1">{lineName(acct, i)}</span>
                              </span>
                              {/* 三态:未回来=转圈 / null=探过确实不通,显示「—」不装成 0ms / 数字=毫秒 */}
                              <span className="rt">
                                {ms === undefined ? <i className="p-dot" /> : ms == null ? "—" : `${ms}ms`}
                              </span>
                            </button>
                          );
                        })}
                      </>
                )}

                {/* ---- 倍速:set_speed 真接 ---- */}
                {panel === "speed" && (
                  <>
                    {/* 长按连调(草稿 L1086):mousedown 起跳并起 interval,松手/移出即停。
                        没有 onClick —— mousedown 已经走了第一步,再加 onClick 会一按走两格。 */}
                    <div className="p-li static center">
                      <span className="p-stepper">
                        <button
                          className="b"
                          onMouseDown={() => holdRepeat(() => bumpSpeed(-0.25))}
                          onMouseUp={stopRepeat} onMouseLeave={stopRepeat}
                        >−</button>
                        <b className="big">{speed.toFixed(2)}×</b>
                        <button
                          className="b"
                          onMouseDown={() => holdRepeat(() => bumpSpeed(0.25))}
                          onMouseUp={stopRepeat} onMouseLeave={stopRepeat}
                        >＋</button>
                      </span>
                    </div>
                    <div className="grp-lab">常用</div>
                    {SPEEDS.map((s) => (
                      <button key={s} className={`p-li${Math.abs(s - speed) < 0.01 ? " on" : ""}`} onClick={() => applySpeed(s)}>
                        <span className="rad" /> {s.toFixed(1)}×
                      </button>
                    ))}
                  </>
                )}

                {/* ---- 更多:草稿十项。仅 跳过片头尾/PiP 尚无核层命令,余下全真接 ---- */}
                {panel === "more" && (
                  <>
                    <div className="p-li static">
                      解码方式
                      <span className="p-seg">
                        {HWDECS.map(([id, label]) => (
                          <button key={id} className={hwdec === id ? "on" : ""} onClick={() => applyHwdec(id)}>{label}</button>
                        ))}
                      </span>
                    </div>
                    <div className="p-li static">
                      画面比例
                      <span className="rt sel" onClick={() => setArOpen((o) => !o)}>
                        {ASPECTS.find(([id]) => id === aspect)?.[1] ?? aspect} ▾
                      </span>
                    </div>
                    {/* 「更多」的 bd 是双列网格,档位行直接铺会被拆到两列;裹一层 span2 才连成一张列表 */}
                    {arOpen && (
                      <div className="span2 col">
                        {ASPECTS.map(([id, label]) => (
                          <button key={id || "src"} className={`p-li sub${aspect === id ? " on" : ""}`} onClick={() => applyAspect(id)}>
                            <span className="rad" /> {label}
                          </button>
                        ))}
                      </div>
                    )}
                    {swRow("自动跳过片头", pbPrefs?.skip_intro ?? false, () =>
                      toggleSkip("skip_intro", !pbPrefs?.skip_intro),
                    )}
                    {swRow("自动跳过片尾", pbPrefs?.skip_outro ?? false, () =>
                      toggleSkip("skip_outro", !pbPrefs?.skip_outro),
                    )}
                    {swRow("画中画 (PiP)", false, () => soon("画中画"))}
                    {/* 定时已开时整行点亮,不翻面板也看得出来 */}
                    <div className={`p-li static${sleepMin != null ? " on" : ""}`}>
                      定时播放
                      <span className="rt sel" onClick={() => setSleepOpen((o) => !o)}>
                        {sleepMin != null ? `${sleepMin} 分钟` : "关闭"} ▾
                      </span>
                    </div>
                    {sleepOpen && (
                      <div className="span2 col">
                        <button className={`p-li sub${sleepMin == null ? " on" : ""}`} onClick={() => applySleep(null)}>
                          <span className="rad" /> 关闭
                        </button>
                        {SLEEP_MINS.map((m) => (
                          <button key={m} className={`p-li sub${sleepMin === m ? " on" : ""}`} onClick={() => applySleep(m)}>
                            <span className="rad" /> {m} 分钟后关闭
                          </button>
                        ))}
                      </div>
                    )}
                    {swRow("杜比视界软解", dolby, () => applyDolby(!dolby))}
                    <button className="p-li" onClick={doShot}><span className="i">◱</span>截图 <span className="rt">S</span></button>
                    <button className="p-li" onClick={copyTime}><span className="i">⧉</span>复制当前时间</button>
                    {/* 播放信息:常见静态规格(用户 2026-07-16:分辨率/码率/大小/编码/音频·字幕格式,
                        不要动态的时长/状态)。取自当前在播版本的流规格(item_media)。 */}
                    <div className="p-note span2">
                      <b className="ttl"><IconInfo size={12} /> 播放信息</b>
                      <span className="kv"><i>标题</i>{playing.name}</span>
                      {playing.series_name && <span className="kv"><i>剧集</i>{playing.series_name}{epTag ? ` · ${epTag}` : ""}</span>}
                      {infoRes && <span className="kv"><i>分辨率</i>{infoRes}</span>}
                      {infoBitrate && <span className="kv"><i>码率</i>{infoBitrate}</span>}
                      {infoSize && <span className="kv"><i>大小</i>{infoSize}</span>}
                      {vStream?.codec && <span className="kv"><i>视频编码</i>{vStream.codec.toUpperCase()}{vStream.video_range && vStream.video_range !== "SDR" ? ` · ${vStream.video_range}` : ""}</span>}
                      {aCodecs && <span className="kv"><i>音频格式</i>{aCodecs}</span>}
                      {sCodecs && <span className="kv"><i>字幕格式</i>{sCodecs}</span>}
                      {curVer?.container && <span className="kv"><i>容器</i>{curVer.container.toUpperCase()}</span>}
                      {versions == null && <span className="kv note">读取媒体规格中…</span>}
                    </div>
                  </>
                )}
              </div>
            </div>
          )}
        </div>
      )}

      {/* 插件的播放器叠加层(slot: player.overlay)。只在播放时挂,没插件贡献就整块不出。
          放 player-layer 外面:OSD 淡出时插件的叠加内容不该跟着消失。 */}
      {playing && <PluginSlot slot="player.overlay" className="pl-plugins" />}

      {/* toast 放 player-layer 外:OSD 淡出时提示还得看得见 */}
      {toast && <div className="toast">{toast}</div>}
    </>
  );
}

/** 线路显示名:用户起的名优先,没起名(或压根没配 lines,probe_lines 会回落单条)按草稿叫「主线 / 备线 N」。 */
function lineName(a: AccountInfo, i: number): string {
  return a.lines[i]?.name || (i === 0 ? "主线" : `备线 ${i}`);
}

function panelTitle(p: Panel): string {
  switch (p) {
    case "eps": return "选集";
    case "audio": return "音轨";
    case "sub": return "字幕";
    case "danmaku": return "弹幕";
    case "super": return "超分";
    case "line": return "线路";
    case "version": return "版本";
    case "speed": return "倍速";
    case "more": return "更多";
    default: return "";
  }
}
