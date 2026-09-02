# LinPlayer OAuth 代理（Cloudflare Pages）

一个**令牌交换代理**：把 Trakt / Bangumi 的 `client_secret` 放到服务端环境变量里，
客户端不再内置 secret。App 只调用本代理的 `/api/*`，由代理注入 secret 去换令牌。

> **为什么不能用 GitHub Pages？**
> GitHub Pages 只能托管**静态文件**，不能跑服务端代码、也不能安全保存 secret，
> 所以无法当代理。Cloudflare Pages 自带 **Pages Functions**（Serverless），可以跑代码、
> 用加密环境变量存 secret，且同一个项目还能顺便托管 Bangumi 回调页。

## 它做了什么

| 路由 | 方法 | 作用 | 是否注入 secret |
|---|---|---|---|
| `/api/trakt/device` | POST | 申请 Trakt 设备码 | 否（仅 client_id） |
| `/api/trakt/token` | POST | 轮询设备码换令牌 | ✅ |
| `/api/trakt/refresh` | POST | 刷新 Trakt 令牌 | ✅ |
| `/api/bangumi/token` | POST | 授权码换令牌 | ✅ |
| `/api/bangumi/refresh` | POST | 刷新 Bangumi 令牌 | ✅ |
| `/oauth/bangumi.html` | GET | Bangumi 回调「显示授权码」静态页 | — |

> `client_id` / `app_id` 是**公开标识符**，留在客户端是安全的；真正要保护的是 secret。

## 目录结构

```
oauth-proxy/
  functions/
    _middleware.js              # CORS + 可选共享密钥校验
    api/trakt/{device,token,refresh}.js
    api/bangumi/{token,refresh}.js
  public/
    index.html                  # 落地页
    oauth/bangumi.html          # Bangumi 回调页
  .dev.vars.example             # 本地调试环境变量样例
```

---

## 一、部署到 Cloudflare Pages（推荐：连 Git 仓库）

1. 登录 Cloudflare 控制台 → **Workers & Pages** → **Create** → **Pages** → **Connect to Git**。
2. 选中本仓库，授权。
3. 构建配置：
   - **Production branch**：`main`
   - **Framework preset**：`None`
   - **Build command**：留空
   - **Build output directory**：`public`
   - **Root directory (Advanced)**：`oauth-proxy`  ← 关键，让它找到 `oauth-proxy/functions`
4. **Environment variables**（Settings → Environment variables，建议设为 *Encrypted*）：
   | 变量名 | 值 |
   |---|---|
   | `TRAKT_CLIENT_ID` | 你的 Trakt client id |
   | `TRAKT_CLIENT_SECRET` | 你的 Trakt client secret |
   | `BANGUMI_APP_ID` | 你的 Bangumi app id |
   | `BANGUMI_APP_SECRET` | 你的 Bangumi app secret |
   | `LINPLAYER_PROXY_KEY` | （可选）自定义共享密钥，挡脚本刷接口 |
5. 保存并 **Deploy**。完成后得到地址，例如 `https://linplayer-oauth.pages.dev`。

> 改了环境变量后需要 **Retry deployment / 重新部署** 才生效。

### 用 Wrangler CLI 部署（可选）

```bash
cd oauth-proxy
npm i -g wrangler
wrangler pages deploy public --project-name linplayer-oauth
# 然后在控制台为该项目补上环境变量（同上）
```

---

## 二、注册回调地址

- **Trakt** 后台 Redirect URI 填：`urn:ietf:wg:oauth:2.0:oob`
  （设备码流程不用回调，但后台必填，占位即可。）
- **Bangumi** 后台回调地址填：`https://<你的项目>.pages.dev/oauth/bangumi.html`

---

## 三、让 App 走代理

代理地址与共享密钥**不写进源码**,走编译期注入(全局红线:线路/中转地址和密钥
都不许进提交)。构建核心层前把这三个环境变量准备好:

| 环境变量 | 填什么 | 对应代理这边的 |
|---|---|---|
| `LP_SYNC_PROXY_BASE` | `https://<你的项目>.pages.dev/api` ← **必须带 `/api` 后缀** | 部署地址 |
| `LP_SYNC_PROXY_KEY` | 和代理的 `LINPLAYER_PROXY_KEY` **一模一样**;代理没设就留空 | `LINPLAYER_PROXY_KEY` |
| `LP_BANGUMI_REDIRECT_URI` | `https://<你的项目>.pages.dev/oauth/bangumi.html` | 回调页(本项目 `public/` 里那个) |

```bash
export LP_SYNC_PROXY_BASE="https://<你的项目>.pages.dev/api"
export LP_SYNC_PROXY_KEY="<和 LINPLAYER_PROXY_KEY 相同>"
export LP_BANGUMI_REDIRECT_URI="https://<你的项目>.pages.dev/oauth/bangumi.html"
bash scripts/build-core.sh
```

GitHub Actions 里三个都放 **Secrets**(不是 Variables —— Variables 在日志里是明文)。
全表见 [`docs/go-migration/BUILD-SECRETS.md`](../docs/go-migration/BUILD-SECRETS.md)。

> ★★ **Trakt/Bangumi 的 client_id / app_id 不在这三个里。**
> 它们是 OAuth 的**公开标识符**,编译在客户端里(`core/sync/sync.go` 的
> `TraktClientID()` / `BangumiAppID()`,轻混淆存放)。真正要保护的 secret
> 只在代理这边(`TRAKT_CLIENT_SECRET` / `BANGUMI_APP_SECRET`)。
>
> **推论:代理的 `TRAKT_CLIENT_ID` / `BANGUMI_APP_ID` 必须和客户端里编译进去的
> 那一对是同一个应用。** 换成你自己新注册的 Trakt 应用而不改客户端的话:
> 设备码是应用 A 发的,而客户端拿应用 B 的 key 去打 `api.trakt.tv` ——
> 表现是「授权成功了,但每次同步都 401」。
> 要换成自己的应用,得同时改 `core/sync/sync.go` 里那两个混淆数组
> (或者提个需求把它们也做成注入)。

> ⚠️ **老的 Rust 版把共享密钥明文写在 `crates/core/src/sync/mod.rs` 里,已经进了
> git 历史。** 换语言不会让它消失 —— 那把 key 要轮换,并按红线改写历史。

## 四、自测

```bash
# 申请 Trakt 设备码（应返回 user_code / verification_url）
curl -X POST https://<你的项目>.pages.dev/api/trakt/device \
  -H "X-LinPlayer-Key: <若设了密钥>"

# Bangumi 换令牌（code 用真实授权码）
curl -X POST https://<你的项目>.pages.dev/api/bangumi/token \
  -H "Content-Type: application/json" \
  -H "X-LinPlayer-Key: <若设了密钥>" \
  -d '{"code":"xxx","redirect_uri":"https://<你的项目>.pages.dev/oauth/bangumi.html"}'
```

本地调试：

```bash
cd oauth-proxy
cp .dev.vars.example .dev.vars   # 填入真实值
npx wrangler pages dev public
```

---

## 五、防滥用（建议）

- 设置 `LINPLAYER_PROXY_KEY`，让随手刷接口的脚本被 401 挡掉
  （注意：该密钥也随 App 分发、可被提取，只是再加一道门槛，并非强鉴权）。
- Cloudflare 控制台为该 Pages 项目开启 **Rate Limiting / WAF 规则**（按 IP 限速）。
- 代理是**唯一持有 secret 的地方**：一旦发现滥用，直接在 Cloudflare 改/停项目或轮换
  secret 即可，无需发版客户端。
