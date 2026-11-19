//! 本地歌词（ENR-03 的本地部分）：同名 `.lrc` / `.txt` 侧车文件，再退回内嵌歌词标签。
//!
//! 按需调用（打开"正在播放"时），找到就写进 `lyrics` 表，下次直接命中。

use crate::Services;
use lekis_types::{Lyrics, LyricsFormat, Result, SourceId, TrackId};
use lekis_vfs::{partial, EntryKind, Vfs, VfsPath};
use std::sync::Arc;

/// 侧车歌词的大小上限（正常 LRC 只有几 KB）。
const MAX_SIDECAR_BYTES: u64 = 1024 * 1024;
/// 内嵌歌词所在的头尾窗口（歌词通常在标签区，和封面一样放头部；MP4 可能在尾部）。
const HEAD_WINDOW: u64 = 2 * 1024 * 1024;
const TAIL_WINDOW: u64 = 1024 * 1024;

/// 找一首歌的本地歌词并入库。找到返回 `Some`。
pub(crate) async fn find_and_store(services: &Arc<Services>, id: TrackId) -> Result<Option<Lyrics>> {
    let files = services.library.track_files(id).await?;
    for file in files {
        if !file.source_kind.is_filesystem() || file.path.is_empty() {
            continue;
        }
        let Some(path) = VfsPath::parse(&file.path) else {
            continue;
        };
        let Some(vfs) = vfs_for(services, file.source_id).await else {
            continue;
        };
        if let Some(lyrics) = load(vfs.as_ref(), &path).await {
            services.library.save_lyrics(id, lyrics.clone()).await?;
            return Ok(Some(lyrics));
        }
    }
    Ok(None)
}

async fn vfs_for(services: &Arc<Services>, source_id: SourceId) -> Option<Arc<dyn Vfs>> {
    if let Some(vfs) = services.vfs_get(source_id) {
        return Some(vfs);
    }
    let source = services.library.get_source(source_id).await.ok()?;
    let vfs = services.open_vfs(&source).ok()?;
    services.vfs_put(source_id, vfs.clone());
    Some(vfs)
}

async fn load(vfs: &dyn Vfs, path: &VfsPath) -> Option<Lyrics> {
    if let Some(text) = read_sidecar(vfs, path).await {
        return Some(make(text, "sidecar"));
    }
    read_embedded(vfs, path).await.map(|text| make(text, "embedded"))
}

fn make(content: String, source: &str) -> Lyrics {
    Lyrics {
        format: detect_format(&content),
        content,
        source: source.into(),
        offset_ms: 0,
        confidence: 1.0,
    }
}

/// 按内容判断格式：有 `[mm:ss` 时间戳是 LRC，行内还有 `<mm:ss` 是逐字 LRC，`<tt` 开头是 TTML。
pub(crate) fn detect_format(content: &str) -> LyricsFormat {
    let head = content.trim_start();
    if head.starts_with("<?xml") || head.starts_with("<tt") {
        return LyricsFormat::Ttml;
    }
    let is_stamp = |s: &str| {
        let b = s.as_bytes();
        b.len() >= 5 && b[0].is_ascii_digit() && b[1].is_ascii_digit() && b[2] == b':'
    };
    let mut timed = false;
    for line in content.lines() {
        let line = line.trim();
        if let Some(rest) = line.strip_prefix('[') {
            if is_stamp(rest) {
                timed = true;
                if line.match_indices('<').any(|(i, _)| is_stamp(&line[i + 1..])) {
                    return LyricsFormat::EnhancedLrc;
                }
            }
        }
    }
    if timed {
        LyricsFormat::Lrc
    } else {
        LyricsFormat::Plain
    }
}

async fn read_sidecar(vfs: &dyn Vfs, audio: &VfsPath) -> Option<String> {
    let stem_path = audio.as_str().rsplit_once('.').map(|(s, _)| s)?;
    for ext in ["lrc", "LRC", "ttml", "txt"] {
        let Some(path) = VfsPath::parse(&format!("{stem_path}.{ext}")) else {
            continue;
        };
        let Ok(meta) = vfs.stat(&path).await else {
            continue;
        };
        if !matches!(meta.kind, EntryKind::File) || meta.size == 0 || meta.size > MAX_SIDECAR_BYTES {
            continue;
        }
        if let Ok(bytes) = vfs.read_range(&path, 0..meta.size).await {
            let text = decode_text(&bytes);
            if !text.trim().is_empty() {
                return Some(text);
            }
        }
    }
    None
}

/// UTF-8（含 BOM）/ UTF-16 BOM；都不是时按有损 UTF-8 解。
fn decode_text(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(rest).into_owned();
    }
    let utf16 = |le: bool, rest: &[u8]| {
        let units: Vec<u16> = rest
            .chunks_exact(2)
            .map(|c| if le { u16::from_le_bytes([c[0], c[1]]) } else { u16::from_be_bytes([c[0], c[1]]) })
            .collect();
        String::from_utf16_lossy(&units)
    };
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        return utf16(true, rest);
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        return utf16(false, rest);
    }
    String::from_utf8_lossy(bytes).into_owned()
}

async fn read_embedded(vfs: &dyn Vfs, path: &VfsPath) -> Option<String> {
    let meta = vfs.stat(path).await.ok()?;
    if !matches!(meta.kind, EntryKind::File) || meta.size == 0 {
        return None;
    }
    let data = partial::read_head_tail(vfs, path, meta.size, HEAD_WINDOW, TAIL_WINDOW)
        .await
        .ok()?;
    match lekis_scanner::tags::read_lyrics(path, &data) {
        Ok(found) => found,
        Err(e) => {
            tracing::debug!(target: "core", path = %path, error = %e, "embedded lyrics parse failed");
            None
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detects_formats() {
        assert_eq!(detect_format("[00:01.00]hello\n[00:02.00]world"), LyricsFormat::Lrc);
        assert_eq!(
            detect_format("[00:01.00]<00:01.00>he<00:01.50>llo"),
            LyricsFormat::EnhancedLrc
        );
        assert_eq!(detect_format("[ar:someone]\njust text"), LyricsFormat::Plain);
        assert_eq!(detect_format("<?xml version=\"1.0\"?><tt>"), LyricsFormat::Ttml);
    }

    #[test]
    fn decodes_bom() {
        assert_eq!(decode_text(b"\xEF\xBB\xBFabc"), "abc");
        assert_eq!(decode_text(&[0xFF, 0xFE, b'a', 0, b'b', 0]), "ab");
    }
}
