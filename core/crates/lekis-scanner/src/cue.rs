//! CUE 整轨解析器（基于 `cue-rw` + `chardetng` + `encoding_rs`）。
//!
//! 解决中文 / 日文无损资源常见的整轨 `.ape` / `.flac` / `.wav` / `.wv` / `.tta` + `.cue` 问题：
//! - 自动识别 UTF-8（含 BOM）、GBK/GB18030、Big5、Shift_JIS、EUC-KR、Windows-1252 编码；
//! - 解析 `REM DATE` / `REM GENRE` / `REM DISCNUMBER`、专辑名、艺人、各轨起止时间；
//! - 容忍 EAC 常见的扩展名错配（例如 CUE 里写 `album.wav`，实际同目录是 `album.ape` 或 `album.flac`）。

use chardetng::{EncodingDetector, Iso2022JpDetection, Utf8Detection};
use cue_rw::{CUEFile, CUETimeStamp};
use lekis_types::{ErrorCode, LekisError, Result};
use lekis_vfs::VfsPath;
use std::collections::HashMap;

/// `.cue` 文件读取上限（2 MiB）。
pub const MAX_CUE_BYTES: u64 = 2 * 1024 * 1024;

/// 从 `.cue` 解析出的一首分轨。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CueTrackEntry {
    /// CUE 文件中 `FILE` 声明的原始文件名（仅文件名或相对路径）。
    pub audio_file_ref: String,
    /// 曲目号（1-based）。
    pub track_no: u32,
    /// 碟片号（来自 `REM DISCNUMBER`）。
    pub disc_no: Option<u32>,
    /// 曲目标题。
    pub title: String,
    /// 曲目艺人（为空时回落到专辑艺人）。
    pub artist: Option<String>,
    /// 专辑名。
    pub album: Option<String>,
    /// 专辑艺人。
    pub album_artist: Option<String>,
    /// 发行年份（来自 `REM DATE`）。
    pub year: Option<i32>,
    /// 流派（来自 `REM GENRE`）。
    pub genre: Option<String>,
    /// 起始毫秒（`INDEX 01`）。
    pub start_ms: u64,
    /// 结束毫秒（下一轨的 `INDEX 00` 或 `INDEX 01`；该音频文件的最后一轨为 `None`）。
    pub end_ms: Option<u64>,
}

/// 解析好的 CUE 表。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ParsedCueSheet {
    /// 专辑标题。
    pub album_title: Option<String>,
    /// 专辑艺人。
    pub album_performer: Option<String>,
    /// 年份。
    pub year: Option<i32>,
    /// 流派。
    pub genre: Option<String>,
    /// 碟片号。
    pub disc_no: Option<u32>,
    /// 所有分轨（按顺序）。
    pub tracks: Vec<CueTrackEntry>,
}

/// 将原始字节按 BOM 或 `chardetng` 猜测的编码解码成 UTF-8 文本。
pub fn decode_cue_text(bytes: &[u8]) -> String {
    if let Some(rest) = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]) {
        return String::from_utf8_lossy(rest).into_owned();
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFF, 0xFE]) {
        let (cow, _, _) = encoding_rs::UTF_16LE.decode(rest);
        return cow.into_owned();
    }
    if let Some(rest) = bytes.strip_prefix(&[0xFE, 0xFF]) {
        let (cow, _, _) = encoding_rs::UTF_16BE.decode(rest);
        return cow.into_owned();
    }
    if let Ok(utf8) = std::str::from_utf8(bytes) {
        return utf8.to_string();
    }
    let mut detector = EncodingDetector::new(Iso2022JpDetection::Allow);
    detector.feed(bytes, true);
    // 非 UTF-8 的 CUE 在中文无损圈绝大多数是 GB18030/GBK 或 Shift_JIS。
    let encoding = detector.guess(None, Utf8Detection::Allow);
    let (cow, _, _) = encoding.decode(bytes);
    cow.into_owned()
}

/// 解析 `.cue` 原始字节。
pub fn parse_cue_bytes(bytes: &[u8]) -> Result<ParsedCueSheet> {
    let text = decode_cue_text(bytes);
    parse_cue_str(&text)
}

/// 解析已转为 UTF-8 的 `.cue` 文本。
pub fn parse_cue_str(input: &str) -> Result<ParsedCueSheet> {
    let cue = CUEFile::parse_permissive(input)
        .map_err(|e| LekisError::new(ErrorCode::Decode, format!("invalid cue sheet: {e}")))?;

    let mut year: Option<i32> = None;
    let mut genre: Option<String> = None;
    let mut disc_no: Option<u32> = None;
    for comment in &cue.comments {
        parse_rem_comment(comment, &mut year, &mut genre, &mut disc_no);
    }

    let album_title = clean_opt(cue.title.as_deref());
    let album_performer = clean_opt(cue.performer.as_deref());

    // 先按文件分组收集每轨的 INDEX 00 / INDEX 01，便于准确计算上一轨的 end_ms。
    let mut per_file_indices: HashMap<usize, Vec<usize>> = HashMap::new();
    for (idx, (file_id, _)) in cue.tracks.iter().enumerate() {
        per_file_indices.entry(*file_id).or_default().push(idx);
    }

    let mut entries = Vec::with_capacity(cue.tracks.len());
    for (idx, (file_id, track)) in cue.tracks.iter().enumerate() {
        let Some(audio_file_ref) = cue.files.get(*file_id) else {
            continue;
        };
        let Some(start_ts) =
            index_timestamp(&track.indices, 1).or_else(|| track.indices.first().map(|(_, ts)| *ts))
        else {
            continue;
        };
        let start_ms = timestamp_to_ms(start_ts);

        // 在同一 FILE 内找下一轨：优先用下一轨的 INDEX 00（去掉轨间静音），没有则用 INDEX 01。
        let end_ms = per_file_indices.get(file_id).and_then(|list| {
            let pos = list.iter().position(|&i| i == idx)?;
            let next_idx = *list.get(pos + 1)?;
            let next_track = &cue.tracks[next_idx].1;
            let next_ts = index_timestamp(&next_track.indices, 0)
                .filter(|ts| timestamp_to_ms(*ts) >= start_ms)
                .or_else(|| index_timestamp(&next_track.indices, 1))
                .or_else(|| next_track.indices.first().map(|(_, ts)| *ts))?;
            Some(timestamp_to_ms(next_ts))
        });

        let mut track_year = year;
        let mut track_genre = genre.clone();
        let mut track_disc = disc_no;
        for comment in &track.comments {
            parse_rem_comment(comment, &mut track_year, &mut track_genre, &mut track_disc);
        }

        let track_no = (idx + 1) as u32;
        let title =
            clean_opt(track.title.as_deref()).unwrap_or_else(|| format!("Track {track_no:02}"));
        let artist = clean_opt(track.performer.as_deref()).or_else(|| album_performer.clone());

        entries.push(CueTrackEntry {
            audio_file_ref: audio_file_ref.clone(),
            track_no,
            disc_no: track_disc,
            title,
            artist,
            album: album_title.clone(),
            album_artist: album_performer.clone(),
            year: track_year,
            genre: track_genre,
            start_ms,
            end_ms,
        });
    }

    Ok(ParsedCueSheet {
        album_title,
        album_performer,
        year,
        genre,
        disc_no,
        tracks: entries,
    })
}

/// 在同目录的音频文件列表里解析 CUE `FILE` 引用。
///
/// 匹配优先级：
/// 1. 精确文件名匹配（不区分大小写）；
/// 2. 同词干（stem）匹配（处理 `FILE "CDImage.wav"` 实际指向 `CDImage.ape` / `CDImage.flac` 的情况）；
/// 3. 如果目录里只有一个音频文件且 CUE 也只引用了一个文件，直接配对（常见于手动改名后的整轨）。
pub fn resolve_cue_audio_path<'a>(
    cue_path: &VfsPath,
    file_ref: &str,
    same_dir_audio: &'a [VfsPath],
    cue_file_count: usize,
) -> Option<&'a VfsPath> {
    let ref_name = file_ref
        .rsplit(['/', '\\'])
        .next()
        .unwrap_or(file_ref)
        .trim();
    if ref_name.is_empty() {
        return None;
    }
    // 1. 精确文件名（不区分大小写）
    if let Some(found) = same_dir_audio.iter().find(|p| {
        p.file_name()
            .is_some_and(|n| n.eq_ignore_ascii_case(ref_name))
    }) {
        return Some(found);
    }
    // 2. 同词干匹配（`album.wav` -> `album.ape` / `album.flac` / `album.wv` / `album.tta`）
    let ref_stem = file_stem(ref_name);
    if !ref_stem.is_empty() {
        if let Some(found) = same_dir_audio.iter().find(|p| {
            p.file_name()
                .map(file_stem)
                .is_some_and(|s| s.eq_ignore_ascii_case(ref_stem))
        }) {
            return Some(found);
        }
    }
    // 3. 和 CUE 文件本身同词干（`Album.cue` + `Album.ape`，而 CUE 内部仍写着 `CDImage.wav`）
    if let Some(cue_stem) = cue_path
        .file_name()
        .map(file_stem)
        .filter(|s| !s.is_empty())
    {
        if let Some(found) = same_dir_audio.iter().find(|p| {
            p.file_name()
                .map(file_stem)
                .is_some_and(|s| s.eq_ignore_ascii_case(cue_stem))
        }) {
            return Some(found);
        }
    }
    // 4. 目录唯一整轨兜底
    if cue_file_count == 1 && same_dir_audio.len() == 1 {
        return same_dir_audio.first();
    }
    None
}

fn file_stem(name: &str) -> &str {
    match name.rsplit_once('.') {
        Some((stem, _)) if !stem.is_empty() => stem,
        _ => name,
    }
}

fn index_timestamp(indices: &[(u8, CUETimeStamp)], wanted: u8) -> Option<CUETimeStamp> {
    indices
        .iter()
        .find(|(n, _)| *n == wanted)
        .map(|(_, ts)| *ts)
}

/// 将 `CUETimeStamp`（`MM:SS:FF`，1 秒 = 75 帧）转换为毫秒。
pub fn timestamp_to_ms(ts: CUETimeStamp) -> u64 {
    let text = ts.to_string();
    let mut parts = text.split(':');
    let m: u64 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    let s: u64 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    let f: u64 = parts.next().and_then(|s| s.parse().ok()).unwrap_or(0);
    (m * 60 + s) * 1_000 + (f * 1_000 + 37) / 75
}

fn clean_opt(s: Option<&str>) -> Option<String> {
    s.map(str::trim)
        .filter(|v| !v.is_empty())
        .map(str::to_string)
}

fn parse_rem_comment(
    comment: &str,
    year: &mut Option<i32>,
    genre: &mut Option<String>,
    disc_no: &mut Option<u32>,
) {
    let trimmed = comment.trim();
    let mut parts = trimmed.splitn(2, |c: char| c.is_ascii_whitespace());
    let key = parts.next().unwrap_or_default();
    let val = parts
        .next()
        .unwrap_or_default()
        .trim()
        .trim_matches('"')
        .trim();
    if val.is_empty() {
        return;
    }
    if key.eq_ignore_ascii_case("DATE") && year.is_none() {
        if let Some(y) = val.get(..4).and_then(|s| s.parse::<i32>().ok()) {
            *year = Some(y);
        }
    } else if key.eq_ignore_ascii_case("GENRE") && genre.is_none() {
        *genre = Some(val.to_string());
    } else if key.eq_ignore_ascii_case("DISCNUMBER") && disc_no.is_none() {
        let num = val.split('/').next().unwrap_or(val).trim();
        if let Ok(d) = num.parse::<u32>() {
            *disc_no = Some(d);
        }
    }
}

#[cfg(test)]
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
mod tests {
    use super::*;

    #[test]
    fn parses_gbk_chinese_cue_sheet() {
        let utf8_cue = r#"REM GENRE Pop
REM DATE 2003
REM DISCNUMBER 1
PERFORMER "周杰伦"
TITLE "叶惠美"
FILE "CDImage.wav" WAVE
  TRACK 01 AUDIO
    TITLE "以父之名"
    PERFORMER "周杰伦"
    INDEX 01 00:00:00
  TRACK 02 AUDIO
    TITLE "晴天"
    INDEX 00 05:39:00
    INDEX 01 05:42:00
  TRACK 03 AUDIO
    TITLE "三年二班"
    INDEX 01 10:11:37
"#;
        let (gbk_bytes, _, _) = encoding_rs::GBK.encode(utf8_cue);
        let parsed = parse_cue_bytes(&gbk_bytes).unwrap();
        assert_eq!(parsed.album_title.as_deref(), Some("叶惠美"));
        assert_eq!(parsed.album_performer.as_deref(), Some("周杰伦"));
        assert_eq!(parsed.year, Some(2003));
        assert_eq!(parsed.genre.as_deref(), Some("Pop"));
        assert_eq!(parsed.disc_no, Some(1));
        assert_eq!(parsed.tracks.len(), 3);

        assert_eq!(parsed.tracks[0].title, "以父之名");
        assert_eq!(parsed.tracks[0].start_ms, 0);
        // Uses Track 02's INDEX 00 (05:39:00 = 339_000 ms)
        assert_eq!(parsed.tracks[0].end_ms, Some(339_000));

        assert_eq!(parsed.tracks[1].title, "晴天");
        assert_eq!(parsed.tracks[1].artist.as_deref(), Some("周杰伦"));
        assert_eq!(parsed.tracks[1].start_ms, 342_000);
        assert_eq!(parsed.tracks[1].end_ms, Some(611_493));

        assert_eq!(parsed.tracks[2].title, "三年二班");
        assert_eq!(parsed.tracks[2].end_ms, None);
    }

    #[test]
    fn resolves_mismatched_wav_ref_to_ape_file() {
        let cue = VfsPath::parse("Jay/叶惠美.cue").unwrap();
        let audio = vec![VfsPath::parse("Jay/叶惠美.ape").unwrap()];
        let resolved = resolve_cue_audio_path(&cue, "CDImage.wav", &audio, 1).unwrap();
        assert_eq!(resolved.as_str(), "Jay/叶惠美.ape");
    }
}
