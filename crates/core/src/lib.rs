// LinPlayer 核心库:平台无关的数据源/网络/配置逻辑。
// 桌面(Tauri)与安卓(flutter_rust_bridge/uniffi)共用同一份;此处禁引任何桌面专属 crate。
pub mod blocklist;
pub mod config;
pub mod config_transfer;
pub mod danmaku;
pub mod download;
pub mod emby;
pub mod http;
pub mod icon_cache;
pub mod icon_library;
pub mod image_cache;
pub mod media;
pub mod net;
pub mod companion;
pub mod paths;
pub mod plugins;
pub mod ranking;
pub mod secrets;
pub mod server_batch;
pub mod source;
pub mod sync;
pub mod translation;
pub mod update;
pub mod watch_history;
pub mod watch_history_sync;

pub use config::{Account, AppConfig, Prefs, ProxyConfig};
pub use emby::{Item, LoginResult, PlaybackTarget, Session};
pub use media::Track;
pub use source::{MediaSourceBackend, SourceEntry, SourceKind, SourceServer};
