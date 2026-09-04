# 版本号口径

## 唯一权威:仓库根的 `VERSION`

一行,形如 `1.1.0`。发布版本号 = `<VERSION>-build<CI run_number>`。

读它的地方(改版本只改 `VERSION` 一处):

| 谁 | 怎么读 |
|---|---|
| CI (`.github/workflows/build.yml`) | `cat VERSION` → 拼上 `-build<run_number>` |
| C# 宿主 | CI 传 `dotnet publish -p:Version=<版本>`;本地开发回落 `csproj` 里的 `<Version>` |
| Go 核心层 | `scripts/build-core.sh` 用 `-ldflags -X ...system.Version=<版本>` 注入 |

## ★ 为什么是 1.1.0 而不是 1.0.0

**版本必须单调递增,否则老用户永远收不到更新** —— App 的更新检查
(`core/system/update.go`)按 `major.minor.patch.build` 逐级比大小,
比不过线上那版就判定「已是最新」,**不报错、不提示**,静默卡死在旧版本。

这个坑本仓踩过两次:

1. 2026-07 仓库重组把权威从一个文件挪到另一个,版本从 `1.0.0` 退成 `0.1.0`;
2. 2026-09-04 删 Rust 栈时发现 C# 宿主 `Program.cs` 里写死 `0.1.0-go`,
   而线上已经发到 `v1.0.0-build684` —— 照那样发布,**所有老用户都收不到更新**。

选 `1.1.0` 是因为第三条:**仓库要清空重建,GitHub 的 `run_number` 会归 1**。
若基线仍是 `1.0.0`,新的 `1.0.0-build1` 比线上 `1.0.0-build684` **小**,
同一个坑会第三次发作。`1.1.0-build1` 则无论 build 号多小都稳压一头。

## 改版本时

只改 `VERSION`。改完确认新值 **大于** `gh release list --limit 1` 里那个 ——
这一步不能省,它是上面三次事故的唯一共同防线。
