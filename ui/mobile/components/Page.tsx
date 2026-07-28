import { useEffect, useRef, type ReactNode } from "react";
import { Icon } from "../app/icons";
import { choreograph, topbarOnScroll } from "../app/motion";

/* 页面骨架 —— 草稿 `ui.js` 里 `page()` 的 React 版。
   每一页都是 topbar + 可滚动 body。

   ## 顶栏是**每页自己的**,不是 App 顶层挂一条
   上一版是 App.tsx 画一条全局 TopBar,页面只提供标题字符串。那样做不到三件事:
     1. **随滚动实体化** —— 顶栏要读它自己那一页的 scrollTop
     2. 右上角的动作按钮各页不同(首页是设置+线路,服务器页是添加,列表页是筛选)
     3. 转场时顶栏要跟着页面一起滑 —— 全局那条是不动的,新旧页标题会"闪切"
   所以顶栏并进页面里。底栏仍然是全局的(三个 Tab 不随页面变)。

   ## 顶栏一上来不画分隔线
   滚动超过 12px 才加 `.solid`。一上来就画一条线 = 首屏被无谓地切了一刀。 */

type Props = {
  title?: ReactNode;
  sub?: ReactNode;
  /** 给了就画返回箭头。栈底页(三个 Tab 的根)不给 —— 画一个按了没反应的箭头更糟 */
  onBack?: () => void;
  /** 右上角的动作按钮 */
  right?: ReactNode;
  /** 大标题(Tab 根页用) */
  big?: boolean;
  /** 不画顶栏(播放页 / 沉浸式详情页自己管整块屏) */
  noBar?: boolean;
  /** 首屏进场编排:卡片 stagger + 图片淡入。列表类页面在数据到位后才该跑,
   *  所以把"数据版本"传进来当依赖 —— 传 undefined 就只在挂载时跑一次。 */
  enterKey?: unknown;
  children: ReactNode;
};

export default function Page({ title, sub, onBack, right, big, noBar, enterKey, children }: Props) {
  const bodyRef = useRef<HTMLDivElement>(null);
  const barRef = useRef<HTMLElement>(null);

  useEffect(() => {
    const b = bodyRef.current;
    const bar = barRef.current;
    if (!b || !bar) return;
    return topbarOnScroll(b, bar);
  }, []);

  /* 进场编排。★ 只给首屏 12 项,屏幕外的交给 IntersectionObserver ——
     全都加 = 一进页面几十个动画同时排队,那就是"卡了一下"。 */
  useEffect(() => {
    choreograph(bodyRef.current);
  }, [enterKey]);

  return (
    <>
      {!noBar && (
        <header className="topbar" ref={barRef}>
          {onBack ? (
            <button type="button" className="tb-back" onClick={onBack} aria-label="返回">
              <Icon n="back" size={24} />
            </button>
          ) : null}
          <div className="tb-t">
            <div className={`tb-title${big ? " big" : ""}`}>{title}</div>
            {sub ? <div className="tb-sub">{sub}</div> : null}
          </div>
          <div className="tb-r">{right}</div>
        </header>
      )}
      <div className="pg-body" ref={bodyRef}>
        {children}
      </div>
    </>
  );
}

/** 顶栏右上角的图标按钮。全站统一 —— 各页各写一个必然长出两套尺寸。 */
export function BarButton({
  icon,
  label,
  onClick,
}: {
  icon: string;
  label: string;
  onClick: () => void;
}) {
  return (
    <button type="button" aria-label={label} onClick={onClick}>
      <Icon n={icon} size={21} />
    </button>
  );
}
