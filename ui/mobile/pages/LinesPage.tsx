import { useEffect, useRef, useState } from "react";
import {
  type AccountInfo,
  type ServerLine,
  listAccounts,
  probeLines,
  setActiveLine,
  setLines,
  syncLines,
} from "@shared/api";
import { useCtx } from "../app/ctx";
import { Icon, iconNode } from "../app/icons";
import { haptic, menu, toast } from "../app/motion";
import Page, { BarButton } from "../components/Page";
import Sheet from "../components/Sheet";
import { Empty, Group } from "../components/ui";
import { Field } from "../components/SourceForm";

/* 服务器线路。**独立一页**,不是 bottom sheet ——
   sheet 的关闭手势就是往下拖,和拖排序叠在同一区域必然误关。
   (PC 端是弹窗内拖拽,桌面没有这个冲突。)

   ★ 活跃线路跟 **URL** 走,不跟数组下标走:排完序下标全变了,
     跟下标的话"当前线路"会莫名其妙指到另一条上。
   ★ 最后一条线路不能删 —— 删光了这台服务器就没有地址了。 */

export default function LinesPage({ serverId }: { serverId?: string }) {
  const { back } = useCtx();
  const [acc, setAcc] = useState<AccountInfo | null>(null);
  const [rows, setRows] = useState<ServerLine[]>([]);
  /** 活跃线路的 **URL**(不是下标) */
  const [activeUrl, setActiveUrl] = useState("");
  const [ms, setMs] = useState<Record<number, number | null>>({});
  const [busy, setBusy] = useState("");
  const [edit, setEdit] = useState<null | { line: ServerLine | null; index: number }>(null);
  const listRef = useRef<HTMLDivElement>(null);

  const load = () =>
    listAccounts()
      .then((as) => {
        const me = as.find((a) => a.server === serverId) ?? as.find((a) => a.active) ?? as[0];
        if (!me) return;
        setAcc(me);
        setRows(me.lines);
        setActiveUrl(me.lines[me.active_line]?.url ?? me.line_url);
      })
      .catch((e) => toast(String(e), "bad"));

  useEffect(() => {
    load();
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [serverId]);

  /** 落盘。★ 顺序:整表覆写 → 再切生效线路(按 URL 找回新下标)。 */
  const persist = (next: ServerLine[], nextActiveUrl: string) => {
    if (!acc) return;
    const idx = Math.max(0, next.findIndex((l) => l.url === nextActiveUrl));
    setBusy("save");
    setLines(acc.server, next)
      .then(() => setActiveLine(acc.server, idx))
      .then(() => {
        setRows(next);
        setActiveUrl(next[idx]?.url ?? nextActiveUrl);
        setMs({}); // 行序变了,旧延迟对不上号,清掉比留着错位强
      })
      .catch((e) => toast(String(e), "bad"))
      .finally(() => setBusy(""));
  };

  const move = (from: number, to: number) => {
    if (to < 0 || to >= rows.length || from === to) return;
    const next = rows.slice();
    const [x] = next.splice(from, 1);
    next.splice(to, 0, x);
    haptic("sel");
    persist(next, activeUrl);
  };

  const del = (i: number) => {
    if (rows.length <= 1) {
      haptic("err");
      return toast("至少得留一条线路", "bad");
    }
    const gone = rows[i];
    const next = rows.filter((_, k) => k !== i);
    // 删掉的正好是生效那条 → 顺延到第一条
    persist(next, gone.url === activeUrl ? next[0].url : activeUrl);
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
                  return load();
                })
                .catch((e) => toast(String(e), "bad"))
                .finally(() => setBusy(""));
            }}
          />
          <BarButton
            icon="refresh"
            label="全部测速"
            onClick={() => {
              if (!acc) return;
              setBusy("probe");
              haptic("tap");
              probeLines(acc.server)
                .then((r) => {
                  const m: Record<number, number | null> = {};
                  for (const p of r) m[p.index] = p.ms; // ms=null 表示不通,**不是错误**
                  setMs(m);
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
        <div ref={listRef}>
          {rows.map((l, i) => (
            <LnRow
              key={l.id || l.url}
              l={l}
              i={i}
              active={l.url === activeUrl}
              ms={ms[i]}
              lvl={lvl(ms[i])}
              onPick={() => {
                if (l.url === activeUrl) return;
                haptic("sel");
                persist(rows, l.url);
              }}
              onUp={() => move(i, i - 1)}
              onDown={() => move(i, i + 1)}
              onMenu={(x, y) =>
                menu(x, y, [
                  { icon: iconNode("check", 18), label: "设为生效线路", on: () => persist(rows, l.url) },
                  { icon: iconNode("pencil", 18), label: "编辑", on: () => setEdit({ line: l, index: i }) },
                  { icon: iconNode("back", 18), label: "上移", on: () => move(i, i - 1) },
                  { icon: iconNode("chevR", 18), label: "下移", on: () => move(i, i + 1) },
                  "-",
                  { icon: iconNode("trash", 18), label: "删除", bad: true, on: () => del(i) },
                ])
              }
            />
          ))}
        </div>
      )}

      <Group title="说明">
        <div className="note-box">
          线路是**同一台服务器的多个入口**(内网直连 / 公网 / CDN 反代)。延迟低的不一定播得稳 ——
          带宽和延迟是两回事。卡了就换一条试试,切换是即时的,不用重登。
        </div>
      </Group>

      {busy && (
        <div className="pad dim" style={{ fontSize: 12.5 }}>
          {busy === "probe" ? "正在逐条测速…" : busy === "sync" ? "正在向服务器要线路表…" : "正在保存…"}
        </div>
      )}

      {edit && (
        <LineEditSheet
          line={edit.line}
          onClose={() => setEdit(null)}
          onSave={(v) => {
            const next =
              edit.index < 0 ? [...rows, v] : rows.map((x, k) => (k === edit.index ? { ...x, ...v } : x));
            persist(next, activeUrl || next[0].url);
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
  onPick,
  onUp,
  onDown,
  onMenu,
}: {
  l: ServerLine;
  i: number;
  active: boolean;
  ms: number | null | undefined;
  lvl: string;
  onPick: () => void;
  onUp: () => void;
  onDown: () => void;
  onMenu: (x: number, y: number) => void;
}) {
  const timer = { t: 0 as ReturnType<typeof setTimeout> | 0 };
  const fired = { v: false };
  return (
    <div
      className={`ln${active ? " on" : ""}`}
      style={{ ["--i" as string]: i }}
      onPointerDown={(e) => {
        fired.v = false;
        const x = e.clientX;
        const y = e.clientY;
        timer.t = setTimeout(() => {
          fired.v = true;
          haptic("sel");
          onMenu(x, y);
        }, 480);
      }}
      onPointerUp={() => timer.t && clearTimeout(timer.t)}
      onPointerCancel={() => timer.t && clearTimeout(timer.t)}
      onPointerMove={() => timer.t && clearTimeout(timer.t)}
      onClick={() => !fired.v && onPick()}
    >
      {/* ★ 排序手柄用两个按钮,不做拖拽。
          草稿里是拖拽,而拖拽和行上的长按叠在同一区域会打架:longPress 只在
          「元素**自己**收到 pointermove 且位移 >10px」时取消,而拖拽的 move 挂在
          document 上 —— 按住手柄不动 480ms 菜单就弹出来了,拖排序当场废掉。
          上下按钮没有这个冲突,而且在只有两三条线路时反而更快。 */}
      <div className="ln-grip">
        <button
          type="button"
          aria-label="上移"
          onClick={(e) => {
            e.stopPropagation();
            onUp();
          }}
        >
          <Icon n="back" size={14} />
        </button>
        <button
          type="button"
          aria-label="下移"
          onClick={(e) => {
            e.stopPropagation();
            onDown();
          }}
        >
          <Icon n="chevR" size={14} />
        </button>
      </div>
      <div className="ln-t">
        <div className="ln-n">
          {l.name || `线路 ${i + 1}`}
          {active && (
            <b className="tag acc" style={{ marginLeft: 6 }}>
              生效中
            </b>
          )}
        </div>
        <div className="ln-u">{l.url}</div>
        {l.remark ? <div className="ln-u">{l.remark}</div> : null}
      </div>
      {/* 延迟:数字之外再给一个能扫的颜色。ms===null 是**不通**,和"慢"是两件事。 */}
      <div className={`ping ${ms === null ? "bad" : lvl}`}>
        {ms === undefined ? <span className="ln-ms">—</span> : ms === null ? <b>不通</b> : <b>{ms}</b>}
        {typeof ms === "number" && <span>ms</span>}
      </div>
    </div>
  );
}

function LineEditSheet({
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
            if (!url.trim()) {
              haptic("err");
              return toast("地址不能空", "bad");
            }
            onSave({
              id: line?.id ?? "",
              name: name.trim() || new URL(url.trim()).host,
              url: url.trim().replace(/\/+$/, ""), // 尾斜杠会让核层拼出双斜杠的 URL
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
