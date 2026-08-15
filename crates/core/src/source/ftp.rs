// FTP 后端。**只负责列目录**:mpv 自带 ftp 协议(实测 libmpv 的 protocol-list 里有
// `ftp`,桌面和安卓两侧都在),所以播放是把 `ftp://用户:密码@主机/路径` 直接交给它,
// 取流那一大套(Range / seek / 重连)由 ffmpeg 自己扛,我们一行都不用写。
//
// ★ 不开 TLS:同一张 protocol-list 里**没有 `ftps`**。列得出来却播不了的源
//   比没有这个源更糟,所以宁可不给 FTPS,也不做一个点进去必然黑屏的功能。
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use std::collections::HashMap;
use suppaftp::types::FileType;
use suppaftp::tokio::AsyncFtpStream;

/// 默认端口。用户填 `ftp://192.168.1.10` 不写端口是常态。
const DEFAULT_PORT: u16 = 21;

#[derive(Default)]
pub struct FtpBackend;

impl FtpBackend {
    pub fn new() -> Self {
        Self::default()
    }

    /// 从 base_url 里拆出 `host:port`。
    ///
    /// ★ 不能走 `normalize_base_url` —— 那个函数缺协议时补的是 **https**,
    ///   拿去连 FTP 会得到「host 是 https」这种解析结果。FTP 这边自己拆。
    fn host_port(base_url: &str) -> Result<(String, u16), SourceError> {
        let s = base_url.trim();
        let s = s
            .strip_prefix("ftp://")
            .or_else(|| s.strip_prefix("FTP://"))
            .unwrap_or(s);
        // 地址后面可能跟了路径(ftp://host/pub),端口只在第一段里找。
        let hostport = s.split('/').next().unwrap_or("").trim_end_matches('/');
        if hostport.is_empty() {
            return Err(SourceError::msg("FTP 地址不能为空"));
        }
        match hostport.rsplit_once(':') {
            Some((h, p)) if !h.is_empty() => {
                let port = p
                    .parse::<u16>()
                    .map_err(|_| SourceError::msg(format!("FTP 端口不是数字: {p}")))?;
                Ok((h.to_string(), port))
            }
            _ => Ok((hostport.to_string(), DEFAULT_PORT)),
        }
    }

    /// base_url 里带的路径前缀(`ftp://host/pub` → `/pub`)。用户可以只把某个子目录接进来。
    fn base_path(base_url: &str) -> String {
        let s = base_url.trim();
        let s = s
            .strip_prefix("ftp://")
            .or_else(|| s.strip_prefix("FTP://"))
            .unwrap_or(s);
        match s.find('/') {
            Some(i) => s[i..].trim_end_matches('/').to_string(),
            None => String::new(),
        }
    }

    /// 账号:空则按匿名。绝大多数公共 FTP 和不少 NAS 的默认共享都是匿名。
    fn credentials(server: &SourceServer) -> (String, String) {
        let u = server.username.clone().unwrap_or_default();
        if u.is_empty() {
            ("anonymous".to_string(), "anonymous@".to_string())
        } else {
            (u, server.password.clone().unwrap_or_default())
        }
    }

    async fn connect(server: &SourceServer) -> Result<AsyncFtpStream, SourceError> {
        let (host, port) = Self::host_port(&server.base_url)?;
        let mut s = AsyncFtpStream::connect((host.as_str(), port))
            .await
            .map_err(|e| SourceError::msg(format!("连不上 FTP {host}:{port}: {e}")))?;
        let (u, p) = Self::credentials(server);
        s.login(&u, &p)
            .await
            .map_err(|e| SourceError::auth(format!("FTP 登录失败: {e}")))?;
        // 必须切二进制。ASCII 模式下服务端会改写换行,视频文件当场损坏 ——
        // 而 RFC959 规定的**默认就是 ASCII**,不显式切就是踩着默认值发车。
        s.transfer_type(FileType::Binary)
            .await
            .map_err(|e| SourceError::msg(format!("FTP 无法切二进制模式: {e}")))?;
        Ok(s)
    }

    /// 把一行列目录输出解析成条目。解析不了的行**跳过而不是报错** ——
    /// LIST 没有标准格式,一行解不动不该让整个目录列不出来。
    ///
    /// ★ **不能用 `line.parse::<FtpFile>()`。** 它的链是
    ///   posix → dos → mlsd → **mlst**,而最后那个 `parse_mlst` 是给「查单个文件」
    ///   用的宽松格式:随便一行文本都能被它认成一个名字。于是 `total 42` 这种
    ///   LIST 头、服务端的欢迎语、乱码行,统统会变成目录里一个**假文件**,
    ///   点进去必然播放失败。所以这里按来源指定解析器,不给兜底那条留门。
    fn parse_lines(lines: &[String], dir: &str, mlsd: bool) -> Vec<SourceEntry> {
        use suppaftp::list::ListParser;
        let mut out = Vec::new();
        for line in lines {
            let parsed = if mlsd {
                ListParser::parse_mlsd(line)
            } else {
                // LIST 的两种主流方言:POSIX(各类 Unix FTPD)和 DOS(IIS)。
                ListParser::parse_posix(line).or_else(|_| ListParser::parse_dos(line))
            };
            let Ok(f) = parsed else {
                continue;
            };
            let name = f.name().to_string();
            if name.is_empty() || name == "." || name == ".." {
                continue;
            }
            let is_dir = f.is_directory();
            out.push(SourceEntry {
                id: format!("{}/{name}", dir.trim_end_matches('/')),
                is_video: !is_dir && is_video_file_name(&name),
                name,
                is_dir,
                size: (!is_dir).then(|| f.size() as i64).filter(|s| *s > 0),
                thumb_url: None,
                raw: None,
            });
        }
        sort_entries(&mut out);
        out
    }

    /// 播放 URL:`ftp://用户:密码@主机:端口/路径`。
    ///
    /// ★ 用户名和密码必须百分号编码后再塞进 userinfo 段。密码里一个 `@` 或 `:`
    ///   就会把 URL 切在错的地方 —— 表现是「密码里带符号的人永远登录失败」,
    ///   而且报的是连接错误,看不出是自己拼错了 URL。
    fn play_url(server: &SourceServer, path: &str) -> Result<String, SourceError> {
        let (host, port) = Self::host_port(&server.base_url)?;
        let (u, p) = Self::credentials(server);
        let userinfo = format!(
            "{}:{}@",
            urlencoding::encode(&u),
            urlencoding::encode(&p)
        );
        let encoded = path
            .split('/')
            .map(|seg| urlencoding::encode(seg).into_owned())
            .collect::<Vec<_>>()
            .join("/");
        Ok(format!("ftp://{userinfo}{host}:{port}{encoded}"))
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for FtpBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::ftp()
    }

    async fn list_dir(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let dir = match dir_id {
            Some(d) => d.to_string(),
            None => {
                let b = Self::base_path(&server.base_url);
                if b.is_empty() {
                    "/".to_string()
                } else {
                    b
                }
            }
        };
        let mut s = Self::connect(server).await?;

        /* 先试 MLSD 再退回 LIST。MLSD(RFC3659)是**机器可读**的:类型和大小都是
           带名字的字段,不用去猜列的位置。LIST 输出则是给人看的 `ls -l`,各家格式
           不一(POSIX / DOS / 还有一堆方言),猜错列就会把日期当成文件名。
           老服务端不认 MLSD,所以必须留 LIST 这条退路。 */
        let (lines, mlsd) = match s.mlsd(Some(&dir)).await {
            Ok(l) if !l.is_empty() => (l, true),
            _ => {
                let l = s
                    .list(Some(&dir))
                    .await
                    .map_err(|e| SourceError::msg(format!("FTP 列目录失败: {e}")))?;
                (l, false)
            }
        };
        // 断开失败无所谓:目录已经拿到了,为了一句 QUIT 让整次浏览失败不划算。
        let _ = s.quit().await;
        Ok(Self::parse_lines(&lines, &dir, mlsd))
    }

    async fn resolve_play(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        Ok(ResolvedPlay::simple(
            Self::play_url(server, &entry.id)?,
            entry.name.clone(),
            HashMap::new(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_host_and_port() {
        assert_eq!(
            FtpBackend::host_port("ftp://192.168.1.10").unwrap(),
            ("192.168.1.10".into(), 21)
        );
        assert_eq!(
            FtpBackend::host_port("ftp://nas.local:2121/pub").unwrap(),
            ("nas.local".into(), 2121)
        );
        // 不带协议头也要认(用户十有八九直接敲 IP)
        assert_eq!(
            FtpBackend::host_port("192.168.1.10:21").unwrap(),
            ("192.168.1.10".into(), 21)
        );
        assert!(FtpBackend::host_port("ftp://host:抽").is_err(), "端口不是数字要报错");
    }

    /// base_url 带子目录时,根目录应当是那个子目录而不是 `/`。
    #[test]
    fn base_path_is_the_root_when_present() {
        assert_eq!(FtpBackend::base_path("ftp://nas.local/pub/media/"), "/pub/media");
        assert_eq!(FtpBackend::base_path("ftp://nas.local"), "");
    }

    /// POSIX(多数 Linux FTPD)格式的 LIST。
    ///
    /// 末尾那两行是**关键**:`total 42` 是 LIST 的头,乱码行是噪声。
    /// 走 `line.parse::<FtpFile>()` 的实现会经 `parse_mlst` 兜底把它们都认成文件,
    /// 于是目录里凭空多出两个点了必然失败的条目。
    #[test]
    fn parses_posix_listing_and_drops_junk_lines() {
        let lines = vec![
            "total 42".to_string(),
            "drwxr-xr-x 2 usr grp 4096 Aug 15 10:30 剧集".to_string(),
            "-rw-r--r-- 1 usr grp 1048576 Aug 15 10:31 movie.mkv".to_string(),
            "-rw-r--r-- 1 usr grp 512 Aug 15 10:31 cover.jpg".to_string(),
            "这一行不是任何已知格式".to_string(),
        ];
        let v = FtpBackend::parse_lines(&lines, "/pub", false);
        assert_eq!(
            v.len(),
            3,
            "垃圾行变成了假条目: {:?}",
            v.iter().map(|e| &e.name).collect::<Vec<_>>()
        );
        assert!(v[0].is_dir && v[0].name == "剧集", "目录要排在最前");
        assert_eq!(v[0].id, "/pub/剧集");
        let mkv = v.iter().find(|e| e.name == "movie.mkv").unwrap();
        assert!(mkv.is_video && mkv.size == Some(1048576));
        assert!(!v.iter().find(|e| e.name == "cover.jpg").unwrap().is_video);
    }

    /// MLSD 是首选路径,必须真的能解 —— 解不动就会静默退化成「目录永远是空的」。
    #[test]
    fn parses_mlsd_listing() {
        let lines = vec![
            "type=dir;sizd=4096;modify=20260815103000; 剧集".to_string(),
            "type=file;size=1048576;modify=20260815103100; movie.mkv".to_string(),
            "type=cdir;modify=20260815103000; .".to_string(),
        ];
        let v = FtpBackend::parse_lines(&lines, "/pub", true);
        let names: Vec<_> = v.iter().map(|e| e.name.as_str()).collect();
        assert!(names.contains(&"剧集") && names.contains(&"movie.mkv"), "解出来的是 {names:?}");
        assert!(!names.contains(&"."), "当前目录自身(cdir)不该出现在列表里");
        let mkv = v.iter().find(|e| e.name == "movie.mkv").unwrap();
        assert!(mkv.is_video && !mkv.is_dir && mkv.size == Some(1048576));
        assert!(v.iter().find(|e| e.name == "剧集").unwrap().is_dir);
    }

    /// 密码里带 `@` / `:` 是最常见的拼 URL 事故:不编码就会把 URL 切在错的地方。
    #[test]
    fn play_url_percent_encodes_credentials() {
        let s = SourceServer {
            base_url: "ftp://nas.local:2121".into(),
            username: Some("me@home".into()),
            password: Some("p@ss:word".into()),
            ..Default::default()
        };
        let u = FtpBackend::play_url(&s, "/pub/a b.mkv").unwrap();
        assert_eq!(u, "ftp://me%40home:p%40ss%3Aword@nas.local:2121/pub/a%20b.mkv");
        // userinfo 段之后只允许剩一个 @ 之前的分隔;裸 @ 会让 host 解析错位
        assert_eq!(u.matches('@').count(), 1, "凭据里的 @ 没编码,host 会被切错");
    }

    /// 没填账号 = 匿名。不少 NAS/公共站就是这么开的,硬塞空账号会被拒。
    #[test]
    fn empty_username_falls_back_to_anonymous() {
        let s = SourceServer::default();
        assert_eq!(FtpBackend::credentials(&s).0, "anonymous");
    }
}
