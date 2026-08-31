# Rust → Go 移植陷阱

> **这份文件收的是「两边都编译通过、单测都绿、但输出不一样」的那类差异。**
> 它们不会以报错的形式出现,只会以「界面上有点不对」的形式出现,
> 而且往往要到用户手里才被看见。
>
> 每条都必须是**在本项目里真的发生过**的 —— 差分对账(`core/cmd/diffcheck`)抓到的,
> 或移植时读代码当场发现的。想象出来的陷阱不写进来。
>
> 判据:一条陷阱要能回答「**它错了会长什么样**」。答不上来的删掉。

## 本页条目

- [T1. 零值切片序列化成 `null`,而 `Vec::new()` 是 `[]`](#t1)
- [T2. `Option<String>` 的 `.or()` 短路:`Some("")` 不会回落](#t2)
- [T3. `sort_by` 不稳定,`SliceStable` 才等价](#t3)
- [T4. 空串折 `null` 这件事,每个结构体的口径都不一样](#t4)
- [T5. serde 的 `default = "…"` 在 Go 这边一个都不存在](#t5)
- [T6. 「读的时候钳」和「写的时候拒」是两件事,不许统一](#t6)

---

<a id="t1"></a>
## T1. 零值切片序列化成 `null`,而 `Vec::new()` 是 `[]`

**2026-08-31 差分对账当场抓到,三处。**

Go 的 `var out []string` 是 `nil`,`encoding/json` 把它编码成 `null`。
Rust 的 `Vec::new()` 编码成 `[]`。两边的函数签名、逻辑、测试全一样,
只有这一个字节的差别。

**它错了会长什么样:** 前端拿到 `null` 直接 `.map()` → `TypeError`。
本仓的窗口是透明的,React 渲染抛错的表现是**一片黑,且不报错**
(见 `docs/lessons/ui-desktop.md`「黑屏多半是 JS 崩了」)。
也就是说:一个库刚好一条收藏都没有 / 一个分面刚好 404,整页就黑了。

**发生过的三处**(`core/emby/filters.go`、`core/emby/lists.go`):

| 函数 | 何时为空 | 修法 |
|---|---|---|
| `facet` | 分面端点 404(某 fork 上 `/Tags`、`/OfficialRatings` 恒 404) | `out := []string{}` 起手 |
| `yearRange` | 探针拿不到年份 | `return []int64{}` |
| `fetchAllPaged` | 一条收藏都没有 | `out := []Item{}` 起手 |

**规矩:每移植一个返回列表的函数,过一眼「空结果那条路返回的是不是 nil」。**
`make([]T, 0, n)` 和 `[]T{}` 都行,`var x []T` 不行。

**怎么钉住:** 语料 `emby.favorites.01-一条都没有时给空数组不是null.json` ——
上游回 `{"Items":[]}`,期望 `[]`。注入 `var out []Item` 后报
「(根) 类型不同:期望数组,实得 nil」。

> 反向也要注意:**故意返回 `nil` 的地方要写清楚**。
> `core/emby/commands.go` 的 `strList` 就故意返回 `nil` ——
> 下游把「nil」和「空数组」当同一件事(「没点名 = 全要」),不该在那里造出区别。

---

<a id="t2"></a>
## T2. `Option<String>` 的 `.or()` 短路:`Some("")` 不会回落

**2026-08-31 差分对账抓到,`date_updated`。**

Rust:

```rust
r.date_last_media_added.or(r.date_created)
```

`.or()` 只在 `None` 时取后者。字段存在但是**空串**时它是 `Some("")` ——
**不回落**,结果就是空串(再经 `.filter(非空)` 折成 `null`)。

我第一版 Go 写成「前者为空就用后者」,于是空串时回落到了 `DateCreated`。

**它错了会长什么样:** 媒体库按「更新时间」排序时,一批本该排在最后的条目
(服务端没给 `DateLastMediaAdded`,只给了空串)插进了中间。**没有任何报错。**

**规矩:`.or()` / `.or_else()` 照抄成「前者是 nil 才取后者」,不是「前者为空才取后者」。**
两者只在「有值但值为空」时不同 —— 而 Emby 的字段里那种情况很常见。

---

<a id="t3"></a>
## T3. `sort_by` 不稳定,`SliceStable` 才等价

Rust 的 `Vec::sort_by` 是**稳定**排序(标准库保证)。
Go 的 `sort.Slice` **不稳定**,`sort.SliceStable` 才是。

**它错了会长什么样:** 详情页演职人员「导演优先排前,**其余保持服务端顺序**」——
服务端那个顺序是按重要性排的。用了不稳定排序,主演的顺序每次刷新都可能不一样,
而且看起来只是「顺序有点怪」,不像 bug。

**规矩:Rust 侧只要用了 `sort_by` / `sort_by_key`,Go 侧一律 `sort.SliceStable`。**
只有明确知道「顺序无所谓」时才用 `sort.Slice`。

**怎么钉住:** 语料 `emby.detail.01-背景图与演职人员排序.json` 里排了三个人,
不给导演提前就报「people[0].id 期望 p-c 实得 p-a」。

---

<a id="t4"></a>
## T4. 空串折 `null` 这件事,每个结构体的口径都不一样

同一个字段名,在两个结构体里的处理**可以是不同的**,而且那不是笔误:

| 结构体 | `series_name` | 出处 |
|---|---|---|
| `Item`(列表卡片) | 空串折 `null` | Rust 侧 `.filter(\|s\| !s.is_empty())` |
| `ItemDetail`(详情页) | **不折**,空串原样 | Rust 侧只有 `.as_str().map()` |

**规矩:逐字段照抄,不许「统一一下」。**
移植时看到两处不一致,先假定它是有意的 —— 去 `git log -S` 查那行是什么时候加的。
真是笔误的话,改它属于**改黄金实现的行为**,要单独提出来,不能夹在移植提交里
(会破坏差分对账的基准,见 `docs/go-migration/README.md` 的三条硬规矩)。

---

<a id="t5"></a>
## T5. serde 的 `default = "…"` 在 Go 这边一个都不存在

**移植 `Prefs` 时发现,是这份清单里目前最贵的一条。**

Rust 的 `Prefs` 有 14 个字段带 `#[serde(default = "…")]`,缺字段时拿到的是
`true` / `1.0` / `"auto-safe"` / `512MB` / `3` / `40`。
Go 的 `encoding/json` 缺字段时**一律零值**。

```go
var p Prefs
json.Unmarshal(raw, &p)   // ← 这一行把 14 个默认值全变成了 false / 0 / ""
```

**它错了会长什么样:** 老用户升级之后 ——

| 字段 | 零值的后果 |
|---|---|
| `sub_enabled` | **字幕默认不开了** |
| `default_speed` | 变成 0 倍速,**根本放不出来** |
| `hwdec` | 空串直接喂 mpv = 走软解,用户:「我没关硬解啊怎么这么卡」 |
| `preview_thumbs` | 进度条悬停缩略图没了 |
| `dolby_auto_sw` | DV 走硬解,画面发绿/发紫 |
| `preload_enabled` | 起播慢回去了,没人知道为什么 |
| `prefetch_threads` | 0 线程 |

而且**配置文件看上去一点问题都没有** —— 它只是少了几个键,那本来就是合法的。

**规矩:凡是 Rust 侧带 `serde(default = …)` 的结构体,Go 侧解析必须
「先造一份默认值,再往上面盖」,绝不 unmarshal 进零值结构体。**

```go
func ParsePrefs(raw json.RawMessage) Prefs {
    p := DefaultPrefs()          // ← 起手就是默认值
    json.Unmarshal(raw, &p)      // 有的键才覆盖
    return p.Clamped()
}
```

**怎么钉住:** `core/config/prefs_test.go` 的
`TestParsePrefs缺字段要拿到默认值不是零值` —— 拿一份**只有一个键**的 prefs 去解,
把每个「默认非零」的字段都点一遍。改成从零值起手,一次报 7 条红。

> 反向也要看一眼:默认**关**的那几个(`cross_server_resume` /
> `cross_server_writeback`)零值恰好是对的,但那是巧合不是设计。
> 同一条测试里也断言了它们必须是关的 —— 哪天有人「顺手把默认值都改成 true」会红。

---

<a id="t6"></a>
## T6. 「读的时候钳」和「写的时候拒」是两件事,不许统一

Rust 侧 `get_prefetch_settings` 把越界值**钳**回合法区间,
`set_prefetch_settings` 对越界值**报错**。移植时很容易觉得「重复了,统一成一种吧」。

两种都错:

| 只钳不拒 | 只拒不钳 |
|---|---|
| 用户设 8 线程 / 8GB,界面显示成功,**实际生效 4 线程 / 4GB**,毫无反馈,下次他还会再设一遍 | 老配置里存着离谱值(Rust 侧真发生过:旧配置存 1GB,新校验是 16~32MB),**设置页一保存就被拒**,用户连「打开某台服务器」都点不动,而且不知道哪儿不对 |

**规矩:**

- `core/config` 的 `Clamped()` —— 读的时候钳,保证界面永远打得开
- `core/prefs` 的 setter —— 写的时候拒,保证用户设的值要么生效要么报错

**怎么钉住:** `core/prefs/prefs_test.go` 的
`TestSetters拒绝越界而不是悄悄钳`(8 个子用例)与
`TestGetters对老配置里的离谱值要钳`。把 setter 改成钳,第一条当场红。
