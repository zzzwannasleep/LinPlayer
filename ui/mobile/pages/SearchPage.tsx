import { useEffect, useRef, useState } from "react";
import { type ServerGroup, aggregateSearch } from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { choreograph, haptic } from "../app/motion";
import Page from "../components/Page";
import { Card, Empty, usePress } from "../components/ui";

/* 搜索。
   ★ 底栏那三个 Tab 里**没有它**了 —— 搜索条并进了「聚合视界」顶部
     (跨源找东西和跨源看有什么是同一件事的两面)。这一页留着是给
     "从别处点进搜索"用的,版式和聚合视界里的搜索一致。

   ★ 用 aggregateSearch(全服聚合)而不是 search(当前服):
     用户装了几台服务器就不该被迫先想"这部片在哪台上"。
     跨服结果**不给长按菜单** —— 长按里的收藏/标记已看是对"当前活跃服务器"写的,
     对着别的服务器的条目按下去会写错地方,而且不报错。

   ★ 「大家在搜」那一块**没有做**:核层没有热搜数据源,编一份写死的关键词
     就是假 UI —— 假 UI 在评审时会被当成"已经做好了",那比空白更贵。
     「最近搜索」是真的(存在本机 localStorage)。 */

const DEBOUNCE_MS = 300;
const RECENT_KEY = "lp.mobile.recentSearch";
const RECENT_MAX = 8;

const readRecent = (): string[] => {
  try {
    const v = JSON.parse(localStorage.getItem(RECENT_KEY) || "[]");
    return Array.isArray(v) ? v.filter((x) => typeof x === "string") : [];
  } catch {
    return [];
  }
};

export default function SearchPage() {
  const { session, back, openItem } = useCtx();
  const [q, setQ] = useState("");
  const [groups, setGroups] = useState<ServerGroup[] | null>(null);
  const [busy, setBusy] = useState(false);
  const [recent, setRecent] = useState<string[]>(readRecent);
  const inputRef = useRef<HTMLInputElement>(null);
  const bodyRef = useRef<HTMLDivElement>(null);

  /* ★ `alive` 必须在 effect 作用域里声明,**不能**在 setTimeout 回调里 ——
     那样每次超时都是一个新的 alive,cleanup 改不到它,迟到的响应照样 set,
     快速改词时结果会闪回上一个词。三端都栽过。 */
  useEffect(() => {
    const s = q.trim();
    if (!s) {
      setGroups(null);
      setBusy(false);
      return;
    }
    let alive = true;
    setBusy(true);
    const t = window.setTimeout(() => {
      aggregateSearch(s)
        .then((g) => {
          if (!alive) return;
          setGroups(g);
          if (g.length) {
            const next = [s, ...recent.filter((x) => x !== s)].slice(0, RECENT_MAX);
            setRecent(next);
            try {
              localStorage.setItem(RECENT_KEY, JSON.stringify(next));
            } catch {
              /* 隐私模式下 localStorage 会抛。搜索本身不该因此失败。 */
            }
          }
        })
        .catch(() => alive && setGroups([]))
        .finally(() => alive && setBusy(false));
    }, DEBOUNCE_MS);
    return () => {
      alive = false;
      window.clearTimeout(t);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [q]);

  useEffect(() => {
    choreograph(bodyRef.current);
  }, [groups]);

  const clearBtn = usePress<HTMLButtonElement>();

  return (
    <Page title="搜索" onBack={back}>
      <div className="sf">
        <Icon n="search" size={18} />
        <input
          type="search"
          placeholder="搜索标题、演员、导演…"
          enterKeyHint="search"
          value={q}
          ref={inputRef}
          autoFocus
          onChange={(e) => setQ(e.target.value)}
        />
        <button
          type="button"
          className="sf-x"
          aria-label="清空"
          ref={clearBtn}
          style={{ visibility: q ? "visible" : "hidden" }}
          onClick={() => {
            setQ("");
            inputRef.current?.focus();
          }}
        >
          <Icon n="close" size={15} />
        </button>
      </div>

      <div ref={bodyRef}>
        {!q ? (
          recent.length ? (
            <div className="sgroup">
              <h2>最近搜索</h2>
              <div className="chips">
                {recent.map((r) => (
                  <button
                    key={r}
                    type="button"
                    className="chip"
                    onClick={() => {
                      haptic("tap");
                      setQ(r);
                    }}
                  >
                    {r}
                  </button>
                ))}
                <button
                  type="button"
                  className="chip"
                  onClick={() => {
                    setRecent([]);
                    try {
                      localStorage.removeItem(RECENT_KEY);
                    } catch {
                      /* 同上 */
                    }
                  }}
                >
                  <Icon n="trash" size={14} />
                  清空
                </button>
              </div>
            </div>
          ) : (
            <Empty icon="search" title="搜点什么" desc="一次搜全部已登录的源,结果按源分开列。" />
          )
        ) : busy && !groups ? (
          /* 骨架而不是"搜索中…"三个字 —— 骨架能让人预判结果长什么样 */
          <div className="grid">
            {Array.from({ length: 6 }, (_, i) => (
              <div className="card" key={i}>
                <div className="card-a ar-poster">
                  <div className="skel" />
                </div>
                <div className="skel-line" style={{ marginTop: 8, width: "78%" }} />
              </div>
            ))}
          </div>
        ) : !groups?.length ? (
          <Empty
            icon="search"
            title={`没有找到「${q}」`}
            desc="每一台源都搜过了。检查有没有打错字,或者换个关键词 —— 有些片源用的是英文原名。"
          />
        ) : (
          groups.map((g) => (
            <div className="sgroup" key={g.server_id}>
              <div className="row-hd">
                <h2>{g.server_name}</h2>
                <span className="dim" style={{ fontSize: 12.5 }}>
                  {g.items.length} 条
                </span>
              </div>
              <div className="grid">
                {session &&
                  g.items.map((it, i) => (
                    <Card key={it.id} item={it} session={session} index={i} onOpen={(x) => openItem(x)} />
                  ))}
              </div>
            </div>
          ))
        )}
      </div>
    </Page>
  );
}
