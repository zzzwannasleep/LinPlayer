import { useEffect, useState } from "react";
import {
  type Item,
  type PersonDetail,
  personDetail,
  personItems,
  personUrl,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { dominantOf, washColor } from "../app/color";
import Page from "../components/Page";
import { Empty, Grid } from "../components/ui";
import { hueOf } from "./DetailPage";

/* 演职员详情页(用户 2026-08-01 新提)。

   版式照用户描述:**左上海报 / 右侧生平 / 下方参演作品**。

   ★ 生平(Overview)**经常是空的** —— 只有刮削器抓到 TMDB 人物页才有。
     空是常态不是错误,所以要为"没有生平"专门排一版(把出生地/生卒顶上来),
     不能留一块白。
   ★ 头像也常常没有(整个详情页的演职员轨道里实测 18.6% 缺图),
     所以这一页的海报位同样要有兜底,而且**兜底和有图时一样大**。
   ★ 背景同样取头像主色向下延伸 —— 和详情页一套语言,不另发明。 */

/** "1971-06-28T00:00:00.0000000Z" → "1971-06-28"。
 *  ★ 不用 `new Date()` 再格式化:那会按**本地时区**偏移一天,
 *    生日显示成前一天是很显眼的错。字符串截断没有这个问题。 */
const ymd = (s: string | null) => (s ? s.slice(0, 10) : null);

/** 生卒 → "1971-06-28(54 岁)" / "1971-06-28 — 2020-01-26"。 */
function lifeLine(d: PersonDetail): string | null {
  const b = ymd(d.birthday);
  const e = ymd(d.death_day);
  if (!b && !e) return null;
  if (b && e) return `${b} — ${e}`;
  if (e) return `卒于 ${e}`;
  const by = Number(b!.slice(0, 4));
  const age = by > 1800 ? new Date().getFullYear() - by : 0;
  return age > 0 ? `${b}(${age} 岁)` : b;
}

export default function PersonPage({ personId }: { personId?: string }) {
  const { session, back, openItem } = useCtx();
  const [d, setD] = useState<PersonDetail | null>(null);
  const [works, setWorks] = useState<Item[] | null>(null);
  const [err, setErr] = useState("");
  const [wash, setWash] = useState<string | null>(null);
  const [ovOpen, setOvOpen] = useState(false);

  useEffect(() => {
    if (!personId) return;
    let alive = true;
    setErr("");
    setWash(null);
    setD(null);
    setWorks(null);
    personDetail(personId)
      .then((x) => alive && setD(x))
      .catch((e) => alive && setErr(String(e)));
    // 作品单独到、单独渲染 —— 不和人物详情绑成一个 Promise.all 屏障
    personItems(personId)
      .then((x) => alive && setWorks(x))
      .catch(() => alive && setWorks([]));
    return () => {
      alive = false;
    };
  }, [personId]);

  if (err) {
    return (
      <Page title="演职员" onBack={back}>
        <Empty icon="info" title="加载失败" desc={err} />
      </Page>
    );
  }
  if (!d || !session) {
    return (
      <Page title="演职员" onBack={back}>
        <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
      </Page>
    );
  }

  const life = lifeLine(d);

  return (
    <Page title={d.name} onBack={back} enterKey={d.id}>
      <div
        className={`detail pdt${wash ? " washed" : ""}`}
        style={wash ? ({ ["--wash" as string]: wash } as React.CSSProperties) : undefined}
      >
        <div className="pdt-top">
          {d.has_primary ? (
            <div className="pdt-av">
              <img
                src={personUrl(session, d.id, 480)}
                alt={d.name}
                decoding="async"
                crossOrigin="anonymous"
                onLoad={(e) => setWash(washColor(dominantOf(e.currentTarget)))}
                onError={(e) => ((e.target as HTMLImageElement).style.opacity = "0")}
              />
            </div>
          ) : (
            <div className="pdt-av fb" style={{ background: hueOf(d.id) }}>
              {d.name.slice(0, 1)}
            </div>
          )}
          <div className="pdt-side">
            <h1 className="pdt-name">{d.name}</h1>
            {life ? <div className="pdt-meta">{life}</div> : null}
            {d.birth_place ? <div className="pdt-meta">{d.birth_place}</div> : null}
            {works && works.length > 0 ? (
              <div className="pdt-meta">{works.length} 部作品在这台服务器上</div>
            ) : null}
          </div>
        </div>

        {/* 生平。★ 没有就**明说服务器上没有**,不要留一块空白让人以为没加载出来。 */}
        <div className="dt-intro">
          {d.overview ? (
            <div className={`dt-ov${ovOpen ? "" : " clamp"}`}>
              <div className="dt-ov-t">{d.overview}</div>
              <button type="button" className="dt-ov-more" onClick={() => setOvOpen((v) => !v)}>
                {ovOpen ? "收起" : "更多"}
              </button>
            </div>
          ) : (
            <div className="dt-ov dim">
              <div className="dt-ov-t">
                服务器上没有这个人的生平 —— 元数据里就是空的。生平要刮削器抓到 TMDB 人物页才有。
              </div>
            </div>
          )}
        </div>

        <section className="dt-sec">
          <div className="row-hd">
            <h2>参演作品</h2>
          </div>
          {works === null ? (
            <div className="pad dim" style={{ fontSize: 13 }}>正在找…</div>
          ) : works.length === 0 ? (
            <Empty
              icon="inbox"
              title="这台服务器上没有他/她的作品"
              desc="不是加载失败 —— 按 PersonIds 查回来就是空的。多半是这个人物条目还没和任何影片建立关联。"
            />
          ) : (
            <Grid
              items={works}
              session={session}
              onOpen={(x) => openItem(x)}
            />
          )}
        </section>
        <div style={{ height: 28 }} />
      </div>
    </Page>
  );
}

