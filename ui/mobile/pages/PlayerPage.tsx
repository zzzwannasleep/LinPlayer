import { useCallback, useEffect, useRef, useState } from "react";
import {
  type DanmakuComment,
  type DanmakuMatchInput,
  type Item,
  type Status,
  type Track,
  danmakuAutoLoad,
  defaultDanmakuFilter,
  fmtTime,
  playerOpts,
  reportProgress,
  seek,
  setNowPlaying,
  setPause,
  setSpeed,
  setTrack,
  setVolume,
  status as getStatus,
  stopPlayback,
} from "@shared/api";
import { pollTracks } from "@shared/track-poll";
import { DanmakuLayer, type TimeSync } from "@shared/Danmaku";
import { attachGestures } from "../components/Gestures";
import Sheet from "../components/Sheet";
import { onShellKey, pushBackHandler } from "../app/backkey";
import {
  IconChevronLeft,
  IconForward,
  IconList,
  IconPause,
  IconPlay,
  IconRewind,
} from "../app/icons";

/* 播放页。

   ## 视频不在这个组件里
   画面是垫在透明 WebView **底下**的原生 mpv SurfaceView。这一页只是叠在上面的
   一层 UI —— 所以进页要给 <html> 挂 `.playing` 把背景整个撤掉,否则视频被盖死,
   表现是「有声音没画面」。离页必须摘掉,不然回到列表页是一片透明(=黑)。

   ## OSD 之外全是手势
   Emby 官方安卓端一个手势都没有,这是最容易拉开差距的地方。六个手势的实现和
   三条设计约束在 components/Gestures.ts 里。

   ## 返回键三级
   面板开着先关面板 → OSD 开着先收 OSD → 才退出播放。
   一次退到底是最容易挨骂的交互:用户只想关掉字幕面板,结果整个退出了。 */

type Props = {
  title?: string;
  /** 正在播的条目。只用来给弹幕自动匹配喂剧名/集号/时长(route.title 是拼好的串,搜不到)。 */
  item?: Item | null;
  onBack: () => void;
  /** 收进迷你播放器(不停播) */
  onMinimize: () => void;
};

type Panel = null | "sub" | "audio" | "speed";

const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2, 3] as const;

export default function PlayerPage({ title, item, onBack, onMinimize }: Props) {
  const [st, setSt] = useState<Status | null>(null);
  const [trk, setTrk] = useState<Track[]>([]);
  const [osd, setOsd] = useState(true);
  const [panel, setPanel] = useState<Panel>(null);
  const [speed, setSpeedState] = useState(1);

  /* 弹幕。渲染走**网页 Canvas 层**,和 PC 端同一个组件(@shared/Danmaku)——
     曾经有一条「生成 ASS 挂给 mpv 的 secondary-sid」的路,已经整条删掉:
     次字幕位只有一个,占了就没法开双语字幕。
     ★ 这一页原来只有一个调 danmakuVisible 的按钮,而**从来没有人加载过弹幕** ——
       那个开关切的是 mpv 的次字幕可见性,点了要么没反应、要么把用户的双语字幕关掉。 */
  const [dm, setDm] = useState(true);
  const [dmComments, setDmComments] = useState<DanmakuComment[]>([]);
  /* 播放时钟快照。轮询是 1s 一拍,弹幕要 60fps —— 两拍之间靠墙钟外推。
     `speed` 必须带上,不然倍速下弹幕按 1x 爬,每秒被真值硬拽回去一次。 */
  const timeSync = useRef<TimeSync>({ base: 0, stamp: performance.now(), paused: false, speed: 1 });
  const speedRef = useRef(1);
  /** 手势指示器:亮度/音量/进度预览 */
  const [hud, setHud] = useState<null | { kind: string; text: string; pct?: number }>(null);
  const [boost, setBoost] = useState(false); // 长按 2× 中

  /* 进度条拖动中的值。★ 三件事得一起做,少一件就是一类具体的 bug:
     1) 拖动期间用它盖住 1s 轮询的 st.time —— 否则还没松手就被真值拽回原处;
     2) 提交挂在 **window** 的 pointerup 上,不能挂 <input> 自己身上 —— 手指划出条外
        再抬起,input 根本收不到事件,进度条从此钉死(PC 端栽过;这一页的注释写着
        「不能挂 input 上」,而下面正是挂在 input 上);
     3) 等核层收下 seek 再放开,失败也放开(不放开 = 一次失败把条永久钉住)。 */
  const [seeking, setSeeking] = useState<number | null>(null);
  const seekingRef = useRef<number | null>(null);

  const hideAt = useRef(0);
  const ended = useRef(false);
  /** 「跳转卡住了」是否已经提示过。一次 seek 只说一次,别每秒刷一条。 */
  const stallSaid = useRef(false);
  const stRef = useRef<Status | null>(null);
  stRef.current = st;
  const surface = useRef<HTMLDivElement>(null);
  /* 音量放 ref 不放 state,两个理由:
     1. `Status` 里**没有** volume 字段(它只报时间/时长/暂停/缓冲/eof),真值在 playerOpts();
     2. 它**从不参与渲染**(HUD 自己有 hud.text)。放 state 的话竖滑一次音量会触发
        几十次整页重渲染 —— 手势期间掉帧的经典来源。 */
  const volRef = useRef(100);
  /* 亮度没有跨平台 API(WebView 拿不到系统亮度)。用一层黑色蒙版模拟:
     只能变暗不能变亮 —— 这是 Web 层能做到的极限,比"没有亮度手势"强。
     ★ 真要调系统亮度得走宿主 Window.attributes.screenBrightness,那是 P1 的事,
       这里**不假装**已经做了。 */
  const [dim, setDim] = useState(0);

  useEffect(() => {
    document.documentElement.classList.add("playing");
    return () => document.documentElement.classList.remove("playing");
  }, []);

  useEffect(() => {
    void setNowPlaying(title ?? null);
    return () => {
      void setNowPlaying(null);
    };
  }, [title]);

  useEffect(() => {
    playerOpts().then((o) => {
      setSpeedState(o.speed);
      speedRef.current = o.speed;
      volRef.current = o.volume;
    }).catch(() => {});
  }, []);

  /* 弹幕自动匹配。整套多源并行 + 分数门槛 + 下一集锚点都在核层,这里只负责喂输入。
     全程 catch:弹幕挂不上绝不能影响播放,但失败也不静默改状态 —— 没匹配到就是空列表,
     开关照样能点,只是画布上什么都没有。 */
  useEffect(() => {
    if (!item) return;
    let alive = true;
    const input: DanmakuMatchInput = {
      title: item.series_name ?? item.name, // 剧集要用剧名,Episode.name 是「第 N 集」搜不到
      episode_no: item.episode_no,
      file_name: item.name,
      duration_secs: item.runtime_secs > 0 ? item.runtime_secs : null,
    };
    danmakuAutoLoad(input, defaultDanmakuFilter(), null, item.series_id ?? null)
      .then((c) => { if (alive && c) setDmComments(c); })
      .catch(() => {});
    return () => { alive = false; };
  }, [item?.id]);

  /* 状态轮询 1s。轮询而不是订阅:核层没有 status 推送通道,而且轮询在卸载时天然停掉。 */
  useEffect(() => {
    let alive = true;
    const t = setInterval(async () => {
      try {
        const s = await getStatus();
        if (!alive) return;
        setSt(s);
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
           另外 keep-open 下 END_FILE 永远不发,判播完只能读 eof(见 [[mpv-keepopen-eof-detection]])。 */
        if (s.eof && !ended.current) {
          ended.current = true;
          clearInterval(t);
          void stopPlayback(s.duration).finally(onBack);
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
  }, [onBack]);

  /* 轨道要**探到稳定**,不能起播拉一次就定死:外挂字幕要等核层收到 mpv 的
     FILE_LOADED 才挂得上,慢服务器上是起播后好几秒的事。三端共用一份逻辑。 */
  useEffect(() => pollTracks(setTrk), []);

  const bump = useCallback(() => {
    setOsd(true);
    hideAt.current = Date.now() + 4000;
  }, []);

  useEffect(() => {
    if (!osd || panel) return; // 面板开着不收 —— 用户正在里面挑东西
    hideAt.current = Date.now() + 4000;
    const t = setInterval(() => {
      if (Date.now() >= hideAt.current) setOsd(false);
    }, 400);
    return () => clearInterval(t);
  }, [osd, panel]);

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

  /* 返回键三级。★ 注册顺序决定优先级:面板自己的 Sheet 也注册了一层,
     它比这里更内层,所以面板开着时先被它吃掉。 */
  useEffect(
    () =>
      pushBackHandler(() => {
        if (panel) {
          setPanel(null);
          return true;
        }
        if (osd) {
          setOsd(false);
          return true;
        }
        return false; // 让 onShellKey 那条走 stopPlayback
      }),
    [panel, osd],
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

  /* 手势。挂在整个播放层上 —— 挂在 OSD 上的话 OSD 收起来就没手势了。 */
  useEffect(() => {
    const el = surface.current;
    if (!el) return;
    return attachGestures(
      el,
      () => ({ time: stRef.current?.time ?? 0, duration: stRef.current?.duration ?? 0 }),
      {
        onAdjust: (kind, ratio) => {
          if (kind === "brightness") {
            setDim((v) => {
              const next = Math.max(0, Math.min(0.85, v - ratio));
              setHud({ kind: "亮度", text: `${Math.round((1 - next) * 100)}%`, pct: 1 - next });
              return next;
            });
          } else {
            const next = Math.max(0, Math.min(100, volRef.current + ratio * 100));
            volRef.current = next;
            void setVolume(next);
            setHud({ kind: "音量", text: `${Math.round(next)}%`, pct: next / 100 });
          }
        },
        onSeekPreview: (target) => {
          const s = stRef.current;
          const d = target - (s?.time ?? 0);
          setHud({
            kind: "进度",
            text: `${fmtTime(target)}  ${d >= 0 ? "+" : "−"}${fmtTime(Math.abs(d))}`,
            pct: s?.duration ? target / s.duration : 0,
          });
        },
        /* ★ 抬手才 seek 一次。拖动期间每帧发 seek 会把 mpv 的命令队列灌满 ——
           本项目在进度条上栽过:「拖动松手弹回」的根因就是 seek 排队。 */
        onSeekCommit: (target) => {
          void seek(target).catch(() => {}); // 核层没就绪会 reject,不接就是 unhandled rejection
          const s = stRef.current;
          if (s) setSt({ ...s, time: target });
        },
        onEnd: () => setHud(null),
        onSingleTap: () => setOsd((v) => !v),
        onDoubleTap: (side) => {
          void jump(side === "left" ? -10 : 10);
          setHud({ kind: side === "left" ? "快退" : "快进", text: "10 秒" });
          window.setTimeout(() => setHud(null), 600);
        },
        onLongPress: (on) => {
          setBoost(on);
          const v = on ? 2 : speed;
          speedRef.current = v; // 弹幕的墙钟外推按倍速走,不同步这里 2× 时弹幕会一直被拽
          void setSpeed(v);
        },
      },
    );
  }, [jump, speed]);

  /* 松手提交。挂 window,理由见 seeking 那段。依赖写 `seeking == null` 而不是 seeking:
     拖动中每动一像素都重挂一遍监听器毫无意义,只要「有没有在拖」这一位变了才需要。 */
  useEffect(() => {
    if (seeking == null) return;
    let done = false;
    const commit = () => {
      if (done) return;
      done = true;
      const v = seekingRef.current;
      if (v == null) { setSeeking(null); return; }
      seek(v).catch(() => {}).finally(() => {
        if (seekingRef.current !== v) return; // 等待期间又拖起来了就别插手
        seekingRef.current = null;
        setSeeking(null);
      });
    };
    window.addEventListener("pointerup", commit);
    window.addEventListener("pointercancel", commit);
    window.addEventListener("blur", commit);
    return () => {
      window.removeEventListener("pointerup", commit);
      window.removeEventListener("pointercancel", commit);
      window.removeEventListener("blur", commit);
    };
  }, [seeking == null]);

  /* ★ 核层每次 loadfile 都把 duration 记账清回 0,mpv 要到 FILE_LOADED 才报得出来。
     这几拍(服务器上能有好几秒)里拿 Emby 的 runtime 顶上,否则进度条量程塌成 1 秒:
     用户点在条中间,目标是 0.5 秒而不是片长的一半 —— 看着就是「点了跳转画面没动」。 */
  const dur = st?.duration || item?.runtime_secs || 0;
  const pos = seeking ?? st?.time ?? 0;
  const subs = trk.filter((t) => t.kind === "sub");
  const auds = trk.filter((t) => t.kind === "audio");

  return (
    <div className="player" ref={surface}>
      {/* 弹幕层。垫在 OSD 之下、亮度蒙版之上;pointer-events:none,不能吃掉手势。
          没有弹幕时它就是一张空画布(组件内部会整帧跳过,不占 GPU)。 */}
      <div className="pl-dmwrap">
        <DanmakuLayer comments={dmComments} timeSync={timeSync} enabled={dm} />
      </div>

      {/* 亮度蒙版。pointer-events:none —— 它不能吃掉手势。 */}
      {dim > 0 && <div className="pl-dim" style={{ opacity: dim }} />}

      {hud && (
        <div className="pl-hud">
          <div className="pl-hud-k">{hud.kind}</div>
          <div className="pl-hud-v">{hud.text}</div>
          {hud.pct != null && (
            <div className="pl-hud-bar"><i style={{ width: `${Math.max(0, Math.min(1, hud.pct)) * 100}%` }} /></div>
          )}
        </div>
      )}

      {boost && <div className="pl-boost">2× 快进中</div>}

      <div className={`pl-osd${osd ? " on" : ""}`}>
        {/* 顶栏。★ 标题自带不透明底,不用渐变 —— 全屏渐变每帧都要重新合成,
            而且渐变边界在低分屏上是糊的(TV 端评审定的口径,手机 GPU 更弱)。 */}
        <div className="pl-top">
          <button type="button" className="pl-ico" onClick={onBack} aria-label="返回">
            <IconChevronLeft size={24} />
          </button>
          <div className="pl-title">{title ?? ""}</div>
          <button type="button" className="pl-ico" onClick={onMinimize} aria-label="缩小">
            <span className="pl-mini-ico" />
          </button>
        </div>

        <div className="pl-bottom">
          <div className="pl-bar">
            <span className="pl-t">{fmtTime(pos)}</span>
            {/* 进度条也可点/可拖 —— 手势之外还留着它,因为"精确跳到某处"用手势做不到。
                ★ 时长还不知道(起播/换片)时**必须禁用**:量程会退化成 `dur || 1` = 1 秒,
                  用户点在条中间算出来的目标是 0.5 秒而不是片长的一半 —— 核层照单全收地
                  跳回片头,看着就是「点了没反应、画面不变,条贴在缓冲头上」。
                ★ 提交挂在 window 上,见上面 seeking 那段(挂 input 自己身上=拖出界钉死)。 */}
            <input
              className="pl-seek"
              type="range"
              min={0}
              max={dur || 1}
              step={1}
              value={pos}
              disabled={!(dur > 0)}
              onChange={(e) => {
                const v = Number(e.target.value);
                seekingRef.current = v;
                setSeeking(v);
                bump();
              }}
            />
            <span className="pl-t">{fmtTime(dur)}</span>
          </div>

          {/* 左组是通用约定,可纯图标;右组必须图标+文字 —— 裸图标方块用户第一反应是"那是什么" */}
          <div className="pl-ctl">
            <button type="button" className="pl-ico" onClick={() => void jump(-10)} aria-label="快退 10 秒">
              <IconRewind size={26} />
            </button>
            <button type="button" className="pl-ico pl-play" onClick={togglePause} aria-label="播放/暂停">
              {st?.paused ? <IconPlay size={30} /> : <IconPause size={30} />}
            </button>
            <button type="button" className="pl-ico" onClick={() => void jump(30)} aria-label="快进 30 秒">
              <IconForward size={26} />
            </button>
          </div>

          <div className="pl-more">
            <button type="button" className="pl-txt" onClick={() => setPanel("sub")}>
              <IconList size={16} /> 字幕
            </button>
            <button type="button" className="pl-txt" onClick={() => setPanel("audio")}>
              <IconList size={16} /> 音轨
            </button>
            <button
              type="button"
              className={`pl-txt${dm ? " on" : ""}`}
              onClick={() => setDm((v) => !v)}
            >
              弹幕
            </button>
            <button type="button" className="pl-txt" onClick={() => setPanel("speed")}>
              {speed}×
            </button>
          </div>
        </div>
      </div>

      <Sheet open={panel === "sub"} onClose={() => setPanel(null)} title="字幕">
        <TrackList list={subs} onPick={(id) => { void setTrack("sub", id); setPanel(null); }} />
      </Sheet>
      <Sheet open={panel === "audio"} onClose={() => setPanel(null)} title="音轨">
        <TrackList list={auds} onPick={(id) => { void setTrack("audio", id); setPanel(null); }} />
      </Sheet>
      <Sheet open={panel === "speed"} onClose={() => setPanel(null)} title="播放速度">
        <div className="opts">
          {SPEEDS.map((s) => (
            <button
              key={s}
              type="button"
              className={`opt${s === speed ? " on" : ""}`}
              onClick={() => {
                setSpeedState(s);
                speedRef.current = s;
                void setSpeed(s);
                setPanel(null);
              }}
            >
              {s}×
            </button>
          ))}
        </div>
      </Sheet>
    </div>
  );
}

function TrackList({ list, onPick }: { list: Track[]; onPick: (id: string) => void }) {
  if (!list.length) return <div className="empty"><div className="dim">没有可选的轨道</div></div>;
  return (
    <div className="opts">
      {/* 「关闭」永远排第一 —— 关字幕是最高频的操作,不该让人滚到底去找 */}
      <button type="button" className="opt" onClick={() => onPick("no")}>关闭</button>
      {list.map((t) => (
        <button key={t.id} type="button" className={`opt${t.selected ? " on" : ""}`} onClick={() => onPick(t.id)}>
          {t.title || t.lang || `轨道 ${t.id}`}
        </button>
      ))}
    </div>
  );
}
