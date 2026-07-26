import { useEffect, useState } from "react";
import {
  type Item,
  type RankingCategory,
  type RankingEntry,
  rankingCategories,
  rankingFetch,
  search,
} from "@shared/api";
import { IconRefresh } from "../app/icons";

/* 排行榜。

   ★ **没有「排行榜开关」这种东西。** TV 端曾经写着「请先在设置里开启排行榜」——
     那是 Flutter 时代留下的谎话,核层压根没有这个开关。别再照抄那句提示。

   ## 点一条会怎样
   榜单条目来自弹弹play/TMDB,**不是本地媒体库的条目** —— 它没有 Emby 的 item id。
   所以点击不能直接进详情,而是拿标题去本服搜索;搜到才进详情,搜不到明说没有。
   假装能进详情然后停在一个空页面上,比说"你的库里没有"糟得多。 */

export default function RankingsPage({ onOpen }: { onOpen: (it: Item) => void }) {
  const [cats, setCats] = useState<RankingCategory[] | null>(null);
  const [cat, setCat] = useState<string>("");
  const [list, setList] = useState<RankingEntry[] | null>(null);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const [miss, setMiss] = useState("");

  useEffect(() => {
    rankingCategories()
      .then((c) => {
        setCats(c);
        setCat((cur) => cur || c[0]?.id || "");
      })
      .catch((e) => setErr(String(e)));
  }, []);

  const load = (force = false) => {
    if (!cat) return;
    setBusy(true);
    setErr("");
    rankingFetch(cat, force)
      .then(setList)
      .catch((e) => setErr(String(e)))
      .finally(() => setBusy(false));
  };

  useEffect(() => {
    if (!cat) return;
    setList(null);
    load(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cat]);

  const open = async (e: RankingEntry) => {
    setMiss("");
    try {
      const hits = await search(e.title, undefined, 5);
      if (hits.length) return onOpen(hits[0]);
      setMiss(`你的库里没有《${e.title}》`);
    } catch (x) {
      setMiss(String(x));
    }
  };

  return (
    <div className="rk">
      <div className="chips lib-bar">
        {(cats ?? []).map((c) => (
          <button key={c.id} type="button" className={`chip${c.id === cat ? " on" : ""}`} onClick={() => setCat(c.id)}>
            {c.label}
          </button>
        ))}
        <button type="button" className="chip" onClick={() => load(true)} aria-label="刷新">
          <IconRefresh size={15} />
        </button>
      </div>

      {err ? (
        <div className="empty"><b>加载失败</b><div className="dim">{err}</div></div>
      ) : cats && !cats.length ? (
        /* ★ 一个分类都没有 = 这个构建**没带弹弹play 编译期凭据**(DANDANPLAY_*)。
           不是服务器故障,也不是"还在加载"。
           原来这里落到下面那个 `{busy ? "加载中…" : ""}` 分支 —— 结果是**一整屏空白
           且一个字都没有**。真机走查时抓到的:编译绿、不报错、CDP 里 crash=null,
           只有把截图看一眼才发现是白板。空态必须说人话,这是「不做假 UI」的另一面。 */
        <div className="empty">
          <b>这个版本没有排行榜</b>
          <div className="dim">
            排行榜要弹弹play 的接口凭据,而凭据是<b>编译期注入</b>的 ——
            本地自己构建的包不带它,用发布版即可。
          </div>
        </div>
      ) : !list ? (
        <div className="empty"><div className="dim">{busy ? "加载中…" : "准备中…"}</div></div>
      ) : !list.length ? (
        <div className="empty"><div className="dim">这个榜单是空的</div></div>
      ) : (
        <div className="cells">
          {list.map((e) => (
            <button key={`${e.source}:${e.id}`} type="button" className="rk-it" onClick={() => void open(e)}>
              {/* 名次做成数字而不是奖牌图标:前三名之后奖牌就没意义了,而数字一直有 */}
              <span className={`rk-n${e.rank <= 3 ? " top" : ""}`}>{e.rank}</span>
              <span className="rk-th">
                {e.image_url && <img src={e.image_url} alt="" loading="lazy" decoding="async" />}
              </span>
              <span className="rk-t">
                <span className="rk-title">{e.title}</span>
                <span className="rk-sub dim">
                  {[e.subtitle, e.rating != null ? `★ ${e.rating.toFixed(1)}` : null]
                    .filter(Boolean)
                    .join(" · ")}
                </span>
              </span>
            </button>
          ))}
        </div>
      )}

      {miss && (
        <div className="toast" onClick={() => setMiss("")}>
          {miss}
        </div>
      )}
    </div>
  );
}
