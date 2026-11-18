//! 匹配打分（ENR-05）。
//!
//! 有 MBID 且一致：直接 1.0。否则按"标题 + 艺人 + 专辑 + 时长"加权：
//!
//! | 项 | 权重 | 说明 |
//! |---|---|---|
//! | 标题 | 0.40 | 去掉括号里的 (Live)、(Remastered) 等后缀再比 |
//! | 艺人 | 0.30 | 任意一个艺人匹配就算 |
//! | 时长 | 0.20 | 差 ≤ 2 秒满分，差 ≥ 10 秒零分 |
//! | 专辑 | 0.10 | 双方都有专辑时才计算，否则这部分按 0.5 给分 |
//!
//! 最后乘以提供方自己的置信度。
//!
//! TODO：中英文名互查（周杰伦 ↔ Jay Chou，用 MusicBrainz 别名）；繁简转换后再比较。

use crate::{Candidate, TrackHint};

/// 计算候选的匹配分数（0..=1）。
pub fn score<T>(hint: &TrackHint, candidate: &Candidate<T>) -> f32 {
    let m = &candidate.matched;
    if let (Some(a), Some(b)) = (&hint.mbid_recording, &m.mbid_recording) {
        return if a.eq_ignore_ascii_case(b) {
            candidate.provider_confidence
        } else {
            0.0
        };
    }

    let title = similarity(&strip_suffix(&hint.title), &strip_suffix(&m.title));
    let artist = hint
        .artists
        .iter()
        .flat_map(|a| m.artists.iter().map(move |b| similarity(a, b)))
        .fold(0.0f32, f32::max);
    let duration = duration_score(hint.duration_ms, m.duration_ms);
    let album = match (&hint.album, &m.album) {
        (Some(a), Some(b)) => similarity(a, b),
        _ => 0.5,
    };

    let raw = 0.40 * title + 0.30 * artist + 0.20 * duration + 0.10 * album;
    (raw * candidate.provider_confidence).clamp(0.0, 1.0)
}

fn duration_score(a_ms: u64, b_ms: u64) -> f32 {
    if a_ms == 0 || b_ms == 0 {
        return 0.5;
    }
    let diff = a_ms.abs_diff(b_ms) as f32 / 1000.0;
    if diff <= 2.0 {
        1.0
    } else if diff >= 10.0 {
        0.0
    } else {
        1.0 - (diff - 2.0) / 8.0
    }
}

/// 去掉标题末尾括号里的版本说明。
fn strip_suffix(s: &str) -> String {
    let mut out = s.trim().to_string();
    for (open, close) in [('(', ')'), ('（', '）'), ('[', ']')] {
        if out.ends_with(close) {
            if let Some(i) = out.rfind(open) {
                if i > 0 {
                    out.truncate(i);
                }
            }
        }
    }
    out.trim().to_string()
}

fn normalize(s: &str) -> Vec<char> {
    s.chars()
        .filter(|c| c.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// 字符串相似度（0..=1），基于字符 bigram 的 Dice 系数。对中文（没有空格分词）也适用。
pub fn similarity(a: &str, b: &str) -> f32 {
    let (a, b) = (normalize(a), normalize(b));
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    if a == b {
        return 1.0;
    }
    if a.len() == 1 || b.len() == 1 {
        return 0.0;
    }
    let bigrams = |v: &[char]| v.windows(2).map(|w| (w[0], w[1])).collect::<Vec<_>>();
    let (ba, mut bb) = (bigrams(&a), bigrams(&b));
    let total = (ba.len() + bb.len()) as f32;
    let mut common = 0usize;
    for g in &ba {
        if let Some(pos) = bb.iter().position(|x| x == g) {
            bb.swap_remove(pos);
            common += 1;
        }
    }
    2.0 * common as f32 / total
}

#[cfg(test)]
mod tests {
    use super::*;

    fn cand(title: &str, artist: &str, duration_ms: u64) -> Candidate<()> {
        Candidate {
            payload: (),
            source: "test".into(),
            matched: TrackHint {
                title: title.into(),
                artists: vec![artist.into()],
                duration_ms,
                ..Default::default()
            },
            provider_confidence: 1.0,
        }
    }

    #[test]
    fn exact_match_scores_high() {
        let hint = TrackHint {
            title: "晴天".into(),
            artists: vec!["周杰伦".into()],
            duration_ms: 269_000,
            ..Default::default()
        };
        assert!(
            score(&hint, &cand("晴天 (Live)", "周杰伦", 270_000)) >= crate::AUTO_APPLY_THRESHOLD
        );
        assert!(score(&hint, &cand("七里香", "周杰伦", 299_000)) < crate::REVIEW_THRESHOLD);
    }

    #[test]
    fn similarity_basics() {
        assert_eq!(similarity("Hello", "hello!"), 1.0);
        assert!(similarity("night", "nacht") < 0.5);
    }
}
