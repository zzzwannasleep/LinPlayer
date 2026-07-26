import { useEffect, useRef, useState } from "react";
import { type Item, type LoginResult, type ServerGroup, aggregateSearch } from "@shared/api";
import Card from "../components/Card";
import { IconClose, IconSearch } from "../app/icons";

/* 搜索(底栏第二个 Tab)。

   ★ 为什么值得占一个 Tab:手机上没有 PC 的 Ctrl+K 浮层,也没有 TV 的语音键。
     搜索是手机上进入内容最短的一条路 —— 藏进顶栏图标就是每次多一次点击,
     而这正是 Emby 官方安卓端被吐槽最多的那类问题。

   ★ 用 aggregateSearch(全服聚合)而不是 search(当前服):
     用户装了几台服务器就不该被迫先想"这部片在哪台上"。核层已经做了聚合,
     前端不用它才是浪费。跨服结果**不给长按菜单** —— 长按里的收藏/标记已看
     是对"当前活跃服务器"写的,对着别的服务器的条目按下去会写错地方。 */

const DEBOUNCE_MS = 300;

export default function SearchPage({
  session,
  onOpen,
}: {
  session: LoginResult;
  onOpen: (it: Item) => void;
}) {
  const [q, setQ] = useState("");
  const [groups, setGroups] = useState<ServerGroup[]>([]);
  const [busy, setBusy] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);

  useEffect(() => {
    const s = q.trim();
    if (!s) {
      setGroups([]);
      setBusy(false);
      return;
    }
    setBusy(true);
    /* 防抖 300ms。没有它的话每敲一个字母都打一次全服聚合搜索 ——
       手机上输入法联想还会一次性吐进来好几个字符,那就是几次并发往返。

       ★ alive 必须声明在 effect 作用域,不能声明在 setTimeout 回调里:
         那样每次超时都是一个新的 alive,cleanup 根本改不到它,
         迟到的响应照样 set —— 表现是快速改词时结果闪回上一个词的。 */
    let alive = true;
    const t = window.setTimeout(() => {
      aggregateSearch(s)
        .then((g) => alive && setGroups(g))
        .catch(() => alive && setGroups([]))
        .finally(() => alive && setBusy(false));
    }, DEBOUNCE_MS);
    return () => {
      alive = false;
      window.clearTimeout(t);
    };
  }, [q]);

  const total = groups.reduce((n, g) => n + g.items.length, 0);

  return (
    <div className="search">
      {/* 输入框固定在顶部:手机键盘会顶起下半屏,输入框跟着内容滚走的话
          用户就看不见自己打了什么。 */}
      <div className="sf">
        <IconSearch size={18} />
        <input
          ref={inputRef}
          value={q}
          onChange={(e) => setQ(e.target.value)}
          placeholder="搜索全部服务器"
          /* enterKeyHint=search 让安卓输入法的回车键显示成放大镜而不是换行。
             一个属性的事,但少了它用户会觉得"这个框怪怪的"。 */
          enterKeyHint="search"
          autoComplete="off"
          autoCorrect="off"
          spellCheck={false}
        />
        {q && (
          <button type="button" className="sf-x" onClick={() => setQ("")} aria-label="清空">
            <IconClose size={18} />
          </button>
        )}
      </div>

      {!q.trim() ? (
        <div className="empty">
          <div className="dim">输入片名、剧名或演员</div>
        </div>
      ) : busy && !total ? (
        <div className="empty">
          <div className="dim">搜索中…</div>
        </div>
      ) : !total ? (
        <div className="empty">
          <div className="dim">没有找到「{q.trim()}」</div>
        </div>
      ) : (
        groups
          .filter((g) => g.items.length > 0)
          .map((g) => (
            <section key={g.server_id} className="sgrp">
              {/* 服务器名必须显示:同一部片可能几台都有,不标出来用户不知道点的是哪个 */}
              <h2>
                {g.server_name}
                <span className="dim"> · {g.items.length}</span>
              </h2>
              <div className="grid">
                {g.items.map((it, i) => (
                  <Card key={`${g.server_id}:${it.id}`} item={it} session={session} index={i} onOpen={onOpen} />
                ))}
              </div>
            </section>
          ))
      )}
    </div>
  );
}
