use lekis_types::Result;
use lekis_vfs::{is_audio_file, EntryKind, Vfs, VfsPath};
use std::collections::VecDeque;

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

/// 广度优先遍历整个源，返回所有音频文件。
///
/// - 跳过以 `.` 开头的目录（包括我们自己的 `.lekis/`）和群晖的 `@eaDir` 缩略图目录；
/// - 单个目录读取失败只记日志，不中断整个扫描。
///
/// TODO(LIB-03)：按 `suggested_concurrency` 并发列目录；边遍历边把结果流式交给下一阶段。
pub async fn walk_audio_files(vfs: &dyn Vfs) -> Result<Vec<FoundFile>> {
    let mut out = Vec::new();
    let mut queue = VecDeque::from([VfsPath::root()]);
    while let Some(dir) = queue.pop_front() {
        let entries = match vfs.list_dir(&dir).await {
            Ok(e) => e,
            Err(e) if dir.is_root() => return Err(e),
            Err(e) => {
                tracing::warn!(target: "scanner", %dir, error = %e, "cannot list directory, skipping");
                continue;
            }
        };
        for entry in entries {
            let name = entry.path.file_name().unwrap_or_default();
            match entry.meta.kind {
                EntryKind::Dir if !should_skip_dir(name) => queue.push_back(entry.path),
                EntryKind::File if is_audio_file(&entry.path) => out.push(FoundFile {
                    path: entry.path,
                    size: entry.meta.size,
                    mtime_ms: entry.meta.mtime_ms,
                }),
                _ => {}
            }
        }
    }
    Ok(out)
}

fn should_skip_dir(name: &str) -> bool {
    name.starts_with('.') || name.eq_ignore_ascii_case("@eaDir") || name == "#recycle"
}
