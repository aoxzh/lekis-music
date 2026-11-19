//! 目录遍历（LIB-03 / LIB-04）。
//!
//! 按层（breadth）并发列目录：先把一层所有待列目录用一个 `buffer_unordered` 流并发列出来，
//! 收集下一层，再进入下一层。同一层里互不依赖，所以不需要 `Arc<dyn Vfs>` —— 所有 future
//! 都借用同一个 `&dyn Vfs`，在同一个任务里并发推进。
//!
//! 增量扫描（[`walk_source`] 传 `previous`）有两级复用：
//! 1. **目录级**：`VfsCapabilities::reliable_dir_mtime` 为真时，`stat` 每个目录，
//!    如果 mtime 和上一次一样就整棵子树复用上一次的文件列表，不再 `list_dir`；
//! 2. **文件级**：`(size, mtime_ms)` 和上一次完全一致的文件直接复用，不用再读标签。

use crate::PreviousScan;
use futures_util::stream::{self, StreamExt};
use lekis_types::{LekisError, Result};
use lekis_vfs::{is_audio_file, DirEntry, EntryKind, Vfs, VfsPath};
use std::collections::HashMap;

/// `suggested_concurrency` 为 0（未知）时使用的并发度。
pub const DEFAULT_CONCURRENCY: usize = 8;
/// 并发度上限。再高对 SMB / WebDAV 只会排队，反而拖慢小目录。
pub const MAX_CONCURRENCY: usize = 32;

/// 遍历时找到的音频文件。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FoundFile {
    /// 路径。
    pub path: VfsPath,
    /// 大小。
    pub size: u64,
    /// 修改时间。
    pub mtime_ms: i64,
}

/// 一次遍历的结果。
#[derive(Debug, Default)]
pub struct WalkOutcome {
    /// 需要（重新）读标签的文件：新增的，或者 `size` / `mtime_ms` 变了的。
    pub changed: Vec<FoundFile>,
    /// 和上一次扫描完全一致、可以直接复用的文件。
    pub unchanged: Vec<FoundFile>,
    /// 这次遍历看到的目录 mtime（键是 [`VfsPath::as_str`]），下一轮增量扫描用。
    ///
    /// 只在 `VfsCapabilities::reliable_dir_mtime` 为真时收集，否则为空。
    pub dirs: HashMap<String, i64>,
}

impl WalkOutcome {
    /// 全部文件数（`changed + unchanged`）。
    pub fn len(&self) -> usize {
        self.changed.len() + self.unchanged.len()
    }

    /// 是不是一个文件都没找到。
    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// 广度优先遍历整个源，返回所有音频文件。
///
/// - 跳过以 `.` 开头的目录（包括我们自己的 `.lekis/`）和群晖的 `@eaDir` 缩略图目录；
/// - 单个子目录读取失败只记日志，不中断整个扫描；根目录读取失败返回错误；
/// - 内部按 `capabilities().suggested_concurrency` 并发列目录，输出按路径排序（确定性）。
pub async fn walk_audio_files(vfs: &dyn Vfs) -> Result<Vec<FoundFile>> {
    let outcome = walk_source(vfs, None).await?;
    let mut files = outcome.changed;
    files.extend(outcome.unchanged);
    files.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(files)
}

/// 遍历一个源，按 [`PreviousScan`] 做增量复用。
///
/// `previous` 为 `None` 时等价于全量扫描（所有文件都进 `changed`）。
pub async fn walk_source(vfs: &dyn Vfs, previous: Option<&PreviousScan>) -> Result<WalkOutcome> {
    let caps = vfs.capabilities();
    let concurrency = clamp_concurrency(caps.suggested_concurrency);
    // 目录 mtime 不可靠的协议（SMB 某些实现、WebDAV）不做目录级剪枝，也不记录 mtime，
    // 但文件级复用（size + mtime）依然有效。
    let record_dirs = caps.reliable_dir_mtime;
    let prune_source = if record_dirs { previous } else { None };

    let mut outcome = WalkOutcome::default();
    let mut level: Vec<VfsPath> = vec![VfsPath::root()];
    while !level.is_empty() {
        let outcomes: Vec<DirOutcome> = stream::iter(std::mem::take(&mut level))
            .map(|dir| inspect_dir(vfs, dir, prune_source, record_dirs))
            .buffer_unordered(concurrency)
            .collect()
            .await;

        let mut next_level = Vec::new();
        for item in outcomes {
            match item {
                DirOutcome::Failed { dir, error } => {
                    if dir.is_root() {
                        return Err(error);
                    }
                    tracing::warn!(
                        target: "scanner",
                        %dir,
                        error = %error,
                        "cannot list directory, skipping"
                    );
                }
                DirOutcome::Reused { dir, mtime_ms } => {
                    outcome.dirs.insert(dir.as_str().to_string(), mtime_ms);
                    // `Reused` 只会在 `prune_source` 是 `Some` 时产生。
                    if let Some(previous) = prune_source {
                        reuse_subtree(previous, &dir, &mut outcome);
                    }
                }
                DirOutcome::Listed {
                    dir,
                    mtime_ms,
                    entries,
                } => {
                    if record_dirs {
                        outcome.dirs.insert(dir.as_str().to_string(), mtime_ms);
                    }
                    for entry in entries {
                        let name = entry.path.file_name().unwrap_or_default();
                        match entry.meta.kind {
                            EntryKind::Dir if !should_skip_dir(name) => next_level.push(entry.path),
                            EntryKind::File if is_audio_file(&entry.path) => {
                                let found = FoundFile {
                                    path: entry.path,
                                    size: entry.meta.size,
                                    mtime_ms: entry.meta.mtime_ms,
                                };
                                if is_unchanged(previous, &found) {
                                    outcome.unchanged.push(found);
                                } else {
                                    outcome.changed.push(found);
                                }
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
        level = next_level;
    }

    // 并发完成顺序不确定，排序保证行为可复现（也便于测试和日志比对）。
    outcome.changed.sort_by(|a, b| a.path.cmp(&b.path));
    outcome.unchanged.sort_by(|a, b| a.path.cmp(&b.path));
    Ok(outcome)
}

/// 一个目录的处理结果。
enum DirOutcome {
    /// 列出来了。
    Listed {
        /// 目录。
        dir: VfsPath,
        /// 目录 mtime（未收集时为 0）。
        mtime_ms: i64,
        /// 目录项。
        entries: Vec<DirEntry>,
    },
    /// 目录 mtime 没变，整棵子树复用。
    Reused {
        /// 目录。
        dir: VfsPath,
        /// 目录 mtime。
        mtime_ms: i64,
    },
    /// `list_dir` / 根目录 `stat` 失败。
    Failed {
        /// 目录。
        dir: VfsPath,
        /// 错误。
        error: LekisError,
    },
}

/// 处理单个目录：必要时 `stat` 判断能否复用，否则 `list_dir`。
async fn inspect_dir(
    vfs: &dyn Vfs,
    dir: VfsPath,
    previous: Option<&PreviousScan>,
    record_dirs: bool,
) -> DirOutcome {
    let mut mtime_ms = 0i64;
    if record_dirs {
        match vfs.stat(&dir).await {
            Ok(meta) => {
                mtime_ms = meta.mtime_ms;
                if previous.is_some_and(|p| p.dirs.get(dir.as_str()) == Some(&mtime_ms)) {
                    return DirOutcome::Reused { dir, mtime_ms };
                }
            }
            Err(e) => {
                // 目录 mtime 拿不到不影响正确性（某些协议连根目录都不给 stat），
                // 只是这次不能做目录级剪枝。
                tracing::debug!(
                    target: "scanner",
                    %dir,
                    error = %e,
                    "cannot stat directory, listing it instead"
                );
            }
        }
    }
    match vfs.list_dir(&dir).await {
        Ok(entries) => DirOutcome::Listed {
            dir,
            mtime_ms,
            entries,
        },
        Err(error) => DirOutcome::Failed { dir, error },
    }
}

/// 把上一次扫描里该目录子树下的文件全部算成"已见、未变"。
fn reuse_subtree(previous: &PreviousScan, dir: &VfsPath, outcome: &mut WalkOutcome) {
    let prefix = dir.as_str();
    let mut reused = 0usize;
    for (path, (size, mtime_ms)) in &previous.files {
        if !is_under(prefix, path) {
            continue;
        }
        match VfsPath::parse(path) {
            Some(parsed) => {
                outcome.unchanged.push(FoundFile {
                    path: parsed,
                    size: *size,
                    mtime_ms: *mtime_ms,
                });
                reused += 1;
            }
            // 共享索引可能来自别的设备，路径不合法时只跳过这一条。
            None => tracing::warn!(
                target: "scanner",
                path = %path,
                "invalid path in previous scan, skipping"
            ),
        }
    }
    tracing::debug!(target: "scanner", %dir, reused, "directory mtime unchanged, reusing subtree");
}

/// `path` 是否在 `prefix` 目录（含所有后代）之下。`prefix` 为空表示根目录。
fn is_under(prefix: &str, path: &str) -> bool {
    if prefix.is_empty() {
        return true;
    }
    path.len() > prefix.len() + 1
        && path.starts_with(prefix)
        && path.as_bytes().get(prefix.len()) == Some(&b'/')
}

/// 文件是否和上一次扫描完全一致（大小 + mtime）。
fn is_unchanged(previous: Option<&PreviousScan>, found: &FoundFile) -> bool {
    previous
        .and_then(|p| p.files.get(found.path.as_str()))
        .is_some_and(|(size, mtime_ms)| *size == found.size && *mtime_ms == found.mtime_ms)
}

/// 并发度：0 当作默认值，其余 clamp 到 `1..=MAX_CONCURRENCY`。
fn clamp_concurrency(suggested: usize) -> usize {
    let n = if suggested == 0 {
        DEFAULT_CONCURRENCY
    } else {
        suggested
    };
    n.clamp(1, MAX_CONCURRENCY)
}

fn should_skip_dir(name: &str) -> bool {
    name.starts_with('.') || name.eq_ignore_ascii_case("@eaDir") || name == "#recycle"
}

#[cfg(test)]
mod tests {
    // 测试里用 unwrap 断言前提成立，这是仓库约定（库代码才禁用）。
    #![allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]

    use super::*;
    use crate::test_support::FakeVfs;
    use lekis_vfs::VfsCapabilities;

    fn caps(reliable_dir_mtime: bool, concurrency: usize) -> VfsCapabilities {
        VfsCapabilities {
            writable: true,
            watch: false,
            reliable_dir_mtime,
            suggested_concurrency: concurrency,
        }
    }

    fn names(files: &[FoundFile]) -> Vec<String> {
        files.iter().map(|f| f.path.as_str().to_string()).collect()
    }

    /// 多层目录 + 并发列目录：路径集合正确。
    #[tokio::test]
    async fn walks_nested_tree_concurrently() {
        let vfs = FakeVfs::new(caps(false, 8));
        vfs.add_dir("a");
        vfs.add_dir("a/b");
        vfs.add_dir("c");
        vfs.add_file("root.flac", 10, 100);
        vfs.add_file("a/one.flac", 11, 101);
        vfs.add_file("a/b/two.mp3", 12, 102);
        vfs.add_file("c/three.ogg", 13, 103);

        let files = walk_audio_files(&vfs).await.unwrap();
        assert_eq!(
            names(&files),
            vec![
                "a/b/two.mp3".to_string(),
                "a/one.flac".to_string(),
                "c/three.ogg".to_string(),
                "root.flac".to_string(),
            ]
        );
        // 输出必须是确定性的（排序后），哪怕并发完成顺序不同。
        let again = walk_audio_files(&vfs).await.unwrap();
        assert_eq!(names(&again), names(&files));
    }

    /// 跳过规则：点开头目录、`@eaDir`、`#recycle`；非音频文件不返回。
    #[tokio::test]
    async fn skips_hidden_and_synology_dirs() {
        let vfs = FakeVfs::new(caps(false, 4));
        vfs.add_dir(".lekis");
        vfs.add_dir(".git");
        vfs.add_dir("@eaDir");
        vfs.add_dir("#recycle");
        vfs.add_dir("Music");
        vfs.add_file(".lekis/index/0000000000000000.cbor.zst", 5, 1);
        vfs.add_file("@eaDir/thumb.jpg", 5, 1);
        vfs.add_file("Music/song.flac", 5, 1);
        vfs.add_file("Music/cover.jpg", 5, 1);
        vfs.add_file("Music/notes.txt", 5, 1);

        let files = walk_audio_files(&vfs).await.unwrap();
        assert_eq!(names(&files), vec!["Music/song.flac".to_string()]);
    }

    /// 子目录读取失败不影响其它目录；根目录失败必须是错误。
    #[tokio::test]
    async fn subdirectory_error_is_skipped_but_root_error_fails() {
        let vfs = FakeVfs::new(caps(false, 3));
        vfs.add_dir("good");
        vfs.add_dir("bad");
        vfs.add_dir("good/deep");
        vfs.add_file("good/a.flac", 1, 1);
        vfs.add_file("good/deep/b.flac", 1, 2);
        vfs.add_file("bad/c.flac", 1, 3);
        vfs.set_list_error("bad");

        let files = walk_audio_files(&vfs).await.unwrap();
        assert_eq!(
            names(&files),
            vec!["good/a.flac".to_string(), "good/deep/b.flac".to_string()]
        );

        vfs.set_list_error("");
        assert!(walk_audio_files(&vfs).await.is_err());
    }

    /// 并发度会被 clamp；0 用默认值。
    #[test]
    fn concurrency_is_clamped() {
        assert_eq!(clamp_concurrency(0), DEFAULT_CONCURRENCY);
        assert_eq!(clamp_concurrency(1), 1);
        assert_eq!(clamp_concurrency(8), 8);
        assert_eq!(clamp_concurrency(1000), MAX_CONCURRENCY);
    }

    /// 文件级复用：size + mtime 都没变的文件进 `unchanged`。
    #[tokio::test]
    async fn file_level_reuse_marks_unchanged_files() {
        let vfs = FakeVfs::new(caps(false, 2));
        vfs.add_file("keep.flac", 10, 100);
        vfs.add_file("changed.flac", 10, 100);

        let mut previous = PreviousScan::default();
        previous.files.insert("keep.flac".into(), (10, 100));
        previous.files.insert("changed.flac".into(), (10, 100));
        // 让 changed.flac 变大
        vfs.set_file_size("changed.flac", 11);

        let outcome = walk_source(&vfs, Some(&previous)).await.unwrap();
        assert_eq!(names(&outcome.unchanged), vec!["keep.flac".to_string()]);
        assert_eq!(names(&outcome.changed), vec!["changed.flac".to_string()]);
        assert_eq!(outcome.len(), 2);
        assert!(!outcome.is_empty());
        // reliable_dir_mtime = false：不收集目录 mtime
        assert!(outcome.dirs.is_empty());
    }

    /// 目录级复用：mtime 没变的子树不再 list_dir（用"如果列了就报错"来证明没列）。
    #[tokio::test]
    async fn unchanged_directory_subtree_is_not_listed() {
        let vfs = FakeVfs::new(caps(true, 2));
        vfs.add_dir("keep");
        vfs.add_dir("other");
        vfs.add_file("keep/a.flac", 1, 10);
        vfs.add_file("keep/sub/b.flac", 2, 20);
        vfs.add_file("other/c.flac", 3, 30);

        let mut previous = PreviousScan::default();
        previous.files.insert("keep/a.flac".into(), (1, 10));
        previous.files.insert("keep/sub/b.flac".into(), (2, 20));
        previous.dirs.insert("keep".into(), vfs.dir_mtime("keep"));
        previous
            .dirs
            .insert("keep/sub".into(), vfs.dir_mtime("keep/sub"));

        // 根和 other 会真的被列出来；keep 有 mtime 记录且没变 → 不列。
        vfs.set_list_error("keep");
        vfs.set_list_error("keep/sub");

        let outcome = walk_source(&vfs, Some(&previous)).await.unwrap();
        assert_eq!(
            names(&outcome.unchanged),
            vec!["keep/a.flac".to_string(), "keep/sub/b.flac".to_string()]
        );
        assert_eq!(names(&outcome.changed), vec!["other/c.flac".to_string()]);
        // 目录 mtime 被记录下来了（根 / keep / other），供下一轮使用
        assert!(outcome.dirs.contains_key(""));
        assert!(outcome.dirs.contains_key("keep"));
        assert!(outcome.dirs.contains_key("other"));
        assert!(!outcome.dirs.contains_key("keep/sub"), "剪掉的子树不会再列");
    }

    /// 目录 mtime 变了就正常往下列。
    #[tokio::test]
    async fn changed_directory_mtime_forces_listing() {
        let vfs = FakeVfs::new(caps(true, 2));
        vfs.add_dir("album");
        vfs.add_file("album/a.flac", 1, 10);

        let mut previous = PreviousScan::default();
        previous.files.insert("album/a.flac".into(), (1, 10));
        previous
            .dirs
            .insert("album".into(), vfs.dir_mtime("album") - 1);

        let outcome = walk_source(&vfs, Some(&previous)).await.unwrap();
        // 列出来了，但文件本身没变 → unchanged
        assert_eq!(names(&outcome.unchanged), vec!["album/a.flac".to_string()]);
        assert!(outcome.changed.is_empty());
    }

    /// `is_under` 的边界：前缀相同但不在子树里的路径不能误判。
    #[test]
    fn subtree_prefix_check_is_segment_aware() {
        assert!(is_under("", "a/b.flac"));
        assert!(is_under("a", "a/b.flac"));
        assert!(is_under("a", "a/b/c.flac"));
        assert!(!is_under("a", "ab/c.flac"));
        assert!(!is_under("a", "a"));
        assert!(!is_under("a", "b/a.flac"));
    }

    /// 根目录 `stat` 失败不算错误（有些协议不给目录 mtime）：退回 `list_dir` 继续走。
    #[tokio::test]
    async fn root_stat_failure_falls_back_to_listing() {
        let vfs = FakeVfs::new(caps(true, 2));
        vfs.add_file("a.flac", 1, 10);
        vfs.set_stat_error("");
        let files = walk_audio_files(&vfs).await.unwrap();
        assert_eq!(names(&files), vec!["a.flac".to_string()]);
        vfs.clear_errors();
        assert_eq!(names(&walk_audio_files(&vfs).await.unwrap()), names(&files));
    }

    /// 目录 mtime 被记录下来（下一轮增量扫描要用）。
    #[tokio::test]
    async fn directory_mtime_is_recorded() {
        let vfs = FakeVfs::new(caps(true, 2));
        vfs.add_dir("album/sub");
        vfs.add_file("album/sub/a.flac", 1, 10);
        vfs.set_dir_mtime("album", 55_555);

        let outcome = walk_source(&vfs, None).await.unwrap();
        assert_eq!(outcome.dirs.get("album"), Some(&55_555));
        assert!(outcome.dirs.contains_key("album/sub"));
    }

    /// 根目录 mtime 没变时整个源一次 `list_dir` 都不发。
    #[tokio::test]
    async fn unchanged_root_subtree_is_not_listed_at_all() {
        let vfs = FakeVfs::new(caps(true, 2));
        vfs.add_dir("album");
        vfs.add_file("album/a.flac", 1, 10);

        let mut previous = PreviousScan::new();
        previous.insert_file("album/a.flac", 1, 10);
        previous.insert_dir("", vfs.dir_mtime(""));

        let outcome = walk_source(&vfs, Some(&previous)).await.unwrap();
        assert_eq!(names(&outcome.unchanged), vec!["album/a.flac".to_string()]);
        assert!(outcome.changed.is_empty());
        assert!(vfs.list_calls().is_empty(), "rows should not be listed");
    }

    /// `suggested_concurrency == 0` 时按默认并发跑，仍然能遍历完。
    #[tokio::test]
    async fn zero_concurrency_still_walks() {
        let vfs = FakeVfs::new(caps(false, 0));
        vfs.add_dir("d");
        vfs.add_file("d/a.flac", 1, 1);
        let files = walk_audio_files(&vfs).await.unwrap();
        assert_eq!(names(&files), vec!["d/a.flac".to_string()]);
    }
}
