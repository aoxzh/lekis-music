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

// Video platforms often supply the uploader as artist. Extract an explicit
// artist/title pair only as a search hint; it is not trusted for auto-apply.
fn video_identity(hint: &TrackHint) -> Option<(String, String)> {
    let folded = width_fold(&hint.title);
    let clean = clean_title(&folded, &[]);
    // Anime uploads commonly put the work and OP/ED label before the
    // quoted song, followed by its performer and a bracketed upload label.
    for (open, close) in [('「', '」'), ('『', '』')] {
        if let Some((context, rest)) = folded.split_once(open) {
            if let Some((song, tail)) = rest.split_once(close) {
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
                let artist = tail
                    .split(['【', '〖', '[', '('])
                    .next()
                    .unwrap_or("")
                    .trim();
                if anime_theme && !song.trim().is_empty() && !artist.is_empty() {
                    return Some((song.trim().to_string(), artist.to_string()));
                }
            }
        }
    }
    for (open, close) in [('「', '」'), ('『', '』')] {
        if let Some((artist, rest)) = clean.split_once(open) {
            if let Some((song, suffix)) = rest.split_once(close) {
                if !artist.trim().is_empty() && !song.trim().is_empty() && suffix.trim().is_empty()
                {
                    return Some((song.trim().to_string(), artist.trim().to_string()));
                }
            }
        }
    }
    let tagged = |part: &str| hint.artists.iter().any(|artist| key(artist) == key(part));
    for (offset, separator) in clean.match_indices(['|', '–', '—', '-', '/']) {
        let (left, right) = (&clean[..offset], &clean[offset + separator.len()..]);
        let (first, second) = (left.trim(), right.trim());
        if first.is_empty() || second.is_empty() {
            continue;
        }
        if tagged(second) {
            return Some((first.into(), second.into()));
        }
        if tagged(first) {
            return Some((second.into(), first.into()));
        }
        let spaced = left.ends_with(' ') && right.starts_with(' ');
        if (separator == "|" || spaced)
            && !clean[offset + separator.len()..].contains(['|', '—', '–'])
            && !matches!(
                key(second).as_str(),
                "live" | "remix" | "cover" | "acoustic" | "instrumental"
            )
        {
            return Some((second.into(), first.into()));
        }
    }
    None
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
    let identity = video_identity(hint);
    if let Some((song, performer)) = &identity {
        push(song.clone(), Some(performer.clone()));
    }
    push(clean.clone(), artist.clone());
    let (song, performer) =
        identity.map_or_else(|| (clean.clone(), artist.clone()), |(s, a)| (s, Some(a)));
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
    let (title, artist) = video_identity(hint)?;
    // A label such as Live or Cover must survive extraction and agree with the record.
    if versions(&hint.title) != versions(&matched.title) {
        return None;
    }
    let inferred = TrackHint {
        title,
        artists: vec![artist],
        ..hint.clone()
    };
    confidence_direct(&inferred, matched)
        .map(|score| score.min(super::super::AUTO_APPLY_THRESHOLD - 0.01))
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
