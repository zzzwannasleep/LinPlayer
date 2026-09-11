---
title: LinPlayer 简介
date: 2026-06-17 10:00:00
categories: [入门]
tags: [介绍, Emby]
---

**LinPlayer** 是一个第三方 **Emby** 客户端播放器。一份各端共用的 **Go 核心层** + 每端自己写的原生 UI，主打高品质本地与流媒体播放体验。

<!-- more -->

## 它是什么

- 连接你的 Emby 服务器，浏览媒体库、续播、上报观看进度。
- 内置成熟的播放内核，支持复杂字幕（ASS/SSA、PGS/SUP）与高码率视频。
- 提供插件系统，可用 JavaScript 扩展能力。

## 支持的平台

| 平台 | 技术栈 | 状态 |
|---|---|---|
| **Windows** | Go 核心 + C# / .NET 10 / Avalonia | 可用，正常发布。免安装绿色包 |
| **Android 手机 / 平板** | Go 核心 + Kotlin / Jetpack Compose | 可用（2026-09-06 起），出已签名 APK |
| **Android TV** | 同上，但需要一版焦点导航 UI | 未开始 —— 手机端那套触摸交互搬不上遥控器 |
| **Linux** | Go 核心 + Avalonia | 未开始 |
| 苹果全线 | —— | 不做 |

> 2026-09-04 起旧的 **Rust 核心 + React/Tauri** 栈已从仓库删除（再往前还有一代 Flutter 栈）。
> Linux 与 TV 端因此暂时没有可运行的实现 —— 这是换栈明知的代价，不是进度倒退。

## 播放内核

- **libmpv** —— 两端都用它做默认内核。复杂字幕（含 PGS/SUP）、滤镜、画面增强（Anime4K）等。
- **ExoPlayer（Media3）** —— **仅安卓**，播放页长按播放键即可切。原生硬解链路，能耗与兼容性好；
  该内核下没有画面增强（glsl-shaders 是 mpv 的东西）。

> 详见 [播放内核与字幕](/wiki/player-cores/) 与 [功能特性](/wiki/features/)。

## 快速开始

前往 [快速开始](/wiki/getting-started/) 了解如何连接服务器并开始播放。
