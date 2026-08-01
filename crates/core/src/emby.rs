// Emby 客户端:登录、取媒体库(Views)、列条目、解析直连播放地址。
use crate::http::{device_name, APP_VERSION, CLIENT_NAME};
use serde::{Deserialize, Serialize};

/// X-Emby-Authorization 头:身份用真实应用标识(非 PoC 名),DeviceId 用持久化设备 ID。
fn auth_header(device_id: &str) -> String {
    format!(
        "MediaBrowser Client=\"{CLIENT_NAME}\", Device=\"{}\", DeviceId=\"{device_id}\", Version=\"{APP_VERSION}\"",
        device_name()
    )
}

#[derive(Clone)]
pub struct Session {
    pub server: String, // 归一化后不带尾斜杠
    pub token: String,
    pub user_id: String,
    pub device_id: String,
}

#[derive(Serialize)]
pub struct LoginResult {
    pub server: String,
    pub token: String,
    pub user_id: String,
    pub user_name: String,
    /// 登录用户的头像 tag(建服务器图标用)。无头像则 None。
    #[serde(default)]
    pub primary_image_tag: Option<String>,
}

#[derive(Deserialize)]
struct AuthResponse {
    #[serde(rename = "AccessToken")]
    access_token: String,
    #[serde(rename = "User")]
    user: AuthUser,
}
#[derive(Deserialize)]
struct AuthUser {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name")]
    name: String,
    /// 用户头像 tag。很多 Emby 服把品牌 logo 设成用户头像,服务器图标优先用它。
    /// 不解这个字段的话图标只能退 /web/touchicon.png —— 能用,但悄悄降级。
    #[serde(rename = "PrimaryImageTag", default)]
    primary_image_tag: Option<String>,
}

#[derive(Deserialize)]
struct ItemsResponse {
    #[serde(rename = "Items")]
    items: Vec<RawItem>,
    /// 库内符合条件的总数(与本页 Items.len() 无关)。前端靠它算分页页数;
    /// 缺省 0 —— /Items/Latest 那种裸数组端点走不到这里。
    #[serde(rename = "TotalRecordCount")]
    total_record_count: Option<i64>,
}

/// 一页条目 + 总数。★ 必须带 total:Emby 单次请求最多吐 200 条(实测 smart.uhdnow.com
/// Limit=1000 仍只返 200),3276 条的库只能靠 StartIndex 翻页,没有总数前端就不知道翻到哪。
#[derive(Serialize)]
pub struct ItemPage {
    pub items: Vec<Item>,
    pub total: i64,
}

#[derive(Deserialize)]
struct RawItem {
    #[serde(rename = "Id")]
    id: String,
    #[serde(rename = "Name")]
    name: Option<String>,
    #[serde(rename = "Type")]
    type_: Option<String>,
    #[serde(rename = "IsFolder")]
    is_folder: Option<bool>,
    #[serde(rename = "CollectionType")]
    collection_type: Option<String>,
    #[serde(rename = "ImageTags")]
    image_tags: Option<serde_json::Value>,
    #[serde(rename = "RunTimeTicks")]
    runtime_ticks: Option<i64>,
    #[serde(rename = "UserData")]
    user_data: Option<UserData>,
    #[serde(rename = "SeriesName")]
    series_name: Option<String>,
    #[serde(rename = "IndexNumber")]
    index_number: Option<i64>,
    #[serde(rename = "ParentIndexNumber")]
    parent_index_number: Option<i64>,
    /// 仅在请求 Fields=MediaSources 时有(分集卡要「2160p · 45M · 18.4G」)。
    #[serde(rename = "MediaSources")]
    media_sources: Option<Vec<RawMediaSource>>,
    /// 以下三项要 Fields=Genres,ProductionYear,CommunityRating 才有值。
    /// 除了给前端展示,还是 items() 客户端兜底过滤的判据(见 ItemQuery 注释)。
    #[serde(rename = "Genres")]
    genres: Option<Vec<String>>,
    #[serde(rename = "ProductionYear")]
    production_year: Option<i64>,
    #[serde(rename = "CommunityRating")]
    community_rating: Option<f64>,
    /// 以下三项要 Fields=ProviderIds,PresentationUniqueKey,Path。
    /// 它们是**跨服务器续播强匹配的判据**:没有 TMDB id 就只能靠剧名+季集号猜,
    /// 猜错不报错、只是静默匹配不上 —— 所以宁可多要这三个字段。
    #[serde(rename = "ProviderIds")]
    provider_ids: Option<std::collections::HashMap<String, String>>,
    #[serde(rename = "PresentationUniqueKey")]
    presentation_unique_key: Option<String>,
    #[serde(rename = "Path")]
    path: Option<String>,
    /// 剧集所属剧的 Id(跨服匹配要拿它去查剧的 TMDB id)。
    #[serde(rename = "SeriesId")]
    series_id: Option<String>,
    /// 以下两项要 Fields=DateCreated,SortName —— 收藏页本地排序用。
    /// DateLastMediaAdded 只有部分服务端给(实测 uhdnow fork 恒为 null),取不到就回落 DateCreated。
    #[serde(rename = "DateCreated")]
    date_created: Option<String>,
    #[serde(rename = "DateLastMediaAdded")]
    date_last_media_added: Option<String>,
    /// Emby 自己的排序名(中文条目常带拼音/去冠词处理),按名称排优先用它。
    #[serde(rename = "SortName")]
    sort_name: Option<String>,
}
#[derive(Deserialize)]
struct UserData {
    #[serde(rename = "PlaybackPositionTicks")]
    position_ticks: Option<i64>,
    /// 已看标记。set_played 改的就是它,列表不返回它前端就没法反显「已看」角标。
    #[serde(rename = "Played")]
    played: Option<bool>,
    /// 未看子项数(剧集/季才有,电影/单集为 None)。海报右上角「未看集数」角标就靠它。
    /// Emby 的 UserData 默认就带,不必请求任何 Fields —— 只是我们过去漏了这个字段。
    #[serde(rename = "UnplayedItemCount")]
    unplayed_item_count: Option<i64>,
}

#[derive(Serialize)]
pub struct Item {
    pub id: String,
    pub name: String,
    pub type_: String,
    pub is_folder: bool,
    pub has_primary: bool,
    pub runtime_secs: f64,
    pub resume_secs: f64,
    /// 剧集所属剧名。Emby 的 Episode.Name 只是「第 35 集」,单看无意义,
    /// 继续观看/收藏/搜索等混排列表必须靠它才说得清是哪部剧。
    pub series_name: Option<String>,
    pub episode_no: Option<i64>,
    pub season_no: Option<i64>,
    /// 以下三项仅在请求带 Fields=MediaSources 时有值(草稿分集卡的「2160p · 45M · 18.4G」)。
    pub video_height: Option<i64>,
    pub bitrate: Option<i64>,
    pub size_bytes: Option<i64>,
    /// 已看(UserData.Played)。set_played 的反显靠它。
    pub played: bool,
    /// 未看子项数(剧集/季)。0 = 全看完 或 非文件夹。海报「未看集数」蓝角标用它,
    /// played=true 时必为 0(全看完),前端据此:有勾优先、否则显数字。
    pub unplayed_item_count: i64,
    /// 以下三项要 Fields=Genres,ProductionYear,CommunityRating;媒体库筛选面板要展示也要过滤。
    pub genres: Vec<String>,
    pub year: Option<i64>,
    pub rating: Option<f64>,
    /// 以下四项要 Fields=ProviderIds,PresentationUniqueKey,Path;跨服务器续播强匹配的判据。
    /// 缺了不崩,但匹配会静默降级到「剧名+季集号」—— 那正是跨服续播最容易假装能用的失败形态。
    pub provider_ids: std::collections::HashMap<String, String>,
    pub presentation_unique_key: Option<String>,
    pub path: Option<String>,
    pub series_id: Option<String>,
    /// 「更新时间」排序用。DateLastMediaAdded 优先(剧集新集入库才动),没有就 DateCreated。
    /// ISO8601 字符串,同一台服务器格式一致 → 前端直接字符串比较即可,不必解析成时间。
    pub date_updated: Option<String>,
    /// Emby 的 SortName(按名称排序用,比 Name 更符合服务端口径)。
    pub sort_name: Option<String>,
}

impl From<RawItem> for Item {
    fn from(r: RawItem) -> Self {
        let has_primary = r
            .image_tags
            .as_ref()
            .and_then(|v| v.get("Primary"))
            .is_some();
        let is_folder = r.is_folder.unwrap_or(false) || r.collection_type.is_some();
        // 主版本(第一个 MediaSource)的规格,只为分集卡那行小字;没请求 Fields 时全 None。
        let ms = r.media_sources.as_ref().and_then(|v| v.first());
        let video_height = ms
            .and_then(|m| m.media_streams.as_ref())
            .and_then(|ss| ss.iter().find(|s| s.type_.as_deref() == Some("Video")))
            .and_then(|s| s.height);
        // user_data 要读三个字段(进度 + 已看 + 未看数),先拆出来免得被 move 掉。
        let (resume_ticks, played, unplayed_item_count) = match r.user_data {
            Some(u) => (
                u.position_ticks.unwrap_or(0),
                u.played.unwrap_or(false),
                u.unplayed_item_count.unwrap_or(0),
            ),
            None => (0, false, 0),
        };
        Item {
            id: r.id,
            name: r.name.unwrap_or_default(),
            type_: r.type_.unwrap_or_default(),
            is_folder,
            has_primary,
            runtime_secs: r.runtime_ticks.unwrap_or(0) as f64 / 1e7,
            resume_secs: resume_ticks as f64 / 1e7,
            played,
            unplayed_item_count,
            genres: r.genres.unwrap_or_default(),
            year: r.production_year,
            rating: r.community_rating,
            series_name: r.series_name.filter(|s| !s.is_empty()),
            episode_no: r.index_number,
            season_no: r.parent_index_number,
            video_height,
            bitrate: ms.and_then(|m| m.bitrate),
            size_bytes: ms.and_then(|m| m.size),
            provider_ids: r.provider_ids.unwrap_or_default(),
            presentation_unique_key: r.presentation_unique_key.filter(|s| !s.is_empty()),
            path: r.path.filter(|s| !s.is_empty()),
            series_id: r.series_id.filter(|s| !s.is_empty()),
            date_updated: r.date_last_media_added.or(r.date_created).filter(|s| !s.is_empty()),
            sort_name: r.sort_name.filter(|s| !s.is_empty()),
        }
    }
}

// ---------- 媒体信息(草稿页 03 的「版本/音轨/字幕」选择器 + 媒体信息版本块)----------
#[derive(Deserialize)]
struct RawMediaSource {
    #[serde(rename = "Id")]
    id: Option<String>,
    #[serde(rename = "Name")]
    name: Option<String>,
    #[serde(rename = "Container")]
    container: Option<String>,
    #[serde(rename = "Size")]
    size: Option<i64>,
    #[serde(rename = "Bitrate")]
    bitrate: Option<i64>,
    #[serde(rename = "RunTimeTicks")]
    runtime_ticks: Option<i64>,
    #[serde(rename = "MediaStreams")]
    media_streams: Option<Vec<RawStream>>,
    /* ↓ 这两个字段原本属于 resolve_stream 里另一个私有的 `MediaSource` 结构体。
       同一个 JSON 对象被建了**两份模型**,于是取流那条路上 MediaStreams 被静默丢弃 ——
       「杜比视界自动软解」判不出 DV 的根因就是这个:数据一直在线上,只是没人接。
       两份模型合成一份,这类「字段在别处解析过了,这里却没有」的坑才不会再长出来。 */
    #[serde(rename = "DirectStreamUrl")]
    direct_stream_url: Option<String>,
    #[serde(rename = "TranscodingUrl")]
    transcoding_url: Option<String>,
}

#[derive(Deserialize)]
struct RawStream {
    #[serde(rename = "Type")]
    type_: Option<String>,
    #[serde(rename = "Codec")]
    codec: Option<String>,
    #[serde(rename = "Profile")]
    profile: Option<String>,
    #[serde(rename = "DisplayTitle")]
    display_title: Option<String>,
    #[serde(rename = "Language")]
    language: Option<String>,
    #[serde(rename = "Width")]
    width: Option<i64>,
    #[serde(rename = "Height")]
    height: Option<i64>,
    #[serde(rename = "BitRate")]
    bitrate: Option<i64>,
    #[serde(rename = "Channels")]
    channels: Option<i64>,
    #[serde(rename = "ChannelLayout")]
    channel_layout: Option<String>,
    #[serde(rename = "AverageFrameRate")]
    frame_rate: Option<f64>,
    #[serde(rename = "VideoRange")]
    video_range: Option<String>,
    /// `VideoRange` 只有 SDR/HDR 两档,**分不出 DoVi 和 HDR10** —— 判杜比视界必须看这个
    /// (取值 DOVI / HDR10 / HLG / HDR10Plus)。老服务器可能不发,故还要看 codec/profile 兜底。
    #[serde(rename = "VideoRangeType")]
    video_range_type: Option<String>,
    #[serde(rename = "IsDefault")]
    is_default: Option<bool>,
    #[serde(rename = "Index")]
    index: Option<i64>,
    /// ★ 外挂字幕三件套。不解析这三个字段 = 分不出外挂和内封,
    /// 也就永远拼不出取字幕的地址 —— 「外挂字幕不加载」的第一层根因。
    #[serde(rename = "IsExternal")]
    is_external: Option<bool>,
    #[serde(rename = "DeliveryUrl")]
    delivery_url: Option<String>,
}

/// 一条流(视频/音频/字幕),字段照草稿媒体信息卡的 kv 行来。
#[derive(Serialize, Clone)]
pub struct StreamInfo {
    pub index: i64,
    pub type_: String, // Video | Audio | Subtitle
    pub codec: String,
    pub profile: Option<String>,
    pub display_title: Option<String>,
    pub language: Option<String>,
    pub width: Option<i64>,
    pub height: Option<i64>,
    pub bitrate: Option<i64>,
    pub channels: Option<i64>,
    pub channel_layout: Option<String>,
    pub frame_rate: Option<f64>,
    pub video_range: Option<String>,
    pub video_range_type: Option<String>,
    pub is_default: bool,
    /// 外挂字幕(单独文件),需要 mpv 用 `sub-add` 另外挂载,不在容器的 track-list 里。
    pub is_external: bool,
    /// 服务器给的取字幕地址(可能是相对路径)。缺失时按 index 自己拼。
    pub delivery_url: Option<String>,
}

/// 这条视频流是不是杜比视界。判定顺序 = 从最权威到最兜底:
///   1. `VideoRangeType == DOVI`(新版 Emby/Jellyfin 直接给结论)
///   2. codec 里带 dvhe/dvh1(DV 独立轨的编码标识)
///   3. profile 里带 "dolby vision"(老服务器只在人类可读串里体现)
/// 只看 `VideoRange=HDR` 会把 HDR10 一起误判成 DV → 无谓地掉进软解、白白卡顿。
pub fn is_dolby_vision(s: &StreamInfo) -> bool {
    if s.type_ != "Video" {
        return false;
    }
    let range_type = s.video_range_type.as_deref().unwrap_or("").to_ascii_lowercase();
    if range_type.contains("dovi") || range_type.contains("dolby") {
        return true;
    }
    let codec = s.codec.to_ascii_lowercase();
    if codec.contains("dvhe") || codec.contains("dvh1") || codec.contains("dav1") {
        return true;
    }
    s.profile
        .as_deref()
        .unwrap_or("")
        .to_ascii_lowercase()
        .contains("dolby vision")
}

/// 一个版本(= 一个 MediaSource)。草稿的「版本 1 · 4K HDR · 主线」一整块。
#[derive(Serialize, Clone)]
pub struct MediaVersion {
    pub id: String,
    pub name: String,
    pub container: Option<String>,
    pub size_bytes: Option<i64>,
    pub bitrate: Option<i64>,
    pub runtime_secs: f64,
    pub streams: Vec<StreamInfo>,
    /// ★ 版本筛选正则会挑中的就是这一条(wiki regex-filters)。
    /// 起播时用户没手动选版本 → `resolve_stream` 挑的正是它,所以详情页/播放器的
    /// 「当前版本」必须显示它,否则界面说在放第一条、实际在放另一条,
    /// 用户看到的就是「正则根本没生效」——这正是 2026-07-30 那次误判的成因。
    /// 正则留空/没命中 → 全 false,调用方回落第一条(和核层的回落一致)。
    pub preferred: bool,
}

impl From<RawMediaSource> for MediaVersion {
    fn from(m: RawMediaSource) -> Self {
        let streams = m
            .media_streams
            .unwrap_or_default()
            .into_iter()
            .filter(|s| {
                matches!(
                    s.type_.as_deref(),
                    Some("Video") | Some("Audio") | Some("Subtitle")
                )
            })
            .map(|s| StreamInfo {
                index: s.index.unwrap_or(0),
                type_: s.type_.unwrap_or_default(),
                codec: s.codec.unwrap_or_default(),
                profile: s.profile.filter(|x| !x.is_empty()),
                display_title: s.display_title.filter(|x| !x.is_empty()),
                language: s.language.filter(|x| !x.is_empty()),
                width: s.width,
                height: s.height,
                bitrate: s.bitrate,
                channels: s.channels,
                channel_layout: s.channel_layout.filter(|x| !x.is_empty()),
                frame_rate: s.frame_rate,
                video_range: s.video_range.filter(|x| !x.is_empty() && x != "Unknown"),
                video_range_type: s.video_range_type.filter(|x| !x.is_empty() && x != "Unknown"),
                is_default: s.is_default.unwrap_or(false),
                is_external: s.is_external.unwrap_or(false),
                // 只认 DeliveryUrl。Path 是**服务端本地文件系统路径**(如 /media/x.ass),
                // 客户端取不到,拿来当 URL 只会 404。
                delivery_url: s.delivery_url.filter(|x| !x.is_empty()),
            })
            .collect();
        MediaVersion {
            id: m.id.unwrap_or_default(),
            name: m.name.unwrap_or_default(),
            container: m.container.filter(|x| !x.is_empty()),
            size_bytes: m.size,
            bitrate: m.bitrate,
            runtime_secs: m.runtime_ticks.unwrap_or(0) as f64 / 1e7,
            streams,
            // 单条源看不出「有没有被正则挑中」——那是整批比出来的,在 media_versions 里补。
            preferred: false,
        }
    }
}

/// 取条目全部版本+流(走 PlaybackInfo,拿到的才是服务端真判定可播的源)。
/// `version_regex` 只用来标 `preferred`,不影响返回哪些版本 —— 和 `resolve_stream`
/// 打的是同一个 PlaybackInfo 端点、同一批 MediaSource、同一套匹配文本,
/// 所以这里标出来的那条,就是真起播时会被选中的那条。
pub async fn media_versions(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    version_regex: &str,
) -> Result<Vec<MediaVersion>, String> {
    let url = format!(
        "{}/Items/{}/PlaybackInfo?UserId={}",
        s.server, item_id, s.user_id
    );
    let resp = http
        .post(&url)
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .json(&serde_json::json!({}))
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    #[derive(Deserialize)]
    struct Wrap {
        #[serde(rename = "MediaSources")]
        media_sources: Option<Vec<RawMediaSource>>,
    }
    let w: Wrap = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    let raw = w.media_sources.unwrap_or_default();
    let texts: Vec<String> = raw.iter().map(source_match_text).collect();
    let hit = crate::media::pick_index(&texts, version_regex);
    let mut out: Vec<MediaVersion> = raw.into_iter().map(MediaVersion::from).collect();
    if let Some(i) = hit {
        out[i].preferred = true;
    }
    Ok(out)
}

/// 首页 Hero 的随机推荐(草稿页 01:大幅剧照轮播)。只要有剧照的,否则 Hero 是空的。
pub async fn random_picks(
    http: &reqwest::Client,
    s: &Session,
    limit: u32,
) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items?Recursive=true&IncludeItemTypes=Movie,Series&SortBy=Random&Limit={}&ImageTypes=Backdrop&Fields=Overview,Genres,ProductionYear,CommunityRating",
        s.server, s.user_id, limit
    );
    fetch_items(http, s, &url).await
}

fn norm(server: &str) -> String {
    server.trim().trim_end_matches('/').to_string()
}

pub async fn login(
    http: &reqwest::Client,
    server: &str,
    username: &str,
    password: &str,
    device_id: &str,
) -> Result<(Session, LoginResult), String> {
    let server = norm(server);
    let url = format!("{server}/Users/AuthenticateByName");
    let body = serde_json::json!({ "Username": username, "Pw": password });
    let resp = http
        .post(&url)
        .header("X-Emby-Authorization", auth_header(device_id))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("登录失败: HTTP {}", resp.status()));
    }
    let auth: AuthResponse = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    let session = Session {
        server: server.clone(),
        token: auth.access_token,
        user_id: auth.user.id.clone(),
        device_id: device_id.to_string(),
    };
    let result = LoginResult {
        server,
        token: session.token.clone(),
        user_id: auth.user.id,
        user_name: auth.user.name,
        primary_image_tag: auth.user.primary_image_tag,
    };
    Ok((session, result))
}

pub async fn views(http: &reqwest::Client, s: &Session) -> Result<Vec<Item>, String> {
    let url = format!("{}/Users/{}/Views", s.server, s.user_id);
    fetch_items(http, s, &url).await
}

/// 媒体库规模统计。手机端首页顶栏那三个数字(电影 / 集 / 总计)和聚合视界每个源
/// 那行「1.6k 电影 · 99k 集」都用它。
#[derive(Serialize, Default, Clone, Debug)]
pub struct Counts {
    pub movie: u64,
    pub series: u64,
    pub episode: u64,
    pub boxset: u64,
}

/// `GET /Items/Counts?UserId=` —— **一次调用**拿到全库规模,不要自己翻页数条目。
///
/// ★ `UserId` 必须带。不带的话服务端把**该用户看不到的库**也算进去。
///   2026-07-28 在 mecf.mebimmer.de 上实测的差值:
///     带 UserId  → Movie 1579 / Series 2393 / Episode 98476
///     不带       → Movie 1618 / Series 2652 / Episode 99346
///   差 39 部电影、259 部剧、870 集 —— 数字看着都"像那么回事",所以漏了不会有人发现。
///
/// ★ 这个端点在**这台服务器上实测 200**;别假设所有 Emby fork 都有(本文件里
///   /Items/Filters、/Years、/Tags 就都是 404)。所以调用方必须容忍它失败 ——
///   统计条是锦上添花,不该让首页整个报错。
pub async fn counts(http: &reqwest::Client, s: &Session) -> Result<Counts, String> {
    let url = format!("{}/Items/Counts?UserId={}", s.server, s.user_id);
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let j: serde_json::Value = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    let n = |k: &str| j[k].as_u64().unwrap_or(0);
    Ok(Counts {
        movie: n("MovieCount"),
        series: n("SeriesCount"),
        episode: n("EpisodeCount"),
        boxset: n("BoxSetCount"),
    })
}

/// 媒体库浏览的查询条件。全 Option = 不传就不进 URL,老调用点(只给 parent_id)照旧能编。
#[derive(Default, Deserialize)]
pub struct ItemQuery {
    pub start_index: Option<u32>,
    /// None → 用 SERVER_PAGE_CAP(200)。★ 不能"省略 Limit 表示不限":
    /// 实测 smart.uhdnow.com(Emby 4.9.3)省略 Limit 只返 20 条,Limit=0 也是 20,
    /// 而 Limit=1000 被硬顶到 200。所以"不限"在单次请求里根本不存在,
    /// 超过 200 条的库只能靠 start_index 翻页(total 已随 ItemPage 返回)。
    pub limit: Option<u32>,
    pub sort_by: Option<String>,
    pub sort_order: Option<String>,
    pub genres: Option<Vec<String>>,
    pub tags: Option<Vec<String>>,
    pub years: Option<Vec<i32>>,
    pub studios: Option<Vec<String>>,
    pub rating_min: Option<f64>,
    pub rating_max: Option<f64>,
}

/// Emby 单次请求返回条数的服务端硬上限(实测:Limit=201/250/500/1000 一律只回 200)。
const SERVER_PAGE_CAP: u32 = 200;

impl ItemQuery {
    /// 本次查询是否需要客户端兜底过滤(见 items() 里的说明)。
    fn needs_local_filter(&self) -> bool {
        self.genres.as_ref().is_some_and(|v| !v.is_empty())
            || self.tags.as_ref().is_some_and(|v| !v.is_empty())
            || self.years.as_ref().is_some_and(|v| !v.is_empty())
            || self.rating_min.is_some()
            || self.rating_max.is_some()
    }

    /// 条目是否命中过滤条件。tags 无法在客户端判定(Item 不带 Tags),故不参与,
    /// 交给服务端;标准 Emby 认 Tags,不认的服务器上 tag 分面本来也是空的。
    fn matches(&self, it: &Item) -> bool {
        if let Some(g) = self.genres.as_ref().filter(|v| !v.is_empty()) {
            if !g.iter().any(|want| it.genres.iter().any(|has| has == want)) {
                return false;
            }
        }
        if let Some(y) = self.years.as_ref().filter(|v| !v.is_empty()) {
            match it.year {
                Some(iy) => {
                    if !y.iter().any(|w| *w as i64 == iy) {
                        return false;
                    }
                }
                None => return false,
            }
        }
        // 评分区间:无评分的条目视为不在区间(与旧 Dart 一致)。
        if self.rating_min.is_some() || self.rating_max.is_some() {
            let Some(r) = it.rating else { return false };
            if self.rating_min.is_some_and(|m| r < m) || self.rating_max.is_some_and(|m| r > m) {
                return false;
            }
        }
        true
    }
}

/// 媒体库浏览。返回 ItemPage(带 total)以支持翻页。
///
/// ★ 服务端过滤在部分 Emby 上是**假的**:实测 smart.uhdnow.com(Emby 4.9.3 "UHD")
/// 对 Genres/GenreIds/Years/MinCommunityRating 一律忽略 —— 传 Genres=喜剧 返回的
/// TotalRecordCount 与不传完全一致(3276),头几条根本没有喜剧标签。
/// 所以参数照发(标准 Emby/Jellyfin 认,服务端过滤能少传数据),同时在客户端按同样条件
/// 复筛一遍:认参数的服务器上复筛是 no-op,不认的服务器上至少保证**不会显示不匹配的条目**。
/// ponytail: 复筛只作用于当前这一页,3276 条的库筛"喜剧"只会得到前 200 条里的喜剧;
/// 要完整结果需服务端支持,或改成翻页累加(17 次请求)—— 宁可少给,不能给错。
pub async fn items(
    http: &reqwest::Client,
    s: &Session,
    parent_id: &str,
    q: &ItemQuery,
) -> Result<ItemPage, String> {
    // Fields 必须带 Genres/ProductionYear/CommunityRating,否则客户端复筛没有判据。
    let mut url = format!(
        "{}/Users/{}/Items?ParentId={}&Recursive=true&IncludeItemTypes=Movie,Series&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating",
        s.server, s.user_id, parent_id
    );
    url.push_str(&format!(
        "&Limit={}",
        q.limit.unwrap_or(SERVER_PAGE_CAP).min(SERVER_PAGE_CAP)
    ));
    if let Some(si) = q.start_index {
        url.push_str(&format!("&StartIndex={si}"));
    }
    // SortOrder 必须跟着 SortBy 一起发:实测只发 StartIndex 不发 SortOrder 时排序不稳,
    // 翻页会拿到重复/错位的条目。默认按名升序(= 原先写死的行为)。
    let sort_by = q.sort_by.as_deref().unwrap_or("SortName");
    let sort_order = q.sort_order.as_deref().unwrap_or("Ascending");
    url.push_str(&format!("&SortBy={}&SortOrder={}", enc(sort_by), enc(sort_order)));
    // Genres/Tags/Studios 竖线分隔,Years 逗号分隔(Emby 约定)。
    push_list(&mut url, "Genres", q.genres.as_deref(), "|");
    push_list(&mut url, "Tags", q.tags.as_deref(), "|");
    push_list(&mut url, "Studios", q.studios.as_deref(), "|");
    if let Some(y) = q.years.as_ref().filter(|v| !v.is_empty()) {
        let joined = y.iter().map(|v| v.to_string()).collect::<Vec<_>>().join(",");
        url.push_str(&format!("&Years={joined}"));
    }
    // Emby 只有下界参数(无 MaxCommunityRating),上界只能靠客户端复筛。
    if let Some(m) = q.rating_min {
        url.push_str(&format!("&MinCommunityRating={m}"));
    }

    let mut page = fetch_page(http, s, &url).await?;
    if q.needs_local_filter() {
        let before = page.items.len();
        page.items.retain(|it| q.matches(it));
        // 复筛动过手 → 服务端的 TotalRecordCount 不再是筛后总数,报本页实际条数,
        // 免得前端按 3276 画出永远翻不满的页码。
        if page.items.len() != before {
            page.total = page.items.len() as i64;
        }
    }
    Ok(page)
}

/// 把多值条件拼进 URL(空则跳过),值逐个转义。
fn push_list(url: &mut String, key: &str, vals: Option<&[String]>, sep: &str) {
    let Some(v) = vals.filter(|v| !v.is_empty()) else { return };
    let joined = v.iter().map(|x| enc(x)).collect::<Vec<_>>().join(sep);
    url.push_str(&format!("&{key}={joined}"));
}

fn enc(s: &str) -> String {
    urlencoding::encode(s).into_owned()
}

/// 首页"最新更新"轨道:某库最近入库条目(GroupItems 让剧集归并到剧,避免刷一堆单集)。
/// Latest 端点直接返回裸数组(非 {Items} 包裹)。
pub async fn latest(
    http: &reqwest::Client,
    s: &Session,
    parent_id: &str,
    limit: u32,
) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items/Latest?ParentId={}&GroupItems=true&Limit={}&Fields=PrimaryImageAspectRatio",
        s.server, s.user_id, parent_id, limit
    );
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let items: Vec<RawItem> = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(items.into_iter().map(Item::from).collect())
}

/// 演职人员(草稿页 03「演职人员」圆头像轨道)。
#[derive(Serialize)]
pub struct Person {
    pub id: String,
    pub name: String,
    pub role: Option<String>,
    /// Director / Actor / Writer / Producer …
    pub type_: String,
    pub has_primary: bool,
}

/// 详情页数据:条目元信息 + 剧集列表(仅 Series/Season 有 children)。
#[derive(Serialize)]
pub struct ItemDetail {
    pub id: String,
    pub name: String,
    pub type_: String,
    pub overview: String,
    pub year: Option<i64>,
    pub genres: Vec<String>,
    pub rating: Option<f64>,
    pub runtime_secs: f64,
    pub resume_secs: f64,
    pub has_primary: bool,
    pub has_backdrop: bool,
    pub is_favorite: bool,
    pub series_name: Option<String>,
    pub series_id: Option<String>,
    pub season_no: Option<i64>,
    pub episode_no: Option<i64>,
    /// 分级(TV-14 / PG-13 …)。选片时真的会看,比画质标签有用。缺省 = 服务器没刮到。
    pub official_rating: Option<String>,
    /// 剧集状态,实测值 `Continuing` / `Ended` / `Unreleased`。电影没有这一项。
    pub status: Option<String>,
    /// 标语(Taglines[0])。**实测只有 34% 的条目有** —— 没有就整行不画,不留空位。
    pub tagline: Option<String>,
    /// Series → 季数;Season → 集数。手机端详情页拿它决定要不要画季选择条。
    pub child_count: Option<i64>,
    pub children: Vec<Item>, // Series/Season → 剧集(按季+集号排序);Movie/Episode → 空
    pub people: Vec<Person>,
}

/// 条目详情。
///
/// `with_children`:是否把**全部分集**一起拉回来。
/// ★ 桌面/TV 端传 true(它们的详情页就是一屏铺完所有集)。
/// ★ **手机端传 false** —— 手机版详情页按季分页拉集(`season_episodes`)。
///   实测这台服务器上最长的剧 2648 集,全量拉是 1813.9KB / 1841ms,
///   分页 30 条是 20.0KB / 435ms。`content-visibility` 只省渲染,
///   省不掉这 1.8MB 的下载和解析。
pub async fn detail(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    with_children: bool,
) -> Result<ItemDetail, String> {
    /* Taglines / OfficialRating / Status 是 2026-07-28 加的,在 mecf.mebimmer.de 上实测有值:
         Status="Continuing"  OfficialRating="TV-14"  Taglines=["在演艺圈（这个世界）中，谎言就是武器"]
       "这剧完结没有" 是选片时真会问的问题，比画质标签有用得多。
       ★ 电影没有 Status，Taglines 常为空数组 —— 两者都是 Option，前端没值就**整行不画**，
         不留空位。 */
    let url = format!(
        "{}/Users/{}/Items/{item_id}?Fields=Overview,Genres,ProductionYear,CommunityRating,PremiereDate,People,Taglines,OfficialRating,Status,ChildCount",
        s.server, s.user_id
    );
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let j: serde_json::Value = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    let type_ = j["Type"].as_str().unwrap_or_default().to_string();

    // Series/Season 才拉子集(全部集,跨季按季号+集号排序)。手机端不要这一坨。
    let children = if with_children && (type_ == "Series" || type_ == "Season") {
        episodes(http, s, item_id).await.unwrap_or_default()
    } else {
        Vec::new()
    };

    let genres = j["Genres"]
        .as_array()
        .map(|a| a.iter().filter_map(|v| v.as_str().map(String::from)).collect())
        .unwrap_or_default();

    // 演职人员:导演优先排前(草稿轨道从左读),其余保持服务端顺序(已按重要性)。
    let mut people: Vec<Person> = j["People"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter(|p| !p["Name"].as_str().unwrap_or_default().is_empty())
                .map(|p| Person {
                    id: p["Id"].as_str().unwrap_or_default().to_string(),
                    name: p["Name"].as_str().unwrap_or_default().to_string(),
                    role: p["Role"].as_str().filter(|x| !x.is_empty()).map(String::from),
                    type_: p["Type"].as_str().unwrap_or_default().to_string(),
                    has_primary: p["PrimaryImageTag"].as_str().is_some(),
                })
                .collect()
        })
        .unwrap_or_default();
    people.sort_by_key(|p| if p.type_ == "Director" { 0 } else { 1 });

    Ok(ItemDetail {
        id: j["Id"].as_str().unwrap_or(item_id).to_string(),
        name: j["Name"].as_str().unwrap_or_default().to_string(),
        type_,
        overview: j["Overview"].as_str().unwrap_or_default().to_string(),
        year: j["ProductionYear"].as_i64(),
        genres,
        rating: j["CommunityRating"].as_f64(),
        runtime_secs: j["RunTimeTicks"].as_i64().unwrap_or(0) as f64 / 1e7,
        resume_secs: j["UserData"]["PlaybackPositionTicks"].as_i64().unwrap_or(0) as f64 / 1e7,
        has_primary: j.get("ImageTags").and_then(|v| v.get("Primary")).is_some(),
        has_backdrop: j["BackdropImageTags"].as_array().map(|a| !a.is_empty()).unwrap_or(false),
        is_favorite: j["UserData"]["IsFavorite"].as_bool().unwrap_or(false),
        series_name: j["SeriesName"].as_str().map(String::from),
        series_id: j["SeriesId"].as_str().map(String::from),
        season_no: j["ParentIndexNumber"].as_i64(),
        episode_no: j["IndexNumber"].as_i64(),
        official_rating: j["OfficialRating"].as_str().filter(|x| !x.is_empty()).map(String::from),
        status: j["Status"].as_str().filter(|x| !x.is_empty()).map(String::from),
        // Taglines 是数组，取第一条。实测只有 34% 的条目有 —— 前端没值就不画那一行。
        tagline: j["Taglines"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|v| v.as_str())
            .filter(|x| !x.is_empty())
            .map(String::from),
        child_count: j["ChildCount"].as_i64(),
        children,
        people,
    })
}

/// 继续观看(有播放进度的条目)。
pub async fn resume(http: &reqwest::Client, s: &Session, limit: u32) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items/Resume?Limit={}&MediaTypes=Video&Recursive=true&Fields=PrimaryImageAspectRatio",
        s.server, s.user_id, limit
    );
    fetch_items(http, s, &url).await
}

/// 翻页拉全:服务端把任何 Limit 都夹到 SERVER_PAGE_CAP(200),写 `Limit=500` 只会**静默少拿**。
/// 想要"全部"就必须自己按 StartIndex 翻到底。base_url 需已带 `?`(调用方拼好查询串)。
///
/// `max` 是安全闸:防某天对上一个几万条的库把内存和服务端一起打爆。到闸就停并返回已拿到的,
/// **不报错** —— 对收藏/分集这两个场景,拿到前 max 条远好过整页失败。
async fn fetch_all_paged(
    http: &reqwest::Client,
    s: &Session,
    base_url: &str,
    max: usize,
) -> Result<Vec<Item>, String> {
    let mut out: Vec<Item> = Vec::new();
    loop {
        let url = format!("{base_url}&StartIndex={}&Limit={SERVER_PAGE_CAP}", out.len());
        let page = fetch_items(http, s, &url).await?;
        let got = page.len();
        out.extend(page);
        // 不足一页 = 到底了;够一页但触闸也停(别无限翻)。
        if got < SERVER_PAGE_CAP as usize || out.len() >= max {
            break;
        }
    }
    Ok(out)
}

/// 收藏列表(IsFavorite 过滤,跨库递归)。
/// 原来写 `Limit=300` —— 服务端夹到 200,收藏超过 200 条就静默丢,用户看不到也无从察觉。改翻页。
/// ★ 排序**不走服务端**。2026-07-19 在用户的真实服务器(v1.uhdnow.com,UHD fork)上实测:
///   `SortBy=SortName&SortOrder=Ascending` 与 `SortBy=CommunityRating&SortOrder=Descending`
///   返回**完全相同**的顺序(恒为 DateCreated 降序)—— 这台 fork 在 `Filters=IsFavorite`
///   查询上直接无视 SortBy/SortOrder。原版 Emby(mebimmer)是认的,**别拿原版的结论替 fork 签字**。
///   所以这里只负责把 Fields 要全,排序交给前端本地做(收藏封顶 2000 条,本地排毫无压力)。
///   要改回服务端排序,先用日志里的 `[TRACE favorites url]` 手法在**目标服务器**上验证。
pub async fn favorites(http: &reqwest::Client, s: &Session) -> Result<Vec<Item>, String> {
    let base = format!(
        "{}/Users/{}/Items?Filters=IsFavorite&Recursive=true&IncludeItemTypes=Movie,Series,Episode&Fields=PrimaryImageAspectRatio,CommunityRating,DateCreated,DateLastMediaAdded,SortName",
        s.server, s.user_id
    );
    fetch_all_paged(http, s, &base, 2000).await
}

/// 切换收藏(POST=加,DELETE=取消)。
pub async fn set_favorite(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    fav: bool,
) -> Result<(), String> {
    let url = format!("{}/Users/{}/FavoriteItems/{}", s.server, s.user_id, item_id);
    let req = if fav { http.post(&url) } else { http.delete(&url) };
    let resp = req
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    Ok(())
}

/* ---------------- 管理员(admin)动作 ----------------
   对标 Emby web。名字容易混,这里把每一项打的**真实端点**钉死:

     刷新媒体库  → POST /Items/{id}/Refresh  Default 模式(只补缺失,不覆盖已有)
     扫描媒体库  → POST /Library/Refresh     整台服务器找新文件(Emby 的「扫描所有媒体库」)
     刷新元数据  → POST /Items/{id}/Refresh  FullRefresh + ReplaceAllMetadata(强制重刮)

   所以前两项**不是**一回事:一个作用于选中的库/条目,一个作用于整台服务器。 */

/// 当前登录用户是不是管理员。
///
/// 不从登录响应里取:配置里存下来的老账号根本不会再走一次 login,
/// 那样升级后老账号会永远判成非管理员(菜单静默不出现,还以为是权限没给)。
pub async fn is_admin(http: &reqwest::Client, s: &Session) -> Result<bool, String> {
    let url = format!("{}/Users/{}", s.server, s.user_id);
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let v: serde_json::Value = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(admin_flag(&v))
}

/// 从 /Users/{id} 响应里读管理员位。缺 Policy / 缺字段一律判**否** —— 宁可少给按钮。
fn admin_flag(user: &serde_json::Value) -> bool {
    user.get("Policy")
        .and_then(|p| p.get("IsAdministrator"))
        .and_then(|b| b.as_bool())
        .unwrap_or(false)
}

/// 刷新某个库/条目。`full=false` 只补缺失,`full=true` 强制重刮(替换已有元数据)。
///
/// Recursive=true:对库卡片来说不递归等于什么都没做(库本身没有元数据可刮)。
/// ReplaceAllImages 恒 false —— 用户自己换过的封面不该被一次「刷新元数据」抹掉。
pub async fn refresh_item(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    full: bool,
) -> Result<(), String> {
    post_admin(http, s, &refresh_url(&s.server, item_id, full)).await
}

fn refresh_url(server: &str, item_id: &str, full: bool) -> String {
    let mode = if full { "FullRefresh" } else { "Default" };
    format!(
        "{server}/Items/{item_id}/Refresh?Recursive=true&MetadataRefreshMode={mode}&ImageRefreshMode={mode}&ReplaceAllMetadata={full}&ReplaceAllImages=false"
    )
}

/// 扫描整台服务器的媒体库文件(Emby web 的「扫描所有媒体库」)。
pub async fn scan_all_libraries(http: &reqwest::Client, s: &Session) -> Result<(), String> {
    let url = format!("{}/Library/Refresh", s.server);
    post_admin(http, s, &url).await
}

async fn post_admin(http: &reqwest::Client, s: &Session, url: &str) -> Result<(), String> {
    let resp = http
        .post(url)
        .header("X-Emby-Token", &s.token)
        .header("Content-Length", "0") // 无 body 的 POST,少了这个有的反代直接 411
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    // 403 = 服务端说你不是管理员。菜单本不该出现,出现了就把真话说出来。
    if resp.status().as_u16() == 403 {
        return Err("服务器拒绝:当前账号没有管理员权限".into());
    }
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    Ok(())
}

/// 某剧全部剧集(递归跨季,按季号→集号升序)。
/// 原来写 `Limit=500` —— 服务端夹到 200,长剧(如 500+ 集的动画/长篇剧)**直接缺集**,
/// 而且缺得无声无息:详情页分集列表就是少,用户以为服务器没有。改翻页。
/// 一季。手机端详情页的季 Tab 条用它。
#[derive(Serialize, Clone, Debug)]
pub struct SeasonInfo {
    pub id: String,
    /// **服务器返回的 Name,不要自己拼「第 N 季」**。
    /// 实测真名是 "全 1 季" / "果宝特攻2" / "怪奇物语 4" —— 自己拼在真机上对不上。
    pub name: String,
    pub index_no: Option<i64>,
    /// 这一季有多少集。决定图文列表还是集号网格(>50 集切网格)。
    pub child_count: i64,
    pub unplayed: i64,
    pub has_primary: bool,
}

/// 某剧的季列表。`/Users/{u}/Items?ParentId={seriesId}` —— 实测返回 Type=Season,
/// 带 ChildCount 和 UserData.UnplayedItemCount(2026-07-28 于 mecf.mebimmer.de 实测)。
///
/// ★ 有些剧**没有季**(单季番剧直接挂集)。那种情况这里返回空 Vec,
///   调用方要回落到「拿 seriesId 当 parent 直接分页拉集」——
///   不回落的表现是"点进去一集都没有",而且不报错。
pub async fn seasons(http: &reqwest::Client, s: &Session, series_id: &str) -> Result<Vec<SeasonInfo>, String> {
    let url = format!(
        "{}/Users/{}/Items?ParentId={}&IncludeItemTypes=Season&SortBy=IndexNumber&SortOrder=Ascending&Fields=ChildCount",
        s.server, s.user_id, series_id
    );
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let j: serde_json::Value = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(j["Items"]
        .as_array()
        .map(|a| {
            a.iter()
                .map(|v| SeasonInfo {
                    id: v["Id"].as_str().unwrap_or_default().to_string(),
                    name: v["Name"].as_str().unwrap_or_default().to_string(),
                    index_no: v["IndexNumber"].as_i64(),
                    child_count: v["ChildCount"].as_i64().unwrap_or(0),
                    unplayed: v["UserData"]["UnplayedItemCount"].as_i64().unwrap_or(0),
                    has_primary: v.get("ImageTags").and_then(|x| x.get("Primary")).is_some(),
                })
                .collect()
        })
        .unwrap_or_default())
}

/// 某季(或某剧)的分集**分页**拉取。手机端详情页滚到底续拉靠它。
///
/// ★ `parent_id` 可以是季 id,也可以是剧 id(没分季的剧)。
/// ★ 不走 `fetch_all_paged` —— 这里要的就是"只拿这一页",全量拉正是要避开的那件事。
/// ★ 带 `Fields=MediaSources` 才有分集卡那行「2160p · 45M · 18.4G」。
pub async fn season_episodes(
    http: &reqwest::Client,
    s: &Session,
    parent_id: &str,
    start_index: i64,
    limit: i64,
) -> Result<ItemPage, String> {
    let url = format!(
        "{}/Users/{}/Items?ParentId={}&IncludeItemTypes=Episode&Recursive=true&SortBy=ParentIndexNumber,IndexNumber&SortOrder=Ascending&Fields=PrimaryImageAspectRatio,MediaSources,Overview,PremiereDate&StartIndex={}&Limit={}",
        s.server,
        s.user_id,
        parent_id,
        start_index,
        limit.min(SERVER_PAGE_CAP as i64),
    );
    fetch_page(http, s, &url).await
}

async fn episodes(
    http: &reqwest::Client,
    s: &Session,
    series_id: &str,
) -> Result<Vec<Item>, String> {
    // 带 MediaSources 才有草稿分集卡那行「2160p · 45M · 18.4G」。
    let base = format!(
        "{}/Users/{}/Items?ParentId={}&IncludeItemTypes=Episode&Recursive=true&SortBy=ParentIndexNumber,IndexNumber&SortOrder=Ascending&Fields=PrimaryImageAspectRatio,MediaSources",
        s.server, s.user_id, series_id
    );
    fetch_all_paged(http, s, &base, 3000).await
}

/// 播放期同步所需的条目信息:Trakt(类型+外部ID+时长)+ Bangumi(标题/季/集/首播日)。
#[derive(serde::Serialize, Clone)]
pub struct ScrobbleInfo {
    pub media_type: String,     // "movie" | "episode"
    pub ids: serde_json::Value, // {imdb, tmdb, tvdb}(Trakt;可能为空对象)
    /// 剧集专用:**剧**(Series)自己的外部 ID。
    /// ★ 为什么要它:Emby 分集的 ProviderIds 经常是空的(尤其番剧),此时 `ids` 为空对象,
    /// scrobble 直接被 has_trakt_ids() 挡掉、一声不吭。有剧 ID + 季集号就能用
    /// {"show":{ids},"episode":{season,number}} 这种 Trakt 更认的形态兜底。
    pub show_ids: serde_json::Value,
    pub runtime_secs: f64,
    // Bangumi 反查用:剧集取剧名(SeriesName),电影取片名(Name)。
    pub title: String,
    pub original_title: Option<String>,
    pub air_date: Option<String>, // PremiereDate
    pub season: i64,              // ParentIndexNumber(电影=1)
    pub episode: i64,             // IndexNumber(电影=1)
}

impl ScrobbleInfo {
    /// Trakt 是否可用:分集自己的 ID 或所属剧的 ID,有一个就能上报。
    pub fn has_trakt_ids(&self) -> bool {
        let non_empty = |v: &serde_json::Value| v.as_object().is_some_and(|o| !o.is_empty());
        non_empty(&self.ids) || non_empty(&self.show_ids)
    }

    /// 组装 Trakt 请求体里的条目部分。
    /// 分集优先用「剧 ID + 季集号」——Trakt 对这种形态的容错最好;分集自带 ID 才走 episode.ids。
    pub fn trakt_body(&self) -> serde_json::Value {
        let non_empty = |v: &serde_json::Value| v.as_object().is_some_and(|o| !o.is_empty());
        if self.media_type == "movie" {
            return serde_json::json!({ "movie": { "ids": self.ids } });
        }
        if non_empty(&self.show_ids) {
            serde_json::json!({
                "show": { "ids": self.show_ids },
                "episode": { "season": self.season, "number": self.episode },
            })
        } else {
            serde_json::json!({ "episode": { "ids": self.ids } })
        }
    }
}

/// 取某个条目的外部 ID(Imdb/Tmdb/Tvdb),归一成 Trakt 要的形状。
fn provider_ids(j: &serde_json::Value) -> serde_json::Value {
    let mut ids = serde_json::Map::new();
    if let Some(obj) = j["ProviderIds"].as_object() {
        for (k, v) in obj {
            let key = k.to_lowercase();
            if !matches!(key.as_str(), "imdb" | "tmdb" | "tvdb") {
                continue;
            }
            let sv = v.as_str().unwrap_or("").trim().to_string();
            if sv.is_empty() {
                continue;
            }
            if key == "imdb" {
                ids.insert(key, serde_json::Value::String(sv));
            } else if let Ok(n) = sv.parse::<i64>() {
                ids.insert(key, serde_json::Value::from(n));
            }
        }
    }
    serde_json::Value::Object(ids)
}

/// 取条目元数据,组装成播放期同步用信息。仅 Movie/Episode 返回 Some(其它类型不同步)。
pub async fn fetch_scrobble_info(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
) -> Option<ScrobbleInfo> {
    let url = format!(
        "{}/Users/{}/Items/{item_id}?Fields=ProviderIds,PremiereDate,OriginalTitle",
        s.server, s.user_id
    );
    let resp = http.get(&url).header("X-Emby-Token", &s.token).send().await.ok()?;
    if !resp.status().is_success() {
        return None;
    }
    let j: serde_json::Value = resp.json().await.ok()?;
    let raw_type = j["Type"].as_str()?;
    let media_type = match raw_type {
        "Movie" => "movie",
        "Episode" => "episode",
        _ => return None,
    };
    let is_episode = raw_type == "Episode";
    // ProviderIds 键名大小写不一(Imdb/Tmdb/Tvdb),归一小写;tmdb/tvdb 转数字(Trakt 要 int)。
    let ids = provider_ids(&j);
    // 分集再顺带把**剧**的 ID 拉一次(多一次请求,换 Trakt 上报不再静默失败)。
    let show_ids = match (is_episode, j["SeriesId"].as_str()) {
        (true, Some(sid)) if !sid.is_empty() => {
            let u = format!("{}/Users/{}/Items/{sid}?Fields=ProviderIds", s.server, s.user_id);
            match http.get(&u).header("X-Emby-Token", &s.token).send().await {
                Ok(r) if r.status().is_success() => r
                    .json::<serde_json::Value>()
                    .await
                    .map(|v| provider_ids(&v))
                    .unwrap_or_else(|_| serde_json::json!({})),
                _ => serde_json::json!({}),
            }
        }
        _ => serde_json::json!({}),
    };
    // 剧集用剧名(SeriesName)反查 Bangumi 本体,电影用片名。
    let title = if is_episode {
        j["SeriesName"].as_str().unwrap_or("")
    } else {
        j["Name"].as_str().unwrap_or("")
    }
    .to_string();
    Some(ScrobbleInfo {
        media_type: media_type.to_string(),
        ids,
        show_ids,
        runtime_secs: j["RunTimeTicks"].as_i64().unwrap_or(0) as f64 / 1e7,
        title,
        original_title: j["OriginalTitle"].as_str().filter(|s| !s.is_empty()).map(String::from),
        air_date: j["PremiereDate"].as_str().filter(|s| !s.is_empty()).map(String::from),
        season: if is_episode { j["ParentIndexNumber"].as_i64().unwrap_or(1) } else { 1 },
        episode: if is_episode { j["IndexNumber"].as_i64().unwrap_or(1) } else { 1 },
    })
}

/// 搜索。types=None 时用默认类型集(含 Episode —— 旧实现写死 Movie,Series 搜不到分集)。
///
/// ★ 实测提醒:smart.uhdnow.com(Emby 4.9.3)在带 SearchTerm 时**忽略 IncludeItemTypes**
/// (传 Episode 照样只回 Series/Movie),且分集名("星海飞驰27")根本搜不出来。
/// 参数照发是为标准 Emby/Jellyfin 服务;这台服务器上搜不到分集是服务端行为,客户端改不动。
pub async fn search(
    http: &reqwest::Client,
    s: &Session,
    query: &str,
    types: Option<&[String]>,
    limit: Option<u32>,
) -> Result<Vec<Item>, String> {
    let url = search_url(s, query, types, limit);
    fetch_items(http, s, &url).await
}

/// 拆出来只为可测 —— 见 tests::search_term_must_be_capitalized。
fn search_url(s: &Session, query: &str, types: Option<&[String]>, limit: Option<u32>) -> String {
    let types = match types.filter(|t| !t.is_empty()) {
        Some(t) => t.iter().map(|x| enc(x)).collect::<Vec<_>>().join(","),
        None => "Movie,Series,Episode".to_string(),
    };
    // ★★ 必须是 SearchTerm(大写 S)。原实现写的 searchTerm 被服务端**静默忽略**:
    // 实测 searchTerm=凡人 返回 TotalRecordCount=25596(整个服务器!)且头几条与关键词无关,
    // 而 SearchTerm=凡人 返回 6 条正确结果。也就是说搜索一直在吐全库前 N 条冒充结果。
    // Emby 的 query 参数大小写敏感,别再改回小写。
    // ProviderIds/PresentationUniqueKey/Path:跨服务器续播恢复扫描要靠它们做强匹配 ——
    // 搜索是恢复扫描的入口,这里不要就只能靠剧名猜(静默匹配不上,不报错)。
    format!(
        "{}/Users/{}/Items?SearchTerm={}&IncludeItemTypes={}&Recursive=true&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating,{HISTORY_FIELDS}&Limit={}",
        s.server,
        s.user_id,
        enc(query),
        types,
        limit.unwrap_or(50).min(SERVER_PAGE_CAP)
    )
}

/// 跨服务器续播强匹配所需的 Fields(见 Item 的 provider_ids/presentation_unique_key/path)。
pub const HISTORY_FIELDS: &str = "ProviderIds,PresentationUniqueKey,Path,SeriesId";

/// 相似推荐(详情页底部)。
///
/// 2026-07-15 在 mecf.mebimmer.de 实测(见 [[emby-test-server-2-mebimmer]]):
/// `GET /Items/{id}/Similar?UserId=..&Limit=12` → `{"Items":[...],"TotalRecordCount":N}`,
/// 相似度靠谱(同题材),Limit 生效,条目带 Primary/Backdrop。可能混 Series+Movie。
/// 旧 Flutter 栈既定口径一致(`getSimilarItems`)。
///
/// 复用 [`fetch_items`] —— 返回结构和列表端点同构,不另造解析。
pub async fn similar(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    limit: u32,
) -> Result<Vec<Item>, String> {
    // Fields 与列表端点对齐:海报要 PrimaryImageAspectRatio,卡片角标要 Genres/Year/Rating。
    let url = format!(
        "{}/Items/{item_id}/Similar?UserId={}&Limit={}&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating,{HISTORY_FIELDS}",
        s.server,
        s.user_id,
        limit.min(SERVER_PAGE_CAP)
    );
    fetch_items(http, s, &url).await
}

/// 演职员详情页要的那点东西。
///
/// ★ 演员在 Emby 里就是一个 `Type=Person` 的 Item,和条目走同一条 `/Users/{uid}/Items/{id}`,
///   所以头像直接复用 `lpimg` 的 Primary 通道 —— 不需要另开图片路径。
/// ★ 生平(Overview)**经常是空的**:只有刮削器抓到 TMDB 人物页才有。空是常态不是错误,
///   前端要为"没有生平"排一版,不能留一块空白。
#[derive(Serialize)]
pub struct PersonDetail {
    pub id: String,
    pub name: String,
    /// 生平。空串 = 服务器上就没有。
    pub overview: String,
    pub has_primary: bool,
    /// 出生日期 ISO 串(PremiereDate)。
    pub birthday: Option<String>,
    /// 卒年(EndDate)。有值 = 已故。
    pub death_day: Option<String>,
    /// 出生地(ProductionLocations[0])。
    pub birth_place: Option<String>,
}

/// 演职员详情。
pub async fn person_detail(
    http: &reqwest::Client,
    s: &Session,
    person_id: &str,
) -> Result<PersonDetail, String> {
    let url = format!(
        "{}/Users/{}/Items/{person_id}?Fields=Overview,PremiereDate,EndDate,ProductionLocations",
        s.server, s.user_id
    );
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let j: serde_json::Value = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(PersonDetail {
        id: j["Id"].as_str().unwrap_or(person_id).to_string(),
        name: j["Name"].as_str().unwrap_or_default().to_string(),
        overview: j["Overview"].as_str().unwrap_or_default().to_string(),
        has_primary: j.get("ImageTags").and_then(|v| v.get("Primary")).is_some(),
        birthday: j["PremiereDate"].as_str().map(String::from),
        death_day: j["EndDate"].as_str().map(String::from),
        birth_place: j["ProductionLocations"]
            .as_array()
            .and_then(|a| a.first())
            .and_then(|v| v.as_str())
            .filter(|x| !x.is_empty())
            .map(String::from),
    })
}

/// 某人参演的电影 / 剧集。
///
/// ★ 用 `PersonIds` 而不是 `Person=<名字>`:同名演员在库里是两个人,按名字筛会把两个人的
///   作品混在一起,而且**不报错**。
/// ★ 按首播时间倒序 —— 演员页的通用口径是"最近的作品在前"。
pub async fn person_items(
    http: &reqwest::Client,
    s: &Session,
    person_id: &str,
    limit: u32,
) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items?PersonIds={person_id}&Recursive=true&IncludeItemTypes=Movie,Series\
         &SortBy=PremiereDate&SortOrder=Descending&Limit={}\
         &Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating",
        s.server,
        s.user_id,
        limit.min(SERVER_PAGE_CAP)
    );
    fetch_items(http, s, &url).await
}

/// 取单条 Item(带跨服续播强匹配所需的全部 Fields)。
/// 与 [`detail`] 的区别:detail 面向详情页(要 Overview/People/子集),这个面向观看记录 —— 只要匹配判据。
pub async fn item_for_history(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
) -> Result<Item, String> {
    let url = format!(
        "{}/Users/{}/Items/{item_id}?Fields=Genres,ProductionYear,CommunityRating,{HISTORY_FIELDS}",
        s.server, s.user_id
    );
    let resp = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let raw: RawItem = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(raw.into())
}

/// 取某剧的 TMDB id(跨服务器匹配剧集时用:同一部剧在两台服的 item_id 不同,但 TMDB id 相同)。
/// 剧不存在/没刮到 TMDB → None(不是错误:没刮削的库属正常,匹配自然降级)。
pub async fn series_tmdb_id(
    http: &reqwest::Client,
    s: &Session,
    series_id: &str,
) -> Option<String> {
    let item = item_for_history(http, s, series_id).await.ok()?;
    crate::watch_history::extract_provider_id(&item.provider_ids, "Tmdb")
}

/// 合集(草稿页 01 首页「合集」轨道)。
pub async fn collections(http: &reqwest::Client, s: &Session) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Users/{}/Items?IncludeItemTypes=BoxSet&Recursive=true&SortBy=SortName&SortOrder=Ascending&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating&Limit={}",
        s.server, s.user_id, SERVER_PAGE_CAP
    );
    fetch_items(http, s, &url).await
}

/// 接下来播放(/Shows/NextUp)。返回的是 Episode,靠 SeriesName 才认得出是哪部剧。
pub async fn next_up(http: &reqwest::Client, s: &Session, limit: u32) -> Result<Vec<Item>, String> {
    let url = format!(
        "{}/Shows/NextUp?UserId={}&Limit={}&Fields=PrimaryImageAspectRatio,Genres,ProductionYear,CommunityRating",
        s.server, s.user_id, limit
    );
    fetch_items(http, s, &url).await
}

/// 标记已看/未看(POST=已看,DELETE=未看)。实测两者均返 200 + 更新后的 UserData。
pub async fn set_played(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    played: bool,
) -> Result<(), String> {
    let url = format!("{}/Users/{}/PlayedItems/{}", s.server, s.user_id, item_id);
    let req = if played { http.post(&url) } else { http.delete(&url) };
    let resp = req
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    Ok(())
}

/// 服务端登出。★ 尽力而为:实测 smart.uhdnow.com 该端点 404 且 token 登出后仍可用,
/// 所以**不能**让它的失败挡住本地删账号 —— 调用方忽略返回值即可。
pub async fn logout(http: &reqwest::Client, s: &Session) -> Result<(), String> {
    let resp = http
        .post(format!("{}/Sessions/Logout", s.server))
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("登出失败: HTTP {}", resp.status()));
    }
    Ok(())
}

// ---------- 服务器公开信息 / 测试连接(登录前用,无会话)----------
#[derive(Serialize, Deserialize)]
pub struct ServerInfo {
    pub name: String,
    pub version: String,
    pub id: String,
}

/// 服主下发的一条备用线路(uhdnow/emby_ext_domains 的 `data[]` 元素)。
#[derive(Deserialize)]
pub struct ExtDomain {
    pub name: String,
    pub url: String,
}

#[derive(Deserialize)]
struct ExtDomainsResp {
    #[serde(default)]
    data: Vec<ExtDomain>,
    #[serde(default)]
    ok: bool,
}

/// 拉取服主配置的备用线路(「同步线路」)。
///
/// ## 这是什么(2026-07-15 按用户点名的 https://github.com/uhdnow/emby_ext_domains 实读源码)
/// **不是**某个中心化的域名列表,而是**服主自己部署**的一个 Go 小服务(Gin,~180 行),
/// 用仓库自带的 nginx 片段挂在**自己 Emby 域名的同一 origin** 下:
/// ```nginx
/// location = /emby/System/Ext/ServerDomains { proxy_pass http://127.0.0.1:52143; }
/// ```
/// 所以「匹配」是**隐式同源**的:拿当前这台服务器的地址去打这个端点,回来的就是这台服的备用线路。
/// 没有 key、没有 ID、没有分组 —— 别去设计什么匹配逻辑,不存在。
///
/// 鉴权:服务端 `extractToken` 认 `X-Emby-Token` / `X-Emby-Authorization` 等 9 种来源,
/// 我们现有的头原样透传即可,零改造。它拿到 token 后回打 `{Emby}/System/Info` 校验(3s 超时)。
///
/// ## Ok(vec![]) 与 Err 的分界(★ 别搞反)
/// **绝大多数 Emby 服务器没装这玩意 —— 404 是常态,不是错误。** 404/超时/解析不了 → `Ok(vec![])`,
/// 让 UI 说「这台服务器没提供线路表」而不是弹一个红色报错吓人。
/// 只有 401(token 失效,用户能采取行动)才 Err。
pub async fn ext_domains(
    http: &reqwest::Client,
    session: &Session,
) -> Result<Vec<ExtDomain>, String> {
    /* 端点路径在上游 nginx 里是**精确匹配** `= /emby/System/Ext/ServerDomains`,
       是相对 origin 的。用户填的地址可能已经带了 /emby(反代常见写法),
       直接拼就成了 /emby/emby/… → 404。故先把结尾的 /emby 削掉再拼。 */
    let base = norm(&session.server);
    let origin = base.strip_suffix("/emby").unwrap_or(&base);
    let url = format!("{origin}/emby/System/Ext/ServerDomains");

    let resp = tokio::time::timeout(
        // 上游 nginx 侧 proxy_read_timeout 10s;而且它每次都要回源校验 token(不缓存)。
        std::time::Duration::from_secs(10),
        http.get(&url)
            .header("X-Emby-Token", &session.token)
            .header("X-Emby-Authorization", auth_header(&session.device_id))
            .send(),
    )
    .await;

    let resp = match resp {
        Ok(Ok(r)) => r,
        // 超时/连不上 —— 大概率是没部署。不是用户能修的事,别报错。
        _ => return Ok(vec![]),
    };
    if resp.status() == reqwest::StatusCode::UNAUTHORIZED {
        return Err("线路服务拒绝了登录凭据(token 可能已失效),请重新登录".into());
    }
    if !resp.status().is_success() {
        return Ok(vec![]); // 404 = 服主没部署,常态
    }
    let Ok(j) = resp.json::<ExtDomainsResp>().await else {
        return Ok(vec![]); // 同路径上挂了别的东西,返回的不是这个格式
    };
    if !j.ok {
        return Ok(vec![]);
    }
    /* ★ 信任边界:`url` 是**服主在自己 config.yaml 里自填的裸字符串,上游零校验**。
       它会被我们直接拿去当 baseUrl 拼 API + 带上 token 请求 —— 配错或被投毒
       就等于把 token 发到任意地址。这里必须自己把关:只收 http(s),且能解析成合法 URL。 */
    Ok(j
        .data
        .into_iter()
        .filter(|d| {
            let u = d.url.trim();
            // 用 reqwest 自己 re-export 的 Url,不为这一行去加 `url` 直接依赖。
            (u.starts_with("http://") || u.starts_with("https://"))
                && reqwest::Url::parse(u).is_ok()
        })
        .collect())
}

/// 探测服务器(草稿页 06「测试连接」)。★ 不需要登录态 —— 这是登录前用的,别走 session。
/// 实测 GET /System/Info/Public 返回 {ServerName, Version, Id}。
pub async fn server_info(http: &reqwest::Client, server: &str) -> Result<ServerInfo, String> {
    let url = format!("{}/System/Info/Public", norm(server));
    let resp = http
        .get(&url)
        .header("X-Emby-Authorization", auth_header("linplayer-probe"))
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let j: serde_json::Value = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    Ok(ServerInfo {
        name: j["ServerName"].as_str().unwrap_or_default().to_string(),
        version: j["Version"].as_str().unwrap_or_default().to_string(),
        id: j["Id"].as_str().unwrap_or_default().to_string(),
    })
}

// ---------- 筛选分面(草稿媒体库详情的 类型/标签/时间 面板)----------
#[derive(Serialize, Default)]
pub struct Filters {
    pub genres: Vec<String>,
    pub tags: Vec<String>,
    pub years: Vec<i32>,
    pub studios: Vec<String>,
    pub official_ratings: Vec<String>,
}

/// 取某库的筛选分面。
///
/// ★ 端点可用性是实测出来的,不是照文档抄的(smart.uhdnow.com / Emby 4.9.3):
///   /Items/Filters、/Users/{u}/Items/Filters2 → 404(旧 Dart 注释里记的坑,复现了)
///   /Genres、/Studios                          → 200 ✅
///   /Years、/Tags、/OfficialRatings            → 404 ❌(旧 Dart 也在拉这三个并吞错,
///                                                 所以旧版的年份/标签分面一直是空的)
/// 故:genres/studios/tags/official_ratings 走各自分面端点(**各自吞错**,一个挂不能拖垮面板);
/// years 因为没有可用端点,改用两次 Limit=1 探针取最早/最晚年份再铺成区间(见下)。
pub async fn filters(http: &reqwest::Client, s: &Session, parent_id: &str) -> Result<Filters, String> {
    // 五路并行,各自吞错 —— 某个分面 404/500 只让它自己为空。
    let (genres, tags, studios, official_ratings, years) = tokio::join!(
        facet(http, s, "Genres", parent_id),
        facet(http, s, "Tags", parent_id),
        facet(http, s, "Studios", parent_id),
        facet(http, s, "OfficialRatings", parent_id),
        year_range(http, s, parent_id),
    );
    Ok(Filters {
        genres,
        tags,
        studios,
        official_ratings,
        years,
    })
}

/// 某分面端点的库内取值(Items[].Name)。失败吞掉返回空:分面挂了不该让整个面板报错。
async fn facet(http: &reqwest::Client, s: &Session, endpoint: &str, parent_id: &str) -> Vec<String> {
    let url = format!(
        "{}/{}?UserId={}&ParentId={}&Recursive=true",
        s.server, endpoint, s.user_id, parent_id
    );
    let Ok(resp) = http.get(&url).header("X-Emby-Token", &s.token).send().await else {
        return Vec::new();
    };
    if !resp.status().is_success() {
        return Vec::new();
    }
    let Ok(j) = resp.json::<serde_json::Value>().await else {
        return Vec::new();
    };
    j["Items"]
        .as_array()
        .map(|a| {
            a.iter()
                .filter_map(|i| i["Name"].as_str())
                .filter(|n| !n.is_empty())
                .map(String::from)
                .collect()
        })
        .unwrap_or_default()
}

/// 年份分面。★ Emby 没有 /Years 端点(实测 404),而全量扫出所有年份要翻 17 页(200/页)。
/// 折中:按 ProductionYear 正/倒排各取 1 条拿到最早/最晚年,铺成倒序区间。
/// ponytail: 区间里可能混入该库没有的年份(选了就是空结果),换取 2 次请求而非 17 次;
/// 要精确年份列表得等服务端支持分面,或改成全量扫描。
async fn year_range(http: &reqwest::Client, s: &Session, parent_id: &str) -> Vec<i32> {
    let probe = |order: &'static str| async move {
        let url = format!(
            "{}/Users/{}/Items?ParentId={}&Recursive=true&IncludeItemTypes=Movie,Series&SortBy=ProductionYear&SortOrder={}&Limit=1&Fields=ProductionYear",
            s.server, s.user_id, parent_id, order
        );
        fetch_items(http, s, &url)
            .await
            .ok()
            .and_then(|v| v.into_iter().next())
            .and_then(|i| i.year)
    };
    let (newest, oldest) = tokio::join!(probe("Descending"), probe("Ascending"));
    match (newest, oldest) {
        (Some(hi), Some(lo)) if hi >= lo => (lo as i32..=hi as i32).rev().collect(),
        _ => Vec::new(),
    }
}

/// 取一页(含总数)。所有 {Items} 包裹的列表端点都从这里过。
async fn fetch_page(http: &reqwest::Client, s: &Session, url: &str) -> Result<ItemPage, String> {
    let resp = http
        .get(url)
        .header("X-Emby-Token", &s.token)
        .send()
        .await
        .map_err(|e| format!("网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("请求失败: HTTP {}", resp.status()));
    }
    let data: ItemsResponse = resp.json().await.map_err(|e| format!("解析失败: {e}"))?;
    let items: Vec<Item> = data.items.into_iter().map(Item::from).collect();
    Ok(ItemPage {
        // 端点没给 TotalRecordCount 时退回本页条数,别让前端看到 0。
        total: data.total_record_count.unwrap_or(items.len() as i64),
        items,
    })
}

/// 只要条目、不关心总数的调用点(继续观看/收藏/剧集…)。
async fn fetch_items(http: &reqwest::Client, s: &Session, url: &str) -> Result<Vec<Item>, String> {
    Ok(fetch_page(http, s, url).await?.items)
}

#[derive(Deserialize)]
struct PlaybackInfoResp {
    #[serde(rename = "MediaSources")]
    media_sources: Vec<RawMediaSource>,
    #[serde(rename = "PlaySessionId")]
    play_session_id: Option<String>,
}

/// 一次播放会话的目标 + 上报三件套共享的 id。
/// ★ PlaySessionId 必须贯穿 start/progress/stopped 三次上报(续播落地老坑)。
#[derive(Clone, Serialize)]
pub struct PlaybackTarget {
    pub url: String,
    pub item_id: String,
    pub media_source_id: String,
    pub play_session_id: String,
    pub play_method: String, // "DirectStream" | "Transcode"
    /// 这一版是不是杜比视界(供「杜比视界自动软解」判断)。
    /// 在这里算而不是丢给前端:PlaybackInfo 的 MediaStreams 只有这条路上拿得到,
    /// 前端手里的 media_versions 是**另一次请求**,两边可能选的不是同一个版本。
    pub is_dolby_vision: bool,
    /// 外挂字幕(服务器上和视频同级的独立 .ass/.srt 文件)。
    /// 这些**不在容器里**,mpv 拿到视频 URL 后 track-list 里根本看不到它们,
    /// 必须播放器起来后逐条 `sub-add`。
    pub external_subs: Vec<ExternalSub>,
}

/// 服务器不给 DeliveryUrl 时自己拼的取字幕路径(相对路径,不含 host)。
///
/// 格式必须和 Emby 自己发的 DeliveryUrl 一模一样 —— 见 tests 里那条实测断言。
fn subtitle_path(item_id: &str, media_source_id: &str, index: i64, ext: &str, token: &str) -> String {
    format!("/Videos/{item_id}/{media_source_id}/Subtitles/{index}/0/Stream.{ext}?api_key={token}")
}

/// 一条外挂字幕的挂载信息。
#[derive(Clone, Serialize)]
pub struct ExternalSub {
    pub url: String,
    pub title: String,
    pub lang: Option<String>,
    pub is_default: bool,
}

// ---------- 章节(「跳过片头/片尾」与「进度条缩略图预览」共用同一份数据)----------
//
// 为什么这两个功能合并成一次请求:Emby 的章节既带时间点(拿来判片头片尾区间),
// 又带 ImageTag(拿来当进度条悬停缩略图)。分两条链路去打服务器纯属重复劳动。
//
// ⚠️ 现实边界,别高估它:
//   * 章节是**服务端**生成的。没刮削过章节的库 → 返回空表 → 两个功能都自动静默不工作。
//   * 章节图要服务端开了「章节图片提取」才有 ImageTag;只有时间点没有图时,
//     跳过片头照常工作,缩略图则退回纯时间气泡(现有行为)。
//   * 片头识别靠**章节名**。番剧组/刮削器给的名字五花八门,这里只认常见写法,
//     认不出就不跳 —— 宁可不跳,也不能把正片切掉。

#[derive(Deserialize)]
struct RawChapter {
    #[serde(rename = "StartPositionTicks")]
    start: Option<i64>,
    #[serde(rename = "Name")]
    name: Option<String>,
    #[serde(rename = "ImageTag")]
    image_tag: Option<String>,
}

#[derive(Deserialize)]
struct ChapterHolder {
    #[serde(rename = "Chapters")]
    chapters: Option<Vec<RawChapter>>,
}

/// 一个章节点。`image_url` 已经拼好 api_key,前端直接塞 `<img src>`。
#[derive(Serialize, Clone, Debug, PartialEq)]
pub struct Chapter {
    pub index: usize,
    pub start_secs: f64,
    pub name: String,
    pub image_url: Option<String>,
}

/// 取条目章节。失败/无章节都返回空表 —— 这两个功能都是增值项,不该拦住播放。
pub async fn chapters(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    thumb_width: u32,
) -> Vec<Chapter> {
    let url = format!(
        "{}/Users/{}/Items/{}?Fields=Chapters",
        s.server, s.user_id, item_id
    );
    let Ok(resp) = http
        .get(&url)
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .send()
        .await
    else {
        return Vec::new();
    };
    if !resp.status().is_success() {
        return Vec::new();
    }
    let Ok(holder) = resp.json::<ChapterHolder>().await else {
        return Vec::new();
    };
    holder
        .chapters
        .unwrap_or_default()
        .into_iter()
        .enumerate()
        .map(|(i, c)| Chapter {
            index: i,
            start_secs: c.start.unwrap_or(0) as f64 / 1e7,
            name: c.name.unwrap_or_default(),
            image_url: c.image_tag.filter(|t| !t.is_empty()).map(|tag| {
                format!(
                    "{}/Items/{}/Images/Chapter/{}?tag={}&maxWidth={}&api_key={}",
                    s.server, item_id, i, tag, thumb_width, s.token
                )
            }),
        })
        .collect()
}

/// 章节名是不是「片头」。
///
/// 短词(op/ed)必须**整词**匹配,不能用 contains —— 否则 "Opera"、"Stop"、"Wedding"
/// 都会被当成片头,把正片开头切掉。长词才放开 contains。
fn name_hits(name: &str, whole_words: &[&str], substrings: &[&str]) -> bool {
    let lower = name.to_ascii_lowercase();
    let tokens: Vec<&str> = lower
        .split(|c: char| !c.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .collect();
    if whole_words.iter().any(|w| tokens.contains(w)) {
        return true;
    }
    substrings.iter().any(|w| lower.contains(w))
}

fn is_intro_name(name: &str) -> bool {
    name_hits(
        name,
        &["op", "intro", "avant"],
        &["opening", "片头", "オープニング", "主题曲"],
    )
}

fn is_outro_name(name: &str) -> bool {
    name_hits(
        name,
        &["ed", "outro", "credits"],
        &["ending", "片尾", "エンディング", "end credit", "next episode", "预告"],
    )
}

/// 片头区间 `(开始, 结束)`。结束 = 下一个章节的开始(没有下一个就用总时长)。
///
/// 只在**前 40%** 里找:有些剧集把片尾曲也叫 "OP"(插入曲/同名主题曲),
/// 不设这道闸会在快看完时把人一脚踹到片尾。
pub fn intro_range(chapters: &[Chapter], runtime_secs: f64) -> Option<(f64, f64)> {
    let limit = if runtime_secs > 0.0 { runtime_secs * 0.4 } else { f64::MAX };
    let i = chapters
        .iter()
        .position(|c| c.start_secs < limit && is_intro_name(&c.name))?;
    let start = chapters[i].start_secs;
    let end = chapters
        .get(i + 1)
        .map(|c| c.start_secs)
        .unwrap_or(runtime_secs);
    // 结束点必须真的在开始之后,且别长得离谱(>5 分钟的"片头"多半是误判的正片章节)。
    if end <= start + 1.0 || end - start > 300.0 {
        return None;
    }
    Some((start, end))
}

/// 可跳过的片尾区间 `(开始, 落点)`。只在**后 25%** 里找,理由同 intro_range(反向)。
///
/// ★ 只有片尾**后面还有内容**(通常是「下集预告」)时才返回 Some。
///   片尾是最后一个章节 = 跳过去就等于把这一集直接结束掉 —— 用户要的是「跳过片尾」,
///   不是「提前结束」,这两件事差得远。那种情况返回 None,什么都不做。
///
/// 判定放在这里而不是留给前端:前端那份总时长在 500ms 轮询的闭包里会过期,
/// 拿旧值去判「后面还有没有东西」迟早判错(而且错的方式是**误跳**,最难受的那种)。
pub fn outro_range(chapters: &[Chapter], runtime_secs: f64) -> Option<(f64, f64)> {
    if runtime_secs <= 0.0 {
        return None;
    }
    let floor = runtime_secs * 0.75;
    let i = chapters
        .iter()
        .position(|c| c.start_secs >= floor && is_outro_name(&c.name))?;
    let start = chapters[i].start_secs;
    let landing = chapters.get(i + 1)?.start_secs; // 没有下一章 = 后面没内容,不跳
    // 落点太贴近结尾(<5s)也当没内容:跳过去只看到一秒黑屏,不如不跳。
    if landing <= start + 1.0 || landing >= runtime_secs - 5.0 {
        return None;
    }
    Some((start, landing))
}

fn secs_to_ticks(secs: f64) -> i64 {
    (secs.max(0.0) * 1e7) as i64
}

/// 补全 server 前缀与 api_key。
fn abs_url(s: &Session, path: &str) -> String {
    let mut u = if path.starts_with("http") {
        path.to_string()
    } else {
        format!("{}{}", s.server, path)
    };
    if !u.contains("api_key=") {
        u.push(if u.contains('?') { '&' } else { '?' });
        u.push_str(&format!("api_key={}", s.token));
    }
    u
}

/* ---------- 直连地址必须**实测支持 Range** ----------

   ★ 2026-07-27 用户报「跳到缓存条没缓存到的地方,画面和进度条一起卡死,别的播放器都正常」。
     根因:PlaybackInfo 给的 DirectStreamUrl 是**相对路径**(`/videos/16612/original.mkv?…`),
     我们把它拼在服务器根上。Emby 本体在根和 `/emby/` 两个前缀上都提供 API,所以我们
     整套接口一直工作正常 —— 但用户那两台服务器前面挂了反代,**只有 `/emby/` 那条路由
     正确处理 Range**:根路径下的同一个地址收到 `Range:` 也回 `200 OK` + 完整
     Content-Length。实测两台都是如此:

         GET /videos/16612/original.mkv       Range: bytes=1000000-1000099  -> 200 (整个文件)
         GET /emby/videos/16612/original.mkv  Range: bytes=1000000-1000099  -> 206 bytes 1000000-1000099/977548032

     ffmpeg 拿不到 206 就只能从当前位置**顺读丢弃**到目标字节 —— 往前跳 9 分钟就是 370MB。
     mpv 日志里是 `https: Unexpected offset: expected N, got 0` + `Seek failed`。
     别的播放器没事,是因为它们按 Emby 惯例把相对地址拼在 `/emby` API 根上。

   ★ **不写死前缀,而是各发一次 `Range: bytes=0-0` 实测**。写死 `/emby` 会在
     Jellyfin(没有这个前缀)和带 base path 的部署上把好地址改坏;而"哪个前缀能 Range"
     恰恰是我们唯一在乎的性质,直接测它最省事也最准。
     每台服务器每次运行只探一次,结果缓存。 */

/// 探测结果缓存:服务器地址 -> 该用的路径前缀("" 或 "/emby")。
static RANGE_PREFIX: std::sync::OnceLock<std::sync::Mutex<std::collections::HashMap<String, String>>> =
    std::sync::OnceLock::new();

/// 生成 `/emby` 前缀的候选路径。已经带前缀、或本来就是绝对地址 = 没有第二个候选。
fn emby_prefixed(path: &str) -> Option<String> {
    if path.starts_with("http") || path.starts_with("/emby/") || path == "/emby" {
        return None;
    }
    Some(if path.starts_with('/') {
        format!("/emby{path}")
    } else {
        format!("/emby/{path}")
    })
}

/// 两次探测结果 -> 该用哪个前缀。
/// 原地址能 Range 就**别动**(最少惊讶);都不行也保持原样 —— 那时换前缀只是换一种坏法,
/// 而播放器侧的 `seek_stalled` 会把原因说给用户听。
fn choose_prefix(plain_ok: bool, emby_ok: bool) -> &'static str {
    if plain_ok || !emby_ok { "" } else { "/emby" }
}

/// 这个地址收到 `Range:` 会不会老老实实回 206。
async fn supports_range(http: &reqwest::Client, url: &str) -> bool {
    // bytes=0-0 = 只要一个字节,探测代价可以忽略。
    match http.get(url).header("Range", "bytes=0-0").send().await {
        Ok(r) => r.status().as_u16() == 206,
        Err(_) => false,
    }
}

/// 把相对播放路径换成「实测支持 Range」的那一条。失败一律回原样 —— 探测本身
/// **绝不能挡住起播**(网络抖一下就播不了,比跳转慢严重得多)。
async fn seekable_path(http: &reqwest::Client, s: &Session, path: &str) -> String {
    let Some(alt) = emby_prefixed(path) else { return path.to_string() };
    let cache = RANGE_PREFIX.get_or_init(Default::default);
    if let Some(p) = cache.lock().unwrap().get(&s.server).cloned() {
        return if p.is_empty() { path.to_string() } else { format!("{p}{path}") };
    }
    let plain_ok = supports_range(http, &abs_url(s, path)).await;
    // 原地址就没问题的话别白探第二次。
    let emby_ok = !plain_ok && supports_range(http, &abs_url(s, &alt)).await;
    let pre = choose_prefix(plain_ok, emby_ok);
    /* 换没换前缀不用另打日志:宿主起播时打的那行 `PLAY … url=` 里就带着最终地址,
       `/emby/videos/…` 一眼可见。 */
    cache
        .lock()
        .unwrap()
        .insert(s.server.clone(), pre.to_string());
    if pre.is_empty() { path.to_string() } else { alt }
}

/// 正确解析播放地址:POST PlaybackInfo -> 用服务器给的 DirectStreamUrl/TranscodingUrl。
/// 返回 PlaybackTarget(含 PlaySessionId,供上报三件套贯穿使用)。
///
/// `media_source_id`:选哪个版本(草稿页 03/04 的「版本」选择器)。
/// None = 服务器返回的第一个。**指定了却找不到就报错,不静默回落第一个** ——
/// 那会让用户以为在看 4K,实际放的是 1080p,且毫无提示。
/// 一条媒体源的**可匹配文本**(版本筛选正则打的就是它)。
///
/// 口径照 wiki `regex-filters`:名称 + 容器 + 视频分辨率 + 编码 + 显示名。
/// 分辨率既给 `2160`(原始高)也给 `2160p`/`4K` 别名 —— 用户写 `4K|2160` 是最常见的
/// 一条,而 Emby 的 DisplayTitle 未必带 "4K" 字样,不补别名等于这条最常用的正则失灵。
fn source_match_text(m: &RawMediaSource) -> String {
    let mut parts: Vec<String> = vec![
        m.name.clone().unwrap_or_default(),
        m.container.clone().unwrap_or_default(),
    ];
    for st in m.media_streams.as_deref().unwrap_or_default() {
        if st.type_.as_deref() != Some("Video") {
            continue;
        }
        parts.push(st.display_title.clone().unwrap_or_default());
        parts.push(st.codec.clone().unwrap_or_default());
        parts.push(st.profile.clone().unwrap_or_default());
        parts.push(st.video_range.clone().unwrap_or_default());
        parts.push(st.video_range_type.clone().unwrap_or_default());
        if let Some(h) = st.height {
            parts.push(format!("{h} {h}p"));
            // 常见口语档位。只补「不会误伤」的两档:4K 与 8K。
            if h >= 4320 {
                parts.push("8K".into());
            } else if h >= 2160 {
                parts.push("4K".into());
            }
        }
    }
    parts.retain(|p| !p.is_empty());
    parts.join(" ")
}

pub async fn resolve_stream(
    http: &reqwest::Client,
    s: &Session,
    item_id: &str,
    media_source_id: Option<&str>,
    // 版本筛选正则(wiki regex-filters)。仅在 media_source_id 为 None ——
    // 也就是用户**没有手动指定版本**时才参与,手动选的永远优先。
    version_regex: &str,
) -> Result<PlaybackTarget, String> {
    let url = format!(
        "{}/Items/{}/PlaybackInfo?UserId={}",
        s.server, item_id, s.user_id
    );
    // 宽松 DeviceProfile:声明啥都能直连,促使服务器返回 DirectStreamUrl
    let profile = serde_json::json!({
        "DeviceProfile": {
            "MaxStreamingBitrate": 120000000i64,
            "MaxStaticBitrate": 100000000i64,
            "DirectPlayProfiles": [ { "Type": "Video" }, { "Type": "Audio" } ],
            "TranscodingProfiles": [],
            "ContainerProfiles": [],
            "CodecProfiles": [],
            // ★ 原来这里是 `[]`。空表 = 告诉服务器「本客户端一种字幕都不支持」,
            // 服务器于是把 DeliveryMethod 判成 Encode/Drop 且不发 DeliveryUrl,
            // 外挂字幕从源头就被掐死。声明 External 后服务器才会给取字幕地址。
            "SubtitleProfiles": [
                { "Format": "srt",  "Method": "External" },
                { "Format": "subrip","Method": "External" },
                { "Format": "ass",  "Method": "External" },
                { "Format": "ssa",  "Method": "External" },
                { "Format": "vtt",  "Method": "External" },
                { "Format": "webvtt","Method": "External" },
                { "Format": "sub",  "Method": "External" },
                { "Format": "idx",  "Method": "External" },
                { "Format": "smi",  "Method": "External" },
                { "Format": "pgssub","Method": "Embed" },
                { "Format": "dvdsub","Method": "Embed" }
            ]
        }
    });
    let resp = http
        .post(&url)
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .json(&profile)
        .send()
        .await
        .map_err(|e| format!("PlaybackInfo 网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("PlaybackInfo 失败: HTTP {}", resp.status()));
    }
    let info: PlaybackInfoResp = resp
        .json()
        .await
        .map_err(|e| format!("PlaybackInfo 解析失败: {e}"))?;
    // 服务器发的 PlaySessionId 优先;缺则本地兜底生成(但同一次播放内保持一致)。
    let play_session_id = info
        .play_session_id
        .filter(|x| !x.is_empty())
        .unwrap_or_else(|| format!("{}-{}", s.device_id, item_id));
    let ms = match media_source_id {
        Some(want) => info
            .media_sources
            .into_iter()
            .find(|m| m.id.as_deref() == Some(want))
            .ok_or_else(|| format!("该条目没有版本 {want}(服务器可能已改动媒体源)"))?,
        None => {
            // 版本正则命中哪条就用哪条,没命中/没设 → 第一条(服务器顺序,旧行为)。
            let texts: Vec<String> =
                info.media_sources.iter().map(source_match_text).collect();
            let idx = crate::media::pick_index(&texts, version_regex).unwrap_or(0);
            info.media_sources
                .into_iter()
                .nth(idx)
                .ok_or("该条目无可播放源")?
        }
    };
    let media_source_id = ms.id.clone().unwrap_or_default();
    // 取流这一跳顺手把 DV 判了 —— MediaStreams 就在同一份响应里,不用再打一次服务器。
    let is_dolby_vision = ms
        .media_streams
        .as_deref()
        .unwrap_or_default()
        .iter()
        .any(|s| {
            let range_type = s.video_range_type.as_deref().unwrap_or("").to_ascii_lowercase();
            let codec = s.codec.as_deref().unwrap_or("").to_ascii_lowercase();
            let profile = s.profile.as_deref().unwrap_or("").to_ascii_lowercase();
            s.type_.as_deref() == Some("Video")
                && (range_type.contains("dovi")
                    || range_type.contains("dolby")
                    || codec.contains("dvhe")
                    || codec.contains("dvh1")
                    || codec.contains("dav1")
                    || profile.contains("dolby vision"))
        });

    // 外挂字幕:优先用服务器给的 DeliveryUrl,没有就按 index 拼标准路由。
    let external_subs: Vec<ExternalSub> = ms
        .media_streams
        .as_deref()
        .unwrap_or_default()
        .iter()
        .filter(|st| st.type_.as_deref() == Some("Subtitle") && st.is_external == Some(true))
        .filter_map(|st| {
            let index = st.index?;
            let codec = st.codec.as_deref().unwrap_or("srt").to_ascii_lowercase();
            // pgs/dvdsub 是图形字幕,外挂形态少见且 mpv 挂载后多半不可用,跳过。
            if matches!(codec.as_str(), "pgssub" | "pgs" | "dvdsub" | "dvbsub") {
                return None;
            }
            // Emby 的 Stream.{ext} 里 ext 用的是封装名,subrip 要写成 srt。
            let ext = match codec.as_str() {
                "subrip" => "srt",
                "webvtt" => "vtt",
                other => other,
            };
            let url = match st.delivery_url.as_deref().filter(|u| !u.is_empty()) {
                Some(d) => abs_url(s, d),
                None => format!(
                    "{}{}",
                    s.server,
                    subtitle_path(item_id, &media_source_id, index, ext, &s.token)
                ),
            };
            Some(ExternalSub {
                title: st
                    .display_title
                    .clone()
                    .filter(|x| !x.is_empty())
                    .or_else(|| st.language.clone().filter(|x| !x.is_empty()))
                    .unwrap_or_else(|| format!("外挂字幕 {index}")),
                lang: st.language.clone().filter(|x| !x.is_empty()),
                is_default: st.is_default.unwrap_or(false),
                url,
            })
        })
        .collect();

    let (url, play_method) = if let Some(d) = ms.direct_stream_url.filter(|x| !x.is_empty()) {
        (abs_url(s, &seekable_path(http, s, &d).await), "DirectStream")
    } else if let Some(t) = ms.transcoding_url.filter(|x| !x.is_empty()) {
        (abs_url(s, &t), "Transcode")
    } else {
        // 兜底:用真实 mediaSourceId + container 直拼
        let container = ms.container.unwrap_or_default();
        let ext = if container.is_empty() {
            String::new()
        } else {
            format!(".{container}")
        };
        (
            format!(
                "{}/Videos/{}/stream{}?static=true&mediaSourceId={}&api_key={}",
                s.server, item_id, ext, media_source_id, s.token
            ),
            "DirectStream",
        )
    };

    Ok(PlaybackTarget {
        url,
        item_id: item_id.to_string(),
        media_source_id,
        play_session_id,
        play_method: play_method.to_string(),
        is_dolby_vision,
        external_subs,
    })
}

// ---------- 播放上报三件套(start / progress / stopped,同 PlaySessionId)----------

async fn post_report(
    http: &reqwest::Client,
    s: &Session,
    endpoint: &str,
    body: serde_json::Value,
) -> Result<(), String> {
    let url = format!("{}/Sessions/Playing{}", s.server, endpoint);
    let resp = http
        .post(&url)
        .header("X-Emby-Token", &s.token)
        .header("X-Emby-Authorization", auth_header(&s.device_id))
        .json(&body)
        .send()
        .await
        .map_err(|e| format!("上报网络错误: {e}"))?;
    if !resp.status().is_success() {
        return Err(format!("上报失败: HTTP {}", resp.status()));
    }
    Ok(())
}

pub async fn report_start(
    http: &reqwest::Client,
    s: &Session,
    t: &PlaybackTarget,
    position_secs: f64,
) -> Result<(), String> {
    let body = serde_json::json!({
        "ItemId": t.item_id,
        "MediaSourceId": t.media_source_id,
        "PlaySessionId": t.play_session_id,
        "PlayMethod": t.play_method,
        "PositionTicks": secs_to_ticks(position_secs),
        "CanSeek": true,
        "IsPaused": false,
    });
    post_report(http, s, "", body).await
}

pub async fn report_progress(
    http: &reqwest::Client,
    s: &Session,
    t: &PlaybackTarget,
    position_secs: f64,
    paused: bool,
) -> Result<(), String> {
    let body = serde_json::json!({
        "ItemId": t.item_id,
        "MediaSourceId": t.media_source_id,
        "PlaySessionId": t.play_session_id,
        "PlayMethod": t.play_method,
        "PositionTicks": secs_to_ticks(position_secs),
        "IsPaused": paused,
        "EventName": "timeupdate",
    });
    post_report(http, s, "/Progress", body).await
}

pub async fn report_stopped(
    http: &reqwest::Client,
    s: &Session,
    t: &PlaybackTarget,
    position_secs: f64,
) -> Result<(), String> {
    let body = serde_json::json!({
        "ItemId": t.item_id,
        "MediaSourceId": t.media_source_id,
        "PlaySessionId": t.play_session_id,
        "PositionTicks": secs_to_ticks(position_secs),
    });
    post_report(http, s, "/Stopped", body).await
}

// image_url() 已删:前端(src/lib/api.ts)自己按 server+token 拼图片地址,
// 且这里写死 Primary?maxHeight=360 无法表达 Thumb/Backdrop/Logo 与尺寸 —— 无人调用的死代码,
// 与其扩参数不如删掉。真要回到 Rust 侧再按 image_type/tag/max_width/max_height 重建。

#[cfg(test)]
mod tests {
    use super::*;

    fn ch(start: f64, name: &str) -> Chapter {
        Chapter { index: 0, start_secs: start, name: name.into(), image_url: None }
    }

    /* 「跳到没缓冲的地方就卡死,别的播放器都正常」。
       PlaybackInfo 给的 DirectStreamUrl 是相对路径,我们拼在服务器根上;而用户那两台
       服务器的反代**只在 `/emby/` 路由上处理 Range**,根路径下收到 Range 也回 200 +
       整个文件。ffmpeg 于是只能顺读丢弃到目标字节(跳 9 分钟 = 370MB)。

       反向验证(见 [[test-must-fail-first]]):
       - 把 emby_prefixed 里 `path.starts_with("/emby/")` 那条守卫删掉 -> 第 3 条断言红
         (会拼出 `/emby/emby/videos/…`);
       - 把 choose_prefix 改成无条件 `"/emby"` -> 第 1 条红(原地址明明是好的,不该动它);
         改成无条件 `""` -> 第 2 条红(该换的时候没换)。 */
    #[test]
    fn range_probe_only_switches_prefix_when_it_actually_helps() {
        // 原地址就支持 Range(绝大多数 Emby)-> 一个字都别动。
        assert_eq!(choose_prefix(true, true), "");
        assert_eq!(choose_prefix(true, false), "");
        // 原地址不认 Range 而 /emby 认 -> 换。这就是用户那两台。
        assert_eq!(choose_prefix(false, true), "/emby");
        // 两条都不认 -> 保持原样。换前缀只是换一种坏法,播放器侧的 seek_stalled 会说明原因。
        assert_eq!(choose_prefix(false, false), "");

        assert_eq!(emby_prefixed("/videos/1/original.mkv?a=b").as_deref(), Some("/emby/videos/1/original.mkv?a=b"));
        assert_eq!(emby_prefixed("videos/1/x.mkv").as_deref(), Some("/emby/videos/1/x.mkv"));
        // 服务端已经给了带前缀的相对地址,或干脆是绝对地址 -> 没有第二个候选,别叠加。
        assert_eq!(emby_prefixed("/emby/videos/1/x.mkv"), None);
        assert_eq!(emby_prefixed("https://h/videos/1/x.mkv"), None);
    }

    /// 非管理员必须判 false。判错了 = 把三个管理动作发给没权限的账号,一点就 403。
    /// 老 Emby / 精简响应可能整个没有 Policy —— 缺字段也必须是 false,不能默认放行。
    #[test]
    fn admin_flag_defaults_to_no_when_unknown() {
        let admin = serde_json::json!({ "Id": "u", "Policy": { "IsAdministrator": true } });
        let user = serde_json::json!({ "Id": "u", "Policy": { "IsAdministrator": false } });
        let no_policy = serde_json::json!({ "Id": "u" });
        let empty_policy = serde_json::json!({ "Id": "u", "Policy": {} });

        assert!(admin_flag(&admin));
        assert!(!admin_flag(&user));
        assert!(!admin_flag(&no_policy), "缺 Policy 不能当管理员");
        assert!(!admin_flag(&empty_policy), "缺 IsAdministrator 不能当管理员");
    }

    /// 「刷新媒体库」和「刷新元数据」打的是同一个端点、不同的模式 ——
    /// 参数写反的话前者会**覆盖用户改过的元数据**,而界面上只写着「刷新」。
    #[test]
    fn refresh_modes_do_not_swap() {
        let light = refresh_url("http://h", "lib1", false);
        let full = refresh_url("http://h", "lib1", true);

        assert!(light.contains("MetadataRefreshMode=Default"), "{light}");
        assert!(light.contains("ReplaceAllMetadata=false"), "轻刷新不能替换已有元数据: {light}");
        assert!(full.contains("MetadataRefreshMode=FullRefresh"), "{full}");
        assert!(full.contains("ReplaceAllMetadata=true"), "{full}");
        // 不递归 = 对库卡片什么都不做(库本身没有元数据可刮)
        assert!(light.contains("Recursive=true") && full.contains("Recursive=true"));
        // 用户手动换过的封面不该被「刷新元数据」抹掉
        assert!(full.contains("ReplaceAllImages=false"), "{full}");
    }

    /// PlaybackInfo 里的 MediaStreams 曾被 resolve_stream 的**第二份** MediaSource 模型
    /// 整个丢掉,于是「杜比视界自动软解」永远判不出 DV。两份模型合一后必须真解析出来。
    #[test]
    fn playback_info_keeps_media_streams_for_dolby_check() {
        let raw = r#"{
            "MediaSources": [{
                "Id": "ms1",
                "DirectStreamUrl": "/videos/1/stream.mkv",
                "MediaStreams": [
                    { "Type": "Video", "Codec": "hevc", "VideoRange": "HDR", "VideoRangeType": "DOVI" },
                    { "Type": "Audio", "Codec": "eac3" }
                ]
            }],
            "PlaySessionId": "psid"
        }"#;
        let info: PlaybackInfoResp = serde_json::from_str(raw).unwrap();
        let ms = &info.media_sources[0];
        let streams = ms.media_streams.as_deref().unwrap();
        assert_eq!(streams.len(), 2, "MediaStreams 被丢了 —— DV 判定拿不到数据");
        assert_eq!(streams[0].video_range_type.as_deref(), Some("DOVI"));
        // DirectStreamUrl 也必须还在(合并模型时最容易漏掉的那个字段)
        assert_eq!(ms.direct_stream_url.as_deref(), Some("/videos/1/stream.mkv"));
    }

    /// 版本筛选正则(wiki regex-filters)打的是 source_match_text 拼出来的那段文本。
    /// 这条钉住 wiki 承诺的四类写法都能命中,尤其是 `4K` —— Emby 只给 Height=2160,
    /// 不补 4K 别名的话「优先 4K 片源」这条最常用的正则永远不命中,而且一声不吭。
    #[test]
    fn version_regex_matches_wiki_examples() {
        let raw = r#"{
            "MediaSources": [
                { "Id": "a", "Name": "1080p x264", "Container": "mp4",
                  "MediaStreams": [{ "Type": "Video", "Codec": "h264", "Height": 1080,
                                     "DisplayTitle": "1080p H264 SDR" }] },
                { "Id": "b", "Name": "原盘 Remux", "Container": "mkv",
                  "MediaStreams": [{ "Type": "Video", "Codec": "hevc", "Height": 2160,
                                     "VideoRangeType": "DOVI", "DisplayTitle": "2160p HEVC" }] }
            ],
            "PlaySessionId": "p"
        }"#;
        let info: PlaybackInfoResp = serde_json::from_str(raw).unwrap();
        let texts: Vec<String> = info.media_sources.iter().map(source_match_text).collect();
        for pat in ["4K|2160", "HEVC|265|x265", "原盘|remux|bluray", "DOVI|杜比视界"] {
            assert_eq!(
                crate::media::pick_index(&texts, pat),
                Some(1),
                "wiki 示例 `{pat}` 应命中第二条媒体源;实际文本 = {texts:?}"
            );
        }
        assert_eq!(crate::media::pick_index(&texts, "1080"), Some(0));
        // ★ 单独钉「4K」这个别名:上面那条 `4K|2160` 里 2160 分支自己就能命中,
        //   删掉别名它照样绿 —— 测不住的断言等于没有。这条只写 4K,别名没了就红。
        assert_eq!(
            crate::media::pick_index(&texts, "4K"),
            Some(1),
            "Emby 只给 Height=2160,不补 4K 别名的话「优先 4K 片源」永远不命中"
        );
        // 没命中 / 没设 → 调用方回落第一条(旧行为不变)
        assert_eq!(crate::media::pick_index(&texts, "8K"), None);
        assert_eq!(crate::media::pick_index(&texts, ""), None);
    }

    /// ★ `preferred` 必须和 `resolve_stream` 挑的是**同一条**。
    /// 这两条路以前各走各的:起播按正则挑了第二条,而详情页/播放器面板照样高亮第一条 ——
    /// 用户看到的界面全在说「在放第一条」,于是判定「正则根本没生效」
    /// (2026-07-30 用户实测报的就是这个,而那时起播其实已经是对的)。
    #[test]
    fn preferred_marks_the_same_source_resolve_stream_would_pick() {
        let raw = r#"{
            "MediaSources": [
                { "Id": "a", "Name": ".1080P.BDRip@北宇治字幕组.简体内嵌", "Container": "mp4",
                  "MediaStreams": [{ "Type": "Video", "Codec": "h264", "Height": 1080 }] },
                { "Id": "b", "Name": ".1080P.BDRip@喵萌奶茶屋.简日双语", "Container": "mp4",
                  "MediaStreams": [{ "Type": "Video", "Codec": "h264", "Height": 1080 }] }
            ],
            "PlaySessionId": "p"
        }"#;
        let info: PlaybackInfoResp = serde_json::from_str(raw).unwrap();
        let texts: Vec<String> = info.media_sources.iter().map(source_match_text).collect();
        // 起播这条路(resolve_stream 里就是这一句)
        let picked = crate::media::pick_index(&texts, "喵萌").unwrap_or(0);
        assert_eq!(picked, 1);
        // 显示这条路(media_versions 里就是这一句)—— 必须得出同一个下标
        let shown = crate::media::pick_index(&texts, "喵萌");
        assert_eq!(shown, Some(picked), "「显示哪条」和「播哪条」必须是同一条");
        // 没设正则 → 谁都不标,前端回落第一条(= resolve_stream 的 unwrap_or(0))
        assert_eq!(crate::media::pick_index(&texts, ""), None);
    }

    /// 外挂字幕兜底路径必须和 Emby 自己发的 DeliveryUrl 字节一致。
    ///
    /// 期望值不是我编的,是 2026-07-21 在 mecf.mebimmer.de(接近原版的 Emby)实测抓到的:
    /// 带 `SubtitleProfiles:[{Format:"ass",Method:"External"}]` 的 PlaybackInfo 返回
    /// `DeliveryUrl=/Videos/50257/mediasource_50257/Subtitles/37/0/Stream.ass?api_key=...`;
    /// 而 `SubtitleProfiles:[]`(改之前的写法)返回 `DeliveryMethod=Encode, DeliveryUrl=null`
    /// —— 那就是「外挂字幕不加载」的源头:根本没有地址可挂。
    /// 少那个 `/0`(StartPositionTicks 段)或把 codec 直接当扩展名,都会 404。
    #[test]
    fn subtitle_fallback_path_matches_real_server() {
        assert_eq!(
            subtitle_path("50257", "mediasource_50257", 37, "ass", "TOKEN"),
            "/Videos/50257/mediasource_50257/Subtitles/37/0/Stream.ass?api_key=TOKEN"
        );
    }

    /// IsExternal / DeliveryUrl 必须真的被解析出来 —— 原来 RawStream 压根没这两个字段,
    /// 于是内封和外挂分不开,外挂字幕永远是「看得见名字、挂不上内容」。
    #[test]
    fn external_subtitle_fields_are_parsed() {
        let raw = serde_json::json!({
            "Id": "ms1",
            "MediaStreams": [
                { "Type": "Subtitle", "Index": 37, "Codec": "ass", "IsExternal": true,
                  "DeliveryUrl": "/Videos/1/ms1/Subtitles/37/0/Stream.ass", "Language": "chi" },
                { "Type": "Subtitle", "Index": 2, "Codec": "ass", "IsExternal": false },
                { "Type": "Video", "Index": 0, "Codec": "hevc" }
            ]
        });
        let ms: RawMediaSource = serde_json::from_value(raw).unwrap();
        let v: MediaVersion = ms.into();
        let subs: Vec<_> = v.streams.iter().filter(|s| s.type_ == "Subtitle").collect();
        assert_eq!(subs.len(), 2);
        let ext = subs.iter().find(|s| s.is_external).expect("外挂字幕没被识别出来");
        assert_eq!(ext.index, 37);
        assert_eq!(ext.delivery_url.as_deref(), Some("/Videos/1/ms1/Subtitles/37/0/Stream.ass"));
        let emb = subs.iter().find(|s| !s.is_external).unwrap();
        assert!(emb.delivery_url.is_none(), "内封字幕不该有取字幕地址");
    }

    /// HDR10 ≠ 杜比视界。只看 VideoRange=HDR 就判 DV,会把所有 HDR 片子无谓拖进软解。
    #[test]
    fn hdr10_is_not_mistaken_for_dolby_vision() {
        let dv = StreamInfo {
            index: 0, type_: "Video".into(), codec: "hevc".into(), profile: None,
            display_title: None, language: None, width: None, height: None, bitrate: None,
            channels: None, channel_layout: None, frame_rate: None,
            video_range: Some("HDR".into()), video_range_type: Some("DOVI".into()), is_default: true,
            is_external: false, delivery_url: None,
        };
        let hdr10 = StreamInfo { video_range_type: Some("HDR10".into()), ..dv.clone() };
        let dv_by_codec = StreamInfo { codec: "dvhe.08".into(), video_range_type: None, ..dv.clone() };
        let dv_by_profile = StreamInfo {
            codec: "hevc".into(), video_range_type: None,
            profile: Some("Main 10 / Dolby Vision".into()), ..dv.clone()
        };
        let audio = StreamInfo { type_: "Audio".into(), ..dv.clone() };

        assert!(is_dolby_vision(&dv));
        assert!(!is_dolby_vision(&hdr10), "HDR10 被误判成 DV");
        assert!(is_dolby_vision(&dv_by_codec), "老服务器不发 VideoRangeType,得靠 codec 兜底");
        assert!(is_dolby_vision(&dv_by_profile));
        assert!(!is_dolby_vision(&audio), "音频轨不该参与 DV 判定");
    }

    /// 片头识别靠章节名。短词用 contains 会把正片切掉 —— 这是本功能最贵的一类误伤。
    #[test]
    fn intro_detection_does_not_eat_the_feature() {
        let normal = vec![ch(0.0, "Opening"), ch(90.0, "Part A"), ch(1200.0, "Ending")];
        assert_eq!(intro_range(&normal, 1440.0), Some((0.0, 90.0)));
        // 片尾是最后一个章节 → 跳过去 = 直接结束这一集,不是用户要的「跳过片尾」
        assert_eq!(outro_range(&normal, 1440.0), None);

        // 片尾后面还有下集预告 → 可以跳,落点是预告的开始
        let with_preview = vec![ch(0.0, "OP"), ch(90.0, "Part A"), ch(1200.0, "ED"), ch(1380.0, "次回予告")];
        assert_eq!(outro_range(&with_preview, 1440.0), Some((1200.0, 1380.0)));

        // "Opera" / "Stop Motion" 含 op,但都不是片头
        let trap = vec![ch(0.0, "The Phantom of the Opera"), ch(120.0, "Stop Motion Scene")];
        assert_eq!(intro_range(&trap, 1440.0), None, "contains 匹配把正片当成了片头");

        // 中文命名
        let cn = vec![ch(12.0, "片头曲"), ch(102.0, "正片"), ch(1300.0, "片尾")];
        assert_eq!(intro_range(&cn, 1440.0), Some((12.0, 102.0)));
        assert_eq!(outro_range(&cn, 1440.0), None); // 片尾后面没东西了
    }

    /// 边界闸门:后半段的 "OP"(同名插入曲)不能当片头,否则快看完时被踹到片尾;
    /// 超长"片头"多半是误命名的正片章节,宁可不跳。
    #[test]
    fn intro_range_rejects_late_and_overlong_matches() {
        let late = vec![ch(100.0, "Part A"), ch(1200.0, "OP")]; // 1200/1440 = 83%,太靠后
        assert_eq!(intro_range(&late, 1440.0), None);

        let overlong = vec![ch(0.0, "Intro"), ch(600.0, "Part A")]; // 10 分钟的"片头"
        assert_eq!(intro_range(&overlong, 1440.0), None);

        let zero_len = vec![ch(0.0, "Intro"), ch(0.5, "Part A")];
        assert_eq!(intro_range(&zero_len, 1440.0), None);

        assert_eq!(intro_range(&[], 1440.0), None, "没有章节时必须静默不工作,不能崩");
        assert_eq!(outro_range(&[], 1440.0), None);
        assert_eq!(outro_range(&[ch(10.0, "Ending")], 0.0), None, "时长未知时不猜");
        // 前 75% 里的 "Ending"(剧情章节名)不是片尾
        assert_eq!(outro_range(&[ch(100.0, "The Ending Begins")], 1440.0), None);
    }

    /// 章节图 URL 必须带 api_key,否则前端 <img> 直接 401 —— 缩略图会静默全白。
    /// 服务端没生成图(无 ImageTag)时必须是 None,不能拼出一个必然 404 的地址。
    #[test]
    fn chapter_image_url_is_authenticated_and_optional() {
        let raw = r#"{ "Chapters": [
            { "StartPositionTicks": 0, "Name": "Opening", "ImageTag": "abc" },
            { "StartPositionTicks": 900000000, "Name": "Part A" }
        ] }"#;
        let holder: ChapterHolder = serde_json::from_str(raw).unwrap();
        let list = holder.chapters.unwrap();
        assert_eq!(list.len(), 2);
        assert_eq!(list[0].image_tag.as_deref(), Some("abc"));
        assert_eq!(list[1].image_tag, None);
        // 90 秒 = 900000000 ticks
        assert_eq!(list[1].start.unwrap() as f64 / 1e7, 90.0);
    }

    /// 真实载荷回归:smart.uhdnow.com 的 /Items/Resume 原样返回(2026-07-15 实抓)。
    /// Episode.Name 只有「第 35 集」,剧名单独在 SeriesName —— 丢了它列表就没法认剧。
    #[test]
    fn episode_carries_series_name() {
        let raw = r#"{
            "Name": "第 35 集",
            "SeriesName": "问心",
            "Id": "e01KWPH9HCE3AFHNG6PN0HP25JS",
            "Type": "Episode",
            "RunTimeTicks": 27390000000,
            "ImageTags": { "Primary": "x" },
            "UserData": { "PlaybackPositionTicks": 0 }
        }"#;
        let it: Item = serde_json::from_str::<RawItem>(raw).unwrap().into();
        assert_eq!(it.series_name.as_deref(), Some("问心"));
        assert_eq!(it.name, "第 35 集");
        assert!(it.has_primary);
        assert_eq!(it.runtime_secs, 2739.0);
    }

    /// 电影没有 SeriesName,不该冒出空串(前端靠 null 判断要不要拼前缀)。
    #[test]
    fn movie_has_no_series_name() {
        let raw = r#"{ "Name": "沙丘", "Id": "m1", "Type": "Movie" }"#;
        let it: Item = serde_json::from_str::<RawItem>(raw).unwrap().into();
        assert_eq!(it.series_name, None);
    }

    /// 真实载荷回归:smart.uhdnow.com 的 /Users/{u}/Items 分页响应(2026-07-15 实抓)。
    /// TotalRecordCount=3276 但本页只有 200 条 —— 总数必须独立于 items.len() 解析出来,
    /// 否则前端按 200 算页数,3000 多条内容静默消失。
    #[test]
    fn page_total_is_independent_of_page_len() {
        let raw = r#"{
            "Items": [
                { "Id": "m1", "Name": "12金鸭", "Type": "Movie" },
                { "Id": "m2", "Name": "2046", "Type": "Movie" }
            ],
            "TotalRecordCount": 3276
        }"#;
        let data: ItemsResponse = serde_json::from_str(raw).unwrap();
        assert_eq!(data.total_record_count, Some(3276));
        assert_eq!(data.items.len(), 2);
    }

    /// Emby 单次最多 200 条:传再大也要夹到 200,免得前端以为拿全了。
    #[test]
    fn limit_is_clamped_to_server_cap() {
        assert_eq!(Some(5000u32).unwrap_or(SERVER_PAGE_CAP).min(SERVER_PAGE_CAP), 200);
        // 不传 limit 时用 200,而不是"省略 Limit"(实测省略只返 20 条)。
        assert_eq!(None::<u32>.unwrap_or(SERVER_PAGE_CAP).min(SERVER_PAGE_CAP), 200);
    }

    /// UserData.Played 要进漏斗:set_played 之后列表得能反显。
    /// 载荷取自实测 POST /Users/{u}/PlayedItems/{id} 的返回。
    #[test]
    fn played_flag_flows_through_funnel() {
        let raw = r#"{
            "Id": "m01KRGA5RC8R7C5RR1S06THXXQT", "Name": "龙门客栈", "Type": "Movie",
            "UserData": { "PlaybackPositionTicks": 120000000, "Played": true }
        }"#;
        let it: Item = serde_json::from_str::<RawItem>(raw).unwrap().into();
        assert!(it.played);
        assert_eq!(it.resume_secs, 12.0); // 已看不该把进度吃掉
    }

    /// 没有 UserData 的条目(如 BoxSet)不该 panic,played=false。
    #[test]
    fn missing_user_data_defaults_to_unplayed() {
        let raw = r#"{ "Id": "b1", "Name": "合集", "Type": "BoxSet" }"#;
        let it: Item = serde_json::from_str::<RawItem>(raw).unwrap().into();
        assert!(!it.played);
        assert_eq!(it.resume_secs, 0.0);
        assert_eq!(it.unplayed_item_count, 0); // 无 UserData → 未看数兜底 0
    }

    /// UnplayedItemCount 要进漏斗:剧集卡「未看集数」蓝角标全靠它。
    /// Emby 默认就在 UserData 里带,不请求任何 Fields —— 载荷取自实测剧集列表返回。
    #[test]
    fn unplayed_count_flows_through_funnel() {
        let raw = r#"{
            "Id": "s01", "Name": "怪奇物语", "Type": "Series", "IsFolder": true,
            "UserData": { "Played": false, "UnplayedItemCount": 3 }
        }"#;
        let it: Item = serde_json::from_str::<RawItem>(raw).unwrap().into();
        assert_eq!(it.unplayed_item_count, 3);
        assert!(!it.played);
    }

    /// 客户端兜底复筛:实测 UHD 服务端忽略 Genres/Years/评分过滤,
    /// 复筛必须真的能把不匹配的条目挡掉 —— 否则筛选面板就是个摆设。
    /// 载荷字段取自实测 Fields=Genres,ProductionYear,CommunityRating 的返回形状。
    #[test]
    fn local_filter_rejects_non_matching_items() {
        let mk = |raw: &str| -> Item { serde_json::from_str::<RawItem>(raw).unwrap().into() };
        // 实测「Genres=喜剧」时服务端原样吐回来的那类条目:根本没有喜剧。
        let action = mk(r#"{"Id":"1","Name":"龙门飞甲","Type":"Movie",
            "Genres":["冒险","剧情","动作"],"ProductionYear":2011,"CommunityRating":6.2}"#);
        let comedy = mk(r#"{"Id":"2","Name":"龙马精神","Type":"Movie",
            "Genres":["剧情","动作","喜剧"],"ProductionYear":2023,"CommunityRating":8.5}"#);

        let by_genre = ItemQuery { genres: Some(vec!["喜剧".into()]), ..Default::default() };
        assert!(by_genre.needs_local_filter());
        assert!(!by_genre.matches(&action), "非喜剧必须被挡掉");
        assert!(by_genre.matches(&comedy));

        let by_year = ItemQuery { years: Some(vec![2023]), ..Default::default() };
        assert!(!by_year.matches(&action));
        assert!(by_year.matches(&comedy));

        // 评分上界 Emby 没有参数,只能靠复筛。
        let by_rating = ItemQuery { rating_min: Some(7.0), rating_max: Some(9.0), ..Default::default() };
        assert!(!by_rating.matches(&action));
        assert!(by_rating.matches(&comedy));

        // 无评分条目视为不在区间(与旧 Dart 行为一致)。
        let unrated = mk(r#"{"Id":"3","Name":"万米危机","Type":"Movie","CommunityRating":null}"#);
        assert!(!by_rating.matches(&unrated));

        // 不传任何筛选条件 → 不复筛,全部放行(避免把正常浏览误伤成空列表)。
        let none = ItemQuery::default();
        assert!(!none.needs_local_filter());
        assert!(none.matches(&action) && none.matches(&unrated));
    }

    /// 空 vec 不算筛选条件 —— 否则前端传 genres:[] 会把整页清空。
    #[test]
    fn empty_filter_vecs_are_not_filters() {
        let q = ItemQuery { genres: Some(vec![]), years: Some(vec![]), ..Default::default() };
        assert!(!q.needs_local_filter());
        let it: Item = serde_json::from_str::<RawItem>(r#"{"Id":"1","Type":"Movie"}"#).unwrap().into();
        assert!(q.matches(&it));
    }

    /// /System/Info/Public 实抓形状(登录前探测,无 token)。
    #[test]
    fn parses_public_server_info() {
        let raw = r#"{"SystemUpdateLevel":"Release","OperatingSystem":"Linux",
            "ServerName":"UHD","Version":"4.9.3.0","Id":"UHD"}"#;
        let j: serde_json::Value = serde_json::from_str(raw).unwrap();
        let si = ServerInfo {
            name: j["ServerName"].as_str().unwrap_or_default().to_string(),
            version: j["Version"].as_str().unwrap_or_default().to_string(),
            id: j["Id"].as_str().unwrap_or_default().to_string(),
        };
        assert_eq!((si.name.as_str(), si.version.as_str(), si.id.as_str()), ("UHD", "4.9.3.0", "UHD"));
    }

    /// /Genres 实抓:Id 是**数字**不是 GUID 字符串,只取 Name 才不会踩类型坑。
    #[test]
    fn parses_genre_facet_with_numeric_ids() {
        let raw = r#"{"Items":[{"Id":12,"Name":"冒险","Type":"Genre"},
            {"Id":35,"Name":"喜剧","Type":"Genre"},{"Id":99,"Name":"","Type":"Genre"}],
            "TotalRecordCount":3}"#;
        let j: serde_json::Value = serde_json::from_str(raw).unwrap();
        let names: Vec<String> = j["Items"].as_array().unwrap().iter()
            .filter_map(|i| i["Name"].as_str()).filter(|n| !n.is_empty())
            .map(String::from).collect();
        assert_eq!(names, vec!["冒险", "喜剧"]); // 空名被剔除
    }

    /// ★ 搜索关键词参数名必须是大写 SearchTerm。
    /// 实测:searchTerm(小写)被服务端静默忽略 → 返回全库 25596 条冒充搜索结果;
    /// SearchTerm → 6 条正确结果。这个测试就是防止有人手滑改回小写。
    #[test]
    fn search_term_must_be_capitalized() {
        let s = Session {
            server: "https://x".into(),
            token: "t".into(),
            user_id: "u".into(),
            device_id: "d".into(),
        };
        let url = search_url(&s, "凡人", None, None);
        assert!(url.contains("SearchTerm="), "关键词参数必须大写 SearchTerm: {url}");
        assert!(!url.contains("searchTerm="), "小写 searchTerm 会被服务端忽略并返回全库");
        // 默认类型集要含 Episode(旧实现写死 Movie,Series 搜不到分集)。
        assert!(url.contains("IncludeItemTypes=Movie,Series,Episode"));
        assert!(url.contains("Limit=50"));
        // 显式传类型/条数时照传,且条数夹到服务端上限。
        let url2 = search_url(&s, "x", Some(&["Movie".to_string()]), Some(9999));
        assert!(url2.contains("IncludeItemTypes=Movie&"));
        assert!(url2.contains("Limit=200"));
    }

    /// 年份区间探针:最早 1922 最晚 2026(实测华语电影库),铺成倒序区间。
    #[test]
    fn year_range_is_descending_and_inclusive() {
        let years: Vec<i32> = (1922i32..=2026).rev().collect();
        assert_eq!(years.first(), Some(&2026));
        assert_eq!(years.last(), Some(&1922));
        assert_eq!(years.len(), 105);
    }
}
