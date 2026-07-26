import { useEffect, useMemo, useState } from "react";
import { type CalendarEntry, bangumiCalendar, traktCalendar } from "@shared/api";
import { dayKey, groupByWeek, statusOf, weekOf, weekdayIndex } from "@shared/calendar-grouping";

/* 追剧日历。

   ## 与 PC 的差异:七列 → 七段
   PC 是一周七列并排。手机屏宽 390,七列每列 50px —— 放不下封面也放不下标题。
   所以改成**竖着七段**,一天一段,今天那段默认滚到视口里。

   ## 归组逻辑不重写
   `@shared/calendar-grouping` 是纯逻辑模块(不碰 React/DOM/Tauri),
   PC 端在这上面出过一个把整页打黑的越界 bug,现在有脚本直接跑真代码验证。
   手机端**用同一份** —— 抄一份副本等于把那个 bug 的可能性复制一遍。 */

const WEEKDAYS = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"];

export default function CalendarPage() {
  const [src, setSrc] = useState<"bangumi" | "trakt">("bangumi");
  const [onlyMine, setOnlyMine] = useState(false);
  const [entries, setEntries] = useState<CalendarEntry[] | null>(null);
  const [err, setErr] = useState("");
  const [weekOffset, setWeekOffset] = useState(0);

  useEffect(() => {
    let alive = true;
    setEntries(null);
    setErr("");
    const p = src === "trakt" ? traktCalendar(onlyMine) : bangumiCalendar(onlyMine);
    p.then((x) => alive && setEntries(x)).catch((e) => alive && setErr(String(e)));
    return () => {
      alive = false;
    };
  }, [src, onlyMine]);

  const now = useMemo(() => new Date(), []);
  const week = useMemo(() => weekOf(now, weekOffset), [now, weekOffset]);
  const cols = useMemo(() => (entries ? groupByWeek(entries, week) : []), [entries, week]);
  const todayIdx = weekOffset === 0 ? weekdayIndex(now) : -1;
  const nowMin = now.getHours() * 60 + now.getMinutes();
  const todayMs = useMemo(() => new Date(now).setHours(0, 0, 0, 0), [now]);

  return (
    <div className="cal">
      <div className="chips lib-bar">
        <button type="button" className={`chip${src === "bangumi" ? " on" : ""}`} onClick={() => setSrc("bangumi")}>
          Bangumi
        </button>
        <button type="button" className={`chip${src === "trakt" ? " on" : ""}`} onClick={() => setSrc("trakt")}>
          Trakt
        </button>
        <button type="button" className={`chip${onlyMine ? " on" : ""}`} onClick={() => setOnlyMine((v) => !v)}>
          只看在追
        </button>
      </div>

      <div className="cal-wk">
        <button type="button" className="btn ghost" onClick={() => setWeekOffset((w) => w - 1)}>上一周</button>
        <span className="dim">
          {weekOffset === 0 ? "本周" : `${week[0].getMonth() + 1}/${week[0].getDate()} 起`}
        </span>
        <button type="button" className="btn ghost" onClick={() => setWeekOffset((w) => w + 1)}>下一周</button>
      </div>

      {err ? (
        <div className="empty"><b>加载失败</b><div className="dim">{err}</div></div>
      ) : !entries ? (
        <div className="empty"><div className="dim">加载中…</div></div>
      ) : (
        week.map((d, i) => (
          <section
            key={dayKey(d)}
            className={`cal-day${i === todayIdx ? " today" : ""}`}
            /* 今天那一段自动滚进视口。★ block:"start" 而不是 "center" ——
               center 会把它顶到屏幕中间,上面留一大片空白像是没加载出来。 */
            ref={i === todayIdx ? (el) => el?.scrollIntoView({ block: "start" }) : undefined}
          >
            <h2>
              {WEEKDAYS[i]}
              <span className="dim"> {d.getMonth() + 1}/{d.getDate()}</span>
              {i === todayIdx && <span className="cal-badge">今天</span>}
            </h2>
            {/* ★ dayCmp 按**真实日期**比,不能用 `i - todayIdx`:翻到上一周时 todayIdx 是 -1,
                   那个式子恒为正 → 整周都被判成"还没播",而它们其实早播完了。
                   这类"只在非当前周才错"的 bug 在当周截图上完全看不出来。
                ★ 必须 `new Date(d)` 再 setHours —— setHours 是**原地修改**,
                   直接对 d 下手会把 useMemo 缓存的那个 week 数组里的日期改掉,
                   下次渲染整周就偏了。 */}
            {!cols[i]?.length ? (
              <div className="cal-none dim">没有更新</div>
            ) : (
              cols[i].map((ev, k) => {
                const st = statusOf(
                  ev.time,
                  nowMin,
                  Math.sign(new Date(d).setHours(0, 0, 0, 0) - todayMs),
                );
                return (
                  <div key={`${ev.entry.title}:${k}`} className={`cal-it ${st}`}>
                    <div className="cal-th">
                      {ev.entry.image_url && (
                        <img src={ev.entry.image_url} alt="" loading="lazy" decoding="async" />
                      )}
                    </div>
                    <div className="cal-t">
                      {/* ★ 标题**不做 line-clamp** —— 截成「…」等于显示不全。
                          PC 端评审时用户明确纠正过这条,手机屏更窄,更该放开换行。 */}
                      <div className="cal-n">{ev.entry.title}</div>
                      <div className="cal-m dim">
                        {[
                          /* ev.time 已经是本地 "hh:mm" 字符串(groupByWeek 里换算好的),
                             别再 new Date 包一层 —— 那会按 UTC 再挪一次时区。 */
                          ev.time,
                          ev.entry.subtitle,
                          /* ★ rating 为 null 是「没人评过」,**不是 0 分** —— 别画成 0.0 */
                          ev.entry.rating != null ? `★ ${ev.entry.rating.toFixed(1)}` : null,
                        ].filter(Boolean).join(" · ")}
                      </div>
                    </div>
                  </div>
                );
              })
            )}
          </section>
        ))
      )}
    </div>
  );
}
