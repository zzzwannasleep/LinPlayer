import { useRef, useState } from "react";
import { haptic, toast } from "../app/motion";
import {
  KIND_QR,
  SourceForm,
  SrcPicker,
  checkRequired,
  emptyForm,
  submitSource,
  type FormState,
} from "../components/SourceForm";

/* 首启闸口 —— 一台源都没有时的那一屏。

   ★ 它就是**添加服务器页的另一种版式**,表单共用 `components/SourceForm`。
     抄一份的下场:新增一个源类型时改了添加页、漏了这里,而**两边都不报错** ——
     这是本仓库的头号高发病。加源只改 SourceForm 里的 `SOURCE_KINDS` 一处。

   ★ 手机版式与 PC 的差异:
     - 不做居中卡片:手机屏幕本来就窄,再套一层卡片只剩一条缝
     - 源类型是**分组网格**(和添加页一致),不是横滑 chip
     - 主按钮**吸在底部安全区上方** —— 键盘升起时表单会滚动,
       按钮跟着滚出屏幕的话用户得先收键盘才能提交,那是每次登录都要多做一次的动作 */

/** 批量粘贴导入:第一次装 App 时没有"从别处复制一大段配置"的场景(那是 PC 换机的路子),
 *  而手机有更好的解 —— 扫码搬配置(qrsync,留着)。 */
const EXCLUDE = ["batch"];

export default function LoginPage({ onLoggedIn }: { onLoggedIn: () => void }) {
  const [kind, setKind] = useState("emby");
  const [f, setF] = useState<FormState>(emptyForm);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const pane = useRef<HTMLDivElement>(null);
  const set = (p: Partial<FormState>) => setF((s) => ({ ...s, ...p }));

  const hasConnect = !KIND_QR.has(kind) && kind !== "qrsync";

  return (
    <div className="login">
      <div className="lg-top">
        <div className="lg-brand">
          Lin<span>Player</span>
        </div>
        <div className="lg-h1">添加第一个片源</div>
        <div className="lg-p">Emby、飞牛、各家网盘都行 —— 先加一个,后面还能再加。</div>
      </div>

      <div className="lg-body">
        <SrcPicker
          cur={kind}
          exclude={EXCLUDE}
          onPick={(id) => {
            setKind(id);
            setF(emptyForm());
            setErr("");
          }}
        />

        {/* key 挂在 kind 上:换源等于换一整套字段,让 React 重建这棵子树,淡入自然重放 */}
        <div className="lg-pane" key={kind} ref={pane}>
          {err && (
            <div className="bad" onClick={() => setErr("")}>
              <b>连接失败</b>
              <div>{err}</div>
            </div>
          )}
          <SourceForm kind={kind} f={f} set={set} />
        </div>
      </div>

      {hasConnect && (
        <div className="lg-acts">
          <button
            type="button"
            className="btn primary"
            disabled={busy}
            onClick={async () => {
              // ★ 本地校验先跑,过了才发请求 —— 等服务端回来才说"名字没填"是白等一趟网络
              if (!checkRequired(pane.current)) return;
              setBusy(true);
              setErr("");
              haptic("tap");
              try {
                await submitSource(kind, f);
                haptic("ok");
                toast("已添加", "ok");
                onLoggedIn();
              } catch (e) {
                setErr(String(e));
              } finally {
                setBusy(false);
              }
            }}
          >
            {busy ? "连接中…" : "添加并进入"}
          </button>
        </div>
      )}
    </div>
  );
}
