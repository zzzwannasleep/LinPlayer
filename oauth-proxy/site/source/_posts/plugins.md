---
title: 插件系统
date: 2026-06-17 10:30:00
categories: [进阶]
tags: [插件, QuickJS]
---

LinPlayer 内置一个基于 **QuickJS**（`flutter_qjs`）的插件系统：每个插件运行在**独立的 JS isolate** 中，通过受权限控制的 `ctx` API 与主程序交互，并可向预定义扩展点挂载功能。

<!-- more -->

## 设计要点

- **隔离**：每个插件独立 isolate，崩溃/超时互不影响（约 8 秒墙钟超时保护）。
- **权限**：插件声明所需权限，安装时经用户同意弹窗授予；`ctx.*` 调用按权限校验。
- **存储**：每插件独立存储（约 5MB），与插件目录分离，升级/重装不丢数据。
- **不残留**：桌面便携版插件随解压文件夹自包含；移动/TV 放应用沙盒，卸载随系统清理。

## manifest.json（节选）

```json
{
  "id": "com.example.foo",
  "name": "示例插件",
  "version": "1.0.0",
  "permissions": ["network", "storage"],
  "extensionPoints": ["..."]
}
```

## 打包与安装

- 插件以 `.lpk`（zip）打包，App 内解压安装、校验。
- 在「插件管理」页可安装 / 启用 / 禁用 / 卸载。

> 更完整的扩展点、`ctx` API 与示例见仓库 `docs/PLUGINS.md` 与 `plugins_examples/`。
