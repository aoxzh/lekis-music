//! 扫描流水线（REQUIREMENTS 3.2 节，LIB-01~13）。
//!
//! ```text
//! walk（遍历目录，收集音频文件）
//!   → read_head_tail（每个文件只读头尾）
//!   → TagReader（解析标签；失败时用文件名兜底）
//!   → Library::upsert_scanned（每 BATCH_SIZE 条一个事务）
//!   → remove_unseen_files（清理已经删除的文件）
//!   → shared_index（写 NAS 共享索引，可选）
//! ```
//!
//! - **LIB-03**：遍历按 `VfsCapabilities::suggested_concurrency` 并发列目录（见 [`walk`]）。
//! - **LIB-04**：增量扫描 [`Scanner::scan_incremental`]——目录 mtime 没变就跳过整个子树；
//!   文件 `size` + `mtime` 没变就跳过读标签，只 touch 一下 `last_seen_at`。
//! - **LIB-05**：NAS 共享索引读写（见 [`shared_index`]），由 [`Scanner::write_shared_index`] 落盘；
//!   扫描前可用 [`shared_index::load_previous_scan`] 得出一份 [`PreviousScan`]。

pub mod shared_index;
pub mod tags;
#[cfg(test)]
mod test_support;
mod walk;

use lekis_library::{Library, ScannedFile, ScannedTags};
use lekis_types::{now_ms, CoreEvent, Result, ScanPhase, SourceId};
use lekis_vfs::{partial, Vfs};
use std::collections::HashMap;
use std::sync::Arc;
use tags::TagReader;

pub use walk::{walk_audio_files, walk_source, FoundFile, WalkOutcome};

/// 每个事务写入的文件数。
pub const BATCH_SIZE: usize = 500;

/// 扫描进度回调。会在扫描任务的线程上调用，实现方不能阻塞。
pub type ProgressFn = Arc<dyn Fn(CoreEvent) + Send + Sync>;

/// 扫描结果统计。
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct ScanReport {
    /// 新增。
    pub added: u64,
    /// 更新。
    pub updated: u64,
    /// 删除。
    pub removed: u64,
    /// 标签解析失败、用文件名兜底的文件数。
    pub fallback: u64,
}

/// 上一次扫描的摘要（来自本地库或 NAS 共享索引）。
///
/// 键是 [`lekis_vfs::VfsPath::as_str`]（不带开头的 `/`，和 `file.path` 存的一致）。
#[derive(Debug, Clone, Default)]
pub struct PreviousScan {
    /// 路径 → (size, mtime_ms)。
    pub files: HashMap<String, (u64, i64)>,
    /// 目录 → 目录 mtime（只对 `reliable_dir_mtime` 的 Vfs 有效）。
    pub dirs: HashMap<String, i64>,
}

impl PreviousScan {
    /// 空摘要。
    pub fn new() -> Self {
        Self::default()
    }

    /// 记录一个文件。
    pub fn insert_file(&mut self, path: impl Into<String>, size: u64, mtime_ms: i64) {
        self.files.insert(path.into(), (size, mtime_ms));
    }

    /// 记录一个目录的 mtime。
    pub fn insert_dir(&mut self, path: impl Into<String>, mtime_ms: i64) {
        self.dirs.insert(path.into(), mtime_ms);
    }

    /// 记录了多少个文件。
    pub fn len(&self) -> usize {
        self.files.len()
    }

    /// 是不是没有任何文件记录。
    pub fn is_empty(&self) -> bool {
        self.files.is_empty()
    }
}

/// 扫描器。
pub struct Scanner {
    library: Library,
    tag_reader: Arc<dyn TagReader>,
    device_id: String,
}

impl Scanner {
    /// 创建扫描器。
    pub fn new(library: Library, tag_reader: Arc<dyn TagReader>) -> Self {
        Self {
            library,
            tag_reader,
            device_id: "unknown".into(),
        }
    }

    /// 设置写共享索引时记录的本机设备 ID（`ShardHeader::written_by`）。
    pub fn with_device_id(mut self, device_id: impl Into<String>) -> Self {
        self.device_id = device_id.into();
        self
    }

    /// 资料库句柄。
    pub fn library(&self) -> &Library {
        &self.library
    }

    /// 完整扫描一个音源（等价于 `previous = None` 的增量扫描）。
    pub async fn scan(
        &self,
        source_id: SourceId,
        vfs: Arc<dyn Vfs>,
        progress: ProgressFn,
    ) -> Result<ScanReport> {
        self.scan_incremental(source_id, vfs, progress, None).await
    }

    /// 增量扫描一个音源（LIB-04）。
    ///
    /// `previous` 给出上一次扫描的摘要时：
    /// - 目录 mtime 没变的子树完全不 `list_dir`；
    /// - `size` + `mtime` 都没变的文件不读标签，只把 `last_seen_at` 刷新到当前时间
    ///   （否则会被 [`Library::remove_unseen_files`] 当成已删除）。
    ///
    /// 如果这些"没变"的文件在本地库里并没有对应行（例如摘要来自别的设备写的共享索引），
    /// 会退回成读标签，保证文件能真正入库。
    pub async fn scan_incremental(
        &self,
        source_id: SourceId,
        vfs: Arc<dyn Vfs>,
        progress: ProgressFn,
        previous: Option<&PreviousScan>,
    ) -> Result<ScanReport> {
        let started_at = now_ms();
        progress(CoreEvent::ScanProgress {
            source_id,
            phase: ScanPhase::Walking,
            done: 0,
            total: None,
        });

        let outcome = walk::walk_source(vfs.as_ref(), previous).await?;
        let total = outcome.len() as u64;
        tracing::info!(
            target: "scanner",
            %source_id,
            total,
            changed = outcome.changed.len(),
            unchanged = outcome.unchanged.len(),
            "walk finished"
        );

        let mut report = ScanReport::default();
        let mut files = outcome.changed;
        let mut outcome_unchanged = outcome.unchanged;

        // 上次只用文件名兜底的文件（时长 0）不复用，再读一次标签：旧版扫描器
        // 读不了内嵌大封面的文件，升级后要靠这一步自愈。真读不出来的文件每次
        // 扫描都会重试一下，数量很少，代价只是一次头尾读取。
        match self.library.zero_duration_paths(source_id).await {
            Ok(paths) if !paths.is_empty() => {
                let suspects: std::collections::HashSet<String> = paths.into_iter().collect();
                let (retry, keep): (Vec<_>, Vec<_>) = outcome_unchanged
                    .into_iter()
                    .partition(|f| suspects.contains(f.path.as_str()));
                if !retry.is_empty() {
                    tracing::info!(target: "scanner", %source_id, count = retry.len(), "re-reading files that only had file-name tags");
                    files.extend(retry);
                    files.sort_by(|a, b| a.path.cmp(&b.path));
                }
                outcome_unchanged = keep;
            }
            Ok(_) => {}
            Err(e) => {
                tracing::warn!(target: "scanner", %source_id, error = %e, "zero-duration lookup failed");
            }
        }

        // 复用上一次的标签：只 refresh last_seen_at，不读文件。
        if !outcome_unchanged.is_empty() {
            let reuse: Vec<(String, u64, i64)> = outcome_unchanged
                .iter()
                .map(|f| (f.path.as_str().to_string(), f.size, f.mtime_ms))
                .collect();
            let expected = reuse.len() as u64;
            let touched = self.library.touch_files(source_id, reuse).await?;
            if touched == expected {
                tracing::debug!(
                    target: "scanner",
                    %source_id,
                    reused = touched,
                    "reused tags for unchanged files"
                );
            } else {
                // 库里没有这些文件（共享索引来自别的设备、或者本地库被重建过）：
                // 必须真读一次标签，否则它们永远进不了库。
                tracing::info!(
                    target: "scanner",
                    %source_id,
                    expected,
                    touched,
                    "some unchanged files have no row in the library, reading their tags"
                );
                files.extend(outcome_unchanged);
                files.sort_by(|a, b| a.path.cmp(&b.path));
            }
        }

        let mut batch = Vec::with_capacity(BATCH_SIZE);
        for (i, found) in files.into_iter().enumerate() {
            let tags = match self.read_tags(vfs.as_ref(), &found).await {
                Ok(t) => t,
                // 明确不是音频（AppleDouble 资源分叉之类）：不入库，也不拿文件名兜底，
                // 否则列表里会多出一首时长 0 的"同名歌"。旧的兜底行扫描结束时按未见清掉。
                Err(e) if e.code == lekis_types::ErrorCode::Unsupported => {
                    tracing::debug!(target: "scanner", path = %found.path, error = %e, "not audio, skipped");
                    continue;
                }
                Err(e) => {
                    tracing::debug!(target: "scanner", path = %found.path, error = %e, "tag read failed, using file name");
                    report.fallback += 1;
                    tags::tags_from_file_name(&found.path)
                }
            };
            batch.push(ScannedFile {
                source_id,
                path: found.path.as_str().to_string(),
                size: found.size,
                mtime_ms: found.mtime_ms,
                tags,
            });
            if batch.len() >= BATCH_SIZE {
                self.flush(&mut batch, &mut report).await?;
                progress(CoreEvent::ScanProgress {
                    source_id,
                    phase: ScanPhase::ReadingTags,
                    done: i as u64 + 1,
                    total: Some(total),
                });
            }
        }
        self.flush(&mut batch, &mut report).await?;

        report.removed = self
            .library
            .remove_unseen_files(source_id, started_at)
            .await?;
        self.library.mark_scanned(source_id).await?;
        progress(CoreEvent::ScanFinished {
            source_id,
            added: report.added,
            updated: report.updated,
            removed: report.removed,
        });
        Ok(report)
    }

    /// 把库里该音源的文件按目录分组写成 NAS 共享索引分片（LIB-05），返回写成功的分片数。
    ///
    /// 共享只读时返回 0（索引是可选加速手段，不是错误）。`scan()` 不会自动调用它——
    /// 由 `lekis-core` 按设置项决定写不写，避免每次扫描都动共享目录。
    pub async fn write_shared_index(&self, source_id: SourceId, vfs: Arc<dyn Vfs>) -> Result<u64> {
        if !vfs.capabilities().writable {
            tracing::debug!(
                target: "scanner",
                %source_id,
                "shared index is read-only, skipping"
            );
            return Ok(0);
        }
        let files = self.library.scannable_files(source_id).await?;
        shared_index::write_source_index(vfs.as_ref(), &self.device_id, &files).await
    }

    async fn read_tags(&self, vfs: &dyn Vfs, found: &FoundFile) -> Result<ScannedTags> {
        let mut head = partial::DEFAULT_HEAD;
        let mut tail = partial::DEFAULT_TAIL;
        // 第一次只读头尾；元数据比窗口大（内嵌大封面）时按容器结构补读，
        // 最多再来两轮（块头可能要读到才知道下一块多长）。
        for attempt in 0..3 {
            let data = partial::read_head_tail(vfs, &found.path, found.size, head, tail).await?;
            let reader = self.tag_reader.clone();
            let path = found.path.clone();
            // 标签解析是 CPU 密集的同步代码，不能在 async 任务里直接跑。
            let (result, data) = tokio::task::spawn_blocking(move || {
                let result = reader.read(&path, &data);
                (result, data)
            })
            .await
            .map_err(|e| lekis_types::LekisError::internal(format!("tag task: {e}")))?;
            match result {
                Ok(tags) => return Ok(tags),
                Err(e) => match tags::wanted_window(&data) {
                    Some(wanted) if attempt < 2 => {
                        tracing::debug!(
                            target: "scanner",
                            path = %found.path,
                            head = wanted.head,
                            tail = wanted.tail,
                            "metadata larger than the read window, reading more"
                        );
                        head = wanted.head;
                        tail = wanted.tail;
                    }
                    _ => return Err(e),
                },
            }
        }
        Err(lekis_types::LekisError::internal("unreachable tag retry"))
    }

    async fn flush(&self, batch: &mut Vec<ScannedFile>, report: &mut ScanReport) -> Result<()> {
        if batch.is_empty() {
            return Ok(());
        }
        let stats = self.library.upsert_scanned(std::mem::take(batch)).await?;
        report.added += stats.added;
        report.updated += stats.updated;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use crate::test_support::{CountingTagReader, FailingTagReader, FakeVfs};
    use lekis_types::{CoreEvent, SourceConfig, SourceKind};
    use std::collections::BTreeMap;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    /// 临时库目录，`Drop` 时删掉。
    struct TempLibrary {
        dir: PathBuf,
        library: Library,
    }

    impl TempLibrary {
        fn new(tag: &str) -> Self {
            let dir = std::env::temp_dir().join(format!(
                "lekis-scanner-{tag}-{}-{}",
                std::process::id(),
                now_ms()
            ));
            std::fs::create_dir_all(&dir).unwrap();
            let library = Library::open(&dir.join("library.sqlite")).unwrap();
            Self { dir, library }
        }

        async fn add_source(&self) -> SourceId {
            self.library
                .add_source(SourceConfig {
                    id: None,
                    kind: SourceKind::Local,
                    name: "Music".into(),
                    addresses: vec![],
                    root_path: String::new(),
                    credential_ref: None,
                    options: BTreeMap::new(),
                    enabled: true,
                })
                .await
                .unwrap()
        }
    }

    impl Drop for TempLibrary {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.dir);
        }
    }

    fn noop_progress() -> ProgressFn {
        Arc::new(|_e: CoreEvent| {})
    }

    /// 全量扫描：两个文件，都调用了一次标签读取，`added == 2`。
    #[tokio::test]
    async fn full_scan_reads_every_file() {
        let tmp = TempLibrary::new("full");
        let source_id = tmp.add_source().await;
        let reader = Arc::new(CountingTagReader::new());
        let scanner = Scanner::new(tmp.library.clone(), reader.clone());

        let vfs = FakeVfs::local_like();
        vfs.add_file("a/one.flac", 10, 100);
        vfs.add_file("a/two.flac", 20, 200);

        let report = scanner
            .scan(source_id, Arc::new(vfs), noop_progress())
            .await
            .unwrap();
        assert_eq!(
            report,
            ScanReport {
                added: 2,
                updated: 0,
                removed: 0,
                fallback: 0,
            }
        );
        assert_eq!(reader.calls(), 2);
        assert_eq!(tmp.library.track_count().await.unwrap(), 2);
    }

    /// 什么都没变：不读标签（0 次），不新增/更新/删除。
    #[tokio::test]
    async fn incremental_scan_without_changes_reads_no_tags() {
        let tmp = TempLibrary::new("incremental");
        let source_id = tmp.add_source().await;
        let reader = Arc::new(CountingTagReader::new());
        let scanner = Scanner::new(tmp.library.clone(), reader.clone());

        let vfs = FakeVfs::local_like();
        vfs.add_file("a/one.flac", 10, 100);
        vfs.add_file("a/two.flac", 20, 200);
        let first = scanner
            .scan(source_id, Arc::new(vfs.clone()), noop_progress())
            .await
            .unwrap();
        assert_eq!(first.added, 2);
        assert_eq!(reader.calls(), 2);

        // 第二次带上前一次的摘要
        let mut previous = PreviousScan::new();
        previous.insert_file("a/one.flac", 10, 100);
        previous.insert_file("a/two.flac", 20, 200);
        let second = scanner
            .scan_incremental(
                source_id,
                Arc::new(vfs.clone()),
                noop_progress(),
                Some(&previous),
            )
            .await
            .unwrap();
        assert_eq!(
            second,
            ScanReport {
                added: 0,
                updated: 0,
                removed: 0,
                fallback: 0,
            }
        );
        assert_eq!(reader.calls(), 2, "unchanged files must not be re-read");
        // 目录级复用：目录 mtime 没记录时仍会列目录，但文件级复用生效
        assert_eq!(tmp.library.track_count().await.unwrap(), 2);
    }

    /// 上次只能用文件名兜底的文件（时长 0）：文件没变也要重读，而且重读后
    /// 不能留下旧的兜底曲目（同一个文件不能挂两首歌）。
    #[tokio::test]
    async fn file_name_fallbacks_are_reread_and_replaced() {
        let tmp = TempLibrary::new("fallback-heal");
        let source_id = tmp.add_source().await;
        let vfs = FakeVfs::local_like();
        vfs.add_file("a/one.mp3", 10, 100);
        vfs.add_file("a/two.mp3", 20, 200);

        let broken = Scanner::new(tmp.library.clone(), Arc::new(FailingTagReader));
        let first = broken
            .scan(source_id, Arc::new(vfs.clone()), noop_progress())
            .await
            .unwrap();
        assert_eq!(first.fallback, 2);
        assert_eq!(tmp.library.track_count().await.unwrap(), 2);

        let reader = Arc::new(CountingTagReader::new());
        let fixed = Scanner::new(tmp.library.clone(), reader.clone());
        let mut previous = PreviousScan::new();
        previous.insert_file("a/one.mp3", 10, 100);
        previous.insert_file("a/two.mp3", 20, 200);
        fixed
            .scan_incremental(
                source_id,
                Arc::new(vfs.clone()),
                noop_progress(),
                Some(&previous),
            )
            .await
            .unwrap();
        assert_eq!(reader.calls(), 2, "fallback files must be re-read");
        assert_eq!(
            tmp.library.track_count().await.unwrap(),
            2,
            "the old file-name tracks must not linger next to the real ones"
        );
        assert!(tmp
            .library
            .zero_duration_paths(source_id)
            .await
            .unwrap()
            .is_empty());

        // 读好了之后就回到正常的增量复用。
        fixed
            .scan_incremental(source_id, Arc::new(vfs), noop_progress(), Some(&previous))
            .await
            .unwrap();
        assert_eq!(reader.calls(), 2);
    }

    /// 只改一个文件的 mtime：只重读那一个，`updated == 1`。
    #[tokio::test]
    async fn incremental_scan_rereads_only_changed_file() {
        let tmp = TempLibrary::new("changed");
        let source_id = tmp.add_source().await;
        let reader = Arc::new(CountingTagReader::new());
        let scanner = Scanner::new(tmp.library.clone(), reader.clone());

        let vfs = FakeVfs::local_like();
        vfs.add_file("a/one.flac", 10, 100);
        vfs.add_file("a/two.flac", 20, 200);
        scanner
            .scan(source_id, Arc::new(vfs.clone()), noop_progress())
            .await
            .unwrap();
        assert_eq!(reader.calls(), 2);

        let mut previous = PreviousScan::new();
        previous.insert_file("a/one.flac", 10, 100);
        previous.insert_file("a/two.flac", 20, 200);
        vfs.set_file_mtime("a/two.flac", 999);

        let report = scanner
            .scan_incremental(source_id, Arc::new(vfs), noop_progress(), Some(&previous))
            .await
            .unwrap();
        assert_eq!(report.updated, 1);
        assert_eq!(report.added, 0);
        assert_eq!(report.removed, 0);
        assert_eq!(reader.calls(), 3, "only the changed file is re-read");
    }

    /// 文件被删掉：`removed == 1`，曲目也跟着清理。
    #[tokio::test]
    async fn deleted_file_is_removed() {
        let tmp = TempLibrary::new("removed");
        let source_id = tmp.add_source().await;
        let scanner = Scanner::new(tmp.library.clone(), Arc::new(CountingTagReader::new()));

        let vfs = FakeVfs::local_like();
        vfs.add_file("a/one.flac", 10, 100);
        vfs.add_file("a/two.flac", 20, 200);
        scanner
            .scan(source_id, Arc::new(vfs.clone()), noop_progress())
            .await
            .unwrap();
        assert_eq!(tmp.library.track_count().await.unwrap(), 2);

        vfs.remove_file("a/two.flac");
        // 等一下，确保 started_at 比上一次的 last_seen_at 大
        tokio::time::sleep(std::time::Duration::from_millis(5)).await;
        let report = scanner
            .scan_incremental(source_id, Arc::new(vfs), noop_progress(), None)
            .await
            .unwrap();
        assert_eq!(report.removed, 1);
        assert_eq!(tmp.library.track_count().await.unwrap(), 1);
    }

    /// 标签读取失败 → 用文件名兜底，`fallback` 计数 +1。
    #[tokio::test]
    async fn tag_failure_falls_back_to_file_name() {
        let tmp = TempLibrary::new("fallback");
        let source_id = tmp.add_source().await;
        let scanner = Scanner::new(tmp.library.clone(), Arc::new(FailingTagReader));

        let vfs = FakeVfs::local_like();
        vfs.add_file("a/晴天.flac", 10, 100);
        let report = scanner
            .scan(source_id, Arc::new(vfs), noop_progress())
            .await
            .unwrap();
        assert_eq!(report.fallback, 1);
        assert_eq!(report.added, 1);
        let rows = tmp
            .library
            .list_track_rows(lekis_types::TrackQuery {
                sort: lekis_types::TrackSort::Title,
                offset: 0,
                limit: 10,
            })
            .await
            .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].title, "晴天");
    }

    /// 摘要里有、本地库里没有的文件（例如来自别的设备的共享索引）必须真读标签入库。
    #[tokio::test]
    async fn previous_scan_without_local_rows_falls_back_to_reading_tags() {
        let tmp = TempLibrary::new("shared-fallback");
        let source_id = tmp.add_source().await;
        let reader = Arc::new(CountingTagReader::new());
        let scanner = Scanner::new(tmp.library.clone(), reader.clone());

        let vfs = FakeVfs::local_like();
        vfs.add_file("a/one.flac", 10, 100);
        let mut previous = PreviousScan::new();
        previous.insert_file("a/one.flac", 10, 100);

        let report = scanner
            .scan_incremental(source_id, Arc::new(vfs), noop_progress(), Some(&previous))
            .await
            .unwrap();
        assert_eq!(report.added, 1);
        assert_eq!(reader.calls(), 1);
    }

    /// 进度事件顺序：先 Walking，最后 ScanFinished。
    #[tokio::test]
    async fn progress_events_are_emitted_in_order() {
        let tmp = TempLibrary::new("progress");
        let source_id = tmp.add_source().await;
        let scanner = Scanner::new(tmp.library.clone(), Arc::new(CountingTagReader::new()));
        let vfs = FakeVfs::local_like();
        vfs.add_file("a/one.flac", 10, 100);

        let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = seen.clone();
        let progress: ProgressFn = Arc::new(move |e: CoreEvent| {
            let label = match e {
                CoreEvent::ScanProgress { phase, .. } => format!("{phase:?}"),
                CoreEvent::ScanFinished { removed, .. } => format!("finished:{removed}"),
                other => format!("{other:?}"),
            };
            sink.lock().unwrap().push(label);
        });
        scanner
            .scan(source_id, Arc::new(vfs), progress)
            .await
            .unwrap();

        let events = seen.lock().unwrap().clone();
        assert_eq!(events.first().map(String::as_str), Some("Walking"));
        assert_eq!(events.last().map(String::as_str), Some("finished:0"));
    }

    /// 写共享索引：分片数 > 0，读回来能重建一份 PreviousScan；只读源返回 0。
    #[tokio::test]
    async fn write_shared_index_then_load_it_back() {
        let tmp = TempLibrary::new("shared");
        let source_id = tmp.add_source().await;
        let scanner = Scanner::new(tmp.library.clone(), Arc::new(CountingTagReader::new()))
            .with_device_id("device-test");

        let source_vfs = FakeVfs::local_like();
        source_vfs.add_file("Music/A/one.flac", 10, 100);
        source_vfs.add_file("Music/A/two.flac", 20, 200);
        source_vfs.add_file("Music/B/three.flac", 30, 300);
        scanner
            .scan(source_id, Arc::new(source_vfs), noop_progress())
            .await
            .unwrap();

        // 共享目录用真实的 LocalVfs
        let share_dir = tmp.dir.join("share");
        std::fs::create_dir_all(&share_dir).unwrap();
        let share = Arc::new(lekis_vfs::local::LocalVfs::new(&share_dir).unwrap());

        let shards = scanner
            .write_shared_index(source_id, share.clone())
            .await
            .unwrap();
        assert_eq!(
            shards, 2,
            "Music/A 和 Music/B 各一个分片（Music 自己没文件）"
        );

        let previous = shared_index::load_previous_scan(share.as_ref())
            .await
            .unwrap()
            .unwrap();
        assert_eq!(previous.files.len(), 3);
        assert_eq!(previous.files.get("Music/A/one.flac"), Some(&(10, 100)));
        assert_eq!(previous.files.get("Music/B/three.flac"), Some(&(30, 300)));

        // 分片里带着标签，别的设备不用再读文件
        let dir = lekis_vfs::VfsPath::parse("Music/A").unwrap();
        let (_header, entries) = shared_index::read_shard(share.as_ref(), &dir)
            .await
            .unwrap()
            .unwrap();
        assert_eq!(entries.len(), 2);
        let tags = shared_index::tags_from_blob(&entries[0].tags_blob).unwrap();
        assert!(!tags.title.is_empty());

        // 只读共享：返回 0，不报错
        let ro = FakeVfs::read_only();
        assert_eq!(
            scanner
                .write_shared_index(source_id, Arc::new(ro))
                .await
                .unwrap(),
            0
        );
    }

    /// 增量扫描会把目录 mtime 也用上：`reliable_dir_mtime` + 摘要里有目录 mtime 时，
    /// 不再列出没变的子树。
    #[tokio::test]
    async fn incremental_scan_prunes_unchanged_directories() {
        let tmp = TempLibrary::new("prune");
        let source_id = tmp.add_source().await;
        let reader = Arc::new(CountingTagReader::new());
        let scanner = Scanner::new(tmp.library.clone(), reader.clone());

        let vfs = FakeVfs::local_like();
        vfs.add_dir("keep");
        vfs.add_file("keep/a.flac", 1, 10);
        vfs.add_file("other/b.flac", 2, 20);
        scanner
            .scan(source_id, Arc::new(vfs.clone()), noop_progress())
            .await
            .unwrap();
        let reads_after_first = reader.calls();

        let mut previous = PreviousScan::new();
        previous.insert_file("keep/a.flac", 1, 10);
        previous.insert_file("other/b.flac", 2, 20);
        previous.insert_dir("keep", vfs.dir_mtime("keep"));
        // keep 子树要是被列了就会报错，从而让测试失败
        vfs.set_list_error("keep");

        let report = scanner
            .scan_incremental(source_id, Arc::new(vfs), noop_progress(), Some(&previous))
            .await
            .unwrap();
        assert_eq!(report.added + report.updated + report.removed, 0);
        assert_eq!(reader.calls(), reads_after_first, "整个子树被剪掉");
    }

    /// 测试用的计数进度回调用不到 `AtomicUsize`，这里保留一个编译期占位：
    /// 保证 `ScanReport` 仍然是 `Copy + Default`，root 侧可以直接构造常量。
    #[test]
    fn scan_report_is_copy_and_default() {
        let counter = AtomicUsize::new(0);
        counter.fetch_add(1, Ordering::SeqCst);
        let r = ScanReport::default();
        let s = r;
        assert_eq!(r, s);
        assert_eq!(counter.load(Ordering::SeqCst), 1);
    }
}
