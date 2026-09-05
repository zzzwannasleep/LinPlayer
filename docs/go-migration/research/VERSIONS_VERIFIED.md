# 版本基线 · 实测核对(2026-09-06)

> **这份文件压过 `MOBILE_*.md` 里的任何版本号。**
>
> 六份调研由子 agent 产出,结构性结论(哪些 API 存在、生命周期规则、JNI keep 写法、
> 无障碍口径)可用;**版本号与发布日期系统性过时**,抽查时逐条打回。
> 下面每一行都是当天从 Google Maven / Maven Central 的 `maven-metadata.xml` 拉的,
> 命令写在文末,可复跑。

## 抽查结果(每份至少一条)

| # | 文档 | 原文结论 | 实测 | 判 |
|---|---|---|---|:--:|
| 1 | `MOBILE_COMPONENTS.md:26` | Material 3 **1.4.0**,「2024-12」 | 版本号对(BOM 2026.08.00 钉的就是 1.4.0);**日期错** | 半对 |
| 2 | `MOBILE_COMPONENTS.md:288` | telephoto **0.13.0** | 最新 `me.saket.telephoto:zoomable` **1.0.0-alpha02** / `zoomable-image-coil3` **0.19.0** | ❌ |
| 3 | `MOBILE_MOTION.md:14-23` | URL 域名 `developer.android.google.com` | 官方域名是 `developer.android.com`,前者不存在 | ❌ |
| 4 | `MOBILE_NAV_STATE.md:613` | Navigation Compose **2.8.6** stable | 最新 stable **2.10.0** | ❌ |
| 5 | `MOBILE_PLAYER.md:769` | media3-session **1.3.0(2024-09)** | 最新 **1.11.0** | ❌ |
| 6 | `MOBILE_PLAYER.md:775` | core-splashscreen **1.0.1** | 最新 stable **1.2.0** | ❌ |
| 7 | `MOBILE_IMAGES.md` | Coil **3.0.0+** | 最新 **3.6.2** | 半对 |

> 结论:**版本这一类事实不能由离线知识给。** 六份文档的价值在「有没有这个 API、
> 它的语义是什么、坑在哪」,不在数字。落码用下表。

## 实测版本表(本轮定死,写码不许再临时改)

| 项 | 版本 | 来源 |
|---|---|---|
| Gradle | **9.7.1** | AGP 9.4 硬要求 ≥9.6.0(实测报错原文:「Minimum supported Gradle version is 9.6.0」) |
| Android Gradle Plugin | **9.4.0** | 8.13.2 装不下 2026 年的 androidx:实测报「Dependency 'androidx.compose.ui:ui-android:1.12.0' requires Android Gradle plugin 9.1.0 or higher」 |
| Kotlin | **2.4.10** | 只用 `plugin.compose` 与 `plugin.serialization` 两个插件 —— **AGP 9 起 Kotlin 支持内置**,带着 `org.jetbrains.kotlin.android` 会直接构建失败 |
| Compose BOM | **2026.08.00** | `dl.google.com/.../androidx/compose/compose-bom/maven-metadata.xml` |
| ├ compose ui(BOM 钉) | 1.12.0 | BOM 的 pom |
| └ material3(BOM 钉) | 1.4.0 | BOM 的 pom |
| activity-compose | **1.13.0** | Google Maven |
| navigation-compose | **2.10.0** | Google Maven |
| lifecycle-runtime-compose / viewmodel-compose | **2.11.0** | Google Maven |
| media3-session / media3-common | **1.11.0** | Google Maven |
| core-splashscreen | **1.2.0** | Google Maven |
| palette-ktx | **1.0.0** | Google Maven(1.1.0 只有 alpha) |
| window(折叠屏) | **1.5.1** | Google Maven |
| profileinstaller | **1.4.1** | Google Maven |
| coil3 | **3.6.2** | Maven Central |
| compileSdk | **37** | `androidx.core:core-ktx:1.19.0` 要求 compile against 37;本机 `platforms/android-37.0` 已装 |
| targetSdk | **36** | 只提 compileSdk,不顺手把运行时行为也换掉 |
| minSdk | **24** | NDK r28 起最低支持 21;24 与本机 `platforms/android-24` 对齐 |
| NDK | **28.2.13676358** | 本机已装(另有 27 / 30-canary,脚本默认钉 28) |
| JDK | **21**(Zulu 21.0.5) | `java -version` |

## 被否掉的依赖

| 库 | 为什么不要 |
|---|---|
| `me.saket.telephoto`(可缩放大图) | 本轮 16 页里**没有大图浏览页**(人物详情、图标库不在本轮)。需求不存在就不引依赖 |
| `androidx.paging:paging-compose` | 分页在核心层(offset/limit,页大小**从响应学**)。Paging 3 的 `PagingSource` 要求 UI 侧持有页码语义,与 SPEC §8.5 冲突 |
| `androidx.media3:media3-exoplayer` | 解码渲染全在核心层 libmpv。只取 `media3-session` |
| 任何 shimmer / 骨架屏库 | `Modifier.background(brush)` + `rememberInfiniteTransition` 约 25 行 |
| 任何依赖注入框架(Hilt / Koin) | 全局只有一个 `CoreClient` 单例。一个单例不需要容器 |

## 复跑命令

```bash
fetchver() {
  local g="$1" a="$2"; local path="${g//./\/}"
  curl -s "https://dl.google.com/dl/android/maven2/$path/$a/maven-metadata.xml" \
    | grep -oE '<version>[^<]+</version>' | sed 's/<[^>]*>//g' | tail -6
}
fetchver androidx.compose compose-bom
fetchver androidx.navigation navigation-compose
fetchver androidx.media3 media3-session
```
Maven Central 的把域名换成 `repo1.maven.org/maven2`。
