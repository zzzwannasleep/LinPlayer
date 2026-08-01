import { useEffect, useRef, useState } from "react";
import {
  type Item,
  type SourceOverview,
  aggregateOverview,
  backdropUrl,
  listLatest,
  listNextUp,
  listResume,
  listRandom,
  logoUrl,
  views,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { autoHideBars, choreograph, haptic, imgsIn, pullRefresh, toast } from "../app/motion";
import { Empty, Row, usePress } from "../components/ui";

/* 首页。
   ★ 这一页的动效有四层,少一层就回到"平的":
     1. Hero:两层图 crossfade 换图 + 文字逐条重新落位 + 环境光跟着换
     2. 首屏 12 张卡 stagger 进场,屏幕外的滚到了才进
     3. 顶栏随滚动实体化(不是一上来就画一条线把首屏切一刀)
     4. 点卡片 → 封面**飞**到详情页 Hero(FLIP 共享元素)

   ★ 加载结构才是"秒不秒开"的关键,不是动画。
     PC 端 2026-07-15 栽过:五个请求 Promise.all + 媒体库串行 await 是**秒级**的,
     而当时去砍入场动画(668ms)只是零头。这里的结构是:
     每块数据各自到、各自渲染,谁先回谁先画。

   ★ chip 行整条去掉(用户 2026-07-28:"很难看没有用")。
     媒体库/收藏/排行榜/追剧日历那几个入口搬去了**聚合视界顶部的四个方块**
     (见 AggregatePage 的 QUICK)—— 有图标、有面积,不是一排灰药丸。 */

const HERO_N = 5;
/** 5 秒一换。★ 不是 3 秒:手机屏幕小,一张大图上要读片名 + 元信息,
 *  3 秒会让人有"还没看完就翻页了"的焦躁。 */
const HERO_MS = 5000;

/* 环境光的调色板。★ 真机上本该由核层从封面取主色,那是另一件事(要解码图片);
   在那之前用**条目 id 的哈希**选一档 —— 确定性的:同一部片每次进来都是同一个颜色,
   不会"每次刷新页面颜色都在变"。 */
const PALETTES = [
  ["#1b2a4a", "#7c3f58", "#e8b06a"], ["#0f2027", "#2c5364", "#7ad1c5"],
  ["#2b1055", "#7597de", "#f3c1c6"], ["#3a1c2b", "#a33d54", "#ffd479"],
  ["#101820", "#31473a", "#a8c686"], ["#241b2f", "#5c4b8a", "#e0c3fc"],
  ["#1a1a2e", "#16213e", "#e94560"], ["#2d132c", "#801336", "#ee4540"],
  ["#12232e", "#007cc7", "#eefbfb"], ["#1e130c", "#9a8478", "#f5e6ca"],
  ["#0b3866", "#1e6091", "#99d98c"], ["#3d0c11", "#8c1c13", "#f0a202"],
];
function hash(s: string) {
  let h = 2166136261;
  for (let i = 0; i < s.length; i++) {
    h ^= s.charCodeAt(i);
    h = Math.imul(h, 16777619);
  }
  return Math.abs(h);
}
function ambientOf(id: string) {
  const p = PALETTES[hash(id) % PALETTES.length];
  return `radial-gradient(120% 52% at 50% -6%, ${p[2]}38 0%, ${p[1]}22 34%, transparent 68%)`;
}

const fmtNum = (n: number) => n.toLocaleString("en-US");

export default function HomePage() {
  const { session, go, openItem, play } = useCtx();
  const [libs, setLibs] = useState<Item[]>([]);
  const [byLib, setByLib] = useState<Record<string, Item[]>>({});
  /** 「继续观看」和「接下来看」合并成一条(用户 2026-07-28 定)。
   *  合并的逻辑站得住:两者都是"该接着看的东西",区别只是"看了一半"还是"还没开始",
   *  而那个区别卡片上的**进度条**已经说清楚了 —— 有进度条 = 看了一半。 */
  const [keepWatching, setKeepWatching] = useState<Item[]>([]);
  const [hero, setHero] = useState<Item[]>([]);
  const [heroIdx, setHeroIdx] = useState(0);
  const [overview, setOverview] = useState<SourceOverview[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  const bodyRef = useRef<HTMLDivElement>(null);
  const barRef = useRef<HTMLElement>(null);
  const heroRef = useRef<HTMLDivElement>(null);

  const load = (): Promise<void> => {
    if (!session) return Promise.resolve();
    /* ★ 各块各自 .then 里 set,**不加 Promise.all 屏障**。谁先回谁先画。 */
    views()
      .then((vs) => {
        setLibs(vs);
        // 有库名了骨架就能撤 —— 不必等内容,轨道标题先立住,卡片陆续填进来
        setLoading(false);
        vs.forEach((v) =>
          listLatest(v.id, 20)
            .then((items) => setByLib((m) => ({ ...m, [v.id]: items })))
            .catch(() => {}),
        );
      })
      .catch((e) => {
        // views 是首页的地基,它挂了才算真错误(其余源挂了都静默)
        setErr(String(e));
        setLoading(false);
      });

    listRandom(HERO_N).then(setHero).catch(() => {});
    Promise.allSettled([listResume(12), listNextUp(20)]).then(([r, n]) => {
      const a = r.status === "fulfilled" ? r.value : [];
      const b = n.status === "fulfilled" ? n.value : [];
      // 同一集可能既在"继续观看"又在"接下来看",去重后按原顺序拼
      const seen = new Set(a.map((x) => x.id));
      setKeepWatching([...a, ...b.filter((x) => !seen.has(x.id))]);
    });
    aggregateOverview().then(setOverview).catch(() => {});
    return Promise.resolve();
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session?.server]);

  /* Hero 轮播。★ 页面被弹出栈之后要停掉 —— 这里靠 effect 的 cleanup,
     草稿里那种"检查节点还在不在"的写法在 React 下不需要。
     ★ `heroHold` 一变就重开计时:用户刚手动拨过,应该从**这一刻**起重新数 5 秒,
       而不是接着上一轮的余数 —— 否则拨完可能过半秒就自动翻页了。 */
  const [heroHold, setHeroHold] = useState(0);
  useEffect(() => {
    if (hero.length < 2) return;
    const t = window.setInterval(() => setHeroIdx((i) => (i + 1) % hero.length), HERO_MS);
    return () => window.clearInterval(t);
  }, [hero.length, heroHold]);

  /* Hero 左右滑动换片(用户 2026-08-01:「随机推荐封面无法滑动」)。
     ★ 只能用 pointer 事件自己算,不能靠 CSS scroll-snap —— 五张图是**叠着 crossfade**
       的(见 .hero-layer),它们没有横向排布,压根没有可滚的内容。
     ★ 判据是「横向位移 > 纵向 且 > 40px」:不加纵向比较的话,用户想上下滚页面时
       手指的斜向抖动会被吃成翻页;不加 40px 下限的话,点一下也会算成滑。
     ★ 滑动之后必须**吃掉那一次 click** —— 否则松手的同时进了详情页。 */
  const heroDrag = useRef<{ x: number; y: number; moved: boolean } | null>(null);
  const heroPan = {
    onPointerDown: (e: React.PointerEvent) => {
      heroDrag.current = { x: e.clientX, y: e.clientY, moved: false };
    },
    onPointerMove: (e: React.PointerEvent) => {
      const d = heroDrag.current;
      if (!d || d.moved) return;
      const dx = e.clientX - d.x;
      const dy = e.clientY - d.y;
      if (Math.abs(dx) < 40 || Math.abs(dx) <= Math.abs(dy)) return;
      d.moved = true;
      haptic("sel");
      setHeroIdx((i) => (i + (dx < 0 ? 1 : hero.length - 1)) % hero.length);
      setHeroHold((v) => v + 1);
    },
    onPointerCancel: () => {
      heroDrag.current = null;
    },
  };

  /* 顶栏:Hero 滚出去之后才实体化。★ 用 Hero 的实际高度当阈值,不写死像素 ——
     横屏时 Hero 矮得多,写死的话顶栏会在还看得见 Hero 的时候就变实心。 */
  useEffect(() => {
    const b = bodyRef.current;
    const bar = barRef.current;
    if (!b || !bar) return;
    const onScroll = () => {
      const h = heroRef.current?.offsetHeight ?? 320;
      bar.classList.toggle("solid", b.scrollTop > h - 90);
    };
    b.addEventListener("scroll", onScroll, { passive: true });
    // 往下滑收起上下栏,往上滑还回来(用户 2026-07-28 要求)
    const offBars = autoHideBars(b, [bar, document.querySelector<HTMLElement>(".tabs")]);
    const offPull = pullRefresh(b, async () => {
      await load();
      toast("已是最新", "ok");
    });
    return () => {
      b.removeEventListener("scroll", onScroll);
      offBars();
      offPull();
    };
    /* ★ 依赖不能是 `[]`。这一页有两个早退分支(没有 Emby 会话 / 首屏加载失败),
       走到那两个分支时 `.pg-body` 根本没渲染,`bodyRef.current` 是 null ——
       effect 空跑一次就再也不跑了。等用户加完服务器 / 点了重试,页面画出来了,
       下拉刷新和"上下栏随滚动显隐"却**永远装不上**,而且一声不吭。
       这和 App.tsx 里三条栈那个 bug 是同一类:**effect 的前提是 DOM 存在,
       依赖数组却没有任何东西反映它什么时候存在**。
       把这两个决定分支走向的 state 放进来,DOM 一出现就重装一遍(有 cleanup,可重入)。 */
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [session, err]);

  useEffect(() => {
    choreograph(bodyRef.current);
  }, [libs.length, keepWatching.length]);

  /* 换 Hero 图时把新图接上淡入。★ 两层叠着 crossfade,不是一个 <img> 改 src ——
     改 src 的那一瞬间是白的,而且新图解码期间旧图已经没了,那个白闪就是"廉价感"的来源。 */
  useEffect(() => {
    if (heroRef.current) imgsIn(heroRef.current);
  }, [heroIdx, hero.length]);

  const lineBtn = usePress<HTMLButtonElement>();
  const setBtn = usePress<HTMLButtonElement>();
  const statBtn = usePress<HTMLButtonElement>();

  if (!session) {
    return (
      <div className="pg-body">
        <Empty
          icon="server"
          title="这一页要 Emby 会话"
          desc="当前只登录了网盘 / 文件浏览型源。去「服务器」加一台 Emby,首页才有东西可摆。"
          action={{ label: "去加一台", on: () => go("addServer") }}
        />
      </div>
    );
  }

  if (err) {
    return (
      <div className="pg-body">
        <Empty
          icon="server"
          title="首页加载失败"
          desc={err}
          action={{ label: "重试", on: () => void load() }}
        />
      </div>
    );
  }

  const h = hero[heroIdx];
  /* 统计:三个数(电影 / 集 / 总计)。
     ★ 去掉「部剧」那一项(用户 2026-07-28 定):对"我有多少能看的"来说,
       剧的**部数**是个中间量 —— 真正能播的是**集**。
     ★ 数字来自 `/Items/Counts?UserId=` 一次调用,不要自己翻页数条目;
       必须带 UserId,不带会把该用户看不到的库也算进去(实测差 39 部电影 / 870 集)。 */
  const c = (overview ?? []).reduce(
    (a, s) => ({ movie: a.movie + s.counts.movie, episode: a.episode + s.counts.episode, boxset: a.boxset + s.counts.boxset }),
    { movie: 0, episode: 0, boxset: 0 },
  );
  const hasCounts = c.movie + c.episode > 0;

  return (
    <>
      {/* 首页顶栏是"浮"在 Hero 上的,不占布局高度 —— 所以不用 <Page> 的常规 topbar */}
      <header className="topbar home-bar" ref={barRef}>
        <div className="tb-t">
          {hasCounts ? (
            <button
              type="button"
              className="hstat"
              ref={statBtn}
              onClick={() =>
                toast(`一次 /Items/Counts?UserId 调用得到 · 合集 ${fmtNum(c.boxset)} 个`)
              }
            >
              <Stat n={c.movie} label="电影" />
              <i className="hs-d" />
              <Stat n={c.episode} label="集" />
              <i className="hs-d" />
              <Stat n={c.movie + c.episode} label="总计" />
            </button>
          ) : (
            /* 统计拿不到(fork 上 /Items/Counts 会 404)时不画一排 0 ——
               那看着像"你的库是空的"。留空,别撒谎。 */
            <div className="tb-title">首页</div>
          )}
        </div>
        <div className="tb-r">
          {/* 线路是「某一台服务器的」—— 不带 id 的话线路页不知道管哪台。
              这里带当前活跃那台;一台都没有时这个按钮不画。 */}
          {overview?.some((s) => s.active) && (
            <button
              type="button"
              aria-label="线路管理"
              ref={lineBtn}
              onClick={() => go({ page: "lines", serverId: overview.find((s) => s.active)!.server_id })}
            >
              <Icon n="line" size={21} />
            </button>
          )}
          <button type="button" aria-label="设置" ref={setBtn} onClick={() => go("settings")}>
            <Icon n="settings" size={21} />
          </button>
        </div>
      </header>

      <div className="pg-body" ref={bodyRef}>
        <div className="home">
          {/* 环境光:把当前 Hero 的主色扩散到页面顶部。
              ★ 这是"高级感"最便宜的一招:没有它,界面就是「一张彩色大图 + 一层死灰 UI」,
                两者毫无关系;有了它,整个首屏像是被这部片子的颜色染过。 */}
          <div className="ambient">
            {hero.map((x, i) => (
              <i key={x.id} className={i === heroIdx ? "on" : ""} style={{ background: ambientOf(x.id) }} />
            ))}
          </div>

          {h && (
            <div
              className="hero"
              ref={heroRef}
              {...heroPan}
              onPointerUp={() => {
                const moved = heroDrag.current?.moved;
                heroDrag.current = null;
                if (!moved) openItem(h);
              }}
            >
              {hero.map((x, i) => (
                <div key={x.id} className={`hero-layer${i === heroIdx ? " on" : ""}`}>
                  {/* 只画当前这张和下一张 —— 五张 1080 大图同时挂在 DOM 里,
                      光是解码就够手机卡一下 */}
                  {Math.abs(i - heroIdx) <= 1 || (heroIdx === 0 && i === hero.length - 1) ? (
                    <img
                      src={backdropUrl(session, x.id, 1080)}
                      alt=""
                      decoding="async"
                      onError={(e) => ((e.target as HTMLImageElement).style.opacity = "0")}
                    />
                  ) : null}
                </div>
              ))}
              <div className="hero-scrim" />
              {/* ★ 三层:艺术字 → 标题 → 元信息,居中。
                  eyebrow 那行、播放/详情两个按钮、画质标签**都去掉了**(用户点名)。
                  去掉按钮不等于没有入口 —— 整块 Hero 本身可点。 */}
              <div className="hero-cap swap" key={h.id}>
                <img
                  className="hero-logo"
                  src={logoUrl(session, h.id, 150)}
                  alt={h.name}
                  style={{ ["--i" as string]: 0 }}
                  decoding="async"
                  /* Logo 图片类型不是每个条目都有(要 ImageTags.Logo)。
                     取不到就整个藏掉,下面那行标题就是兜底 —— 不留一个破图图标。 */
                  onError={(e) => ((e.target as HTMLImageElement).style.display = "none")}
                />
                <div className="hero-title" style={{ ["--i" as string]: 1 }}>
                  {h.name}
                </div>
                <div className="hero-meta" style={{ ["--i" as string]: 2 }}>
                  {metaRow(h)}
                </div>
              </div>
              {hero.length > 1 && (
                <div className="hero-dots">
                  {hero.map((x, i) => (
                    /* 点圆点也能跳 —— 圆点本身只有 6px,外面那个 button 把可点区撑到 22px,
                       不然它是个"看得见但按不中"的东西。 */
                    <button
                      key={x.id}
                      type="button"
                      aria-label={`第 ${i + 1} 张`}
                      className={i === heroIdx ? "on" : ""}
                      onPointerUp={(e) => {
                        e.stopPropagation();
                        if (i === heroIdx) return;
                        haptic("sel");
                        setHeroIdx(i);
                        setHeroHold((v) => v + 1);
                      }}
                    >
                      <i />
                    </button>
                  ))}
                </div>
              )}
            </div>
          )}

          <div>
            {loading ? (
              <>
                <Row skeleton={1} session={session} onOpen={() => {}} />
                <Row skeleton={1} session={session} onOpen={() => {}} />
              </>
            ) : (
              <>
                {keepWatching.length > 0 && (
                  <Row
                    title="继续观看"
                    items={keepWatching}
                    variant="thumb"
                    session={session}
                    onOpen={(it) => void play(it)}
                  />
                )}
                {libs.map((v) => (
                  <Row
                    key={v.id}
                    title={v.name}
                    items={byLib[v.id]}
                    /* ★ 这个库的条目还没回来 → 画骨架卡,**不要画一条空轨道**。
                       空轨道看着像"这个库是空的",而且它高度是 0,后面的轨道会
                       先挤上来、数据一到再往下弹一次 —— 那一跳就是"很难看"。
                       各库各自到、各自换,不等最慢的那一个。 */
                    skeleton={byLib[v.id] ? 0 : 1}
                    session={session}
                    onOpen={(it, el) => openItem(it, el ? flipOf(el) : null)}
                    onMore={() => go({ page: "library", parentId: v.id, title: v.name })}
                  />
                ))}
                {!libs.length && (
                  <Empty
                    icon="grid"
                    title="这台服务器上一个媒体库都没有"
                    desc="不是加载失败 —— 服务端返回的库列表就是空的。去 Emby 后台建一个库并扫描一次。"
                  />
                )}
              </>
            )}
          </div>
        </div>
      </div>
    </>
  );
}

function Stat({ n, label }: { n: number; label: string }) {
  return (
    <div className="hs-i">
      {/* 数字用等宽:不等宽的话刷新后数字位数一变,后面的标签会左右抖 */}
      <b className="num">{fmtNum(n)}</b>
      <span>{label}</span>
    </div>
  );
}

/** 年份 · 评分 · 类型。★ 画质标签去掉(用户 2026-07-28 定)——
 *  首屏第一眼要的是"这是什么",不是参数;画质在详情页和播放器版本面板里。 */
function metaRow(it: Item) {
  const parts: string[] = [];
  if (it.year) parts.push(String(it.year));
  if (it.rating) parts.push("★ " + it.rating.toFixed(1));
  if (it.genres?.length) parts.push(it.genres.slice(0, 2).join(" · "));
  return parts.flatMap((p, i) => (i ? [<i className="sep" key={`s${i}`} />, <span key={p}>{p}</span>] : [<span key={p}>{p}</span>]));
}

/** 从卡片元素取 FLIP 起点。放在这儿而不是 ui.tsx,是为了让 Card 保持"不知道有转场这回事"。 */
function flipOf(el: HTMLElement) {
  const img = el.querySelector("img");
  return {
    rect: el.getBoundingClientRect(),
    src: img?.currentSrc || img?.src || "",
    radius: getComputedStyle(el).borderRadius,
  };
}
