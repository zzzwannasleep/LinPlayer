import { useCallback, useEffect, useRef, useState } from "react";
import {
  type AccountInfo,
  type ServerLine,
  listAccounts,
  probeLine,
  setActiveLine,
  setLines,
  syncLines,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon, iconNode } from "../app/icons";
import { haptic, menu, toast } from "../app/motion";
import Page, { BarButton } from "../components/Page";
import Sheet from "../components/Sheet";
import { Empty } from "../components/ui";
import { Field } from "../components/SourceForm";

/* 服务器线路。**独立一页**,不是弹窗 —— 排序要拖,拖需要整块可用面积。

   ★ 活跃线路跟 **URL** 走,不跟数组下标走:排完序下标全变了,
     跟下标的话"当前线路"会莫名其妙指到另一条上。
   ★ 最后一条线路不能删 —— 删光了这台服务器就没有地址了。

   ═══ 2026-08-01 这一版改的三件事(用户点名) ═══

   ★ **上下按钮换成长按拖拽。** 上一版的注释里写着"拖拽和长按会打架,所以用按钮" ——
     那个结论只在「长按菜单和拖拽是两套独立监听」时成立。这一版把长按和拖拽做成
     **同一个 pointer 手势**(长按 420ms 抬起 → 之后的 move 就是拖),
     并且 `setPointerCapture` 把后续事件锁在这一行上,根本不存在两套监听互相取消的问题。
     行上的菜单挪到右侧那个 ⋮ 按钮,和拖拽在空间上分开。

   ★ **进页面就自动测速,不用点。** 逐条发(`probe_line`),谁先回谁先显示 ——
     整表 `probe_lines` 要等最慢那条(最坏 6s)才一起返回,一条死线就把整屏扣住。

   ★ **底部那段"说明"整块删掉。** 它讲的是"延迟低不等于播得稳",而这一页
     每行右边就写着延迟数字 —— 说明文字没有给出任何行动指引。 */

/** 按住多久算"要拖了"。420ms:比 iOS 的 500ms 略快(手机上排序是明确意图,
 *  不需要那么长的确认),又远大于误触的 200ms。 */
const LIFT_MS = 420;
/** 按住期间手指走过这么多像素就判定是"在滚页面",取消拖拽意图。 */
const SLOP = 10;

export default function LinesPage({ serverId }: { serverId?: string }) {
  const { back } = useCtx();
  const [acc, setAcc] = useState<AccountInfo | null>(null);
  const [rows, setRows] = useState<ServerLine[]>([]);
  /** 活跃线路的 **URL**(不是下标) */
  const [activeUrl, setActiveUrl] = useState("");
  /** 下标 → 延迟。undefined=还没测,null=不通,数字=毫秒 */
  const [ms, setMs] = useState<Record<number, number | null>>({});
  const [probing, setProbing] = useState(false);
  const [busy, setBusy] = useState("");
  const [edit, setEdit] = useState<null | { line: ServerLine | null; index: number }>(null);

  const load = useCallback(
    () =>
      listAccounts()
        .then((as) => {
          const me = as.find((a) => a.server === serverId) ?? as.find((a) => a.active) ?? as[0];
          if (!me) return null;
          setAcc(me);
          setRows(me.lines);
          setActiveUrl(me.lines[me.active_line]?.url ?? me.line_url);
          return me;
        })
        .catch((e) => {
          toast(String(e), "bad");
          return null;
        }),
    [serverId],
  );

  /* 逐条测速。★ 不用 probe_lines(整表) —— 它要等最慢的那条才返回,
     一条死线 = 整屏六秒空白。逐条发的话死线只是它自己那一行慢慢转。
     ★ `alive` 守卫:测速在飞的时候用户可能已经退页 / 重排过,
       回来的结果对不上号,直接丢掉比写进去强。 */
  const probeSeq = useRef(0);
  const probeAll = useCallback((server: string, n: number) => {
    if (!n) return;
    const my = ++probeSeq.current;
    setMs({});
    setProbing(true);
    let left = n;
    for (let i = 0; i < n; i++) {
      probeLine(server, i)
        .then((p) => {
          if (my !== probeSeq.current) return;
          setMs((m) => ({ ...m, [p.index]: p.ms }));
        })
        .catch(() => {
          if (my !== probeSeq.current) return;
          setMs((m) => ({ ...m, [i]: null }));
        })
        .finally(() => {
          if (my !== probeSeq.current) return;
          if (--left === 0) setProbing(false);
        });
    }
  }, []);

  useEffect(() => {
    load().then((me) => me && probeAll(me.server, me.lines.length));
  }, [load, probeAll]);

  /** 落盘。★ 顺序:整表覆写 → 再切生效线路(按 URL 找回新下标)。 */
  const persist = (next: ServerLine[], nextActiveUrl: string, reprobe = false) => {
    if (!acc) return;
    const idx = Math.max(0, next.findIndex((l) => l.url === nextActiveUrl));
    setBusy("save");
    setLines(acc.server, next)
      .then(() => setActiveLine(acc.server, idx))
      .then(() => {
        setRows(next);
        setActiveUrl(next[idx]?.url ?? nextActiveUrl);
        /* 行序变了,旧延迟按下标索引就全错位了。要么重测,要么清空 ——
           **绝不能留着**,留着的表现是"排完序每条线的延迟都换了个数"。 */
        if (reprobe) probeAll(acc.server, next.length);
        else setMs({});
      })
      .catch((e) => toast(String(e), "bad"))
      .finally(() => setBusy(""));
  };

  const del = (i: number) => {
    if (rows.length <= 1) {
      haptic("err");
      return toast("至少得留一条线路", "bad");
    }
    const gone = rows[i];
    const next = rows.filter((_, k) => k !== i);
    // 删掉的正好是生效那条 → 顺延到第一条
    persist(next, gone.url === activeUrl ? next[0].url : activeUrl, true);
  };

  /* ── 长按拖拽排序 ──
     全部状态放 ref:跟手期间每帧改的是 DOM 的 transform,不走 React
     (每帧一次 render 在安卓 WebView 上直接掉到 30fps)。
     松手时才把最终顺序交回 state。 */
  const listRef = useRef<HTMLDivElement>(null);
  const drag = useRef<{
    from: number;
    to: number;
    startY: number;
    h: number;
    els: HTMLElement[];
    lifted: boolean;
    timer: ReturnType<typeof setTimeout> | null;
    moved: boolean;
  } | null>(null);

  /* ★ 收参数,**不读 drag.current**。
     第一版是从 ref 里读的,而调用点(onRowUp)为了防重入已经先把 ref 置空了 ——
     于是这个函数每次都在开头 return,内联的 transform/transition **一次都没被清过**。
     后果不是"少了个动画":React 重排 DOM 之后,这些残留的 translateY 还按住旧位置,
     数据明明已经换序,屏幕上却像什么都没发生。 */
  const clearDragStyles = (d: { els: HTMLElement[] } | null) => {
    if (!d) return;
    d.els.forEach((el) => {
      el.style.transform = "";
      el.style.transition = "";
      el.classList.remove("dragging");
    });
  };

  const onRowDown = (i: number) => (e: React.PointerEvent<HTMLDivElement>) => {
    if (rows.length < 2) return; // 只有一条线路,没有"排序"这回事
    const host = listRef.current;
    if (!host) return;
    const els = [...host.querySelectorAll<HTMLElement>(".ln")];
    const self = els[i];
    if (!self) return;
    const d = {
      from: i,
      to: i,
      startY: e.clientY,
      h: self.getBoundingClientRect().height,
      els,
      lifted: false,
      moved: false,
      timer: null as ReturnType<typeof setTimeout> | null,
    };
    drag.current = d;
    d.timer = setTimeout(() => {
      if (!drag.current || drag.current !== d) return;
      d.lifted = true;
      haptic("sel");
      /* 抬起来之后才 setPointerCapture:提前捕获会把还没判定成拖拽的手势
         也锁在这一行上,页面就滚不动了。
         ★ 必须 try 住:指针在这 420ms 里已经抬起 / 被系统收走时,
           setPointerCapture 会抛 NotFoundError。**抛出去就等于后面两行不执行** ——
           `dragging` 类加不上,那一行拖起来完全没有视觉反馈(而位置其实在跟手动),
           用户看到的是"按住之后什么都没发生,但松手顺序变了"。
           捕获失败本身无害(pointermove 仍然会落在这一行上),不该连带毁掉视觉。 */
      try {
        self.setPointerCapture?.(e.pointerId);
      } catch {
        /* 捕获不到就算了 —— 见上 */
      }
      self.classList.add("dragging");
      els.forEach((el) => (el.style.transition = el === self ? "none" : "transform 160ms ease"));
    }, LIFT_MS);
  };

  const onRowMove = (e: React.PointerEvent<HTMLDivElement>) => {
    const d = drag.current;
    if (!d) return;
    const dy = e.clientY - d.startY;
    if (!d.lifted) {
      // 还没抬起来就动了 = 用户在滚页面,取消拖拽意图(也顺带取消"这是一次点击")
      if (Math.abs(dy) > SLOP) {
        if (d.timer) clearTimeout(d.timer);
        drag.current = null;
      }
      return;
    }
    d.moved = true;
    const self = d.els[d.from];
    self.style.transform = `translateY(${dy}px)`;
    /* 目标位置 = 位移换算成"跨过了几行"。用行高做换算(各行高度接近),
       比逐行量 rect 便宜得多,而且拖动中的视觉反馈本来就允许 ±几像素的误差。 */
    const to = Math.max(0, Math.min(d.els.length - 1, d.from + Math.round(dy / d.h)));
    if (to === d.to) return;
    d.to = to;
    haptic("tap");
    d.els.forEach((el, k) => {
      if (k === d.from) return;
      let shift = 0;
      if (d.from < to && k > d.from && k <= to) shift = -d.h;
      else if (d.from > to && k >= to && k < d.from) shift = d.h;
      el.style.transform = shift ? `translateY(${shift}px)` : "";
    });
  };

  const onRowUp = (i: number) => () => {
    const d = drag.current;
    drag.current = null;
    if (!d) return;
    if (d.timer) clearTimeout(d.timer);
    if (!d.lifted) {
      // 没抬起来 = 这是一次普通点击 → 选这条线路
      if (!d.moved && rows[i] && rows[i].url !== activeUrl) {
        haptic("sel");
        persist(rows, rows[i].url);
      }
      return;
    }
    clearDragStyles(d);
    if (d.to === d.from) return;
    const next = rows.slice();
    const [x] = next.splice(d.from, 1);
    next.splice(d.to, 0, x);
    haptic("ok");
    persist(next, activeUrl, true);
  };

  const lvl = (v: number | null | undefined) =>
    v == null ? "" : v < 50 ? "good" : v < 150 ? "mid" : "bad";

  return (
    <Page
      title="服务器线路"
      sub={acc?.name}
      onBack={back}
      right={
        <>
          <BarButton
            icon="sync"
            label="同步线路"
            onClick={() => {
              if (!acc) return;
              setBusy("sync");
              haptic("tap");
              syncLines(acc.server)
                .then((r) => {
                  /* ★ `supported:false` 是**常态**(绝大多数服务器没装 emby_ext_domains),
                     不是错误 —— 别弹红。 */
                  if (!r.supported) {
                    toast("这台服务器没提供线路表(服主未部署 emby_ext_domains),线路请手动加", "warn");
                    return;
                  }
                  toast(r.added ? `已同步 ${r.added} 条新线路(共 ${r.total} 条)` : `线路已是最新(共 ${r.total} 条)`, "ok");
                  return load().then((me) => me && probeAll(me.server, me.lines.length));
                })
                .catch((e) => toast(String(e), "bad"))
                .finally(() => setBusy(""));
            }}
          />
          <BarButton icon="plus" label="添加线路" onClick={() => setEdit({ line: null, index: -1 })} />
        </>
      }
      enterKey={rows}
    >
      {!acc ? (
        <div className="pad dim" style={{ fontSize: 13 }}>加载中…</div>
      ) : !rows.length ? (
        <Empty
          icon="line"
          title="这台服务器只有一个地址"
          desc="线路是同一台服务器的多个入口(内网 / 公网 / CDN)。加一条之后可以按延迟挑最快的。"
          action={{ label: "添加线路", on: () => setEdit({ line: null, index: -1 }) }}
        />
      ) : (
        <div className="ln-list" ref={listRef}>
          {rows.map((l, i) => (
            <LnRow
              key={l.id || l.url}
              l={l}
              i={i}
              active={l.url === activeUrl}
              ms={ms[i]}
              lvl={lvl(ms[i])}
              onDown={onRowDown(i)}
              onMove={onRowMove}
              onUp={onRowUp(i)}
              onMenu={(x, y) =>
                menu(x, y, [
                  { icon: iconNode("check", 18), label: "设为生效线路", on: () => persist(rows, l.url) },
                  { icon: iconNode("pencil", 18), label: "编辑", on: () => setEdit({ line: l, index: i }) },
                  {
                    icon: iconNode("refresh", 18),
                    label: "重测这一条",
                    on: () => {
                      if (!acc) return;
                      // 删 key 而不是写 undefined —— 那一行要回到"转圈"态,不是"不通"
                      setMs((m) => {
                        const n = { ...m };
                        delete n[i];
                        return n;
                      });
                      probeLine(acc.server, i)
                        .then((p) => setMs((m) => ({ ...m, [p.index]: p.ms })))
                        .catch(() => setMs((m) => ({ ...m, [i]: null })));
                    },
                  },
                  "-",
                  { icon: iconNode("trash", 18), label: "删除", bad: true, on: () => del(i) },
                ])
              }
            />
          ))}
        </div>
      )}

      {rows.length > 1 && (
        <div className="ln-hint">
          {probing ? "正在测速…" : busy === "save" ? "正在保存…" : "长按一条可以拖动排序"}
        </div>
      )}
      {busy === "sync" && (
        <div className="pad dim" style={{ fontSize: 12.5 }}>正在向服务器要线路表…</div>
      )}

      {edit && (
        <LineEditDialog
          line={edit.line}
          onClose={() => setEdit(null)}
          onSave={(v) => {
            const next =
              edit.index < 0 ? [...rows, v] : rows.map((x, k) => (k === edit.index ? { ...x, ...v } : x));
            persist(next, activeUrl || next[0].url, true);
            setEdit(null);
          }}
        />
      )}
    </Page>
  );
}

function LnRow({
  l,
  i,
  active,
  ms,
  lvl,
  onDown,
  onMove,
  onUp,
  onMenu,
}: {
  l: ServerLine;
  i: number;
  active: boolean;
  ms: number | null | undefined;
  lvl: string;
  onDown: (e: React.PointerEvent<HTMLDivElement>) => void;
  onMove: (e: React.PointerEvent<HTMLDivElement>) => void;
  onUp: () => void;
  onMenu: (x: number, y: number) => void;
}) {
  return (
    <div
      className={`ln${active ? " on" : ""}`}
      style={{ ["--i" as string]: i }}
      onPointerDown={onDown}
      onPointerMove={onMove}
      onPointerUp={onUp}
      onPointerCancel={onUp}
    >
      <div className="ln-t">
        <div className="ln-n">
          {l.name || `线路 ${i + 1}`}
          {active && (
            <b className="tag acc" style={{ marginLeft: 6 }}>
              生效中
            </b>
          )}
        </div>
        {/* ★ 这一行原来画的是 `l.url`。地址一律不显示(用户 2026-08-02),
            第二行改成**备注** —— 那才是用户自己写的、用来认它的东西。
            没有备注就整行不画,不拿地址来凑。 */}
        {l.remark ? <div className="ln-u">{l.remark}</div> : null}
      </div>
      {/* 延迟:数字之外再给一个能扫的颜色。
          ★ 三种状态必须分得开:undefined=**还在测**(转圈,不是"没有")、
            null=**不通**、数字=毫秒。上一版把"还在测"画成一个 —— 号,
            和"测出来是空的"长得一模一样。 */}
      <div className={`ping ${ms === null ? "bad" : lvl}`}>
        {ms === undefined ? (
          <span className="ping-wait" aria-label="测速中" />
        ) : ms === null ? (
          <b>不通</b>
        ) : (
          <>
            <b>{ms}</b>
            <span>ms</span>
          </>
        )}
      </div>
      <button
        type="button"
        className="ln-more"
        aria-label="更多"
        /* ★ 必须掐掉冒泡:不掐的话按 ⋮ 会同时触发行上的 pointerdown,
           按住不放 420ms 就抬起来开始拖了。 */
        onPointerDown={(e) => e.stopPropagation()}
        onPointerUp={(e) => e.stopPropagation()}
        onClick={(e) => {
          e.stopPropagation();
          const r = e.currentTarget.getBoundingClientRect();
          onMenu(r.left + r.width / 2, r.bottom);
        }}
      >
        <Icon n="more" size={18} />
      </button>
    </div>
  );
}

function LineEditDialog({
  line,
  onClose,
  onSave,
}: {
  line: ServerLine | null;
  onClose: () => void;
  onSave: (l: ServerLine) => void;
}) {
  const [name, setName] = useState(line?.name ?? "");
  const [url, setUrl] = useState(line?.url ?? "");
  const [remark, setRemark] = useState(line?.remark ?? "");
  return (
    <Sheet open onClose={onClose} title={line ? "编辑线路" : "添加线路"}>
      <div className="pad">
        <Field label="线路名称" placeholder="比如「内网直连」「公网 CDN」" value={name} onChange={setName} />
        <Field
          label="地址"
          type="url"
          placeholder="https://emby.example.com:8920"
          value={url}
          onChange={setUrl}
          required
          reqKey="url"
        />
        <Field label="备注(可留空)" placeholder="比如「只有连了 WiFi 才通」" value={remark} onChange={setRemark} />
      </div>
      <div className="sheet-acts">
        <button type="button" className="btn ghost" onClick={onClose}>
          取消
        </button>
        <button
          type="button"
          className="btn primary"
          onClick={() => {
            const u = url.trim();
            if (!u) {
              haptic("err");
              return toast("地址不能空", "bad");
            }
            /* ★ new URL() 对 "emby.example.com" 这种没协议的串会**抛异常**,
               不接住的话点保存整个弹窗白屏(错误边界接管),而用户只是少打了 https://。 */
            let host = u;
            try {
              host = new URL(u).host;
            } catch {
              haptic("err");
              return toast("地址要带 http:// 或 https://", "bad");
            }
            onSave({
              id: line?.id ?? "",
              name: name.trim() || host,
              url: u.replace(/\/+$/, ""), // 尾斜杠会让核层拼出双斜杠的 URL
              remark: remark.trim() || null,
            });
          }}
        >
          保存
        </button>
      </div>
    </Sheet>
  );
}
