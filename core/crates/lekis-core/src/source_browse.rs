//! 「添加音源」时浏览远端目录：只给界面子文件夹名和这一层的音频文件数。

use lekis_vfs::{DirEntry, EntryKind};

/// 一层目录的浏览结果。
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SourceListing {
    /// 子文件夹名（不含隐藏 / 系统目录），按名称不区分大小写排序。
    pub folders: Vec<String>,
    /// 这一层直接包含的音频文件数（不递归）。
    pub audio_files: u32,
}

/// NAS 和操作系统自己的目录，选音乐文件夹时只会添乱。
const SYSTEM_DIRS: &[&str] = &[
    "@eaDir",
    "#recycle",
    "#snapshot",
    "$RECYCLE.BIN",
    "System Volume Information",
    "lost+found",
];

fn is_hidden(name: &str) -> bool {
    name.starts_with('.') || SYSTEM_DIRS.iter().any(|d| d.eq_ignore_ascii_case(name))
}

impl SourceListing {
    /// 从 `list_dir` 的结果整理出文件夹列表和音频文件数。
    pub fn from_entries(entries: Vec<DirEntry>) -> Self {
        let mut folders = Vec::new();
        let mut audio_files = 0u32;
        for entry in entries {
            let Some(name) = entry.path.file_name().map(str::to_string) else {
                continue;
            };
            match entry.meta.kind {
                EntryKind::Dir if !is_hidden(&name) => folders.push(name),
                EntryKind::File if lekis_vfs::is_audio_file(&entry.path) => {
                    audio_files = audio_files.saturating_add(1);
                }
                _ => {}
            }
        }
        folders.sort_by_key(|n| n.to_lowercase());
        folders.dedup();
        Self {
            folders,
            audio_files,
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;
    use lekis_vfs::{FileMeta, VfsPath};

    fn entry(path: &str, kind: EntryKind) -> DirEntry {
        DirEntry {
            path: VfsPath::parse(path).expect("path"),
            meta: FileMeta {
                kind,
                size: 0,
                mtime_ms: 0,
            },
        }
    }

    #[test]
    fn keeps_visible_folders_and_counts_audio() {
        let listing = SourceListing::from_entries(vec![
            entry("Music/rock", EntryKind::Dir),
            entry("Music/Jazz", EntryKind::Dir),
            entry("Music/@eaDir", EntryKind::Dir),
            entry("Music/.lekis", EntryKind::Dir),
            entry("Music/#recycle", EntryKind::Dir),
            entry("Music/a.flac", EntryKind::File),
            entry("Music/b.MP3", EntryKind::File),
            entry("Music/cover.jpg", EntryKind::File),
            entry("Music/link", EntryKind::Other),
        ]);
        assert_eq!(listing.folders, vec!["Jazz", "rock"]);
        assert_eq!(listing.audio_files, 2);
    }
}
