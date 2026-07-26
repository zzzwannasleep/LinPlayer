import { useRef, useState, type ReactNode } from "react";

/* 下拉刷新。

   ★ 为什么自己写而不是靠浏览器:安卓 WebView 的原生下拉刷新只在**页面级**存在,
     而我们的滚动容器是 `.page`(为了给底栏让高度),浏览器那套根本不触发。
     body 上还关掉了 overscroll(见 mobile.css),否则整页会橡皮筋。

   ★ 阻尼 0.5:手指走 128px,指示器才走 64px。1:1 跟手会让人一不小心拉出半屏,
     而完全不动又像卡住。阻尼是"能拉动但要费点力"的那个感觉。

   ★ 只在**滚动位置为 0** 时才认下拉。不判这个的话,用户在列表中间往下滑会触发刷新。 */

const THRESHOLD = 64;
const DAMP = 0.5;

export default function PullRefresh({
  onRefresh,
  children,
}: {
  onRefresh: () => Promise<unknown>;
  children: ReactNode;
}) {
  const [pull, setPull] = useState(0);
  const [busy, setBusy] = useState(false);
  const startY = useRef<number | null>(null);
  const fired = useRef(false);

  const scroller = (el: HTMLElement | null) => el?.closest(".page") as HTMLElement | null;

  return (
    <div
      className="pr"
      onPointerDown={(e) => {
        if (busy) return;
        const sc = scroller(e.currentTarget);
        // 只有滚到顶了才是"下拉刷新",否则这是普通滚动
        if (sc && sc.scrollTop > 0) return;
        startY.current = e.clientY;
        fired.current = false;
      }}
      onPointerMove={(e) => {
        if (startY.current == null || busy) return;
        const dy = (e.clientY - startY.current) * DAMP;
        if (dy <= 0) {
          setPull(0);
          return;
        }
        setPull(dy);
        if (dy > THRESHOLD && !fired.current) {
          fired.current = true;
          navigator.vibrate?.(10); // 过阈值给一下触觉,用户不用盯着指示器看
        }
      }}
      onPointerUp={() => {
        const hit = pull > THRESHOLD;
        startY.current = null;
        if (!hit) return setPull(0);
        setBusy(true);
        setPull(THRESHOLD);
        onRefresh()
          .catch(() => {})
          .finally(() => {
            setBusy(false);
            setPull(0);
          });
      }}
      onPointerCancel={() => {
        startY.current = null;
        setPull(0);
      }}
    >
      <div
        className="pr-ind"
        style={{
          /* 只动 transform 和 opacity。用 height 做这个动画会每帧重排整页。 */
          transform: `translateY(${pull}px)`,
          opacity: Math.min(1, pull / THRESHOLD),
        }}
      >
        <i className={busy ? "spinner" : pull > THRESHOLD ? "ready" : ""} />
      </div>
      <div
        className="pr-body"
        style={{ transform: `translateY(${pull}px)`, transition: startY.current == null ? "transform 260ms cubic-bezier(.32,.72,0,1)" : "none" }}
      >
        {children}
      </div>
    </div>
  );
}
