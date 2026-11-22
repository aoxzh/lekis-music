//! 注音歌词（Ruby lyrics）：给歌词里的汉字标上读音。
//!
//! 解决的是「本地曲库里有歌词，但看不懂 / 唱不出来」这件事：中文歌词逐字标拼音，
//! 渲染在汉字上方（`{晴|qíng}` 这种 ruby 排版）。不需要联网、不需要词典包——
//! 拼音表是编译进二进制的静态数据。
//!
//! 输出用 **UTF-16 偏移**而不是字节偏移：Dart 的 `String` 是 UTF-16，桥接层把
//! 偏移原样交给 `TextPainter.getBoxesForSelection`，两边不需要再换算。
//!
//! 只处理汉字。假名、谚文、拉丁字母、数字、标点全部原样跳过（返回的 `spans` 里
//! 不会出现它们），这样调用方可以放心地把 `spans` 当作「需要标注的位置」列表。
//!
//! 多音字按单字默认读音处理（`了` → `le`、`行` → `xing`）。歌词是短句，
//! 逐字注音本来就是给「认字」用的，不做词级消歧——真要消歧得引入词典包，
//! 体积代价（几十 MB）远大于收益。

use pinyin::{Pinyin, ToPinyin};

/// 一个注音区间：`line` 的 UTF-16 区间 `[start, end)`，读音为 `ruby`。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RubySpan {
    /// 起始 UTF-16 偏移（含）。
    pub start: usize,
    /// 结束 UTF-16 偏移（不含）。
    pub end: usize,
    /// 读音（拼音）。
    pub ruby: String,
}

/// 拼音写法。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum PinyinStyle {
    /// 不带声调：`qing tian`。
    #[default]
    Plain,
    /// 带声调符号：`qíng tiān`。
    Tone,
    /// 带声调数字：`qing2 tian1`。
    ToneNum,
}

impl PinyinStyle {
    /// 取这个风格下单个音节的写法。
    fn render(self, pinyin: Pinyin) -> &'static str {
        match self {
            Self::Plain => pinyin.plain(),
            Self::Tone => pinyin.with_tone(),
            Self::ToneNum => pinyin.with_tone_num_end(),
        }
    }
}

/// 是否为汉字（含扩展 A 与兼容区）。
#[must_use]
pub fn is_han(ch: char) -> bool {
    matches!(ch as u32,
        0x3400..=0x4DBF     // 扩展 A
        | 0x4E00..=0x9FFF   // 基本区
        | 0xF900..=0xFAFF   // 兼容表意文字
        | 0x20000..=0x2FA1F // 扩展 B~F（含兼容补充）
    )
}

/// 这段文本里有没有汉字。给调用方做「要不要注音」的廉价前置判断。
#[must_use]
pub fn contains_han(text: &str) -> bool {
    text.chars().any(is_han)
}

/// 给一行文本生成注音区间。
///
/// 偏移是 **UTF-16**，可以直接给 Dart 用。没有汉字的行返回空 `Vec`。
///
/// ```ignore
/// let spans = annotate_line("晴天", PinyinStyle::Plain);
/// assert_eq!(spans[0].ruby, "qing");
/// ```
#[must_use]
pub fn annotate_line(line: &str, style: PinyinStyle) -> Vec<RubySpan> {
    // 先廉价筛一遍：纯英文 / 纯假名歌词（大量存在）直接返回，不进字符循环。
    if !contains_han(line) {
        return Vec::new();
    }
    let mut spans = Vec::new();
    let mut offset = 0usize;
    for ch in line.chars() {
        let len = ch.len_utf16();
        if is_han(ch) {
            if let Some(pinyin) = ch.to_pinyin() {
                spans.push(RubySpan {
                    start: offset,
                    end: offset + len,
                    ruby: style.render(pinyin).to_owned(),
                });
            }
        }
        offset += len;
    }
    spans
}

/// 批量版本：一次把整首歌的歌词都注好音。
#[must_use]
pub fn annotate_lines<S: AsRef<str>>(lines: &[S], style: PinyinStyle) -> Vec<Vec<RubySpan>> {
    lines
        .iter()
        .map(|line| annotate_line(line.as_ref(), style))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn joined(line: &str, style: PinyinStyle) -> String {
        annotate_line(line, style)
            .into_iter()
            .map(|s| s.ruby)
            .collect::<Vec<_>>()
            .join(" ")
    }

    #[test]
    fn plain_pinyin_per_han_char() {
        assert_eq!(joined("晴天", PinyinStyle::Plain), "qing tian");
    }

    #[test]
    fn tone_marks() {
        assert_eq!(joined("晴天", PinyinStyle::Tone), "qíng tiān");
    }

    #[test]
    fn tone_numbers() {
        assert_eq!(joined("晴天", PinyinStyle::ToneNum), "qing2 tian1");
    }

    #[test]
    fn skips_non_han() {
        // 假名、拉丁、数字、标点都不进 spans，但偏移要正确。
        let spans = annotate_line("Hello 世界 123", PinyinStyle::Plain);
        assert_eq!(spans.len(), 2);
        let chars: Vec<char> = "Hello 世界 123".chars().collect();
        assert_eq!(chars[spans[0].start], '世');
        assert_eq!(chars[spans[1].start], '界');
    }

    #[test]
    fn offsets_are_utf16_units() {
        // emoji 占 2 个 UTF-16 单元，汉字偏移必须跟着走，否则 Dart 侧框选会错位。
        let line = "🎵晴天";
        let spans = annotate_line(line, PinyinStyle::Plain);
        assert_eq!(spans[0].start, 2);
        assert_eq!(spans[0].end, 3);
        assert_eq!(spans[1].start, 3);
        // 用 UTF-16 切片验证：Dart 里等价于 line.substring(start, end)。
        let units: Vec<u16> = line.encode_utf16().collect();
        let first: String = units[spans[0].start..spans[0].end]
            .iter()
            .filter_map(|unit| char::from_u32(u32::from(*unit)))
            .collect();
        assert_eq!(first, "晴");
    }

    #[test]
    fn traditional_chinese() {
        assert_eq!(joined("我們的歌", PinyinStyle::Plain), "wo men de ge");
    }

    #[test]
    fn pure_kana_is_empty() {
        assert!(annotate_line("きょうもあめ", PinyinStyle::Plain).is_empty());
        assert!(!contains_han("きょうもあめ"));
    }

    #[test]
    fn batch_matches_single() {
        let lines = ["晴天", "きょうのあめ", ""];
        let batch = annotate_lines(&lines, PinyinStyle::Plain);
        assert_eq!(batch.len(), 3);
        assert_eq!(batch[0], annotate_line(lines[0], PinyinStyle::Plain));
        assert!(batch[1].is_empty());
        assert!(batch[2].is_empty());
    }

    #[test]
    fn punctuation_between_han_keeps_offsets() {
        let spans = annotate_line("我，你", PinyinStyle::Plain);
        assert_eq!(spans.len(), 2);
        assert_eq!(
            spans[0],
            RubySpan {
                start: 0,
                end: 1,
                ruby: "wo".to_owned()
            }
        );
        assert_eq!(
            spans[1],
            RubySpan {
                start: 2,
                end: 3,
                ruby: "ni".to_owned()
            }
        );
    }
}
