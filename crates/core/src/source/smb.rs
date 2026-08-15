// SMB / CIFS 后端(局域网共享,家里那台 NAS 最常见的接法)。
//
// ## 和另外两个局域网源不一样的地方:必须自己搬字节
// WebDAV 本身就是 HTTP、FTP 有 mpv 自带的 `ftp` 协议,两个都能把地址直接甩给播放器。
// SMB 不行 —— 实测本仓的 libmpv **没有编进 smb 协议**(桌面 DLL 用 ctypes 读
// `protocol-list`:68 个协议里没有 `smb`/`cifs`;两侧的 .so/.dll 也都不含
// libsmbclient 的符号)。所以这里的 resolve_play 返回的是一个**本地 http 地址**,
// 由 net/localserve.rs 那座桥把 SMB 的随机读翻译成 HTTP Range。
//
// ## 为什么是 smb2 这个 crate
// 纯 Rust、无 build.rs、无 C 依赖 —— 安卓交叉编译能过(已用 scripts/check-android.sh 验)。
// 更关键的是它有 `FileReader::read_at(offset, len)`:**视频要 seek,只能顺读的
// 实现等于不能用**。libsmbclient 系(pavao)是 C FFI,安卓上这条路直接堵死。
//
// ## 连接策略:每次操作现连,不做连接池
// 列目录本来就几百毫秒一次,播放那条则由 FileReader 自己攥着一条连接活到播完。
// 连接池要配套「失效检测 + 重连 + 并发借还」,而收益只是省掉列目录时的握手。
// ponytail: 现连现用;等真出现「点目录卡」再上池子。
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use crate::net::localserve::{self, BridgeHandle, RangeSource};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::Duration;

const DEFAULT_PORT: u16 = 445;

pub struct SmbBackend {
    /// 当前这片在放的桥。**换片就替换**,旧的一 drop 端口和那条 SMB 连接一起收。
    /// 存在这里而不是丢给调用方,是因为 `resolve_play` 只能返回一个 URL ——
    /// handle 没人持有的话,函数一返回桥就没了,mpv 拿到的会是个已经关掉的端口。
    bridge: Mutex<Option<BridgeHandle>>,
}

impl Default for SmbBackend {
    fn default() -> Self {
        Self::new()
    }
}

impl SmbBackend {
    pub fn new() -> Self {
        Self { bridge: Mutex::new(None) }
    }

    /// `smb://host` / `\\host` / `host:445` 都要认 —— 用户从哪抄来的都有。
    fn host_port(base_url: &str) -> Result<(String, u16), SourceError> {
        let s = base_url.trim();
        let s = s
            .strip_prefix("smb://")
            .or_else(|| s.strip_prefix("SMB://"))
            .unwrap_or(s);
        // Windows 的 UNC 写法:\\192.168.1.10\共享
        let s = s.trim_start_matches('\\').replace('\\', "/");
        let hostport = s.split('/').next().unwrap_or("").trim().to_string();
        if hostport.is_empty() {
            return Err(SourceError::msg("SMB 地址不能为空"));
        }
        match hostport.rsplit_once(':') {
            Some((h, p)) if !h.is_empty() => {
                let port = p
                    .parse::<u16>()
                    .map_err(|_| SourceError::msg(format!("SMB 端口不是数字: {p}")))?;
                Ok((h.to_string(), port))
            }
            _ => Ok((hostport, DEFAULT_PORT)),
        }
    }

    /// entry.id 的形状:`共享名/子目录/文件`(**不带前导斜杠**)。
    /// 拆成 (共享名, 共享内路径)。根目录(id 为空)返回 None。
    fn split_share(id: &str) -> Option<(&str, &str)> {
        let id = id.trim_matches('/');
        if id.is_empty() {
            return None;
        }
        Some(match id.split_once('/') {
            Some((share, rest)) => (share, rest),
            None => (id, ""),
        })
    }

    async fn connect(server: &SourceServer) -> Result<smb2::SmbClient, SourceError> {
        let (host, port) = Self::host_port(&server.base_url)?;
        let user = server.username.clone().unwrap_or_default();
        let pass = server.password.clone().unwrap_or_default();
        // 域:`DOMAIN\user` 这种写法要拆开,整串塞进 username 认证必失败。
        let (domain, user) = match user.split_once('\\') {
            Some((d, u)) => (d.to_string(), u.to_string()),
            None => (String::new(), user),
        };
        smb2::SmbClient::connect(smb2::ClientConfig {
            addr: format!("{host}:{port}"),
            // 5 秒对局域网够,但对刚从休眠里醒过来的 NAS 偏紧。
            timeout: Duration::from_secs(15),
            username: user,
            password: pass,
            domain,
            /* 开自动重连:Wi-Fi 漫游、NAS 硬盘转起来这类断连在家用环境里是常态,
               而它只会重放「重放了也不改变语义」的操作(读、列目录),
               不会替我们重发写操作。正在放的片子断一下能自己接上,比弹个错强。 */
            auto_reconnect: true,
            compression: true,
            dfs_enabled: true,
            dfs_target_overrides: HashMap::new(),
        })
        .await
        .map_err(|e| Self::wrap_err(e, &host))
    }

    /// SMB 的鉴权失败要标成 is_auth,UI 才会引导去重新登录而不是只弹一句红字。
    fn wrap_err(e: smb2::Error, host: &str) -> SourceError {
        let msg = e.to_string();
        let lower = msg.to_lowercase();
        if lower.contains("logon")
            || lower.contains("access denied")
            || lower.contains("access_denied")
            || lower.contains("password")
            || lower.contains("credential")
        {
            SourceError::auth(format!("SMB 登录失败({host}):{msg}"))
        } else {
            SourceError::msg(format!("SMB 出错({host}):{msg}"))
        }
    }

    /// 根目录 = 这台机器上的共享列表。
    ///
    /// ★ 要过滤掉 IPC$ / ADMIN$ / C$ 这类管理共享:它们点进去不是权限不足就是空的,
    ///   摆在第一屏只会让用户以为源坏了。用 crate 自带的 filter_disk_shares,
    ///   免得自己把 STYPE 的位运算抄错。
    async fn list_shares(server: &SourceServer) -> Result<Vec<SourceEntry>, SourceError> {
        let (host, _) = Self::host_port(&server.base_url)?;
        let mut client = Self::connect(server).await?;
        let shares = client
            .list_shares()
            .await
            .map_err(|e| Self::wrap_err(e, &host))?;
        let mut out: Vec<SourceEntry> = smb2::rpc::srvsvc::filter_disk_shares(shares)
            .into_iter()
            .map(|s| SourceEntry {
                id: s.name.clone(),
                name: s.name,
                is_dir: true,
                is_video: false,
                size: None,
                thumb_url: None,
                raw: None,
            })
            .collect();
        sort_entries(&mut out);
        Ok(out)
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for SmbBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::smb()
    }

    async fn list_dir(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let Some((share, path)) = dir_id.and_then(Self::split_share) else {
            // 没给 id(或给了个空的)= 根,列共享。
            return Self::list_shares(server).await;
        };
        let (host, _) = Self::host_port(&server.base_url)?;
        let mut client = Self::connect(server).await?;
        let tree = client
            .connect_share(share)
            .await
            .map_err(|e| Self::wrap_err(e, &host))?;
        let conn = client.connection_mut();
        let items = tree
            .list_directory(conn, path)
            .await
            .map_err(|e| Self::wrap_err(e, &host))?;

        let mut out = Vec::new();
        for it in items {
            // `.` 和 `..` 是协议层的产物,不是用户的东西。
            if it.name == "." || it.name == ".." {
                continue;
            }
            let child = if path.is_empty() {
                format!("{share}/{}", it.name)
            } else {
                format!("{share}/{path}/{}", it.name)
            };
            out.push(SourceEntry {
                id: child,
                is_video: !it.is_directory && is_video_file_name(&it.name),
                is_dir: it.is_directory,
                size: (!it.is_directory).then_some(it.size as i64).filter(|s| *s > 0),
                name: it.name,
                thumb_url: None,
                raw: None,
            });
        }
        sort_entries(&mut out);
        Ok(out)
    }

    async fn resolve_play(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let (share, path) = Self::split_share(&entry.id)
            .ok_or_else(|| SourceError::msg("SMB 播放路径不完整(缺共享名)"))?;
        if path.is_empty() {
            return Err(SourceError::msg("不能直接播放一个共享,请点进去选文件"));
        }
        let (host, _) = Self::host_port(&server.base_url)?;
        let mut client = Self::connect(server).await?;
        let tree = client
            .connect_share(share)
            .await
            .map_err(|e| Self::wrap_err(e, &host))?;
        // FileReader 是 'static 的:它自己攥着 Tree 和一条 Connection 的 Arc,
        // 所以 client 在这句之后掉出作用域也不会把连接带走。
        let reader = client
            .open_file_reader(&tree, path)
            .await
            .map_err(|e| Self::wrap_err(e, &host))?;

        let bridge = localserve::start(Arc::new(SmbFile(reader)))
            .await
            .map_err(|e| SourceError::msg(format!("起本地转发失败: {e}")))?;
        let url = bridge.url.clone();
        // 装上新桥的同时把上一片那座拆掉(旧 handle 在这里被 drop)。
        *self.bridge.lock().unwrap() = Some(bridge);

        Ok(ResolvedPlay::simple(url, entry.name.clone(), HashMap::new()))
    }
}

/// 把 smb2 的随机读文件接到本地 HTTP 桥上。
struct SmbFile(smb2::FileReader);

#[async_trait::async_trait]
impl RangeSource for SmbFile {
    fn size(&self) -> u64 {
        self.0.size()
    }
    async fn read_at(&self, offset: u64, len: u64) -> std::io::Result<Vec<u8>> {
        self.0
            .read_at(offset, len)
            .await
            .map_err(|e| std::io::Error::other(e.to_string()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 用户会从四个地方抄地址来:资源管理器(UNC)、别的播放器(smb://)、
    /// 自己记的 IP、带端口的。四种都得认,认错一种就是「填了地址连不上」。
    #[test]
    fn accepts_every_shape_of_address() {
        for (input, want) in [
            ("smb://192.168.1.10", ("192.168.1.10", 445)),
            ("192.168.1.10", ("192.168.1.10", 445)),
            ("\\\\192.168.1.10\\media", ("192.168.1.10", 445)),
            ("smb://nas.local:4450/媒体", ("nas.local", 4450)),
        ] {
            let got = SmbBackend::host_port(input).unwrap();
            assert_eq!(got, (want.0.to_string(), want.1), "地址没解对: {input}");
        }
        assert!(SmbBackend::host_port("").is_err());
        assert!(SmbBackend::host_port("smb://host:抽").is_err(), "端口不是数字要报错");
    }

    /// id 的分层是「第一段是共享名,剩下的是共享内路径」。
    /// 拆错的话会拿整条路径去 connect_share,必然连不上任何共享。
    #[test]
    fn splits_share_from_path() {
        assert_eq!(SmbBackend::split_share("media"), Some(("media", "")));
        assert_eq!(
            SmbBackend::split_share("media/剧集/S01"),
            Some(("media", "剧集/S01"))
        );
        // 根目录:没有共享名可拆,调用方据此去列共享
        assert_eq!(SmbBackend::split_share(""), None);
        assert_eq!(SmbBackend::split_share("/"), None);
    }

    /// 共享本身不是文件,点它要给一句人话,而不是让底下报个 STATUS_ 开头的错。
    #[tokio::test]
    async fn playing_a_bare_share_is_rejected_with_a_readable_message() {
        let b = SmbBackend::new();
        let entry = SourceEntry {
            id: "media".into(),
            name: "media".into(),
            is_dir: true,
            is_video: false,
            size: None,
            thumb_url: None,
            raw: None,
        };
        let s = SourceServer { base_url: "smb://10.0.0.1".into(), ..Default::default() };
        // ResolvedPlay 没有 Debug,用不了 expect_err
        let Err(e) = b.resolve_play(&reqwest::Client::new(), &s, &entry, None).await else {
            panic!("共享不该能直接播");
        };
        assert!(e.message.contains("请点进去选文件"), "报的是: {}", e.message);
    }
}
