import { useRef, useState } from "react";
import { useCtx } from "../app/ctx";
import { haptic, menu, toast } from "../app/motion";
import { iconNode } from "../app/icons";
import Page, { BarButton } from "../components/Page";
import Sheet from "../components/Sheet";
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

/* 添加服务器 —— 和首启闸口(LoginPage)、重新登录用**同一份表单**
   (`components/SourceForm`),只是版式不同。抄两份的话新增源类型会改一处漏一处。

   ═══ 2026-08-02 改成分步(用户点名) ═══
   用户原话:「『添加服务器』和『首次添加服务器』这两个页面的往下浏览布局很糟糕。
   应该改为分步引导:先让用户选择服务器类型(媒体服务器 / 网盘·文件源),
   选择后再切到下一个页面,直接让用户输入名称、地址、用户名和密码。
   批量添加统一收纳到右上角。」

   上一版是**一屏到底**:13 个源类型的网格 + 底下跟着表单。在 390px 的屏上
   那是三排格子,选完还要往下滚一屏才看得见第一个输入框;而且那 13 个格子
   在填字段的全程都占着版面,纯干扰。

   ★ 两步之间**不压路由栈**:压了的话安卓返回键要按两下才回得到服务器页,
     而用户心里的返回目标始终是"上一步"。这里用 `sec` 一个 state 做分步,
     返回箭头自己判断该退一步还是退整页。 */

export default function AddServerPage() {
  const { back, reloadGate } = useCtx();
  /** null = 还在第一步(选大类) */
  const [sec, setSec] = useState<string | null>(null);
  const [kind, setKind] = useState("emby");
  const [f, setF] = useState<FormState>(emptyForm);
  const [busy, setBusy] = useState(false);
  /** 右上角收纳的两个工具:批量粘贴 / 扫码搬配置 */
  const [tool, setTool] = useState<null | "batch" | "qrsync">(null);
  const pane = useRef<HTMLDivElement>(null);
  const set = (p: Partial<FormState>) => setF((s) => ({ ...s, ...p }));

  /* 扫码型在二维码里自己完成登录 —— 底部那条「连接」对它没意义,画出来只会让人乱点。 */
  const hasConnect = !KIND_QR.has(kind);

  const enterSec = (s: string) => {
    setSec(s);
    // 进到一个大类,默认选中它的第一种(多数大类里第一种就是最常用的那个)
    setKind(kindsOf(s)[0]?.id ?? "emby");
    setF(emptyForm());
  };

  return (
    <Page
      title={sec ?? "添加服务器"}
      onBack={sec ? () => setSec(null) : back}
      right={
        <BarButton
          icon="more"
          label="更多方式"
          onClick={(x, y) =>
            menu(x, y, [
              {
                icon: iconNode("list", 18),
                label: "批量粘贴导入",
                on: () => setTool("batch"),
              },
              {
                icon: iconNode("qr", 18),
                label: "扫码搬配置",
                on: () => setTool("qrsync"),
              },
            ])
          }
        />
      }
      enterKey={sec}
    >
      {sec === null ? (
        <>
          <div className="stp-h">
            <h2>要加哪种源?</h2>
            <p>先选个大类,下一步只填这一类要的那几个字段。</p>
          </div>
          <SrcCats onPick={enterSec} />
        </>
      ) : (
        <>
          <SrcKinds
            sec={sec}
            cur={kind}
            onPick={(id) => {
              setKind(id);
              setF(emptyForm());
            }}
          />
          <div className="lg-pane" key={kind} ref={pane}>
            <SourceForm kind={kind} f={f} set={set} />
          </div>
        </>
      )}

      {sec !== null && hasConnect && (
        <div className="lg-acts">
          <button
            type="button"
            className="btn primary"
            disabled={busy}
            onClick={async () => {
              // ★ 本地校验先跑,零成本;过了才发请求
              if (!checkRequired(pane.current)) return;
              setBusy(true);
              haptic("tap");
              try {
                await submitSource(kind, f);
                haptic("ok");
                toast("已添加", "ok");
                reloadGate();
                back();
              } catch (e) {
                toast(String(e), "bad");
              } finally {
                setBusy(false);
              }
            }}
          >
            {busy ? "连接中…" : "连接"}
          </button>
        </div>
      )}

      {/* 两个工具走居中弹窗 —— 它们都是"偶尔用一次"的东西,不值当占一个页面。 */}
      <Sheet
        open={tool !== null}
        onClose={() => setTool(null)}
        title={tool === "batch" ? "批量粘贴导入" : "扫码搬配置"}
        snap
      >
        <div className="pad">
          {tool && <SourceForm kind={tool} f={f} set={set} />}
        </div>
      </Sheet>
    </Page>
  );
}