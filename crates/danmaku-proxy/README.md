# LinPlayer 弹幕代理

把弹弹Play 的签名从客户端挪到服务器。

**为什么要有它**:客户端里的 AppSecret 无论怎么加密都是可提取的 —— 解密口令必须和密文
一起发出去。谁拿到安装包都能用你的配额,客户端限流拦不住外人。挪到服务端之后:

- 密钥只在这台机器的环境变量里,客户端一个字节都拿不到;
- **出站闸门**把「收到多少」和「转发多少」解耦。被刷爆的后果退化成「这段时间弹幕慢」,
  配额一个不掉;
- **共享缓存**把上游调用量从「播放次数」塌成「不同集数 × TTL 窗口」。
  一百个人看同一集,上游只打一次 —— 这一条省下来的比限流多一个数量级。

---

## 一、部署

服务只监听回环地址,前面挂你自己的反代 + Cloudflare。它**不做** TLS、不做 IP 封禁、
不做 DDoS 防护 —— 那三件事反代和 CF 做得更好。

### Docker(推荐,服务器上不用装 Rust)

在**仓库根目录**执行:

```bash
docker build -f crates/danmaku-proxy/Dockerfile -t linplayer-danmaku-proxy .

docker run -d --name danmaku-proxy --restart unless-stopped \
  -p 127.0.0.1:8787:8787 \
  -v /srv/danmaku-proxy:/data \
  -e DANDANPLAY_APP_ID='你的AppId' \
  -e DANDANPLAY_APP_SECRET='你的AppSecret' \
  -e ADMIN_PASSWORD='一个够长的管理密码' \
  linplayer-danmaku-proxy
```

`-p 127.0.0.1:8787:8787` 里的 `127.0.0.1:` **不要去掉** —— 去掉就等于把一个没有 TLS
的服务直接挂到公网上。

> 凭据别写进 `docker-compose.yml` 再提交 —— 用 `--env-file`(文件加进 `.gitignore`)
> 或 docker secret。这份 README 里也一个真值都没有,照着填。

### 不用 Docker

```bash
cargo build --release -p linplayer-danmaku-proxy
# 产物:target/release/linplayer-danmaku-proxy(单文件,无运行时依赖)
```

systemd 单元见本目录 `linplayer-danmaku-proxy.service`。

### 反代(OpenResty / nginx)

只需要一段 location,别的都不用改:

```nginx
location / {
    proxy_pass         http://127.0.0.1:8787;
    proxy_set_header   Host              $host;
    proxy_set_header   X-Real-IP         $remote_addr;
    proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
    # 弹幕正文单集能到几 MB,默认的 proxy_buffer 会频繁落临时文件
    proxy_buffering    off;
    proxy_read_timeout 30s;
}
```

### Cloudflare(橙云)

在这个域名上建议开:

| 规则 | 目的 |
|---|---|
| Rate limiting:`/api/register` 每 IP 10 分钟 5 次 | 挡批量注册。服务里也有一层,这层挡在更前面 |
| Rate limiting:`/api/v2/*` 每 IP 每分钟 60 次 | 挡单机猛刷,省掉源站的 CPU |
| WAF:`/admin*` 只放行你自己的 IP(或加 Access) | 管理界面能改闸门和封禁,不该对全世界开 |
| Cache Rules:**不要**缓存 `/api/*` | CF 缓存不认我们的令牌,会把 A 的响应发给 B |

**国内可达性**:你之前实测过「国内 CF 有地方阻断、GitHub 反而稳」(插件仓库因此没挪 CF)。
弹幕接口挂 CF 之前建议先拿这个域名实测一轮。真不通的话,留一个直连源站的备用域名,
客户端两条都试。

---

## 二、环境变量

| 变量 | 必填 | 默认 | 说明 |
|---|---|---|---|
| `DANDANPLAY_APP_ID` | ✅ | — | 弹弹Play AppId |
| `DANDANPLAY_APP_SECRET` | ✅ | — | AppSecret。**多串轮换密钥**可换行分隔,服务只取第一串 |
| `ADMIN_PASSWORD` | ✅ | — | 管理界面密码,至少 8 位。没有默认密码,不设就拒绝启动 |
| `PORT` | | `8787` | 监听端口 |
| `BIND` | | `127.0.0.1` | 监听地址。容器里由镜像设成 `0.0.0.0` |
| `DATA_DIR` | | `./data` | 配置、客户端表、缓存都在这里。**要持久化** |
| `UPSTREAM_BASE` | | 弹弹官方 | 只给自检用(拿假上游顶替,免得跑一次测试烧一次配额) |

其余所有旋钮都在管理界面里改,**改完立刻生效不用重启**(磁盘上限除外)。

---

## 三、上线后第一件事

打开 `https://你的域名/admin`,把**出站:每天上限**改成你在弹弹那边的真实配额的 80%。

默认值(3000/天)只保证「不会一天之内烧光」,不保证用满 —— 它不知道你的配额是多少。

顺带看一眼:

- **缓存命中率**:跑几天后应该稳定在 60% 以上。长期低于 30% 说明 TTL 设太短了,调大
  「弹幕正文 TTL」最划算(弹幕少了最近几条没人看得出来)。
- **客户端**表里的「上游」列 = 这台设备真正花掉的配额。有一台远高于其它,基本就是它在刷,
  直接封。
- 被刷急了:注册模式切「邀请码」或「关闭」。**存量客户端不受影响**,只是不再发新令牌。

---

## 四、接口

客户端要用的只有两个:

```
POST /api/register            {"label": "设备名", "invite": "邀请码(可选)"}
                              → {"token": "64 位 hex"}   ★ 令牌只在这里出现一次

ANY  /api/v2/<弹弹的路径>      需要 X-LP-Token: <token>
                              → 弹弹的响应原样透传
```

白名单只放行 `search/anime`、`search/episodes`、`bangumi/`、`comment/`、`match`、
`trending/` —— 不做通配转发,那等于给全世界开了一个带我们签名的免费代理。

**错误口径**照弹弹自己的来:HTTP 200 + body 里的 `errorCode`,客户端已有的解析器
直接就能显示。自定义码:

| 码 | 含义 |
|---|---|
| 1001 | 服务关闭 / 不接受注册 / 需要邀请码 |
| 1002 | 客户端限流(每分钟或每日额度) |
| 1003 | **出站闸门拦下** —— 上游配额今天用完了 |
| 1004 | 上游不可达 |
| 1005 | 不在白名单的接口 |

HTTP **401** 是唯一的例外:表示令牌无效或被封禁,客户端应当清掉本地令牌重新注册。
业务码做不到这件事,所以它必须走状态码。

---

## 五、排障

| 现象 | 先查 |
|---|---|
| 启动就退出,`[致命] 需要…` | 三个必填环境变量少了哪个 |
| 客户端全部 401 | 令牌是不是被删了 / 封了;管理界面客户端表里找它的编号 |
| 全部返回 `errorCode:1003` | 出站闸门已用满。管理界面看「今日上游调用」,UTC 00:00 重置 |
| 上游一律 403 | 签名错。最常见的成因是 AppSecret 是**多串轮换密钥**而被整坨拿去签了 —— 本服务已处理(只取第一串),但如果你在别处也用这个密钥,注意同样的坑 |
| 缓存命中率一直是 0 | 看响应头 `X-LP-Cache`。一直 MISS 且参数每次都不一样,多半是客户端在往 query 里塞时间戳之类的东西 |

自检:

```bash
cargo test -p linplayer-danmaku-proxy          # 18 条单测
node crates/danmaku-proxy/e2e.mjs              # 端到端(自带假上游,不碰真配额)
```
