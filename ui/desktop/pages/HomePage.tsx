import { useCallback, useEffect, useRef, useState, type ReactNode } from "react";
import {
  type Item,
  type LoginResult,
  backdropUrl,
  listCollections,
  listLatest,
  listNextUp,
  listRandom,
  listResume,
  logoUrl,
  posterUrl,
  thumbUrl,
  views,
} from "@shared/api";
import { useCardActions } from "../lib/cardActions";
import Poster from "../components/Poster";
import { PluginSlot } from "../components/PluginHost";
import {
  IconChevronLeft,
  IconChevronRight,
  IconLibrary,
  IconRefresh,
  IconSearch,
} from "../app/icons";
import "./HomePage.css";

/**
 * Hero 的 logo 标题(标注 6:「大幅剧照 + logo 标题」)。
 * Emby 的 /Items/{id}/Images/Logo 和 posterUrl 同形状,只是 Logo 而非 Primary。
 * 就地放不进 api.ts:那份文件不归这里改,而且目前只有首页 Hero 用得上。
 * ★ 核层 Item 没有 has_logo 之类的标志位 → 只能靠 <img onError> 兜底回文字标题,
 *   没有别的诚实判据(先 HEAD 探一次纯属多一个往返)。
 */


type Props = {
  session: LoginResult;
  onOpenLibrary: (view: Item) => void;
  onOpenItem: (it: Item) => void;
  onPlay: (it: Item) => void;
  onSearch: () => void;
  onRefresh: () => void;
  reloadKey: number;
};

/**
 * 横向轨道:草稿末条注「轨道右端悬停显现翻页箭头 ›,滚轮横向滚动;不用移动端的惯性滑动」。
 * 三种轨道(继续观看/媒体库/最新)共用一套滚动+箭头逻辑,不各写一遍。
 */
function Rail({ children }: { children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [edge, setEdge] = useState({ left: false, right: false });

  // 到头的方向不留死箭头,所以要跟着滚动位置算。
  const sync = useCallback(() => {
    const el = ref.current;
    if (!el) return;
    setEdge({
      left: el.scrollLeft > 4,
      right: el.scrollLeft + el.clientWidth < el.scrollWidth - 4,
    });
  }, []);

  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    sync();

    const onWheel = (e: WheelEvent) => {
      if (Math.abs(e.deltaY) <= Math.abs(e.deltaX)) return;
      // 该方向已经到头就把滚轮还给页面,否则鼠标停在轨道上整页都滚不动了。
      const canScroll =
        e.deltaY > 0
          ? el.scrollLeft + el.clientWidth < el.scrollWidth - 1
          : el.scrollLeft > 1;
      if (!canScroll) return;
      // React 的 onWheel 挂在 root 上且是 passive 的,preventDefault 不生效 →
      // 必须原生非 passive 绑定,不然横向滚的同时整页也跟着纵向滚。
      e.preventDefault();
      el.scrollLeft += e.deltaY;
    };
    el.addEventListener("wheel", onWheel, { passive: false });

    // 数据/图片异步到货会改 scrollWidth,重算箭头显隐。
    const ro = new ResizeObserver(sync);
    ro.observe(el);
    for (const c of Array.from(el.children)) ro.observe(c);

    return () => {
      el.removeEventListener("wheel", onWheel);
      ro.disconnect();
    };
  }, [sync, children]);

  const page = (dir: 1 | -1) => {
    const el = ref.current;
    if (el) el.scrollBy({ left: dir * el.clientWidth * 0.9, behavior: "smooth" });
  };

  return (
    <div className="hm-rail">
      <div className="rail" ref={ref} onScroll={sync}>
        {children}
      </div>
      {edge.left && (
        <button className="hm-arrow left" title="上一屏" onClick={() => page(-1)}>
          <IconChevronLeft size={16} />
        </button>
      )}
      {edge.right && (
        <button className="hm-arrow right" title="下一屏" onClick={() => page(1)}>
          <IconChevronRight size={16} />
        </button>
      )}
    </div>
  );
}

const typeLabel = (t: string) => (t === "Movie" ? "电影" : t === "Series" ? "剧集" : t);

export default function HomePage({
  session,
  onOpenLibrary,
  onOpenItem,
  onPlay,
  onSearch,
  onRefresh,
  reloadKey,
}: Props) {
  const [libs, setLibs] = useState<Item[]>([]);
  const [byLib, setByLib] = useState<Record<string, Item[]>>({});
  const [resume, setResume] = useState<Item[]>([]);
  const [nextUp, setNextUp] = useState<Item[]>([]);
  const [collections, setCollections] = useState<Item[]>([]);
  const [featured, setFeatured] = useState<Item[]>([]);
  const [heroIdx, setHeroIdx] = useState(0);
  /** 取 Logo 失败的条目 id。按 id 记而不是一个 bool —— 否则翻到下一张 Hero 还顶着上一张的失败态。 */
  const [logoFail, setLogoFail] = useState<Set<string>>(new Set());
  const [err, setErr] = useState("");
  const hover = useRef(false);
  const cbarRef = useRef<HTMLDivElement>(null);

  /* 卡片动作(收藏/标记已看/右键菜单/悬停播放)全走公共 hook —— 首页/媒体库/收藏/搜索同一套。
     标记已看后只重拉「继续观看」这条轨道(Emby 里已看即掉出 Resume),不整页刷(会把 Hero 重随机)。 */
  const { cardProps, menu, toastNode } = useCardActions(session, {
    onPlay,
    onChanged: () => void listResume(12).then(setResume).catch(() => {}),
  });

  /** 首屏是否还在等第一批数据 —— 控制骨架。null=加载中,[]/有值=到了。 */
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    let alive = true;
    setByLib({});
    setFeatured([]);
    setHeroIdx(0);
    setLogoFail(new Set());
    setLoading(true);

    /* ★ 加载结构:骨架先出 → 每块数据各自到、各自渲染 → 媒体库**并发**不串行。
       用户 2026-07-15 当面纠正:「先出现骨架 然后再不断加载图片 不要等所有图片都能加载再加载」。

       旧写法两个屏障,叠起来是**秒级**的(我之前砍的 668ms 动画只是零头):
         1) 五个请求 `await Promise.all` —— 收藏/合集慢一点,Hero 就跟着等;
         2) `for (const v of vs) await listLatest(v)` —— 八个媒体库 = 八次**串行**往返。
       现在:每个请求**各自** .then 里 set,谁先回谁先画;媒体库用 Promise.all 一次性并发。
       各块自己有 .catch → 一个源挂了不拖累别的,也不整页报错。 */

    // Hero + 媒体库列表:决定「骨架能不能撤」的两个,先亮。
    views()
      .then((vs) => {
        if (!alive) return;
        setLibs(vs);
        setLoading(false); // 有库名了,轨道骨架就能各就各位,不必等内容
        // 每个库**并发**拉,谁先回谁先填 —— 不再一个 await 一个
        vs.forEach((v) =>
          listLatest(v.id, 20)
            .then((items) => alive && setByLib((m) => ({ ...m, [v.id]: items })))
            .catch(() => {}),
        );
      })
      .catch((e) => {
        // views 是首页的地基,它挂了才算真错误(其余源挂了都静默)。
        if (alive) {
          setErr(String(e));
          setLoading(false);
        }
      });

    listRandom(5).then((r) => alive && setFeatured(r)).catch(() => {});
    listResume(12).then((r) => alive && setResume(r)).catch(() => {});
    listNextUp(20).then((r) => alive && setNextUp(r)).catch(() => {});
    listCollections().then((c) => alive && setCollections(c)).catch(() => {});

    return () => {
      alive = false;
    };
  }, [session.server, reloadKey]);

  // Hero 自动轮播(标注 6:悬停暂停)。
  useEffect(() => {
    if (featured.length < 2) return;
    const t = window.setInterval(() => {
      if (!hover.current) setHeroIdx((i) => (i + 1) % featured.length);
    }, 6000);
    return () => window.clearInterval(t);
  }, [featured.length]);

  /** 顶栏随内容滚动淡出(标注 4)。直接写 DOM 上的 CSS 变量,不走 state ——
      滚动每帧 setState 会把整页(含所有海报)重渲一遍。 */
  const onScroll = (e: { currentTarget: HTMLDivElement }) => {
    const el = cbarRef.current;
    if (!el) return;
    el.style.setProperty("--cbar-fade", String(Math.max(0, 1 - e.currentTarget.scrollTop / 140)));
  };

  const hero = featured[heroIdx];
  const step = (d: 1 | -1) =>
    setHeroIdx((i) => (i + d + featured.length) % featured.length);
  // Item 里只有类型/时长是实的(年份/简介在 ItemDetail,首页不为 5 张 Hero 各拉一次详情)。
  /** Hero 标签(草稿:艺术字/标题下面一行)。年份 · 类型 · 评分 —— 和详情页 chips 口径一致。 */
  const heroTags = hero
    ? [
        hero.year ? String(hero.year) : "",
        typeLabel(hero.type_),
        hero.rating != null && hero.rating > 0 ? `★ ${hero.rating.toFixed(1)}` : "",
      ].filter(Boolean)
    : [];

  return (
    <>
      {/* 不写 inline style 设默认值:那样 React 每次重渲都可能把 --cbar-fade 抹回 1,
          滚到一半弹个 toast 顶栏就闪回来。默认值交给 CSS 的 var(--cbar-fade, 1) 回落。 */}
      <div className="cbar" ref={cbarRef}>
        <span className="crumb">
          <b>首页</b>
        </span>
        <span className="push">
          <button className="searchbox" onClick={onSearch}>
            <IconSearch size={14} /> 搜索 / 聚合… <span className="kbd">Ctrl K</span>
          </button>
          <button className="ibtn" title="刷新" onClick={onRefresh}>
            <IconRefresh size={15} />
          </button>
        </span>
      </div>

      <div className="scroll" onScroll={onScroll}>
        {err && <div className="empty">加载失败：{err}</div>}

        {/* Hero 骨架:featured 还没回来时垫一块,别让首屏顶上一片空白。
            list_random 通常是最快回来的之一,但网络差时也可能慢 —— 骨架保证「一进来就有东西」。 */}
        {!hero && !err && (
          <div className="hero hm-hero skeleton" style={{ cursor: "default" }} aria-hidden />
        )}

        {hero && (
          <div
            className="hero hm-hero"
            onMouseEnter={() => (hover.current = true)}
            onMouseLeave={() => (hover.current = false)}
            onClick={() => onOpenItem(hero)}
          >
            <img
              key={hero.id}
              className="hero-bg"
              src={backdropUrl(session, hero.id)}
              onError={(e) => {
                const el = e.target as HTMLImageElement;
                // list_random 保证有 backdrop,但取图仍可能失败 → 退回海报。
                if (hero.has_primary) el.src = posterUrl(session, hero.id, 720);
                else el.style.opacity = "0";
              }}
            />
            <div className="hero-grad" />

            {featured.length > 1 && (
              <>
                <button
                  className="hm-arrow left"
                  title="上一张"
                  onClick={(e) => {
                    e.stopPropagation();
                    step(-1);
                  }}
                >
                  <IconChevronLeft size={16} />
                </button>
                <button
                  className="hm-arrow right"
                  title="下一张"
                  onClick={(e) => {
                    e.stopPropagation();
                    step(1);
                  }}
                >
                  <IconChevronRight size={16} />
                </button>
              </>
            )}

            <div className="hero-body">
              {/* 用户 2026-07-15 定的版式:艺术字(缩小) → 条目标题 → 标签。
                  「随机推荐」eyebrow 删了(没必要);播放/＋/详情 三键删了 —— 整块单击进详情。 */}
              {logoFail.has(hero.id) ? (
                /* ★ 决定 A:艺术字取不到 → 回落成文字标题,**此时隐藏下面那行标题**,
                   否则和它自己重复。所以这里直接把 hero-title 当唯一标题,下面那行加 !logoFail 守卫。 */
                <div className="hero-title">{hero.name}</div>
              ) : (
                <img
                  key={hero.id}
                  className="hm-herologo"
                  src={logoUrl(session, hero.id)}
                  alt={hero.name}
                  onError={() => setLogoFail((s) => new Set(s).add(hero.id))}
                />
              )}
              {/* 条目标题:只在「用了艺术字」时出现;回落文字标题时上面那行已经是标题了,不重复。 */}
              {!logoFail.has(hero.id) && <div className="hero-subtitle">{hero.name}</div>}
              {heroTags.length > 0 && (
                <div className="hero-tags">
                  {heroTags.map((t) => (
                    <span className={`hero-tag${t.startsWith("★") ? " y" : ""}`} key={t}>
                      {t}
                    </span>
                  ))}
                </div>
              )}
            </div>

            <div className="hero-dots">
              {featured.map((f, i) => (
                <i
                  key={f.id}
                  className={i === heroIdx ? "on" : ""}
                  onClick={(e) => {
                    e.stopPropagation();
                    setHeroIdx(i);
                  }}
                />
              ))}
            </div>
          </div>
        )}

        <div className="hm-body">
          {resume.length > 0 && (
            <section>
              <div className="rowlab">
                <span className="h">继续观看</span>
              </div>
              {/* 继续观看基本都是剧集,封面本来就是 16:9 剧照 → thumb 横版,不用竖海报。 */}
              <Rail>
                {resume.map((it) => (
                  <div className="r-wide" key={it.id}>
                    <Poster
                      item={it}
                      session={session}
                      variant="thumb"
                      onOpen={onOpenItem}
                      {...cardProps(it)}
                    />
                  </div>
                ))}
              </Rail>
            </section>
          )}

          {/* 接下来观看(/Shows/NextUp):剧集追更的「下一集」。命令一直在,首页过去没接。
              竖海报 → 用竖版卡;和继续观看错开(那边是有进度的当前集,这边是没看过的下一集)。 */}
          {nextUp.length > 0 && (
            <section>
              <div className="rowlab">
                <span className="h">接下来观看</span>
              </div>
              <Rail>
                {nextUp.map((it) => (
                  <div className="r-wide" key={it.id}>
                    <Poster
                      item={it}
                      session={session}
                      variant="thumb"
                      onOpen={onOpenItem}
                      {...cardProps(it)}
                    />
                  </div>
                ))}
              </Rail>
            </section>
          )}

          {/* 合集轨道(草稿 L643-649:16:9 卡)。BoxSet 是文件夹 → 卡片单击就是进合集详情。 */}
          {collections.length > 0 && (
            <section>
              <div className="rowlab">
                <span className="h">合集</span>
              </div>
              <Rail>
                {collections.map((c) => (
                  <div className="r-wide" key={c.id}>
                    <Poster
                      item={c}
                      session={session}
                      variant="thumb"
                      onOpen={onOpenItem}
                      {...cardProps(c)}
                    />
                  </div>
                ))}
              </Rail>
            </section>
          )}

          {/* 插件面板(slot: home.stats)。没插件挂上来时整块不渲染 —— 连标题都不出。 */}
          <PluginSlot slot="home.stats" className="hm-plugins" />

          {/* 媒体库入口行:loading 时先出骨架(和下面每个轨道同款),不要等 views() 回来才凭空冒出来。 */}
          {loading && (
            <section>
              <div className="rowlab"><span className="h">媒体库</span></div>
              <div className="rail">
                {Array.from({ length: 6 }).map((_, i) => (
                  <div className="r-wide" key={i}><div className="pcard thumb-ar skeleton" /></div>
                ))}
              </div>
            </section>
          )}

          {libs.length > 0 && (
            <section>
              <div className="rowlab">
                <span className="h">媒体库</span>
              </div>
              <Rail>
                {libs.map((v) => (
                  <button
                    className="r-wide hm-lib"
                    key={v.id}
                    title={v.name}
                    onClick={() => onOpenLibrary(v)}
                  >
                    <div className="hm-libimg">
                      {v.has_primary ? (
                        <img
                          src={thumbUrl(session, v.id)}
                          loading="lazy"
                          onError={(e) =>
                            ((e.target as HTMLImageElement).style.visibility = "hidden")
                          }
                        />
                      ) : (
                        <div className="hm-libfb">
                          <IconLibrary size={26} />
                        </div>
                      )}
                    </div>
                    <div className="pcap">{v.name}</div>
                  </button>
                ))}
              </Rail>
            </section>
          )}

          {/* views() 还没回来时,先出两条「最新」轨道骨架占位 —— libs 空时下面的 libs.map
              一条都不画,首屏下半会是空的。有 libs 了这段就撤。 */}
          {loading &&
            Array.from({ length: 2 }).map((_, s) => (
              <section key={`sk-${s}`}>
                <div className="rowlab"><span className="h skeleton" style={{ width: 120, height: 15, borderRadius: 6 }} /></div>
                <div className="rail">
                  {Array.from({ length: 7 }).map((_, i) => (
                    <div className="r-poster" key={i}><div className="pcard poster-ar skeleton" /></div>
                  ))}
                </div>
              </section>
            ))}

          {libs.map((lib) => {
            const items = byLib[lib.id];
            return (
              <section key={lib.id}>
                <div className="rowlab">
                  <span className="h">最新 · {lib.name}</span>
                  <button className="all" onClick={() => onOpenLibrary(lib)}>
                    查看更多 <IconChevronRight size={12} />
                  </button>
                </div>
                {items == null ? (
                  <div className="rail">
                    {Array.from({ length: 7 }).map((_, i) => (
                      <div className="r-poster" key={i}>
                        <div className="pcard poster-ar skeleton" />
                      </div>
                    ))}
                  </div>
                ) : items.length === 0 ? (
                  <div className="empty">这个库还没有内容</div>
                ) : (
                  <Rail>
                    {items.map((it) => (
                      <div className="r-poster" key={it.id}>
                        <Poster
                          item={it}
                          session={session}
                          onOpen={onOpenItem}
                          {...cardProps(it)}
                        />
                      </div>
                    ))}
                  </Rail>
                )}
              </section>
            );
          })}
          <div style={{ height: 40 }} />
        </div>
      </div>

      {/* 右键菜单(标记已/未播放 + 收藏 + 管理员项)与 toast 都由 useCardActions 出 ——
          现在四处网格(首页/媒体库/收藏/搜索)共用同一套,不再是首页独有。 */}
      {menu}
      {toastNode}
    </>
  );
}
