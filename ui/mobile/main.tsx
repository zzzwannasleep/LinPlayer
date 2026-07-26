import React from "react";
import ReactDOM from "react-dom/client";
import App from "./App";
import { installShellKeyBridge } from "./app/backkey";
import "./theme/mobile.css";

/* 壳按键桥必须在**任何组件挂载之前**装好:装晚了的话,启动瞬间按下的返回键
   落到一个还不存在的 window.__lpTvKey 上,静默丢掉。 */
installShellKeyBridge();

/* ★ 这里**不调** applyThemeEarly()。
   手机端是强制深色(见 ui/mobile/README.md 的硬约束),配色写死在 theme/mobile.css 里,
   不读 <html data-theme>。调了它反而会把 PC 端存在 localStorage 里的 "light"
   带进来 —— 而 mobile.css 根本没有浅色分支,结果是浅色 token 缺失、页面半黑半白。 */

ReactDOM.createRoot(document.getElementById("root") as HTMLElement).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);
