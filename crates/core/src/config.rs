// 应用配置 + 服务器账号持久化。
// Phase 1:落地"重启免登"——把登录后的 token/user 存盘,下次启动直接进库。
// ponytail: token 目前明文存 config.json(与 PoC 同等安全姿态);是否升级 OS 钥匙串(keyring)见交付说明的待决项。
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// 一条备用线路(同一服务器的不同入口:直连/CDN/内网)。对齐 Dart ServerLine。
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct ServerLine {
    pub id: String,
    pub name: String,
    pub url: String,
    #[serde(default)]
    pub remark: Option<String>,
}

/// 一个已登录的服务器账号。**统一承载 Emby 与浏览型源**(靠 source_kind 区分),
/// 对齐 Dart 的 ServerConfig —— 旧栈只有一张服务器表,新栈也只能有一张。
///
/// 身份键仍是 `server`(归一化后不带尾斜杠):前端既有的 server_id 参数就是它,别换。
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct Account {
    pub server: String, // 归一化后不带尾斜杠
    pub token: String,
    pub user_id: String,
    pub user_name: String,

    /// 显示名;空则由 [`Account::display_name`] 回落到 host。
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub remark: Option<String>,
    #[serde(default)]
    pub icon_url: Option<String>,
    /// 登录密码(可选)。用于需重新登录的场景 + 插件 emby.credentials 权限。
    #[serde(default)]
    pub password: Option<String>,
    /// 备用线路;空表示只用 `server` 本身。
    #[serde(default)]
    pub lines: Vec<ServerLine>,
    #[serde(default)]
    pub active_line: usize,
    /// 是否信任该服务器的自签名/无效 TLS 证书(不安全)。默认 false=严格校验。
    /// 仅对本服务器主机放行,不影响更新下载/WebDAV/其它主机。
    #[serde(default)]
    pub allow_insecure_tls: bool,
    /// 源类型:emby(默认)/ openlist / quark / anirss / feiniu / stremio,
    /// 或插件贡献的 `plugin:<插件id>/<源id>`。是**开放键**,见 `source::SourceKind`。
    /// `SourceKind::default()` 就是 emby,故直接 `#[serde(default)]` 即可。
    #[serde(default)]
    pub source_kind: crate::source::SourceKind,
    /// 浏览型源的连接凭据;source_kind 为 emby 时为 None。
    #[serde(default)]
    pub source: Option<crate::source::SourceServer>,
}

impl Account {
    /// 当前生效的线路地址(原始上游,**不经** CF 优选反代改写)。
    /// 对齐 Dart 的 directLineUrl:越界下标钳回合法区间,而不是 panic。
    pub fn direct_line_url(&self) -> &str {
        if self.lines.is_empty() {
            return &self.server;
        }
        let i = self.active_line.min(self.lines.len() - 1);
        &self.lines[i].url
    }

    /// 当前生效的线路地址。**会被 CF 优选反代改写**:当前这条线路开了优选反代时返回本地
    /// 反代基址(`http://127.0.0.1:port/...`),让 API 请求与 mpv 取流都改走优选 CF IP。
    /// 需要原始上游地址(起反代自身的上游、编辑线路、展示给用户看)时用 [`Account::direct_line_url`]。
    ///
    /// 这是 CF 优选的**唯一 choke point** —— 取基址一律走这里,新增取流路径别绕开它,
    /// 否则会出现「API 走优选、取流仍走原线」这种一半生效的静默故障。
    ///
    /// ★ 查表用的是 **direct_line_url()(当前那条线)**,不是 self.server(整台服)。
    ///   按服务器查等于把这台服的每条线都劫持到同一个反代上,而反代的上游 host 是开启时
    ///   那条线定死的 —— 切到没走 CF 的线路后,请求会被送去「A 线的域名 + 钉死的 CF IP」,
    ///   连得上但拿不到数据,且不报错(见 net::cf::runtime 顶部)。
    pub fn active_line_url(&self) -> String {
        let direct = self.direct_line_url();
        crate::net::cf::runtime::local_url_for(direct).unwrap_or_else(|| direct.to_string())
    }

    /// 显示名:优先用户起的名,否则回落 host,再否则整个 URL。
    pub fn display_name(&self) -> String {
        if !self.name.trim().is_empty() {
            return self.name.clone();
        }
        self.server
            .split("://")
            .nth(1)
            .and_then(|s| s.split('/').next())
            .filter(|h| !h.is_empty())
            .unwrap_or(&self.server)
            .to_string()
    }

    pub fn is_file_browse(&self) -> bool {
        !self.source_kind.is_emby()
    }
}

/// 线路 url 归一化(去尾斜杠 + 去空白)。**去重必须用它** ——
/// 服主表里写 `https://a.com/`、用户手填 `https://a.com`,不归一化就会重复加一条,
/// 每点一次「同步线路」表就长一截。
fn norm_line_url(u: &str) -> String {
    u.trim().trim_end_matches('/').to_string()
}

/// 把服主下发的线路并入账号的线路表。返回**新增**条数。
///
/// ## 只增不删(见 sync_lines 命令上的说明)
/// 用户手填的内网/自建线路服主表里没有,整表覆写等于删用户配置 —— 而他多半正是在
/// 「线路连不上」时点的同步。
///
/// ## active_line 跟着 url 走,不跟着下标走
/// active_line 是**下标**。空表时 direct_line_url() 回落 `server` 本身,一旦同步进来 N 条,
/// 下标 0 就从「server」变成了「服主的第一条线路」—— 用户点个同步,生效线路被悄悄换掉。
/// 所以:合并前先记下当前生效的 url,合并后按 url 找回下标。
pub fn merge_lines(a: &mut Account, remote: &[crate::emby::ExtDomain]) -> usize {
    // ★ 先记住「现在实际在用哪个地址」。空表时它是 server 本身,不是任何一条 lines。
    let active_url = norm_line_url(a.direct_line_url());

    /* 表为空 = 一直在用 `server` 裸地址。必须先把它显式落成第一条线路,
       否则同步完 lines[0] 变成服主的线路,用户原来那条就从表里消失了。 */
    if a.lines.is_empty() {
        a.lines.push(ServerLine {
            id: "origin".into(),
            name: "主线".into(),
            url: a.server.clone(),
            remark: None,
        });
    }

    let mut added = 0;
    for d in remote {
        let u = norm_line_url(&d.url);
        if u.is_empty() || a.lines.iter().any(|l| norm_line_url(&l.url) == u) {
            continue; // 已有,跳过(名字以本地为准:用户可能改过备注)
        }
        a.lines.push(ServerLine {
            // id 用 url 而非序号:序号会随表变动,url 是这条线路的天然身份。
            id: u.clone(),
            name: if d.name.trim().is_empty() { u.clone() } else { d.name.trim().to_string() },
            url: d.url.trim().to_string(),
            remark: Some("服务器下发".into()),
        });
        added += 1;
    }

    // 按 url 找回原来那条的下标;找不到(理论上不会)就保守钳回合法区间。
    a.active_line = a
        .lines
        .iter()
        .position(|l| norm_line_url(&l.url) == active_url)
        .unwrap_or_else(|| a.active_line.min(a.lines.len() - 1));
    added
}

/// 播放偏好(语言选轨)。
#[derive(Serialize, Deserialize, Clone)]
pub struct Prefs {
    pub audio_lang: Option<String>,
    pub sub_lang: Option<String>,
    pub sub_enabled: bool,
    /* 正则优先选择(wiki: /wiki/regex-filters)。空 = 不启用,回退到上面的语言偏好。
       优先级:手动选过的 ＞ 正则命中 ＞ 语言/服务端默认。
       校验必须走 media::validate_track_regex(Rust regex crate),**不能**用前端的 JS RegExp:
       两套语法集不同(Rust 无前后瞻),JS 放行而 Rust 编译不过的表达式会静默失效。 */
    #[serde(default)]
    pub version_regex: String,
    #[serde(default)]
    pub sub_regex: String,
    #[serde(default)]
    pub audio_regex: String,
    /* 这里曾有 `shader_strength: u8`(0~100 的滤镜强度)+ UI 上一个让用户自己拧的 stepper。
       用户 2026-07-15 否掉:「强度不是靠用户调的 是让你设计挡位的……用户又不会调 没用啊」。
       强度现在**烧死在档位里**(src-tauri/src/shaders.rs 的 preset()),梯度由档位名承诺。
       别再把调参外包给用户。旧配置里残留的这个键会被 serde 忽略,不用迁移。 */
    /// 跨服务器续播:在别的服务器看过同一部片时,用本地记录里的最大进度起播。
    /// 默认关 —— 它会让「这台服上没看过的片」也从中间起播,得用户明确要才开。
    #[serde(default)]
    pub cross_server_resume: bool,
    /// 跨服回传主开关:看完/进度写回**其它**服务器。
    /// 默认关 —— 它会往别人的服务器写数据,必须用户主动开(对齐 Dart 默认值)。
    #[serde(default)]
    pub cross_server_writeback: bool,
    /// 回传范围:"all" 所有看过的服 / "first" 仅初次 / "latest" 仅最近。
    /// 存 wire 字符串而非枚举:Prefs 在 config 里,枚举在 watch_history 里,
    /// 这么存免得 config 反过来依赖 watch_history。取用时 WritebackRange::from_wire。
    #[serde(default = "default_writeback_range")]
    pub cross_server_writeback_range: String,
    /// 回传时是否连播放进度一起同步(关掉则只同步「已看完」标记)。默认开。
    #[serde(default = "default_true")]
    pub cross_server_writeback_progress: bool,
    /* 多线程加载(本地预取代理)开在**哪些服务器**上。存 Account.server(归一化身份键),
       空表 = 全部关闭,也是默认值。
       ## 为什么是「按服务器」而不是一个全局开关
       它是**优化**不是功能:能不能加速取决于对端(远程 Emby 有收益;局域网/NAS 本就跑满,
       多开几条 Range 只是白白多占连接)。所以只能由用户按服务器主动开,不给全开的入口。
       ## 粒度是服务器,不是线路
       一台服的多条线路(直连/CDN/内网)是同一个源的不同入口,选中这台服 = 它**所有**线路
       都走预取;线路是用户随手切的,再让他逐线路配一遍纯属折腾。
       ## 默认关
       2026-07-15 实测开着会放不出来(有流量、黑屏无声、永远缓冲);根因(并发连接共用
       一份取数游标)已于 2026-07-17 修掉,见 net/prefetch.rs 顶部说明 + 那条并发回归测试。
       但「修好了」不等于「该默认开」—— 它仍是拿风险换速度,继续让用户按服务器自己选。 */
    #[serde(default)]
    pub prefetch_servers: Vec<String>,
    /// 预取并发线程数。引擎内部 clamp(2,4),这里存原值。
    #[serde(default = "default_prefetch_threads")]
    pub prefetch_threads: usize,
    /// 截图保存目录。`None` = 系统图片文件夹下的 `LinPlayer/`。
    ///
    /// 截图是**用户要拿去用的产物**,不是程序残留 —— 所以默认落系统图片文件夹(好找),
    /// 而不是跟着 downloads 一起塞进 userdata/(那儿翻起来费劲)。
    #[serde(default)]
    pub screenshot_dir: Option<String>,
    /// 读前缓冲上限(字节)。**每条播放连接**各占这么多内存,故上限 32MB。
    ///
    /// 旧配置里存的是 1GB(那时它被误当成下限用,见 net/prefetch.rs 的 read_ahead_bytes)。
    /// 引擎会把超限值钳回 32MB,但**读出来给设置页时也要钳**——否则设置页拿到 1GB、
    /// 一保存就被核层拒(新校验是 16~32MB),用户连"打开某台服务器"都点不动。
    #[serde(default = "default_prefetch_cache")]
    pub prefetch_cache_bytes: u64,

    /* ===== 预加载(net::preload)=====
       进详情页就把「即将要播的那个流」的头/尾两段跑热,读完即丢。和上面的多线程加载
       **不是一回事**:那个是播放中在本地起代理喂 mpv,这个是播放前把路跑通。
       ## 为什么默认开
       它只花一次几十 MB 的流量,换掉起播时那几百毫秒的冷握手 + 冷 seek,对远程 Emby
       收益最直接;而且不改播放地址、不落盘,没有 prefetch 那种「开了放不出来」的风险面。
       计费网络/手机流量的用户可以关。
       ## 为什么不按服务器
       预热是对**当前正在看的那个条目**做的,用户人就在那台服的详情页上,再让他去
       另一个页面按服务器配一遍毫无意义。 */
    #[serde(default = "default_true")]
    pub preload_enabled: bool,
    /// 头部预热量(MB)。0 = 只热尾部索引。默认 32,对齐旧 Dart preload_service。
    #[serde(default = "default_preload_head_mb")]
    pub preload_head_mb: u64,

    /* ===== 播放器默认行为 =====
       这 6 项 2026-07-19 前只存在前端 localStorage("lp.playback.local"),设置页自己都写着
       「核心尚无落点,仅存本机、尚未影响实际播放」—— 用户改了没有任何效果。现在落到这里,
       由 src-tauri 的 play()/play_external() 在**每次起播时**应用。
       为什么归 Prefs 而不是按服务器:它们是**播放器**行为(解码器、倍速、外部程序),
       跟对端服务器无关 —— 与 prefetch_servers 那种「取决于对端」的优化不是一回事。 */
    /// 默认解码方式:`"auto-safe"` 硬解(默认) / `"no"` 软解。
    /// 值直接喂 mpv 的 hwdec,别在这里存 "hw"/"sw" 再到处翻译。
    #[serde(default = "default_hwdec")]
    pub hwdec: String,
    /// 默认倍速。起播时应用一次,播放中用户再调不回写这里(那是临时调整)。
    #[serde(default = "default_speed")]
    pub default_speed: f64,
    /// 自动跳过片头。依赖**服务端章节**,没刮削章节的库自动静默不工作。
    /// 片头片尾是**两个**开关:播放页「更多」面板里就是两行,一个字段喂两行会出现
    /// 「点片头把片尾也翻了」。设置页也照这个粒度给两行,两处口径必须一致。
    #[serde(default)]
    pub skip_intro: bool,
    /// 自动跳过片尾。只在片尾后面还有内容(下集预告)时才会真跳,见 emby::outro_range。
    #[serde(default)]
    pub skip_outro: bool,
    /// 进度条悬停缩略图。数据来自服务端章节图,没有则退回纯时间气泡。
    #[serde(default = "default_true")]
    pub preview_thumbs: bool,
    /// 杜比视界自动软解:识别到 DV 时强制 `hwdec=no`。
    /// 默认开 —— DV 走硬解在多数 Windows 显卡上出色偏移(发绿/发紫),软解画面才是对的。
    #[serde(default = "default_true")]
    pub dolby_auto_sw: bool,
    /// 外部播放器可执行文件路径。非空 = 起播时交给它,不走内置 mpv。
    #[serde(default)]
    pub external_player: String,

    /* 应用内更新(见 crate::update)。两个渠道对应 CI 的两种产物:
       stable = publish.yml 提升出的正式 Release,prerelease = build.yml 推出的 -pre。 */
    /// 更新渠道。默认稳定版 —— 不能让普通用户默认吃到每次推 main 的构建。
    #[serde(default)]
    pub update_channel: crate::update::UpdateChannel,
    /// 启动时自动检查更新。关掉之后只剩设置页里的手动检查。
    #[serde(default = "default_true")]
    pub update_auto_check: bool,

    /// 详情页背景图的模糊强度,0~100(0=完全不糊,能看清背景图;100=糊成纯色块)。
    /// 归 Prefs 是因为它是**观感偏好**,不是主题 —— 换主题不该把它重置。
    #[serde(default = "default_detail_blur")]
    pub detail_blur: u8,
}
fn default_detail_blur() -> u8 {
    40
}
fn default_hwdec() -> String {
    "auto-safe".to_string()
}
fn default_speed() -> f64 {
    1.0
}
/// 倍速合法区间。设置页与命令层共用 —— 别各写各的(prefetch_cache 就吃过这个亏)。
pub const SPEED_MIN: f64 = 0.25;
pub const SPEED_MAX: f64 = 4.0;
fn default_prefetch_threads() -> usize {
    3
}
fn default_prefetch_cache() -> u64 {
    512 * 1024 * 1024
}
/// 预热头部量(MB)。32 = 旧 Dart preload_service 的口径,别随手改小:
/// 太小盖不住起播后头几秒的解码,预热就白做了。
fn default_preload_head_mb() -> u64 {
    32
}
/// 预热头部量的合法区间(MB)。0 = 只热尾部索引;上限 512,再大就不是「预热」是「下载」了。
pub const PRELOAD_HEAD_MB_MAX: u64 = 512;
/// 缓存上限的合法区间(字节)。设置页与命令层共用,别各写各的。
///
/// ★ 2026-07-19 从 16~32MB 放开到 64MB~4GB:分段以前全在**内存**里,峰值还要乘活跃
/// 连接数,所以只敢给 32MB;现在改成落盘环形缓存(net/prefetch.rs 的 DiskCache),
/// 内存只留传输中的那几段,这个值变成**磁盘占用上限**,GB 级才有意义。
pub const PREFETCH_CACHE_MIN: u64 = 64 * 1024 * 1024;
pub const PREFETCH_CACHE_MAX: u64 = 4 * 1024 * 1024 * 1024;
fn default_writeback_range() -> String {
    "all".to_string()
}
impl Default for Prefs {
    fn default() -> Self {
        Self {
            audio_lang: None,
            sub_lang: None,
            sub_enabled: true,
            version_regex: String::new(),
            sub_regex: String::new(),
            audio_regex: String::new(),
            cross_server_resume: false,
            cross_server_writeback: false,
            cross_server_writeback_range: default_writeback_range(),
            cross_server_writeback_progress: true,
            screenshot_dir: None, // 系统图片文件夹/LinPlayer
            prefetch_servers: Vec::new(), // 见字段上的说明:空表=全关,只能按服务器主动开
            prefetch_threads: default_prefetch_threads(),
            prefetch_cache_bytes: default_prefetch_cache(),
            preload_enabled: true,
            preload_head_mb: default_preload_head_mb(),
            hwdec: default_hwdec(),
            default_speed: default_speed(),
            skip_intro: false,
            skip_outro: false,
            preview_thumbs: true,
            dolby_auto_sw: true,
            external_player: String::new(),
            update_channel: crate::update::UpdateChannel::Stable,
            update_auto_check: true,
            detail_blur: default_detail_blur(),
        }
    }
}

/// 自建弹幕服务器(兼容弹弹Play /api/v2 接口)。可配多个:并行分源、用户挑。
#[derive(Serialize, Deserialize, Clone, Default)]
pub struct DanmakuServer {
    /// 稳定 id(前端增删改的身份键)。旧配置迁移过来的固定为 "custom"。
    #[serde(default)]
    pub id: String,
    /// 显示名;空则前端回落 host。
    #[serde(default)]
    pub name: String,
    pub api_url: String,
    pub auth_type: String, // none | pathToken | headerToken | queryToken
    pub token: String,
    #[serde(default = "default_true")]
    pub enabled: bool,
    /// 越小越先用(并行拉取后按它排序挑主源)。
    #[serde(default)]
    pub priority: i32,
}

/// 用户自定义代理(三端通用)。type 为 none 时不启用。
/// HTTP/HTTPS 走 CONNECT 隧道;SOCKS5 依赖 reqwest "socks" 特性。
/// ⚠️ libmpv 仅支持 HTTP 代理(http-proxy),SOCKS 只对 API/图片/字幕/下载生效。
#[derive(Serialize, Deserialize, Clone, PartialEq)]
pub struct ProxyConfig {
    #[serde(rename = "type")]
    pub type_: String, // none | http | https | socks5 | socks4
    pub host: String,
    pub port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    /// 是否让媒体流(mpv 播放)也走代理(仅 HTTP 系列有效)。
    #[serde(default = "default_true")]
    pub proxy_media: bool,
}
fn default_true() -> bool {
    true
}
impl Default for ProxyConfig {
    fn default() -> Self {
        Self {
            type_: "none".into(),
            host: String::new(),
            port: 0,
            username: String::new(),
            password: String::new(),
            proxy_media: true,
        }
    }
}
impl ProxyConfig {
    pub fn is_enabled(&self) -> bool {
        self.type_ != "none" && !self.host.trim().is_empty() && self.port > 0
    }
    fn is_http(&self) -> bool {
        self.type_ == "http" || self.type_ == "https"
    }
    /// reqwest/mpv 用的代理 URL(如 socks5://user:pass@host:port);未启用返回 None。
    pub fn proxy_url(&self) -> Option<String> {
        if !self.is_enabled() {
            return None;
        }
        let scheme = match self.type_.as_str() {
            "http" | "https" => "http",
            "socks5" => "socks5",
            "socks4" => "socks4a",
            _ => return None,
        };
        let auth = if self.username.is_empty() {
            String::new()
        } else {
            format!(
                "{}:{}@",
                urlencoding::encode(&self.username),
                urlencoding::encode(&self.password)
            )
        };
        Some(format!("{scheme}://{auth}{}:{}", self.host, self.port))
    }
    /// mpv http-proxy 值(仅 HTTP 系列 + 开启 proxy_media)。
    pub fn mpv_http_proxy(&self) -> Option<String> {
        if self.is_enabled() && self.is_http() && self.proxy_media {
            self.proxy_url()
        } else {
            None
        }
    }
}

/* ★ Default **不能 derive**。derive 出来的是「每个字段各自的 Default」,
     而 `bool::default()` 是 false —— 于是所有 `#[serde(default = "…")]` 写的默认值
     在「没有配置文件」这条路径上**全部失效**(load() 那里是 unwrap_or_default())。

     2026-07-21 真栽过:companion_enabled 标了 `default = "yes"`,老用户升级(配置文件
     存在、只是缺这个字段)一切正常,**全新安装/卸载重装的人手机遥控永远打不开** ——
     而且不报错,界面只说"未开启",查都没处查。

     改成走 serde 反序列化一个空对象:这样**只有一个真相来源**,以后谁再加
     `#[serde(default = ...)]` 字段都自动对齐,不必记得同步第二处。 */
#[derive(Serialize, Deserialize)]
pub struct AppConfig {
    /* ★ 这三个原本**没标 default**,是个埋着的雷:配置文件里少了任意一个,
       整份 JSON 就反序列化失败 → load() 的 `.ok()` 吞掉 → `unwrap_or_default()`
       退回空配置 → **用户所有服务器账号一次性消失,且不报错**。
       标上 default 之后,缺字段只丢那一个字段(device_id 空了 load() 会重新生成)。 */
    /// 每安装稳定不变的设备 ID(Emby DeviceId 用,影响会话/上报归属)。
    #[serde(default)]
    pub device_id: String,
    #[serde(default)]
    pub accounts: Vec<Account>,
    /// 当前活跃账号在 accounts 中的下标。
    #[serde(default)]
    pub active: Option<usize>,
    /// 播放偏好;serde(default) 兼容旧配置文件。
    #[serde(default)]
    pub prefs: Prefs,
    /// 旧配置的单个自建弹幕源。**只读不写**:load() 时迁进 danmaku_sources 后就不再落盘。
    /// 留着纯粹是为了老用户升级不丢源 —— 别在新代码里用它。
    #[serde(default, rename = "danmaku", skip_serializing)]
    legacy_danmaku: Option<DanmakuServer>,
    /// 自建弹幕源(可多个)。官方弹弹Play 不在这里:它靠编译期凭据,不由用户配。
    #[serde(default)]
    pub danmaku_sources: Vec<DanmakuServer>,
    #[serde(default)]
    pub proxy: ProxyConfig,
    /// 已连接的 Trakt 账号(令牌);None=未连接。ponytail: 与其它 token 同为明文,加固待 keyring。
    #[serde(default)]
    pub sync_trakt: Option<crate::sync::SyncAccount>,
    /// 已连接的 Bangumi 账号(令牌);None=未连接。
    #[serde(default)]
    pub sync_bangumi: Option<crate::sync::SyncAccount>,
    /// 手机控制台(局域网扫码遥控,见 crate::companion)。
    /// **默认开**:关着的话"遥控器"每次要先在电视上打开,等于没有。
    #[serde(default = "yes")]
    pub companion_enabled: bool,
    /// 界面主题("dark"/"light")的**镜像**。真正的权威在前端 localStorage ——
    /// 这里存一份只是为了手机控制台能显示当前值(它读不到 WebView 的 localStorage)。
    #[serde(default)]
    pub theme: String,
    /// 用户订阅的**第三方**插件源。官方源不在这里(它是编译期常量),
    /// 否则官方源的 URL 一旦改动,老用户的配置文件里会永远钉着旧地址。
    #[serde(default)]
    pub plugin_sources: Vec<crate::plugins::PluginSource>,
    /// 官方插件源开关。**可禁不可删**:删掉之后新用户开箱即空,再想找回来只能手打 URL。
    #[serde(default = "yes")]
    pub plugin_official_enabled: bool,
}

fn yes() -> bool {
    true
}

impl Default for AppConfig {
    /// 走 serde 反序列化一个空对象 —— 保证「没有配置文件」和「配置文件里缺字段」
    /// 拿到的是**同一份**默认值(每个字段的 `#[serde(default)]`)。
    /// 空对象一定能反序列化成功(所有字段都有 default),真炸了也宁可 panic:
    /// 那说明有字段漏标 default,是编码错误,不该悄悄退回一份半残配置。
    fn default() -> Self {
        serde_json::from_str("{}").expect("AppConfig 有字段没标 #[serde(default)]")
    }
}

fn config_path() -> PathBuf {
    crate::paths::config_file()
}

fn gen_device_id() -> String {
    // 首次运行生成一个稳定 ID:安装时的纳秒时间戳足够唯一,之后持久化不变。
    use std::time::{SystemTime, UNIX_EPOCH};
    let n = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(0);
    format!("linplayer-{n:x}")
}

impl AppConfig {
    /// 读盘;不存在则建默认。保证 device_id 非空(新生成则立即落盘)。
    pub fn load() -> Self {
        let mut cfg: AppConfig = std::fs::read_to_string(config_path())
            .ok()
            .and_then(|s| serde_json::from_str(&s).ok())
            .unwrap_or_default();
        let mut dirty = false;
        if cfg.device_id.is_empty() {
            cfg.device_id = gen_device_id();
            dirty = true;
        }
        // 迁移:旧配置的单个自建弹幕源 -> 多源表。只在多源表还空时做,别把用户后来配的覆盖了。
        if let Some(old) = cfg.legacy_danmaku.take() {
            if cfg.danmaku_sources.is_empty() && !old.api_url.trim().is_empty() {
                cfg.danmaku_sources.push(DanmakuServer {
                    id: "custom".into(),
                    name: "自建源".into(),
                    enabled: true,
                    ..old
                });
            }
            dirty = true; // legacy 字段 skip_serializing,存一次就从盘上消失了
        }
        if dirty {
            cfg.save();
        }
        // 必须无条件同步:save() 只在 dirty 时走,干净加载时白名单会是空的 ——
        // 表现为"重启后自签名服务器全连不上,重新勾一次又好了"。
        cfg.sync_insecure_hosts();
        cfg
    }

    /// 启用的自建弹幕源,按 priority 升序。宿主据此组多源请求。
    pub fn enabled_danmaku_sources(&self) -> Vec<DanmakuServer> {
        let mut v: Vec<_> = self.danmaku_sources.iter().filter(|s| s.enabled).cloned().collect();
        v.sort_by_key(|s| s.priority);
        v
    }

    pub fn save(&self) {
        let path = config_path();
        if let Some(parent) = path.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        if let Ok(json) = serde_json::to_string_pretty(self) {
            let _ = std::fs::write(path, json);
        }
        self.sync_insecure_hosts();
    }

    /// 把「允许自签名」的账号 host 同步进 HTTP 层白名单。
    /// 挂在 load/save 上是故意的:每条改账号的路径最后都会 save,搭在这儿就不会漏
    /// —— 漏了的后果是用户勾了"允许自签名"却连不上、或取消了勾选却还在放行,两头都不响。
    fn sync_insecure_hosts(&self) {
        let hosts = self
            .accounts
            .iter()
            .filter(|a| a.allow_insecure_tls)
            // 一个账号可能配多条线路,每条都可能是不同 host,得全放进去。
            .flat_map(|a| {
                std::iter::once(a.server.clone())
                    .chain(a.lines.iter().map(|l| l.url.clone()))
            })
            .collect::<Vec<_>>();
        crate::http::set_insecure_hosts(hosts);
    }

    pub fn active_account(&self) -> Option<&Account> {
        self.active.and_then(|i| self.accounts.get(i))
    }

    /// 按 server 去重写入(同服重登刷新 token),并设为活跃账号。
    /// 重登**保留用户侧编辑**(名称/备注/图标/线路/TLS 开关)——那些不该被一次登录冲掉。
    pub fn upsert(&mut self, acc: Account) {
        match self.accounts.iter().position(|a| a.server == acc.server) {
            Some(i) => {
                let old = &self.accounts[i];
                let merged = Account {
                    name: if acc.name.is_empty() { old.name.clone() } else { acc.name },
                    remark: acc.remark.or_else(|| old.remark.clone()),
                    icon_url: acc.icon_url.or_else(|| old.icon_url.clone()),
                    lines: if acc.lines.is_empty() { old.lines.clone() } else { acc.lines },
                    active_line: old.active_line,
                    allow_insecure_tls: old.allow_insecure_tls,
                    ..acc
                };
                self.accounts[i] = merged;
                self.active = Some(i);
            }
            None => {
                self.accounts.push(acc);
                self.active = Some(self.accounts.len() - 1);
            }
        }
    }

    pub fn find(&self, server_id: &str) -> Option<&Account> {
        self.accounts.iter().find(|a| a.server == server_id)
    }

    pub fn find_mut(&mut self, server_id: &str) -> Option<&mut Account> {
        self.accounts.iter_mut().find(|a| a.server == server_id)
    }

    /// 拖拽排序。移动后修正 active 下标,让活跃账号跟着走而不是指向别人。
    pub fn reorder(&mut self, from: usize, to: usize) -> Result<(), String> {
        let n = self.accounts.len();
        if from >= n || to >= n {
            return Err("排序下标越界".into());
        }
        let active_server = self.active_account().map(|a| a.server.clone());
        let acc = self.accounts.remove(from);
        self.accounts.insert(to, acc);
        if let Some(sv) = active_server {
            self.active = self.accounts.iter().position(|a| a.server == sv);
        }
        Ok(())
    }

    /// 删除账号;活跃账号被删则回落到第一个(空表则清空活跃)。
    pub fn remove(&mut self, server_id: &str) -> bool {
        let Some(i) = self.accounts.iter().position(|a| a.server == server_id) else {
            return false;
        };
        let was_active = self.active == Some(i);
        let active_server = self.active_account().map(|a| a.server.clone());
        self.accounts.remove(i);
        // 按服务器存的开关跟着账号走:留着的话,重新加同一地址的服会「自己就开着」。
        self.prefs.prefetch_servers.retain(|s| s != server_id);
        self.active = if self.accounts.is_empty() {
            None
        } else if was_active {
            Some(0)
        } else {
            // 删的是别人:靠 server 重新定位,别让下标漂移串台。
            active_server.and_then(|sv| self.accounts.iter().position(|a| a.server == sv)).or(Some(0))
        };
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /* 「没有配置文件」和「配置文件里缺字段」必须拿到**同一份**默认值。

       这条测试是 2026-07-21 那个线上事故的直接产物:companion_enabled 标了
       `#[serde(default = "yes")]`,但 AppConfig 当时是 `#[derive(Default)]`,
       而 load() 在没有配置文件时走 `unwrap_or_default()` —— 那条路径根本不经过
       serde,于是**全新安装的人手机遥控永远是关的**,界面还说"没连上局域网",
       用户照着提示去查网线。老用户升级反而正常(配置文件在,只是缺字段),
       所以本地和 CI 都测不出来。

       反向验证:把 AppConfig 改回 #[derive(Default)],本测试立刻红。 */
    #[test]
    fn default_equals_deserializing_an_empty_object() {
        let from_default = AppConfig::default();
        let from_empty: AppConfig = serde_json::from_str("{}").unwrap();
        assert_eq!(
            serde_json::to_value(&from_default).unwrap(),
            serde_json::to_value(&from_empty).unwrap(),
            "AppConfig::default() 和「反序列化空对象」结果不一致 ——              多半是 derive(Default) 把某个 #[serde(default = \"…\")] 架空了"
        );
    }

    /// 手机遥控**默认开**。关着的话"遥控器"每次要先去电视上打开,等于没有。
    #[test]
    fn companion_is_on_by_default() {
        assert!(AppConfig::default().companion_enabled, "手机遥控默认必须是开的");
    }

    use super::*;

    fn acc(server: &str) -> Account {
        Account { server: server.into(), ..Default::default() }
    }

    /* 老配置里 prefetch_cache_bytes 存的是 1GB。新校验只收 16~32MB,若把旧值原样
       透给设置页,用户一点任何开关(保存整个结构体)就会被核层拒 —— 连"给某台服开多线程"
       都点不动。这里钉死:旧值必须能被钳进合法区间。
       反向验证:去掉 get_prefetch_settings 里的 clamp,这条断言仍绿(它测的是区间本身),
       真正的守卫是下面 legacy_1gb 那条。 */
    /* 老配置(没有这次新加的 6 个播放器字段)必须照常读出来,新字段吃默认值。
       这条守的是**账号丢失**:Prefs 少一个 #[serde(default)],整个 config.json 就解析失败,
       用户升级一次 = 服务器和 token 全没了。加字段时这条测试必须跟着加一个键进去验。
       反向验证方式:把某个新字段的 #[serde(default)] 删掉,这条立刻红。 */
    #[test]
    fn legacy_config_without_new_playback_fields_still_loads() {
        // 2026-07-19 之前真实 config.json 的 prefs 形状(6 个新字段一个都没有)
        let legacy = r#"{
            "audio_lang": "chi",
            "sub_lang": null,
            "sub_enabled": true,
            "cross_server_resume": true,
            "prefetch_servers": ["https://example.com"],
            "prefetch_threads": 3,
            "prefetch_cache_bytes": 33554432
        }"#;
        let p: Prefs = serde_json::from_str(legacy).expect("老配置必须能解析 —— 解析失败=用户账号全丢");
        // 老字段原样保留
        assert_eq!(p.audio_lang.as_deref(), Some("chi"));
        assert!(p.cross_server_resume);
        assert_eq!(p.prefetch_servers.len(), 1);
        // 新字段吃默认值,且默认值必须是"保持原有行为"的那个
        assert_eq!(p.hwdec, "auto-safe", "默认必须是硬解(老行为),不能因为加字段就把人切到软解");
        assert_eq!(p.default_speed, 1.0);
        assert!(!p.skip_intro, "自动跳过必须默认关 —— 默认开会让人莫名其妙被跳走");
        assert!(!p.skip_outro);
        assert!(p.preview_thumbs);
        assert!(p.dolby_auto_sw);
        assert_eq!(p.external_player, "");
        // 更新相关(2026-07-19 加)。默认必须是「稳定版 + 自动检查」——
        // 默认给预览版等于把每次推 main 的构建推给所有人。
        assert_eq!(p.update_channel, crate::update::UpdateChannel::Stable);
        assert!(p.update_auto_check);
    }

    /// 倍速区间必须包含默认值,否则老用户一进设置页就存不下(prefetch 的 1GB 就是这么炸的)。
    #[test]
    fn default_speed_is_inside_the_legal_range() {
        assert!((SPEED_MIN..=SPEED_MAX).contains(&Prefs::default().default_speed));
        assert!(SPEED_MIN > 0.0, "0 倍速 = 永远不动");
    }

    #[test]
    fn prefetch_cache_range_absorbs_legacy_values() {
        // 落盘改造后 1GB 本身就合法了(它当年就是默认值)。
        let legacy_1gb: u64 = 1024 * 1024 * 1024;
        assert!(
            (PREFETCH_CACHE_MIN..=PREFETCH_CACHE_MAX).contains(&legacy_1gb),
            "1GB 该是合法的磁盘缓存上限了"
        );
        // 但更早的小值/离谱值仍必须能钳进区间,否则设置页整个存不进去。
        for legacy in [1u64, 16 << 20, 32 << 20, 64u64 << 30] {
            let c = legacy.clamp(PREFETCH_CACHE_MIN, PREFETCH_CACHE_MAX);
            assert!((PREFETCH_CACHE_MIN..=PREFETCH_CACHE_MAX).contains(&c), "legacy={legacy}");
        }
        // 新装默认值本身必须合法(否则首次进设置页就存不了)。
        let d = Prefs::default().prefetch_cache_bytes;
        assert!(
            (PREFETCH_CACHE_MIN..=PREFETCH_CACHE_MAX).contains(&d),
            "默认值 {d} 不在 {PREFETCH_CACHE_MIN}~{PREFETCH_CACHE_MAX} 内"
        );
    }

    fn ext(name: &str, url: &str) -> crate::emby::ExtDomain {
        crate::emby::ExtDomain { name: name.into(), url: url.into() }
    }
    fn line(url: &str) -> ServerLine {
        ServerLine { id: url.into(), name: url.into(), url: url.into(), remark: None }
    }

    /// ★★ 同步线路**绝不能把用户正在用的那条线换掉**。
    ///
    /// 这条测试的第一版是**假的**:它只测了「表非空 + 追加到表尾」,而 merge_lines 本就
    /// append-only,按下标保留和按 url 保留结果一样 —— 把实现换成 `active_line.min(len-1)`
    /// 它照样绿。真正会出事的是**下标是脏的**那种:
    ///
    /// `set_lines` 的钳位写的是 `if !lines.is_empty()`,所以**传空表时 active_line 的旧值
    /// 原样留着**(lines=[] 而 active_line=2)。此时 direct_line_url() 因为空表回落 `server`,
    /// 一切正常;可一旦同步进来几条线,按下标算就会把生效线路挪到某条 CDN 上 ——
    /// 用户只是点了个「同步线路」,结果连的服务器被悄悄换了,且不报错。
    #[test]
    fn sync_keeps_the_line_user_is_actually_on() {
        let mut a = acc("https://emby.example.com");
        // 脏状态:线路表空(实际在用 server 裸地址),但下标还留着上一次的值。
        // 可达路径:set_lines(server_id, vec![]) —— 它的钳位跳过了空表分支。
        a.lines = vec![];
        a.active_line = 2;
        assert_eq!(a.direct_line_url(), "https://emby.example.com", "前提:空表时用的是裸地址");

        merge_lines(&mut a, &[ext("CDN1", "https://cdn1.com"), ext("CDN2", "https://cdn2.com")]);

        assert_eq!(
            a.direct_line_url(),
            "https://emby.example.com",
            "同步后生效线路必须还是用户原来实际在用的那个地址,不能被挪到 CDN 上"
        );
    }

    /// 追加线路后,原来那条的下标即使不变也得**指着同一个 url**(防以后有人给 merge 加排序/前插)。
    #[test]
    fn sync_appends_and_leaves_existing_lines_where_they_were() {
        let mut a = acc("https://emby.example.com");
        a.lines = vec![line("https://old-a.com"), line("https://mine.lan")];
        a.active_line = 1;
        let added = merge_lines(&mut a, &[ext("CDN1", "https://cdn1.com")]);
        assert_eq!(added, 1);
        assert_eq!(a.direct_line_url(), "https://mine.lan", "生效线路必须还是用户原来那条");
    }

    /// 用户手填的线路(内网/自建)服主表里不可能有 —— 只增不删,一条都不许丢。
    #[test]
    fn sync_never_deletes_user_lines() {
        let mut a = acc("https://emby.example.com");
        a.lines = vec![line("https://mine.lan"), line("https://my-cdn.net")];
        merge_lines(&mut a, &[ext("官方", "https://official.com")]);
        for u in ["https://mine.lan", "https://my-cdn.net"] {
            assert!(a.lines.iter().any(|l| l.url == u), "用户手填的 {u} 被同步删掉了");
        }
    }

    /// 空线路表时一直用的是 `server` 裸地址。同步必须先把它落成一条线路,
    /// 否则 lines[0] 变成服主的线路 → 用户原来能用的地址从表里凭空消失。
    #[test]
    fn sync_from_empty_table_preserves_the_bare_server_url() {
        let mut a = acc("https://emby.example.com");
        assert!(a.lines.is_empty());
        merge_lines(&mut a, &[ext("CDN", "https://cdn.com")]);
        assert_eq!(a.lines[0].url, "https://emby.example.com", "原始地址必须落成第一条");
        assert_eq!(a.direct_line_url(), "https://emby.example.com", "生效线路不能被换成 CDN");
        assert_eq!(a.lines.len(), 2);
    }

    /// 重复点「同步线路」不能让表无限膨胀。尾斜杠差异也算同一条。
    #[test]
    fn sync_is_idempotent_and_ignores_trailing_slash() {
        let mut a = acc("https://emby.example.com");
        let remote = [ext("CDN", "https://cdn.com/")]; // 服主写了尾斜杠
        assert_eq!(merge_lines(&mut a, &remote), 1);
        let n = a.lines.len();
        // 再点两次
        assert_eq!(merge_lines(&mut a, &remote), 0, "同一条线路被重复加了");
        assert_eq!(merge_lines(&mut a, &[ext("CDN", "https://cdn.com")]), 0, "尾斜杠差异被当成了新线路");
        assert_eq!(a.lines.len(), n, "重复同步让线路表膨胀了");
    }

    /// 已落盘的老配置里**还留着 `shader_strength` 这个已删字段**(上一版发过包)。
    /// 反序列化必须**忽略**它,而不是报错 —— Config::load 失败会静默回落 Default,
    /// 于是用户的所有偏好(选轨/跨服/预取)一起蒸发,而且不报错。
    /// 这条钉的是「别给 Prefs 加 deny_unknown_fields」。
    #[test]
    fn stale_shader_strength_key_from_old_builds_is_ignored_not_fatal() {
        let p: Prefs = serde_json::from_str(
            r#"{"audio_lang":"jpn","sub_lang":"chi","sub_enabled":true,"shader_strength":70}"#,
        )
        .expect("带已删字段的老配置必须还能读,否则用户偏好全丢");
        assert_eq!(p.audio_lang.as_deref(), Some("jpn"), "同一份 JSON 里的其它偏好必须留住");
        // 缺键的更老配置也得能读
        let p2: Prefs =
            serde_json::from_str(r#"{"audio_lang":null,"sub_lang":null,"sub_enabled":true}"#)
                .expect("老配置必须还能读");
        assert!(p2.sub_enabled);
    }

    #[test]
    fn direct_line_url_falls_back_and_clamps() {
        let mut a = acc("https://h:8096");
        // 无线路 → 用 server 本身。
        assert_eq!(a.direct_line_url(), "https://h:8096");
        a.lines = vec![
            ServerLine { id: "1".into(), name: "直连".into(), url: "https://direct".into(), remark: None },
            ServerLine { id: "2".into(), name: "CDN".into(), url: "https://cdn".into(), remark: None },
        ];
        a.active_line = 1;
        assert_eq!(a.direct_line_url(), "https://cdn");
        // 下标越界(线路被删过)→ 钳回最后一条,不 panic。
        a.active_line = 99;
        assert_eq!(a.direct_line_url(), "https://cdn");
    }

    /// CF 优选的 choke point 必须真的穿透到 Account 这一层 —— 否则改写表登记了、
    /// 取基址的人却拿不到,就是"开了优选没反应"。这条测的就是那根线通不通。
    #[test]
    fn active_line_url_is_rewritten_by_cf_runtime() {
        // 全局改写表被所有测试共享,用唯一地址免得和别的用例串台。
        let mut a = acc("https://cf-choke-point-test.example.com");
        a.lines = vec![ServerLine {
            id: "1".into(),
            name: "CDN".into(),
            url: "https://cf-choke-cdn.example.com".into(),
            remark: None,
        }];
        // 未开优选 → 与 direct 一致。
        assert_eq!(a.active_line_url(), "https://cf-choke-cdn.example.com");

        crate::net::cf::runtime::bind(a.direct_line_url(), "http://127.0.0.1:5001");
        assert_eq!(a.active_line_url(), "http://127.0.0.1:5001", "开了优选却没改写 = choke point 断了");
        // direct 必须**不受**改写影响:反代自己要拿它当上游,被改写就自环了。
        assert_eq!(a.direct_line_url(), "https://cf-choke-cdn.example.com");

        crate::net::cf::runtime::unbind("https://cf-choke-cdn.example.com");
        assert_eq!(a.active_line_url(), "https://cf-choke-cdn.example.com", "关了优选没恢复直连");
    }

    /* 回归:优选**只作用于开它的那条线路**,不能牵连同一台服的其它线路。
       用户 2026-08-01:「服务器有很多条线路,而且有些线路并没有使用 Cloudflare」。
       旧实现按 server_id 登记改写 —— 一开优选,这台服的每条线都被劫持到那个反代上,
       而反代上游 host 是开启时那条线定死的:切到非 CF 线路后请求打到「A 线域名 +
       钉死的 CF IP」,连得上、没数据、不报错 = 用户报的加载极慢/没画面没声音。
       反向验证:把 active_line_url() 改回按 self.server 查,本测试立刻红。 */
    #[test]
    fn cf_route_does_not_leak_to_the_other_lines_of_the_same_server() {
        let mut a = acc("https://cf-perline-test.example.com");
        a.lines = vec![
            ServerLine { id: "1".into(), name: "CF 线".into(), url: "https://cf-perline-a.example.com".into(), remark: None },
            ServerLine { id: "2".into(), name: "直连线".into(), url: "https://cf-perline-b.example.com".into(), remark: None },
        ];

        // 只给第 0 条线开优选。
        a.active_line = 0;
        crate::net::cf::runtime::bind(a.direct_line_url(), "http://127.0.0.1:5002");
        assert_eq!(a.active_line_url(), "http://127.0.0.1:5002");

        // 切到第 1 条(没走 CF 的那条)→ 必须直连,不能被上一条的反代劫持。
        a.active_line = 1;
        assert_eq!(
            a.active_line_url(),
            "https://cf-perline-b.example.com",
            "没开优选的线路被别的线路的 CF 反代劫持了 —— 上游 host 还是 A 线的,必然拉不到数据"
        );

        crate::net::cf::runtime::unbind("https://cf-perline-a.example.com");
    }

    #[test]
    fn display_name_prefers_custom_then_host() {
        let mut a = acc("https://smart.example.com/emby");
        assert_eq!(a.display_name(), "smart.example.com");
        a.name = "我的服".into();
        assert_eq!(a.display_name(), "我的服");
        // 全空白的名字不算名字。
        a.name = "   ".into();
        assert_eq!(a.display_name(), "smart.example.com");
    }

    #[test]
    fn upsert_refreshes_token_but_keeps_user_edits() {
        let mut cfg = AppConfig::default();
        cfg.upsert(Account {
            server: "https://h".into(),
            token: "old".into(),
            name: "我的服".into(),
            remark: Some("备注".into()),
            allow_insecure_tls: true,
            active_line: 1,
            lines: vec![ServerLine { id: "1".into(), name: "l".into(), url: "https://l".into(), remark: None }],
            ..Default::default()
        });
        // 重登:只带 token,不带用户编辑过的字段。
        cfg.upsert(Account { server: "https://h".into(), token: "new".into(), ..Default::default() });
        assert_eq!(cfg.accounts.len(), 1, "同服重登不该变成两条");
        let a = &cfg.accounts[0];
        assert_eq!(a.token, "new", "token 必须刷新");
        assert_eq!(a.name, "我的服", "登录不该冲掉用户起的名");
        assert_eq!(a.remark.as_deref(), Some("备注"));
        assert!(a.allow_insecure_tls, "登录不该重置 TLS 开关");
        assert_eq!(a.active_line, 1, "登录不该重置选中线路");
        assert_eq!(a.lines.len(), 1, "登录不该清空线路");
    }

    #[test]
    fn reorder_keeps_active_pointing_at_same_account() {
        let mut cfg = AppConfig::default();
        for s in ["https://a", "https://b", "https://c"] {
            cfg.upsert(acc(s));
        }
        cfg.active = Some(0); // 活跃 = a
        cfg.reorder(2, 0).unwrap(); // c 拖到最前 → [c, a, b]
        assert_eq!(cfg.accounts[0].server, "https://c");
        assert_eq!(
            cfg.active_account().unwrap().server,
            "https://a",
            "拖别人不该把活跃账号串到别的服"
        );
        assert!(cfg.reorder(0, 9).is_err(), "越界必须报错而不是 panic");
    }

    #[test]
    fn remove_relocates_active() {
        let mut cfg = AppConfig::default();
        for s in ["https://a", "https://b", "https://c"] {
            cfg.upsert(acc(s));
        }
        cfg.active = Some(2); // 活跃 = c
        assert!(cfg.remove("https://a"));
        assert_eq!(cfg.active_account().unwrap().server, "https://c", "删别人不该改活跃账号");
        // 删活跃的 → 回落第一个。
        assert!(cfg.remove("https://c"));
        assert_eq!(cfg.active_account().unwrap().server, "https://b");
        assert!(cfg.remove("https://b"));
        assert!(cfg.active.is_none(), "删空后不该留下悬空下标");
        assert!(!cfg.remove("https://nope"));
    }

    #[test]
    fn old_config_json_still_loads() {
        // 回归:老配置文件没有新字段,必须靠 serde(default) 读得进来,否则用户升级即丢账号。
        let old = r#"{"device_id":"d","accounts":[{"server":"https://h","token":"t","user_id":"u","user_name":"n"}],"active":0}"#;
        let cfg: AppConfig = serde_json::from_str(old).expect("老配置必须能读");
        assert_eq!(cfg.accounts.len(), 1);
        let a = &cfg.accounts[0];
        assert_eq!(a.token, "t");
        assert!(a.source_kind.is_emby(), "老账号必须默认当 Emby");
        assert!(a.source.is_none());
        assert!(a.lines.is_empty());
    }

    #[test]
    fn legacy_single_danmaku_migrates_to_sources() {
        // 老配置只有一个 danmaku 对象 → 必须迁进多源表,否则用户升级即丢弹幕源。
        let old = r#"{"device_id":"d","accounts":[],"danmaku":{"api_url":"https://dm","auth_type":"pathToken","token":"tk"}}"#;
        let mut cfg: AppConfig = serde_json::from_str(old).unwrap();
        assert!(cfg.danmaku_sources.is_empty(), "迁移前多源表是空的");
        // load() 里的迁移段(这里手动跑,load 会读真实用户目录不适合单测)。
        if let Some(o) = cfg.legacy_danmaku.take() {
            if cfg.danmaku_sources.is_empty() && !o.api_url.trim().is_empty() {
                cfg.danmaku_sources.push(DanmakuServer { id: "custom".into(), enabled: true, ..o });
            }
        }
        assert_eq!(cfg.danmaku_sources.len(), 1);
        assert_eq!(cfg.danmaku_sources[0].api_url, "https://dm");
        assert_eq!(cfg.danmaku_sources[0].token, "tk");
        assert!(cfg.danmaku_sources[0].enabled, "迁移来的源必须默认启用,不然弹幕悄悄没了");
        // 迁移后不该再把 legacy 字段写回盘。
        let json = serde_json::to_string(&cfg).unwrap();
        assert!(!json.contains("\"danmaku\":"), "legacy 字段必须 skip_serializing");
        assert!(json.contains("danmaku_sources"));
    }

    #[test]
    fn enabled_danmaku_sources_filters_and_sorts() {
        let mut cfg = AppConfig::default();
        cfg.danmaku_sources = vec![
            DanmakuServer { id: "b".into(), priority: 2, enabled: true, ..Default::default() },
            DanmakuServer { id: "off".into(), priority: 0, enabled: false, ..Default::default() },
            DanmakuServer { id: "a".into(), priority: 1, enabled: true, ..Default::default() },
        ];
        let ids: Vec<_> = cfg.enabled_danmaku_sources().into_iter().map(|s| s.id).collect();
        assert_eq!(ids, ["a", "b"], "停用的要滤掉,其余按 priority 升序");
    }

    #[test]
    fn proxy_url_builds_scheme_and_auth() {
        let mut p = ProxyConfig { type_: "socks5".into(), host: "h".into(), port: 1080, ..Default::default() };
        assert_eq!(p.proxy_url().as_deref(), Some("socks5://h:1080"));
        p.username = "u".into();
        p.password = "p@ss".into();
        assert_eq!(p.proxy_url().as_deref(), Some("socks5://u:p%40ss@h:1080"));
        // socks 不给 mpv;http 系列才给。
        assert!(p.mpv_http_proxy().is_none());
        let h = ProxyConfig { type_: "http".into(), host: "h".into(), port: 8080, proxy_media: true, ..Default::default() };
        assert_eq!(h.mpv_http_proxy().as_deref(), Some("http://h:8080"));
        // 关闭 proxy_media → 不给 mpv。
        let h2 = ProxyConfig { proxy_media: false, ..h.clone() };
        assert!(h2.mpv_http_proxy().is_none());
        // 未启用 → None。
        assert!(ProxyConfig::default().proxy_url().is_none());
    }
}
