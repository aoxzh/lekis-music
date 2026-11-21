//! 根据播放位置决定悬浮窗显示什么（纯函数，与平台无关）。

use crate::model::{LyricsDoc, Word};

/// 什么都没在播 / 歌词还没到时显示的占位文字。
pub const IDLE_TEXT: &str = "Lekis 桌面歌词";
/// 间奏（空行）时显示的文字。
pub const INTERLUDE_TEXT: &str = "♪ ♪ ♪";

/// 主行的高亮程度。
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Fill {
    /// 整行用未唱颜色（占位文字）。
    Nothing,
    /// 整行用已唱颜色（没有逐字时间的当前行、曲名）。
    All,
    /// 卡拉 OK：`word` 之前的字已唱完，`word` 唱到 `fraction`（0..=1）。
    Partial {
        /// 正在唱的字。
        word: usize,
        /// 这个字唱了多少。
        fraction: f32,
    },
}

/// 主行是什么（渲染缓存用它判断要不要重新排版）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum PrimaryKind {
    /// 占位文字。
    Idle,
    /// 曲名（没有同步歌词，或第一行之前）。
    Title,
    /// 第 n 行歌词。
    Line(usize),
}

/// 某一时刻悬浮窗的内容。
#[derive(Debug, Clone, PartialEq)]
pub struct View<'a> {
    /// 主行来源。
    pub kind: PrimaryKind,
    /// 主行文字。
    pub primary: &'a str,
    /// 主行的逐字时间（可能为空）。
    pub words: &'a [Word],
    /// 主行高亮。
    pub fill: Fill,
    /// 第二行（小字）。
    pub secondary: Option<&'a str>,
    /// 卡拉 OK 填充正在推进：需要按显示器刷新率重绘。
    pub animating: bool,
    /// 再过多少毫秒主行会换（播放中才有意义）。
    pub next_change_in_ms: Option<u64>,
}

impl View<'_> {
    fn idle() -> View<'static> {
        View {
            kind: PrimaryKind::Idle,
            primary: IDLE_TEXT,
            words: &[],
            fill: Fill::Nothing,
            secondary: None,
            animating: false,
            next_change_in_ms: None,
        }
    }
}

fn non_empty(s: &str) -> Option<&str> {
    (!s.trim().is_empty()).then_some(s)
}

/// 计算 `position_ms` 时的内容。`track_id` 是播放时钟当前的曲目。
pub fn view<'a>(
    doc: Option<&'a LyricsDoc>,
    track_id: Option<i64>,
    position_ms: u64,
    two_line: bool,
) -> View<'a> {
    let Some(doc) = doc else {
        return View::idle();
    };
    if track_id.is_none() || doc.track_id != track_id {
        return View::idle();
    }
    let title_view = |secondary: Option<&'a str>, wait: Option<u64>| -> View<'a> {
        match non_empty(&doc.title) {
            Some(title) => View {
                kind: PrimaryKind::Title,
                primary: title,
                words: &[],
                fill: Fill::All,
                secondary: if two_line { secondary } else { None },
                animating: false,
                next_change_in_ms: wait,
            },
            None => View {
                next_change_in_ms: wait,
                ..View::idle()
            },
        }
    };
    if !doc.synced || doc.lines.is_empty() {
        return title_view(non_empty(&doc.artist), None);
    }

    // 最后一个 start <= position 的行。
    let idx = doc
        .lines
        .partition_point(|l| u64::from(l.start_ms) <= position_ms)
        .checked_sub(1);
    let Some(i) = idx else {
        let first = &doc.lines[0];
        let wait = u64::from(first.start_ms).saturating_sub(position_ms);
        return title_view(
            non_empty(&first.text).or(non_empty(&doc.artist)),
            Some(wait),
        );
    };
    let line = &doc.lines[i];
    let next = doc.lines.get(i + 1);
    let next_change_in_ms = next.map(|n| u64::from(n.start_ms).saturating_sub(position_ms));

    let secondary = if two_line {
        line.translation
            .as_deref()
            .and_then(non_empty)
            .or_else(|| next.and_then(|n| non_empty(&n.text)))
    } else {
        None
    };

    let Some(primary) = non_empty(&line.text) else {
        return View {
            kind: PrimaryKind::Line(i),
            primary: INTERLUDE_TEXT,
            words: &[],
            fill: Fill::Nothing,
            secondary,
            animating: false,
            next_change_in_ms,
        };
    };

    let (fill, animating) = karaoke(&line.words, position_ms);
    View {
        kind: PrimaryKind::Line(i),
        primary,
        words: &line.words,
        fill,
        secondary,
        animating,
        next_change_in_ms,
    }
}

/// 逐字填充进度。没有逐字时间时整行高亮。
fn karaoke(words: &[Word], position_ms: u64) -> (Fill, bool) {
    let Some(last) = words.last() else {
        return (Fill::All, false);
    };
    if position_ms >= u64::from(last.end_ms) {
        return (Fill::All, false);
    }
    let w = words
        .partition_point(|w| u64::from(w.start_ms) <= position_ms)
        .saturating_sub(1);
    let word = &words[w];
    let start = u64::from(word.start_ms);
    let end = u64::from(word.end_ms.max(word.start_ms));
    let fraction = if position_ms < start {
        0.0
    } else if end <= start {
        1.0
    } else {
        ((position_ms - start) as f64 / (end - start) as f64).clamp(0.0, 1.0) as f32
    };
    (Fill::Partial { word: w, fraction }, true)
}

/// 播放位置的插值：核心大约每 200ms 报一次进度，悬浮窗每帧都要一个平滑的值。
#[derive(Debug, Clone, Copy, Default)]
pub struct Clock {
    /// 当前曲目。
    pub track_id: Option<i64>,
    /// 是否在播。
    pub playing: bool,
    /// 最近一次报告的位置。
    pub position_ms: u64,
}

/// 把采样插值成每帧的位置，且播放中不往回跳（进度报告的抖动）。
#[derive(Debug, Default)]
pub struct Interpolator {
    last_track: Option<i64>,
    last_shown: u64,
}

/// 小于这个值的回退视为抖动，忽略；更大的回退是 seek。
const JITTER_MS: u64 = 300;

impl Interpolator {
    /// `elapsed_ms`：距离采样过去了多久。
    pub fn position(&mut self, clock: Clock, elapsed_ms: u64) -> u64 {
        let raw = if clock.playing {
            clock.position_ms.saturating_add(elapsed_ms)
        } else {
            clock.position_ms
        };
        let shown = if clock.playing
            && clock.track_id == self.last_track
            && raw < self.last_shown
            && self.last_shown - raw < JITTER_MS
        {
            self.last_shown
        } else {
            raw
        };
        self.last_track = clock.track_id;
        self.last_shown = shown;
        shown
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::Line;

    fn line(start: u32, text: &str) -> Line {
        Line {
            start_ms: start,
            text: text.into(),
            translation: None,
            words: vec![],
        }
    }

    fn doc(lines: Vec<Line>) -> LyricsDoc {
        LyricsDoc {
            track_id: Some(7),
            title: "Song".into(),
            artist: "Artist".into(),
            synced: true,
            lines,
        }
    }

    #[test]
    fn idle_without_doc_or_on_track_mismatch() {
        assert_eq!(view(None, Some(7), 0, true).kind, PrimaryKind::Idle);
        let d = doc(vec![line(0, "a")]);
        assert_eq!(view(Some(&d), Some(8), 0, true).kind, PrimaryKind::Idle);
        assert_eq!(view(Some(&d), None, 0, true).kind, PrimaryKind::Idle);
    }

    #[test]
    fn title_before_first_line_with_upcoming_line() {
        let d = doc(vec![line(1000, "first"), line(2000, "second")]);
        let v = view(Some(&d), Some(7), 400, true);
        assert_eq!(v.kind, PrimaryKind::Title);
        assert_eq!(v.primary, "Song");
        assert_eq!(v.secondary, Some("first"));
        assert_eq!(v.next_change_in_ms, Some(600));
    }

    #[test]
    fn current_and_next_line() {
        let d = doc(vec![line(0, "a"), line(1000, "b"), line(2000, "c")]);
        let v = view(Some(&d), Some(7), 1500, true);
        assert_eq!(v.kind, PrimaryKind::Line(1));
        assert_eq!(v.primary, "b");
        assert_eq!(v.secondary, Some("c"));
        assert_eq!(v.fill, Fill::All);
        assert!(!v.animating);
        assert_eq!(v.next_change_in_ms, Some(500));
        let single = view(Some(&d), Some(7), 1500, false);
        assert_eq!(single.secondary, None);
        let last = view(Some(&d), Some(7), 9000, true);
        assert_eq!(last.secondary, None);
        assert_eq!(last.next_change_in_ms, None);
    }

    #[test]
    fn translation_wins_over_next_line() {
        let mut l = line(0, "原文");
        l.translation = Some("translation".into());
        let d = doc(vec![l, line(1000, "next")]);
        assert_eq!(
            view(Some(&d), Some(7), 10, true).secondary,
            Some("translation")
        );
    }

    #[test]
    fn unsynced_shows_title_and_artist() {
        let mut d = doc(vec![line(0, "x")]);
        d.synced = false;
        let v = view(Some(&d), Some(7), 5000, true);
        assert_eq!(v.primary, "Song");
        assert_eq!(v.secondary, Some("Artist"));
    }

    #[test]
    fn interlude_line() {
        let d = doc(vec![line(0, "a"), line(1000, " "), line(5000, "b")]);
        let v = view(Some(&d), Some(7), 2000, true);
        assert_eq!(v.primary, INTERLUDE_TEXT);
        assert_eq!(v.secondary, Some("b"));
    }

    #[test]
    fn karaoke_progress() {
        let mut l = line(1000, "ab");
        l.words = vec![
            Word {
                start_ms: 1000,
                end_ms: 1200,
                text: "a".into(),
            },
            Word {
                start_ms: 1200,
                end_ms: 1600,
                text: "b".into(),
            },
        ];
        let d = doc(vec![l, line(3000, "z")]);
        let at = |p| view(Some(&d), Some(7), p, true);
        assert_eq!(
            at(1100).fill,
            Fill::Partial {
                word: 0,
                fraction: 0.5
            }
        );
        assert!(at(1100).animating);
        assert_eq!(
            at(1300).fill,
            Fill::Partial {
                word: 1,
                fraction: 0.25
            }
        );
        assert_eq!(at(1600).fill, Fill::All);
        assert!(!at(1600).animating);
    }

    #[test]
    fn interpolator_smooths_jitter_but_follows_seeks() {
        let mut ip = Interpolator::default();
        let c = |pos| Clock {
            track_id: Some(1),
            playing: true,
            position_ms: pos,
        };
        assert_eq!(ip.position(c(1000), 150), 1150);
        // 新采样比显示值略小：保持不回退。
        assert_eq!(ip.position(c(1100), 0), 1150);
        // seek 回到开头：跟随。
        assert_eq!(ip.position(c(0), 0), 0);
        // 暂停时不插值。
        let paused = Clock {
            playing: false,
            ..c(500)
        };
        assert_eq!(ip.position(paused, 999), 500);
    }
}
