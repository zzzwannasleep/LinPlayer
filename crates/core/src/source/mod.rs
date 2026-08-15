// 文件浏览型数据源后端抽象(网盘/聚合/追番),对齐 Dart 的 media_source_backend.dart。
// 三件事:列目录 / 搜索(可降级)/ 把文件解析成可播 URL(含逐流 headers)。
use serde::{Deserialize, Serialize};
use std::collections::HashMap;

pub mod aliyundrive;
pub mod anirss;
pub mod baidu;
pub mod feiniu;
pub mod ftp;
pub mod local;
pub mod openlist;
pub mod pan115;
pub mod pan115_crypto;
pub mod pan139;
pub mod pan189;
pub mod plugin_source;
pub mod quark;
pub mod quark_tv;
pub mod smb;
pub mod webdav;

/// 源类型标识。**开放键**:内置源是固定小写字面量,插件贡献的源是 `plugin:<插件id>/<源id>`。
///
/// 2026-07-23 从封闭 enum 改成开放键 —— 封闭 enum 意味着加一个源必须改 Rust 重新编译,
/// 插件永远塞不进 `HashMap<SourceKind, Arc<dyn MediaSourceBackend>>` 那张分派表。
///
/// `#[serde(transparent)]` 让线上表示仍是**裸小写字符串**,与改造前逐字节相同:
/// 老配置照常读回,而且不再会因为遇到未知变体而让整份 config 反序列化失败。
/// (装过插件源的用户禁用/卸载该插件后,账号不该跟着一起掉 —— 见
/// `unknown_kind_deserializes_instead_of_failing`。)
///
/// `transparent` 对单字段 newtype 其实是**冗余**的(serde 默认就透传,实测去掉它
/// `kind_wire_format_is_bare_lowercase_string` 不会红)。留着是当编译期的钉子:
/// 谁哪天往这个 struct 里加第二个字段,`transparent` 会直接编译报错,
/// 而不是悄悄把线上表示从裸字符串变成对象、让所有老配置读不回来。
#[derive(Serialize, Deserialize, Clone, PartialEq, Eq, Hash, Debug)]
#[serde(transparent)]
pub struct SourceKind(String);

impl SourceKind {
    pub const EMBY: &'static str = "emby";
    pub const OPENLIST: &'static str = "openlist";
    pub const QUARK: &'static str = "quark";
    pub const ANIRSS: &'static str = "anirss";
    pub const FEINIU: &'static str = "feiniu";
    pub const ALIYUNDRIVE: &'static str = "aliyundrive";
    pub const BAIDU: &'static str = "baidu";
    pub const PAN115: &'static str = "pan115";
    pub const PAN189: &'static str = "pan189";
    pub const PAN139: &'static str = "pan139";
    /// 局域网/自建文件源。这三个**不是网盘**:没有厂商 API、没有账号体系,
    /// 只有一个地址加一对账号密码,连的是用户自己那台 NAS 或路由器上的硬盘。
    pub const SMB: &'static str = "smb";
    pub const WEBDAV: &'static str = "webdav";
    pub const FTP: &'static str = "ftp";
    /// 本机文件夹(用户用系统选择器挑的那个目录)。
    pub const LOCAL: &'static str = "local";

    /// 插件源键前缀。插件贡献的源统一形如 `plugin:com.example.foo/mysrc`。
    const PLUGIN_PREFIX: &'static str = "plugin:";

    /// 全部内置源。**顺序即枚举顺序**,给需要穷举的地方(跨语言契约测试)用。
    pub const BUILTIN: &'static [&'static str] = &[
        Self::EMBY, Self::OPENLIST, Self::QUARK,
        Self::ANIRSS, Self::FEINIU,
        Self::ALIYUNDRIVE, Self::BAIDU, Self::PAN115,
        Self::PAN189, Self::PAN139,
        Self::SMB, Self::WEBDAV, Self::FTP, Self::LOCAL,
    ];

    pub fn is_builtin(&self) -> bool {
        Self::BUILTIN.contains(&self.0.as_str())
    }

    pub fn new(id: impl Into<String>) -> Self {
        Self(id.into())
    }
    pub fn as_str(&self) -> &str {
        &self.0
    }

    pub fn emby() -> Self {
        Self::new(Self::EMBY)
    }
    pub fn openlist() -> Self {
        Self::new(Self::OPENLIST)
    }
    pub fn quark() -> Self {
        Self::new(Self::QUARK)
    }
    pub fn anirss() -> Self {
        Self::new(Self::ANIRSS)
    }
    pub fn feiniu() -> Self {
        Self::new(Self::FEINIU)
    }
    pub fn aliyundrive() -> Self {
        Self::new(Self::ALIYUNDRIVE)
    }
    pub fn baidu() -> Self {
        Self::new(Self::BAIDU)
    }
    pub fn pan115() -> Self {
        Self::new(Self::PAN115)
    }
    pub fn pan189() -> Self {
        Self::new(Self::PAN189)
    }
    pub fn pan139() -> Self {
        Self::new(Self::PAN139)
    }
    pub fn smb() -> Self {
        Self::new(Self::SMB)
    }
    pub fn webdav() -> Self {
        Self::new(Self::WEBDAV)
    }
    pub fn ftp() -> Self {
        Self::new(Self::FTP)
    }
    pub fn local() -> Self {
        Self::new(Self::LOCAL)
    }

    /// Emby 是唯一的非「文件浏览型」源,全仓多处靠它分叉。
    pub fn is_emby(&self) -> bool {
        self.0 == Self::EMBY
    }

    /// 插件贡献的源。一个插件可贡献多个源,故带 src_id。
    pub fn plugin(plugin_id: &str, src_id: &str) -> Self {
        Self(format!("{}{plugin_id}/{src_id}", Self::PLUGIN_PREFIX))
    }

    /// 是插件源就拆出 `(插件id, 源id)`。**残缺键一律返回 None** ——
    /// 拆出空 id 会让上层去问一个不存在的插件,错误信息还会指向错的地方。
    pub fn as_plugin(&self) -> Option<(&str, &str)> {
        let (plugin_id, src_id) = self.0.strip_prefix(Self::PLUGIN_PREFIX)?.split_once('/')?;
        (!plugin_id.is_empty() && !src_id.is_empty()).then_some((plugin_id, src_id))
    }

    pub fn is_plugin(&self) -> bool {
        self.as_plugin().is_some()
    }

    /// **兼容用,别在新代码里当展示名。**
    ///
    /// 2026-07-23 之前 `SourceKind` 是封闭 enum,`apps/*/src/lib.rs` 用
    /// `format!("{kind:?}")`(派生 Debug = 首字母大写的变体名)当作
    /// **无 base_url 的源(夸克 Cookie 模式)的账号 id 和用户名**,这些字符串
    /// 已经躺在用户配置文件里了。
    ///
    /// 改成 newtype 后 Debug 变成 `SourceKind("quark")` —— 直接沿用会让老账号
    /// 在 `upsert` 时匹配不上、变成重复项,旧账号成孤儿。这个方法逐字复刻老输出。
    pub fn legacy_debug_label(&self) -> String {
        let mut chars = self.0.chars();
        match chars.next() {
            Some(first) => first.to_uppercase().collect::<String>() + chars.as_str(),
            None => String::new(),
        }
    }
}

impl Default for SourceKind {
    fn default() -> Self {
        Self::emby()
    }
}

impl std::fmt::Display for SourceKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

/// 浏览返回的一行:文件夹或文件。
#[derive(Serialize, Clone)]
pub struct SourceEntry {
    /// 继续浏览/取流的标识:OpenList=完整路径,夸克=fid,Ani-rss=filename。
    pub id: String,
    pub name: String,
    pub is_dir: bool,
    pub is_video: bool,
    pub size: Option<i64>,
    pub thumb_url: Option<String>,
    /// 源原始数据,供 resolve_play 复用(避免二次请求)。
    pub raw: Option<serde_json::Value>,
}

/// 一档可选清晰度(转码源如夸克提供多档)。
#[derive(Serialize, Clone)]
pub struct PlayQuality {
    pub id: String,
    pub label: String,
    pub rank: i32,
}

/// 外挂字幕轨。
#[derive(Serialize, Clone)]
pub struct SourceSubtitle {
    pub url: String,
    pub title: Option<String>,
    pub language: Option<String>,
    pub http_headers: HashMap<String, String>,
}

/// 交给播放器的最小可播单元:URL + 逐流 headers。
#[derive(Serialize, Clone)]
pub struct ResolvedPlay {
    pub url: String,
    pub title: String,
    pub http_headers: HashMap<String, String>,
    pub user_agent_override: Option<String>,
    pub subtitles: Vec<SourceSubtitle>,
    pub qualities: Vec<PlayQuality>,
    pub selected_quality_id: Option<String>,
}

impl ResolvedPlay {
    pub fn simple(url: String, title: String, http_headers: HashMap<String, String>) -> Self {
        Self {
            url,
            title,
            http_headers,
            user_agent_override: None,
            subtitles: vec![],
            qualities: vec![],
            selected_quality_id: None,
        }
    }
}

/* ══════════════════════════════════════════════════════════════════════════
   影视目录能力(catalog)—— 可选,只有资源站这类源实现。

   **网盘是文件树,资源站是影视目录,这是两种东西。** 文件树一行只需要
   「名字 + 是不是文件夹 + 多大」,`SourceEntry` 就够了;影视目录一张卡要
   海报、标题、「更新至17集」、年份、评分,还要分类和无限翻页。

   把这些字段硬塞进 `SourceEntry`,代价是十个网盘后端(40 处构造点)全得陪着改,
   还要背一堆它们永远填 None 的字段;而资源站也不需要 `size`。所以这里另起一套
   类型,`SourceEntry` 一个字段都不动。

   trait 上这三个方法都有默认实现(返回 unsupported),现有后端零改动。
   前端进一个源时先探 `categories`:通了就走影视浏览页,不通就走文件浏览页。
   ══════════════════════════════════════════════════════════════════════════ */

/// 「不支持这个能力」的稳定前缀。命令层把 `SourceError` 拍成字符串交给前端,
/// 前端只能靠文案判断 —— 靠中文提示语判断会在改文案时静默失效,所以给个标记。
pub const UNSUPPORTED_PREFIX: &str = "__LP_UNSUPPORTED__";

/// 分类。资源站的分类树只有两级,再深也照收,前端自己决定画几级。
#[derive(Serialize, Clone, Default)]
pub struct MediaCategory {
    pub id: String,
    pub name: String,
    pub children: Vec<MediaCategory>,
}

/// 目录里的一张卡。
#[derive(Serialize, Clone, Default)]
pub struct MediaCard {
    pub id: String,
    pub title: String,
    pub poster: Option<String>,
    /// 右下角角标:资源站的 `vod_remarks`(「更新至17集」/「HD」/「全24集」)。
    /// ★ 它必须是**独立字段**。没有它的时候只能拼进标题,卡片下面就变成
    ///   「神之水滴 · 更新至17集 · 2026」—— 那不是标题,是把三样东西塞进一个格子。
    pub badge: Option<String>,
    pub year: Option<String>,
    pub score: Option<String>,
    /// 剧集(点开先看分集) vs 单片(点开直接播)。
    pub is_series: bool,
}

/// 目录的一页。`has_more` 决定前端还要不要继续往下拉 ——
/// 「下一页」不该是列表里的一个条目,那是把翻页伪装成内容。
#[derive(Serialize, Clone, Default)]
pub struct MediaPage {
    pub items: Vec<MediaCard>,
    pub page: u32,
    pub has_more: bool,
    pub total: Option<u32>,
}

/// 一集。`raw` 原样回传给 `resolve_play`,所以播放链路一行都不用改。
#[derive(Serialize, Clone, Default)]
pub struct MediaEpisode {
    pub id: String,
    pub name: String,
    pub raw: Option<serde_json::Value>,
}

/// 一条播放线路。
#[derive(Serialize, Clone, Default)]
pub struct MediaLine {
    pub id: String,
    pub name: String,
    pub episodes: Vec<MediaEpisode>,
}

/// 一部片的详情页数据。
#[derive(Serialize, Clone, Default)]
pub struct MediaDetail {
    pub id: String,
    pub title: String,
    pub poster: Option<String>,
    pub badge: Option<String>,
    pub year: Option<String>,
    pub area: Option<String>,
    pub lang: Option<String>,
    pub genre: Option<String>,
    pub score: Option<String>,
    pub overview: Option<String>,
    pub actors: Option<String>,
    pub director: Option<String>,
    pub lines: Vec<MediaLine>,
}

/// 「添加服务器」时验证这个源确实能用。
///
/// ★ **不能只试 `list_dir`。** 影视目录型的源(资源站)根本不实现它 —— 它有分类、
/// 有分页、有分集,不是文件树。只探 `list_dir` 的话那一整类源在添加这一步就被判死,
/// 报的还是一句「插件数据源必须返回数组」,完全看不出是探测方式选错了(2026-08-01
/// 真踩到:插件装好了、目录也能列,就是加不进服务器表)。
///
/// 两条能力通任意一条,就算这个源能用。
///
/// 放在核层而不是各端命令里:桌面和安卓的 `source_login` 是两份手工拷贝,
/// 这种「探测口径」放在两边迟早只改一边。
pub async fn probe_backend(
    backend: &dyn MediaSourceBackend,
    http: &reqwest::Client,
    server: &SourceServer,
) -> Result<(), SourceError> {
    let files_err = match backend.list_dir(http, server, None).await {
        Ok(_) => return Ok(()),
        Err(e) => e,
    };
    match backend.categories(http, server).await {
        Ok(_) => Ok(()),
        // 两条都不通:报**文件树**那条的错。用户填错地址时那句通常更具体
        // (「返回的不是采集接口 JSON」之类),而目录那条往往只是句「不支持」。
        Err(cat_err) => Err(if cat_err.is_unsupported() { files_err } else { cat_err }),
    }
}

/// 扫码登录:开始。返回给前端展示的二维码 + 一段不透明上下文(原样回传给 poll)。
/// image 既可能是 data URI(自己画的二维码 PNG),也可能是一个图片 URL(网盘直接给图)。
#[derive(Serialize, Clone)]
pub struct QrStart {
    pub image: String,
    /// 轮询要用的上下文(uuid/sign/sid…),JSON 字符串,前端不解读只回传。
    pub ctx: String,
}

/// 扫码登录:轮询一次的结果。
#[derive(Serialize, Clone)]
#[serde(tag = "state", rename_all = "snake_case")]
pub enum QrPoll {
    /// 还没扫 / 已扫未确认 —— 前端继续轮询。
    Pending,
    /// 已确认,凭据到手。这张 map 直接并进新建 SourceServer 的 extra 后落盘。
    Confirmed { credentials: HashMap<String, String> },
    /// 二维码过期,前端要重新 start。
    Expired,
}

/// 源后端统一错误。is_auth=鉴权失效(UI 可引导重登)。
#[derive(Debug, Clone, Serialize)]
pub struct SourceError {
    pub message: String,
    pub is_auth: bool,
}
impl SourceError {
    pub fn msg(m: impl Into<String>) -> Self {
        Self { message: m.into(), is_auth: false }
    }
    pub fn auth(m: impl Into<String>) -> Self {
        Self { message: m.into(), is_auth: true }
    }
    pub fn unsupported() -> Self {
        Self::msg("该源不支持搜索")
    }
    /// 「这个源没有这个能力」。带稳定前缀,前端据此静默退回另一条路径,
    /// 而不是把它当成一条真错误弹给用户。
    pub fn unsupported_feature(what: &str) -> Self {
        Self::msg(format!("{UNSUPPORTED_PREFIX}{what}"))
    }
    pub fn is_unsupported(&self) -> bool {
        self.message.contains(UNSUPPORTED_PREFIX)
    }
}
impl std::fmt::Display for SourceError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.message)
    }
}

/// 一个浏览型源服务器的连接凭据。对齐 Dart ServerConfig 的相关字段。
/// serde:源服务器要随 AppConfig 落盘(重启免登 + 多源并存),故必须可序列化。
#[derive(Clone, Default, Serialize, Deserialize)]
pub struct SourceServer {
    pub id: String,
    pub base_url: String, // activeLineUrl,后端内部 normalize
    pub username: Option<String>,
    pub password: Option<String>,
    pub token: Option<String>,             // 账密型主令牌
    pub extra: HashMap<String, String>,    // 夸克等多凭据(cookie/refresh_token…)
}

/// 文件浏览型源后端的最小抽象(三端复用,纯逻辑)。
#[async_trait::async_trait]
pub trait MediaSourceBackend: Send + Sync {
    fn kind(&self) -> SourceKind;

    /// 列目录。dir_id=None 表示根目录。
    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError>;

    /// 源内搜索。无源端搜索能力的实现返回 unsupported,UI 退回本地过滤。
    async fn search(
        &self,
        _http: &reqwest::Client,
        _server: &SourceServer,
        _query: &str,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        Err(SourceError::unsupported())
    }

    /// 把文件解析成可播单元(含取流所需 headers)。短效直链过期后播放层回调重解析。
    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError>;

    /// 播放进度上报。有服务端观看记录的源(飞牛等)覆写它,纯网盘默认空实现。
    ///
    /// 调用方在播放中按既有节奏(5s 一拍)调用,并在停止时以 finished 再调一次。
    /// 失败一律吞掉不打断播放 —— 进度没记上是小事,把正在看的片子打断是大事。
    async fn report_progress(
        &self,
        _http: &reqwest::Client,
        _server: &SourceServer,
        _entry: &SourceEntry,
        _position_secs: f64,
        _duration_secs: f64,
        _finished: bool,
    ) -> Result<(), SourceError> {
        Ok(())
    }

    /// **凭据轮换回写通道。** 返回 Some 表示该源的存盘凭据变了,调用方必须落盘。
    ///
    /// 存在的理由:trait 只拿得到 `&SourceServer`(只读),而 oplist 系与阿里云盘的
    /// refresh_token 是**一次性的** —— 刷新一次旧值当场作废。不回写的话内存里能用,
    /// 一重启就拿着死 token 去刷,表现为「用得好好的,重开就要重新授权」,且不报错。
    ///
    /// 调用方在每次 list_dir/search/resolve_play 之后取一次;返回的 map 并入
    /// `SourceServer.extra` 后存盘。默认实现返回 None(凭据不轮换的源无需关心)。
    fn take_rotated_credentials(&self, _server_id: &str) -> Option<HashMap<String, String>> {
        None
    }

    // ── 影视目录能力(可选,见本文件中部那段说明) ──────────────────────────
    // 三个方法默认都返回「不支持」,所以网盘那十个后端一行都不用改。
    // 前端进一个源时先探 categories:通了走影视浏览页,不通走文件浏览页。

    /// 分类树。
    async fn categories(
        &self,
        _http: &reqwest::Client,
        _server: &SourceServer,
    ) -> Result<Vec<MediaCategory>, SourceError> {
        Err(SourceError::unsupported_feature("影视目录"))
    }

    /// 目录的一页。`category_id` 为 None = 全站最新;`keyword` 非空 = 搜索。
    /// 搜索和浏览共用一个方法,因为**搜索结果也要能一直往下拉** —— 分成两条
    /// 路径的话,翻页逻辑就得写两遍,而少写的那遍就是「搜索只有第一页」。
    async fn catalog(
        &self,
        _http: &reqwest::Client,
        _server: &SourceServer,
        _category_id: Option<&str>,
        _keyword: Option<&str>,
        _page: u32,
    ) -> Result<MediaPage, SourceError> {
        Err(SourceError::unsupported_feature("影视目录"))
    }

    /// 一部片的详情(简介 / 演职员 / 线路 / 分集)。
    async fn media_detail(
        &self,
        _http: &reqwest::Client,
        _server: &SourceServer,
        _id: &str,
    ) -> Result<MediaDetail, SourceError> {
        Err(SourceError::unsupported_feature("影视目录"))
    }
}

// ---------- 各后端共用工具 ----------

/// 规整 baseUrl:去尾斜杠、补协议(缺省 https)。
pub fn normalize_base_url(raw: &str) -> String {
    let mut url = raw.trim().to_string();
    if url.is_empty() {
        return url;
    }
    if !url.starts_with("http://") && !url.starts_with("https://") {
        url = format!("https://{url}");
    }
    while url.ends_with('/') {
        url.pop();
    }
    url
}

/// 把扫码内容(一段 URL/字符串)渲成二维码 SVG 的 data URI,前端 `<img src>` 直显。
/// 阿里/189 的出码接口给的是待渲染字符串而非图片,统一在这里渲染,前端不必带 JS 二维码库。
pub fn qr_svg_data_uri(content: &str) -> Result<String, SourceError> {
    use qrcode::render::svg;
    use qrcode::QrCode;
    let code = QrCode::new(content.as_bytes())
        .map_err(|e| SourceError::msg(format!("二维码生成失败: {e}")))?;
    let svg = code
        .render::<svg::Color>()
        .min_dimensions(240, 240)
        .quiet_zone(true)
        .build();
    Ok(format!(
        "data:image/svg+xml;base64,{}",
        base64::Engine::encode(&base64::engine::general_purpose::STANDARD, svg.as_bytes())
    ))
}

/// 视频扩展名判定(各后端列目录时标记 is_video)。
pub fn is_video_file_name(name: &str) -> bool {
    match name.rsplit_once('.') {
        Some((_, ext)) => VIDEO_EXTENSIONS.contains(&ext.to_lowercase().as_str()),
        None => false,
    }
}

const VIDEO_EXTENSIONS: &[&str] = &[
    "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm", "m4v", "mpg", "mpeg", "ts", "m2ts", "mts",
    "rmvb", "rm", "vob", "3gp", "f4v", "ogv", "m3u8", "iso", "divx", "asf", "mxf",
];

/// 文件夹在前、各自按名排序。
pub fn sort_entries(entries: &mut [SourceEntry]) {
    entries.sort_by(|a, b| {
        if a.is_dir != b.is_dir {
            return if a.is_dir {
                std::cmp::Ordering::Less
            } else {
                std::cmp::Ordering::Greater
            };
        }
        a.name.to_lowercase().cmp(&b.name.to_lowercase())
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn normalize_and_video_detection() {
        assert_eq!(normalize_base_url(" http://x:5244/ "), "http://x:5244");
        assert_eq!(normalize_base_url("alist.example.com//"), "https://alist.example.com");
        assert!(is_video_file_name("片子.MKV"));
        assert!(is_video_file_name("a.mp4"));
        assert!(!is_video_file_name("cover.jpg"));
        assert!(!is_video_file_name("无扩展名"));
    }

    /// SourceKind 的线上表示就是**配置文件里的字面量**和**前端 api.ts 的联合类型**。
    /// 字面量写歪一个字母,老配置就读不回来(掉账号),前端的 KIND_LABEL 也对不上。
    ///
    /// 2026-07-23 从封闭 enum 改成开放键(newtype String)后,这条钉的是
    /// **线上表示逐字节不变** —— 改造前后序列化结果必须完全一致。
    #[test]
    fn kind_wire_format_is_bare_lowercase_string() {
        let all = [
            (SourceKind::emby(), "emby"),
            (SourceKind::openlist(), "openlist"),
            (SourceKind::quark(), "quark"),
            (SourceKind::anirss(), "anirss"),
            (SourceKind::feiniu(), "feiniu"),
            (SourceKind::aliyundrive(), "aliyundrive"),
            (SourceKind::baidu(), "baidu"),
            (SourceKind::pan115(), "pan115"),
            (SourceKind::pan189(), "pan189"),
            (SourceKind::pan139(), "pan139"),
            (SourceKind::smb(), "smb"),
            (SourceKind::webdav(), "webdav"),
            (SourceKind::ftp(), "ftp"),
            (SourceKind::local(), "local"),
        ];
        // 这张表必须与 BUILTIN 一一对应 —— 新增源只加常量不补这里,
        // 下面的逐条断言就完全跑不到它,等于没有守卫。
        assert_eq!(
            all.len(),
            SourceKind::BUILTIN.len(),
            "新增了内置源却没补进本测试表,线上表示无人把关"
        );
        for (k, wire) in all {
            assert_eq!(
                serde_json::to_string(&k).unwrap(),
                format!("\"{wire}\""),
                "{wire} 序列化后不是裸小写字符串 —— 老版本读不回新配置"
            );
            let back: SourceKind = serde_json::from_str(&format!("\"{wire}\"")).unwrap();
            assert_eq!(back, k, "{wire} 反序列化不回原值 —— 老配置会掉账号");
        }
        assert!(
            SourceKind::default().is_emby(),
            "默认必须是 emby —— 没有 source_kind 字段的老账号全靠它兜底"
        );
    }

    /// 插件源键的往返和边界。内置源被误判成插件源的话,请求会被路由去问一个
    /// 根本不存在的插件;残缺键拆出空 id 则会让错误信息指向错的地方。
    #[test]
    fn plugin_kind_roundtrips_and_never_collides_with_builtin() {
        let k = SourceKind::plugin("com.example.foo", "mysrc");
        assert_eq!(k.as_str(), "plugin:com.example.foo/mysrc");
        assert_eq!(
            serde_json::to_string(&k).unwrap(),
            "\"plugin:com.example.foo/mysrc\""
        );
        assert_eq!(k.as_plugin(), Some(("com.example.foo", "mysrc")));
        assert!(k.is_plugin() && !k.is_emby());

        // 直接遍历 BUILTIN:任何新增内置源都自动纳入,不会漏。
        for name in SourceKind::BUILTIN {
            let builtin = SourceKind::new(*name);
            assert!(builtin.is_builtin(), "{builtin} 不认自己是内置源");
            assert!(!builtin.is_plugin(), "内置源 {builtin} 被误判成插件源");
            assert_eq!(builtin.as_plugin(), None);
        }
        // 键重复会让后注册的后端悄悄顶掉前一个。
        let mut seen = std::collections::HashSet::new();
        for name in SourceKind::BUILTIN {
            assert!(seen.insert(*name), "内置源键重复: {name}");
        }

        // 残缺键:少 src_id / 少 plugin_id / 没有分隔符,一律不许拆出来
        for broken in ["plugin:com.x.y/", "plugin:/srcid", "plugin:nosep", "plugin:"] {
            assert_eq!(
                SourceKind::new(broken).as_plugin(),
                None,
                "残缺插件键 {broken} 不该拆出 id"
            );
        }
    }

    /// `legacy_debug_label()` 必须逐字等于老封闭 enum 的派生 Debug 输出 ——
    /// 它是**已经落在用户配置里的账号 id**(夸克 Cookie 模式 base_url 为空,拿它当稳定 id)。
    /// 差一个字母,老账号 upsert 时就匹配不上、变重复项,旧账号成孤儿。
    #[test]
    fn legacy_debug_label_reproduces_old_enum_debug_exactly() {
        let expected = [
            (SourceKind::emby(), "Emby"),
            (SourceKind::openlist(), "Openlist"),
            (SourceKind::quark(), "Quark"),
            (SourceKind::anirss(), "Anirss"),
            (SourceKind::feiniu(), "Feiniu"),
            // 下面几个没有"老 enum"可兼容,但它们同样靠这个标签当**账号 id**
            // (base_url 为空的源),所以一旦发版就同样不能再改。
            (SourceKind::aliyundrive(), "Aliyundrive"),
            (SourceKind::baidu(), "Baidu"),
            (SourceKind::pan115(), "Pan115"),
            (SourceKind::pan189(), "Pan189"),
            (SourceKind::pan139(), "Pan139"),
            (SourceKind::smb(), "Smb"),
            (SourceKind::webdav(), "Webdav"),
            (SourceKind::ftp(), "Ftp"),
            (SourceKind::local(), "Local"),
        ];
        assert_eq!(expected.len(), SourceKind::BUILTIN.len(), "新增源未补进本表");
        for (k, old_debug) in expected {
            assert_eq!(
                k.legacy_debug_label(),
                old_debug,
                "{k} 的兼容标签跟老 enum 的 Debug 对不上 —— 老账号会掉"
            );
        }
    }

    /// 开放键的核心收益:装过插件源的配置,在插件被禁用/卸载后仍能读回**整个账号**,
    /// 而不是让整份 config 反序列化失败、把所有服务器一起带走。
    /// 老的封闭 enum 遇到未知字面量会直接报错,这正是要摆脱的东西。
    #[test]
    fn unknown_kind_deserializes_instead_of_failing() {
        let k: SourceKind = serde_json::from_str("\"plugin:com.gone/x\"")
            .expect("未知源类型必须能读回,否则插件一卸载用户就掉光服务器");
        assert_eq!(k.as_str(), "plugin:com.gone/x");
        assert!(!k.is_emby());
    }

    /* ── 添加服务器时的能力探测 ────────────────────────────────────────
       2026-08-01 的 P0:探测只试了 list_dir,而影视目录型的源不实现它 ——
       插件装好了、目录也列得出来,就是**加不进服务器表**,报「插件数据源必须
       返回数组」。这三条钉住三种源都能通过探测。 */

    struct FakeBackend {
        files: bool,
        catalog: bool,
    }

    #[async_trait::async_trait]
    impl MediaSourceBackend for FakeBackend {
        fn kind(&self) -> SourceKind {
            SourceKind::new("fake")
        }
        async fn list_dir(
            &self,
            _h: &reqwest::Client,
            _s: &SourceServer,
            _d: Option<&str>,
        ) -> Result<Vec<SourceEntry>, SourceError> {
            if self.files {
                Ok(vec![])
            } else {
                Err(SourceError::msg("插件数据源必须返回数组"))
            }
        }
        async fn resolve_play(
            &self,
            _h: &reqwest::Client,
            _s: &SourceServer,
            _e: &SourceEntry,
            _q: Option<&str>,
        ) -> Result<ResolvedPlay, SourceError> {
            unreachable!()
        }
        async fn categories(
            &self,
            _h: &reqwest::Client,
            _s: &SourceServer,
        ) -> Result<Vec<MediaCategory>, SourceError> {
            if self.catalog {
                Ok(vec![])
            } else {
                Err(SourceError::unsupported_feature("影视目录"))
            }
        }
    }

    #[tokio::test]
    async fn probe_accepts_file_tree_sources() {
        let b = FakeBackend { files: true, catalog: false };
        assert!(probe_backend(&b, &reqwest::Client::new(), &SourceServer::default()).await.is_ok());
    }

    /// 这一条就是那个 P0 的回归:只实现影视目录、不实现 list_dir 的源必须能加进来。
    #[tokio::test]
    async fn probe_accepts_catalog_only_sources() {
        let b = FakeBackend { files: false, catalog: true };
        probe_backend(&b, &reqwest::Client::new(), &SourceServer::default())
            .await
            .expect("只实现影视目录的源也必须能通过添加服务器的探测");
    }

    /// 两条都不通时,要报**文件树**那条的错 —— 用户填错地址时那句更具体,
    /// 而目录那条往往只是句「不支持」,对定位毫无帮助。
    #[tokio::test]
    async fn probe_reports_the_useful_error_when_both_fail() {
        let b = FakeBackend { files: false, catalog: false };
        let e = probe_backend(&b, &reqwest::Client::new(), &SourceServer::default())
            .await
            .expect_err("两条都不通必须报错");
        assert!(e.message.contains("必须返回数组"), "拿到的是: {}", e.message);
        assert!(!e.is_unsupported(), "不该把「不支持影视目录」当成给用户看的理由");
    }
}
