---
title: 功能特性
date: 2026-06-17 10:10:00
categories: [入门]
tags: [功能]
---

LinPlayer 的核心功能一览。

<!-- more -->

## 播放

- 双内核（**仅安卓**）：设置 →「播放器」选默认内核；播放页**长按播放键**用另一个内核起播一次。
  换内核要退出当前播放再进 —— 播到一半换等于拆掉解码器重建。
- 硬解 / 软解切换，记忆进度续播。
- 倍速、长按临时倍速、跳过片头/片尾、画面比例、画面增强（Anime4K 六档，仅 mpv 内核）。
- 手势：双击快进退、左右滑进度、上下滑亮度/音量、长按倍速。

## 字幕

- 文本字幕：SRT / ASS / SSA / VTT / TTML。
- **ASS/SSA 特效**：libmpv 内置 libass；ExoPlayer 借用 libmpv 已导出的 libass 符号渲染成位图（不引第二份），保留字号/位置/样式。
- 图形字幕：PGS / SUP（依赖含 `hdmv_pgs_subtitle` 解码器的 libmpv）。
- 外挂字幕导入、字幕延迟、次字幕（mpv）。

## 媒体与同步

- Emby 媒体库浏览、续播、播放进度上报。
- 观看完成阈值上报到已连接的同步服务（如 Trakt / Bangumi）。
- 弹幕：搜索、加载、密度/速度/透明度/延迟可调。

## 扩展

- **插件系统**：基于 QuickJS 的 JS 插件，独立 isolate 运行。详见 [插件系统](/wiki/plugins/)。

## 各端

- **Windows**：C# / Avalonia，自绘标题栏、独立播放窗口、键盘快捷键。
- **Android 手机 / 平板**：Kotlin / Jetpack Compose，沉浸式播放页，手势全套。
- **Android TV**：未开始（遥控器焦点导航要单独做一版）。
