---
title: 播放内核与字幕
date: 2026-06-17 10:20:00
categories: [进阶]
tags: [mpv, ExoPlayer, 字幕, HDR]
---

LinPlayer 集成两套播放内核，理解它们的差异有助于选对内核。

<!-- more -->

## libmpv

- 复杂字幕的最佳选择：内置 **libass**，ASS/SSA 特效保真度最高。
- 支持 **PGS/SUP** 图形字幕（需 libmpv 含 `hdmv_pgs_subtitle` 解码器）。
- 支持滤镜、超分（Anime4K）、次字幕等高级能力。

## ExoPlayer（Media3）

- Android 原生硬解链路，能耗与兼容性好。
- ASS/SSA 经 **ass-media**（libass）渲染为带精确位置/尺寸的位图叠加，样式保真。
- 适合追求原生硬解、不需要 mpv 高级特性的场景。

## HDR / Dolby Vision

- HDR / DV 片源在 SDR 屏幕上需要 **tone-mapping**，否则画面发灰或偏色。
- ExoPlayer 在检测到 HDR/DV 轨道时启用 Media3 的色彩处理管线做 HDR→SDR 映射。
- libmpv 的杜比视界正确着色依赖 **libplacebo**（gpu-next）。

> 选择建议：**字幕特效多/图形字幕**优先 libmpv；**追求原生硬解**可用 ExoPlayer。
