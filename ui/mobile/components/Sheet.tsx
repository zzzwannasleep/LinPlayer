import { useEffect, type ReactNode } from "react";
import { pushBackHandler } from "../app/backkey";
import { Icon } from "../app/icons";

/* 居中弹窗 —— 全站唯一的模态容器。

   ## 为什么不再是 bottom sheet(2026-08-01 用户定,推翻本文件上一版的结论)
   上一版这里写着「从底部升起才落在拇指区,是 iOS/Android 十年的收敛结果」。
   那句话在**全屏页**上成立,在我们这个应用上不成立 —— 我们有一条**悬浮底栏**。
   底栏盖在页面栈之上、z-index 比 sheet 的内容高度更靠外,于是 sheet 底部那排
   「取消 / 确定」正好落在底栏那条胶囊下面:按钮画得出来,**点不到**。
   用户在「添加线路」上撞的就是这个。
   居中弹窗离底栏最远,而且不需要为「拖到哪一档」再发明一套手势。

   ## 保留的三件事(改成居中之后仍然必须做)
   - **返回键必须由它吃掉**:不注册 pushBackHandler 的话,弹窗开着按返回是
     弹窗没关、整个页面先退了 —— 用户只想关掉筛选面板,结果回到了上一页。
   - 打开时锁背景滚动,否则手指在弹窗上滑到尽头会带着底下的页面一起滚。
   - 内容超高时**弹窗自己内部滚**,不是把弹窗撑出屏幕。

   ## 调用点零改动
   props 和上一版逐字一致(`snap` 保留但语义变成「内容多,给到更高的上限」),
   `.sheet-acts` 这个类名也保留 —— 全站二十几个调用点一个字都不用改。 */

type Props = {
  open: boolean;
  onClose: () => void;
  title?: ReactNode;
  children: ReactNode;
  /** 内容多(筛选面板、超分档位…)→ 放宽高度上限。不给 = 普通上限。 */
  snap?: boolean;
};

export default function Sheet({ open, onClose, title, children, snap }: Props) {
  /* 返回键。★ 注册的是「我吃掉」——返回 true,App.tsx 那边就不会去弹路由栈。 */
  useEffect(() => {
    if (!open) return;
    return pushBackHandler(() => {
      onClose();
      return true;
    });
  }, [open, onClose]);

  useEffect(() => {
    if (!open) return;
    const prev = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.body.style.overflow = prev;
    };
  }, [open]);

  if (!open) return null;

  return (
    <>
      <div className="scrim" onClick={onClose} />
      <div className={`sheet${snap ? " tall" : ""}`} role="dialog" aria-modal="true">
        {/* 标题栏永远画,即便没给 title —— 那个 × 是「不用手势也能关掉」的唯一保证。
            (bottom sheet 时代关闭靠往下拖,居中弹窗没有那个手势。) */}
        <div className="sheet-hd">
          <div className="sheet-title">{title}</div>
          <button type="button" className="sheet-x" aria-label="关闭" onClick={onClose}>
            <Icon n="close" size={18} />
          </button>
        </div>
        <div className="sheet-body">{children}</div>
      </div>
    </>
  );
}
