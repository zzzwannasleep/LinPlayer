import { useEffect, useRef, useState } from "react";
import {
  type Item,
  type ServerGroup,
  type SourceOverview,
  aggregateOverview,
  aggregateSearch,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { choreograph, haptic, pullRefresh, toast } from "../app/motion";
import Page from "../components/Page";
import { Card, Empty, usePress } from "../components/ui";

/* 聚合视界 —— 底栏第二个 Tab。
   ★ 2026-07-28 整页重做。上一版把所有源揉成一条混合流,被否了 ——
     用户要的是**分别列出来**:这台服的观看记录一节、那台服的观看记录一节。
     理由站得住:多源用户脑子里的模型就是"我有几台机器",
     揉成一条流反而把"这是哪来的"这个最重要的信息藏起来了。
   ★ 搜索**不弹任何提示**(用户原话:每敲一个字弹一个 toast 很恶心)。
     打字直接出结果,清空就回到分源视图。 */

/** key 必须是 Rust 侧 SourceKind 的字面值(全小写)。
 *  写错**不报错**,只是永远回落成 server 图标 —— 见 [[sourcekind-wire-is-lowercase]]。 */
const KIND_IC: Record<string, string> = {
  emby: "server", feiniu: "server", stremio: "plugin",
  aliyundrive: "cloud", quark: "cloud", baidu: "cloud", pan115: "cloud",
  pan189: "cloud", pan139: "cloud", openlist: "cloud", anirss: "rss",
};

/* 四个快捷入口。★ 这一行是首页那条 chip 行的去处 ——
   用户嫌 chip 行"难看没有用",但排行榜/追剧日历总要有入口,
   所以搬到这里做成有图标、有面积的方块,而不是一排灰药丸。 */
const QUICK = [
  { id: "resume", label: "继续观看", icon: "play" },
  { id: "favorites", label: "收藏", icon: "heart" },
  { id: "rankings", label: "排行榜", icon: "trophy" },
  { id: "calendar", label: "追剧日历", icon: "calendar" },
] as const;

const fmtNum = (n: number) => n.toLocaleString("en-US");

export default function AggregatePage() {
  const { session, go, openItem, play } = useCtx();
  const [srcs, setSrcs] = useState<SourceOverview[] | null>(null);
  const [q, setQ] = useState("");
  const [hits, setHits] = useState<ServerGroup[] | null>(null);
  const [busy, setBusy] = useState(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const bodyRef = useRef<HTMLElement>(null);

  const load = () => aggregateOverview().then(setSrcs).catch(() => setSrcs([]));
  useEffect(() => {
    load();
  }, []);

  /* 搜索:300ms 防抖后打真的聚合搜索。
     ★ `alive` 必须在 effect 作用域里声明,**不能**在 setTimeout 回调里 ——
       那样每次超时都是一个新的 alive,cleanup 改不到它,迟到的响应照样 set,
       快速改词时结果会闪回上一个词。这条三端都栽过。 */
  useEffect(() => {
    const s = q.trim();
    if (!s) {
      setHits(null);
      setBusy(false);
      return;
    }
    let alive = true;
    setBusy(true);
    const t = window.setTimeout(() => {
      aggregateSearch(s)
        .then((g) => alive && setHits(g))
        .catch(() => alive && setHits([]))
        .finally(() => alive && setBusy(false));
    }, 300);
    return () => {
      alive = false;
      window.clearTimeout(t);
    };
  }, [q]);

  useEffect(() => {
    const b = bodyRef.current?.querySelector<HTMLElement>(".pg-body");
    if (!b) return;
    return pullRefresh(b, async () => {
      await load();
      toast("全部源都刷过了", "ok");
    });
  }, []);

  useEffect(() => {
    choreograph(bodyRef.current?.querySelector<HTMLElement>(".pg-body") ?? null);
  }, [srcs, hits]);

  const clearBtn = usePress<HTMLButtonElement>();

  /** 有内容的源才铺一节。全零的源(网盘、或 /Items/Counts 不支持的 fork)
   *  仍然要能被看到 —— 藏起来会让人以为"我的网盘丢了"。所以放在最后单独一行。 */
  const live = (srcs ?? []).filter((s) => s.counts.movie + s.counts.episode > 0 || s.resume.length > 0);
  const quiet = (srcs ?? []).filter((s) => !live.includes(s));

  return (
    <span ref={bodyRef as React.Ref<HTMLSpanElement>} style={{ display: "contents" }}>
      <Page title="聚合视界" big enterKey={srcs}>
        <div className="agg">
          <div className="sf">
            <Icon n="search" size={19} />
            <input
              type="search"
              placeholder="搜片名 · 在全部源里找"
              value={q}
              ref={inputRef}
              enterKeyHint="search"
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
              <Icon n="close" size={17} />
            </button>
          </div>

          {/* 快捷入口。搜索时收起来 —— 搜结果的时候它只是噪音 */}
          {!q && (
            <div className="quick">
              {QUICK.map((x) => (
                <QuickBtn key={x.id} icon={x.icon} label={x.label} onClick={() => go(x.id)} />
              ))}
            </div>
          )}

          {q ? (
            <SearchResults q={q} busy={busy} hits={hits} session={session} onOpen={openItem} />
          ) : srcs === null ? (
            /* 加载中不画空态 —— 那会闪一下"没有源"再变出来 */
            <div className="pad dim" style={{ fontSize: 13 }}>
              正在问每一台源…
            </div>
          ) : !srcs.length ? (
            <Empty
              icon="server"
              title="一台源都还没有"
              desc="加一台 Emby 或网盘,这里会按源分开列出各自的观看记录。"
              action={{ label: "添加服务器", on: () => go("addServer") }}
            />
          ) : (
            <>
              {live.map((s) => (
                <section className="agg-src" key={s.server_id}>
                  <div className="src-hd">
                    <span className="src-ic">
                      <Icon n={KIND_IC[s.source_kind] || "server"} size={18} />
                    </span>
                    <div className="src-t">
                      <div className="src-n">{s.server_name}</div>
                      <div className="src-m">
                        {s.counts.movie + s.counts.episode > 0
                          ? `${fmtNum(s.counts.movie)} 电影 · ${fmtNum(s.counts.episode)} 集`
                          : "规模未知(这台服务器不支持 /Items/Counts)"}
                      </div>
                    </div>
                    <MoreBtn onClick={() => go({ page: "library", title: s.server_name })} />
                  </div>
                  {/* ★ 观看记录用 **16:9 集封面**(用户 2026-07-28 纠正)。
                      上一版为了"卡片统一"把这里改成海报,方向错了 ——
                      **集封面本来就只有横的**,形态是内容决定的,不是能靠"统一"抹平的。
                      全站就是两种卡:16:9 集封面(看到哪了)+ 2:3 海报(有什么)。 */}
                  {s.resume.length && session ? (
                    <div className="row-scroll">
                      {s.resume.map((it, i) => (
                        <Card
                          key={it.id}
                          item={it}
                          session={session}
                          variant="thumb"
                          index={i}
                          onOpen={(x) => void play(x)}
                        />
                      ))}
                    </div>
                  ) : (
                    <div className="src-empty">这个源还没有观看记录</div>
                  )}
                </section>
              ))}
              {quiet.length > 0 && (
                <section className="agg-src">
                  <div className="src-hd">
                    <span className="src-ic">
                      <Icon n="cloud" size={18} />
                    </span>
                    <div className="src-t">
                      <div className="src-n">另外 {quiet.length} 个源</div>
                      <div className="src-m">
                        {quiet.map((s) => s.server_name).join(" · ")} —— 文件浏览型,没有观看记录这个概念
                      </div>
                    </div>
                    <MoreBtn onClick={() => go("netdisk")} />
                  </div>
                </section>
              )}
            </>
          )}
          <div style={{ height: 16 }} />
        </div>
      </Page>
    </span>
  );
}

function QuickBtn({ icon, label, onClick }: { icon: string; label: string; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button
      type="button"
      className="quick-i"
      ref={ref}
      onClick={() => {
        haptic("tap");
        onClick();
      }}
    >
      <span className="quick-ic">
        <Icon n={icon} size={20} />
      </span>
      <span>{label}</span>
    </button>
  );
}

function MoreBtn({ onClick }: { onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button type="button" className="row-more" ref={ref} onClick={onClick}>
      进入
      <Icon n="chevR" size={15} />
    </button>
  );
}

function SearchResults({
  q,
  busy,
  hits,
  session,
  onOpen,
}: {
  q: string;
  busy: boolean;
  hits: ServerGroup[] | null;
  session: ReturnType<typeof useCtx>["session"];
  onOpen: (it: Item) => void;
}) {
  if (busy && !hits) return <div className="pad dim" style={{ fontSize: 13 }}>正在全部源里找…</div>;
  if (!hits || !session) return null;
  if (!hits.length) {
    return (
      <Empty
        icon="search"
        title={`没有找到「${q}」`}
        desc="每一台源都搜过了。检查有没有打错字,或者换个关键词 —— 有些片源用的是英文原名。"
      />
    );
  }
  /* 结果**仍然按源分组** —— 和这一页的主张一致:先告诉你"在哪儿"。
     ★ 跨服结果**不给长按菜单**:长按里的收藏/标已看是对**当前活跃服务器**写的,
       对着别的服的条目按下去会写到错误的地方,而且不报错。 */
  return (
    <>
      {hits.map((g) => (
        <div className="agg-sec" key={g.server_id}>
          <div className="row-hd">
            <h2>{g.server_name}</h2>
            <span className="dim" style={{ fontSize: 12.5 }}>
              {g.items.length} 条
            </span>
          </div>
          <div className="grid">
            {g.items.slice(0, 12).map((it, i) => (
              <Card key={it.id} item={it} session={session} index={i} onOpen={(x) => onOpen(x)} />
            ))}
          </div>
        </div>
      ))}
    </>
  );
}

/* ============================================================
   「继续观看」目的地页 —— 快捷入口那一行的第一个。
   ★ **也按源分节**。和聚合视界主页的区别:那边每个源只给最近几条;
     这边给每个源的**全部**观看记录。
   ★ 用横滑轨道不用换行网格:16:9 卡在两列网格里怎么排都会在右边剩一块
     (166×2 + 间距 ≠ 屏宽),而横滑轨道天生右边零留白 —— 最后一张被屏幕边缘切开,
     那本身就是"还能往右滑"的暗示。
   ============================================================ */
export function ResumePage() {
  const { session, back, play } = useCtx();
  const [srcs, setSrcs] = useState<SourceOverview[] | null>(null);
  useEffect(() => {
    aggregateOverview().then(setSrcs).catch(() => setSrcs([]));
  }, []);

  const live = (srcs ?? []).filter((s) => s.resume.length > 0);
  const total = live.reduce((a, s) => a + s.resume.length, 0);

  return (
    <Page title="继续观看" sub={srcs ? `${live.length} 个源` : undefined} onBack={back} enterKey={srcs}>
      {srcs === null ? (
        <div className="pad dim" style={{ fontSize: 13 }}>
          正在问每一台源…
        </div>
      ) : !live.length ? (
        <Empty icon="play" title="还没有观看记录" desc="看过的东西会自动出现在这里,每个源分开记。" />
      ) : (
        <>
          <div className="pad" style={{ padding: "10px var(--pad) 0" }}>
            <span className="dim" style={{ fontSize: 13 }}>
              {total} 条 · 来自 {live.length} 个源
            </span>
          </div>
          {live.map((s) => (
            <section className="agg-src" key={s.server_id}>
              <div className="src-hd">
                <span className="src-ic">
                  <Icon n={KIND_IC[s.source_kind] || "server"} size={18} />
                </span>
                <div className="src-t">
                  <div className="src-n">{s.server_name}</div>
                  <div className="src-m">{s.resume.length} 条观看记录</div>
                </div>
              </div>
              {session && (
                <div className="row-scroll">
                  {s.resume.map((it, i) => (
                    <Card
                      key={it.id}
                      item={it}
                      session={session}
                      variant="thumb"
                      index={i}
                      onOpen={(x) => void play(x)}
                    />
                  ))}
                </div>
              )}
            </section>
          ))}
          <div style={{ height: 16 }} />
        </>
      )}
    </Page>
  );
}
