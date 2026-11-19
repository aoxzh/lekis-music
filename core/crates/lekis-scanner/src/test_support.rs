//! 测试用的假 VFS（只在 `cfg(test)` 下编译）。

// 测试基础设施：这里用 unwrap / expect / panic 表达"前提不成立就是测试 bug"，是仓库约定。
#![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

use async_trait::async_trait;
use bytes::Bytes;
use lekis_types::{ErrorCode, LekisError, Result, SourceKind};
use lekis_vfs::{DirEntry, EntryKind, FileMeta, Vfs, VfsCapabilities, VfsPath};
use std::collections::{BTreeMap, BTreeSet};
use std::ops::Range;
use std::sync::{Arc, Mutex};

/// 内存目录树。目录、文件、mtime 都在内存里，可以注入 `list_dir` / `stat` 错误。
///
/// 克隆出来的是**同一个**树（内部状态共享），所以 `scan` 之后还能在原对象上断言调用记录。
#[derive(Clone)]
pub struct FakeVfs {
    caps: VfsCapabilities,
    files: Arc<Mutex<BTreeMap<String, (u64, i64)>>>,
    dirs: Arc<Mutex<BTreeSet<String>>>,
    dir_mtime: Arc<Mutex<BTreeMap<String, i64>>>,
    list_errors: Arc<Mutex<BTreeSet<String>>>,
    stat_errors: Arc<Mutex<BTreeSet<String>>>,
    list_calls: Arc<Mutex<Vec<String>>>,
    next_mtime: Arc<Mutex<i64>>,
}

impl FakeVfs {
    /// 按给定能力位创建。
    pub fn new(caps: VfsCapabilities) -> Self {
        Self {
            caps,
            files: Arc::new(Mutex::new(BTreeMap::new())),
            dirs: Arc::new(Mutex::new(BTreeSet::new())),
            dir_mtime: Arc::new(Mutex::new(BTreeMap::new())),
            list_errors: Arc::new(Mutex::new(BTreeSet::new())),
            stat_errors: Arc::new(Mutex::new(BTreeSet::new())),
            list_calls: Arc::new(Mutex::new(Vec::new())),
            next_mtime: Arc::new(Mutex::new(1_000)),
        }
    }

    /// 本地文件系统那样的默认能力位。
    pub fn local_like() -> Self {
        Self::new(VfsCapabilities {
            writable: true,
            watch: false,
            reliable_dir_mtime: true,
            suggested_concurrency: 8,
        })
    }

    /// 只读共享：`writable == false`。
    pub fn read_only() -> Self {
        Self::new(VfsCapabilities {
            writable: false,
            watch: false,
            reliable_dir_mtime: true,
            suggested_concurrency: 4,
        })
    }

    fn tick(&self) -> i64 {
        let mut n = self.next_mtime.lock().expect("fake vfs poisoned");
        *n += 1;
        *n
    }

    /// 加一个目录（连同所有祖先）。
    pub fn add_dir(&self, path: &str) {
        self.dirs
            .lock()
            .expect("fake vfs poisoned")
            .insert(path.to_string());
        let mtime = self.tick();
        self.dir_mtime
            .lock()
            .expect("fake vfs poisoned")
            .entry(path.to_string())
            .or_insert(mtime);
        if let Some(parent) = parent_of(path) {
            if !parent.is_empty() && !self.dirs.lock().expect("poisoned").contains(parent) {
                self.add_dir(parent);
            }
        }
    }

    /// 加一个文件。
    pub fn add_file(&self, path: &str, size: u64, mtime_ms: i64) {
        if let Some(parent) = parent_of(path) {
            if !parent.is_empty() {
                self.add_dir(parent);
            }
        }
        self.files
            .lock()
            .expect("fake vfs poisoned")
            .insert(path.to_string(), (size, mtime_ms));
    }

    /// 删掉一个文件（模拟用户在磁盘上删了歌）。
    pub fn remove_file(&self, path: &str) {
        self.files.lock().expect("fake vfs poisoned").remove(path);
    }

    /// 改文件大小（模拟文件被替换）。
    pub fn set_file_size(&self, path: &str, size: u64) {
        let mut files = self.files.lock().expect("fake vfs poisoned");
        let mtime = files.get(path).map(|(_, m)| *m).unwrap_or(0);
        files.insert(path.to_string(), (size, mtime));
    }

    /// 改文件 mtime。
    pub fn set_file_mtime(&self, path: &str, mtime_ms: i64) {
        let mut files = self.files.lock().expect("fake vfs poisoned");
        let size = files.get(path).map(|(s, _)| *s).unwrap_or(0);
        files.insert(path.to_string(), (size, mtime_ms));
    }

    /// 手动设置目录 mtime。
    pub fn set_dir_mtime(&self, path: &str, mtime_ms: i64) {
        self.add_dir(path);
        self.dir_mtime
            .lock()
            .expect("fake vfs poisoned")
            .insert(path.to_string(), mtime_ms);
    }

    /// 读目录 mtime（测试里用来构造 `PreviousScan`）。
    pub fn dir_mtime(&self, path: &str) -> i64 {
        self.dir_mtime
            .lock()
            .expect("fake vfs poisoned")
            .get(path)
            .copied()
            .unwrap_or(0)
    }

    /// 让某个目录的 `list_dir` 失败（空字符串表示根目录）。
    pub fn set_list_error(&self, path: &str) {
        self.list_errors
            .lock()
            .expect("fake vfs poisoned")
            .insert(path.to_string());
    }

    /// 让某个目录的 `stat` 失败。
    pub fn set_stat_error(&self, path: &str) {
        self.stat_errors
            .lock()
            .expect("fake vfs poisoned")
            .insert(path.to_string());
    }

    /// 清掉所有注入的错误。
    pub fn clear_errors(&self) {
        self.list_errors.lock().expect("poisoned").clear();
        self.stat_errors.lock().expect("poisoned").clear();
    }

    /// 到目前为止 `list_dir` 被调用的目录（按调用顺序）。
    pub fn list_calls(&self) -> Vec<String> {
        self.list_calls.lock().expect("poisoned").clone()
    }
}

/// 父目录（根目录的空字符串没有父目录）。
fn parent_of(path: &str) -> Option<&str> {
    if path.is_empty() {
        return None;
    }
    Some(match path.rsplit_once('/') {
        Some((parent, _)) => parent,
        None => "",
    })
}

fn base_of(path: &str) -> &str {
    path.rsplit('/').next().unwrap_or(path)
}

fn child_path(dir: &str, name: &str) -> String {
    if dir.is_empty() {
        name.to_string()
    } else {
        format!("{dir}/{name}")
    }
}

fn not_found(what: &str) -> LekisError {
    LekisError::new(ErrorCode::NotFound, format!("fake vfs: not found: {what}"))
}

#[async_trait]
impl Vfs for FakeVfs {
    fn kind(&self) -> SourceKind {
        SourceKind::Local
    }

    fn capabilities(&self) -> VfsCapabilities {
        self.caps
    }

    async fn list_dir(&self, dir: &VfsPath) -> Result<Vec<DirEntry>> {
        let dir_str = dir.as_str();
        self.list_calls
            .lock()
            .expect("fake vfs poisoned")
            .push(dir_str.to_string());
        if self
            .list_errors
            .lock()
            .expect("fake vfs poisoned")
            .contains(dir_str)
        {
            return Err(not_found(dir_str));
        }
        if !dir.is_root() && !self.dirs.lock().expect("poisoned").contains(dir_str) {
            return Err(not_found(dir_str));
        }

        let mut out = Vec::new();
        for child in self.dirs.lock().expect("poisoned").iter() {
            if child.is_empty() || parent_of(child) != Some(dir_str) {
                continue;
            }
            out.push(DirEntry {
                path: VfsPath::parse(child).ok_or_else(|| not_found(child))?,
                meta: FileMeta {
                    kind: EntryKind::Dir,
                    size: 0,
                    mtime_ms: self.dir_mtime(child),
                },
            });
        }
        for (path, (size, mtime_ms)) in self.files.lock().expect("poisoned").iter() {
            if parent_of(path) != Some(dir_str) {
                continue;
            }
            out.push(DirEntry {
                path: VfsPath::parse(path).ok_or_else(|| not_found(path))?,
                meta: FileMeta {
                    kind: EntryKind::File,
                    size: *size,
                    mtime_ms: *mtime_ms,
                },
            });
        }
        out.sort_by(|a, b| a.path.cmp(&b.path));
        Ok(out)
    }

    async fn stat(&self, path: &VfsPath) -> Result<FileMeta> {
        let key = path.as_str().to_string();
        if self.stat_errors.lock().expect("poisoned").contains(&key) {
            return Err(not_found(&key));
        }
        if key.is_empty() || self.dirs.lock().expect("poisoned").contains(&key) {
            return Ok(FileMeta {
                kind: EntryKind::Dir,
                size: 0,
                mtime_ms: self.dir_mtime(&key),
            });
        }
        if let Some((size, mtime_ms)) = self.files.lock().expect("poisoned").get(&key) {
            return Ok(FileMeta {
                kind: EntryKind::File,
                size: *size,
                mtime_ms: *mtime_ms,
            });
        }
        Err(not_found(&key))
    }

    async fn read_range(&self, path: &VfsPath, range: Range<u64>) -> Result<Bytes> {
        if range.end < range.start {
            return Err(LekisError::invalid("range end < start"));
        }
        let key = path.as_str().to_string();
        let size = self
            .files
            .lock()
            .expect("poisoned")
            .get(&key)
            .map(|(s, _)| *s)
            .ok_or_else(|| not_found(&key))?;
        let start = range.start.min(size);
        let end = range.end.min(size);
        Ok(Bytes::from(vec![0u8; (end - start) as usize]))
    }

    async fn write_atomic(&self, path: &VfsPath, data: Bytes) -> Result<()> {
        if !self.caps.writable {
            return Err(LekisError::new(
                ErrorCode::PermissionDenied,
                format!("fake vfs is read-only: {path}"),
            ));
        }
        let key = path.as_str().to_string();
        if let Some(parent) = parent_of(&key) {
            if !parent.is_empty() && !self.dirs.lock().expect("poisoned").contains(parent) {
                return Err(not_found(parent));
            }
        }
        let mtime = self.next_mtime.lock().expect("poisoned").wrapping_add(1);
        self.files
            .lock()
            .expect("poisoned")
            .insert(key, (data.len() as u64, mtime));
        Ok(())
    }

    async fn create_dir_all(&self, dir: &VfsPath) -> Result<()> {
        if !self.caps.writable {
            return Err(LekisError::new(
                ErrorCode::PermissionDenied,
                format!("fake vfs is read-only: {dir}"),
            ));
        }
        let key = dir.as_str().to_string();
        if key.is_empty() {
            return Ok(());
        }
        // 逐段建目录，和 `create_dir_all` 语义一致。
        let mut prefix = String::new();
        for part in key.split('/').filter(|s| !s.is_empty()) {
            prefix = child_path(&prefix, part);
            self.add_dir(&prefix);
        }
        Ok(())
    }
}

/// 数调用次数的假标签读取器：每次 `read` 返回一个以文件名当标题的标签。
pub struct CountingTagReader {
    calls: std::sync::atomic::AtomicUsize,
}

impl CountingTagReader {
    /// 新建，计数器从 0 开始。
    pub fn new() -> Self {
        Self {
            calls: std::sync::atomic::AtomicUsize::new(0),
        }
    }

    /// 到目前为止 `read` 被调用的次数。
    pub fn calls(&self) -> usize {
        self.calls.load(std::sync::atomic::Ordering::SeqCst)
    }
}

impl Default for CountingTagReader {
    fn default() -> Self {
        Self::new()
    }
}

impl crate::tags::TagReader for CountingTagReader {
    fn read(
        &self,
        path: &VfsPath,
        _data: &lekis_vfs::partial::PartialFile,
    ) -> Result<lekis_library::ScannedTags> {
        self.calls.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        let title = stem(path.as_str());
        Ok(lekis_library::ScannedTags {
            title,
            artists: vec!["测试艺人".into()],
            album: Some("测试专辑".into()),
            duration_ms: 1_000,
            ..Default::default()
        })
    }
}

/// 总是失败的标签读取器。
pub struct FailingTagReader;

impl crate::tags::TagReader for FailingTagReader {
    fn read(
        &self,
        path: &VfsPath,
        _data: &lekis_vfs::partial::PartialFile,
    ) -> Result<lekis_library::ScannedTags> {
        Err(not_found(&format!("no tags in {path}")))
    }
}

/// 把 `VfsPath` 的字符串形式转成路径列表（排序后），方便断言。
pub fn path_strings(paths: impl IntoIterator<Item = VfsPath>) -> Vec<String> {
    let mut out: Vec<String> = paths.into_iter().map(|p| p.as_str().to_string()).collect();
    out.sort();
    out
}

/// 从文件名取茎（`a/b.flac` → `b`），测试里当标题用。
pub fn stem(path: &str) -> String {
    let name = base_of(path);
    match name.rsplit_once('.') {
        Some((stem, _)) => stem.to_string(),
        None => name.to_string(),
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;

    #[tokio::test]
    async fn fake_vfs_tree_roundtrip() {
        let vfs = FakeVfs::local_like();
        vfs.add_dir("a/b");
        vfs.add_file("a/b/c.flac", 5, 7);
        vfs.add_file("root.flac", 3, 9);

        let root = vfs.list_dir(&VfsPath::root()).await.unwrap();
        assert_eq!(
            root.iter()
                .map(|e| e.path.as_str().to_string())
                .collect::<Vec<_>>(),
            vec!["a".to_string(), "root.flac".to_string()]
        );
        let ab = vfs.list_dir(&VfsPath::parse("a/b").unwrap()).await.unwrap();
        assert_eq!(ab.len(), 1);
        assert_eq!(ab[0].meta.size, 5);
        assert_eq!(ab[0].meta.mtime_ms, 7);

        let meta = vfs
            .stat(&VfsPath::parse("root.flac").unwrap())
            .await
            .unwrap();
        assert_eq!(meta.kind, EntryKind::File);
        assert_eq!(stem("a/b/c.flac"), "c");
    }

    #[tokio::test]
    async fn fake_vfs_read_only_and_errors() {
        let vfs = FakeVfs::read_only();
        vfs.add_file("x.flac", 1, 1);
        vfs.set_list_error("bad");
        assert!(vfs.list_dir(&VfsPath::parse("bad").unwrap()).await.is_err());
        assert!(vfs
            .write_atomic(&VfsPath::parse("y").unwrap(), Bytes::from_static(b"1"))
            .await
            .is_err());
        assert_eq!(
            path_strings([VfsPath::parse("b").unwrap(), VfsPath::parse("a").unwrap()]),
            vec!["a".to_string(), "b".to_string()]
        );
    }
}
