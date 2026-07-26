import { useSourceForms } from "../../desktop/pages/sources/sourceForms";

/* 首启闸口 —— 一台源都没有时的那一屏。

   ★ 表单**不重写**,用 `useSourceForms` 那一份。
     那个 hook 是三端共用的数据源表单实现,页面只负责摆版式(它自己的注释就是这么写的)。
     手机端再抄一份的下场:新增一个源类型时改了 PC、漏了手机,
     手机用户永远看不到那个源,**而且两边都不报错** —— 这是本仓库的头号高发病。
     加源请改 sourceForms.tsx 的 BUILTIN_SOURCES,改那一处,三端同时生效。

   ★ 手机版式与 PC 的差异:
     - 不做居中卡片:手机屏幕本来就窄,再套一层卡片只剩一条缝
     - 源芯片横滑一行(插件源数量是运行时才知道的,换行会让高度抖)
     - 主按钮**吸在底部安全区上方** —— 键盘升起时表单会滚动,
       按钮跟着滚出屏幕的话用户得先收键盘才能提交,那是每次登录都要多做一次的动作 */

const EXCLUDE = [
  /* 批量粘贴导入:手机上没有"从别处复制一大段配置"的场景(那是 PC 换机时的路子),
     而手机有更好的解:扫码搬配置(qrsync,留着)。 */
  "batch",
];

export default function LoginPage({ onLoggedIn }: { onLoggedIn: () => void }) {
  const f = useSourceForms({ exclude: EXCLUDE, onDone: onLoggedIn });

  return (
    <div className="login">
      <div className="lg-top">
        <div className="lg-brand">
          Lin<span>Player</span>
        </div>
        <div className="lg-h1">添加第一个片源</div>
      </div>

      <div className="chips lg-chips">
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

      {/* key 挂在 sel 上:换源等于换一整套字段,让 React 重建这棵子树,淡入自然重放 */}
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
        {f.primary("添加并进入")}
      </div>

      {f.deepDialog}
      {f.toast && <div className="toast">{f.toast}</div>}
    </div>
  );
}
