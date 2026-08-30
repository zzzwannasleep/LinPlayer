// 批量解析「分享文本」+ `linplayer://` 深链 → 结构化账号块。
//
// 移植自 Dart 三件套:
//   lib/core/utils/server_batch_parser.dart   自由文本 → ParsedServerBlock
//   lib/core/utils/server_batch_adder.dart    ParsedServerBlock → ServerLine/DanmakuServer
//   lib/core/services/deep_link_service.dart  linplayer://add-server 解析
//
// 本文件是**平台无关纯逻辑**:不碰 AppConfig 存盘、不发网络请求、不弹确认框。
// 登录(逐线路试)/落盘/用户确认/Windows 协议注册全归宿主(src-tauri)编排。
//
// 机场/Emby 分享出来的开通信息通常长这样(可能一次包含多个账号块)。
//
// ⚠️ 下面这段样例与测试夹具里的值**全部是编造的占位符**,不是真实账号。
//    仓库红线:任何真实域名/账号/密码都不许进版本控制 —— 包括"只是个测试夹具"。
//    改这段时保持**结构**不变即可(CJK 用户名 / 两个不同的密码字段 / 括号备注 /
//    带端口的 URL / 带路径的弹幕 URL),值随便编。
//
//     ▎创建用户成功🎉
//     · 用户名称 | 示例用户
//     · 用户密码 | Ab3xKp9Q
//     · 安全密码 | 1234(仅发送一次)
//     · 到期时间 | 2026-06-30 23:34:28
//     主线路(可尝试直连)
//     https://line1.example.com:443
//     海外备用(国际优化 CDN)
//     https://cdn.example.net:443
//     弹幕 API
//     https://danmu.example.org/api-danmu

use crate::config::{DanmakuServer, ServerLine};
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::OnceLock;

/// 一条带名字的线路(服务器线路或弹幕线路通用)。
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct ParsedLine {
    pub name: String,
    pub url: String,
}

/// 一个账号块:一台服务器(可能多线路) + 该账号的弹幕线路 + 用户名/密码。
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct ParsedServerBlock {
    #[serde(default)]
    pub username: Option<String>,
    #[serde(default)]
    pub password: Option<String>,
    #[serde(default)]
    pub lines: Vec<ParsedLine>,
    #[serde(default)]
    pub danmaku_lines: Vec<ParsedLine>,
}

impl ParsedServerBlock {
    pub fn is_empty(&self) -> bool {
        self.lines.is_empty() && self.danmaku_lines.is_empty()
    }
}

/// 深链 `linplayer://add-server?...` 的解析结果。
///
/// 比裸 [`ParsedServerBlock`] 多一个 `name`:那是链接里的 `?name=`(服务器显示名),
/// 登录后取不到 Emby SystemInfo.serverName 时的回退名。丢了它 = 静默降级成用户名,
/// 所以单独带出来给宿主。
#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
pub struct DeepLinkAddServer {
    #[serde(default)]
    pub name: Option<String>,
    #[serde(default)]
    pub block: ParsedServerBlock,
}

// ---------- 正则(对齐 Dart 的 static final RegExp) ----------

/// 行内「标签 <分隔符> URL」。分隔符:`|` `:` `：`。
fn re_kv_same_line_url() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(?i)^(.{1,40}?)\s*[\|:：]\s*((?:https?://)\S+)").unwrap())
}

/// 行内「键 <分隔符> 值」(值不含 URL)。
fn re_kv_field() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^([^\|:：]{1,16})\s*[\|:：]\s*(.+)$").unwrap())
}

fn re_url() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"(?i)https?://[^\s|，,\)）；;]+").unwrap())
}

fn re_leading_bullets() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"^[\s·•\-\*▎▍►>《　]+").unwrap())
}

/// 行首形如 "创建用户成功" 的块头。
fn re_block_header() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"创建用户|【\s*服务器\s*】|账号信息|开通成功").unwrap())
}

fn re_paren_note() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[（(].*$").unwrap())
}

fn re_trailing_punct() -> &'static Regex {
    static R: OnceLock<Regex> = OnceLock::new();
    R.get_or_init(|| Regex::new(r"[，,。；;、\)）】\]]+$").unwrap())
}

const USER_KEYS: &[&str] = &[
    "用户名称", "用户名", "账户名", "账号名", "账户", "账号", "帐号", "用户",
    "username", "user", "account", "name",
];
const PASS_KEYS: &[&str] = &[
    "用户密码", "登录密码", "登陆密码", "密码", "password", "passwd", "pwd", "pass",
];
/// 这些键即便带「密码/时间」字样也不是登录凭据,忽略。
const IGNORE_KEYS: &[&str] = &[
    "安全密码", "安全密碼", "到期时间", "到期時間", "过期时间", "有效期", "expire",
    "expiry", "到期", "剩余", "当前线路", "当前線路",
];

// ---------- 文本解析 ----------

/// 解析整段分享文本为多个账号块。
pub fn parse_share_text(text: &str) -> Vec<ParsedServerBlock> {
    let mut blocks: Vec<ParsedServerBlock> = Vec::new();
    let mut current = ParsedServerBlock::default();
    let mut pending_label: Option<String> = None;

    // 按 '\n' 切:CRLF 文本残留的 '\r' 由下面的 trim 吃掉(与 Dart 同)。
    for raw in text.split('\n') {
        let line = re_leading_bullets().replace(raw, "").trim().to_string();
        if line.is_empty() {
            continue;
        }

        // 显式块头:开启新块。
        // 注意:current 为空时**不 continue**,该行会掉到 ④ 变成 pending_label(Dart 原样如此)。
        if re_block_header().is_match(&line) && !current.is_empty() {
            flush(&mut blocks, &mut current, &mut pending_label);
            continue;
        }

        // ① 同一行「标签: URL」
        if let Some(c) = re_kv_same_line_url().captures(&line) {
            let label = c[1].trim().to_string();
            // 差异修复(见交付说明):Dart 这里直接把 \S+ 整段当 URL,会把 "https://a.com,备注"
            // 的 ",备注" 也吞进 URL(分支 ② 用 _urlRegex 就不会)。这里统一用 re_url 收口。
            let raw_url = re_url().find(&c[2]).map(|m| m.as_str()).unwrap_or(&c[2]).to_string();
            let url = clean_url(&raw_url);
            let label = if label.is_empty() { pending_label.clone() } else { Some(label) };
            add_url(&mut current, label.as_deref(), &url);
            pending_label = None;
            continue;
        }

        // ② 行内直接含 URL(标签在上一行)
        let urls: Vec<String> = re_url().find_iter(&line).map(|m| clean_url(m.as_str())).collect();
        if !urls.is_empty() {
            for url in &urls {
                add_url(&mut current, pending_label.as_deref(), url);
            }
            pending_label = None;
            continue;
        }

        // ③ 无 URL:键值字段(用户名/密码)或纯标签。
        if let Some(c) = re_kv_field().captures(&line) {
            let key = c[1].trim().to_lowercase();
            let value = c[2].trim().to_string();
            let label = c[1].trim().to_string();
            if matches_any(&key, IGNORE_KEYS) {
                continue;
            }
            // 先判密码:「用户密码」同时含「用户」与「密码」字样,必须优先归为密码,
            // 否则会被用户名键的子串匹配误吞。
            if matches_any(&key, PASS_KEYS) {
                if current.password.is_none() {
                    current.password = Some(strip_note(&value));
                }
                continue;
            }
            if matches_any(&key, USER_KEYS) {
                // 新用户名 → 若当前块已有内容,开新块。
                if current.username.is_some()
                    || !current.lines.is_empty()
                    || !current.danmaku_lines.is_empty()
                {
                    flush(&mut blocks, &mut current, &mut pending_label);
                }
                current.username = Some(strip_note(&value));
                continue;
            }
            // 未知键值 → 当作标签(键名)。
            pending_label = Some(label);
            continue;
        }

        // ④ 纯文本行 → 作为下一条 URL 的标签(取最靠近 URL 的一行)。
        pending_label = Some(line);
    }
    flush(&mut blocks, &mut current, &mut pending_label);

    // 去掉完全空的块。
    blocks.retain(|b| !b.is_empty());
    blocks
}

fn flush(
    blocks: &mut Vec<ParsedServerBlock>,
    current: &mut ParsedServerBlock,
    pending: &mut Option<String>,
) {
    let done = std::mem::take(current);
    if !done.is_empty() || done.username.is_some() {
        blocks.push(done);
    }
    *pending = None;
}

fn add_url(block: &mut ParsedServerBlock, label: Option<&str>, url: &str) {
    if url.is_empty() {
        return;
    }
    let name = match label {
        Some(l) if !l.is_empty() => strip_note(l),
        _ => host_of(url),
    };
    let is_danmaku = looks_danmaku(label) || looks_danmaku(Some(url));
    let target = if is_danmaku { &mut block.danmaku_lines } else { &mut block.lines };
    if target.iter().any(|l| l.url == url) {
        return; // 去重
    }
    target.push(ParsedLine { name, url: url.to_string() });
}

fn looks_danmaku(s: Option<&str>) -> bool {
    let Some(s) = s else { return false };
    let t = s.to_lowercase();
    t.contains("danmu") || t.contains("danmaku") || t.contains("弹幕")
}

/// key 已小写。Dart 是 `key == k || key.contains(k)` —— 相等必然被 contains 覆盖,这里只留 contains。
fn matches_any(key: &str, keys: &[&str]) -> bool {
    keys.iter().any(|k| key.contains(&k.to_lowercase()))
}

/// 去掉值里的括号备注,如 "1234(仅发送一次)" → "1234","示例用户 " → "示例用户"。
fn strip_note(value: &str) -> String {
    re_paren_note().replace(value.trim(), "").trim().to_string()
}

fn clean_url(url: &str) -> String {
    // 去掉尾部常见标点。
    re_trailing_punct().replace(url.trim(), "").to_string()
}

fn host_of(url: &str) -> String {
    reqwest::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_string))
        .filter(|h| !h.is_empty())
        .unwrap_or_else(|| "线路".to_string())
}

// ---------- 落配置用的纯函数(对齐 ServerBatchAdder,不含登录/存盘) ----------

/// 规范化服务器地址:缺协议时补 https://。
pub fn normalize_url(url: &str) -> String {
    let u = url.trim();
    if u.is_empty() {
        return String::new();
    }
    let lower = u.to_ascii_lowercase();
    if lower.starts_with("http://") || lower.starts_with("https://") {
        u.to_string()
    } else {
        format!("https://{u}")
    }
}

/// 块里的服务器线路 → [`ServerLine`](登录候选,按顺序试)。宿主逐条登录,成功即用该下标做 active_line。
///
/// id 用归一化后的 URL(稳定身份键),与 set_danmaku_config 里「id 为空就拿 api_url 顶」的约定同款。
/// Dart 用的是 uuid v4 —— 本 crate 无 uuid 依赖,且 URL 做 id 比随机 uuid 更稳(重复导入不产生重影)。
pub fn server_lines(block: &ParsedServerBlock) -> Vec<ServerLine> {
    block
        .lines
        .iter()
        .map(|l| {
            let url = normalize_url(&l.url);
            ServerLine {
                id: url.trim_end_matches('/').to_string(),
                name: l.name.clone(),
                url,
                remark: None,
            }
        })
        .collect()
}

/// 服务器图标地址。优先用登录用户的头像——很多 Emby 服把品牌 logo 直接设成用户头像,
/// 且用户头像在 Emby 是公开资源(登录选人界面免登录就显示),无需 api_key。
/// 该用户没头像时退回 `/web/touchicon.png`。两者都取不到时由 UI 回退内置 Emby 图标。
pub fn build_icon_url(
    base_url: &str,
    user_id: Option<&str>,
    primary_image_tag: Option<&str>,
) -> String {
    let b = base_url.trim().trim_end_matches('/');
    match (
        user_id.filter(|s| !s.is_empty()),
        primary_image_tag.filter(|s| !s.is_empty()),
    ) {
        (Some(uid), Some(tag)) => format!("{b}/Users/{uid}/Images/Primary?tag={tag}"),
        _ => format!("{b}/web/touchicon.png"),
    }
}

/// 块里的弹幕线路 → 全局弹幕源配置(鉴权方式默认「无」,用户可在弹幕设置里改)。
pub fn danmaku_sources_of(block: &ParsedServerBlock, base_priority: i32) -> Vec<DanmakuServer> {
    block
        .danmaku_lines
        .iter()
        .enumerate()
        .map(|(i, l)| {
            let api_url = normalize_url(&l.url);
            DanmakuServer {
                id: api_url.trim_end_matches('/').to_string(),
                name: l.name.clone(),
                api_url,
                auth_type: "none".into(),
                token: String::new(),
                enabled: true,
                priority: base_priority + i as i32,
            }
        })
        .collect()
}

// ---------- 深链 ----------

/// 深链查询串。Dart 的 `Uri.queryParameters` 对重复键取**最后一个**(splitQueryString 是 fold 覆盖写),
/// `queryParametersAll` 取全部 —— 这里 last()/all() 与之一一对应,别改成 first()。
struct QueryParams(Vec<(String, String)>);

impl QueryParams {
    fn new(u: &reqwest::Url) -> Self {
        Self(u.query_pairs().map(|(k, v)| (k.into_owned(), v.into_owned())).collect())
    }
    fn last(&self, k: &str) -> Option<String> {
        self.0.iter().rev().find(|(a, _)| a == k).map(|(_, v)| v.clone())
    }
    fn all(&self, k: &str) -> Vec<String> {
        self.0.iter().filter(|(a, _)| a == k).map(|(_, v)| v.clone()).collect()
    }
}

/// 认链:scheme 必须是 linplayer,host 或 path 命中 `want`(对齐 Dart 的 host||path.contains 判定)。
fn deep_link_target(url: &str, want: &str) -> Option<QueryParams> {
    let u = reqwest::Url::parse(url).ok()?;
    if u.scheme() != "linplayer" {
        return None;
    }
    // url crate 对非特殊 scheme 的 host 不小写化(Dart 的 Uri 会),这里补上。
    let host = u.host_str().unwrap_or("").to_lowercase();
    if host != want && !u.path().contains(want) {
        return None;
    }
    Some(QueryParams::new(&u))
}

/// 解析 `linplayer://add-server?...` 深链。
///
/// 形式一(结构化):`?name=&user=&pwd=&line=&line=&danmaku=`
/// 形式二(整段分享文本):`?text=<urlencoded>`,此时仍可用 `?user=`/`?pwd=` 覆盖文本里解出的凭据。
///
/// 返回 None = 不是本 App 的 add-server 链接 / 链接里没有任何可用线路。
///
/// **返回非 None ≠ 可以直接登录**:外部链接完全不可信,宿主必须先弹确认框(展示 host/用户名/
/// 弹幕源数量 + 明文 HTTP 警告),用户点了才登录、添加、设为当前、并入弹幕源。
/// 另:`?user=` 存在但为空串时 username 会是 `Some("")`(Dart 同款语义:显式空 ≠ 回落 text 里的
/// 用户名),宿主据此判「链接缺少用户名」拒绝登录。
pub fn parse_deep_link(url: &str) -> Option<DeepLinkAddServer> {
    let q = deep_link_target(url, "add-server")?;
    let mut block = block_from_query(&q)?;
    if block.is_empty() {
        return None;
    }
    // 查询参数优先于 text 里解析出来的凭据(对齐 Dart _handle)。
    if let Some(user) = q.last("user") {
        block.username = Some(user.trim().to_string());
    }
    if let Some(pwd) = q.last("pwd") {
        block.password = Some(pwd); // 密码不 trim:可能真含空格
    }
    Some(DeepLinkAddServer { name: q.last("name"), block })
}

/// 解析 `linplayer://sync-bangumi?code=...` 深链,返回 Bangumi 授权码。
/// 同样不可信:宿主必须先弹确认框再拿去换令牌(防网页 drive-by 把用户绑到攻击者账号)。
pub fn parse_bangumi_code(url: &str) -> Option<String> {
    let q = deep_link_target(url, "sync-bangumi")?;
    let code = q.last("code")?.trim().to_string();
    (!code.is_empty()).then_some(code)
}

/// 优先用结构化参数(line/danmaku/user/pwd),否则回退解析 `text` 整段分享文本。
fn block_from_query(q: &QueryParams) -> Option<ParsedServerBlock> {
    if let Some(text) = q.last("text") {
        if !text.trim().is_empty() {
            return parse_share_text(&text).into_iter().next();
        }
    }
    let line_urls = q.all("line");
    let danmaku_urls = q.all("danmaku");
    if line_urls.is_empty() && danmaku_urls.is_empty() {
        return None;
    }
    Some(ParsedServerBlock {
        username: q.last("user"),
        password: q.last("pwd"),
        lines: line_urls
            .iter()
            .map(|u| u.trim())
            .filter(|u| !u.is_empty())
            .map(|u| ParsedLine { name: host_of(&normalize_url(u)), url: u.to_string() })
            .collect(),
        danmaku_lines: danmaku_urls
            .iter()
            .map(|u| u.trim())
            .filter(|u| !u.is_empty())
            .map(|u| ParsedLine { name: "弹幕".to_string(), url: u.to_string() })
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn pairs(v: &[ParsedLine]) -> Vec<(&str, &str)> {
        v.iter().map(|l| (l.name.as_str(), l.url.as_str())).collect()
    }

    /// Dart 文档注释里那段真实机场分享文本 —— 这是这个模块存在的理由,必须一字不差解对。
    #[test]
    fn parses_real_world_share_text() {
        let text = "▎创建用户成功🎉\n\
                    · 用户名称 | 示例用户\n\
                    · 用户密码 | Ab3xKp9Q\n\
                    · 安全密码 | 1234（仅发送一次）\n\
                    · 到期时间 | 2026-06-30 23:34:28\n\
                    主线路（可尝试直连）\n\
                    https://line1.example.com:443\n\
                    海外备用（国际优化 CDN）\n\
                    https://cdn.example.net:443\n\
                    弹幕 API\n\
                    https://danmu.example.org/api-danmu\n";
        let blocks = parse_share_text(text);
        assert_eq!(blocks.len(), 1, "整段是一个账号块");
        let b = &blocks[0];
        assert_eq!(b.username.as_deref(), Some("示例用户"));
        assert_eq!(
            b.password.as_deref(),
            Some("Ab3xKp9Q"),
            "「安全密码」不是登录凭据,不能顶掉「用户密码」"
        );
        assert_eq!(
            pairs(&b.lines),
            [
                ("主线路", "https://line1.example.com:443"),
                ("海外备用", "https://cdn.example.net:443"),
            ],
            "标签在上一行;括号备注要剥掉;端口要留着"
        );
        assert_eq!(
            pairs(&b.danmaku_lines),
            [("弹幕 API", "https://danmu.example.org/api-danmu")],
            "含「弹幕」/danmu 的必须进弹幕线路而不是服务器线路"
        );
    }

    #[test]
    fn splits_multiple_account_blocks() {
        let text = "用户名 | u1\n密码 | p1\n线路 | https://a.com:8096\n\
                    用户名 | u2\n密码 | p2\n线路 | https://b.com\n";
        let blocks = parse_share_text(text);
        assert_eq!(blocks.len(), 2, "第二个用户名必须开新块,不能全糊成一坨");
        assert_eq!(blocks[0].username.as_deref(), Some("u1"));
        assert_eq!(blocks[0].password.as_deref(), Some("p1"));
        assert_eq!(pairs(&blocks[0].lines), [("线路", "https://a.com:8096")]);
        assert_eq!(blocks[1].username.as_deref(), Some("u2"));
        assert_eq!(blocks[1].password.as_deref(), Some("p2"));
        assert_eq!(pairs(&blocks[1].lines), [("线路", "https://b.com")]);
    }

    /// 块头显式分隔(且各块没有用户名)也要切开。
    #[test]
    fn splits_on_block_header() {
        let text = "创建用户成功\n主线路\nhttps://a.com\n创建用户成功\n主线路\nhttps://b.com\n";
        let blocks = parse_share_text(text);
        assert_eq!(blocks.len(), 2);
        assert_eq!(pairs(&blocks[0].lines), [("主线路", "https://a.com")]);
        assert_eq!(pairs(&blocks[1].lines), [("主线路", "https://b.com")]);
    }

    #[test]
    fn missing_username_still_yields_lines() {
        // 机场只发线路、用户名靠用户自己补(UI 让填一次套用到所有块)。
        let text = "主线路\nhttps://a.com:443\n弹幕\nhttps://d.com/danmu\n";
        let blocks = parse_share_text(text);
        assert_eq!(blocks.len(), 1, "没用户名不能整块丢掉");
        assert!(blocks[0].username.is_none());
        assert!(blocks[0].password.is_none());
        assert_eq!(pairs(&blocks[0].lines), [("主线路", "https://a.com:443")]);
        assert_eq!(pairs(&blocks[0].danmaku_lines), [("弹幕", "https://d.com/danmu")]);
    }

    #[test]
    fn full_width_colon_separator() {
        let text = "用户名：alice\n密码：secret123\n主线路：https://a.example.com:8096\n";
        let blocks = parse_share_text(text);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].username.as_deref(), Some("alice"));
        assert_eq!(blocks[0].password.as_deref(), Some("secret123"));
        assert_eq!(
            pairs(&blocks[0].lines),
            [("主线路", "https://a.example.com:8096")],
            "全角冒号 + 端口必须都吃得下"
        );
    }

    #[test]
    fn strips_leading_bullets() {
        let text = "▎账号信息\n· 用户名 | bob\n• 密码 | pw\n▍主线路\n► https://a.com\n";
        let blocks = parse_share_text(text);
        assert_eq!(blocks.len(), 1);
        assert_eq!(blocks[0].username.as_deref(), Some("bob"), "· 不能被当成用户名的一部分");
        assert_eq!(blocks[0].password.as_deref(), Some("pw"));
        assert_eq!(pairs(&blocks[0].lines), [("主线路", "https://a.com")], "▍/► 要剥干净");
    }

    #[test]
    fn dedupes_same_url_and_falls_back_to_host_name() {
        let blocks = parse_share_text("https://a.com/x\nhttps://a.com/x\n");
        assert_eq!(
            pairs(&blocks[0].lines),
            [("a.com", "https://a.com/x")],
            "同 URL 去重,无标签用 host 当名"
        );
    }

    #[test]
    fn same_line_url_stops_at_punctuation() {
        // 差异修复:Dart 分支①的 \S+ 会把 ",备注" 也吞进 URL。
        let blocks = parse_share_text("主线路: https://a.com，备注\n");
        assert_eq!(pairs(&blocks[0].lines), [("主线路", "https://a.com")]);
    }

    #[test]
    fn empty_text_yields_nothing() {
        assert!(parse_share_text("").is_empty());
        assert!(parse_share_text("这里啥也没有\n随便几行字\n").is_empty(), "没线路的块必须丢掉");
    }

    // ---------- adder ----------

    #[test]
    fn normalize_url_adds_scheme() {
        assert_eq!(normalize_url("a.com"), "https://a.com");
        assert_eq!(normalize_url("  a.com:8096 "), "https://a.com:8096");
        assert_eq!(normalize_url("http://a.com"), "http://a.com", "明文 http 不能被偷偷改成 https");
        assert_eq!(normalize_url("HTTPS://a.com"), "HTTPS://a.com");
        assert_eq!(normalize_url("   "), "");
    }

    #[test]
    fn server_lines_normalize_and_keep_order() {
        let b = ParsedServerBlock {
            lines: vec![
                ParsedLine { name: "直连".into(), url: "a.com:8096".into() },
                ParsedLine { name: "CDN".into(), url: "https://cdn.a.com".into() },
            ],
            ..Default::default()
        };
        let ls = server_lines(&b);
        assert_eq!(ls.len(), 2, "线路顺序=登录尝试顺序,不能乱");
        assert_eq!(ls[0].url, "https://a.com:8096");
        assert_eq!(ls[0].name, "直连");
        assert_eq!(ls[1].url, "https://cdn.a.com");
        assert_ne!(ls[0].id, ls[1].id, "id 必须互不相同");
    }

    #[test]
    fn build_icon_url_prefers_user_avatar() {
        assert_eq!(
            build_icon_url("https://a.com/", Some("uid"), Some("tag1")),
            "https://a.com/Users/uid/Images/Primary?tag=tag1"
        );
        // 没头像 tag → 退回 touchicon;尾斜杠要削干净(多个也要)。
        assert_eq!(
            build_icon_url("https://a.com///", Some("uid"), None),
            "https://a.com/web/touchicon.png"
        );
        assert_eq!(build_icon_url("https://a.com", None, Some("tag")), "https://a.com/web/touchicon.png");
        assert_eq!(
            build_icon_url("https://a.com", Some(""), Some("tag")),
            "https://a.com/web/touchicon.png"
        );
    }

    #[test]
    fn danmaku_sources_continue_priority() {
        let b = ParsedServerBlock {
            danmaku_lines: vec![
                ParsedLine { name: "弹幕 API".into(), url: "d1.com/api".into() },
                ParsedLine { name: "备用".into(), url: "https://d2.com/api/".into() },
            ],
            ..Default::default()
        };
        let s = danmaku_sources_of(&b, 3);
        assert_eq!(s.len(), 2);
        assert_eq!(s[0].api_url, "https://d1.com/api");
        assert_eq!(s[0].priority, 3, "要接在已有源后面,不能从 0 抢先");
        assert_eq!(s[1].priority, 4);
        assert_eq!(s[0].auth_type, "none");
        assert!(s[0].enabled, "新加的源必须默认启用,否则用户加了却没弹幕");
        assert_eq!(s[1].id, "https://d2.com/api", "id 削尾斜杠,重复导入不产生重影");
    }

    // ---------- 深链 ----------

    #[test]
    fn deep_link_structured_params() {
        let d = parse_deep_link(
            "linplayer://add-server?name=MyServer&user=bob&pwd=p%40ss&\
             line=https%3A%2F%2Fa.com%3A8096&line=https%3A%2F%2Fb.com&danmaku=https%3A%2F%2Fd.com%2Fapi",
        )
        .expect("合法 add-server 链接必须解出来");
        assert_eq!(d.name.as_deref(), Some("MyServer"));
        assert_eq!(d.block.username.as_deref(), Some("bob"));
        assert_eq!(d.block.password.as_deref(), Some("p@ss"));
        assert_eq!(
            pairs(&d.block.lines),
            [("a.com", "https://a.com:8096"), ("b.com", "https://b.com")],
            "重复的 line= 必须全收,只收第一个就等于悄悄丢线路"
        );
        assert_eq!(pairs(&d.block.danmaku_lines), [("弹幕", "https://d.com/api")]);
    }

    #[test]
    fn deep_link_text_param_and_credential_override() {
        let d = parse_deep_link(
            "linplayer://add-server?text=%E4%B8%BB%E7%BA%BF%E8%B7%AF%0Ahttps%3A%2F%2Fa.com%3A443&user=bob&pwd=pw",
        )
        .expect("text= 整段文本必须能解");
        assert_eq!(pairs(&d.block.lines), [("主线路", "https://a.com:443")]);
        assert_eq!(d.block.username.as_deref(), Some("bob"), "?user= 要覆盖文本里解出的用户名");
        assert_eq!(d.block.password.as_deref(), Some("pw"));
        assert!(d.name.is_none());
    }

    #[test]
    fn deep_link_rejects_junk() {
        assert!(
            parse_deep_link("https://evil.com/add-server?line=https://a.com").is_none(),
            "别的 scheme 不接"
        );
        assert!(parse_deep_link("linplayer://sync-bangumi?code=x").is_none(), "别的 host 不接");
        assert!(parse_deep_link("linplayer://add-server").is_none(), "没线路 = 没用");
        assert!(parse_deep_link("linplayer://add-server?line=%20").is_none(), "空白线路不算线路");
        assert!(parse_deep_link("not a url").is_none());
        // ?user= 显式空 → Some("")(不回落 text 里的用户名),宿主据此拒绝登录。
        let d = parse_deep_link("linplayer://add-server?user=&line=https%3A%2F%2Fa.com").unwrap();
        assert_eq!(d.block.username.as_deref(), Some(""));
    }

    #[test]
    fn bangumi_deep_link() {
        assert_eq!(
            parse_bangumi_code("linplayer://sync-bangumi?code=%20abc%20").as_deref(),
            Some("abc")
        );
        assert!(parse_bangumi_code("linplayer://sync-bangumi?code=").is_none(), "空授权码不能拿去换令牌");
        assert!(parse_bangumi_code("linplayer://sync-bangumi").is_none());
        assert!(parse_bangumi_code("linplayer://add-server?code=x").is_none());
    }
}
