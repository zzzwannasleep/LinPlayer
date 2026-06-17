---
title: LinPlayer 简介
date: 2026-06-17 10:00:00
categories: [入门]
tags: [介绍, Emby]
---

**LinPlayer** 是一个第三方 **Emby** 客户端播放器，覆盖 **移动端、桌面端、TV 端**三类设备，主打高品质本地与流媒体播放体验。

<!-- more -->

## 它是什么

- 连接你的 Emby 服务器，浏览媒体库、续播、上报观看进度。
- 内置成熟的播放内核，支持复杂字幕（ASS/SSA、PGS/SUP）与高码率视频。
- 提供插件系统，可用 JavaScript 扩展能力。

## 支持的平台

| 平台 | 技术栈 | 说明 |
|---|---|---|
| Android / iOS | Flutter（Material） | 移动端主形态 |
| Windows / Linux / macOS | Flutter（fluent_ui / macos_ui / Material 分平台） | 桌面端原生观感 |
| Android TV / Apple TV / 平板 | Flutter（焦点导航 TV UI） | 遥控器友好 |

## 播放内核

LinPlayer 同时集成两套内核，按内容与平台择优：

- **libmpv**：复杂字幕（含 PGS/SUP）、滤镜、超分（Anime4K）等。
- **ExoPlayer（Media3）**：Android 原生硬解链路，配合 libass 渲染 ASS 字幕。

> 详见 [播放内核与字幕](/wiki/player-cores/) 与 [功能特性](/wiki/features/)。

## 快速开始

前往 [快速开始](/wiki/getting-started/) 了解如何连接服务器并开始播放。
