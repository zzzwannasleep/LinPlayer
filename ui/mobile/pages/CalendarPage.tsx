import { useEffect, useMemo, useState } from "react";
import { type CalendarEntry, bangumiCalendar, traktCalendar } from "@shared/api";
import { dayKey, groupByWeek, statusOf, weekOf, weekdayIndex } from "@shared/calendar-grouping";
import { useCtx } from "../app/ctx";
import { Icon } from "../app/icons";
import { haptic } from "../app/motion";
import Page from "../components/Page";
import { Empty, usePress } from "../components/ui";

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
  const { back } = useCtx();
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

  const last = week[6];
  const range = `${week[0].getMonth() + 1} 月 ${week[0].getDate()} 日 – ${last.getMonth() + 1} 月 ${last.getDate()} 日`;

  return (
    <Page title="追剧日历" onBack={back} enterKey={entries}>
      <div className="cal">
        <div className="cal-nav">
          <NavBtn icon="back" label="上一周" onClick={() => setWeekOffset((w) => w - 1)} />
          <div className="cal-range">{weekOffset === 0 ? `本周 · ${range}` : range}</div>
          <NavBtn icon="chevR" label="下一周" onClick={() => setWeekOffset((w) => w + 1)} />
        </div>

        <div className="chips">
          <Chip on={src === "bangumi"} label="Bangumi" onClick={() => setSrc("bangumi")} />
          <Chip on={src === "trakt"} label="Trakt" onClick={() => setSrc("trakt")} />
          <Chip on={onlyMine} label="只看在追" onClick={() => setOnlyMine((v) => !v)} />
        </div>

        {err ? (
          <Empty icon="calendar" title="放送表取不到" desc={err} />
        ) : !entries ? (
          <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
        ) : (
          week.map((d, i) => (
            <div
              key={dayKey(d)}
              className={`cal-day${i === todayIdx ? " today" : ""}`}
              /* 今天那一段自动滚进视口。★ block:"start" 而不是 "center" ——
                 center 会把它顶到屏幕中间,上面留一大片空白像是没加载出来。 */
              ref={i === todayIdx ? (el) => el?.scrollIntoView({ block: "start" }) : undefined}
            >
              <div className="cal-d">
                <div className="cal-dn">{WEEKDAYS[i]}</div>
                <div className="cal-dd">
                  {d.getMonth() + 1}/{d.getDate()}
                </div>
              </div>
              <div className="cal-list">
                {/* ★ dayCmp 按**真实日期**比,不能用 `i - todayIdx`:翻到上一周时 todayIdx 是 -1,
                       那个式子恒为正 → 整周都被判成"还没播",而它们其实早播完了。
                       这类"只在非当前周才错"的 bug 在当周截图上完全看不出来。
                    ★ 必须 `new Date(d)` 再 setHours —— setHours 是**原地修改**,
                       直接对 d 下手会把 useMemo 缓存的那个 week 数组里的日期改掉,
                       下次渲染整周就偏了。 */}
                {!cols[i]?.length ? (
                  <div className="cal-empty">今天没有更新</div>
                ) : (
                  cols[i].map((ev, k) => {
                    const st = statusOf(ev.time, nowMin, Math.sign(new Date(d).setHours(0, 0, 0, 0) - todayMs));
                    return (
                      <div
                        key={`${ev.entry.title}:${k}`}
                        className={`cal-it${st === "past" ? " done" : st === "soon" ? " soon" : ""}`}
                      >
                        {/* ★ 标题**不做 line-clamp** —— 截成「…」等于显示不全。
                            PC 端评审时用户明确纠正过这条,手机屏更窄,更该放开换行。 */}
                        <div className="t">
                          {ev.entry.title}
                          {ev.entry.subtitle ? ` · ${ev.entry.subtitle}` : ""}
                        </div>
                        <div className="h">
                          {/* ev.time 已经是本地 "hh:mm" 字符串(groupByWeek 里换算好的),
                              别再 new Date 包一层 —— 那会按 UTC 再挪一次时区。
                              ★ rating 为 null 是「没人评过」,**不是 0 分** —— 别画成 0.0 */}
                          {[ev.time, ev.entry.rating != null ? `★ ${ev.entry.rating.toFixed(1)}` : null]
                            .filter(Boolean)
                            .join(" · ")}
                        </div>
                      </div>
                    );
                  })
                )}
              </div>
            </div>
          ))
        )}
      </div>
    </Page>
  );
}

function NavBtn({ icon, label, onClick }: { icon: string; label: string; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button
      type="button"
      aria-label={label}
      ref={ref}
      onClick={() => {
        haptic("tap");
        onClick();
      }}
    >
      <Icon n={icon} size={18} />
    </button>
  );
}

function Chip({ on, label, onClick }: { on?: boolean; label: string; onClick: () => void }) {
  const ref = usePress<HTMLButtonElement>();
  return (
    <button
      type="button"
      className={`chip${on ? " on" : ""}`}
      ref={ref}
      onClick={() => {
        haptic("sel");
        onClick();
      }}
    >
      {label}
    </button>
  );
}
