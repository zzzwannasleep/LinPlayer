import { useRef, useState } from "react";
import { useCtx } from "../app/ctx";
import { haptic, toast } from "../app/motion";
import Page from "../components/Page";
import {
  KIND_QR,
  SourceForm,
  SrcPicker,
  checkRequired,
  emptyForm,
  submitSource,
  type FormState,
} from "../components/SourceForm";

/* 添加服务器 —— 和首启闸口(LoginPage)、重新登录用**同一份表单**
   (`components/SourceForm`),只是版式不同。抄两份的话新增源类型会改一处漏一处。

   ★ 源类型是**分组网格**不是横滑 chip:13 种 chip 要滑三屏,
     滑到一半根本不知道后面还有没有。
   ★ 服务器名称必填、排第一行 —— 扫码型的用户扫完就跳走了,放后面等于没有。
   ★ 必填校验在**发请求之前**跑。等服务端回来才说"名字没填"是白等一趟网络。 */

export default function AddServerPage() {
  const { back, reloadGate } = useCtx();
  const [kind, setKind] = useState("emby");
  const [f, setF] = useState<FormState>(emptyForm);
  const [busy, setBusy] = useState(false);
  const pane = useRef<HTMLDivElement>(null);
  const set = (p: Partial<FormState>) => setF((s) => ({ ...s, ...p }));

  /* 扫码型在二维码里自己完成登录 —— 底部那条「连接」对它没意义,画出来只会让人乱点。
     批量/搬配置也各自有自己的提交按钮。 */
  const hasConnect = !KIND_QR.has(kind) && kind !== "batch" && kind !== "qrsync";

  return (
    <Page title="添加服务器" onBack={back}>
      <SrcPicker cur={kind} onPick={(id) => {
        setKind(id);
        setF(emptyForm());
      }} />

      <div className="lg-pane" ref={pane}>
        <SourceForm kind={kind} f={f} set={set} />
      </div>

      {hasConnect && (
        <div className="lg-acts">
          <button
            type="button"
            className="btn"
            onClick={() => {
              haptic("tap");
              /* 摄像头扫码要宿主接相机权限 —— **不假装**已经做了 */
              toast("摄像头扫码要宿主接相机权限,先用「扫码搬配置」里的粘贴载荷", "warn");
            }}
          >
            扫码添加
          </button>
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
    </Page>
  );
}
