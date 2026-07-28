import { TABS, type TabId } from "./nav";
import { Icon } from "./icons";
import { haptic } from "./motion";

/* 底栏 —— 悬浮液态玻璃胶囊。
 *
 * ★ 它是 `.stacks` 的**兄弟**,绝不能塞进页面容器里:页面栈那一层带 transform 动画,
 *   而 transform 会给后代的 `position:fixed`/`absolute` 定位建包含块 ——
 *   底栏会跟着页面一起滑走。PC 端右键菜单偏位、TV 端底栏跑到屏幕上方 200px,
 *   都是栽在这一条。
 *
 * ★ 版式(用户 2026-07-28 定):左右 6px、底 7px + 安全区,圆角 20px。
 *   两个极端都试过 —— 悬浮孤岛(左右 18 / 底 14)"漏风",完全贴底又太硬。
 *
 * ★ 选中态换的是**实心图标**(home → homeOn),不是只变个颜色。
 *   小尺寸下颜色差别在强光下看不出来,形状差别看得出来。 */

export default function Tabs({ tab, onTab }: { tab: TabId; onTab: (t: TabId) => void }) {
  return (
    <nav className="tabs" role="tablist">
      <div className="tabs-inner">
        {TABS.map((t) => {
          const on = t.id === tab;
          return (
            <button
              key={t.id}
              type="button"
              role="tab"
              aria-selected={on}
              className={`tab${on ? " on" : ""}`}
              data-tab={t.id}
              onClick={() => {
                haptic("tap");
                onTab(t.id);
              }}
            >
              <span className="tab-ic">
                <Icon n={on ? t.iconOn : t.icon} size={23} />
              </span>
              <span>{t.label}</span>
            </button>
          );
        })}
      </div>
    </nav>
  );
}
