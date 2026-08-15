// WebDAV 后端。列目录=PROPFIND(Depth:1),播放=把同一个 https URL 交给 mpv,
// 逐流带 Authorization: Basic —— WebDAV 的取流就是普通 HTTP GET,所以**播放链路一行都不用改**。
//
// ## 为什么不用 reqwest_dav 这类现成 crate
// 本仓的 reqwest client 挂着两样东西:按 host 的自签名证书白名单(见 http.rs 的
// HostAllowlistVerifier)和全局代理设置。现成 crate 自己 build 一个 Client,
// 这两样**全部绕过** —— 而 WebDAV 的典型对端就是家里那台自签名证书的 NAS,
// 绕过白名单等于「填对了地址也连不上,还只报一句 certificate error」。
// PROPFIND 本身只是一个带 XML body 的请求,响应解析靠 quick-xml,统共百来行,
// 比把证书策略再实现一遍便宜得多。
use super::{
    is_video_file_name, normalize_base_url, sort_entries, MediaSourceBackend, ResolvedPlay,
    SourceEntry, SourceError, SourceKind, SourceServer,
};
use base64::Engine;
use quick_xml::events::Event;
use std::collections::HashMap;

/// 只问我们真正用得上的四个属性。要整个 `<allprop>` 的话,某些服务端
/// (Nextcloud 尤其)会把一大堆自有属性一起塞回来,响应体大好几倍还更容易解析出岔子。
const PROPFIND_BODY: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<d:propfind xmlns:d="DAV:"><d:prop>
<d:displayname/><d:getcontentlength/><d:resourcetype/><d:getcontenttype/>
</d:prop></d:propfind>"#;

#[derive(Default)]
pub struct WebdavBackend;

impl WebdavBackend {
    pub fn new() -> Self {
        Self::default()
    }

    /// `Authorization: Basic`。WebDAV 没有会话令牌,每个请求都要重新带 ——
    /// 取流那条也一样,所以它必须原样进 ResolvedPlay.http_headers。
    fn auth_header(server: &SourceServer) -> Option<String> {
        let u = server.username.clone().unwrap_or_default();
        if u.is_empty() {
            return None; // 匿名共享(有的 NAS 开放只读匿名)
        }
        let p = server.password.clone().unwrap_or_default();
        Some(format!(
            "Basic {}",
            base64::engine::general_purpose::STANDARD.encode(format!("{u}:{p}"))
        ))
    }

    /// 把 base_url 拆成 (origin, 根路径)。
    /// origin = `https://主机:端口`;根路径 = 用户填的地址里带的那截路径
    /// (Nextcloud 必有:`/remote.php/dav/files/用户名`;群晖也常有)。
    fn split_base(base_url: &str) -> (String, String) {
        let base = normalize_base_url(base_url);
        let after_scheme = match base.find("://") {
            Some(i) => i + 3,
            None => 0,
        };
        match base[after_scheme..].find('/') {
            Some(j) => {
                let cut = after_scheme + j;
                (
                    base[..cut].to_string(),
                    base[cut..].trim_end_matches('/').to_string(),
                )
            }
            None => (base, String::new()),
        }
    }

    /// 把一条**服务端绝对路径**(`/remote.php/dav/files/u/剧集`)拼成完整 URL。
    ///
    /// ★ 拼的是 **origin**,不是 base_url。entry.id 来自响应里的 `href`,而 href
    ///   是**服务端绝对路径**(已经含了 base_url 里那截前缀)。拿它去接 base_url
    ///   会拼出 `/dav/dav/剧集` 这种双前缀 —— 根目录能列、点进任何子目录必 404,
    ///   而且只在「base_url 带路径」的服务端上犯(Nextcloud 全中,群晖常中)。
    ///
    /// ★ 路径要逐段百分号编码,但**斜杠不能编码**。整串 encode 会把 `/` 变成 `%2F`,
    ///   服务端看到的就成了一个名字里带斜杠的文件,必 404。
    fn url_for(base_url: &str, abs_path: &str) -> String {
        let (origin, _) = Self::split_base(base_url);
        let encoded = abs_path
            .split('/')
            .map(|seg| urlencoding::encode(seg).into_owned())
            .collect::<Vec<_>>()
            .join("/");
        format!("{origin}{encoded}")
    }

    async fn propfind(
        http: &reqwest::Client,
        server: &SourceServer,
        path: &str,
    ) -> Result<String, SourceError> {
        let url = Self::url_for(&server.base_url, path);
        let mut req = http
            .request(
                reqwest::Method::from_bytes(b"PROPFIND").expect("PROPFIND 是合法方法名"),
                &url,
            )
            .header("Depth", "1")
            .header("Content-Type", "application/xml; charset=utf-8")
            .body(PROPFIND_BODY);
        if let Some(a) = Self::auth_header(server) {
            req = req.header("Authorization", a);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| SourceError::msg(format!("无法连接 WebDAV: {e}")))?;
        let status = resp.status();
        if status == reqwest::StatusCode::UNAUTHORIZED || status == reqwest::StatusCode::FORBIDDEN {
            return Err(SourceError::auth("WebDAV 账号或密码不对"));
        }
        if !status.is_success() {
            // 405 = 这个地址不支持 PROPFIND,基本都是把普通 http 服务当 WebDAV 填了。
            let hint = if status == reqwest::StatusCode::METHOD_NOT_ALLOWED {
                "(这个地址不支持 PROPFIND,可能不是 WebDAV 服务)"
            } else {
                ""
            };
            return Err(SourceError::msg(format!("WebDAV 返回 {status}{hint}")));
        }
        resp.text()
            .await
            .map_err(|e| SourceError::msg(format!("读取 WebDAV 响应失败: {e}")))
    }

    /// 解析 207 multistatus。
    ///
    /// ★ **不能按 `d:response` 这种带前缀的字面量匹配。** 命名空间前缀是各家自选的:
    ///   Apache 用 `D:`,Nextcloud 用 `d:`,还有服务端把 DAV: 设成默认命名空间、
    ///   干脆不带前缀。所以一律取**本地名**(去掉 `:` 之前那截)再比。
    fn parse(xml: &str, base_path: &str) -> Result<Vec<SourceEntry>, SourceError> {
        /* ★ **不能开 trim_text。** 它是逐个 Text 事件去空白的,而 0.41 会把
           `Tom &amp; Jerry` 拆成 Text("Tom ") + GeneralRef + Text(" Jerry") ——
           两截各自被 trim 掉尾空格,拼回来就成了「Tom&Jerry」。名字里的空格
           就这么没了,还不报错。改成不 trim、最后统一 trim 整个值。 */
        let reader = &mut quick_xml::Reader::from_str(xml);

        let mut out = Vec::new();
        // 当前 <response> 累积到的字段
        let (mut href, mut disp, mut len, mut is_dir) = (String::new(), String::new(), 0i64, false);
        let mut cur = String::new(); // 当前正在读文本的元素本地名
        let mut in_response = false;

        let local = |raw: &[u8]| -> String {
            let s = String::from_utf8_lossy(raw);
            s.rsplit(':').next().unwrap_or("").to_ascii_lowercase()
        };

        /// 往当前元素累加一段文本。**必须是追加**,原因见下面 GeneralRef 那段注释。
        fn push_text(cur: &str, v: &str, href: &mut String, disp: &mut String, len: &mut i64) {
            match cur {
                "href" => href.push_str(v),
                "displayname" => disp.push_str(v),
                // 长度是纯数字,不会被实体拆开,直接解析即可。
                "getcontentlength" => *len = v.trim().parse().unwrap_or(*len),
                _ => {}
            }
        }

        loop {
            match reader.read_event() {
                Err(e) => return Err(SourceError::msg(format!("WebDAV 响应不是合法 XML: {e}"))),
                Ok(Event::Eof) => break,
                Ok(Event::Start(t)) => {
                    let n = local(t.name().as_ref());
                    match n.as_str() {
                        "response" => {
                            in_response = true;
                            href.clear();
                            disp.clear();
                            len = 0;
                            is_dir = false;
                        }
                        // <collection/> 出现在 <resourcetype> 里就代表这是目录。
                        // 它通常是**自闭合标签**,所以下面 Empty 那个分支同样要认。
                        "collection" => is_dir = true,
                        _ => {}
                    }
                    cur = n;
                }
                Ok(Event::Empty(t)) => {
                    if local(t.name().as_ref()) == "collection" {
                        is_dir = true;
                    }
                    cur.clear();
                }
                Ok(Event::Text(t)) => {
                    let v = t.decode().unwrap_or_default().to_string();
                    push_text(&cur, &v, &mut href, &mut disp, &mut len);
                }
                /* ★ quick-xml 0.41 起,`&amp;` 这类实体**不再并进 Text**,而是单独发一个
                   GeneralRef 事件。于是「Tom &amp; Jerry」会被拆成 Text("Tom ") +
                   GeneralRef("amp") + Text(" Jerry") 三拍 —— 上面那句要是写成赋值而不是
                   追加,文件名就只剩最后一截「 Jerry」,而且不报任何错。
                   文件名里带 & 太常见了,所以这里必须自己把实体拼回去。 */
                Ok(Event::GeneralRef(r)) => {
                    let resolved = match r.resolve_char_ref() {
                        // 数字实体(&#38; / &#x26;)库能直接算出字符
                        Ok(Some(c)) => c.to_string(),
                        // 具名实体:XML 预定义的只有这五个,其余原样留着别猜
                        _ => match r.decode().unwrap_or_default().as_ref() {
                            "amp" => "&".to_string(),
                            "lt" => "<".to_string(),
                            "gt" => ">".to_string(),
                            "quot" => "\"".to_string(),
                            "apos" => "'".to_string(),
                            other => format!("&{other};"),
                        },
                    };
                    push_text(&cur, &resolved, &mut href, &mut disp, &mut len);
                }
                Ok(Event::End(t)) => {
                    if local(t.name().as_ref()) == "response" && in_response {
                        in_response = false;
                        // 关掉 trim_text 后,少数会缩进叶子节点的服务端会把换行和空格
                        // 一起带进来,统一在这里去掉(文件名首尾本来就不该有空白)。
                        if let Some(e) =
                            Self::entry_of(href.trim(), disp.trim(), len, is_dir, base_path)
                        {
                            out.push(e);
                        }
                    }
                    cur.clear();
                }
                _ => {}
            }
        }
        sort_entries(&mut out);
        Ok(out)
    }

    /// 把一条 `<response>` 变成 SourceEntry;是「当前目录自己」那条则返回 None。
    fn entry_of(
        href: &str,
        disp: &str,
        len: i64,
        is_dir: bool,
        base_path: &str,
    ) -> Option<SourceEntry> {
        // href 可能是绝对 URL(http://host/dav/a)也可能是绝对路径(/dav/a),两种都合法。
        let path = match href.find("://") {
            Some(i) => {
                let rest = &href[i + 3..];
                rest.find('/').map(|j| &rest[j..]).unwrap_or("/").to_string()
            }
            None => href.to_string(),
        };
        // href 是百分号编码的,要解回真实路径才能当下一次 PROPFIND 的入参。
        let path = urlencoding::decode(&path)
            .map(|c| c.into_owned())
            .unwrap_or(path);
        let trimmed = path.trim_end_matches('/');

        // Depth:1 的响应**第一条永远是被请求的目录自己**。不剔掉的话点进任何目录
        // 都会看到一个指向自己的条目,一路点下去无限套娃。
        if trimmed == base_path.trim_end_matches('/') {
            return None;
        }
        let name = if disp.is_empty() {
            trimmed.rsplit('/').next().unwrap_or("").to_string()
        } else {
            disp.to_string()
        };
        if name.is_empty() {
            return None;
        }
        let is_video = !is_dir && is_video_file_name(&name);
        Some(SourceEntry {
            id: if is_dir {
                format!("{trimmed}/")
            } else {
                trimmed.to_string()
            },
            name,
            is_dir,
            is_video,
            size: (len > 0).then_some(len),
            thumb_url: None,
            raw: None,
        })
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for WebdavBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::webdav()
    }

    async fn list_dir(
        &self,
        http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        /* 一律用**服务端绝对路径**当 dir_id —— 响应里的 href 就是这个口径,
           两边统一才不用来回换算。根目录 = base_url 里带的那截路径(没带就是 `/`)。 */
        let path = match dir_id {
            Some(d) => d.to_string(),
            None => {
                let (_, root) = Self::split_base(&server.base_url);
                if root.is_empty() {
                    "/".to_string()
                } else {
                    root
                }
            }
        };
        let xml = Self::propfind(http, server, &path).await?;
        Self::parse(&xml, &path)
    }

    async fn resolve_play(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let mut headers = HashMap::new();
        if let Some(a) = Self::auth_header(server) {
            headers.insert("Authorization".to_string(), a);
        }
        Ok(ResolvedPlay::simple(
            Self::url_for(&server.base_url, &entry.id),
            entry.name.clone(),
            headers,
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Apache mod_dav 的真实形状:大写 `D:` 前缀、href 是绝对路径、目录带尾斜杠。
    const APACHE: &str = r#"<?xml version="1.0"?>
<D:multistatus xmlns:D="DAV:">
  <D:response><D:href>/dav/</D:href><D:propstat><D:prop>
    <D:displayname>dav</D:displayname><D:resourcetype><D:collection/></D:resourcetype>
  </D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>
  <D:response><D:href>/dav/%E5%89%A7%E9%9B%86/</D:href><D:propstat><D:prop>
    <D:displayname>剧集</D:displayname><D:resourcetype><D:collection/></D:resourcetype>
  </D:prop></D:propstat></D:response>
  <D:response><D:href>/dav/movie.mkv</D:href><D:propstat><D:prop>
    <D:displayname>movie.mkv</D:displayname><D:getcontentlength>1234</D:getcontentlength>
    <D:resourcetype/>
  </D:prop></D:propstat></D:response>
</D:multistatus>"#;

    /// Nextcloud 的形状:小写 `d:` 前缀。**同一段解析代码必须两种都吃得下** ——
    /// 命名空间前缀是服务端自选的,按字面量 `D:response` 匹配的实现在这里会解出空表。
    const NEXTCLOUD: &str = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/remote.php/dav/files/u/</d:href><d:propstat><d:prop>
    <d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
  <d:response><d:href>/remote.php/dav/files/u/a.mp4</d:href><d:propstat><d:prop>
    <d:displayname>a.mp4</d:displayname><d:getcontentlength>99</d:getcontentlength>
    <d:resourcetype/></d:prop></d:propstat></d:response>
</d:multistatus>"#;

    #[test]
    fn parses_apache_and_skips_self() {
        let v = WebdavBackend::parse(APACHE, "/dav/").unwrap();
        // 三条 response,自己那条要被剔掉 —— 留着会让每个目录里都躺一个指向自己的项。
        assert_eq!(
            v.len(),
            2,
            "自身那条没被剔掉: {:?}",
            v.iter().map(|e| &e.name).collect::<Vec<_>>()
        );
        assert!(v[0].is_dir && v[0].name == "剧集", "目录该排在前面且名字解码正确");
        assert_eq!(
            v[0].id, "/dav/剧集/",
            "下一跳的路径必须是**解码后**的,否则再 PROPFIND 会双重编码"
        );
        assert!(!v[1].is_dir && v[1].is_video);
        assert_eq!(v[1].size, Some(1234));
    }

    /// 前缀大小写不同的同一份 XML 必须解出同样的东西。
    #[test]
    fn namespace_prefix_case_does_not_matter() {
        let v = WebdavBackend::parse(NEXTCLOUD, "/remote.php/dav/files/u/").unwrap();
        assert_eq!(v.len(), 1, "小写 d: 前缀解不出来 —— 说明在按字面量前缀匹配");
        assert_eq!(v[0].name, "a.mp4");
        assert!(v[0].is_video);
    }

    /// 文件名里的 `&`。quick-xml 0.41 把实体拆成独立事件,
    /// 拼不回去的实现会把「Tom &amp; Jerry.mkv」解成「 Jerry.mkv」—— 而且不报错。
    #[test]
    fn reassembles_entities_inside_text() {
        let xml = r#"<?xml version="1.0"?>
<d:multistatus xmlns:d="DAV:">
  <d:response><d:href>/dav/</d:href><d:propstat><d:prop>
    <d:resourcetype><d:collection/></d:resourcetype></d:prop></d:propstat></d:response>
  <d:response><d:href>/dav/Tom &amp; Jerry.mkv</d:href><d:propstat><d:prop>
    <d:displayname>Tom &amp; Jerry.mkv</d:displayname>
    <d:getcontentlength>7</d:getcontentlength>
    <d:resourcetype/></d:prop></d:propstat></d:response>
</d:multistatus>"#;
        let v = WebdavBackend::parse(xml, "/dav/").unwrap();
        assert_eq!(v.len(), 1);
        assert_eq!(v[0].name, "Tom & Jerry.mkv", "实体没拼回去,文件名被截断了");
        assert_eq!(v[0].id, "/dav/Tom & Jerry.mkv");
        assert_eq!(v[0].size, Some(7), "长度被实体事件打断后丢了");
    }

    /// **点进子目录的完整往返。** 这条钉的是双前缀那个坑:
    /// 响应里的 href 是服务端绝对路径(已含 base_url 里那截 `/remote.php/dav/files/u`),
    /// 拿它去接 base_url 会拼出 `/remote.php/dav/files/u/remote.php/...`。
    /// 根目录照样能列,只有**点进任何子目录**才 404 —— 而 Nextcloud 全中招。
    #[test]
    fn entry_id_round_trips_when_base_url_has_a_path() {
        let base = "https://cloud.example.com/remote.php/dav/files/u";
        assert_eq!(
            WebdavBackend::split_base(base),
            (
                "https://cloud.example.com".to_string(),
                "/remote.php/dav/files/u".to_string()
            )
        );
        let v = WebdavBackend::parse(NEXTCLOUD, "/remote.php/dav/files/u").unwrap();
        let child = &v[0];
        // 拿列出来的 id 去拼下一次请求的 URL —— 必须正好落在那个文件上
        assert_eq!(
            WebdavBackend::url_for(base, &child.id),
            "https://cloud.example.com/remote.php/dav/files/u/a.mp4",
            "前缀拼重了 —— 点进子目录会 404"
        );
    }

    /// base_url 不带路径时,根目录就是 `/`。
    #[test]
    fn split_base_handles_bare_host() {
        assert_eq!(
            WebdavBackend::split_base("https://nas.local:5006"),
            ("https://nas.local:5006".to_string(), String::new())
        );
    }

    /// 路径里的斜杠不能被编码,中文/空格要被编码。整串 encode 会把 `/` 变成 %2F 必 404。
    #[test]
    fn url_encodes_segments_but_not_slashes() {
        // abs_path 是服务端绝对路径,所以这里要把 /dav 前缀写进去
        let u = WebdavBackend::url_for("https://nas.example.com/dav/", "/dav/剧集/a b.mkv");
        assert_eq!(u, "https://nas.example.com/dav/%E5%89%A7%E9%9B%86/a%20b.mkv");
        assert!(!u.contains("%2F"), "斜杠被编码了,服务端会当成文件名的一部分");
    }

    #[test]
    fn basic_auth_header_and_anonymous() {
        let mut s = SourceServer {
            username: Some("u".into()),
            password: Some("p".into()),
            ..Default::default()
        };
        // base64("u:p") == "dTpw"
        assert_eq!(WebdavBackend::auth_header(&s).unwrap(), "Basic dTpw");
        s.username = None;
        assert!(
            WebdavBackend::auth_header(&s).is_none(),
            "匿名共享不该硬塞一个空账号的 Basic 头"
        );
    }
}
