// 多线程(分段)下载管理器 —— 迁自 Dart download_manager.dart。
//
// - 同一时刻只下 **一个文件**,单文件内部 1–4 分段(线程)并发,用 HTTP Range 分块。
// - 每段写独立 `${file}.partN` 临时文件,全完成后按序拼接;天然断点续传(重启按 part 大小恢复)。
// - 探测大小 + Range 支持;不支持 Range/未知大小 → 退回单段整流。
//
// 进度不主动推送,前端轮询 list();一个活跃下载,文件 I/O 走 tokio::fs。

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncReadExt, AsyncWriteExt};

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum DownloadStatus {
    Queued,
    Downloading,
    Paused,
    Completed,
    Failed,
    Canceled,
}

#[derive(Serialize, Deserialize, Clone)]
pub struct DownloadSegment {
    pub start: i64,
    pub end: i64, // -1 = 未知大小(单段整流)
    #[serde(default)]
    pub downloaded: i64,
}

impl DownloadSegment {
    fn length(&self) -> i64 {
        self.end - self.start + 1
    }
}

#[derive(Serialize, Deserialize, Clone)]
pub struct DownloadItem {
    pub id: String,
    pub item_id: String,
    #[serde(default)]
    pub media_source_id: Option<String>,
    #[serde(rename = "type")]
    pub type_: String,
    pub title: String,
    #[serde(default)]
    pub series_id: Option<String>,
    #[serde(default)]
    pub series_name: Option<String>,
    #[serde(default)]
    pub season_number: Option<i64>,
    #[serde(default)]
    pub episode_number: Option<i64>,
    #[serde(default)]
    pub poster_url: Option<String>,
    pub container: String,
    pub url: String,
    pub file_path: String,
    #[serde(default)]
    pub total_bytes: i64,
    pub status: DownloadStatus,
    #[serde(default)]
    pub error: Option<String>,
    pub added_at: i64,
    #[serde(default)]
    pub supports_range: bool,
    #[serde(default)]
    pub segments: Vec<DownloadSegment>,
    // 派生:已收字节 + 进度(前端展示用,序列化便于直接读)。
    #[serde(default)]
    pub received_bytes: i64,
    #[serde(default)]
    pub progress: f64,
}

impl DownloadItem {
    /// 新建待入队条目(id/file_path/added_at 由 enqueue 填)。
    pub fn new(
        item_id: String,
        type_: String,
        title: String,
        container: String,
        url: String,
        poster_url: Option<String>,
    ) -> Self {
        DownloadItem {
            id: String::new(),
            item_id,
            media_source_id: None,
            type_,
            title,
            series_id: None,
            series_name: None,
            season_number: None,
            episode_number: None,
            poster_url,
            container,
            url,
            file_path: String::new(),
            total_bytes: 0,
            status: DownloadStatus::Queued,
            error: None,
            added_at: 0,
            supports_range: false,
            segments: vec![],
            received_bytes: 0,
            progress: 0.0,
        }
    }

    fn part_path(&self, index: usize) -> PathBuf {
        PathBuf::from(format!("{}.part{index}", self.file_path))
    }
    fn recompute(&mut self) {
        self.received_bytes = self.segments.iter().map(|s| s.downloaded).sum();
        self.progress = if self.status == DownloadStatus::Completed {
            1.0
        } else if self.total_bytes <= 0 {
            0.0
        } else {
            (self.received_bytes as f64 / self.total_bytes as f64).clamp(0.0, 1.0)
        };
    }
}

fn now_ms() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_millis() as i64)
        .unwrap_or(0)
}

struct State {
    items: HashMap<String, DownloadItem>,
    dir: PathBuf,
    index_path: PathBuf,
    active_id: Option<String>,
    cancel: Arc<AtomicBool>,
    pending_removal: std::collections::HashSet<String>,
    threads: usize,
}

/// 下载管理器。tauri 持一个,命令桥转发操作。
#[derive(Clone)]
pub struct DownloadManager {
    state: Arc<Mutex<State>>,
    client: reqwest::Client,
    /* ★ 自带运行时句柄,**不用裸 `tokio::spawn`**。
       裸 spawn 要求调用线程处在 tokio 上下文里,而本管理器的写路径是被
       **同步** `#[tauri::command]` 调的 —— tauri 在收到 IPC 的那条线程上内联执行
       (tauri-2.11.5 webview/mod.rs:1909 `run_invoke_handler`),那是 WebView2 的
       消息线程,没有任何 tokio 上下文。裸 spawn 在那里 panic("no reactor running"),
       panic 穿过 FFI 边界就是整个进程消失 = 用户报的「一点下载就卡死然后闪退」。
       (list() 不 spawn,所以下载页打得开、一动就死。)
       句柄在 new() 里抓一次,之后从任何线程 spawn 都成立 —— 修在这里,
       桌面/安卓两端、现有和将来新加的命令一并覆盖,不用逐个命令改成 async。 */
    rt: tokio::runtime::Handle,
}

impl DownloadManager {
    /// dir 由调用方决定(桌面:`paths::downloads_dir()` = 数据根下的 downloads/)。
    /// index.json 跟着 dir 走 —— 换 dir 等于换一份索引,旧目录里的文件不会自动出现在列表里。
    /// load 恢复既有索引。
    pub async fn new(dir: PathBuf) -> Self {
        let _ = tokio::fs::create_dir_all(&dir).await;
        let index_path = dir.join("index.json");
        let mut items = HashMap::new();
        if let Ok(raw) = tokio::fs::read_to_string(&index_path).await {
            if let Ok(list) = serde_json::from_str::<Vec<DownloadItem>>(&raw) {
                for mut it in list {
                    // 被中断的"下载中"改为暂停,按 part 文件实际大小恢复。
                    if it.status == DownloadStatus::Downloading {
                        it.status = DownloadStatus::Paused;
                    }
                    sync_segments_from_disk(&mut it).await;
                    it.recompute();
                    items.insert(it.id.clone(), it);
                }
            }
        }
        let mgr = DownloadManager {
            state: Arc::new(Mutex::new(State {
                items,
                dir,
                index_path,
                active_id: None,
                cancel: Arc::new(AtomicBool::new(false)),
                pending_removal: Default::default(),
                threads: 2,
            })),
            client: crate::http::emby_client(),
            // new() 本身是 async → 一定在运行时上下文里,这里抓得到。
            rt: tokio::runtime::Handle::current(),
        };
        mgr.process_queue();
        mgr
    }

    pub fn set_threads(&self, n: usize) {
        self.state.lock().unwrap().threads = n.clamp(1, 4);
    }

    /// 列出所有任务(按加入时间倒序)。
    pub fn list(&self) -> Vec<DownloadItem> {
        let st = self.state.lock().unwrap();
        let mut v: Vec<DownloadItem> = st.items.values().cloned().collect();
        v.sort_by(|a, b| b.added_at.cmp(&a.added_at));
        v
    }

    /// 已完成的本地文件路径(未完成返回 None)。
    pub fn completed_path(&self, item_id: &str) -> Option<String> {
        let st = self.state.lock().unwrap();
        st.items
            .values()
            .find(|i| i.item_id == item_id && i.status == DownloadStatus::Completed)
            .map(|i| i.file_path.clone())
    }

    /// 新增任务;已存在则(失败/取消的)重新入队,返回其 id。
    #[allow(clippy::too_many_arguments)]
    pub fn enqueue(&self, mut item: DownloadItem) -> String {
        let id = item.item_id.clone();
        item.id = id.clone();
        {
            let mut st = self.state.lock().unwrap();
            if let Some(ex) = st.items.get_mut(&id) {
                if ex.status == DownloadStatus::Failed || ex.status == DownloadStatus::Canceled {
                    ex.status = DownloadStatus::Queued;
                    ex.error = None;
                }
            } else {
                if item.container.trim().is_empty() {
                    item.container = "mkv".into();
                }
                item.container = item.container.trim().to_lowercase();
                let fname = format!("{}_{}.{}", safe_name(&item.title), item.item_id, item.container);
                item.file_path = st.dir.join(fname).to_string_lossy().to_string();
                item.status = DownloadStatus::Queued;
                item.added_at = now_ms();
                item.recompute();
                st.items.insert(id.clone(), item);
            }
        }
        self.persist_blocking();
        self.process_queue();
        id
    }

    pub fn pause(&self, id: &str) {
        let mut st = self.state.lock().unwrap();
        if let Some(it) = st.items.get_mut(id) {
            it.status = DownloadStatus::Paused;
        }
        if st.active_id.as_deref() == Some(id) {
            st.cancel.store(true, Ordering::SeqCst);
        }
        drop(st);
        self.persist_blocking();
    }

    pub fn resume(&self, id: &str) {
        {
            let mut st = self.state.lock().unwrap();
            if let Some(it) = st.items.get_mut(id) {
                if it.status == DownloadStatus::Completed {
                    return;
                }
                it.status = DownloadStatus::Queued;
                it.error = None;
            }
        }
        self.persist_blocking();
        self.process_queue();
    }

    /// 只清记录,保留已下好的文件(下载页「清除已完成」)。
    /// 与 remove 的唯一区别就是不 delete_files —— 别把这两个合并回去。
    pub fn forget(&self, id: &str) -> bool {
        let gone = {
            let mut st = self.state.lock().unwrap();
            // 正在下的条目没有「完整文件」可留,交给 remove 走取消+清理,别在这里半路截胡。
            if st.active_id.as_deref() == Some(id) {
                false
            } else {
                st.items.remove(id).is_some()
            }
        };
        if gone {
            self.persist_blocking();
        }
        gone
    }

    pub fn remove(&self, id: &str) {
        let (active, item) = {
            let mut st = self.state.lock().unwrap();
            let active = st.active_id.as_deref() == Some(id);
            if active {
                if let Some(it) = st.items.get_mut(id) {
                    it.status = DownloadStatus::Canceled;
                }
                st.pending_removal.insert(id.to_string());
                st.cancel.store(true, Ordering::SeqCst);
                (true, None)
            } else {
                (false, st.items.remove(id))
            }
        };
        if !active {
            if let Some(it) = item {
                self.rt.spawn(async move { delete_files(&it).await });
            }
            self.persist_blocking();
        }
    }

    // ==================== 下载核心 ====================

    fn process_queue(&self) {
        let next = {
            let st = self.state.lock().unwrap();
            if st.active_id.is_some() {
                return;
            }
            st.items
                .values()
                .filter(|i| i.status == DownloadStatus::Queued)
                .min_by_key(|i| i.added_at)
                .map(|i| i.id.clone())
        };
        if let Some(id) = next {
            let me = self.clone();
            self.rt.spawn(async move { me.start_download(id).await });
        }
    }

    async fn start_download(&self, id: String) {
        let cancel = Arc::new(AtomicBool::new(false));
        {
            let mut st = self.state.lock().unwrap();
            if st.active_id.is_some() {
                return;
            }
            st.active_id = Some(id.clone());
            st.cancel = cancel.clone();
            if let Some(it) = st.items.get_mut(&id) {
                it.status = DownloadStatus::Downloading;
                it.error = None;
            }
        }

        let result = self.download_item(&id, &cancel).await;

        // 收尾。
        let removal;
        {
            let mut st = self.state.lock().unwrap();
            if let Some(it) = st.items.get_mut(&id) {
                match &result {
                    Ok(()) => {
                        if it.total_bytes <= 0 {
                            it.total_bytes = it.segments.iter().map(|s| s.downloaded).sum();
                        }
                        it.status = DownloadStatus::Completed;
                        it.recompute();
                    }
                    Err(e) => {
                        // pause/remove 已置 paused/canceled;其余判失败。
                        if it.status == DownloadStatus::Downloading {
                            it.status = DownloadStatus::Failed;
                            it.error = Some(e.clone());
                        }
                    }
                }
            }
            st.active_id = None;
            removal = st.pending_removal.remove(&id);
        }
        if removal {
            let item = self.state.lock().unwrap().items.remove(&id);
            if let Some(it) = item {
                delete_files(&it).await;
            }
        }
        self.persist().await;
        self.process_queue();
    }

    async fn download_item(&self, id: &str, cancel: &Arc<AtomicBool>) -> Result<(), String> {
        // 探测大小 + 构建分段(仅首次)。
        let (need_probe, url) = {
            let st = self.state.lock().unwrap();
            let it = st.items.get(id).ok_or("任务不存在")?;
            (it.total_bytes <= 0 && it.segments.is_empty(), it.url.clone())
        };
        if need_probe {
            let (total, supports) = probe(&self.client, &url).await;
            let mut st = self.state.lock().unwrap();
            let threads = st.threads;
            if let Some(it) = st.items.get_mut(id) {
                if total > 0 {
                    it.total_bytes = total;
                }
                it.supports_range = supports;
                build_segments(it, threads);
            }
        } else {
            {
                let mut st = self.state.lock().unwrap();
                let threads = st.threads;
                if let Some(it) = st.items.get_mut(id) {
                    if it.segments.is_empty() {
                        build_segments(it, threads);
                    }
                }
            }
            let mut it = self.snapshot(id).ok_or("任务不存在")?;
            sync_segments_from_disk(&mut it).await;
            self.write_segments(id, &it);
        }

        let it = self.snapshot(id).ok_or("任务不存在")?;
        let n = it.segments.len();

        // 并发跑所有分段。
        let mut set = tokio::task::JoinSet::new();
        for i in 0..n {
            let me = self.clone();
            let id = id.to_string();
            let cancel = cancel.clone();
            set.spawn(async move { me.run_segment(&id, i, cancel).await });
        }
        let mut err: Option<String> = None;
        while let Some(r) = set.join_next().await {
            match r {
                Ok(Ok(())) => {}
                Ok(Err(e)) => {
                    err = Some(e);
                    cancel.store(true, Ordering::SeqCst); // 一段出错/取消 → 立即取消其余
                }
                Err(_) => err = Some("分段任务崩溃".into()),
            }
        }
        if let Some(e) = err {
            return Err(e);
        }

        // 全部完成 → 拼接。
        let it = self.snapshot(id).ok_or("任务不存在")?;
        assemble(&it).await.map_err(|e| e.to_string())?;
        Ok(())
    }

    async fn run_segment(&self, id: &str, index: usize, cancel: Arc<AtomicBool>) -> Result<(), String> {
        let it = self.snapshot(id).ok_or("任务不存在")?;
        let seg = it.segments.get(index).ok_or("分段越界")?.clone();
        let part = it.part_path(index);

        let mut existing = tokio::fs::metadata(&part).await.map(|m| m.len() as i64).unwrap_or(0);
        if seg.end >= 0 && existing > seg.length() {
            existing = seg.length();
        }
        self.update_downloaded(id, index, existing);
        if seg.end >= 0 && existing >= seg.length() {
            return Ok(()); // 该段已完成
        }

        let mut rb = self.client.get(&it.url);
        if it.supports_range {
            if seg.end >= 0 {
                rb = rb.header("Range", format!("bytes={}-{}", seg.start + existing, seg.end));
            } else if existing > 0 {
                rb = rb.header("Range", format!("bytes={existing}-"));
            }
        }
        let mut resp = rb.send().await.map_err(friendly_err)?;
        if resp.status().as_u16() >= 400 {
            return Err(status_err(resp.status().as_u16()));
        }

        let mut f = tokio::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&part)
            .await
            .map_err(|e| e.to_string())?;
        let mut downloaded = existing;
        loop {
            if cancel.load(Ordering::SeqCst) {
                return Err("已暂停".into());
            }
            match resp.chunk().await.map_err(friendly_err)? {
                Some(chunk) => {
                    f.write_all(&chunk).await.map_err(|e| e.to_string())?;
                    downloaded += chunk.len() as i64;
                    self.update_downloaded(id, index, downloaded);
                }
                None => break,
            }
        }
        f.flush().await.ok();
        Ok(())
    }

    // ---- 小工具 ----
    fn snapshot(&self, id: &str) -> Option<DownloadItem> {
        self.state.lock().unwrap().items.get(id).cloned()
    }
    fn write_segments(&self, id: &str, src: &DownloadItem) {
        let mut st = self.state.lock().unwrap();
        if let Some(it) = st.items.get_mut(id) {
            it.segments = src.segments.clone();
            it.recompute();
        }
    }
    fn update_downloaded(&self, id: &str, index: usize, val: i64) {
        let mut st = self.state.lock().unwrap();
        if let Some(it) = st.items.get_mut(id) {
            if let Some(seg) = it.segments.get_mut(index) {
                seg.downloaded = val;
            }
            it.recompute();
        }
    }

    fn persist_blocking(&self) {
        let me = self.clone();
        self.rt.spawn(async move { me.persist().await });
    }
    async fn persist(&self) {
        let (path, json) = {
            let st = self.state.lock().unwrap();
            let list: Vec<&DownloadItem> = st.items.values().collect();
            (st.index_path.clone(), serde_json::to_string(&list).unwrap_or_default())
        };
        let _ = tokio::fs::write(path, json).await;
    }
}

// ==================== 无状态辅助 ====================

async fn sync_segments_from_disk(item: &mut DownloadItem) {
    for i in 0..item.segments.len() {
        let part = item.part_path(i);
        let Ok(meta) = tokio::fs::metadata(&part).await else {
            continue;
        };
        let mut len = meta.len() as i64;
        let seg = &item.segments[i];
        // 分段文件超出区间长度(僵尸写入):截断避免拼接错位。
        if seg.end >= 0 && len > seg.length() {
            if let Ok(f) = tokio::fs::OpenOptions::new().write(true).open(&part).await {
                let _ = f.set_len(seg.length() as u64).await;
            }
            len = seg.length();
        }
        let seg = &mut item.segments[i];
        seg.downloaded = if seg.end >= 0 { len.clamp(0, seg.length()) } else { len };
    }
}

/// 探测文件大小与 Range 支持(Range bytes=0-0 → 206 + Content-Range)。
async fn probe(client: &reqwest::Client, url: &str) -> (i64, bool) {
    match client.get(url).header("Range", "bytes=0-0").send().await {
        Ok(resp) => {
            let status = resp.status().as_u16();
            let h = resp.headers();
            if status == 206 {
                if let Some(total) = h
                    .get("content-range")
                    .and_then(|v| v.to_str().ok())
                    .and_then(|s| s.rsplit('/').next())
                    .and_then(|s| s.trim().parse::<i64>().ok())
                {
                    return (total, true);
                }
            }
            let total = h
                .get("content-length")
                .and_then(|v| v.to_str().ok())
                .and_then(|s| s.parse::<i64>().ok())
                .unwrap_or(0);
            let supports = h
                .get("accept-ranges")
                .and_then(|v| v.to_str().ok())
                .map(|s| s.to_lowercase().contains("bytes"))
                .unwrap_or(false);
            (total, supports)
        }
        Err(_) => (0, false), // 探测失败:退回单线程未知大小
    }
}

fn build_segments(item: &mut DownloadItem, threads: usize) {
    let total = item.total_bytes;
    if total <= 0 || !item.supports_range {
        item.segments = vec![DownloadSegment { start: 0, end: -1, downloaded: 0 }];
        return;
    }
    // 小文件(<2MB)不分段。
    let n = if total < 2 * 1024 * 1024 { 1 } else { threads.clamp(1, 4) };
    let chunk = (total as usize).div_ceil(n) as i64;
    let mut segs = Vec::new();
    for i in 0..n {
        let start = i as i64 * chunk;
        if start >= total {
            break;
        }
        let end = if i == n - 1 { total - 1 } else { (start + chunk - 1).min(total - 1) };
        segs.push(DownloadSegment { start, end, downloaded: 0 });
    }
    item.segments = segs;
    item.recompute();
}

async fn assemble(item: &DownloadItem) -> std::io::Result<()> {
    let out_path = PathBuf::from(&item.file_path);
    let _ = tokio::fs::remove_file(&out_path).await;
    let mut out = tokio::fs::File::create(&out_path).await?;
    let mut buf = vec![0u8; 1 << 20];
    for i in 0..item.segments.len() {
        let part = item.part_path(i);
        if let Ok(mut f) = tokio::fs::File::open(&part).await {
            loop {
                let n = f.read(&mut buf).await?;
                if n == 0 {
                    break;
                }
                out.write_all(&buf[..n]).await?;
            }
        }
    }
    out.flush().await?;
    for i in 0..item.segments.len() {
        let _ = tokio::fs::remove_file(item.part_path(i)).await;
    }
    Ok(())
}

async fn delete_files(item: &DownloadItem) {
    let _ = tokio::fs::remove_file(&item.file_path).await;
    for i in 0..item.segments.len() {
        let _ = tokio::fs::remove_file(item.part_path(i)).await;
    }
}

fn friendly_err(e: reqwest::Error) -> String {
    if e.is_timeout() {
        "连接超时".into()
    } else if e.is_connect() {
        "网络连接失败".into()
    } else {
        "下载出错".into()
    }
}

fn status_err(code: u16) -> String {
    match code {
        401 | 403 => "无下载权限".into(),
        c => format!("服务器错误({c})"),
    }
}

fn safe_name(name: &str) -> String {
    let mut s: String = name
        .chars()
        .map(|c| if r#"\/:*?"<>|"#.contains(c) { '_' } else { c })
        .collect();
    s = s.trim().to_string();
    if s.chars().count() > 60 {
        s = s.chars().take(60).collect();
    }
    if s.is_empty() {
        "video".into()
    } else {
        s
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(total: i64, range: bool) -> DownloadItem {
        DownloadItem {
            id: "x".into(),
            item_id: "x".into(),
            media_source_id: None,
            type_: "Movie".into(),
            title: "t".into(),
            series_id: None,
            series_name: None,
            season_number: None,
            episode_number: None,
            poster_url: None,
            container: "mkv".into(),
            url: "http://x".into(),
            file_path: "x.mkv".into(),
            total_bytes: total,
            status: DownloadStatus::Queued,
            error: None,
            added_at: 0,
            supports_range: range,
            segments: vec![],
            received_bytes: 0,
            progress: 0.0,
        }
    }

    /* forget 与 remove 的分界是「清除已完成」这条命令的全部意义:
       remove 会 delete_files 把片子删了,forget 不能。这两个测试是那条分界线的护栏。 */

    async fn mgr_with_completed(dir: &std::path::Path, file: &std::path::Path) -> DownloadManager {
        tokio::fs::write(file, b"video").await.unwrap();
        let m = DownloadManager::new(dir.to_path_buf()).await;
        let mut it = item(5, false);
        it.id = "done1".into();
        it.status = DownloadStatus::Completed;
        it.file_path = file.to_string_lossy().into_owned();
        m.state.lock().unwrap().items.insert(it.id.clone(), it);
        m
    }

    #[tokio::test]
    async fn forget_drops_record_but_keeps_file() {
        let dir = std::env::temp_dir().join("lp_forget_keep");
        let _ = tokio::fs::remove_dir_all(&dir).await;
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let file = dir.join("keep.mkv");
        let m = mgr_with_completed(&dir, &file).await;

        assert!(m.forget("done1"), "已完成的条目应能被 forget");
        assert!(m.list().is_empty(), "记录应已清掉");
        /* 必须先等一会儿再断言:delete_files 是 spawn 出去的,立刻断言 exists() 会
           在 bug 存在时也「赢下竞态」而假绿 —— 这个 sleep 才是这条测试有效的原因。 */
        tokio::time::sleep(std::time::Duration::from_millis(300)).await;
        assert!(file.exists(), "forget 绝不能删已下好的文件");
    }

    #[tokio::test]
    async fn remove_deletes_file() {
        let dir = std::env::temp_dir().join("lp_forget_del");
        let _ = tokio::fs::remove_dir_all(&dir).await;
        tokio::fs::create_dir_all(&dir).await.unwrap();
        let file = dir.join("gone.mkv");
        let m = mgr_with_completed(&dir, &file).await;

        m.remove("done1");
        assert!(m.list().is_empty());
        // delete_files 是 spawn 出去的,给它落地的时间。
        for _ in 0..50 {
            if !file.exists() {
                break;
            }
            tokio::time::sleep(std::time::Duration::from_millis(20)).await;
        }
        assert!(!file.exists(), "remove 的既有语义就是连文件一起删,别改坏");
    }

    /* 回归:**写路径必须能在没有 tokio 上下文的线程上跑**。
       `download_enqueue`/`pause`/`resume`/`remove`/`clear_completed` 都是**同步**
       `#[tauri::command]`,tauri 在 IPC 线程上内联执行它们(WebView2 消息线程),
       那里没有 tokio 上下文。管理器内部一旦裸 `tokio::spawn` 就 panic,
       穿过 FFI 边界 = 进程直接没了(用户 2026-08-01:「一点下载整个软件卡死随后闪退」)。

       这条测试**故意不放在 #[tokio::test] 里** —— 那个宏会给测试线程建好上下文,
       bug 就永远复现不出来。必须是裸 std 线程,才和真实调用环境一致。
       反向验证:把 rt.spawn 改回 tokio::spawn,本测试立刻红(panic 在 join 里)。 */
    #[test]
    fn write_path_survives_outside_tokio_context() {
        // current_thread 就够:本测试断言的是 spawn **不 panic**,不是任务真跑完
        // (crates/core 只开了 tokio 的 "rt",没有 rt-multi-thread)。
        let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        let dir = std::env::temp_dir().join("lp_dl_no_ctx");
        let _ = std::fs::remove_dir_all(&dir);
        let m = rt.block_on(DownloadManager::new(dir.clone()));

        // 这条线程和 tauri 同步命令所处的环境一致:没有 tokio 上下文。
        let joined = std::thread::spawn(move || {
            let mut it = item(0, false);
            it.item_id = "no_ctx".into();
            m.enqueue(it); // → persist_blocking + process_queue,两处 spawn
            m.pause("no_ctx"); // → persist_blocking
            m.resume("no_ctx"); // → persist_blocking + process_queue
            m.forget("no_ctx"); // → persist_blocking
        })
        .join();

        assert!(
            joined.is_ok(),
            "写路径在无 tokio 上下文的线程上 panic 了 —— 同步 tauri 命令正是这个环境,\
             这一 panic 就是整个进程闪退"
        );
        // 运行时留到这里再落地:提前 drop 会把 spawn 出去的 persist 掐死,测出假绿。
        drop(rt);
    }

    #[test]
    fn segments_split_and_cover_full_range() {
        let mut it = item(100 * 1024 * 1024, true);
        build_segments(&mut it, 4);
        assert_eq!(it.segments.len(), 4);
        assert_eq!(it.segments[0].start, 0);
        assert_eq!(it.segments.last().unwrap().end, it.total_bytes - 1);
        // 无缝无叠。
        for w in it.segments.windows(2) {
            assert_eq!(w[0].end + 1, w[1].start);
        }
    }

    #[test]
    fn small_file_single_segment() {
        let mut it = item(1024 * 1024, true); // <2MB
        build_segments(&mut it, 4);
        assert_eq!(it.segments.len(), 1);
    }

    #[test]
    fn no_range_falls_back_to_stream() {
        let mut it = item(0, false);
        build_segments(&mut it, 4);
        assert_eq!(it.segments.len(), 1);
        assert_eq!(it.segments[0].end, -1);
    }

    #[test]
    fn safe_name_strips_and_truncates() {
        assert_eq!(safe_name("a/b:c"), "a_b_c");
        assert!(safe_name(&"x".repeat(100)).chars().count() <= 60);
        assert_eq!(safe_name("  "), "video");
    }
}
