import { useEffect, useState } from "react";
import {
  type Item,
  type LoginResult,
  backdropUrl,
  listLatest,
  listNextUp,
  listRandom,
  listResume,
  views,
} from "@shared/api";
import { HOME_CHIPS, type PageId } from "../app/nav";
import Row from "../components/Row";

/* 首页。

   版式:Hero(大图) → chip 行 → 继续观看 → 接下来看 → 每个媒体库一条轨道。

   ★ 加载结构是这一页的核心,不是动画。
     PC 端 2026-07-15 栽过一次:五个请求 `await Promise.all` + 媒体库串行 await,
     叠起来是**秒级**的,而当时我去砍入场动画(668ms)——那只是零头。
     这里照抄修好之后的结构:**每块数据各自 .then 里 set,谁先回谁先画**,
     媒体库并发不串行,各块自己 catch(一个源挂了不拖累别的,也不整页报错)。
     别再把"不秒加载"归因到动画上。 */

type Props = {
  session: LoginResult;
  onOpen: (it: Item) => void;
  /** 点 chip / 「更多」→ 压栈进对应页面 */
  onGo: (page: PageId, parentId?: string, title?: string) => void;
};

export default function HomePage({ session, onOpen, onGo }: Props) {
  const [libs, setLibs] = useState<Item[]>([]);
  const [byLib, setByLib] = useState<Record<string, Item[]>>({});
  const [resume, setResume] = useState<Item[]>([]);
  const [nextUp, setNextUp] = useState<Item[]>([]);
  const [hero, setHero] = useState<Item[]>([]);
  const [heroIdx, setHeroIdx] = useState(0);
  const [loading, setLoading] = useState(true);
  const [err, setErr] = useState("");

  useEffect(() => {
    let alive = true;
    setLoading(true);
    setErr("");

    views()
      .then((vs) => {
        if (!alive) return;
        setLibs(vs);
        // 有库名了骨架就能撤 —— 不必等内容,轨道标题先立住,卡片陆续填进来
        setLoading(false);
        vs.forEach((v) =>
          listLatest(v.id, 20)
            .then((items) => alive && setByLib((m) => ({ ...m, [v.id]: items })))
            .catch(() => {}),
        );
      })
      .catch((e) => {
        // views 是首页的地基,它挂了才算真错误(其余源挂了都静默)
        if (!alive) return;
        setErr(String(e));
        setLoading(false);
      });

    listRandom(5).then((r) => alive && setHero(r)).catch(() => {});
    listResume(12).then((r) => alive && setResume(r)).catch(() => {});
    listNextUp(20).then((r) => alive && setNextUp(r)).catch(() => {});

    return () => {
      alive = false;
    };
  }, [session.server]);

  /* Hero 轮播。★ 5 秒不是 3 秒:手机屏幕小,一张大图上要读片名+简介,
     3 秒会让人有"还没看完就翻页了"的焦躁。停在页面上不动时才轮播,
     用户一旦开始滚动就没必要继续换(见下面的 onScroll 逻辑不做 —— 保持简单,
     轮播本身只动 opacity,滚动时也不掉帧)。 */
  useEffect(() => {
    if (hero.length < 2) return;
    const t = window.setInterval(() => setHeroIdx((i) => (i + 1) % hero.length), 5000);
    return () => window.clearInterval(t);
  }, [hero.length]);

  if (err) {
    return (
      <div className="pad">
        <div className="empty">
          <b>首页加载失败</b>
          <div className="dim">{err}</div>
        </div>
      </div>
    );
  }

  const h = hero[heroIdx];

  return (
    <div className="home">
      {/* Hero。has_backdrop 这个标志位 Item 上没有 —— 靠 onError 兜底藏图,
          这是核层能给的唯一诚实判据(先 HEAD 探一次纯属多一个往返)。 */}
      {h && (
        <div className="hero" onClick={() => onOpen(h)}>
          <img
            key={h.id}
            className="hero-img"
            src={backdropUrl(session, h.id, 1080)}
            alt=""
            decoding="async"
            onError={(e) => ((e.target as HTMLImageElement).style.opacity = "0")}
          />
          {/* ★ 不用渐变遮罩。全屏渐变每帧都要重新合成,而且渐变边界在低分屏上是糊的。
              裸文字压在亮场景上会看不清 → 给文字**自带一块不透明底**,不是加回渐变。
              这条是 TV 端评审时定的口径,手机上同理(而且手机 GPU 更弱)。 */}
          <div className="hero-cap">
            <div className="hero-title">{h.name}</div>
            <div className="hero-sub">
              {[h.year, h.genres?.slice(0, 2).join(" · ")].filter(Boolean).join(" · ")}
            </div>
          </div>
          {hero.length > 1 && (
            <div className="hero-dots">
              {hero.map((x, i) => (
                <i key={x.id} className={i === heroIdx ? "on" : ""} />
              ))}
            </div>
          )}
        </div>
      )}

      {/* chip 行:PC 侧栏里那 5 个内容入口搬到这儿(见 app/nav.ts 的取舍说明)。
          横滑不换行 —— 换行会让首页顶部高度随入口数抖动。 */}
      <div className="chips">
        {HOME_CHIPS.map((c) => (
          <button key={c.id} type="button" className="chip" onClick={() => onGo(c.id)}>
            {c.label}
          </button>
        ))}
      </div>

      {loading && (
        <div className="row">
          <div className="row-hd">
            <h2 className="sk-t" />
          </div>
          <div className="row-scroll">
            {[0, 1, 2, 3].map((i) => (
              <div key={i} className="mcard-wrap">
                <div className="mcard ar-poster">
                  <div className="mskel" />
                </div>
              </div>
            ))}
          </div>
        </div>
      )}

      <Row title="继续观看" items={resume} session={session} onOpen={onOpen} variant="thumb" />
      <Row title="接下来看" items={nextUp} session={session} onOpen={onOpen} variant="thumb" />

      {libs.map((v) => (
        <Row
          key={v.id}
          title={v.name}
          items={byLib[v.id] ?? []}
          session={session}
          onOpen={onOpen}
          onMore={() => onGo("library", v.id, v.name)}
        />
      ))}
    </div>
  );
}
