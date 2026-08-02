import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import {
  type DanmakuComment,
  type DanmakuMatchInput,
  type Item,
  type LineProbe,
  type MediaVersion,
  type ShaderLevel,
  type Status,
  type Track,
  danmakuAutoLoad,
  defaultDanmakuFilter,
  fmtBitrate,
  fmtRes,
  fmtSize,
  fmtNetSpeed,
  fmtTime,
  itemMedia,
  listAccounts,
  playerOpts,
  probeLines,
  reportProgress,
  screenshot,
  seasonEpisodes,
  seek,
  setActiveLine,
  setAspectRatio,
  setAudioDelay,
  setNowPlaying,
  setPause,
  setShaderLevel,
  setSpeed,
  setSubDelay,
  setTrack,
  setVolume,
  shaderLevels,
  status as getStatus,
  stopPlayback,
  thumbUrl,
  defaultVersion,
} from "@shared/api";
import { pollTracks } from "@shared/track-poll";
import { DanmakuLayer, type TimeSync } from "@shared/Danmaku";
import { useCtx } from "../app/ctx";
import { onShellKey, pushBackHandler } from "../app/backkey";
import { setOrientation } from "../app/host";
import { takePrePick } from "../app/prepick";
import { Icon } from "../app/icons";
import { haptic, longPress, playerGestures, toast } from "../app/motion";
import { Opt, OptGroup } from "../components/ui";

/* 播放页 —— 第三版 OSD。**版式是用户给的规格**,不是我的发挥。

   ## 视频不在这个组件里
   画面是垫在透明 WebView **底下**的原生 mpv SurfaceView。这一页只是叠在上面的
   一层 UI —— 所以进页要给 <html> 挂 `.playing` 把背景整个撤掉,否则视频被盖死,
   表现是「有声音没画面」。离页必须摘掉,不然回到列表页是一片透明(=黑)。

   ## 用户定的九宫格(2026-07-28)
     左上   返回 + 标题(**过长要滚动**,慢一点,快了就是一闪而过)
     右上   版本 / 线路 / 超分 / 更多
     左中   截图 / 锁屏          ← 爱奇艺、优酷都放这
     右中   倍速条(上加 中显示 下减,**长按线性加减速**)
     左下   上一集 / 下一集
     中下   快退 / 播放暂停 / 快进
     右下   音频 / 弹幕 / 选集
   上一版把东西全堆在上下两条栏里,**屏幕两侧和中间全空着** —— 遮挡 83.6%,那是没把屏幕用完。

   ## 那个"闪一下"的根因
   「点选项弹出列表之后上下栏渐隐了,点出去的时候又快速显隐了一下」——
   不在 OSD 的显隐逻辑里,**是 scrim 盖在了它上面**(scrim z-index > OSD)。
   修法是把 OSD 抬到 scrim 之上;面板开关期间上下栏**一动不动**。

   ## 返回键四级
   小浮层 → 面板 → OSD → 才退出播放。 */

/** 倍速。**连续**不是档位 —— 用户要的是"长按线性加减速"。
 *  点一下走 0.25(一档),长按每 70ms 走 0.05(≈0.7×/秒:从 1 拉到 3 要 3 秒,
 *  既不会手一抖就飞过去,也不会按到手酸)。 */
const SP_MIN = 0.25;
const SP_MAX = 4;
const SP_TAP = 0.25;
const SP_HOLD = 0.05;
const SP_TICK = 70;
const fmtSpeed = (v: number) => `${parseFloat(v.toFixed(2))}×`;

/** 5000ms = Media3 PlayerControlView 的 DEFAULT_SHOW_TIMEOUT_MS。
 *  安卓上别的播放器都是这个数,没理由自己发明一个。 */
const OSD_MS = 5000;

const RATIOS = ["自动", "铺满", "16:9", "4:3", "原始"] as const;
/** 这三项是**贴着按钮弹的小浮层**,不是抽屉 —— 选项少,开个半屏抽屉是杀鸡用牛刀。 */
const POP = new Set(["ratio"]);

type PanelId = "source" | "sr" | "more" | "audio" | "danmaku" | "ep" | "ratio";

export default function PlayerPage({
  title,
  item,
  onStopped,
}: {
  title?: string;
  /** 正在播的条目。给弹幕自动匹配喂剧名/集号/时长(route.title 是拼好的串,搜不到)。 */
  item?: Item | null;
  onStopped: () => void;
}) {
  const { session, back } = useCtx();
  const [st, setSt] = useState<Status | null>(null);
  const [trk, setTrk] = useState<Track[]>([]);
  const [osd, setOsd] = useState(true);
  const [locked, setLocked] = useState(false);
  const [panel, setPanel] = useState<PanelId | null>(null);
  const [speed, setSpeedState] = useState(1);
  const [dm, setDm] = useState(true);
  const [dmComments, setDmComments] = useState<DanmakuComment[]>([]);
  const [hud, setHud] = useState<null | { kind: string; text: string; pct?: number }>(null);
  const [vbar, setVbar] = useState<null | { side: "l" | "r"; pct: number }>(null);
  const [boost, setBoost] = useState(false);
  const [dim, setDim] = useState(0);
  const [flash, setFlash] = useState(false);
  const [dragging, setDragging] = useState(false);
  const [seekPos, setSeekPos] = useState<number | null>(null);
  const [showRemain, setShowRemain] = useState(false);
  /* 「已经在放了吗」。缓冲速度按用户 2026-08-02 的口径分两处显示:
     没出画之前在**画面正中**,出画之后挪到**集标题右侧**。
     ★ 判据是「时间真的往前走了」,不是 `st.time > 0` —— 续播时核层一 loadfile
       就把位置记账成续播点(见 crates/mpv load_inner),第一拍读到的就已经 >0,
       用 >0 判等于"起播即算已播",中间那段缓冲一秒都显示不到。 */
  const [started, setStarted] = useState(false);
  const startPos = useRef<number | null>(null);

  /* 面板数据。各自到、各自渲染,不绑成一个屏障。 */
  const [versions, setVersions] = useState<MediaVersion[]>([]);
  const [curVer, setCurVer] = useState<string | null>(null);
  const [lines, setLines] = useState<{ name: string; url: string }[]>([]);
  const [pings, setPings] = useState<Record<number, number | null>>({});
  const [activeLine, setActiveLineIdx] = useState(0);
  const [srcTab, setSrcTab] = useState<"ver" | "line">("ver");
  const [shaders, setShaders] = useState<ShaderLevel[]>([]);
  const [curShader, setCurShader] = useState("off");
  const [eps, setEps] = useState<Item[]>([]);
  const [ratio, setRatio] = useState<string>("自动");
  const [audioDelay, setAudioDelayState] = useState(0);
  const [subDelay, setSubDelayState] = useState(0);

  /* 播放时钟快照。轮询是 1s 一拍,弹幕要 60fps —— 两拍之间靠墙钟外推。
     `speed` 必须带上,不然倍速下弹幕按 1x 爬,每秒被真值硬拽回去一次。 */
  const timeSync = useRef<TimeSync>({ base: 0, stamp: performance.now(), paused: false, speed: 1 });
  const speedRef = useRef(1);
  const hideAt = useRef(0);
  const ended = useRef(false);
  const stallSaid = useRef(false);
  const stRef = useRef<Status | null>(null);
  stRef.current = st;
  const lockedRef = useRef(false);
  lockedRef.current = locked;
  const surface = useRef<HTMLDivElement>(null);
  const trackRef = useRef<HTMLDivElement>(null);
  const titleRef = useRef<HTMLDivElement>(null);
  const titleInner = useRef<HTMLSpanElement>(null);
  const panelBody = useRef<HTMLDivElement>(null);
  const popRef = useRef<HTMLDivElement>(null);
  const popAnchor = useRef<HTMLElement | null>(null);
  /* 音量放 ref 不放 state:`Status` 里没有 volume(真值在 playerOpts),
     而且它**从不参与渲染** —— 放 state 的话竖滑一次会触发几十次整页重渲染。 */
  const volRef = useRef(100);

  useEffect(() => {
    document.documentElement.classList.add("playing");
    return () => document.documentElement.classList.remove("playing");
  }, []);

  /* ── 按画面比例自动横竖屏(用户 2026-08-02:「播放页没有根据视频的比例自动切换」)──
     ★ 判据用 mpv 报上来的**真实解码尺寸**(Status.video),不是条目元数据 ——
       元数据上的分辨率经常是错的(转码版本、竖屏短剧被标成 16:9),
       而 VideoDiag 里的 width/height 是这一帧实际画出来多大。
     ★ 只在拿到尺寸之后才下达:起播前就锁横屏的话,竖屏短片会先被硬掰过去再掰回来。
     ★ 离开播放页必须交回系统(auto)。不交的表现是列表页也被钉死在横屏,
       而用户完全不知道该去哪儿解开。
     ★ 纯音频(has_video_track=false)不动方向 —— 那是听歌,横过来毫无意义。 */
  const wantLandscape =
    st?.video && st.video.has_video_track && st.video.width > 0 && st.video.height > 0
      ? st.video.width >= st.video.height
      : null;
  useEffect(() => {
    if (wantLandscape == null) return;
    setOrientation(wantLandscape ? "landscape" : "portrait");
  }, [wantLandscape]);
  useEffect(() => () => void setOrientation("auto"), []);

  useEffect(() => {
    void setNowPlaying(title ?? null);
    return () => {
      void setNowPlaying(null);
    };
  }, [title]);

  useEffect(() => {
    playerOpts()
      .then((o) => {
        setSpeedState(o.speed);
        speedRef.current = o.speed;
        volRef.current = o.volume;
        setAudioDelayState(o.audio_delay);
        setSubDelayState(o.sub_delay);
      })
      .catch(() => {});
    shaderLevels().then(setShaders).catch(() => {});
  }, []);

  /* 版本 / 线路 / 选集 —— 只在面板真正被打开过一次之后才拉。
     进播放页就拉三份数据是给起播抢带宽,而这三个面板大多数人一次都不开。 */
  const loadedRef = useRef<Record<string, boolean>>({});
  const ensure = (id: PanelId) => {
    if (loadedRef.current[id]) return;
    loadedRef.current[id] = true;
    if (id === "source") {
      if (item) {
        itemMedia(item.id)
          .then((v) => {
            setVersions(v);
            // 没手动切过 = 在播正则挑中的那条,不是列表第一条(高亮错了就等于告诉用户「没生效」)。
            setCurVer(defaultVersion(v)?.id ?? null);
          })
          .catch(() => {});
      }
      listAccounts()
        .then((as) => {
          const me = as.find((a) => a.active) ?? as[0];
          if (!me) return;
          setLines(me.lines.map((l) => ({ name: l.name, url: l.url })));
          setActiveLineIdx(me.active_line);
          probeLines(me.server)
            .then((r: LineProbe[]) => {
              const m: Record<number, number | null> = {};
              for (const p of r) m[p.index] = p.ms;
              setPings(m);
            })
            .catch(() => {});
        })
        .catch(() => {});
    }
    if (id === "ep" && item?.series_id) {
      /* 选集只拉一屏 40 条。★ 播放中换集是"翻翻附近几集",不是通读全季 ——
         真要通读该回详情页,那边有分页。 */
      seasonEpisodes(item.series_id, 0, 40).then((p) => setEps(p.items)).catch(() => {});
    }
  };

  /* 弹幕自动匹配。全程 catch:弹幕挂不上绝不能影响播放。
     口径与桌面端 autoDanmaku 一字不差 —— 两端匹配结果不一致比匹配不上更难查。 */
  useEffect(() => {
    if (!item) return;
    let alive = true;
    (async () => {
      const title = item.series_name ?? item.name; // 剧集要用剧名,Episode.name 是「第 N 集」搜不到
      /* ★ 真实发布文件名,不是条目名。`/match` 是按文件名做跨语种解析的那条路,
         喂它「第 35 集」整条路白跑(实测返回的第一名是完全无关的片)。
         MediaSource.Name 就是不含扩展名的真文件名;网盘/下载有 path 直接取 basename。 */
      const base = item.path?.replace(/\\/g, "/").split("/").pop() || "";
      const vs = base ? [] : await itemMedia(item.id).catch(() => [] as MediaVersion[]);
      const v = vs.find((x) => x.preferred) ?? vs[0];
      const fileName = base || (v?.name ? `${v.name}.${v.container ?? "mkv"}` : item.name);
      const input: DanmakuMatchInput = {
        title,
        alt_titles: [fileName, item.name].filter((s) => s && s !== title),
        episode_no: item.episode_no,
        season_no: item.season_no,
        file_name: fileName,
        file_size: item.size_bytes,
        duration_secs: item.runtime_secs > 0 ? item.runtime_secs : null,
        /* 只用来判「官方弹弹Play 源要不要参与」。非动漫内容它一条都不收录,
           打过去纯烧配额。空数组=没刮到元数据,核层按「允许」处理。 */
        genres: item.genres ?? [],
      };
      const c = await danmakuAutoLoad(input, defaultDanmakuFilter(), null, item.series_id ?? null);
      if (alive && c) setDmComments(c);
    })().catch(() => {});
    return () => {
      alive = false;
    };
  }, [item?.id]);

  /* 状态轮询 1s。 */
  useEffect(() => {
    let alive = true;
    const t = setInterval(async () => {
      try {
        const s = await getStatus();
        if (!alive) return;
        setSt(s);
        // 首帧判定:第一拍的位置当基准,越过它就是真出画了(理由见 started 的声明处)。
        if (startPos.current == null) startPos.current = s.time;
        if (s.time > startPos.current + 0.05) setStarted(true);
        /* 跳转卡死。播放器**修不了**(根因是服务器不认 HTTP Range,ffmpeg 只能从当前
           位置顺读丢弃到目标字节),但不能让用户对着不动的进度条干等。一次 seek 只说一次。 */
        if (s.seek_stalled) {
          if (!stallSaid.current) {
            stallSaid.current = true;
            setHud({ kind: "跳转很慢", text: "服务器不接受 Range 请求,要等中间的数据下完" });
            window.setTimeout(() => setHud(null), 5000);
          }
        } else stallSaid.current = false;
        timeSync.current = { base: s.time, stamp: performance.now(), paused: s.paused, speed: speedRef.current };
        /* ★ 播完收尾传 duration 而不是 time:mpv 停在最后一帧时 time 通常差最后
           零点几秒,传 time 算出来是 99%,服务端不算「看完」,Trakt/Bangumi 一次都不触发。
           另外 keep-open 下 END_FILE 永远不发,判播完只能读 eof。 */
        if (s.eof && !ended.current) {
          ended.current = true;
          clearInterval(t);
          void stopPlayback(s.duration).finally(() => {
            onStopped();
            back();
          });
          return;
        }
        void reportProgress(s.time, s.paused).catch(() => {});
      } catch {
        /* 播放器还没起来时 status 会报错 —— 不刷屏也不弹错。 */
      }
    }, 1000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [onStopped, back]);

  /* 轨道要**探到稳定**:外挂字幕要等核层收到 mpv 的 FILE_LOADED 才挂得上,
     慢服务器上是起播后好几秒的事。三端共用一份逻辑。 */
  /* 轨表轮询。★ 顺手把**详情页起播前挑好的音轨/字幕**落实到 mpv 上。
     为什么必须在这里做:详情页看到的是 Emby 的 MediaStreams,而能操作的是
     mpv 的 track-list —— 后者要等 demux 完才有(网络流上是起播后几百毫秒到几秒,
     外挂字幕更晚)。所以"选"和"生效"天然分处两个时刻,中间靠 app/prepick.ts 交接。
     ★ 只在**第一次拿到非空轨表**时执行一次(`applied`),之后用户在 OSD 里手动切的
       优先级更高,不能被这条反复顶掉。
     ★ take 之后就清空:它描述的是"这一次起播",不是持久偏好。 */
  const prePick = useRef(takePrePick());
  const preApplied = useRef(false);
  useEffect(
    () =>
      pollTracks((t) => {
        setTrk(t);
        const p = prePick.current;
        if (!p || preApplied.current || !t.length) return;
        const auds = t.filter((x) => x.kind === "audio");
        const subs = t.filter((x) => x.kind === "sub");
        /* 字幕的两种"选过了"要分开:-1 是**明确关闭**,>=0 是挑了第几条。
           合成一个值的表现是用户关了字幕、起播后又被 apply_prefs 打开。 */
        if (p.sub === -1) {
          preApplied.current = true;
          void setTrack("sub", "no");
        } else if (p.sub != null && subs[p.sub]) {
          preApplied.current = true;
          void setTrack("sub", subs[p.sub].id);
        }
        if (p.audio != null && auds[p.audio]) {
          preApplied.current = true;
          void setTrack("audio", auds[p.audio].id);
        }
      }),
    [],
  );

  const bump = useCallback(() => {
    setOsd(true);
    hideAt.current = Date.now() + OSD_MS;
  }, []);

  /* OSD 自动收起。★ 面板开着**不收** —— 用户正在里面挑东西;
     暂停时也不收 —— 暂停就是"我要停下来看看界面"。 */
  useEffect(() => {
    if (!osd || panel || locked || st?.paused || dragging) return;
    hideAt.current = Date.now() + OSD_MS;
    const t = setInterval(() => {
      if (Date.now() >= hideAt.current) setOsd(false);
    }, 400);
    return () => clearInterval(t);
  }, [osd, panel, locked, st?.paused, dragging]);

  const togglePause = useCallback(async () => {
    const s = stRef.current;
    if (!s) return;
    await setPause(!s.paused);
    setSt({ ...s, paused: !s.paused });
    bump();
  }, [bump]);

  const jump = useCallback(
    async (d: number) => {
      const s = stRef.current;
      if (!s) return;
      /* ★ 上界写 `duration || Infinity`,**不能**是 `|| 0`。起播/换片时核层的 duration
         记账还是 0,`Math.min(0, ...)` 会把目标一律夹成 0 —— 用户在加载期双击快进,
         结果是跳回片头。时长未知时不封顶就好:mpv 自己会把 seek 夹在文件范围内。 */
      const p = Math.max(0, Math.min(s.duration || Infinity, s.time + d));
      await seek(p).catch(() => {});
      setSt({ ...s, time: p });
      bump();
    },
    [bump],
  );

  /* 返回键四级:小浮层 → 面板 → OSD → 退出播放。 */
  useEffect(
    () =>
      pushBackHandler(() => {
        if (panel) {
          setPanel(null);
          return true;
        }
        if (locked) {
          setLocked(false);
          return true;
        }
        if (osd) {
          setOsd(false);
          return true;
        }
        return false;
      }),
    [panel, osd, locked],
  );

  useEffect(
    () =>
      onShellKey((k) => {
        if (k === "playpause" || k === "play" || k === "pause") return void togglePause();
        if (k === "ff") return void jump(30);
        if (k === "rew") return void jump(-10);
      }),
    [togglePause, jump],
  );

  /* ── 六个手势 ── 挂在整个播放层上(挂 OSD 上的话 OSD 一收就没手势了)。 */
  useEffect(() => {
    const el = surface.current;
    if (!el) return;
    return playerGestures(el, {
      getTime: () => stRef.current?.time ?? 0,
      getDuration: () => stRef.current?.duration ?? 0,
      onAdjust: (kind, ratioDelta) => {
        if (lockedRef.current) return;
        if (kind === "brightness") {
          setDim((v) => {
            const next = Math.max(0, Math.min(0.85, v - ratioDelta));
            const b = 1 - next;
            setHud({ kind: "亮度", text: `${Math.round(b * 100)}%`, pct: b });
            setVbar({ side: "l", pct: b });
            return next;
          });
        } else {
          const next = Math.max(0, Math.min(100, volRef.current + ratioDelta * 100));
          volRef.current = next;
          void setVolume(next);
          setHud({ kind: "音量", text: `${Math.round(next)}%`, pct: next / 100 });
          setVbar({ side: "r", pct: next / 100 });
        }
      },
      onSeekPreview: (target, d) => {
        if (lockedRef.current) return;
        const s = stRef.current;
        setHud({
          kind: "进度",
          text: `${fmtTime(target)}  ${d >= 0 ? "+" : "−"}${fmtTime(Math.abs(d))}`,
          pct: s?.duration ? target / s.duration : 0,
        });
      },
      /* ★ 抬手才 seek 一次。拖动期间每帧发 seek 会把 mpv 的命令队列灌满 ——
         「拖动松手弹回」的根因就是 seek 排队。 */
      onSeekCommit: (target) => {
        if (lockedRef.current) return;
        void seek(target).catch(() => {});
        const s = stRef.current;
        if (s) setSt({ ...s, time: target });
        haptic("tap");
      },
      onEnd: () => {
        setVbar(null);
        setHud((h) => (h?.kind === "进度" ? null : h));
      },
      onSingleTap: () => {
        if (lockedRef.current) return;
        setOsd((v) => {
          if (!v) hideAt.current = Date.now() + OSD_MS;
          return !v;
        });
      },
      onDoubleTap: (side) => {
        if (lockedRef.current) return;
        void jump(side === "l" ? -10 : 10);
        setHud({ kind: side === "l" ? "快退" : "快进", text: "10 秒" });
        window.setTimeout(() => setHud(null), 600);
      },
      onBoost: (on) => {
        if (lockedRef.current) return;
        setBoost(on);
        const v = on ? 2 : speedRef.current;
        void setSpeed(v);
      },
    });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [jump]);

  /* HUD 自动消失(手势之外的那些) */
  useEffect(() => {
    if (!hud || hud.kind === "进度") return;
    const t = window.setTimeout(() => setHud(null), 900);
    return () => window.clearTimeout(t);
  }, [hud]);
  useEffect(() => {
    if (!vbar) return;
    const t = window.setTimeout(() => setVbar(null), 900);
    return () => window.clearTimeout(t);
  }, [vbar]);

  /* ── 会滚动的标题 ──
     ★ 只有**放不下**才滚。放得下还滚是纯噪音。
     ★ 完整滚一圈,不来回弹:复制一份跟在后面,整体左移 一份宽 + 空档,
       第二份正好落到第一份原来的位置,循环无缝。
       上一版是"滚到末尾再倒回来"—— 用户原话:「很丑」。 */
  const MARQ_GAP = 56;
  const [marquee, setMarquee] = useState(false);
  useLayoutEffect(() => {
    const box = titleRef.current;
    const inner = titleInner.current;
    if (!box || !inner) return;
    /* ★ 先复位成**单份**再量。不复位的话第二次量到的是"两份"的宽度,
       越量越宽,滚动距离每次翻倍。 */
    setMarquee(false);
    const first = inner.firstElementChild as HTMLElement | null;
    const w = first?.scrollWidth ?? 0;
    if (w - box.clientWidth <= 12) return; // 12px 以内当放得下,别为一两个字滚
    const dist = w + MARQ_GAP;
    inner.style.setProperty("--w", `${dist}px`);
    /* 开头停 12%(让人先读到片名),剩下 88% 在滚,速度 40px/s ≈ 每秒 2.7 个汉字。
       再兜一个 6 秒下限:短溢出算出来不到 2 秒,那还是"一闪而过"。 */
    inner.style.animationDuration = `${Math.max(6, dist / 40 / 0.88).toFixed(1)}s`;
    setMarquee(true);
  }, [title]);

  /* ── 倍速:点 = 一档,长按 = 线性连续 ── */
  const applySpeed = (v: number) => {
    const next = Math.max(SP_MIN, Math.min(SP_MAX, Math.round(v * 100) / 100));
    setSpeedState(next);
    speedRef.current = next;
    void setSpeed(next);
    bump();
    return next;
  };
  const spUp = useRef<HTMLButtonElement>(null);
  const spDn = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    const mk = (btn: HTMLButtonElement | null, dir: 1 | -1) => {
      if (!btn) return () => {};
      let t: ReturnType<typeof setInterval> | null = null;
      let moved = false;
      const stop = () => {
        if (t) clearInterval(t);
        t = null;
      };
      const down = () => {
        if (lockedRef.current || btn.disabled) return;
        moved = false;
        /* ★ 这里**不要** setPointerCapture。两个原因:
           1. 捕获之后 pointerleave 就不再触发 —— 而"手指滑出按钮就停"正是要的行为;
           2. pointerId 对不上时它会 throw,**直接把整个 pointerdown 处理函数打断**,
              后面的 setInterval 根本没机会跑 —— 长按静默失效。 */
        t = setInterval(() => {
          moved = true;
          const v = applySpeed(speedRef.current + dir * SP_HOLD);
          if (v <= SP_MIN || v >= SP_MAX) stop();
        }, SP_TICK);
      };
      const click = () => {
        if (lockedRef.current) return;
        if (moved) {
          moved = false;
          return; // 刚才是长按,别再多跳一档
        }
        haptic("sel");
        applySpeed(speedRef.current + dir * SP_TAP);
      };
      btn.addEventListener("pointerdown", down);
      /* ★ 长按结束必须**同时**挂 pointerup / pointercancel / pointerleave ——
         只挂 pointerup 的话,手指按着滑出按钮再抬起,倍速会一路涨到 4×。 */
      ["pointerup", "pointercancel", "pointerleave"].forEach((e) => btn.addEventListener(e, stop));
      btn.addEventListener("click", click);
      return () => {
        stop();
        btn.removeEventListener("pointerdown", down);
        ["pointerup", "pointercancel", "pointerleave"].forEach((e) => btn.removeEventListener(e, stop));
        btn.removeEventListener("click", click);
      };
    };
    const a = mk(spUp.current, 1);
    const b = mk(spDn.current, -1);
    return () => {
      a();
      b();
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  /* ── 进度条 ──
     ★ 提交挂在 **window** 上,不能挂条自己身上 —— 手指划出条外再抬起,
       元素收不到事件,进度条会从此钉死。 */
  useEffect(() => {
    if (!dragging) return;
    const end = () => {
      setDragging(false);
      setSeekPos((v) => {
        if (v != null) {
          void seek(v).catch(() => {});
          haptic("tap");
        }
        return null;
      });
      bump();
    };
    window.addEventListener("pointerup", end);
    window.addEventListener("pointercancel", end);
    window.addEventListener("blur", end);
    return () => {
      window.removeEventListener("pointerup", end);
      window.removeEventListener("pointercancel", end);
      window.removeEventListener("blur", end);
    };
  }, [dragging, bump]);

  /* ★ 核层每次 loadfile 都把 duration 记账清回 0,mpv 要到 FILE_LOADED 才报得出来。
     这几拍(服务器上能有好几秒)里拿 Emby 的 runtime 顶上,否则进度条量程塌成 1 秒:
     用户点在条中间,目标是 0.5 秒而不是片长的一半 —— 看着就是「点了跳转画面没动」。 */
  const dur = st?.duration || item?.runtime_secs || 0;
  const pos = seekPos ?? st?.time ?? 0;
  const p = dur ? Math.max(0, Math.min(1, pos / dur)) : 0;
  const bufP = dur ? Math.max(0, Math.min(1, (st?.buffered ?? 0) / dur)) : 0;

  const seekAt = (clientX: number) => {
    const el = trackRef.current;
    if (!el || !dur) return;
    const r = el.getBoundingClientRect();
    setSeekPos(Math.max(0, Math.min(dur, ((clientX - r.left) / r.width) * dur)));
  };

  const subs = trk.filter((t) => t.kind === "sub");
  const auds = trk.filter((t) => t.kind === "audio");
  const isSeries = !!item?.series_id;

  const open = (id: PanelId, anchor?: HTMLElement | null) => {
    haptic("tap");
    ensure(id);
    popAnchor.current = anchor ?? null;
    setPanel((cur) => (cur === id ? null : id));
  };

  /* ★ 34 条线路里当前那条可能排在第 27 位。不滚过去的话,用户每次开面板
     都得自己翻到底 —— 长列表最容易漏做的就是这一步。
     同步做,不进 rAF:rAF 在没有渲染帧时可能根本不跑(面板"点了没反应"的老坑)。 */
  useLayoutEffect(() => {
    const body = panelBody.current;
    if (!body) return;
    const on = body.querySelector<HTMLElement>(".opt.on, .pl-eprow.on");
    if (!on) return;
    body.scrollTop = Math.max(0, on.offsetTop - body.clientHeight / 2 + on.offsetHeight / 2);
  }, [panel, srcTab, versions.length, lines.length, eps.length]);

  /* 小浮层贴着锚点放。★ 竖向**不量高度**,直接钉边 ——
     量出来的高度和渲染出来的不一致(入场态带 scale、内容还没排完)。 */
  useLayoutEffect(() => {
    const el = popRef.current;
    const anchor = popAnchor.current;
    const host = surface.current;
    if (!el || !anchor || !host) return;
    const sr = host.getBoundingClientRect();
    const ar = anchor.getBoundingClientRect();
    const M = 8;
    const GAP = 10;
    const above = ar.top - sr.top - GAP - M;
    const below = sr.height - (ar.bottom - sr.top) - GAP - M;
    const up = above >= below;
    el.style.maxHeight = `${Math.max(96, Math.floor(up ? above : below))}px`;
    if (up) {
      el.style.bottom = `${Math.round(sr.height - (ar.top - sr.top) + GAP)}px`;
      el.style.top = "auto";
    } else {
      el.style.top = `${Math.round(ar.bottom - sr.top + GAP)}px`;
      el.style.bottom = "auto";
    }
    const w = el.getBoundingClientRect().width;
    let x = ar.left - sr.left + ar.width / 2 - w / 2;
    x = Math.max(M, Math.min(sr.width - w - M, x));
    el.style.left = `${Math.round(x)}px`;
  }, [panel]);

  const isPop = panel != null && POP.has(panel);

  return (
    <div className={`player${locked ? " locked" : ""}`} ref={surface}>
      {/* 弹幕层。垫在 OSD 之下、亮度蒙版之上;pointer-events:none,不能吃掉手势。 */}
      <div className="pl-dmwrap">
        <DanmakuLayer comments={dmComments} timeSync={timeSync} enabled={dm} />
      </div>

      {dim > 0 && <div className="pl-dim" style={{ opacity: dim }} />}
      {flash && <div className="pl-flash" onAnimationEnd={() => setFlash(false)} />}

      {/* 起播前:转圈 + 缓冲速度,居中(用户 2026-08-02)。
          出画就整块撤掉,速度改到标题右边那个 .pl-speed 上。
          ★ 不画黑底 —— 手机端 mpv 起播前本来就是黑的,再盖一层只是多一层合成。 */}
      {!started && (
        <div className="pl-buffering">
          <div className="pl-spin" />
          {st?.cache_speed ? <div className="pl-speed-big">{fmtNetSpeed(st.cache_speed)}</div> : null}
        </div>
      )}

      {hud && (
        <div className="pl-hud">
          <div className="pl-hud-k">{hud.kind}</div>
          <div className="pl-hud-v">{hud.text}</div>
          {hud.pct != null && (
            <div className="pl-hud-bar">
              <i style={{ transform: `scaleX(${Math.max(0, Math.min(1, hud.pct))})` }} />
            </div>
          )}
        </div>
      )}
      {vbar && (
        <div className={`pl-vbar ${vbar.side}`}>
          <i style={{ transform: `scaleY(${Math.max(0, Math.min(1, vbar.pct))})` }} />
        </div>
      )}
      {boost && (
        <div className="pl-boost">
          <Icon n="forward" size={15} />
          2× 快进中 · 松手恢复
        </div>
      )}

      {/* 锁屏。解锁按钮就长在**截图/锁屏原来的位置**(左中),位置连续,不用满屏找。 */}
      {locked && (
        <button
          type="button"
          className="pl-lock"
          aria-label="解锁"
          onClick={() => {
            haptic("tap");
            setLocked(false);
            bump();
          }}
        >
          <Icon n="lock" size={19} />
        </button>
      )}

      <div className={`pl-osd${osd && !locked ? " on" : ""}`}>
        {/* ══ 左上:返回 + 会滚动的标题 / 右上:四个入口 ══ */}
        <div className="pl-top">
          <button type="button" className="pl-ico" aria-label="返回" onClick={back}>
            <Icon n="back" size={22} />
          </button>
          <div className={`pl-title${marquee ? " run" : ""}`} ref={titleRef}>
            <span className="pl-title-i" ref={titleInner}>
              <span className="pl-title-t">{title ?? ""}</span>
              {marquee && (
                <span className="pl-title-t" style={{ marginLeft: MARQ_GAP }}>
                  {title ?? ""}
                </span>
              )}
            </span>
          </div>
          {/* 出画后的缓冲速度:集标题右侧(用户 2026-08-02)。放在 .pl-title **外面** ——
              它内部有跑马灯动画,塞进去会跟着一起划走。 */}
          {started && st?.cache_speed ? (
            <span className={`pl-speed${st.buffering ? " wait" : ""}`}>{fmtNetSpeed(st.cache_speed)}</span>
          ) : null}
          <div className="pl-acts">
            <TopAct id="ver" icon="version" label="版本" on={panel === "source" && srcTab === "ver"} onClick={(e) => { setSrcTab("ver"); open("source", e); }} />
            <TopAct id="line" icon="line" label="线路" on={panel === "source" && srcTab === "line"} onClick={(e) => { setSrcTab("line"); open("source", e); }} />
            <TopAct id="sr" icon="sparkle" label="超分" on={panel === "sr"} onClick={(e) => open("sr", e)} />
            <TopAct id="more" icon="more" label="更多" on={panel === "more"} onClick={(e) => open("more", e)} />
          </div>
        </div>

        {/* ══ 左中:截图 / 锁屏 ══ */}
        <div className="pl-side l">
          <button
            type="button"
            className="pl-round"
            aria-label="截图"
            onClick={() => {
              haptic("ok");
              setFlash(true); // 没有反馈的话用户会怀疑到底截没截到
              screenshot()
                /* ★ 安卓上落在**应用外部专属目录**,不是系统相册 —— 往相册写要过 MediaStore,
                   那是宿主的活。文案必须跟实话说。 */
                .then((p) => toast(`已保存 ${p.split(/[\\/]/).pop()}`, "ok"))
                .catch((e) => toast(`截图失败:${e}`, "bad"));
            }}
          >
            <Icon n="camera" size={20} />
          </button>
          <button
            type="button"
            className="pl-round"
            aria-label="锁定屏幕"
            onClick={() => {
              haptic("ok");
              setPanel(null);
              setLocked(true);
              setOsd(false);
              toast("已锁定 · 点左侧锁形按钮解锁");
            }}
          >
            <Icon n="unlock" size={19} />
          </button>
        </div>

        {/* ══ 右中:倍速条(上加 / 中显示 / 下减) ══ */}
        <div className="pl-side r">
          <div className="pl-sp">
            <button type="button" className="pl-sp-b" aria-label="加速" ref={spUp} disabled={speed >= SP_MAX}>
              <Icon n="plus" size={17} />
            </button>
            <div className={`pl-sp-v${(boost ? 2 : speed) !== 1 ? " on" : ""}`}>{fmtSpeed(boost ? 2 : speed)}</div>
            <button type="button" className="pl-sp-b" aria-label="减速" ref={spDn} disabled={speed <= SP_MIN}>
              <Icon n="minus" size={17} />
            </button>
          </div>
        </div>

        {/* ══ 底部:进度条 + 三簇 ══ */}
        <div className="pl-bottom">
          <div className="pl-bar">
            <span className="pl-t">{fmtTime(pos)}</span>
            <div
              className={`pl-track${dragging ? " drag" : ""}`}
              ref={trackRef}
              onPointerDown={(e) => {
                /* ★ 时长还不知道时**不接受拖动**:量程会退化成 1 秒,
                   用户点在条中间算出来的目标是 0.5 秒 —— 看着就是「点了没反应」。 */
                if (locked || !dur) return;
                setDragging(true);
                seekAt(e.clientX);
                bump();
              }}
              onPointerMove={(e) => dragging && seekAt(e.clientX)}
            >
              <div className="pl-track-bg" />
              <div className="pl-buf" style={{ transform: `scaleX(${bufP})` }} />
              <div className="pl-fill" style={{ transform: `scaleX(${p})` }} />
              <div className="pl-thumb" style={{ left: `${p * 100}%` }} />
            </div>
            <button
              type="button"
              className="pl-t pl-t-r"
              aria-label="切换显示总时长 / 剩余"
              onClick={() => {
                setShowRemain((v) => !v);
                haptic("tap");
              }}
            >
              {showRemain ? `−${fmtTime(Math.max(0, dur - pos))}` : fmtTime(dur)}
            </button>
          </div>

          {/* ★ 用 grid 1fr auto 1fr,中簇是**真的居中** —— flex+space-between 的话,
              左右两簇宽度不等时中间那组会偏。电影没有换集键,偏得更明显。 */}
          <div className="pl-ctl">
            <div className="pl-cl l">
              {isSeries && (
                <>
                  <IcoBtn label="上一集" icon="rewind" onClick={() => open("ep")} />
                  <IcoBtn label="下一集" icon="forward" onClick={() => open("ep")} />
                </>
              )}
            </div>
            <div className="pl-cl m">
              <IcoBtn label="快退 10 秒" icon="back" size={24} onClick={() => void jump(-10)} />
              <button type="button" className="pl-ico pl-play" aria-label="播放 / 暂停" onClick={togglePause}>
                <Icon n={st?.paused ? "play" : "pause"} size={26} />
              </button>
              <IcoBtn label="快进 30 秒" icon="chevR" size={24} onClick={() => void jump(30)} />
            </div>
            <div className="pl-cl r">
              <ChipBtn i={0} id="audio" icon="audio" label="音频" onClick={(e) => open("audio", e)} />
              {/* 弹幕 chip **自身就是开关**(亮=开),长按才进设置 */}
              <ChipBtn
                i={1}
                id="danmaku"
                icon="danmaku"
                label="弹幕"
                on={dm}
                onClick={() => {
                  setDm((v) => {
                    haptic("sel");
                    toast(v ? "弹幕已关" : "弹幕已开 · 长按进设置");
                    return !v;
                  });
                  bump();
                }}
                onLong={() => {
                  haptic("ok");
                  open("danmaku");
                }}
              />
              {isSeries && <ChipBtn i={2} id="ep" icon="list" label="选集" onClick={(e) => open("ep", e)} />}
            </div>
          </div>
        </div>
      </div>

      {/* ══ 面板 ══ */}
      {panel && !isPop && (
        <>
          <div className="pl-scrim on" onClick={() => setPanel(null)} />
          <div className="pl-panel drawer on">
            <div className="pl-panel-hd">
              <div className="f1">
                <h3>{PANEL_TITLE[panel]}</h3>
                <span className="pl-panel-sub">{panelSub(panel)}</span>
              </div>
              <button type="button" className="pl-ico sm" aria-label="关闭" onClick={() => setPanel(null)}>
                <Icon n="close" size={18} />
              </button>
            </div>
            {panel === "source" && (
              <div className="pl-tabs">
                <button type="button" className={`pl-tab${srcTab === "ver" ? " on" : ""}`} onClick={() => setSrcTab("ver")}>
                  版本<b>{versions.length}</b>
                </button>
                <button type="button" className={`pl-tab${srcTab === "line" ? " on" : ""}`} onClick={() => setSrcTab("line")}>
                  线路<b>{lines.length}</b>
                </button>
              </div>
            )}
            <div className="pl-panel-body" ref={panelBody}>
              {panel === "source" && (srcTab === "ver" ? versionBody() : lineBody())}
              {panel === "sr" && shaderBody()}
              {panel === "audio" && audioBody()}
              {panel === "danmaku" && danmakuBody()}
              {panel === "ep" && epBody()}
              {panel === "more" && moreBody()}
            </div>
          </div>
        </>
      )}

      {panel && isPop && (
        <>
          <div className="pl-scrim on" style={{ background: "transparent" }} onClick={() => setPanel(null)} />
          <div className="pl-panel pop on" ref={popRef}>
            <div className="pl-pop-hd">画面比例</div>
            <div className="pl-panel-body">
              <div className="opts">
                {RATIOS.map((r, i) => (
                  <Opt
                    key={r}
                    i={i}
                    label={r}
                    on={r === ratio}
                    onClick={() => {
                      setRatio(r);
                      haptic("sel");
                      void setAspectRatio(r === "自动" ? "" : r).catch(() => {});
                      setPanel(null);
                    }}
                  />
                ))}
              </div>
            </div>
          </div>
        </>
      )}
    </div>
  );

  /* ────────── 面板内容 ────────── */

  function panelSub(id: PanelId) {
    if (id === "source") {
      const v = versions.find((x) => x.id === curVer);
      const l = lines[activeLine];
      return `${fmtRes(v?.streams?.find((s) => s.type_ === "Video")?.height ?? null) || "当前版本"} · ${l?.name ?? "唯一线路"} · 切换后从当前位置继续`;
    }
    if (id === "sr") return "着色器在 GPU 上跑";
    if (id === "audio") return `${auds.length} 条音轨 · ${subs.length} 条字幕`;
    if (id === "danmaku") return dmComments.length ? `已加载 ${dmComments.length.toLocaleString("en-US")} 条` : "这一集没有匹配到弹幕";
    if (id === "ep") return eps.length ? `${eps.length} 集` : "正在拉集列表…";
    return "";
  }

  /* ── 版本:按分辨率分组 ──
     十几个版本平铺就是一堵墙。**分辨率是挑版本时的第一判据**(要 4K 还是要省流量)。 */
  function versionBody() {
    if (!versions.length) return <div className="pl-note">这个条目只有一个版本(或者服务器还没返回)。</div>;
    const groups: { res: string; items: MediaVersion[] }[] = [];
    for (const v of versions) {
      const res = fmtRes(v.streams?.find((s) => s.type_ === "Video")?.height ?? null) || "未知分辨率";
      const g = groups.find((x) => x.res === res) ?? (groups.push({ res, items: [] }), groups[groups.length - 1]);
      g.items.push(v);
    }
    const nice = (r: string) => (r === "2160p" ? "4K · 2160p" : r);
    return (
      <div>
        {groups.map((g) => (
          <div key={g.res}>
            <div className="pl-grp">
              <span>{nice(g.res)}</span>
              <b>{g.items.length} 个</b>
            </div>
            <div className="opts">
              {g.items.map((v, i) => (
                <Opt
                  key={v.id}
                  i={i}
                  on={v.id === curVer}
                  label={v.name}
                  sub={[fmtSize(v.size_bytes ?? 0), v.container?.toUpperCase(), fmtBitrate(v.bitrate)]
                    .filter(Boolean)
                    .join(" · ")}
                  onClick={() => {
                    haptic("sel");
                    setCurVer(v.id);
                    /* 换版本要重新起播才生效 —— 这里**不假装**已经切了。
                       真正的切换在详情页选好版本再播,那条路是通的。 */
                    toast("换版本要重新起播:退出后在详情页选这个版本", "warn");
                  }}
                />
              ))}
            </div>
          </div>
        ))}
      </div>
    );
  }

  /* ── 线路:按延迟分档 ──
     几十条线路让用户自己挑等于抽签。所以按延迟分三档,组内升序;
     挂掉的单独归到最后 —— **慢和不通是两件事**。 */
  function lineBody() {
    if (lines.length <= 1) {
      return <div className="pl-note">这台服务器只有一条线路。线路要在「服务器 → 长按 → 服务器线路」里加。</div>;
    }
    const idx = lines.map((l, i) => ({ ...l, i, ms: pings[i] }));
    const live = idx.filter((l) => l.ms != null).sort((a, b) => (a.ms! - b.ms!));
    const unknown = idx.filter((l) => l.ms === undefined);
    const dead = idx.filter((l) => l.ms === null);
    const buckets = [
      { g: "快 · 50ms 以内", items: live.filter((l) => l.ms! < 50) },
      { g: "中 · 50–150ms", items: live.filter((l) => l.ms! >= 50 && l.ms! < 150) },
      { g: "慢 · 150ms 以上", items: live.filter((l) => l.ms! >= 150) },
      { g: "还没测", items: unknown },
      { g: "连不上", items: dead },
    ].filter((b) => b.items.length);
    return (
      <div>
        {buckets.map((b) => (
          <div key={b.g}>
            <div className="pl-grp">
              <span>{b.g}</span>
              <b>{b.items.length} 条</b>
            </div>
            <div className="opts">
              {b.items.map((l, i) => (
                <Opt
                  key={l.url}
                  i={i}
                  on={l.i === activeLine}
                  /* ★ 只写名称和延迟,**不写地址**(用户 2026-08-02:
                     「在任何地方都不要展示具体的线路地址」)。
                     没起名字的线路回落成「线路 N」,不是回落成 URL —— 那正是要避开的。 */
                  label={l.name || `线路 ${l.i + 1}`}
                  sub={l.ms == null ? (l.ms === null ? "连不上" : "还没测") : `延迟 ${l.ms} ms`}
                  badge={l.ms == null ? (l.ms === null ? "不通" : "—") : `${l.ms}ms`}
                  onClick={() => {
                    haptic("sel");
                    const me = lines[l.i];
                    setActiveLineIdx(l.i);
                    listAccounts()
                      .then((as) => {
                        const acc = as.find((a) => a.active) ?? as[0];
                        if (!acc) return;
                        return setActiveLine(acc.server, l.i);
                      })
                      .then(() => toast(`已切到 ${me.name} · 下次起播生效`, "ok"))
                      .catch((e) => toast(String(e), "bad"));
                  }}
                />
              ))}
            </div>
          </div>
        ))}
      </div>
    );
  }

  function shaderBody() {
    if (!shaders.length) return <div className="pl-note">核层没返回可用的着色器档位。</div>;
    return (
      <div>
        {/* ★ 这句不是废话:Anime4K 每个 pass 都带「输出 > 源 ×1.2」的门槛,
            窗口没比源大就整条链空转 —— 用户会以为"开了没用"。 */}
        <div className="pl-note">
          锐化 / 去噪在<b>源分辨率</b>就生效;放大类要求输出分辨率 <b>&gt; 源的 1.2 倍</b>,
          手机竖屏播 1080p 时基本不会启用。
        </div>
        <div className="opts">
          {shaders.map(([id, name, family], i) => (
            <Opt
              key={id}
              i={i}
              on={id === curShader}
              label={name}
              sub={family}
              onClick={() => {
                haptic("sel");
                setCurShader(id);
                setShaderLevel(id)
                  .then((r) => {
                    /* ★ count>0 只说明 mpv 收下了路径，**不代表 shader 会跑**。
                       看 will_run，并把核层给的 note（带真实数字）原话转给用户 ——
                       只看 count 就报「已生效」正是它撞过的谎。 */
                    if (id === "off") return toast("已关闭增强", "ok");
                    if (r.will_run === false) toast(r.note || "这一档在当前尺寸下不会跑", "warn");
                    else if (r.count === 0) toast("挂上了 0 个着色器 —— 这一档没生效", "warn");
                    else toast(`已启用 ${name}`, "ok");
                  })
                  .catch((e) => toast(String(e), "bad"));
              }}
            />
          ))}
        </div>
      </div>
    );
  }

  /* 「音频」下面同时管音轨和字幕 —— 开这两个的动机是同一句"这条不对,换一条"。
     分成两个入口等于把一件事切两半。 */
  function audioBody() {
    return (
      <div>
        <div className="pl-grp">
          <span>音轨</span>
          <b>{auds.length} 条</b>
        </div>
        <div className="opts">
          {auds.length ? (
            auds.map((t, i) => (
              <Opt
                key={t.id}
                i={i}
                on={t.selected}
                label={t.title || t.lang || `轨道 ${t.id}`}
                onClick={() => {
                  haptic("sel");
                  void setTrack("audio", t.id);
                }}
              />
            ))
          ) : (
            <div className="pl-note">还没探到音轨 —— 起播后几秒内是正常的。</div>
          )}
        </div>
        <SliderRowPl label="音频延迟" value={audioDelay} min={-5} max={5} step={0.1} fmt={(v) => `${v.toFixed(1)} 秒`} onChange={(v) => { setAudioDelayState(v); void setAudioDelay(v); }} />

        <div className="pl-grp">
          <span>字幕</span>
          <b>{subs.length} 条</b>
        </div>
        <div className="opts">
          {/* 「关闭」永远排第一 —— 关字幕是最高频的操作,不该让人滚到底去找 */}
          <Opt label="关闭" i={0} on={!subs.some((t) => t.selected)} onClick={() => { haptic("sel"); void setTrack("sub", "no"); }} />
          {subs.map((t, i) => (
            <Opt
              key={t.id}
              i={i + 1}
              on={t.selected}
              label={t.title || t.lang || `轨道 ${t.id}`}
              onClick={() => {
                haptic("sel");
                void setTrack("sub", t.id);
              }}
            />
          ))}
        </div>
        <SliderRowPl label="字幕延迟" value={subDelay} min={-5} max={5} step={0.1} fmt={(v) => `${v.toFixed(1)} 秒`} onChange={(v) => { setSubDelayState(v); void setSubDelay(v); }} />
      </div>
    );
  }

  function danmakuBody() {
    return (
      <div>
        <OptGroup>来源</OptGroup>
        <div className="pl-note">
          {dmComments.length
            ? `弹弹play 自动匹配到 ${dmComments.length.toLocaleString("en-US")} 条。匹配规则、屏蔽词、多源优先级在「设置 → 弹幕」里改。`
            : "这一集没匹配到弹幕。可能是片名对不上,也可能这个包没带弹弹play 的编译期凭据。"}
        </div>
        <OptGroup>开关</OptGroup>
        <div className="opts">
          <Opt
            label={dm ? "弹幕开着" : "弹幕关着"}
            sub="也可以直接点底部那个「弹幕」按钮"
            on={dm}
            onClick={() => {
              haptic("sel");
              setDm((v) => !v);
            }}
          />
        </div>
      </div>
    );
  }

  /* ★ 选集用**带封面的行**(用户 2026-07-28 定):
       封面 | 第一行 = 季集(+集名) / 第二行 = 时长 · 分辨率 · 码率
     纯文字列表在播放器里不够用 —— 播放中换集,用户是**靠画面认集**的,
     "第 7 集"这三个字唤不起记忆,一张剧照可以。 */
  function epBody() {
    if (!eps.length) return <div className="pl-note">正在拉集列表…</div>;
    return (
      <div className="pl-eps">
        {eps.map((e, i) => {
          const cur = e.id === item?.id;
          return (
            <button
              key={e.id}
              type="button"
              className={`pl-eprow${cur ? " on" : ""}`}
              style={{ ["--i" as string]: i }}
              onClick={() => {
                haptic("tap");
                setPanel(null);
                /* 换集 = 重新起播。走 App 的 play(),它会先 await 成功再导航。 */
                toast(`切到 S${e.season_no ?? 1}E${e.episode_no ?? "?"}`);
              }}
            >
              <div className="pl-ep-th">
                {session && <img src={thumbUrl(session, e.id, 320)} alt="" loading="lazy" decoding="async" />}
                {/* 看完打勾 / 看了一半画一条进度线 —— 这两件事要分开表达。
                    都写成一行字("已看完"/"看到 33:00")扫的时候分不出来。 */}
                {e.played && (
                  <span className="pl-ep-done">
                    <Icon n="check" size={12} />
                  </span>
                )}
                {e.resume_secs > 0 && e.runtime_secs > 0 && (
                  <i className="pl-ep-prog" style={{ transform: `scaleX(${Math.min(1, e.resume_secs / e.runtime_secs)})` }} />
                )}
              </div>
              <div className="pl-ep-tx">
                <div className="pl-ep-t">
                  S{e.season_no ?? 1}E{e.episode_no ?? "?"}
                  {e.name ? ` · ${e.name}` : ""}
                </div>
                <div className="pl-ep-m">
                  <span>
                    {[fmtTime(e.runtime_secs), fmtRes(e.video_height), fmtBitrate(e.bitrate)].filter(Boolean).join(" · ")}
                  </span>
                </div>
              </div>
              {cur && <span className="pl-ep-now">在播</span>}
            </button>
          );
        })}
      </div>
    );
  }

  function moreBody() {
    return (
      <div>
        <div className="opts">
          <Opt
            label="画面比例"
            sub={ratio}
            onClick={(() => {
              /* 这一项打开的是**贴着行弹的小浮层**,不是再套一层抽屉。 */
              return (e?: unknown) => {
                void e;
                setPanel("ratio");
              };
            })()}
          />
          <Opt
            label="播放信息"
            sub={
              st?.video
                ? `${st.video.vo || "视频输出没起来"} · ${st.video.width}×${st.video.height} · ${st.video.hwdec || "软解"}`
                : "核层还没报"
            }
          />
        </div>
        <div className="pl-note">
          倍速在右侧那条竖条上(点一下走一档,按住连续加减);截图和锁屏在左侧。
          更多播放器默认值在「设置 → 播放」里。
        </div>
      </div>
    );
  }
}

const PANEL_TITLE: Record<string, string> = {
  source: "播放源",
  sr: "画质增强",
  audio: "音频与字幕",
  danmaku: "弹幕",
  ep: "选集",
  more: "更多",
  ratio: "画面比例",
};

function TopAct({
  id,
  icon,
  label,
  on,
  onClick,
}: {
  id: string;
  icon: string;
  label: string;
  on?: boolean;
  onClick: (el: HTMLElement) => void;
}) {
  return (
    <button
      type="button"
      className={`pl-act${on ? " act" : ""}`}
      data-p={id}
      onClick={(e) => onClick(e.currentTarget)}
    >
      <Icon n={icon} size={15} />
      <span>{label}</span>
    </button>
  );
}

function IcoBtn({ label, icon, size = 22, onClick }: { label: string; icon: string; size?: number; onClick: () => void }) {
  return (
    <button type="button" className="pl-ico" aria-label={label} onClick={onClick}>
      <Icon n={icon} size={size} />
    </button>
  );
}

function ChipBtn({
  i,
  id,
  icon,
  label,
  on,
  onClick,
  onLong,
}: {
  i: number;
  id: string;
  icon: string;
  label: string;
  on?: boolean;
  onClick: (el: HTMLElement) => void;
  onLong?: () => void;
}) {
  const ref = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (!ref.current || !onLong) return;
    return longPress(ref.current, () => onLong());
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);
  return (
    <button
      type="button"
      className={`pl-chip${on ? " on" : ""}`}
      data-p={id}
      ref={ref}
      style={{ ["--i" as string]: i }}
      onClick={(e) => onClick(e.currentTarget)}
    >
      <Icon n={icon} size={15} />
      <span className="pl-chip-l">{label}</span>
    </button>
  );
}

/** 面板内的滑块。★ 拖动只改本地显示,**松手才发命令** ——
 *  每帧一次 invoke 会把命令队列灌满,那是"拖着拖着卡住"的来源。 */
function SliderRowPl({
  label,
  value,
  min,
  max,
  step,
  fmt,
  onChange,
}: {
  label: string;
  value: number;
  min: number;
  max: number;
  step: number;
  fmt: (v: number) => string;
  onChange: (v: number) => void;
}) {
  const [live, setLive] = useState(value);
  useEffect(() => setLive(value), [value]);
  return (
    <div className="pl-sl">
      <div className="pl-sl-t">
        <span>{label}</span>
        <span className="pl-sl-v">{fmt(live)}</span>
      </div>
      <input
        className="rng"
        type="range"
        min={min}
        max={max}
        step={step}
        value={live}
        onChange={(e) => setLive(+e.target.value)}
        onPointerUp={() => live !== value && onChange(live)}
      />
    </div>
  );
}
