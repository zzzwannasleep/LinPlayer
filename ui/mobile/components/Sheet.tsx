import { useEffect, useRef, useState, type ReactNode } from "react";
import { pushBackHandler } from "../app/backkey";

/* Bottom sheet —— 手机端替代 PC 下拉面板/右键菜单的通用容器。

   ## 为什么不是"居中弹窗"
   居中弹窗的关闭按钮在屏幕上半部,单手握持时拇指够不着。从底部升起的面板,
   内容和关闭手势都落在拇指区里。这是 iOS/Android 两家近十年的收敛结果,不是审美选择。

   ## 三档位
   peek(内容高度) / half(50%) / full(90%)。给了 `snap` 才三档,不给就只有一档(内容高)。
   松手时按**速度优先、位置其次**判档:快速下甩直接关,慢慢拖则就近吸附。
   只看位置的话,用户"快速甩一下"会因为位移不够而弹回去 —— 那是最挫败的一种手感。

   ## 硬约束
   - 只动 `transform`,不动 `height`/`top`(那两个每帧重排)
   - 拖拽期间关掉 transition,否则跟手会有一帧延迟(看起来像"粘")
   - **返回键必须由它吃掉**:不注册 pushBackHandler 的话,面板开着按返回是
     面板没关、整个页面先退了 —— 用户只想关掉筛选面板,结果回到了上一页
   - 内容区滚到顶之后再下拉才拖 sheet,否则列表滚不动 */

type Props = {
  open: boolean;
  onClose: () => void;
  title?: ReactNode;
  children: ReactNode;
  /** 多档位。不给 = 只有内容高度一档 */
  snap?: boolean;
};

/** 松手速度超过这个就按方向直接跨档(px/ms)。0.8 ≈ 一次利落的甩动。 */
const FLING = 0.8;

export default function Sheet({ open, onClose, title, children, snap }: Props) {
  const [dragY, setDragY] = useState(0);
  const [dragging, setDragging] = useState(false);
  const [tall, setTall] = useState(false); // snap 模式下:是否已经拉到 full
  const bodyRef = useRef<HTMLDivElement>(null);
  const start = useRef<{ y: number; t: number } | null>(null);
  const last = useRef<{ y: number; t: number } | null>(null);

  /* 返回键。★ 注册的是「我吃掉」——返回 true,App.tsx 那边就不会去弹路由栈。 */
  useEffect(() => {
    if (!open) return;
    return pushBackHandler(() => {
      onClose();
      return true;
    });
  }, [open, onClose]);

  /* 打开时锁住背景滚动。不锁的话手指在 sheet 上滑到尽头会带着底下的页面一起滚
     ——「滚穿」是移动端 modal 的经典毛病。 */
  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, [open]);

  useEffect(() => {
    if (open) {
      setDragY(0);
      setTall(false);
    }
  }, [open]);

  if (!open) return null;

  const onDown = (e: React.PointerEvent) => {
    start.current = { y: e.clientY, t: e.timeStamp };
    last.current = start.current;
    setDragging(true);
    (e.target as HTMLElement).setPointerCapture?.(e.pointerId);
  };

  const onMove = (e: React.PointerEvent) => {
    if (!start.current) return;
    const dy = e.clientY - start.current.y;
    last.current = { y: e.clientY, t: e.timeStamp };
    /* 往上拖:snap 模式下允许(去 full 档),否则加阻尼让它"拉不动"——
       给阻力而不是硬停,用户才知道"这里到头了"而不是"卡住了"。 */
    setDragY(dy < 0 ? (snap && !tall ? dy : dy * 0.25) : dy);
  };

  const onUp = () => {
    if (!start.current || !last.current) return;
    const dy = last.current.y - start.current.y;
    const dt = Math.max(1, last.current.t - start.current.t);
    const v = dy / dt; // px/ms,正数 = 往下

    setDragging(false);
    start.current = null;

    // 速度优先:快速下甩直接关,不看拖了多远
    if (v > FLING) return onClose();
    if (snap && v < -FLING) {
      setTall(true);
      setDragY(0);
      return;
    }
    // 位置其次
    const h = bodyRef.current?.offsetHeight ?? 400;
    if (dy > h * 0.35) return onClose();
    if (snap && dy < -60) setTall(true);
    setDragY(0);
  };

  return (
    <>
      <div className="scrim" onClick={onClose} />
      <div
        className={`sheet${tall ? " tall" : ""}${dragging ? " dragging" : ""}`}
        style={{ transform: `translateY(${Math.max(0, dragY)}px)` }}
        role="dialog"
        aria-modal="true"
      >
        {/* 抓手 + 标题整条都能拖 —— 只有一个 32px 的小横条可拖的话很难抓中 */}
        <div className="sheet-grip" onPointerDown={onDown} onPointerMove={onMove} onPointerUp={onUp} onPointerCancel={onUp}>
          <i />
          {title && <div className="sheet-title">{title}</div>}
        </div>
        <div className="sheet-body" ref={bodyRef}>
          {children}
        </div>
      </div>
    </>
  );
}
