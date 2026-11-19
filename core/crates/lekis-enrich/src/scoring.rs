//! 匹配打分（ENR-05）。
//!
//! 有 MBID 且一致：直接 1.0。否则按"标题 + 艺人 + 专辑 + 时长"加权：
//!
//! | 项 | 权重 | 说明 |
//! |---|---|---|
//! | 标题 | 0.40 | 去掉括号里的 (Live)、(Remastered) 等后缀再比 |
//! | 艺人 | 0.30 | 任意一个艺人匹配就算；候选的多个艺人会先拆开 |
//! | 时长 | 0.20 | 差 ≤ 2 秒满分，差 ≥ 10 秒零分，中间线性衰减 |
//! | 专辑 | 0.10 | 双方都有专辑时才计算，否则这部分按 0.5 给分 |
//!
//! 最后乘以提供方自己的置信度（ENR-05："分数和来源都可解释"：
//! [`Explanation`] 能把四个分项和最终分数一起交出去，UI 的待确认队列直接展示）。
//!
//! **中英文名互查**：除了直接比较，还会比较汉字的拼音形式，于是
//! "周杰伦" ↔ "Zhou Jielun"、"周杰倫" ↔ "周杰伦" 都能匹配上（pinyin 表覆盖繁体字）。
//! 真正的别名互查（周杰伦 ↔ Jay Chou）需要 MusicBrainz 的 alias 数据，属于以后接指纹
//! 时一起做的事，这里不假装能靠拼音解决。

use crate::{Candidate, TrackHint};
use pinyin::ToPinyin;

/// 各分项权重（和模块文档里的表一致，改这里就要改文档）。
const WEIGHT_TITLE: f32 = 0.40;
const WEIGHT_ARTIST: f32 = 0.30;
const WEIGHT_DURATION: f32 = 0.20;
const WEIGHT_ALBUM: f32 = 0.10;

/// 候选艺人字符串里常见的多艺人分隔符。
const ARTIST_SEPARATORS: [&str; 5] = ["/", ";", "&", ",", "、"];

/// 单次匹配的分项拆解。UI 用它解释"为什么给了 0.83 分"。
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Explanation {
    /// 标题相似度（0..=1）。
    pub title: f32,
    /// 艺人相似度（0..=1）。
    pub artist: f32,
    /// 时长相似度（0..=1）。
    pub duration: f32,
    /// 专辑相似度（0..=1）。
    pub album: f32,
    /// 加权后的原始分数（未乘提供方置信度）。
    pub weighted: f32,
    /// 乘上提供方置信度后的最终分数。
    pub final_score: f32,
    /// 是否走了 MBID 直通（MBID 一致时直接满分，其余分项无意义）。
    pub mbid_hit: bool,
}

/// 计算候选的匹配分数（0..=1），并返回分项拆解。
///
/// MBID 两边都有时以 MBID 为准（一致 → 满分，不一致 → 0 分）。
pub fn explain<T>(hint: &TrackHint, candidate: &Candidate<T>) -> Explanation {
    let matched = &candidate.matched;

    if let (Some(a), Some(b)) = (&hint.mbid_recording, &matched.mbid_recording) {
        let hit = a.eq_ignore_ascii_case(b);
        let raw = if hit { 1.0 } else { 0.0 };
        return Explanation {
            title: raw,
            artist: raw,
            duration: raw,
            album: raw,
            weighted: raw,
            final_score: (raw * candidate.provider_confidence).clamp(0.0, 1.0),
            mbid_hit: hit,
        };
    }

    let title = title_similarity(&hint.title, &matched.title);
    let artist = artist_similarity(&hint.artists, &matched.artists);
    let duration = duration_score(hint.duration_ms, matched.duration_ms);
    let album = match (&hint.album, &matched.album) {
        (Some(a), Some(b)) => similarity(a, b),
        _ => 0.5,
    };
    let weighted = WEIGHT_TITLE * title
        + WEIGHT_ARTIST * artist
        + WEIGHT_DURATION * duration
        + WEIGHT_ALBUM * album;

    Explanation {
        title,
        artist,
        duration,
        album,
        weighted,
        final_score: (weighted * candidate.provider_confidence).clamp(0.0, 1.0),
        mbid_hit: false,
    }
}

/// 计算候选的匹配分数（0..=1）。
pub fn score<T>(hint: &TrackHint, candidate: &Candidate<T>) -> f32 {
    explain(hint, candidate).final_score
}

/// 直接对"候选自己描述的曲目信息"打分（ENR-05 的核心公式）。
///
/// 提供方拿到一条搜索结果后直接调它填 [`Candidate::provider_confidence`]，
/// 不需要先造一个完整的 [`Candidate`]。返回 f64 方便和 JSON 里的双精度数值对照。
pub fn score_match(
    hint: &TrackHint,
    candidate_title: &str,
    candidate_artist: &str,
    candidate_album: Option<&str>,
    candidate_duration_ms: u64,
) -> f64 {
    let title = title_similarity(&hint.title, candidate_title);
    let artist = artist_similarity(
        &hint.artists,
        &split_artists(candidate_artist)
            .into_iter()
            .map(str::to_string)
            .collect::<Vec<_>>(),
    );
    let duration = duration_score(hint.duration_ms, candidate_duration_ms);
    let album = match (hint.album.as_deref(), candidate_album) {
        (Some(a), Some(b)) if !a.trim().is_empty() && !b.trim().is_empty() => similarity(a, b),
        _ => 0.5,
    };

    let raw = WEIGHT_TITLE * title
        + WEIGHT_ARTIST * artist
        + WEIGHT_DURATION * duration
        + WEIGHT_ALBUM * album;
    f64::from(raw.clamp(0.0, 1.0))
}

/// 标题相似度：先去掉版本后缀，再比。
fn title_similarity(a: &str, b: &str) -> f32 {
    similarity(&strip_suffix(a), &strip_suffix(b))
}

/// 艺人相似度：任意一对艺人匹配就算，取最大值。
fn artist_similarity(hint_artists: &[String], candidate_artists: &[String]) -> f32 {
    if hint_artists.is_empty() || candidate_artists.is_empty() {
        // 双方都没艺人信息时不该因此把分数打到 0，给个中性值。
        return 0.5;
    }
    let mut best = 0.0f32;
    for a in hint_artists {
        for b in candidate_artists {
            best = best.max(similarity(a, b));
        }
    }
    best
}

/// 把"Artist A / Artist B"这种串拆成多个艺人。
fn split_artists(artist: &str) -> Vec<&str> {
    let mut parts = vec![artist];
    for separator in ARTIST_SEPARATORS {
        parts = parts
            .into_iter()
            .flat_map(|part| part.split(separator))
            .collect();
    }
    parts
        .into_iter()
        .map(str::trim)
        .filter(|part| !part.is_empty())
        .collect()
}

fn duration_score(a_ms: u64, b_ms: u64) -> f32 {
    if a_ms == 0 || b_ms == 0 {
        // 时长未知（流媒体服务器常常不给，或者本地文件没读到）时不惩罚也不加分。
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

/// 汉字的拼音形式（非汉字原样保留，去掉声调只留字母）。
///
/// 这样 "周杰伦" → "zhoujielun"、"周杰倫" → "zhoujielun"（繁体也能查到拼音），
/// 于是繁简、拼音和汉字的两种写法都能互相比较。
fn pinyin_normalize(s: &str) -> Vec<char> {
    let mut out = String::with_capacity(s.len() * 3);
    for ch in s.chars() {
        match ch.to_pinyin() {
            Some(pinyin) => out.push_str(pinyin.plain()),
            None => {
                if ch.is_alphanumeric() {
                    out.extend(ch.to_lowercase());
                }
            }
        }
    }
    out.chars().collect()
}

/// 字符串相似度（0..=1），基于字符 bigram 的 Dice 系数。对中文（没有空格分词）也适用。
///
/// 除了直接比较，还会比较拼音形式，取两者较大的一个（ENR-05 的中英文名互查）。
pub fn similarity(a: &str, b: &str) -> f32 {
    let direct = dice(&normalize(a), &normalize(b));
    if direct >= 1.0 {
        return 1.0;
    }
    let transliterated = dice(&pinyin_normalize(a), &pinyin_normalize(b));
    direct.max(transliterated)
}

/// 两个有序字符序列的 Dice 系数。
fn dice(a: &[char], b: &[char]) -> f32 {
    if a.is_empty() || b.is_empty() {
        return 0.0;
    }
    if a == b {
        return 1.0;
    }
    if a.len() == 1 || b.len() == 1 {
        // 单字符只可能是"部分匹配"，用精确比较会误判，索性给 0；
        // 拼音化之后的单字符比较仍然有效。
        return if a == b { 1.0 } else { 0.0 };
    }
    let bigrams = |v: &[char]| v.windows(2).map(|w| (w[0], w[1])).collect::<Vec<_>>();
    let (ba, mut bb) = (bigrams(a), bigrams(b));
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
#[allow(clippy::unwrap_used, clippy::expect_used, clippy::panic)]
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

    fn hint(title: &str, artist: &str, duration_ms: u64) -> TrackHint {
        TrackHint {
            title: title.into(),
            artists: vec![artist.into()],
            duration_ms,
            ..Default::default()
        }
    }

    #[test]
    fn exact_match_scores_high() {
        let h = hint("晴天", "周杰伦", 269_000);
        assert!(score(&h, &cand("晴天 (Live)", "周杰伦", 270_000)) >= crate::AUTO_APPLY_THRESHOLD);
        assert!(
            score(
                &h,
                &cand("Symphony No. 9", "Berliner Philharmoniker", 4_000_000)
            ) < crate::REVIEW_THRESHOLD
        );
    }

    #[test]
    fn similarity_basics() {
        assert_eq!(similarity("Hello", "hello!"), 1.0);
        assert!(similarity("night", "nacht") < 0.5);
    }

    /// 完全一致的候选应该拿到接近满分的分数（含专辑）。
    #[test]
    fn score_match_perfect_candidate() {
        let h = TrackHint {
            title: "Bohemian Rhapsody".into(),
            artists: vec!["Queen".into()],
            album: Some("A Night at the Opera".into()),
            duration_ms: 354_000,
            ..Default::default()
        };
        let value = score_match(
            &h,
            "Bohemian Rhapsody",
            "Queen",
            Some("A Night at the Opera"),
            354_000,
        );
        assert!(value > 0.99, "score = {value}");
        assert!(value <= 1.0);
    }

    /// 线索里没有专辑信息时，专辑项只损失"中性值"那一半，不该断崖式掉分。
    #[test]
    fn score_match_unknown_album_is_neutral() {
        let h = hint("Bohemian Rhapsody", "Queen", 354_000);
        let value = score_match(
            &h,
            "Bohemian Rhapsody",
            "Queen",
            Some("A Night at the Opera"),
            354_000,
        );
        assert!((value - 0.95).abs() < 0.01, "score = {value}");
        assert!(value >= f64::from(crate::AUTO_APPLY_THRESHOLD));
    }

    /// 时长差 2 秒以内不扣分；差 10 秒以上时长项归零。
    #[test]
    fn score_match_duration_band() {
        let h = hint("Song", "Artist", 200_000);
        let exact = score_match(&h, "Song", "Artist", None, 200_000);
        let within_two = score_match(&h, "Song", "Artist", None, 201_900);
        let too_long = score_match(&h, "Song", "Artist", None, 240_000);
        assert_eq!(exact, within_two, "±2 秒内应该同分");
        assert!(
            exact > too_long,
            "时长差 40 秒应该掉分：{exact} vs {too_long}"
        );
        // 时长权重 0.20，掉光就是差 0.20。
        assert!((exact - too_long - 0.20).abs() < 0.001, "差值应为 0.20");
    }

    /// 时长未知时给中性分，不用 0 分误杀。
    #[test]
    fn score_match_unknown_duration_is_neutral() {
        let h = hint("Song", "Artist", 0);
        let value = score_match(&h, "Song", "Artist", None, 200_000);
        // 满分 1.0 - 时长项损失 0.20*0.5 - 专辑项损失 0.10*0.5 = 0.85。
        assert!((value - 0.85).abs() < 0.01, "score = {value}");
    }

    /// 艺人部分匹配（候选是 "Queen & David Bowie"）也算命中。
    #[test]
    fn score_match_multi_artist_candidate() {
        let h = hint("Under Pressure", "Queen", 248_000);
        let value = score_match(&h, "Under Pressure", "Queen & David Bowie", None, 248_000);
        assert!(value >= 0.94, "score = {value}");
    }

    /// 专辑不同会小幅扣分（权重 0.10），但不会把强匹配拖到阈值以下。
    #[test]
    fn score_match_album_only_penalty() {
        let h = TrackHint {
            title: "Song".into(),
            artists: vec!["Artist".into()],
            album: Some("Album A".into()),
            duration_ms: 200_000,
            ..Default::default()
        };
        let same = score_match(&h, "Song", "Artist", Some("Album A"), 200_000);
        let other = score_match(&h, "Song", "Artist", Some("Completely Different"), 200_000);
        assert!(same > other);
        assert!(other >= 0.85, "专辑不同不该掉出自动应用阈值：{other}");
    }

    /// 完全不相关的候选要落到丢弃区。
    #[test]
    fn score_match_unrelated_candidate_is_discarded() {
        let h = hint("晴天", "周杰伦", 269_000);
        let value = score_match(
            &h,
            "Symphony No. 9",
            "Berliner Philharmoniker",
            Some("Beethoven"),
            4_000_000,
        );
        assert!(
            value < f64::from(crate::REVIEW_THRESHOLD),
            "score = {value}"
        );
    }

    /// 中英文名互查：拼音写法和汉字写法能匹配（ENR-05）。
    #[test]
    fn score_match_pinyin_cross_language() {
        let h = hint("晴天", "周杰伦", 269_000);
        let pinyin_value = score_match(&h, "Qing Tian", "Zhou Jielun", None, 269_000);
        let unrelated = score_match(
            &h,
            "Seven Miles of Fragrance",
            "Someone Else",
            None,
            269_000,
        );
        assert!(
            pinyin_value > unrelated,
            "拼音写法应该比无关候选分高：{pinyin_value} vs {unrelated}"
        );
        assert!(
            pinyin_value > 0.5,
            "拼音写法应能进入待确认区以上：{pinyin_value}"
        );
    }

    /// 繁体 ↔ 简体经过拼音后一致。
    #[test]
    fn similarity_handles_traditional_and_simplified() {
        let value = similarity("周杰倫", "周杰伦");
        assert!(value >= 0.99, "繁简同一名字的相似度 = {value}");
        assert!(similarity("陳奕迅", "陈奕迅") >= 0.99);
    }

    /// MBID 一致直接满分；不一致直接 0 分（不再看标题）。
    #[test]
    fn mbid_takes_priority() {
        let mbid = "b1a9c0f4-1c1e-4f5a-9a4e-000000000001";
        let mut h = hint("Whatever", "Whoever", 1000);
        h.mbid_recording = Some(mbid.into());
        let mut same = cand("Totally Different", "Other", 999_000);
        same.matched.mbid_recording = Some(mbid.to_uppercase());
        assert_eq!(score(&h, &same), 1.0);

        let mut different = cand("Totally Different", "Other", 999_000);
        different.matched.mbid_recording = Some("00000000-0000-0000-0000-000000000000".into());
        assert_eq!(score(&h, &different), 0.0);
    }

    /// 提供方置信度是最后的乘数（ENR-05：分数可解释）。
    #[test]
    fn provider_confidence_multiplies() {
        let h = hint("Song", "Artist", 200_000);
        let mut candidate = cand("Song", "Artist", 200_000);
        let full = score(&h, &candidate);
        candidate.provider_confidence = 0.5;
        let half = score(&h, &candidate);
        assert!((half - full * 0.5).abs() < 0.001);
    }

    /// `explain` 的分项加起来就是 weighted 分数。
    #[test]
    fn explanation_components_add_up() {
        let h = TrackHint {
            title: "晴天".into(),
            artists: vec!["周杰伦".into()],
            album: Some("叶惠美".into()),
            duration_ms: 269_000,
            ..Default::default()
        };
        let mut candidate = cand("晴天", "周杰伦", 269_000);
        candidate.matched.album = Some("叶惠美".into());
        let detail = explain(&h, &candidate);
        let recomputed = WEIGHT_TITLE * detail.title
            + WEIGHT_ARTIST * detail.artist
            + WEIGHT_DURATION * detail.duration
            + WEIGHT_ALBUM * detail.album;
        assert!((recomputed - detail.weighted).abs() < 1e-6);
        assert!(!detail.mbid_hit);
        assert!(detail.final_score >= 0.99, "final = {}", detail.final_score);
    }

    #[test]
    fn strip_suffix_handles_bracket_variants() {
        assert_eq!(strip_suffix("晴天 (Live)"), "晴天");
        assert_eq!(strip_suffix("晴天（现场版）"), "晴天");
        assert_eq!(strip_suffix("Song [Remastered 2011]"), "Song");
        assert_eq!(strip_suffix("(Intro)"), "(Intro)");
    }
}
