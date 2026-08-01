import { useRef, useState } from "react";
import { Icon } from "../app/icons";
import { haptic, toast } from "../app/motion";
import {
  KIND_QR,
  SourceForm,
  SrcCats,
  SrcKinds,
  checkRequired,
  emptyForm,
  kindsOf,
  submitSource,
  type FormState,
} from "../components/SourceForm";

/* 首启闸口 —— 一台源都没有时的那一屏。

   ★ 它就是**添加服务器页的另一种版式**,表单共用 `components/SourceForm`。
     抄一份的下场:新增一个源类型时改了添加页、漏了这里,而**两边都不报错** ——
     这是本仓库的头号高发病。加源只改 SourceForm 里的 `SOURCE_KINDS` 一处。

   ★ 手机版式与 PC 的差异:
     - 不做居中卡片:手机屏幕本来就窄,再套一层卡片只剩一条缝
     - 主按钮**吸在底部安全区上方** —— 键盘升起时表单会滚动,
       按钮跟着滚出屏幕的话用户得先收键盘才能提交

   ═══ 2026-08-02 改成分步(用户点名,和添加服务器页同一套)═══
   「『添加服务器』和『首次添加服务器』这两个页面的往下浏览布局很糟糕。
   应该改为分步引导:先让用户选择服务器类型,选择后再切到下一个页面。」
   上一版是 13 个源类型的网格 + 底下跟着表单,在 390px 的屏上选完还要
   往下滚一屏才看得见第一个输入框,而那 13 个格子全程占着版面。

   ★ 第一步**没有返回箭头** —— 这是首启,没有"上一页"可回。
     进到第二步之后才画一个,回到大类选择。 */

export default function LoginPage({ onLoggedIn }: { onLoggedIn: () => void }) {
  /** null = 还在第一步(选大类) */
  const [sec, setSec] = useState<string | null>(null);
  const [kind, setKind] = useState("emby");
  const [f, setF] = useState<FormState>(emptyForm);
  const [busy, setBusy] = useState(false);
  const [err, setErr] = useState("");
  const pane = useRef<HTMLDivElement>(null);
  const set = (p: Partial<FormState>) => setF((s) => ({ ...s, ...p }));

  const hasConnect = !KIND_QR.has(kind);

  return (
    <div className="login">
      <div className="lg-top">
        {sec !== null && (
          <button
            type="button"
            className="tb-back"
            aria-label="返回上一步"
            style={{ marginLeft: -10, marginBottom: 4 }}
            onClick={() => {
              haptic("tap");
              setSec(null);
              setErr("");
            }}
          >
            <Icon n="back" size={24} />
          </button>
        )}
        <div className="lg-brand">
          Lin<span>Player</span>
        </div>
        <div className="lg-h1">{sec === null ? "添加第一个片源" : sec}</div>
        <div className="lg-p">
          {sec === null
            ? "Emby、飞牛、各家网盘都行 —— 先加一个,后面还能再加。"
            : "填完下面这几项就能进去了。"}
        </div>
      </div>

      <div className="lg-body">
        {sec === null ? (
          <SrcCats
            onPick={(s) => {
              setSec(s);
              setKind(kindsOf(s)[0]?.id ?? "emby");
              setF(emptyForm());
              setErr("");
            }}
          />
        ) : (
          <>
            <SrcKinds
              sec={sec}
              cur={kind}
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
          </>
        )}
      </div>

      {sec !== null && hasConnect && (
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
