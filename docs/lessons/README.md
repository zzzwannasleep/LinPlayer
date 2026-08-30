# 踩坑与经验(lessons)

这里是把长期记忆整理迁移过来的分域经验库。它替代原来的记忆库,是本仓库「同一个坑别踩第二次」的唯一出处。

**当前 123 条。** 迁移时是 125 条,2026-08-30 删掉 2 条**已被事实推翻**的(见下)。

> **原则:重新组织,不做摘要。** 每条经验的价值都在细节里(具体的属性名、具体的数字、具体的症状),所以正文一律按原样搬运,没有压缩、没有改写结论。原文里的日期、版本号、文件路径也保持原样 —— 其中不少路径已经被 2026-07-19 的仓库重构作废,这类条目顶部有一行 ⚠️ 提示,但**正文不改**。

## 维护纪律

**被推翻的内容直接删,不留注解。** 留着占地方,还会被下一个人当成有效结论再读一遍。
删之前先确认:**仍然成立的那部分在别处有没有**(比如弹幕那条删掉时,
其中的 mpv/ASS 事实已在 `docs/go-migration/knowledge/ASS_DANMAKU.md` 里,密度更高)。

已删记录见 [`contradictions-resolved.md`](contradictions-resolved.md) 末尾。

## 分域导航

| 文件 | 收哪些 | 条数 |
|---|---|---:|
| [`player-mpv.md`](player-mpv.md) | 播放器 / libmpv / 字幕 / 画质 / 播放窗口 | 21 |
| [`network.md`](network.md) | 预取代理 / 下载 / 线路 / HTTP / 超时 / UA | 14 |
| [`emby.md`](emby.md) | Emby 协议 / 媒体库 / 图片 / 上报 / fork 差异 | 14 |
| [`sources.md`](sources.md) | 网盘 / 局域网源 / 资源站 / 登录逆向 / 凭据 | 9 |
| [`danmaku-sync.md`](danmaku-sync.md) | 弹幕 / 弹弹Play / Bangumi / Trakt / 日历 / 排行榜 | 8 |
| [`plugins.md`](plugins.md) | 插件系统 / 插件市场 / 插件仓库 | 5 |
| [`ui-desktop.md`](ui-desktop.md) | PC 端 UI | 13 |
| [`ui-mobile.md`](ui-mobile.md) | 手机端 UI | 7 |
| [`ui-tv.md`](ui-tv.md) | TV 端 UI / 焦点 | 2 |
| [`android.md`](android.md) | 安卓平台(打包 / 签名 / 资源限定符 / R8 / 主题) | 8 |
| [`build-release.md`](build-release.md) | 构建 / CI / 发布 / 版本 / 打包 / 仓库卫生 | 11 |
| [`methodology.md`](methodology.md) | 工作方法与纪律 | 8 |
| [`decisions.md`](decisions.md) | 架构决策与端范围 | 3 |
| **合计** | | **123** |

另有两份不属于这 123 条的邻居文档,单独维护:

- [`red-line-audit.md`](red-line-audit.md) —— 仓库内真实地址泄漏的红线审计
- [`contradictions-resolved.md`](contradictions-resolved.md) —— 迁移时比对出的 11 组「矛盾」逐条裁决
  (结论:**真矛盾 0 组**,8 组的成因都是「记的是快照而没记版本」)

## 怎么用

- **动手前先扫对应领域文件开头的「最容易踩的坑」**(3~5 行),那是这个领域里最贵的几条。
- **每个文件开头有本页条目清单**,按标题找。
- 一条经验横跨多个领域时,**正文只存一份**,其它文件末尾的「跨域交叉引用」留一行指针。
- 条目之间的引用(原记忆里的 `[[wiki 链接]]`)已改写成指向新位置的 markdown 链接。
  少数指向的是已作废的 Flutter 时代旧记忆(不在这 123 条里),会显示成
  `「xxx」(该条不在本库,多为 Flutter 时代的旧记忆,已作废)`。

## 每条经验的格式

(下面这段用缩进代码块写,是为了不让它自己被下面的自查命令数进去)

    ### <标题>

    > 原记忆:`<原文件名>` · 类型:`<frontmatter 里的 type>`

    <正文,原样保留>

`类型` 取自原记忆的 `metadata.type`,三种:
`project`(某次落地的工程事实,95 条)/ `feedback`(用户口径与工作纪律,19 条)/ `reference`(可复查的实测参考,11 条)。

## 脱敏口径

按仓库红线(见 `red-line-audit.md`)与 CLAUDE.md:**任何 IP、域名、线路/中转地址、端口、账号、密码、密钥、token 都不进仓库。**
迁移时的处理:

- **用户自有/测试用的服务器地址、账号、密码、用户 id、订单号、自建代理域名、采集站名** —— 一律换成占位符
  (`<Emby 测试服 A>` / `<测试账号>` / `<自建 oauth-proxy 域名>` / `<采集站甲>` …),
  被改过的条目顶部有一行 🔒 标注「原文含具体值,已脱敏」。
- **公开的第三方 API 域名**(github.com / api.dandanplay.net / api.bgm.tv / 各网盘官方端点等)予以保留 ——
  它们是这些条目的技术要点本身,且本来就是公开文档里的地址。
- 需要具体值时去问项目负责人,**不要**再把它们写回任何文件。

## 自查:条目总数必须 = 125

```bash
# 1) 条目数(red-line-audit.md 不属于这 125 条,排除掉)
grep -c '^### ' docs/lessons/*.md | grep -v red-line-audit | awk -F: '{s+=$2} END {print s}'   # => 125

# 2) 每条都带「原记忆」出处行,且原文件名互不重复
grep -h '^> 原记忆:' docs/lessons/*.md | wc -l                                  # => 125
grep -ho '^> 原记忆:`[^`]*`' docs/lessons/*.md | sort -u | wc -l                 # => 125

# 3) 和记忆库逐个对账:两边文件名集合必须完全一致(输出为空才算过)
comm -3 \
  <(grep -ho '^> 原记忆:`[^`]*`' docs/lessons/*.md | sed 's/.*`\(.*\)`/\1/' | sort -u) \
  <(ls ~/.claude/projects/D--LinPlayer/memory/*.md | xargs -n1 basename | grep -v '^MEMORY.md$' | sort)
```

第 3 条是真正的闭环:前两条只能证明「有 125 个东西」,只有和记忆库对账才能证明**是那 125 个**。
