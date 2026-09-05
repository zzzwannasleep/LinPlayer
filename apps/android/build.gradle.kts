// 版本全钉死。实测依据见 docs/go-migration/research/VERSIONS_VERIFIED.md,
// 依赖清单见 docs/go-migration/UI_MOBILE.md §12 —— 要加依赖先回去改那份文档。
plugins {
    // ★ AGP 9 起 Kotlin 支持是内置的,不再需要 org.jetbrains.kotlin.android ——
    //   带着它会直接构建失败(kotl.in/gradle/agp-built-in-kotlin)
    id("com.android.application") version "9.4.0" apply false
    kotlin("plugin.compose") version "2.4.10" apply false
    kotlin("plugin.serialization") version "2.4.10" apply false
}
