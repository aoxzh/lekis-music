//! 本地歌词：同名逐字歌词、LRC、TTML、WebVTT 或 TXT 侧车，再退回内嵌歌词标签。
//!
//! 按需调用（打开"正在播放"时），找到就写进 `lyrics` 表，下次直接命中。

use crate::Services;
use lekis_types::{Lyrics, LyricsFormat, Result, SourceId, TrackId};
use lekis_vfs::{partial, EntryKind, Vfs, VfsPath};
use std::sync::Arc;

mod karaoke;
mod webvtt;

pub(super) const LYRICS_EXTS: &[&str] = &[
    "elrc", "ELRC", "qrc", "QRC", "yrc", "YRC", "krc", "KRC", "lrc", "LRC", "ttml", "vtt", "VTT",
    "txt",
];

/// 侧车歌词的大小上限（正常 LRC 只有几 KB）。
const MAX_SIDECAR_BYTES: u64 = 1024 * 1024;
/// 内嵌歌词所在的头尾窗口（歌词通常在标签区，和封面一样放头部；MP4 可能在尾部）。
const HEAD_WINDOW: u64 = 2 * 1024 * 1024;
const TAIL_WINDOW: u64 = 1024 * 1024;

/// 找一首歌的本地歌词并入库。找到返回 `Some`。
pub(crate) async fn find_and_store(
    services: &Arc<Services>,
    id: TrackId,
) -> Result<Option<Lyrics>> {
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

pub(crate) async fn vfs_for(services: &Arc<Services>, source_id: SourceId) -> Option<Arc<dyn Vfs>> {
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
    read_embedded(vfs, path)
        .await
        .map(|text| make(text, "embedded"))
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
                if line
                    .match_indices('<')
                    .any(|(i, _)| is_stamp(&line[i + 1..]))
                {
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

pub(super) async fn read_sidecar(vfs: &dyn Vfs, audio: &VfsPath) -> Option<String> {
    let stem_path = audio.as_str().rsplit_once('.').map(|(s, _)| s)?;
    for &ext in LYRICS_EXTS {
        let Some(path) = VfsPath::parse(&format!("{stem_path}.{ext}")) else {
            continue;
        };
        let Some(bytes) = sidecar_bytes(vfs, &path).await else {
            continue;
        };
        if let Some(format) = karaoke::Format::from_ext(ext) {
            if let Some(ttml) = karaoke::read(format, &bytes, vfs, stem_path, ext).await {
                return Some(ttml);
            }
            continue;
        }
        let text = decode_text(&bytes);
        if ext.eq_ignore_ascii_case("vtt") {
            if let Some(ttml) = webvtt::to_ttml(&text) {
                return Some(ttml);
            }
        } else if !text.trim().is_empty() {
            return Some(text);
        }
    }
    None
}

async fn sidecar_bytes(vfs: &dyn Vfs, path: &VfsPath) -> Option<bytes::Bytes> {
    let meta = vfs.stat(path).await.ok()?;
    if meta.kind != EntryKind::File || !(1..=MAX_SIDECAR_BYTES).contains(&meta.size) {
        return None;
    }
    let bytes = vfs.read_range(path, 0..meta.size).await.ok()?;
    (bytes.len() as u64 == meta.size).then_some(bytes)
}

/// UTF-8（含 BOM）/ UTF-16 BOM；都不是时按有损 UTF-8 解。
fn decode_text(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(rest).into_owned();
    }
    let utf16 = |le: bool, rest: &[u8]| {
        let units: Vec<u16> = rest
            .chunks_exact(2)
            .map(|c| {
                if le {
                    u16::from_le_bytes([c[0], c[1]])
                } else {
                    u16::from_be_bytes([c[0], c[1]])
                }
            })
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
        assert_eq!(
            detect_format("[00:01.00]hello\n[00:02.00]world"),
            LyricsFormat::Lrc
        );
        assert_eq!(
            detect_format("[00:01.00]<00:01.00>he<00:01.50>llo"),
            LyricsFormat::EnhancedLrc
        );
        assert_eq!(
            detect_format("[ar:someone]\njust text"),
            LyricsFormat::Plain
        );
        assert_eq!(
            detect_format("<?xml version=\"1.0\"?><tt>"),
            LyricsFormat::Ttml
        );
    }

    #[tokio::test]
    async fn reads_elrc_sidecar_with_japanese_word_timestamps() {
        let root = std::env::temp_dir().join(format!("lekis-elrc-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&root);
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(
            root.join("track.ELRC"),
            "[00:01.00]<00:01.00>原<00:01.50>文",
        )
        .unwrap();
        let vfs = lekis_vfs::local::LocalVfs::new(&root).unwrap();
        let lyrics = load(&vfs, &VfsPath::parse("track.flac").unwrap())
            .await
            .unwrap();
        assert_eq!(lyrics.format, LyricsFormat::EnhancedLrc);
        assert_eq!(lyrics.source, "sidecar");
        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn converts_webvtt_blocks_to_frontend_ttml() {
        let input = "WEBVTT title\r\nKind: captions\r\n\r\n\
            NOTE\tcomment\r\n00:00.000 --> 00:01.000\r\nignore\r\n \t\r\n\
            STYLE\r\n::cue { color: lime }\r\n\r\n\
            REGION\r\nid:main\r\n\r\n\
            verse 1\r\n00:01.007 --> 00:04.120 align:start position:10%\r\n\
            <v 声優><c.blue><b>春</b> &amp; <i>夏</i></c></v>\r\n\
            <00:02.010><u>&lt;tag&gt;</u> [00:03.00]\r\n\r\n\
            01:40:05.123 --> 01:40:06.456\r\n<lang en>last\u{0}</lang>";
        let expected = "<tt xmlns=\"http://www.w3.org/ns/ttml\"><body><div>\
            <p begin=\"1007ms\" end=\"4120ms\">春 &amp; 夏<br/>&lt;tag&gt; [00:03.00]</p>\
            <p begin=\"6005123ms\" end=\"6006456ms\">last</p></div></body></tt>";
        assert_eq!(webvtt::to_ttml(input).as_deref(), Some(expected));
        assert_eq!(detect_format(expected), LyricsFormat::Ttml);
    }

    #[test]
    fn skips_invalid_webvtt_cues_and_recovers_at_next_block() {
        for timing in [
            "00:61.123 --> 01:02.000",
            "01:60:00.000 --> 02:00:00.000",
            "00:00.00 --> 00:01.000",
            "00:01.000 --> 00:01.000",
            "00:02.000 --> 00:01.000",
            "00:00.000 --> broken",
            "9999999999999999999:00:00.000 --> 9999999999999999999:01:00.000",
        ] {
            let input = format!("WEBVTT\n\n{timing}\nbad");
            assert!(webvtt::to_ttml(&input).is_none());
            let recovered =
                webvtt::to_ttml(&format!("{input}\n\n00:00.001 --> 00:02.000\nok")).unwrap();
            assert!(recovered.contains(">ok</p>"));
            assert!(!recovered.contains("bad"));
        }
        for input in [
            "WEBVTTjunk\n\n00:00.000 --> 00:01.000\ntext",
            "WEBVTT\n\n00:00.000 --> 00:01.000\n<i></i>&nbsp;",
            "WEBVTT\n\nNOTE\n00:00.000 --> 00:01.000\nhidden",
        ] {
            assert!(webvtt::to_ttml(input).is_none());
        }
    }

    #[tokio::test]
    async fn loads_webvtt_in_sidecar_order_and_falls_back() {
        let root = std::env::temp_dir().join(format!("lekis-vtt-read-{}", std::process::id()));
        std::fs::create_dir_all(&root).unwrap();
        let vfs = lekis_vfs::local::LocalVfs::new(&root).unwrap();
        let audio = VfsPath::parse("disc.one.flac").unwrap();
        let vtt = root.join("disc.one.VTT");
        std::fs::write(&vtt, "\u{feff}WEBVTT\r\r00:01.001 --> 00:02.002\rtext").unwrap();
        let txt = root.join("disc.one.txt");
        std::fs::write(&txt, "fallback").unwrap();
        let lrc = root.join("disc.one.lrc");
        std::fs::write(&lrc, "[00:01.00]preferred").unwrap();
        assert_eq!(load(&vfs, &audio).await.unwrap().format, LyricsFormat::Lrc);
        std::fs::remove_file(lrc).unwrap();
        let lyrics = load(&vfs, &audio).await.unwrap();
        assert_eq!(lyrics.source, "sidecar");
        assert_eq!(lyrics.format, LyricsFormat::Ttml);
        assert!(lyrics
            .content
            .contains("<p begin=\"1001ms\" end=\"2002ms\">text</p>"));
        std::fs::OpenOptions::new()
            .write(true)
            .open(&vtt)
            .unwrap()
            .set_len(MAX_SIDECAR_BYTES + 1)
            .unwrap();
        assert_eq!(load(&vfs, &audio).await.unwrap().content, "fallback");
        std::fs::write(vtt, "WEBVTT\n\nNOTE ignore me").unwrap();
        assert_eq!(load(&vfs, &audio).await.unwrap().content, "fallback");
        std::fs::remove_file(txt).unwrap();
        assert!(load(&vfs, &audio).await.is_none());
        let mut flac = b"fLaC\x00\x00\x00\x22".to_vec();
        let mut stream_info = [0u8; 34];
        stream_info[..4].copy_from_slice(&[0x10, 0, 0x10, 0]);
        stream_info[10..18].copy_from_slice(&[0x0a, 0xc4, 0x42, 0xf0, 0, 0, 0xac, 0x44]);
        flac.extend_from_slice(&stream_info);
        let comment = b"LYRICS=embedded line";
        flac.extend_from_slice(&[0x84, 0, 0, (12 + comment.len()) as u8]);
        flac.extend_from_slice(&0u32.to_le_bytes());
        flac.extend_from_slice(&1u32.to_le_bytes());
        flac.extend_from_slice(&(comment.len() as u32).to_le_bytes());
        flac.extend_from_slice(comment);
        std::fs::write(root.join(audio.as_str()), flac).unwrap();
        let embedded = load(&vfs, &audio).await.unwrap();
        assert_eq!(embedded.source, "embedded");
        assert_eq!(embedded.content, "embedded line");
        std::fs::remove_dir_all(root).unwrap();
    }

    #[test]
    fn decodes_bom() {
        assert_eq!(decode_text(b"\xEF\xBB\xBFabc"), "abc");
        assert_eq!(decode_text(&[0xFF, 0xFE, b'a', 0, b'b', 0]), "ab");
    }
}
