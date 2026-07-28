import { useEffect, useState } from "react";
import { type RankingCategory, type RankingEntry, rankingCategories, rankingFetch, search } from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { choreograph, haptic, toast } from "../app/motion";
import Page from "../components/Page";
import { Empty, usePress } from "../components/ui";
import { useRef } from "react";

/* 排行榜。

   ★ **没有「排行榜开关」这种东西。** TV 端曾经写着「请先在设置里开启排行榜」——
     那是 Flutter 时代留下的谎话,核层压根没有这个开关。别再照抄那句提示。

   ★ 一个分类都没有 = 这个包**编译时没带弹弹play 凭据**。
     上一版落在 `{busy ? "加载中…" : ""}` 分支上,表现是**一整屏空白一个字都没有**——
     CDP 里 crash=null、不报错,只有把截图看一眼才发现是白板。空态必须说人话。

   ## 点一条会怎样
   榜单条目来自弹弹play/TMDB,**不是本地媒体库的条目** —— 它没有 Emby 的 item id。
   所以点击不能直接进详情,而是拿标题去本服搜索;搜到才进详情,搜不到明说没有。
   假装能进详情然后停在一个空页面上,比说"你的库里没有"糟得多。 */

export default function RankingsPage() {
  const { back, openItem } = useCtx();
  const [cats, setCats] = useState<RankingCategory[] | null>(null);
  const [cat, setCat] = useState("");
  const [list, setList] = useState<RankingEntry[] | null>(null);
  const [err, setErr] = useState("");
  const [busy, setBusy] = useState(false);
  const listRef = useRef<HTMLDivElement>(null);

  useEffect(() => {
    rankingCategories()
      .then((cs) => {
        setCats(cs);
        setCat(cs[0]?.id ?? "");
      })
      .catch((e) => setErr(String(e)));
  }, []);

  const load = (force = false) => {
    if (!cat) return;
    setBusy(true);
    setList(null);
    rankingFetch(cat, force)
      .then(setList)
      .catch((e) => setErr(String(e)))
      .finally(() => setBusy(false));
  };

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cat]);

  useEffect(() => {
    choreograph(listRef.current);
  }, [list]);

  const open = (e: RankingEntry) => {
    haptic("tap");
    search(e.title, ["Movie", "Series"], 1)
      .then((r) => {
        if (r[0]) openItem(r[0]);
        else toast(`你的库里没有《${e.title}》`, "warn");
      })
      .catch(() => toast("搜索失败", "bad"));
  };

  return (
    <Page title="排行榜" onBack={back} enterKey={list}>
      <div className="chips">
        {(cats ?? []).map((c) => (
          <Chip
            key={c.id}
            on={c.id === cat}
            label={c.label}
            onClick={() => {
              haptic("sel");
              setCat(c.id);
            }}
          />
        ))}
        {cats && cats.length > 0 && (
          <Chip icon="refresh" label="刷新" onClick={() => load(true)} />
        )}
      </div>

      <div ref={listRef}>
        {err ? (
          <Empty icon="trophy" title="排行榜取不到" desc={err} />
        ) : cats === null ? (
          <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
        ) : !cats.length ? (
          <Empty
            icon="trophy"
            title="这个包里没有排行榜数据源"
            desc="排行榜要弹弹play 的编译期凭据(DANDANPLAY_APP_ID / SECRET)。本地自己 build 的包不带它,所以分类列表是空的 —— 这不是加载失败。用 CI 出的正式包就有。"
          />
        ) : busy || list === null ? (
          <div className="pad dim" style={{ fontSize: 13 }}>正在拉「{cats.find((c) => c.id === cat)?.label}」…</div>
        ) : !list.length ? (
          <Empty icon="trophy" title="这个榜单暂时没有数据" desc="换一个分类试试 —— 接口是按分类返回的。" />
        ) : (
          list.map((e, i) => (
            <RankRow key={`${e.source}:${e.id}`} e={e} i={i} onClick={() => open(e)} />
          ))
        )}
      </div>
    </Page>
  );
}

function RankRow({ e, i, onClick }: { e: RankingEntry; i: number; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button
      type="button"
      className="rk-item"
      ref={ref}
      style={{ ["--i" as string]: i }}
      onClick={onClick}
    >
      <div className={`rk-no${e.rank <= 3 ? " top" : ""}`}>{e.rank}</div>
      <div className="card-a ar-poster" style={{ width: 44, flexShrink: 0 }}>
        {e.image_url ? <img src={e.image_url} alt="" loading="lazy" decoding="async" /> : null}
      </div>
      <div className="rk-t">
        <div className="rk-tt">{e.title}</div>
        <div className="rk-ts">
          {[e.subtitle, e.rating != null ? `★ ${e.rating.toFixed(1)}` : null].filter(Boolean).join(" · ")}
        </div>
      </div>
      {e.is_favorited ? <Icon n="heartOn" size={16} /> : null}
    </button>
  );
}

function Chip({ on, label, icon, onClick }: { on?: boolean; label: string; icon?: string; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button type="button" className={`chip${on ? " on" : ""}`} ref={ref} onClick={onClick}>
      {icon ? <Icon n={icon} size={15} /> : null}
      {label}
    </button>
  );
}
