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
//! TODO(LIB-03)：按协议自适应的并发读取（`VfsCapabilities::suggested_concurrency`）。
//! TODO(LIB-04)：增量扫描——目录 mtime 没变就跳过整个子树；文件 size + mtime 没变就跳过。
//! TODO(LIB-05)：先读 NAS 共享索引，命中的文件直接入库，不用再读文件。

pub mod shared_index;
pub mod tags;
mod walk;

use lekis_library::{Library, ScannedFile, ScannedTags};
use lekis_types::{now_ms, CoreEvent, Result, ScanPhase, SourceId};
use lekis_vfs::{partial, Vfs};
use std::sync::Arc;
use tags::TagReader;

pub use walk::{walk_audio_files, FoundFile};

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

/// 扫描器。
pub struct Scanner {
    library: Library,
    tag_reader: Arc<dyn TagReader>,
}

impl Scanner {
    /// 创建扫描器。
    pub fn new(library: Library, tag_reader: Arc<dyn TagReader>) -> Self {
        Self {
            library,
            tag_reader,
        }
    }

    /// 完整扫描一个音源。
    pub async fn scan(
        &self,
        source_id: SourceId,
        vfs: Arc<dyn Vfs>,
        progress: ProgressFn,
    ) -> Result<ScanReport> {
        let started_at = now_ms();
        progress(CoreEvent::ScanProgress {
            source_id,
            phase: ScanPhase::Walking,
            done: 0,
            total: None,
        });
        let files = walk_audio_files(vfs.as_ref()).await?;
        let total = files.len() as u64;
        tracing::info!(target: "scanner", %source_id, total, "walk finished");

        let mut report = ScanReport::default();
        let mut batch = Vec::with_capacity(BATCH_SIZE);
        for (i, found) in files.into_iter().enumerate() {
            let tags = match self.read_tags(vfs.as_ref(), &found).await {
                Ok(t) => t,
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

    async fn read_tags(&self, vfs: &dyn Vfs, found: &FoundFile) -> Result<ScannedTags> {
        let partial = partial::read_head_tail(
            vfs,
            &found.path,
            found.size,
            partial::DEFAULT_HEAD,
            partial::DEFAULT_TAIL,
        )
        .await?;
        let reader = self.tag_reader.clone();
        let path = found.path.clone();
        // 标签解析是 CPU 密集的同步代码，不能在 async 任务里直接跑。
        tokio::task::spawn_blocking(move || reader.read(&path, &partial))
            .await
            .map_err(|e| lekis_types::LekisError::internal(format!("tag task: {e}")))?
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
