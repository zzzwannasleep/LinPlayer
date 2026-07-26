import { TABS, type TabId } from "./nav";

/* 底栏。三个 Tab,理由见 nav.ts。

   ★ 这个元素**不能**放进任何带 transform / will-change 动画的祖先里。
     transform 会给后代 position:fixed 建包含块,fixed 就不再以视口为参照 ——
     表现是底栏跟着页面转场一起滑走、或者停在屏幕中间。
     PC 端的右键菜单偏位、TV 端播放页底栏跑到屏幕上方 200px,都是这一条。
     所以 App.tsx 里底栏是**页面容器的兄弟**,不是它的后代。 */
export default function Tabs({
  tab,
  onTab,
}: {
  tab: TabId;
  onTab: (t: TabId) => void;
}) {
  return (
    <nav className="tabs" role="tablist">
      {TABS.map((t) => {
        const on = t.id === tab;
        const Icon = t.icon;
        return (
          <button
            key={t.id}
            type="button"
            role="tab"
            aria-selected={on}
            className={`tab${on ? " on" : ""}`}
            onClick={() => onTab(t.id)}
          >
            <Icon size={22} />
            <span>{t.label}</span>
          </button>
        );
      })}
    </nav>
  );
}
