import { useCallback, useEffect, useRef, useState } from "react";
import {
  type Status,
  type Track,
  danmakuVisible,
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
  onBack: () => void;
  /** 收进迷你播放器(不停播) */
  onMinimize: () => void;
};

type Panel = null | "sub" | "audio" | "speed";

const SPEEDS = [0.5, 0.75, 1, 1.25, 1.5, 2, 3] as const;

export default function PlayerPage({ title, onBack, onMinimize }: Props) {
  const [st, setSt] = useState<Status | null>(null);
  const [trk, setTrk] = useState<Track[]>([]);
  const [osd, setOsd] = useState(true);
  const [panel, setPanel] = useState<Panel>(null);
  const [speed, setSpeedState] = useState(1);

  const [dm, setDm] = useState(true);
  /** 手势指示器:亮度/音量/进度预览 */
  const [hud, setHud] = useState<null | { kind: string; text: string; pct?: number }>(null);
  const [boost, setBoost] = useState(false); // 长按 2× 中

  const hideAt = useRef(0);
  const ended = useRef(false);
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
      volRef.current = o.volume;
    }).catch(() => {});
  }, []);

  /* 状态轮询 1s。轮询而不是订阅:核层没有 status 推送通道,而且轮询在卸载时天然停掉。 */
  useEffect(() => {
    let alive = true;
    const t = setInterval(async () => {
      try {
        const s = await getStatus();
        if (!alive) return;
        setSt(s);
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
      const p = Math.max(0, Math.min(s.duration || 0, s.time + d));
      await seek(p);
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
          void seek(target);
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
          void setSpeed(on ? 2 : speed);
        },
      },
    );
  }, [jump, speed]);

  const dur = st?.duration || 0;
  const pos = st?.time ?? 0;
  const subs = trk.filter((t) => t.kind === "sub");
  const auds = trk.filter((t) => t.kind === "audio");

  return (
    <div className="player" ref={surface}>
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
                ★ onMouseUp 不能挂在 input 自己身上:拖出界再松手就钉死了(PC 端栽过)。
                  这里用 onChange 更新预览 + onPointerUp 挂在容器上提交。 */}
            <input
              className="pl-seek"
              type="range"
              min={0}
              max={dur || 1}
              step={1}
              value={pos}
              onChange={(e) => {
                const v = Number(e.target.value);
                setSt((s) => (s ? { ...s, time: v } : s));
                bump();
              }}
              onPointerUp={(e) => void seek(Number((e.target as HTMLInputElement).value))}
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
              onClick={() => {
                const next = !dm;
                setDm(next);
                void danmakuVisible(next);
              }}
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
