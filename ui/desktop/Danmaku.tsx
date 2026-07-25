import { useEffect, useRef, type MutableRefObject } from "react";

/* 弹幕类型只保留**一份**(核层契约那份)。这里原本另写了个四字段的窄版本,
   于是同名两个类型在 App.tsx 里对不上 —— 把同一份数据既喂给这个组件、又喂给
   danmaku_attach 时会当场编译错。渲染只用到前四个字段,但类型别再分家。 */
export type { DanmakuComment } from "@shared/api";
import type { DanmakuComment } from "@shared/api";
/** 播放时钟的快照。`speed` **必须有**:两次轮询之间是用墙钟外推的,
 *  没有倍速这个因子,2x 播放时弹幕按 1x 爬,再每 250ms 被真值一把拽回去 ——
 *  那就是用户报的「倍速更卡」,和绘制开销毫无关系。 */
export type TimeSync = { base: number; stamp: number; paused: boolean; speed: number };

type Active = { text: string; color: string; mode: number; born: number; width: number; lane: number; speed: number };

const DURATION = 8; // 滚动弹幕在屏时长(秒)——不传 duration 时的默认,改它会改默认观感
const FIXED_DUR = 5; // 顶/底弹幕停留时长

/** Canvas 弹幕层:自跑 rAF,时间从 timeSync 插值(平滑于 500ms 轮询),同步 mpv 播放。
 *
 *  弹幕的「显示速度 / 字体大小」是**前端渲染参数**(核层 danmaku_filter 只管过滤/去重,
 *  文档里写明渲染归前端),所以调节点在这儿,不是缺核层命令。
 *  两个 props 都可省:省略时行为与开放 props 之前逐像素一致,用户不动就不变。 */
export function DanmakuLayer({
  comments,
  timeSync,
  enabled,
  duration = DURATION,
  fontSize,
}: {
  comments: DanmakuComment[];
  timeSync: MutableRefObject<TimeSync>;
  enabled: boolean;
  /** 滚动弹幕横穿屏幕的秒数,越小越快。省略 = DURATION(8s)。 */
  duration?: number;
  /** 弹幕字号(CSS px)。省略 = 按画面高自适应(canvas.height/22,原行为)。 */
  fontSize?: number;
}) {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const stateRef = useRef({ cursor: 0, active: [] as Active[], lastT: -1, laneFree: [] as number[] });

  // 换视频/重载弹幕 → 重置游标与在屏弹幕
  useEffect(() => {
    stateRef.current = { cursor: 0, active: [], lastT: -1, laneFree: [] };
  }, [comments]);

  useEffect(() => {
    const canvas = canvasRef.current!;
    const ctx = canvas.getContext("2d")!;
    let raf = 0;

    /* 画布尺寸靠 ResizeObserver 推,不在 rAF 里读 getBoundingClientRect ——
       后者每帧强制一次同步布局(layout thrash),而尺寸一秒也变不了几次。 */
    let W = 0, H = 0, dpr = 1;
    const measure = () => {
      const r = canvas.getBoundingClientRect();
      dpr = window.devicePixelRatio || 1;
      W = Math.round(r.width * dpr);
      H = Math.round(r.height * dpr);
    };
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(canvas);

    const frame = () => {
      raf = requestAnimationFrame(frame);
      if (canvas.width !== W || canvas.height !== H) { canvas.width = W; canvas.height = H; }
      ctx.clearRect(0, 0, canvas.width, canvas.height);
      if (!enabled || !comments.length) { stateRef.current.active = []; return; }

      // canvas 是 dpr 放大过的位图,故 CSS px 的 fontSize 要乘 dpr 才是画布里的字号;
      // 自适应那支本就以画布像素算,不用乘。
      const fs = fontSize != null
        ? Math.max(10, Math.round(fontSize * dpr))
        : Math.max(18, Math.round(canvas.height / 22));
      ctx.font = `${fs}px "Microsoft YaHei", sans-serif`;
      const laneH = Math.round(fs * 1.4);
      const numLanes = Math.max(1, Math.floor(canvas.height / laneH));

      const st = stateRef.current;
      const ts = timeSync.current;
      // ★ 乘 speed:墙钟外推必须按倍速走,否则每次轮询都要把弹幕硬拽回真实位置。
      const t = ts.paused ? ts.base : ts.base + ((performance.now() - ts.stamp) / 1000) * (ts.speed || 1);

      // seek 检测:大跳则清屏并重定位游标
      if (t < st.lastT - 0.5 || t > st.lastT + 3) {
        st.active = [];
        let i = 0;
        while (i < comments.length && comments[i].time < t) i++;
        st.cursor = i;
      }
      st.lastT = t;

      // 生成到当前时间
      while (st.cursor < comments.length && comments[st.cursor].time <= t) {
        const c = comments[st.cursor++];
        if (!c.text) continue;
        const width = ctx.measureText(c.text).width;
        const color = `#${(c.color & 0xffffff).toString(16).padStart(6, "0")}`;
        const speed = (canvas.width + width) / duration;
        let lane = 0;
        if (c.mode === 4 || c.mode === 5) {
          const used = new Set(st.active.filter((a) => a.mode === c.mode).map((a) => a.lane));
          while (used.has(lane) && lane < numLanes - 1) lane++;
        } else {
          /* 滚动:选入口已空出的道,否则选最快空出的。
             ★ 每条轨的「空出时刻」直接记在 laneFree 里 —— 原来是对**全量在屏弹幕**
               做 filter+slice(-1),外面还套着轨道数的循环,于是每生成一条弹幕就是
               O(轨道数 × 在屏条数)。弹幕一密就是这里在掉帧。 */
          if (st.laneFree.length !== numLanes) st.laneFree = new Array(numLanes).fill(-Infinity);
          let best = 0, bestFree = Infinity;
          for (let l = 0; l < numLanes; l++) {
            const freeAt = st.laneFree[l];
            if (t >= freeAt) { best = l; break; }
            if (freeAt < bestFree) { bestFree = freeAt; best = l; }
          }
          lane = best;
          st.laneFree[lane] = t + (width + fs) / speed;
        }
        st.active.push({ text: c.text, color, mode: c.mode, born: t, width, lane, speed });
      }

      // 渲染 + 清理过期
      ctx.textBaseline = "top";
      ctx.lineWidth = Math.max(2, fs / 12);
      ctx.strokeStyle = "rgba(0,0,0,0.75)";
      st.active = st.active.filter((a) => {
        let x: number, y: number;
        if (a.mode === 4) {
          x = (canvas.width - a.width) / 2;
          y = canvas.height - (a.lane + 1) * laneH;
          if (t - a.born > FIXED_DUR) return false;
        } else if (a.mode === 5) {
          x = (canvas.width - a.width) / 2;
          y = a.lane * laneH;
          if (t - a.born > FIXED_DUR) return false;
        } else {
          x = canvas.width - (t - a.born) * a.speed;
          y = a.lane * laneH;
          if (x + a.width < 0) return false;
        }
        ctx.strokeText(a.text, x, y);
        ctx.fillStyle = a.color;
        ctx.fillText(a.text, x, y);
        return true;
      });
    };

    raf = requestAnimationFrame(frame);
    return () => { cancelAnimationFrame(raf); ro.disconnect(); };
    // duration/fontSize 进依赖:改档位要立刻重建 frame 闭包,否则调了没反应。
  }, [comments, enabled, timeSync, duration, fontSize]);

  return <canvas ref={canvasRef} className="danmaku-canvas" />;
}
