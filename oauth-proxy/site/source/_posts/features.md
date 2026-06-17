---
title: 功能特性
date: 2026-06-17 10:10:00
categories: [入门]
tags: [功能]
---

LinPlayer 的核心功能一览。

<!-- more -->

## 播放

- 双内核：libmpv / ExoPlayer，可在播放页「更多 → 内核切换」即时切换。
- 硬解 / 软解切换，记忆进度续播。
- 倍速、长按临时倍速、跳过片头/片尾、画面比例、超分辨率（Anime4K，mpv）。
- 手势：双击快进退、左右滑进度、上下滑亮度/音量、长按倍速。

## 字幕

- 文本字幕：SRT / ASS / SSA / VTT / TTML。
- **ASS/SSA 特效**：libmpv 内置 libass；ExoPlayer 经 ass-media 用 libass 渲染为位图，保留字号/位置/样式。
- 图形字幕：PGS / SUP（依赖含 `hdmv_pgs_subtitle` 解码器的 libmpv）。
- 外挂字幕导入、字幕延迟、次字幕（mpv）。

## 媒体与同步

- Emby 媒体库浏览、续播、播放进度上报。
- 观看完成阈值上报到已连接的同步服务（如 Trakt / Bangumi）。
- 弹幕：搜索、加载、密度/速度/透明度/延迟可调。

## 扩展

- **插件系统**：基于 QuickJS 的 JS 插件，独立 isolate 运行。详见 [插件系统](/wiki/plugins/)。

## 桌面 / TV

- 桌面端按平台采用 fluent_ui（Win）/ macos_ui（mac）/ Material（Linux），自绘标题栏、沉浸模式。
- TV 端遥控器焦点导航，专为大屏设计。
