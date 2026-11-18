//! 标签读取。
//!
//! [`TagReader`] 是同步接口（CPU 密集），扫描器在 `spawn_blocking` 里调用它。

use lekis_library::ScannedTags;
use lekis_types::{LekisError, Result};
use lekis_vfs::partial::PartialFile;
use lekis_vfs::VfsPath;

/// 标签解析器。
pub trait TagReader: Send + Sync {
    /// 从文件头尾数据里解析标签。数据不够时返回 `Err`，扫描器会用文件名兜底
    /// （以后改成：返回"需要补读的范围"，由扫描器补读后重试）。
    fn read(&self, path: &VfsPath, data: &PartialFile) -> Result<ScannedTags>;
}

/// 基于 lofty 的实现（LIB-02）。
///
/// TODO：
/// - lofty 需要 `Read + Seek`：用 `head` + `tail` 拼一个"稀疏文件"读取器，中间没读到的部分返回错误；
/// - 多值标签拆分（`/`、`;`、`feat.`、`&`），见 LIB-08；
/// - 读取 ReplayGain、MusicBrainz ID、作曲家 / 作品 / 乐章；
/// - 时长：优先从流信息计算，不要相信 `TLEN` 标签。
pub struct LoftyTagReader;

impl TagReader for LoftyTagReader {
    fn read(&self, _path: &VfsPath, _data: &PartialFile) -> Result<ScannedTags> {
        Err(LekisError::not_implemented("lofty tag reader"))
    }
}

/// 没有标签时，用文件名兜底：支持 `艺人 - 标题.flac` 和 `01. 标题.flac` 两种常见格式。
pub fn tags_from_file_name(path: &VfsPath) -> ScannedTags {
    let name = path.file_name().unwrap_or_default();
    let stem = name.rsplit_once('.').map(|(s, _)| s).unwrap_or(name);
    let stem = stem
        .trim_start_matches(|c: char| c.is_ascii_digit())
        .trim_start_matches(['.', ' ', '-', '_'])
        .trim();
    let (artists, title) = match stem.split_once(" - ") {
        Some((artist, title)) => (vec![artist.trim().to_string()], title.trim().to_string()),
        None => (Vec::new(), stem.to_string()),
    };
    // 上级目录名当作专辑名（"艺人/专辑/01 歌名.flac" 是最常见的整理方式）。
    let album = path.parent().and_then(|p| p.file_name().map(str::to_owned));
    ScannedTags {
        title,
        artists,
        album,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn file_name_fallback() {
        let p = VfsPath::parse("周杰伦/叶惠美/03. 晴天.flac").unwrap_or_default();
        let t = tags_from_file_name(&p);
        assert_eq!(t.title, "晴天");
        assert_eq!(t.album.as_deref(), Some("叶惠美"));

        let p = VfsPath::parse("misc/Jay Chou - 晴天.mp3").unwrap_or_default();
        let t = tags_from_file_name(&p);
        assert_eq!(t.title, "晴天");
        assert_eq!(t.artists, vec!["Jay Chou".to_string()]);
    }
}
