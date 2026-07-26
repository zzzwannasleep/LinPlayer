import { useEffect, useState, type ReactElement } from "react";
import { type AccountInfo, cacheSize, clearCache, fmtSize, listAccounts } from "@shared/api";
import type { PageId } from "../app/nav";
import {
  IconChevronRight,
  IconCloud,
  IconInfo,
  IconPlugin,
  IconServer,
  IconTrash,
} from "../app/icons";

/* 设置(底栏第三个 Tab)。

   ★ 它同时是手机端的「我的」:PC 侧栏底部的服务器/插件,以及网盘、Ani-RSS
     这些"配置类"入口全收在这里。底栏只有三个位置(见 app/nav.ts 的取舍),
     而这些页面的共同点是**进去一次配好就很少再来** —— 正适合收进二级。

   ★ 每一项都是整行可点(≥56dp),不是"一行文字 + 右边一个小箭头按钮"。
     手机上让用户去点一个 24px 的箭头是设计事故。 */

type Cell = { id: PageId; label: string; icon: () => ReactElement; sub?: string };
type Group = { title: string; items: Cell[] };

export default function SettingsPage({ onGo }: { onGo: (p: PageId) => void }) {
  const [accounts, setAccounts] = useState<AccountInfo[]>([]);
  const [cache, setCache] = useState<number | null>(null);
  const [clearing, setClearing] = useState(false);

  useEffect(() => {
    listAccounts().then(setAccounts).catch(() => {});
    cacheSize().then(setCache).catch(() => {});
  }, []);

  const groups: Group[] = [
    {
      title: "源",
      items: [
        {
          id: "servers",
          label: "服务器",
          icon: () => <IconServer size={20} />,
          sub: accounts.length ? `${accounts.length} 台` : undefined,
        },
        { id: "netdisk", label: "网盘", icon: () => <IconCloud size={20} /> },
        { id: "anirss", label: "Ani-RSS 订阅", icon: () => <IconInfo size={20} /> },
      ],
    },
    {
      title: "扩展",
      items: [{ id: "plugins", label: "插件", icon: () => <IconPlugin size={20} /> }],
    },
  ];

  return (
    <div className="settings">
      {groups.map((g) => (
        <section key={g.title} className="sgroup">
          <h2>{g.title}</h2>
          <div className="cells">
            {g.items.map((it) => (
              <button key={it.id} type="button" className="cell" onClick={() => onGo(it.id)}>
                <span className="cell-i">{it.icon()}</span>
                <span className="cell-l">{it.label}</span>
                {it.sub && <span className="cell-s">{it.sub}</span>}
                <IconChevronRight size={18} />
              </button>
            ))}
          </div>
        </section>
      ))}

      <section className="sgroup">
        <h2>存储</h2>
        <div className="cells">
          <button
            type="button"
            className="cell"
            disabled={clearing}
            onClick={() => {
              setClearing(true);
              /* 清完立刻重新量一次 —— 显示"0 B"是这个操作唯一的反馈。
                 不重量的话按钮按下去界面纹丝不动,用户会以为没生效然后再按几次。 */
              clearCache()
                .then(() => cacheSize())
                .then(setCache)
                .catch(() => {})
                .finally(() => setClearing(false));
            }}
          >
            <span className="cell-i">
              <IconTrash size={20} />
            </span>
            <span className="cell-l">清除缓存</span>
            <span className="cell-s">
              {clearing ? "清理中…" : cache == null ? "" : fmtSize(cache) || "0 B"}
            </span>
          </button>
        </div>
      </section>

      <div className="ver">LinPlayer {__APP_VERSION__}</div>
    </div>
  );
}
