//! Conservative lyric identity checks, including explicit kana-script equivalents.
use super::{LyricsFormat, TrackHint};

pub(crate) fn width_fold(value: &str) -> String {
    value
        .chars()
        .map(|ch| match ch {
            '\u{ff01}'..='\u{ff5e}' => char::from_u32(ch as u32 - 0xfee0).unwrap_or(ch),
            '\u{3000}' => ' ',
            _ => ch,
        })
        .collect::<String>()
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

fn key(value: &str) -> String {
    width_fold(value)
        .chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

// Only the one-to-one modern kana range is converted. Kanji readings and
// half-width or compatibility forms are deliberately not inferred.
fn kana_fold(value: &str) -> String {
    value
        .chars()
        .map(|c| match c {
            '\u{30a1}'..='\u{30f6}' => char::from_u32(c as u32 - 0x60).unwrap_or(c),
            _ => c,
        })
        .collect()
}

fn kana_alternate(value: &str, to_katakana: bool) -> String {
    value
        .chars()
        .map(|c| match c {
            '\u{3041}'..='\u{3096}' if to_katakana => char::from_u32(c as u32 + 0x60).unwrap_or(c),
            '\u{30a1}'..='\u{30f6}' if !to_katakana => char::from_u32(c as u32 - 0x60).unwrap_or(c),
            _ => c,
        })
        .collect()
}

fn equivalent_kana(a: &str, b: &str) -> bool {
    let (a, b) = (key(a), key(b));
    a != b && kana_fold(&a) == kana_fold(&b)
}

fn is_media_label(value: &str) -> bool {
    matches!(
        key(value).as_str(),
        "officialmusicvideo"
            | "officialvideo"
            | "officialaudio"
            | "musicvideo"
            | "lyricvideo"
            | "lyricsvideo"
            | "officialmv"
            | "mv"
            | "pv"
            | "公式mv"
            | "公式musicvideo"
            | "歌詞付き"
    )
}

pub(super) fn clean_title(title: &str, artists: &[String]) -> String {
    let mut out = width_fold(title);
    // Quoted titles in official uploads are safe only when the prefix identifies
    // the tagged artist. Do not extract arbitrary anime names from brackets.
    for (open, close) in [('「', '」'), ('『', '』')] {
        if let Some((prefix, rest)) = out.split_once(open) {
            if let Some((name, suffix)) = rest.split_once(close) {
                if !name.trim().is_empty()
                    && is_media_label(suffix)
                    && artists.iter().any(|a| key(a) == key(prefix))
                {
                    return name.trim().to_string();
                }
            }
        }
    }
    loop {
        let before = out.clone();
        for (open, close) in [('(', ')'), ('[', ']'), ('【', '】')] {
            if out.ends_with(close) {
                if let Some(pos) = out.rfind(open) {
                    if pos > 0
                        && is_media_label(&out[pos + open.len_utf8()..out.len() - close.len_utf8()])
                    {
                        out.truncate(pos);
                        out = out
                            .trim()
                            .trim_end_matches(['-', '–', '—', '|'])
                            .trim()
                            .to_string();
                    }
                }
            }
        }
        for suffix in [
            "Official Music Video",
            "Official Video",
            "Official Audio",
            "Music Video",
            "Lyric Video",
            "Official MV",
        ] {
            if out.to_lowercase().ends_with(&suffix.to_lowercase()) && out.len() > suffix.len() {
                out.truncate(out.len() - suffix.len());
                out = out
                    .trim()
                    .trim_end_matches(['-', '–', '—', '|'])
                    .trim()
                    .to_string();
            }
        }
        if out == before {
            return out;
        }
    }
}

pub(super) fn normalized_hint(hint: &TrackHint) -> TrackHint {
    TrackHint {
        title: clean_title(&hint.title, &hint.artists),
        artists: hint.artists.iter().map(|a| width_fold(a)).collect(),
        album: hint.album.as_ref().map(|a| width_fold(a)),
        ..hint.clone()
    }
}

// Upload captions start with quality / format labels such as `【官方MV】`,
// `【4K/Hi-Res】` or `[Official Video]`. They describe the video, not the song,
// so strip them before looking for an artist/title pair.
fn is_caption_label(value: &str) -> bool {
    let compact = key(value);
    if compact.is_empty() {
        return false;
    }
    if is_media_label(value) {
        return true;
    }
    const MARKERS: &[&str] = &[
        "官方",
        "视频",
        "影片",
        "中字",
        "字幕",
        "双字",
        "完整版",
        "高清",
        "无损",
        "试听",
        "现场",
        "official",
        "musicvideo",
        "lyricvideo",
        "video",
        "audio",
        "mv",
        "pv",
        "4k",
        "8k",
        "hires",
        "1080p",
        "720p",
        "hd",
        "remaster",
    ];
    MARKERS.iter().any(|marker| compact.contains(marker))
}

fn strip_leading_caption_labels(mut value: &str) -> &str {
    loop {
        let mut stripped = false;
        for (open, close) in [('【', '】'), ('[', ']')] {
            let Some(inner) = value.strip_prefix(open) else {
                continue;
            };
            let Some((label, tail)) = inner.split_once(close) else {
                continue;
            };
            if !is_caption_label(label) {
                continue;
            }
            value = tail.trim_start_matches(|c: char| {
                c.is_whitespace() || matches!(c, '｜' | '|' | '·' | '-' | '–' | '—')
            });
            stripped = true;
            break;
        }
        if !stripped {
            return value;
        }
    }
}

/// Whether `value` begins with a media label such as `Official Music Video`,
/// even when a performer or `VOCAL: ...` note follows it.
fn starts_with_media_label(value: &str) -> bool {
    if is_media_label(value) {
        return true;
    }
    let mut prefix = String::new();
    for word in value.split_whitespace().take(5) {
        if !prefix.is_empty() {
            prefix.push(' ');
        }
        prefix.push_str(word);
        if is_media_label(&prefix) {
            return true;
        }
    }
    value
        .split(['-', '–', '—', '|'])
        .next()
        .is_some_and(is_media_label)
}

/// Quoted titles (「」, 『』, 《》) are explicit in a way that a bare dash is not.
/// Anime uploads put the work and OP/ED label before the song; everything else
/// is normally `Artist「Song」` or `Artist《Song》`.
fn quoted_identity(value: &str) -> Option<(String, String)> {
    for (open, close) in [('「', '」'), ('『', '』'), ('《', '》')] {
        let Some((context, rest)) = value.split_once(open) else {
            continue;
        };
        let Some((song, tail)) = rest.split_once(close) else {
            continue;
        };
        let (context, song, tail) = (context.trim(), song.trim(), tail.trim());
        if context.is_empty() || song.is_empty() {
            continue;
        }
        let context_key = key(context);
        let anime_theme = [
            "op主题曲",
            "ed主题曲",
            "op主題歌",
            "ed主題歌",
            "オープニングテーマ",
            "エンディングテーマ",
        ]
        .iter()
        .any(|label| context_key.ends_with(label));
        if anime_theme {
            let artist = tail
                .split(['【', '〖', '[', '(', '（'])
                .next()
                .unwrap_or("")
                .trim();
            if !artist.is_empty() {
                return Some((song.to_string(), artist.to_string()));
            }
        }
        if tail.is_empty() || starts_with_media_label(tail) {
            return Some((song.to_string(), context.to_string()));
        }
    }
    None
}

fn separator_identities(value: &str, had_caption: bool, hint: &TrackHint) -> Vec<(String, String)> {
    let tagged = |part: &str| hint.artists.iter().any(|artist| key(artist) == key(part));
    let mut out = Vec::new();
    for (offset, separator) in value.match_indices(['|', '–', '—', '-', '/']) {
        let (left, right) = (&value[..offset], &value[offset + separator.len()..]);
        let (first, second) = (left.trim(), right.trim());
        if first.is_empty() || second.is_empty() {
            continue;
        }
        if tagged(second) {
            out.push((first.into(), second.into()));
        } else if tagged(first) {
            out.push((second.into(), first.into()));
        } else {
            let spaced = left.ends_with(' ') && right.starts_with(' ');
            let version_word = matches!(
                key(second).as_str(),
                "live" | "remix" | "cover" | "acoustic" | "instrumental"
            );
            if (separator == "|" || spaced)
                && !value[offset + separator.len()..].contains(['|', '—', '–'])
                && !version_word
            {
                out.push((second.into(), first.into()));
            } else if separator == "-" && had_caption {
                // `【官方MV】念-薛之谦` and `【官方MV】薛之谦-念` are both common.
                // Both orientations are search hints; the identity gate still
                // requires the candidate to agree on title, artist and version.
                let before = left.chars().next_back();
                let after = right.chars().next();
                if before.is_some_and(|c| !c.is_ascii_alphanumeric())
                    && after.is_some_and(|c| !c.is_ascii_alphanumeric())
                {
                    out.push((first.into(), second.into()));
                    out.push((second.into(), first.into()));
                }
            }
        }
        if !out.is_empty() {
            break;
        }
    }
    out
}

// Video platforms often supply the uploader as artist. Extract explicit
// artist/title pairs only as a search hint; it is not trusted for auto-apply.
fn video_identities(hint: &TrackHint) -> Vec<(String, String)> {
    let folded = width_fold(&hint.title);
    let body = strip_leading_caption_labels(&folded);
    let had_caption = body.len() != folded.len();
    let clean = clean_title(body, &[]);
    let mut out = Vec::new();
    let mut push = |song: String, artist: String| {
        let pair = (song.trim().to_string(), artist.trim().to_string());
        if !pair.0.is_empty() && !pair.1.is_empty() && !out.contains(&pair) {
            out.push(pair);
        }
    };
    if let Some((song, artist)) = quoted_identity(body).or_else(|| quoted_identity(&clean)) {
        push(song, artist);
    }
    for (song, artist) in separator_identities(&clean, had_caption, hint) {
        push(song, artist);
    }
    out
}

fn space_scripts(text: &str) -> String {
    let mut out = String::new();
    let mut previous = None;
    for ch in text.chars() {
        let script = match ch {
            'a'..='z' | 'A'..='Z' => Some(false),
            '\u{3040}'..='\u{30ff}' | '\u{3400}'..='\u{9fff}' | '\u{ac00}'..='\u{d7a3}' => {
                Some(true)
            }
            _ => None,
        };
        if previous.is_some() && script.is_some() && previous != script {
            out.push(' ');
        }
        out.push(ch);
        previous = script;
    }
    out
}

pub(crate) fn search_variants(hint: &TrackHint) -> Vec<(String, Option<String>)> {
    let artist = hint
        .artists
        .iter()
        .find(|a| !a.trim().is_empty())
        .map(|a| a.trim().to_string());
    let mut variants = Vec::new();
    let mut push = |title: String, artist: Option<String>| {
        let query = (title, artist);
        if !query.0.is_empty() && !variants.contains(&query) {
            variants.push(query);
        }
    };
    push(hint.title.trim().into(), artist.clone());
    let clean = clean_title(&hint.title, &hint.artists);
    let identities = video_identities(hint);
    for (song, performer) in &identities {
        push(song.clone(), Some(performer.clone()));
    }
    push(clean.clone(), artist.clone());
    let (song, performer) = identities.first().map_or_else(
        || (clean.clone(), artist.clone()),
        |(song, performer)| (song.clone(), Some(performer.clone())),
    );
    push(space_scripts(&song), performer);
    if artist.is_some() {
        push(clean, None);
    }
    // Keep every existing search first, then add at most four script alternatives.
    // Each remains subject to the original identity and version gates.
    let original = variants.clone();
    for (title, artist) in original {
        for to_katakana in [false, true] {
            let alternate = (
                kana_alternate(&title, to_katakana),
                artist.as_ref().map(|a| kana_alternate(a, to_katakana)),
            );
            if alternate != (title.clone(), artist.clone()) && !variants.contains(&alternate) {
                variants.push(alternate);
                if variants.len() >= 8 {
                    return variants;
                }
            }
        }
    }
    variants
}

pub(crate) fn versions(title: &str) -> Vec<bool> {
    let folded = width_fold(title).to_lowercase();
    let compact = key(title);
    [
        &["tvsize", "tvサイズ", "テレビサイズ"][..],
        &["shortversion", "shortver", "ショートバージョン"],
        &["live", "ライブ", "ライヴ", "现场", "現場"],
        &["remix", "リミックス"],
        &["instrumental", "offvocal", "カラオケ", "karaoke", "伴奏"],
        &["cover", "カバー", "歌ってみた", "翻唱"],
        &["acoustic", "アコースティック"],
    ]
    .iter()
    .map(|group| {
        group.iter().any(|v| {
            if v.is_ascii() {
                // ASCII version words must start/end at word boundaries: Deliver is not Live.
                folded.match_indices(v).any(|(start, _)| {
                    let end = start + v.len();
                    !folded[..start]
                        .chars()
                        .next_back()
                        .is_some_and(|c| c.is_ascii_alphanumeric())
                        && !folded[end..]
                            .chars()
                            .next()
                            .is_some_and(|c| c.is_ascii_alphanumeric())
                }) || folded
                    .split(|c: char| !c.is_ascii_alphanumeric())
                    .filter(|s| !s.is_empty())
                    .collect::<Vec<_>>()
                    .windows(2)
                    .any(|pair| pair.concat() == *v)
            } else {
                compact.contains(v)
            }
        })
    })
    .collect()
}

/// Identity is a gate before the weighted score. Duration cannot compensate for
/// an unrelated title/artist, or turn TV-size and live recordings into an album cut.
pub(crate) fn confidence(hint: &TrackHint, matched: &TrackHint) -> Option<f32> {
    if let Some(score) = confidence_direct(hint, matched) {
        return Some(score);
    }
    // A label such as Live or Cover must survive extraction and agree with the record.
    if versions(&hint.title) != versions(&matched.title) {
        return None;
    }
    let mut best = None;
    for (title, artist) in video_identities(hint) {
        let inferred = TrackHint {
            title,
            artists: vec![artist],
            ..hint.clone()
        };
        if let Some(score) = confidence_direct(&inferred, matched) {
            let score = score.min(super::super::AUTO_APPLY_THRESHOLD - 0.01);
            best = Some(best.map_or(score, |current: f32| current.max(score)));
        }
    }
    best
}

fn confidence_direct(hint: &TrackHint, matched: &TrackHint) -> Option<f32> {
    let mut hint = normalized_hint(hint);
    let mut matched = normalized_hint(matched);
    // Only substitute when the entire normalized field is otherwise identical;
    // this cannot make a partial/fuzzy Japanese match cross the identity gate.
    if equivalent_kana(&hint.title, &matched.title) {
        hint.title = kana_fold(&hint.title);
        matched.title = kana_fold(&matched.title);
    }
    for a in &mut hint.artists {
        for b in &mut matched.artists {
            if equivalent_kana(a, b) {
                *a = kana_fold(a);
                *b = kana_fold(b);
            }
        }
    }
    let title = super::super::scoring::similarity(&hint.title, &matched.title);
    if title < 0.75 || versions(&hint.title) != versions(&matched.title) {
        return None;
    }
    let artist = hint
        .artists
        .iter()
        .filter(|a| !a.trim().is_empty())
        .flat_map(|a| {
            matched
                .artists
                .iter()
                .filter(|b| !b.trim().is_empty())
                .map(move |b| super::super::scoring::similarity(a, b))
        })
        .reduce(f32::max);
    if artist.is_some_and(|score| score < 0.6) {
        return None;
    }
    if hint.duration_ms > 0
        && matched.duration_ms > 0
        && hint.duration_ms.abs_diff(matched.duration_ms) > 10_000
    {
        return None;
    }
    let score = super::as_confidence(super::score_match(
        &hint,
        &matched.title,
        &matched.artists.join(" / "),
        matched.album.as_deref(),
        matched.duration_ms,
    ));
    // A search without an artist is a useful manual candidate, never a reason
    // to guess a performer automatically. Likewise, fuzzy title variants need review.
    Some(if artist.is_none() || title < 0.95 {
        score.min(super::super::AUTO_APPLY_THRESHOLD - 0.01)
    } else {
        score
    })
}

pub(super) fn has_synced_hit(candidates: &[super::Candidate<super::LyricsPayload>]) -> bool {
    candidates.iter().any(|c| {
        c.payload.format == LyricsFormat::Lrc
            && c.provider_confidence >= super::super::AUTO_APPLY_THRESHOLD
    })
}

pub(super) fn sort(candidates: &mut Vec<super::Candidate<super::LyricsPayload>>) {
    candidates.sort_by(|a, b| {
        // Strong synced lyrics precede a plain fallback. A low-confidence synced
        // candidate must not hide a reliable plain transcription of the right song.
        let rank = |c: &super::Candidate<super::LyricsPayload>| {
            (
                c.provider_confidence >= super::super::AUTO_APPLY_THRESHOLD,
                c.payload.format == LyricsFormat::Lrc,
            )
        };
        rank(b)
            .cmp(&rank(a))
            .then(b.provider_confidence.total_cmp(&a.provider_confidence))
    });
    candidates.dedup_by(|a, b| a.payload == b.payload && a.matched == b.matched);
    candidates.truncate(super::MAX_CANDIDATES);
}
