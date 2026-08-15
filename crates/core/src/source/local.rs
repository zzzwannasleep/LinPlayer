// 本机文件夹。用户点「本地播放」→ 系统文件夹选择器挑一个目录 → 当成一个源接进来,
// 之后就和网盘/局域网源走**完全一样**的浏览页和播放链路。
//
// ## 为什么做成「源」而不是另开一套页面
// 一个能列目录、能把条目解析成可播地址的东西,正好就是 `MediaSourceBackend`。
// 做成源就白拿:文件浏览页、面包屑、搜索、播放、服务器列表里的一条、重启免登。
// 另开一套「本地播放页」等于把这些**再实现一遍**,还得再维护一遍。
//
// ## 交给 mpv 的是**裸路径**,不是 file:// URL
// 播放链路(`source_play`)最后一句是 `p.load_with_headers(&resolved.url, …)`,而 mpv
// 吃裸路径 —— 旁边的 `play_local` 一直就是直接把 `D:\片子\a.mkv` 喂进去的。
// 自己拼 file:// 反而要处理盘符、反斜杠、百分号编码三件事,每件都能拼错。
use super::{
    is_video_file_name, sort_entries, MediaSourceBackend, ResolvedPlay, SourceEntry, SourceError,
    SourceKind, SourceServer,
};
use std::collections::HashMap;
use std::path::{Path, PathBuf};

#[derive(Default)]
pub struct LocalBackend;

impl LocalBackend {
    pub fn new() -> Self {
        Self::default()
    }

    /// 把要访问的路径**关进用户选的那个根目录里**。
    ///
    /// ★ entry.id 是绝对路径,而前端可以把任意 id 传回来(浏览页的面包屑、历史记录、
    ///   将来某个手滑拼出来的路径)。不做这道闸,一个 `..` 就能从用户挑的「电影」
    ///   目录跑到整块硬盘上去 —— 这不是「反正是他自己的电脑」能糊弄过去的:
    ///   用户挑一个目录的动作本身就是在划范围。
    ///
    /// 用 canonicalize 而不是纯字符串比较:符号链接、`..`、大小写、Windows 的
    /// `\\?\` 前缀都得先归一,不然「看着在里面、实际在外面」照样能过。
    fn confine(root: &str, target: &Path) -> Result<PathBuf, SourceError> {
        let root = Path::new(root.trim());
        let root_real = root
            .canonicalize()
            .map_err(|e| SourceError::msg(format!("文件夹打不开({}): {e}", root.display())))?;
        let target_real = target
            .canonicalize()
            .map_err(|e| SourceError::msg(format!("路径打不开({}): {e}", target.display())))?;
        if !target_real.starts_with(&root_real) {
            return Err(SourceError::msg("这个路径不在你选的文件夹里"));
        }
        Ok(target_real)
    }

    /// 读一个目录。**单条读失败只跳过这一条**,不让整个目录列不出来 ——
    /// 一个权限不足的子目录不该把旁边二十部片子一起拖下水。
    async fn read(dir: &Path) -> Result<Vec<SourceEntry>, SourceError> {
        let mut rd = tokio::fs::read_dir(dir)
            .await
            .map_err(|e| SourceError::msg(format!("读不了这个文件夹: {e}")))?;
        let mut out = Vec::new();
        while let Ok(Some(ent)) = rd.next_entry().await {
            let name = ent.file_name().to_string_lossy().into_owned();
            // 隐藏文件/系统目录:列出来只是噪声(macOS 的 .DS_Store、Windows 的 System Volume Information)
            if name.starts_with('.') {
                continue;
            }
            let Ok(ft) = ent.file_type().await else { continue };
            // 符号链接按它指向的东西算(指向目录就当目录)。confine 那道闸会挡住指到外面去的。
            let is_dir = if ft.is_symlink() {
                tokio::fs::metadata(ent.path()).await.map(|m| m.is_dir()).unwrap_or(false)
            } else {
                ft.is_dir()
            };
            let size = if is_dir {
                None
            } else {
                ent.metadata().await.ok().map(|m| m.len() as i64).filter(|s| *s > 0)
            };
            out.push(SourceEntry {
                id: ent.path().to_string_lossy().into_owned(),
                is_video: !is_dir && is_video_file_name(&name),
                name,
                is_dir,
                size,
                thumb_url: None,
                raw: None,
            });
        }
        sort_entries(&mut out);
        Ok(out)
    }
}

#[async_trait::async_trait]
impl MediaSourceBackend for LocalBackend {
    fn kind(&self) -> SourceKind {
        SourceKind::local()
    }

    async fn list_dir(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        dir_id: Option<&str>,
    ) -> Result<Vec<SourceEntry>, SourceError> {
        let root = server.base_url.trim();
        if root.is_empty() {
            return Err(SourceError::msg("这个本地源没有记住文件夹路径"));
        }
        let want = PathBuf::from(dir_id.unwrap_or(root));
        let dir = Self::confine(root, &want)?;
        Self::read(&dir).await
    }

    async fn resolve_play(
        &self,
        _http: &reqwest::Client,
        server: &SourceServer,
        entry: &SourceEntry,
        _quality_id: Option<&str>,
    ) -> Result<ResolvedPlay, SourceError> {
        let path = Self::confine(&server.base_url, Path::new(&entry.id))?;
        if !path.is_file() {
            // 索引里有不代表文件还在(用户可能删了/挪走了/U盘拔了)。
            return Err(SourceError::msg(format!(
                "文件已不存在:{}",
                path.display()
            )));
        }
        Ok(ResolvedPlay::simple(
            path.to_string_lossy().into_owned(),
            entry.name.clone(),
            HashMap::new(),
        ))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// 造一棵临时目录树,返回根路径。
    ///
    /// ★ 每个测试**必须各用各的目录**。上一版用进程号当目录名,四条测试共用一棵树,
    ///   而 cargo 默认多线程并跑 —— 「删掉 movie.mkv 看报错」那条一动手,
    ///   正在列目录的那条当场少一个文件。红的是测试自己打架,不是被测代码有问题。
    fn tree(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("lp-local-{}-{tag}", std::process::id()));
        let _ = fs::remove_dir_all(&root);
        fs::create_dir_all(root.join("剧集/S01")).unwrap();
        fs::write(root.join("movie.mkv"), b"x").unwrap();
        fs::write(root.join("cover.jpg"), b"x").unwrap();
        fs::write(root.join(".hidden"), b"x").unwrap();
        fs::write(root.join("剧集/S01/ep1.mp4"), b"xx").unwrap();
        root
    }

    fn server(root: &Path) -> SourceServer {
        SourceServer {
            base_url: root.to_string_lossy().into_owned(),
            ..Default::default()
        }
    }

    #[tokio::test]
    async fn lists_root_dirs_first_and_marks_video() {
        let root = tree("list");
        let b = LocalBackend::new();
        let v = b.list_dir(&reqwest::Client::new(), &server(&root), None).await.unwrap();
        let names: Vec<_> = v.iter().map(|e| e.name.as_str()).collect();
        assert_eq!(names, vec!["剧集", "cover.jpg", "movie.mkv"], "目录要排在最前");
        assert!(!names.contains(&".hidden"), "隐藏文件不该列出来");
        let mkv = v.iter().find(|e| e.name == "movie.mkv").unwrap();
        assert!(mkv.is_video && !mkv.is_dir && mkv.size == Some(1));
        assert!(!v.iter().find(|e| e.name == "cover.jpg").unwrap().is_video);
        let _ = fs::remove_dir_all(&root);
    }

    /// 点进子目录:拿上一层给的 id 直接回传,必须能列出来。
    #[tokio::test]
    async fn descends_into_subdirectory() {
        let root = tree("descend");
        let b = LocalBackend::new();
        let sv = server(&root);
        let top = b.list_dir(&reqwest::Client::new(), &sv, None).await.unwrap();
        let sub = top.iter().find(|e| e.name == "剧集").unwrap();
        let lvl2 = b.list_dir(&reqwest::Client::new(), &sv, Some(&sub.id)).await.unwrap();
        assert_eq!(lvl2.len(), 1, "S01 没列出来");
        let lvl3 = b.list_dir(&reqwest::Client::new(), &sv, Some(&lvl2[0].id)).await.unwrap();
        assert_eq!(lvl3[0].name, "ep1.mp4");
        assert!(lvl3[0].is_video);
        let _ = fs::remove_dir_all(&root);
    }

    /// ★ 越狱闸。用户挑的是「某个文件夹」,不是「整块硬盘」——
    /// 一个 `..` 就能爬出去的话,这个选择动作等于没划范围。
    #[tokio::test]
    async fn cannot_escape_the_chosen_folder() {
        let root = tree("escape");
        let b = LocalBackend::new();
        let sv = server(&root);
        let outside = root.join("..").to_string_lossy().into_owned();
        // SourceEntry 没有 Debug,用不了 expect_err
        let Err(e) = b.list_dir(&reqwest::Client::new(), &sv, Some(&outside)).await else {
            panic!("`..` 爬到上层去了 —— 越狱闸没关住");
        };
        assert!(e.message.contains("不在你选的文件夹里"), "报的是: {}", e.message);
        let _ = fs::remove_dir_all(&root);
    }

    /// 播放解析:给出去的必须是**裸路径**(mpv 吃它),而且要确认文件还在。
    #[tokio::test]
    async fn resolves_to_a_bare_path_and_checks_existence() {
        let root = tree("resolve");
        let b = LocalBackend::new();
        let sv = server(&root);
        let mkv = root.join("movie.mkv").to_string_lossy().into_owned();
        let entry = SourceEntry {
            id: mkv.clone(), name: "movie.mkv".into(), is_dir: false, is_video: true,
            size: None, thumb_url: None, raw: None,
        };
        let r = b.resolve_play(&reqwest::Client::new(), &sv, &entry, None).await.unwrap();
        assert!(!r.url.starts_with("file://"), "拼了 file:// —— mpv 要的是裸路径");
        assert!(r.url.ends_with("movie.mkv"));
        assert!(r.http_headers.is_empty(), "本地文件不该带任何 HTTP 头");

        // 文件被删掉后要报「文件已不存在」,而不是把一个死路径丢给 mpv 让它黑屏
        fs::remove_file(root.join("movie.mkv")).unwrap();
        let Err(e) = b.resolve_play(&reqwest::Client::new(), &sv, &entry, None).await else {
            panic!("文件都没了还解析成功");
        };
        assert!(e.message.contains("不存在") || e.message.contains("打不开"), "报的是: {}", e.message);
        let _ = fs::remove_dir_all(&root);
    }

    /// 文件夹被删/U盘拔了:要给一句人话,而不是一路 unwrap 崩掉。
    #[tokio::test]
    async fn missing_root_reports_cleanly() {
        let b = LocalBackend::new();
        let sv = SourceServer {
            base_url: std::env::temp_dir().join("lp-does-not-exist-xyz").to_string_lossy().into_owned(),
            ..Default::default()
        };
        let Err(e) = b.list_dir(&reqwest::Client::new(), &sv, None).await else {
            panic!("不存在的文件夹居然列成功了");
        };
        assert!(e.message.contains("打不开"), "报的是: {}", e.message);
    }
}
