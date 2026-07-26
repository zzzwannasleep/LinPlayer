import type { ReactNode } from "react";
import { IconChevronLeft } from "./icons";

/* 顶栏。**只放不常点的东西**:返回、标题、右侧一个动作。
   高频操作一律排在屏幕下 1/3(拇指可达区)—— 顶栏在单手握持时够不着,
   把主要动作放这儿是把桌面版式直接搬过来的典型错误。

   ★ 和底栏一样,不能被带 transform 的祖先包住(见 Tabs.tsx 的注释)。 */
export default function TopBar({
  title,
  sub,
  onBack,
  right,
}: {
  title: ReactNode;
  sub?: ReactNode;
  /** 给了就画返回箭头。栈底页(三个 Tab 的根)不给 —— 画一个按了没反应的箭头更糟 */
  onBack?: () => void;
  right?: ReactNode;
}) {
  return (
    <header className="topbar">
      {onBack ? (
        <button type="button" className="tb-back" onClick={onBack} aria-label="返回">
          <IconChevronLeft size={24} />
        </button>
      ) : (
        <span className="tb-gap" />
      )}
      <div className="tb-t">
        <div className="tb-title">{title}</div>
        {sub ? <div className="tb-sub">{sub}</div> : null}
      </div>
      <div className="tb-r">{right}</div>
    </header>
  );
}
