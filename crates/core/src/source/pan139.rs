// 移动云盘 / 中国移动云盘(yun.139.com)后端。个人云(hcy 新接口)。
//
// 登录:**手机号+密码 / 扫码**(逆向自官网 yun.139.com 自己的 Vue SPA
// app.5f980ea6.js,非 10086 统一认证);也保留手动粘贴 Authorization 兜底。
//   - 登录:POST .../user/thirdlogin(密码 pintype=9),
//     dycpwd=密码明文,secinfo=SHA1("fetion.com.cn:"+它).大写。
//   - 关键:Authorization **服务端从不下发现成串**,是客户端自算的:
//       Authorization = "Basic " + base64("pc:{手机号}:{data.token}")
//     所以拿到 token 就能离线算出 Authorization,不必再手动抓浏览器(enCodeToken 逆向)。
//
// 每个请求(含登录)都要 **mcloud-sign** 签名(cal_sign,与 app.js getNewSign 逐字节一致):
//   1. body 过 encodeURIComponent(JS 口径,不是通用 urlencode);
//   2. 拆成字符**排序**再拼回,base64;
//   3. sign = UPPER( MD5( MD5(base64) + MD5(ts + ":" + randStr) ) );
//   header:mcloud-sign: {ts},{randStr},{sign}。
//
// 扫码登录(thirdlogin type=5,dycpwd=qrcSessionID)见下方 qr_start/qr_poll。
//   token 过期(有 expireTime)无刷新端点,过期即重新登录。
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, QrPoll, QrStart, ResolvedPlay,
    SourceEntry, SourceError, SourceKind, SourceServer,
};
use md5::{Digest, Md5};
use rand::RngCore;
use serde_json::{json, Value};
use sha1::Sha1;
use std::collections::HashMap;

const HCY_HOST: &str = "https://personal-kd-njs.yun.139.com";
const PAGE_SIZE: i64 = 100;
const MAX_PAGES: usize = 400;
/// hcy 个人云根目录。UNVERIFIED:OpenList 用 dir.GetID(),根对象 ID 未在取到的源码片段里,
/// 按社区约定用 "root";填错可在表单 extra.root_id 覆盖。
const DEFAULT_ROOT: &str = "root";

#[derive(Default)]
pub struct Pan139Backend;

impl Pan139Backend {
    pub fn new() -> Self {
        Self
    }

    fn authorization(server: &SourceServer) -> Result<String, SourceError> {
        let raw = server
            .extra
            .get("authorization")
            .cloned()
            .or_else(|| server.token.clone())
            .filter(|s| !s.trim().is_empty())
            .ok_or_else(|| SourceError::auth("尚未登录，请粘贴移动云盘 Authorization"))?;
        let raw = raw.trim();
        // 用户可能只贴了 base64 主体,也可能带 "Basic " 前缀,统一补上。
        if raw.to_ascii_lowercase().starts_with("basic ") {
            Ok(raw.to_string())
        } else {
            Ok(format!("Basic {raw}"))
        }
    }

    async fn post(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
        body: Value,
    ) -> Result<Value, SourceError> {
        let auth = Self::authorization(server)?;
        let body_str = serde_json::to_string(&body).unwrap_or_default();
        let ts = now_ms().to_string();
        let rand_str = gen_rand_str();
        let sign = cal_sign(&body_str, &ts, &rand_str);

        let resp = http
            .post(format!("{HCY_HOST}{path}"))
            .header("Accept", "application/json, text/plain, */*")
            .header("Content-Type", "application/json;charset=UTF-8")
            .header("Authorization", &auth)
            .header("CMS-DEVICE", "default")
            .header("mcloud-channel", "1000101")
            .header("mcloud-client", "10701")
            .header("mcloud-version", "7.14.0")
            .header("mcloud-sign", format!("{ts},{rand_str},{sign}"))
            .header("x-SvcType", "1")
            .header("x-DeviceInfo", "||9|7.14.0|chrome|120.0.0.0|||windows 10||zh-CN|||")
            .header("x-huawei-channelSrc", "10000034")
            .header("x-inner-ntwk", "2")
            .header("x-m4c-caller", "PC")
            .header("x-m4c-src", "10002")
            .body(body_str)
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("移动云盘请求失败: {e}")))?;
        let status = resp.status();
        let v: Value = resp
            .json()
            .await
            .map_err(|e| SourceError::msg(format!("移动云盘响应解析失败({status}): {e}")))?;
        // 139 用 success + code 表状态;鉴权失效常见 code 含 "auth"/"token" 或 HTTP 401。
        let success = v["success"].as_bool().unwrap_or(false)
            || v["code"].as_str() == Some("0")
            || v["code"].as_i64() == Some(0);
        if !success {
            let msg = v["message"].as_str().unwrap_or("请求失败");
            let is_auth = status == reqwest::StatusCode::UNAUTHORIZED
                || {
                    let code = v["code"].as_str().unwrap_or("").to_ascii_lowercase();
                    code.contains("auth") || code.contains("token") || code.contains("login")
                };
            return Err(SourceError {
                message: format!(
                    "移动云盘错误: {msg}{}",
                    if is_auth { "（Authorization 可能已过期，请重新粘贴）" } else { "" }
                ),
                is_auth,
            });
        }
        Ok(v)
    }
}

fn item_to_entry(m: &Value) -> SourceEntry {
    let is_dir = m["type"].as_str() == Some("folder");
    let name = m["name"].as_str().unwrap_or("").to_string();
    let is_video = !is_dir && is_video_file_name(&name);
    SourceEntry {
        id: m["fileId"].as_str().unwrap_or("").to_string(),
        is_video,
        name,
        is_dir,
        size: m["size"].as_i64(),
        thumb_url: m["thumbnailUrl"]
            .as_str()
            .or_else(|| m["bigThumbnailUrl"].as_str())
            .map(|s| s.to_string()),
        raw: None,
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for Pan139Backend {
    fn kind(&self) -> SourceKind {
        SourceKind::pan139()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let root = server
            .extra
            .get("root_id")
            .filter(|s| !s.is_empty())
            .map(|s| s.as_str())
            .unwrap_or(DEFAULT_ROOT);
        let parent = dir_id.filter(|d| !d.is_empty()).unwrap_or(root);
        let mut out = Vec::new();
        let mut cursor = String::new();
        for _ in 0..MAX_PAGES {
            let body = json!({
                "imageThumbnailStyleList": ["Small", "Large"],
                "orderBy": "updated_at",
                "orderDirection": "DESC",
                "pageInfo": { "pageCursor": cursor, "pageSize": PAGE_SIZE },
                "parentFileId": parent,
            });
            let v = self.post(http, server, "/hcy/file/list", body).await?;
            let data = &v["data"];
            let empty = vec![];
            let items = data["items"].as_array().unwrap_or(&empty);
            out.extend(items.iter().map(item_to_entry));
            match data["nextPageCursor"].as_str().filter(|s| !s.is_empty()) {
                Some(c) => cursor = c.to_string(),
                None => break,
            }
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn resolve_play(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let v = self
            .post(
                http,
                server,
                "/hcy/file/getDownloadUrl",
                json!({ "fileId": entry.id }),
            )
            .await?;
        let url = v["data"]["cdnUrl"]
            .as_str()
            .filter(|s| !s.is_empty())
            .or_else(|| v["data"]["url"].as_str())
            .unwrap_or("");
        if url.is_empty() {
            return Err(SourceError::msg("移动云盘未返回下载地址"));
        }
        Ok(ResolvedPlay::simple(url.to_string(), entry.name.clone(), HashMap::new()))
    }
}

// ---------- 手机号登录(密码) ----------

const USER_HOST: &str = "https://user-njs.yun.139.com/user";
const CLIENT_TYPE_139: i64 = 670;
const CP_ID: i64 = 292;
const VERSION_139: &str = "mCloud_4.3.0_536";

/// SHA1(s) 大写 hex。secinfo 用。
fn sha1_upper(s: &str) -> String {
    let mut h = Sha1::new();
    h.update(s.as_bytes());
    hex::encode(h.finalize()).to_uppercase()
}

/// Authorization = "Basic " + base64("pc:{手机号}:{token}")。逆向自 app.js enCodeToken。
fn compute_authorization(phone: &str, token: &str) -> String {
    use base64::Engine;
    let raw = format!("pc:{phone}:{token}");
    format!("Basic {}", base64::engine::general_purpose::STANDARD.encode(raw.as_bytes()))
}

/// 响应是否成功。139 用 success 布尔或 code(0 / "0" / 六个零 / S000000)表状态。
fn resp_ok(v: &Value) -> bool {
    if let Some(b) = v["success"].as_bool() {
        return b;
    }
    match &v["code"] {
        Value::String(s) => {
            s == "0" || s == "000000" || s.eq_ignore_ascii_case("s000000")
        }
        Value::Number(n) => n.as_i64() == Some(0),
        Value::Null => true, // 无 code 字段就不当失败(以 data.token 存在为准)
        _ => true,
    }
}

fn resp_msg(v: &Value) -> String {
    v["message"]
        .as_str()
        .or_else(|| v["msg"].as_str())
        .unwrap_or("请求失败")
        .to_string()
}

/// 登录系 POST(user-njs 域,带 mcloud-sign 但**无 Authorization**——登录本身还没凭据)。
async fn login_post(
    http: &reqwest::Client,
    path: &str,
    body: Value,
) -> Result<Value, SourceError> {
    let body_str = serde_json::to_string(&body).unwrap_or_default();
    let ts = now_ms().to_string();
    let rand_str = gen_rand_str();
    let sign = cal_sign(&body_str, &ts, &rand_str);
    let resp = http
        .post(format!("{USER_HOST}{path}"))
        .header("Accept", "application/json, text/plain, */*")
        .header("Content-Type", "application/json;charset=UTF-8")
        .header("CMS-DEVICE", "default")
        .header("mcloud-channel", "1000101")
        .header("mcloud-client", "10701")
        .header("mcloud-version", "7.14.0")
        .header("mcloud-sign", format!("{ts},{rand_str},{sign}"))
        .header("x-huawei-channelSrc", "10000034")
        .header("x-NationCode", "+86")
        .body(body_str)
        .send()
        .await
        .map_err(|e| SourceError::msg(format!("移动云盘请求失败: {e}")))?;
    let status = resp.status();
    resp.json()
        .await
        .map_err(|e| SourceError::msg(format!("移动云盘响应解析失败({status}): {e}")))
}

/// 账密登录:手机号+密码。
pub async fn password_login(
    http: &reqwest::Client,
    username: &str,
    password: &str,
) -> Result<HashMap<String, String>, SourceError> {
    let phone = username.trim();
    if phone.is_empty() || password.is_empty() {
        return Err(SourceError::auth("请填写手机号和密码"));
    }
    third_login(http, phone, password, 9).await
}

/// thirdlogin:密码(pintype=9)与扫码(pintype=21)同端点,dycpwd 装密码明文或扫码会话 ID。
/// 成功后拿 data.token 本地算 Authorization,作为凭据返回。
async fn third_login(
    http: &reqwest::Client,
    phone: &str,
    secret: &str,
    pintype: i64,
) -> Result<HashMap<String, String>, SourceError> {
    let v = login_post(
        http,
        "/thirdlogin",
        json!({
            "msisdn": phone,
            "random": "",
            "dycpwd": secret,
            "cpid": CP_ID,
            "clienttype": CLIENT_TYPE_139,
            "version": VERSION_139,
            "pintype": pintype,
            "secinfo": sha1_upper(&format!("fetion.com.cn:{secret}")),
            "verType": 2,
            "loginMode": "0",
            "extInfo": {},
        }),
    )
    .await?;
    // token 在 body.data.token(响应拦截器已解包一层,已核对 app.js);兜底再看顶层 token。
    let token = v["data"]["token"]
        .as_str()
        .or_else(|| v["token"].as_str())
        .unwrap_or("");
    if token.is_empty() {
        if !resp_ok(&v) {
            return Err(SourceError::auth(format!("移动云盘登录失败: {}", resp_msg(&v))));
        }
        return Err(SourceError::msg("移动云盘登录成功但未返回令牌"));
    }
    let auth = compute_authorization(phone, token);
    Ok(HashMap::from([("authorization".to_string(), auth)]))
}

// ---------- 扫码登录 ----------
//
// 逆向自 chunk-23496a60(登录组件 createLoginQrcode/queryQrcLoginResult):
//   - sID 是**客户端自生成**的随机串(服务端不下发),二维码内容:
//       https://yun.139.com/w/#/qrcLogin?sID={sID}&dID={设备id}&cType=9
//   - 手机 App 扫这个 URL 确认后,PC 端反复 POST /thirdlogin(type=5→pintype=21,dycpwd=sID)拿 token。
//   - 轮询状态 data.result.resultCode:200059548=已扫待确认(继续)、200059542=已失效、200059549=已取消。
//   - 扫码登录的手机号从响应 encryptAccount(base64 的真实手机号)解出,再算 Authorization。

const QR_URL_BASE: &str = "https://yun.139.com/w/#/qrcLogin";

/// 出码:sID 客户端自生成,无需请求服务端。ctx 带 sID 回传给 qr_poll。
pub async fn qr_start(_http: &reqwest::Client) -> Result<QrStart, SourceError> {
    let sid = gen_rand_str();
    let did = gen_rand_str();
    let text = format!("{QR_URL_BASE}?sID={sid}&dID={did}&cType=9");
    let image = super::qr_svg_data_uri(&text)?;
    let ctx = json!({ "sID": sid }).to_string();
    Ok(QrStart { image, ctx })
}

/// 轮询一次:POST /thirdlogin(type=5)。confirmed 时算出 Authorization 作凭据。
pub async fn qr_poll(http: &reqwest::Client, ctx: &str) -> Result<QrPoll, SourceError> {
    let c: Value =
        serde_json::from_str(ctx).map_err(|_| SourceError::msg("扫码上下文损坏，请重新获取二维码"))?;
    let sid = c["sID"].as_str().unwrap_or("");
    if sid.is_empty() {
        return Err(SourceError::msg("扫码上下文缺少会话 ID"));
    }
    let v = login_post(
        http,
        "/thirdlogin",
        json!({
            "msisdn": "",
            "random": "",
            "dycpwd": sid,
            "cpid": CP_ID,
            "clienttype": CLIENT_TYPE_139,
            "version": VERSION_139,
            "pintype": 21,
            "secinfo": sha1_upper(&format!("fetion.com.cn:{sid}")),
            "verType": 2,
            "loginMode": "0",
            "extInfo": {},
        }),
    )
    .await?;
    // 成功:token + encryptAccount(base64 手机号)算 Authorization。
    let token = v["data"]["token"]
        .as_str()
        .or_else(|| v["token"].as_str())
        .unwrap_or("");
    if resp_ok(&v) && !token.is_empty() {
        let phone = decode_encrypt_account(&v);
        let auth = compute_authorization(&phone, token);
        return Ok(QrPoll::Confirmed {
            credentials: HashMap::from([("authorization".to_string(), auth)]),
        });
    }
    // 状态码判定(resultCode 可能是字符串或数字)。
    let code = match &v["data"]["result"]["resultCode"] {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        _ => String::new(),
    };
    match code.as_str() {
        "200059542" | "200059549" => Ok(QrPoll::Expired),
        _ => Ok(QrPoll::Pending), // 200059548 已扫待确认 / 待扫 / 其它一律继续等
    }
}

/// 从响应 encryptAccount(base64 的真实手机号)解出手机号;失败退回 simplifyAccount(脱敏,不理想但不空)。
fn decode_encrypt_account(v: &Value) -> String {
    use base64::Engine;
    let enc = v["data"]["encryptAccount"].as_str().unwrap_or("");
    if !enc.is_empty() {
        if let Ok(b) = base64::engine::general_purpose::STANDARD.decode(enc) {
            if let Ok(s) = String::from_utf8(b) {
                if !s.is_empty() {
                    return s;
                }
            }
        }
    }
    v["data"]["simplifyAccount"].as_str().unwrap_or("").to_string()
}

// ---------- mcloud-sign ----------

fn md5_hex(data: &[u8]) -> String {
    let mut h = Md5::new();
    h.update(data);
    hex::encode(h.finalize())
}

/// JS encodeURIComponent 的忠实复刻:只放行 A-Za-z0-9 与 -_.!~*'() ,其余按 UTF-8 字节
/// 百分号大写十六进制编码。**不能用通用 urlencode**(那会把 !~*'() 也编码,签名就对不上服务端)。
fn encode_uri_component(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for b in s.bytes() {
        let c = b as char;
        if c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.' | '!' | '~' | '*' | '\'' | '(' | ')') {
            out.push(c);
        } else {
            out.push('%');
            out.push_str(&format!("{b:02X}"));
        }
    }
    out
}

/// calSign:encodeURIComponent → 字符排序 → base64 → 双层 MD5 → 大写。
fn cal_sign(body: &str, ts: &str, rand_str: &str) -> String {
    use base64::Engine;
    let enc = encode_uri_component(body);
    // encodeURIComponent 输出纯 ASCII,按 char 排序 == 按字节排序,与 Go 的 sort.Strings 一致。
    let mut chars: Vec<char> = enc.chars().collect();
    chars.sort_unstable();
    let sorted: String = chars.into_iter().collect();
    let b64 = base64::engine::general_purpose::STANDARD.encode(sorted.as_bytes());
    let part1 = md5_hex(b64.as_bytes());
    let part2 = md5_hex(format!("{ts}:{rand_str}").as_bytes());
    md5_hex(format!("{part1}{part2}").as_bytes()).to_uppercase()
}

fn gen_rand_str() -> String {
    let mut b = [0u8; 8];
    rand::rng().fill_bytes(&mut b);
    hex::encode(b)
}

fn now_ms() -> u128 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis())
        .unwrap_or(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// encodeURIComponent 已知答案:对齐浏览器 JS。写歪一个保留字符,全表签名报废。
    #[test]
    fn encode_uri_component_matches_js() {
        assert_eq!(encode_uri_component("a b/c=中"), "a%20b%2Fc%3D%E4%B8%AD");
        // JS 不编码这几个:-_.!~*'()
        assert_eq!(encode_uri_component("-_.!~*'()"), "-_.!~*'()");
        // JSON 常见字符
        assert_eq!(encode_uri_component("{\"k\":\"v\"}"), "%7B%22k%22%3A%22v%22%7D");
    }

    /// calSign 排序不变性 + 形状。ts/randStr 相同则输出恒定;输出 32 位大写十六进制。
    #[test]
    fn cal_sign_is_deterministic_uppercase_md5() {
        let s1 = cal_sign(r#"{"a":1,"b":2}"#, "1700000000000", "abcd1234");
        let s2 = cal_sign(r#"{"a":1,"b":2}"#, "1700000000000", "abcd1234");
        assert_eq!(s1, s2);
        assert_eq!(s1.len(), 32, "MD5 = 16 字节 = 32 hex");
        assert!(s1.chars().all(|c| c.is_ascii_hexdigit() && !c.is_lowercase()));
        // ts 变则签名变(ts 进了第二层 MD5)。
        assert_ne!(s1, cal_sign(r#"{"a":1,"b":2}"#, "1700000000001", "abcd1234"));
    }

    /// Authorization 归一化:裸 base64 补 "Basic ",已带前缀的原样。无凭据报鉴权。
    #[test]
    fn authorization_normalizes_prefix() {
        let mut s = SourceServer::default();
        assert!(Pan139Backend::authorization(&s).is_err());
        s.extra.insert("authorization".into(), "YWJjOjEyMw==".into());
        assert_eq!(Pan139Backend::authorization(&s).unwrap(), "Basic YWJjOjEyMw==");
        s.extra.insert("authorization".into(), "Basic ZZZ".into());
        assert_eq!(Pan139Backend::authorization(&s).unwrap(), "Basic ZZZ");
    }

    #[test]
    fn item_type_folder_vs_file() {
        let d = json!({"type":"folder","name":"影视","fileId":"c1"});
        assert!(item_to_entry(&d).is_dir);
        let f = json!({"type":"file","name":"a.mkv","fileId":"f1","size":9});
        let e = item_to_entry(&f);
        assert!(!e.is_dir && e.is_video && e.id == "f1" && e.size == Some(9));
    }

    /// SHA1 大写 known-answer:secinfo 算错服务端可能拒登。SHA1("abc") 是标准向量。
    #[test]
    fn sha1_upper_known_answer() {
        assert_eq!(sha1_upper("abc"), "A9993E364706816ABA3E25717850C26C9CD0D89D");
    }

    /// Authorization 组装 known-answer:base64("pc:1:2")=cGM6MToy。逆向自 enCodeToken,
    /// 拼错(冒号/前缀/编码)则每个业务请求鉴权全废。
    #[test]
    fn authorization_known_answer() {
        assert_eq!(compute_authorization("1", "2"), "Basic cGM6MToy");
        // 真实形状:Basic 前缀 + 可解码回 "pc:手机号:token"。
        use base64::Engine;
        let a = compute_authorization("13800138000", "TOK123");
        let b64 = a.strip_prefix("Basic ").unwrap();
        let raw = base64::engine::general_purpose::STANDARD.decode(b64).unwrap();
        assert_eq!(String::from_utf8(raw).unwrap(), "pc:13800138000:TOK123");
    }

    /// 扫码手机号从 encryptAccount(base64 真实手机号)解;缺失退回 simplifyAccount。
    #[test]
    fn decode_encrypt_account_from_base64() {
        use base64::Engine;
        let enc = base64::engine::general_purpose::STANDARD.encode("13800138000");
        let v = json!({"data": {"encryptAccount": enc, "simplifyAccount": "138****8000"}});
        assert_eq!(decode_encrypt_account(&v), "13800138000");
        // 无 encryptAccount 时退脱敏号(不空即可,总比空手机号强)。
        let v2 = json!({"data": {"simplifyAccount": "138****8000"}});
        assert_eq!(decode_encrypt_account(&v2), "138****8000");
    }

    /// resp_ok:success 布尔优先,其次 code 的多种 0 写法;无 code 不算失败。
    #[test]
    fn resp_ok_variants() {
        assert!(resp_ok(&json!({"success": true})));
        assert!(!resp_ok(&json!({"success": false})));
        assert!(resp_ok(&json!({"code": "0"})));
        assert!(resp_ok(&json!({"code": "S000000"})));
        assert!(resp_ok(&json!({"code": 0})));
        assert!(!resp_ok(&json!({"code": "200059554"})));
        assert!(resp_ok(&json!({"data": {"token": "x"}})));
    }
}
