# 编译期注入的变量(GitHub Actions 要配的那一批)

`scripts/build-core.sh` 在编 `lpcore` 之前会跑一次 `go run ./cmd/sealsecrets`,
把下面这些**环境变量**转成 `go build -ldflags -X` 片段灌进二进制。
一个都不配也能编得出来 —— 对应的功能会**明说「这个构建没配」**,而不是装作没数据。

> **为什么走注入而不是写在源码里**:全局红线 ——
> 「任何 IP、域名、线路/中转地址、账号、密码、密钥、token,都不得出现在任何提交里」。
> 私有仓库同样适用(仓库可能改公开、被 fork、被 CI 缓存)。

> **只有密文进 ldflags**:明文会**原样出现在构建日志和进程命令行里**,
> 而 CI 的日志是公开的。`sealsecrets` 负责在进 ldflags 之前先加密。

## 全表

| 环境变量 | 配了才有的功能 | 不配时的表现 | 该放 secret 还是 variable |
|---|---|---|---|
| `DANDANPLAY_APP_ID` | 弹幕(弹弹Play)、动漫排行榜 | 弹幕搜不到、排行榜空 | **secret** |
| `DANDANPLAY_APP_SECRET` | 同上 | 同上 | **secret** |
| `TMDB_API_KEY` | 影视排行榜 | 影视榜那几个分类空 | **secret** |
| `LP_SYNC_PROXY_BASE` | Trakt / Bangumi 登录(自建 OAuth 代理的**地址**,**要带 `/api` 后缀**) | 两个同步服务登不上 | **secret** |
| `LP_SYNC_PROXY_KEY` | 同上(访问代理的**共享密钥**,和代理的 `LINPLAYER_PROXY_KEY` 相同) | 同上 | **secret** |
| `LP_BANGUMI_REDIRECT_URI` | Bangumi OAuth 回调页地址 | Bangumi 登录跳不回来 | **secret** |
| `LP_AFDIAN_SPONSOR_URL` | 追剧日历的赞助入口 | 赞助按钮指向空地址 | **secret** |
| `LP_ICON_LIBRARY_SOURCES` | 服务器图标库(逗号分隔的多个 registry 地址) | 图标库页明说「这个构建没有配置图标源」,只能上传本地图片 | **secret** |
| `LP_CF_TEST_URL` | CF 优选的下载测速文件地址 | 测速跳过下载那一段,排序退化成**纯按延迟**(功能仍可用) | **secret** |

★ 后两个是 2026-09-01 从黄金实现里挪出来的:Rust 版把四条图标源和测速地址
**硬编在 `.rs` 里**,那是既有的红线欠账。Go 侧一律注入,并各有一条测试钉住
「源码里必须是空」(`core/prefs/iconlibrary_test.go`、`core/net/cf/speedtest_test.go`)。

## 同步那三个不是 Trakt / Bangumi 的 appid+secret

**这是最容易搞混的一处。** 客户端**从来不持有** Trakt / Bangumi 的 secret ——
那两对凭据配在**代理**上,客户端只知道「去哪找代理」和「敲门用什么暗号」。

```
                     LP_SYNC_PROXY_KEY(暗号)
LinPlayer 客户端  ──────────────────────────>  你的 OAuth 代理  ────>  Trakt / Bangumi
                LP_SYNC_PROXY_BASE(地址)        TRAKT_CLIENT_SECRET
                                                BANGUMI_APP_SECRET
```

| 配在哪 | 变量 | 是什么 |
|---|---|---|
| **客户端**(本表) | `LP_SYNC_PROXY_BASE` | 代理地址 + `/api`。空 = 这个构建没配同步服务 |
| **客户端**(本表) | `LP_SYNC_PROXY_KEY` | 敲门的共享密钥。代理没设就留空 |
| **客户端**(本表) | `LP_BANGUMI_REDIRECT_URI` | Bangumi 授权完跳回哪个页面 |
| **代理**(`oauth-proxy/`) | `TRAKT_CLIENT_ID` / `TRAKT_CLIENT_SECRET` | Trakt 那对 |
| **代理**(`oauth-proxy/`) | `BANGUMI_APP_ID` / `BANGUMI_APP_SECRET` | Bangumi 那对 |
| **代理**(`oauth-proxy/`) | `LINPLAYER_PROXY_KEY` | 和客户端的 `LP_SYNC_PROXY_KEY` 对上 |

代理本身在本仓库的 `oauth-proxy/`(Cloudflare Pages Functions),部署步骤见它的 README。

★ **两个 id 不在这张表里**:Trakt 的 `client_id` 和 Bangumi 的 `app_id` 是 OAuth 的
**公开标识符**,编译在客户端里(`core/sync/sync.go`,轻混淆存放)。
**所以代理上那两个 id 必须和客户端编进去的是同一个应用** —— 换成自己新注册的应用
而不动客户端,表现是「授权成功了,但每次同步都 401」。

★ Bangumi 还有一条**完全不经代理**的路:设置页可以直接贴个人 Access Token。
代理挂了、密钥轮换了,这条照样能登。Trakt 没有这条路(设备码流必须换 secret)。

⚠️ **老的 Rust 版把这把共享密钥明文写在 `crates/core/src/sync/mod.rs` 里,
已经进了 git 历史。** 换语言不会让它消失 —— 要轮换那把 key 并按红线改写历史。
这条记在 `TODO.md` 的迁移必带清单里。

## 留在源码里的地址,以及为什么

这些**不走注入**,它们不是任何人的服务器地址,和端口号一个性质:

| 位置 | 是什么 |
|---|---|
| `core/httpx/httpx.go` `RepoURL` | 本仓库自己的公开地址(第三方 API 的 UA 里要带,bgm.tv 开发指引要求) |
| `core/system/update.go` `githubAPI` | GitHub API 基址(检查更新) |
| `core/plugin/market.go` `officialSourceURL` | 本项目自己的公开插件仓库 |
| `core/translate/settings.go` | OpenAI / Anthropic / 百度 的**厂商公开 API 基址**,而且是设置页里用户可改的默认值 |
| `core/translate/engine.go` `TencentEndpoint` | 腾讯云 TMT 的公开 endpoint |
| `core/translate/whisper.go` | Hugging Face 官方权重仓库 + ffmpeg 官网给各平台指的两个分发源;用户可在设置里填镜像或手填本地路径绕开 |
| `core/net/cf/ranges.go` | Cloudflare **官方公布**的 IPv4/IPv6 地址段 |

> ⚠️ 最后一条会被推前扫的那条 `grep -rnE '[0-9]{1,3}(\.[0-9]{1,3}){3}'` 命中。
> 它是公开的网段表不是谁的服务器,但如果口径要收紧,把它也挪成注入即可
> (加一个 `LP_CF_RANGES`,格式同 `LP_ICON_LIBRARY_SOURCES`)。

## 在 GitHub Actions 里怎么配

**九个全部放 Secrets**(Settings → Secrets and variables → Actions → Secrets),
不要放 Variables —— Variables 在日志里是明文可见的,而其中几个本身就是密钥。

构建 job 里这样传(现有的 `.github/workflows/build.yml` 已经这么传前三个):

```yaml
- name: Build core
  run: bash scripts/build-core.sh
  env:
    DANDANPLAY_APP_ID: ${{ secrets.DANDANPLAY_APP_ID }}
    DANDANPLAY_APP_SECRET: ${{ secrets.DANDANPLAY_APP_SECRET }}
    TMDB_API_KEY: ${{ secrets.TMDB_API_KEY }}
    LP_SYNC_PROXY_BASE: ${{ secrets.LP_SYNC_PROXY_BASE }}
    LP_SYNC_PROXY_KEY: ${{ secrets.LP_SYNC_PROXY_KEY }}
    LP_BANGUMI_REDIRECT_URI: ${{ secrets.LP_BANGUMI_REDIRECT_URI }}
    LP_AFDIAN_SPONSOR_URL: ${{ secrets.LP_AFDIAN_SPONSOR_URL }}
    LP_ICON_LIBRARY_SOURCES: ${{ secrets.LP_ICON_LIBRARY_SOURCES }}
    LP_CF_TEST_URL: ${{ secrets.LP_CF_TEST_URL }}
```

> ★★ **漏传一个是静默的**:构建照样绿,产物照样能跑,只是那个功能永远不工作。
> 2026-07-21 就这么栽过一次(安卓 job 从建起来就没传 `DANDANPLAY_*`/`TMDB_API_KEY`)。
> `scripts/check-workflows.sh` 里有一道闸门盯着前三个;
> **新加的六个还没进那道闸门**,加 job 时要自己核对。

## 本机怎么试

```bash
export LP_ICON_LIBRARY_SOURCES="https://example.com/icons.json"
bash scripts/build-core.sh
# 输出会打一行「已注入编译期凭据(N 项)」
```

自检台(`scripts/selfcheck-win.sh`)走的是**另一条路**:它用同名环境变量在
**运行时**覆盖(见 `core/prefs/iconlibrary.go` 和 `core/net/cf/speedtest.go`
里的 `os.Getenv`),把地址指到假服务器上,所以不需要真去注入。
