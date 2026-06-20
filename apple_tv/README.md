# LinPlayer tvOS

LinPlayer 的 Apple TV 原生版本，使用 Swift + SwiftUI 构建。

## 为什么需要原生版本？

Flutter 官方不支持 tvOS 平台编译，因此 Apple TV 版本需要使用原生 Swift/SwiftUI 重写 UI 层，
同时复用与 Flutter 版本相同的 Emby API 接口。

## 系统要求

- Xcode 15.0+
- tvOS 17.0+
- Swift 5.9+

## 项目结构

```
apple_tv/
├── LinPlayerTV/
│   ├── LinPlayerTVApp.swift          # App 入口
│   ├── RootView.swift                # 根视图（引导/登录/主界面路由 + 会话自动恢复 + Onboarding）
│   ├── MainTabView.swift             # 主框架 MainShellView：左侧边栏导航（对齐安卓 TV 端）
│   ├── Models/
│   │   └── MediaModels.swift         # 数据模型（与 Emby API 对应）
│   ├── Services/
│   │   ├── EmbyApiClient.swift       # Emby API 客户端
│   │   ├── ServerManager.swift       # 服务器配置管理
│   │   └── AuthManager.swift         # 认证状态管理
│   ├── Theme/
│   │   └── AppTheme.swift            # 主题色、间距、字号
│   ├── Extensions/
│   │   └── View+Extensions.swift     # SwiftUI 扩展
│   ├── Views/
│   │   ├── Components/               # 通用 UI 组件
│   │   │   ├── PosterCard.swift      # 竖版海报卡片
│   │   │   ├── WideCard.swift        # 横版宽卡片（继续观看）
│   │   │   ├── ContentRow.swift      # 横向滚动内容行
│   │   │   └── HeroBanner.swift      # 首页 Hero 轮播
│   │   ├── Home/
│   │   │   └── HomeView.swift        # 首页
│   │   ├── Detail/
│   │   │   └── DetailView.swift      # 详情页（含季/集选择）
│   │   ├── Player/
│   │   │   └── PlayerView.swift      # 播放页（AVPlayer）
│   │   ├── Library/
│   │   │   └── LibraryListView.swift # 媒体库列表与详情
│   │   ├── Search/
│   │   │   └── SearchView.swift      # 搜索页
│   │   ├── Server/
│   │   │   ├── ServerListView.swift  # 服务器列表/添加
│   │   │   └── LoginView.swift       # 登录页
│   │   └── Settings/
│   │       └── SettingsView.swift    # 设置页
│   ├── Assets.xcassets/              # 资源目录
│   └── Info.plist                    # tvOS 配置
├── LinPlayerTV.xcodeproj/            # Xcode 工程文件
└── Package.swift                     # SPM 配置
```

## 功能对照

| 功能 | Flutter TV 版 | tvOS 原生版 |
|------|:---:|:---:|
| 服务器管理 | ✅ | ✅ |
| 用户登录 | ✅ | ✅ |
| 首页（Hero + 继续观看 + 媒体库） | ✅ | ✅ |
| 媒体库浏览（分页 + 排序） | ✅ | ✅ |
| 详情页（评分/简介/演员/相似） | ✅ | ✅ |
| 剧集选季/选集 | ✅ | ✅ |
| 搜索 | ✅ | ✅ |
| 视频播放（AVPlayer） | ✅ (media_kit) | ✅ (AVPlayer) |
| 播放进度同步 | ✅ | ✅ |
| 收藏 | ✅ | ✅ |
| 设置/退出登录 | ✅ | ✅ |
| 遥控器导航 | ✅ (自定义焦点) | ✅ (原生焦点) |
| 弹幕 | ✅ | ❌ (后续添加) |
| 字幕选择 | ✅ | 🔜 (系统播放器内置) |
| DLNA 投屏 | ✅ | ❌ (不适用) |
| 下载 | ✅ | ❌ (tvOS 限制) |

## 开发指南

### 在 Xcode 中打开

推荐使用 Xcode 直接打开 `apple_tv/LinPlayerTV` 目录（File → Open），
Xcode 会自动识别 Swift Package 结构。

或者打开 `apple_tv/LinPlayerTV.xcodeproj`。

### 构建步骤

1. 在 Mac 上安装 Xcode 15+
2. 打开项目
3. 选择 Apple TV 模拟器或真机作为目标
4. `Cmd + R` 运行

### API 兼容性

tvOS 版本的 `EmbyApiClient` 与 Flutter 版本的 `EmbyApiClient` 使用完全相同的 API 端点：

- 认证：`/Users/AuthenticateByName`
- 首页：`/Users/{id}/Items/Resume`, `/Shows/NextUp`, `/Users/{id}/Views`
- 媒体库：`/Users/{id}/Items`
- 详情：`/Items/{id}`, `/Shows/{id}/Seasons`, `/Shows/{id}/Episodes`
- 搜索：`/Users/{id}/Items?SearchTerm=...`
- 播放：`/Items/{id}/PlaybackInfo`, `/Videos/{id}/stream`
- 进度上报：`/Sessions/Playing`, `/Sessions/Playing/Progress`, `/Sessions/Playing/Stopped`
- 收藏：`/Users/{id}/FavoriteItems/{id}`
- 图片：`/Items/{id}/Images/{type}`

### 自签名证书

`EmbyApiClient` 内置了 `InsecureSessionDelegate`，允许连接使用自签名 SSL 证书的 Emby 服务器。

## 设计规范

- 品牌色：`#5B8DEF`
- 背景色：`#121212`（强制深色模式）
- 焦点效果：使用 tvOS 原生焦点系统，配合 `TVCardButtonStyle`
- 字体：系统 SF Pro，针对 TV 远距离观看调大了字号
- 布局：适配 1920×1080 分辨率
