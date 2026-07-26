import { useSourceForms } from "../../desktop/pages/sources/sourceForms";

/* 添加服务器 —— 和首启闸口(LoginPage)是**同一份表单**,只是版式不同。

   新增源类型请改 `sourceForms.tsx` 的 BUILTIN_SOURCES,改那一处三端同时生效。
   在这里另抄一份的下场:加了新源,PC 有、手机没有,而**两边都不报错**。 */

export default function AddServerPage({ onDone }: { onDone: () => void }) {
  const f = useSourceForms({ exclude: ["batch"], onDone });

  return (
    <div className="login as">
      <div className="chips">
        {f.sources.map((s) => (
          <button
            key={s.id}
            type="button"
            className={`chip${f.sel === s.id ? " on" : ""}`}
            onClick={() => {
              f.setSel(s.id);
              f.setErr("");
              f.setToast("");
            }}
          >
            {s.label}
          </button>
        ))}
      </div>

      <div className="lg-pane" key={f.sel}>
        {f.err && (
          <div className="bad" onClick={() => f.setErr("")}>
            <b>连接失败</b>
            <div>{f.err}</div>
          </div>
        )}
        {f.fields()}
      </div>

      <div className="lg-acts">
        {f.sel === "emby" && (
          <button type="button" className="btn ghost" disabled={f.busy} onClick={f.doTest}>
            {f.testState === "busy" ? "测试中…" : f.testState === "ok" ? "✓ 连接成功" : "测试连接"}
          </button>
        )}
        {f.primary("添加")}
      </div>

      {f.deepDialog}
      {f.toast && <div className="toast">{f.toast}</div>}
    </div>
  );
}
